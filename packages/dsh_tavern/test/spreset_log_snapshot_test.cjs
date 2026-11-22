const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {test} = require('node:test');

const assetPath = process.argv.find(value => value.startsWith('--asset='))?.slice('--asset='.length)
  ?? 'assets/spreset_page_runtime.js';
const asset = fs.readFileSync(assetPath, 'utf8');
const fixturePath = 'test/fixtures/spreset/page-console-truncation.json';
const fixtureSource = '() => { console.info("a".repeat(8193), "b".repeat(8194)); return true; }';

function page() {
  const context = vm.createContext({console: {log() {}, info() {}, warn() {}, error() {}, debug() {}}});
  vm.runInContext(asset, context);
  // Observe the actual production snapshot/serialization boundary. The host
  // console deliberately does not serialize its original user arguments.
  vm.runInContext(`
    globalThis.observed = {longReads: 0, longSnapshotKeys: 0, longSerializedKeys: 0, maxSerializedChars: 0};
    const descriptor = Object.getOwnPropertyDescriptor;
    Object.getOwnPropertyDescriptor = function(value, key) {
      if (typeof key === 'string' && key.length > 8192) observed.longReads++;
      return descriptor(value, key);
    };
    const fromEntries = Object.fromEntries;
    Object.fromEntries = function(entries) {
      const rows = Array.from(entries);
      for (const [key] of rows) if (typeof key === 'string' && key.length > 8192) observed.longSnapshotKeys++;
      return fromEntries(rows);
    };
    const stringify = JSON.stringify;
    JSON.stringify = function(value, ...rest) {
      if (value && typeof value === 'object' && !Array.isArray(value)) {
        for (const key of Object.keys(value)) if (key.length > 8192) observed.longSerializedKeys++;
      }
      const result = stringify(value, ...rest);
      if (result !== undefined) observed.maxSerializedChars = Math.max(observed.maxSerializedChars, result.length);
      return result;
    };
  `, context);
  let serial = 0;
  return {
    context,
    evaluate(source, {captureLogs = true, signal} = {}) {
      const id = `snapshot-${++serial}`;
      return context.DshSPresetPageRuntime.evaluate({
        requestId: id, chatId: 'chat', generationId: 'generation', sessionId: id,
        stage: 'EntryCondition', kind: 'functionExpression', source, arguments: [], captureLogs,
      }, signal);
    },
  };
}

async function fixture() {
  const result = await page().evaluate(fixtureSource);
  assert.equal(result.scriptLogValuesTruncated, 2);
  return JSON.parse(JSON.stringify(result));
}

