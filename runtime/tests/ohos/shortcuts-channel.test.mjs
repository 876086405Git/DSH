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
const text = readFileSync(new URL('../../../app/ohos/entry/src/main/ets/plugins/ShortcutsPlugin.ets', import.meta.url), 'utf8');
const compiled = ts.transpileModule(text, { compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
} });
const plain = value => value instanceof Map || Object.prototype.toString.call(value) === '[object Map]'
  ? Object.fromEntries(value) : value;
const shortcut = kind => ({ parameters: { dshShortcut: kind } });
const fromLauncher = { launchReason: 0, launchReasonMessage: 'ReasonMessage_DesktopShortcut' };
const fromElsewhere = { launchReason: 0 };

// A fresh module per test: the pending queue is a process-wide static.
function fixture() {
  const channels = [], sent = [];
  class Channel {
    constructor(_messenger, name) { this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod(method, args) { sent.push({ channel: this.name, method, args: plain(args) }); }
  }
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, {
    module, exports: module.exports,
    require(name) {
      if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel };
      throw new Error(`Unexpected runtime import ${name}`);
    },
  });
  const Plugin = module.exports.default;
  const engine = { getBinaryMessenger: () => ({}) };
  const make = () => { const plugin = new Plugin(); plugin.onAttachedToEngine(engine); return plugin; };
  function call(method, args = {}) {
    return new Promise(resolve => channels.at(-1).handler.onMethodCall({ method, argument: name => args[name] }, {
      success: value => resolve({ value: plain(value) }),
      error: (code, message) => resolve({ error: code, message }),
      notImplemented: () => resolve({ missing: true }),
    }));
  }
  return { Plugin, make, engine, channels, sent, call };
}

test('the exact channel name, and methods it does not have stay missing', async () => {
  const f = fixture(); f.make();
  assert.deepEqual(f.channels.map(c => c.name), ['dsh/shortcuts']);
  assert.deepEqual(await f.call('unknown'), { missing: true });
});

test('setRecent answers success and sends nothing back: there is no public API to publish with', async () => {
  const f = fixture(); f.make();
  const items = [{ id: 's1', title: '对话', host: 'local' }];
  assert.deepEqual(await f.call('setRecent', { items }), { value: true });
  assert.deepEqual(await f.call('setRecent', { items: [] }), { value: true });
  assert.deepEqual(f.sent, []);
});

test('cold and warm entries wait for ready, use the Dart map contract and keep arrival order', async () => {
  const f = fixture(); f.make();
  f.Plugin.receive(shortcut('voice'), fromLauncher);
  f.Plugin.receive(shortcut('new'), fromLauncher);
  assert.deepEqual(f.sent, []);
  assert.deepEqual(await f.call('ready'), { value: true });
  assert.deepEqual(f.sent, [
    { channel: 'dsh/shortcuts', method: 'entry', args: { kind: 'voice' } },
    { channel: 'dsh/shortcuts', method: 'entry', args: { kind: 'new' } },
  ]);
  await f.call('ready');
  assert.equal(f.sent.length, 2);
  f.Plugin.receive(shortcut('new'), fromLauncher);
  f.Plugin.receive(shortcut('new'), fromLauncher);
  assert.equal(f.sent.length, 4, 'a shortcut tapped twice is two arrivals');
});

test('an entry that arrives before the engine exists is kept for it', async () => {
  const f = fixture();
  f.Plugin.receive(shortcut('new'), fromLauncher);
  f.make();
  assert.deepEqual(f.sent, []);
  await f.call('ready');
  assert.deepEqual(f.sent.map(v => v.args), [{ kind: 'new' }]);
});

test('engine replacement before ready keeps the arrival and delivers it once', async () => {
  const f = fixture(); const first = f.make();
  f.Plugin.receive(shortcut('voice'), fromLauncher);
  first.onDetachedFromEngine(f.engine);
  assert.equal(f.channels[0].handler, null);
  const second = f.make();
  await f.call('ready');
  assert.deepEqual(f.sent.map(v => v.args), [{ kind: 'voice' }]);
  second.onDetachedFromEngine(f.engine);
  f.make();
  await f.call('ready');
  assert.equal(f.sent.length, 1);
});

test('after detach nothing reaches the retired channel; the entry waits for the next engine', async () => {
  const f = fixture(); const plugin = f.make();
  await f.call('ready');
  plugin.onDetachedFromEngine(f.engine);
  f.Plugin.receive(shortcut('new'), fromLauncher);
  assert.deepEqual(f.sent, []);
  f.make();
  await f.call('ready');
  assert.deepEqual(f.sent.map(v => v.args), [{ kind: 'new' }]);
  assert.equal(f.sent.length, 1);
});

test('voice opens the microphone only for the launcher: any other app gets a plain new chat', async () => {
  const f = fixture(); f.make();
  await f.call('ready');
  f.Plugin.receive(shortcut('voice'), fromElsewhere);
  f.Plugin.receive(shortcut('voice'), { launchReason: 0, launchReasonMessage: 'ReasonMessage_SystemShare' });
  // The launcher's reason is the system's to set; a parameter claiming it means nothing.
  f.Plugin.receive({ parameters: { dshShortcut: 'voice', 'ohos.params.launchReasonMessage': 'ReasonMessage_DesktopShortcut' } }, fromElsewhere);
  assert.deepEqual(f.sent.map(v => v.args), [{ kind: 'new' }, { kind: 'new' }, { kind: 'new' }]);
  f.Plugin.receive(shortcut('voice'), fromLauncher);
  assert.deepEqual(f.sent.at(-1).args, { kind: 'voice' });
});

test('ordinary launches and anything else in the parameter are not entries', async () => {
  const f = fixture(); f.make();
  await f.call('ready');
  const wants = [
    {}, { parameters: {} }, { parameters: { other: 'new' } }, shortcut('chat'), shortcut(''), shortcut(7),
    { action: 'ohos.want.action.viewData', uri: 'dshgo://open/new' },
  ];
  for (const want of wants) assert.equal(f.Plugin.receive(want, fromLauncher), false);
  assert.deepEqual(f.sent, []);
  assert.equal(f.Plugin.receive(shortcut('new'), fromLauncher), true);
});
