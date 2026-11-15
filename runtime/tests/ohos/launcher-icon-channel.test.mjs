// Actual product ETS after TypeScript erasure; OS and Flutter are explicit test doubles.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const prefix = process.env.OHOS_TYPESCRIPT_PREFIX;
assert(prefix, 'Set OHOS_TYPESCRIPT_PREFIX to the locked process npm-ci directory');
const ts = createRequire(resolve(prefix, 'package.json'))('typescript');
const text = readFileSync(new URL('../../../app/ohos/entry/src/main/ets/plugins/LauncherIconPlugin.ets', import.meta.url), 'utf8');
const compiled = ts.transpileModule(text, { compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
} });
const plain = value => value instanceof Map || Object.prototype.toString.call(value) === '[object Map]'
  ? Object.fromEntries(value) : value;
const failure = code => Object.assign(new Error('bundle manager'), { code });

// `enabled`: the alternate icon the system reports on. Alternate names are the
// app.json5 ones; `mist` is the app's own icon, so it never appears.
function fixture({ enabled = null, set, get } = {}) {
  const channels = [], sets = [];
  const state = { enabled };
  class Channel {
    constructor(_messenger, name) { this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
  }
  const bundleManager = {
    getAlternateIcons: get ?? (async () => ['night', 'frost', 'ink'].map(name => ({ iconName: name, iconId: 1, enabled: name === state.enabled }))),
    setAlternateIcon: set ?? (async name => {
      sets.push(name);
      if (name === '' && state.enabled === null) throw failure(17700309);
      state.enabled = name === '' ? null : name;
    }),
  };
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, {
    module, exports: module.exports,
    require(name) {
      if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel };
      if (name === '@ohos.bundle.bundleManager') return { default: bundleManager };
      throw new Error(`Unexpected runtime import ${name}`);
    },
  });
  const engine = { getBinaryMessenger: () => ({}) };
  const plugin = new module.exports.default();
  plugin.onAttachedToEngine(engine);
  function call(method, args = {}) {
    return new Promise(resolve => channels.at(-1).handler.onMethodCall({ method, argument: name => args[name] }, {
      success: value => resolve({ value: plain(value) }),
      error: (code, message) => resolve({ error: code, message }),
      notImplemented: () => resolve({ missing: true }),
    }));
  }
  return { plugin, engine, channels, sets, state, call };
}

test('the exact channel name, and methods it does not have stay missing', async () => {
  const f = fixture();
  assert.deepEqual(f.channels.map(c => c.name), ['dsh/launcher_icon']);
  assert.deepEqual(await f.call('unknown'), { missing: true });
});

test('state reports the enabled alternate, and the app\'s own icon when there is none', async () => {
  assert.deepEqual(await fixture().call('state'), { value: { current: 'mist' } });
  for (const name of ['night', 'frost', 'ink']) {
    assert.deepEqual(await fixture({ enabled: name }).call('state'), { value: { current: name } });
  }
});

test('state failures stay errors: Dart keeps its own answer', async () => {
  const rejected = fixture({ get: () => Promise.reject(failure(17700311)) });
  assert.equal((await rejected.call('state')).error, 'failed');
  const thrown = fixture({ get: () => { throw failure(17700311); } });
  assert.equal((await thrown.call('state')).error, 'failed');
  const malformed = fixture({ get: async () => [{ iconName: 'unknown-icon', iconId: 1, enabled: true }] });
  assert.equal((await malformed.call('state')).error, 'failed');
});

test('set turns an alternate on by its app.json5 name and answers with what is on', async () => {
  const f = fixture();
  assert.deepEqual(await f.call('set', { id: 'night' }), { value: { current: 'night' } });
  assert.deepEqual(f.sets, ['night']);
  assert.deepEqual(await f.call('state'), { value: { current: 'night' } });
  assert.deepEqual(await f.call('set', { id: 'ink' }), { value: { current: 'ink' } });
  assert.deepEqual(f.sets, ['night', 'ink']);
});

test('mist cancels the alternate; already on it is success, not the system\'s 17700309', async () => {
  const f = fixture({ enabled: 'frost' });
  assert.deepEqual(await f.call('set', { id: 'mist' }), { value: { current: 'mist' } });
  assert.deepEqual(f.sets, ['']);
  assert.equal(f.state.enabled, null);
  assert.deepEqual(await f.call('set', { id: 'mist' }), { value: { current: 'mist' } });
});

test('a refused switch is an error, whichever way the system says it', async () => {
  const theme = fixture({ set: () => Promise.reject(failure(17700310)) });
  assert.equal((await theme.call('set', { id: 'night' })).error, 'failed');
  const thrown = fixture({ set: () => { throw failure(17700310); } });
  assert.equal((await thrown.call('set', { id: 'night' })).error, 'failed');
  const cancelFails = fixture({ enabled: 'night', set: () => Promise.reject(failure(17700310)) });
  assert.equal((await cancelFails.call('set', { id: 'mist' })).error, 'failed');
});

test('an unknown id never reaches the system', async () => {
  const f = fixture();
  for (const id of [undefined, null, '', 'mistt', 'summer_theme', 7, 'layered_image']) {
    assert.equal((await f.call('set', { id })).error, 'unknown', String(id));
  }
  assert.deepEqual(f.sets, []);
});

test('detaching clears the handler', () => {
  const f = fixture();
  f.plugin.onDetachedFromEngine(f.engine);
  assert.equal(f.channels[0].handler, null);
});