if (process.argv.includes('--write-fixture')) {
  fixture().then(value => {
    fs.writeFileSync(fixturePath, JSON.stringify(value, null, 2) + '\n');
  }).catch(error => { console.error(error); process.exitCode = 1; });
} else {
  test('8 MiB property name is omitted before own value read, snapshot construction and serialization', async t => {
    const p = page();
    const result = await p.evaluate(`() => {
      let reads = 0;
      const value = {['k'.repeat(8 * 1024 * 1024)]: 'discarded', safe: 'kept', get accessor() { reads++; return 'hidden'; }};
      console.info(value);
      return reads;
    }`);
    t.diagnostic(JSON.stringify(p.context.observed));
    assert.equal(result.value, 0);
    assert.equal(p.context.observed.longReads, 0);
    assert.equal(p.context.observed.longSnapshotKeys, 0);
    assert.equal(p.context.observed.longSerializedKeys, 0);
    assert.ok(p.context.observed.maxSerializedChars < 65536);
    assert.deepEqual(JSON.parse(result.scriptLogs[0].values[0]), {safe: 'kept', accessor: '[Accessor]'});
    assert.equal(result.scriptLogValuesTruncated, 1);
    assert.equal(result.scriptLogsDropped, 0);
  });

  test('8192 UTF-16 code units remain; longer property names and scalar strings count each omitted slot once', async () => {
    const result = await page().evaluate(`() => {
      console.info({['k'.repeat(8192)]: 'kept', ['x'.repeat(8193)]: 'discarded'}, 'a'.repeat(8192), 'b'.repeat(8193));
      return true;
    }`);
    assert.equal(result.scriptLogValuesTruncated, 2);
    const values = result.scriptLogs[0].values;
    assert.equal(Object.keys(JSON.parse(values[0]))[0].length, 8192);
    assert.equal(values[1].length, 8192);
    assert.equal(values[2], '[OMITTED string: 8193 chars]');
    assert.equal(result.scriptLogsDropped, 0);
  });

  test('array counting reuses one length read and one numeric conversion for the snapshot', async () => {
    const result = await page().evaluate(`() => {
      let reads = 0, conversions = 0;
      const length = {valueOf() { conversions++; return conversions === 1 ? 52 : 2; }};
      const value = new Proxy(Array(52).fill(1), {get(target, key, receiver) {
        if (key === 'length') { reads++; return length; }
        return Reflect.get(target, key, receiver);
      }});
      console.info(value);
      return {reads, conversions};
    }`);
    assert.equal(result.value.reads, 1);
    assert.equal(result.value.conversions, 1);
    assert.equal(JSON.parse(result.scriptLogs[0].values[0]).length, 50);
    assert.equal(result.scriptLogValuesTruncated, 2);
  });

  test('array omitted-slot counts use the original Array.from ToLength result', async () => {
    for (const [expression, retained, omitted] of [
      ['NaN', 0, 0], ['-0', 0, 0], ['-2', 0, 0], ['-Infinity', 0, 0],
      ['0.9', 0, 0], ['49.9', 49, 0], ['52.9', 50, 2], ['Infinity', 50, Number.MAX_SAFE_INTEGER - 50],
    ]) {
      const result = await page().evaluate(`() => {
        const value = new Proxy([], {get(target, key, receiver) {
          return key === 'length' ? ${expression} : Reflect.get(target, key, receiver);
        }});
        console.info(value);
        console.info('x'.repeat(8193));
        return true;
      }`);
      assert.equal(JSON.parse(result.scriptLogs[0].values[0]).length, retained, expression);
      assert.equal(result.scriptLogValuesTruncated, omitted + 1, expression);
      assert.ok(Number.isSafeInteger(result.scriptLogValuesTruncated), expression);
    }
  });

  const limits = [
    ['extra console arguments', 'console.info(1, 2, 3, 4, 5, 6, 7, 8, 9);', 1],
    ['array slots', 'console.info(Array.from({length: 52}, (_, i) => i));', 2],
    ['object properties', 'console.info(Object.fromEntries(Array.from({length: 52}, (_, i) => ["k" + i, i])));', 2],
    ['depth subtree', 'let x = "leaf"; for (let i = 0; i < 7; i++) x = {x}; console.info(x);', 1],
    // 45 whole arrays consume 496 nodes with the outer array. The next array
    // retains 3 leaves, omits 7, then each of 4 remaining arrays is one cut.
    ['node subtrees', 'console.info(Array.from({length: 50}, () => Array(10).fill(1)));', 11],
    ['event preview', 'console.info(...Array(8).fill("a".repeat(8192)));', 1],
    ['function text', 'console.info(Function("/*" + "x".repeat(9000) + "*/"));', 1],
  ];
  for (const [label, body, count] of limits) {
    test(`page truncation count covers ${label}`, async () => {
      const result = await page().evaluate(`() => { ${body} return 1; }`);
      assert.equal(result.value, 1);
      assert.equal(result.scriptLogValuesTruncated, count);
      assert.equal(result.scriptLogsDropped, 0);
      if (label === 'event preview') assert.equal(result.scriptLogs[0].truncated, true);
    });
  }

  test('evicted console records and value truncations stay separate', async () => {
    const result = await page().evaluate('() => { for (let i = 0; i < 600; i++) console.info(i); return 600; }');
    assert.equal(result.scriptLogs.length, 500);
    assert.equal(result.scriptLogsDropped, 100);
    assert.equal(result.scriptLogValuesTruncated, 0);
  });

  test('capture disabled neither snapshots nor counts omitted values', async () => {
    const p = page();
    const result = await p.evaluate('() => { console.info({["k".repeat(8 * 1024 * 1024)]: "x".repeat(9000)}); return 1; }', {captureLogs: false});
    assert.equal(result.value, 1);
    assert.equal(result.scriptLogs.length, 0);
    assert.equal(result.scriptLogsDropped, 0);
    assert.equal(result.scriptLogValuesTruncated, 0);
    assert.equal(p.context.observed.longReads, 0);
    assert.equal(p.context.observed.longSnapshotKeys, 0);
    assert.equal(p.context.observed.longSerializedKeys, 0);
  });

  test('real page response matches the small fixture used by the Dart report test', async () => {
    assert.deepEqual(await fixture(), JSON.parse(fs.readFileSync(fixturePath, 'utf8')));
  });

  test('script failures and initial cancellation still reject', async () => {
    const p = page();
    await assert.rejects(p.evaluate('() => { console.info("x".repeat(9000)); throw new Error("actual script failure"); }'), /actual script failure/);
    await assert.rejects(p.evaluate('() => 1', {signal: {aborted: true}}), /cancelled/);
  });
}
