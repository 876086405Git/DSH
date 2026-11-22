// Usage: node tool/st_differential/helper-image-conversion-oracle.cjs /path/to/pinned/utils.ts
// Executes only the actual fixed conversion/array functions with explicit
// network/base64, event and timer boundaries. Does not load the extension.
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { stripTypeScriptTypes } = require('node:module');
const source = fs.readFileSync(process.argv[2], 'utf8');
const sha256 = '9aace591938c207d8c3e81a5619ed39ccc6a1d53a1d3e84190243ca6c69ca3ff';
assert.equal(crypto.createHash('sha256').update(source).digest('hex'), sha256);
function extract(marker) {
  const start = source.indexOf(marker);
  assert.ok(start >= 0, marker);
  const end = /^}\s*$/m.exec(source.slice(start));
  assert.ok(end, marker);
  return stripTypeScriptTypes(source.slice(start, start + end.index + end[0].length).replace(/^export /, ''), { mode: 'strip' });
}
const code = [
  extract('export async function convertFileToBase64('),
  extract('export async function processImageArrayDirectly('),
  extract('export function setupImageArrayProcessing('),
  'Object.assign(globalThis, {convertFileToBase64,processImageArrayDirectly,setupImageArrayProcessing});',
].join('\n');
const urls = [0, 1, 2, 3].map(i => `https://fixture.invalid/${i}.png`);
const png = 'data:image/png;base64,AQ==', otherPng = 'data:image/png;base64,Ag==';
const cases = [
  { name: 'single-download-failure', mode: 'single', stages: ['download'] },
  { name: 'single-base64-failure', mode: 'single', stages: ['base64'] },
  { name: 'single-data-uri', mode: 'single', data: true, stages: [] },
  { name: 'raw-array-mixed', mode: 'raw', stages: ['ok', 'download', 'ok', 'base64'], input: 'Q' },
  { name: 'normal-array-mixed', mode: 'normal', stages: ['ok', 'download', 'ok', 'base64'], input: 'Q' },
  { name: 'raw-array-all-failed', mode: 'raw', stages: ['download'], input: '' },
  { name: 'normal-array-all-failed', mode: 'normal', stages: ['download'], input: '' },
  { name: 'normal-array-missing', mode: 'normal', stages: ['ok'], input: 'Q', missing: true },
  { name: 'normal-array-assistant', mode: 'normal', stages: ['ok'], input: 'Q', role: 'assistant' },
  { name: 'normal-array-parts', mode: 'normal', stages: ['ok'], input: 'Q', parts: true },
];
async function run(test) {
  const calls = [], warnings = [], gates = new Map();
  for (let i = 0; i < test.stages.length; i++) {
    let release;
    const promise = new Promise(resolve => release = resolve);
    gates.set(urls[i], { promise, release });
  }
  let handler;
  const ctx = {
    console: { warn: message => warnings.push(String(message)), error: message => warnings.push(String(message)) },
    oai_settings: { inline_image_quality: 'low' }, isDataURL: value => value.startsWith('data:'),
    eventSource: { once: (name, callback) => { handler = callback; }, removeListener() {} },
    setTimeout: () => 1, clearTimeout() {},
    fetch: async url => {
      calls.push(url);
      await gates.get(url).promise;
      const index = urls.indexOf(url);
      if (test.stages[index] === 'download') throw new Error('Observed fixture fetch failure');
      return { ok: true, blob: async () => ({ index }) };
    },
    getBase64Async: async blob => {
      if (test.stages[blob.index] === 'base64') throw new Error('Observed fixture base64 failure');
      return blob.index === 2 ? otherPng : png;
    },
  };
  vm.createContext(ctx);
  vm.runInContext(code, ctx);
  let pending, setup, message;
  if (test.mode === 'single') pending = ctx.convertFileToBase64(test.data ? png : urls[0]);
  else if (test.mode === 'raw') pending = ctx.processImageArrayDirectly(test.input, urls.slice(0, test.stages.length));
  else {
    setup = ctx.setupImageArrayProcessing(test.input, urls.slice(0, test.stages.length));
    message = { role: test.role ?? 'user', content: test.missing ? 'NO MARKER' : setup.userInputWithMarker };
    if (test.parts) message.content = [{ type: 'text', text: message.content }];
    pending = handler({ chat: [message] });
  }
  const shouldFetch = !test.data && !test.missing && !test.parts && test.role !== 'assistant';
  assert.equal(calls.length, shouldFetch ? test.stages.length : 0, `${test.name}: concurrent start`);
  for (const gate of [...gates.values()].reverse()) gate.release();
  const value = await pending;
  if (setup) {
    await setup.imageProcessingPromise;
    setup.cleanup();
  }
  const content = test.mode === 'normal' ? message.content : value;
  if (test.name.endsWith('mixed')) {
    assert.deepEqual(JSON.parse(JSON.stringify(content)), [
      { type: 'text', text: 'Q' },
      { type: 'image_url', image_url: { url: png, detail: 'low' } },
      { type: 'image_url', image_url: { url: otherPng, detail: 'low' } },
    ]);
  }
  if (test.name.endsWith('all-failed')) assert.deepEqual(JSON.parse(JSON.stringify(content)), [{ type: 'text', text: '' }]);
  if (test.name.endsWith('-failure')) assert.equal(value, undefined);
  return { name: test.name, defined: content !== undefined, ...(content === undefined ? {} : { content }), calls, warnings };
}
(async () => {
  const results = [];
  for (const test of cases) results.push(await run(test));
  process.stdout.write(JSON.stringify({
    source: { repository: 'N0VI028/JS-Slash-Runner', commit: '29331c36fb9b2e880d4d488ff919317e1bc95684', file: 'src/function/generate/utils.ts', sha256 },
    scope: 'Actual fixed conversion and array functions; network/base64 outcomes, timers and event host are explicit controls. No compression, tokenizer, browser or full prompt assembly.',
    count: results.length, results,
  }, null, 2) + '\n');
})().catch(error => { console.error(error); process.exitCode = 1; });
