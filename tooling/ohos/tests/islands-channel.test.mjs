// Runs the actual IslandsPlugin.ets against the prepared fork's real
// InstanceManager and WebViewPlatformView (see webview-fork-fixture.mjs for the
// environment). The system APIs and Flutter's channel are doubles: this is not
// an ArkTS compiler or a device test.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { ControllerDouble, forkClasses, forkSource, loadEts, RenderExitReason } from './webview-fork-fixture.mjs';

const plugins = new URL('../../../app/ohos/entry/src/main/ets/plugins/', import.meta.url);
const source = name => readFileSync(new URL(name, plugins), 'utf8');
const plain = value => value instanceof Map || Object.prototype.toString.call(value) === '[object Map]'
  ? Object.fromEntries(value) : value;
const MemoryLevel = Object.freeze({ MEMORY_LEVEL_MODERATE: 0, MEMORY_LEVEL_LOW: 1, MEMORY_LEVEL_CRITICAL: 2,
  MEMORY_LEVEL_UI_HIDDEN: 3, MEMORY_LEVEL_BACKGROUND_MODERATE: 4, MEMORY_LEVEL_BACKGROUND_LOW: 5,
  MEMORY_LEVEL_BACKGROUND_CRITICAL: 6 });
const GIB = 1024 * 1024;

function fixture({ webViewPlugin = true, memory = {} } = {}) {
  const channels = [], watchers = new Map();
  let nextWatcher = 1;
  const { InstanceManager, WebViewPlatformView } = forkClasses();
  const instances = new InstanceManager({ onFinalize() {} });
  const webView = id => {
    const view = new WebViewPlatformView({}, instances);
    instances.addDartCreatedInstance(view, id);
    return view;
  };
  class Channel {
    invoked = [];
    constructor(_messenger, name) { this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod(method, args) { this.invoked.push([method, plain(args)]); }
  }
  const hidebug = {
    getSystemMemInfo: memory.info ?? (() => ({ totalMem: 12n * BigInt(GIB), availableMem: 5n * BigInt(GIB) })),
    getAppNativeMemInfoAsync: memory.pss ?? (async () => ({ pss: 123456n })),
  };
  const appManager = { isRamConstrainedDevice: memory.lowRam ?? (async () => false) };
  const facts = loadEts(source('OhosDeviceFacts.ets'), {
    '@ohos.hidebug': { default: hidebug }, '@ohos.deviceInfo': { default: {} },
  }, { canIUse: () => memory.capable ?? true });
  const { default: IslandsPlugin } = loadEts(source('IslandsPlugin.ets'), {
    '@ohos.hidebug': { default: hidebug },
    '@ohos.app.ability.appManager': { default: appManager },
    '@ohos.app.ability.AbilityConstant': { default: { MemoryLevel } },
    '@ohos/flutter_ohos': { MethodChannel: Channel },
    './OhosDeviceFacts': facts,
  }, { Map });
  const application = {
    on(type, callback) { assert.equal(type, 'environment'); watchers.set(nextWatcher, callback); return nextWatcher++; },
    off(type, id) { assert.equal(type, 'environment'); assert.ok(watchers.delete(id)); return Promise.resolve(); },
  };
  const registry = {
    has: name => webViewPlugin && name === 'WebViewFlutterPlugin',
    // As FlutterEngineConnectionRegistry: an unknown name gets an empty plugin.
    get: name => (webViewPlugin && name === 'WebViewFlutterPlugin' ? { getInstanceManager: () => instances } : {}),
  };
  const binding = {
    getBinaryMessenger: () => ({}),
    getApplicationContext: () => ({ getApplicationContext: () => application }),
    getFlutterEngine: () => ({ getPlugins: () => registry }),
  };
  const plugin = new IslandsPlugin();
  plugin.onAttachedToEngine(binding);
  const channel = channels[0];
  // StandardMessageCodec decodes a Dart map to a JS Map; MethodCall.argument reads it.
  const call = (method, args) => new Promise(resolve => channel.handler.onMethodCall({
    method, args,
    argument: key => (args == null ? null : new Map(Object.entries(args)).get(key)),
  }, {
    success: value => resolve({ value: plain(value) }),
    error: code => resolve({ error: code }),
    notImplemented: () => resolve({ missing: true }),
  }));
  return { plugin, binding, channel, call, webView, instances, watchers };
}

const attach = (f, id, extra = {}) => f.call('attach', { id, dark: false, textZoom: 100, ...extra });

test('the channel takes the methods of IslandsPlugin.kt and nothing else', async () => {
  const f = fixture();
  assert.equal(f.channel.name, 'dsh/islands');
  assert.deepEqual(await f.call('onPause', {}), { missing: true });
});

test('EntryAbility registers it once the fork is registered', () => {
  const entry = readFileSync(new URL('../entryability/EntryAbility.ets', plugins), 'utf8');
  assert.ok(entry.indexOf('GeneratedPluginRegistrant.registerWith') < entry.indexOf('add(new IslandsPlugin())'));
});

test('the plugin name it looks up is the one the fork registers under', () => {
  assert.match(forkSource('WebViewFlutterPlugin.ets'), /const TAG:string = "WebViewFlutterPlugin";/);
  assert.match(forkSource('WebViewFlutterPlugin.ets'), /getUniqueClassName\(\): string \{\s*return TAG;/);
});

test('attach takes the WebView with the identifier Dart knows it by', async () => {
  const f = fixture();
  const view = f.webView(7), other = f.webView(8);
  assert.deepEqual(await attach(f, 7, { dark: true, textZoom: 130 }), { value: true });
  assert.equal(view.getDarkMode(), true);
  assert.equal(view.getWebSettings().getTextZoom(), 130);
  assert.equal(other.getDarkMode(), false);
  assert.equal(other.getWebSettings().getTextZoom(), 0);
});

test('attach is false when there is no such WebView, and never pretends', async () => {
  const f = fixture();
  assert.deepEqual(await attach(f, 7), { value: false });
  for (const id of [null, undefined, '7', 7.5]) assert.deepEqual(await attach(f, id), { value: false });
  f.instances.addDartCreatedInstance({}, 5);
  assert.deepEqual(await attach(f, 5), { value: false });
  const none = fixture({ webViewPlugin: false });
  none.webView(7);
  assert.deepEqual(await attach(none, 7), { value: false });
});

test('dark and text size change at run time on the WebView named', async () => {
  const f = fixture();
  const view = f.webView(7), other = f.webView(8);
  await attach(f, 7);
  await attach(f, 8);
  assert.deepEqual(await f.call('setDark', { id: 7, dark: true }), { value: null });
  assert.equal(view.getDarkMode(), true);
  assert.equal(other.getDarkMode(), false);
  assert.deepEqual(await f.call('setDark', { id: 7, dark: false }), { value: null });
  assert.equal(view.getDarkMode(), false);
  const zooms = [];
  view.getWebSettings().onTextZoomChanged(ratio => zooms.push(ratio));
  assert.deepEqual(await f.call('setTextZoom', { id: 7, zoom: 150 }), { value: null });
  assert.deepEqual(zooms, [150]);
  assert.equal(other.getWebSettings().getTextZoom(), 100);
  assert.deepEqual(await f.call('setDark', { id: 99, dark: true }), { value: null });
  assert.deepEqual(await f.call('setTextZoom', { id: 99, zoom: 120 }), { value: null });
});

test('text zoom keeps to the range IslandPolicy.textZoom keeps on Android', async () => {
  const f = fixture();
  const view = f.webView(7);
  await attach(f, 7, { textZoom: 20 });
  assert.equal(view.getWebSettings().getTextZoom(), 50);
  await f.call('setTextZoom', { id: 7, zoom: 999 });
  assert.equal(view.getWebSettings().getTextZoom(), 300);
  await f.call('setTextZoom', { id: 7 });
  assert.equal(view.getWebSettings().getTextZoom(), 300);
});

test('a dead renderer is reported with the identifier of the WebView that saw it', async () => {
  const f = fixture();
  const view = f.webView(7), other = f.webView(8), unguarded = f.webView(9);
  await attach(f, 7);
  await attach(f, 8);
  view.onRenderExited({ renderExitReason: RenderExitReason.ProcessCrashed });
  assert.deepEqual(f.channel.invoked, [['rendererGone', { id: 7, crashed: true }]]);
  other.onRenderExited({ renderExitReason: RenderExitReason.ProcessWasKilled });
  assert.deepEqual(f.channel.invoked[1], ['rendererGone', { id: 8, crashed: false }]);
  unguarded.onRenderExited({ renderExitReason: RenderExitReason.ProcessCrashed });
  assert.equal(f.channel.invoked.length, 2);
});

test('a destroyed WebView says nothing more, and its Web component comes down', async () => {
  const f = fixture();
  const view = f.webView(7);
  await attach(f, 7);
  let disposed = 0;
  view.setOnDisposeCallback(() => disposed++);
  assert.deepEqual(await f.call('destroy', { id: 7 }), { value: null });
  assert.equal(disposed, 1);
  assert.deepEqual(view.getController().calls, ['stopAllMedia']);
  view.onRenderExited({ renderExitReason: RenderExitReason.ProcessCrashed });
  assert.deepEqual(f.channel.invoked, []);
});

test('destroy with no Web component bound is still an answer, as runCatching on Android', async () => {
  const f = fixture();
  const view = f.webView(7);
  await attach(f, 7);
  view.getController().bound = false;
  assert.deepEqual(await f.call('destroy', { id: 7 }), { value: null });
  assert.deepEqual(await f.call('destroy', { id: 99 }), { value: null });
  view.onRenderExited({ renderExitReason: RenderExitReason.ProcessCrashed });
  assert.deepEqual(f.channel.invoked, []);
});

test('pause and resume are the public onInactive and onActive of that WebView', async () => {
  const f = fixture();
  const view = f.webView(7), other = f.webView(8);
  assert.ok(view.getController() instanceof ControllerDouble);
  assert.deepEqual(await f.call('pause', { id: 7 }), { value: null });
  assert.deepEqual(await f.call('resume', { id: 7 }), { value: null });
  assert.deepEqual(view.getController().calls, ['onInactive', 'onActive']);
  assert.deepEqual(other.getController().calls, []);
});

test('pause before the Web component exists is no answer lost', async () => {
  const f = fixture();
  f.webView(7).getController().bound = false;
  assert.deepEqual(await f.call('pause', { id: 7 }), { value: null });
  assert.deepEqual(await f.call('resume', { id: 7 }), { value: null });
  assert.deepEqual(await f.call('pause', { id: 99 }), { value: null });
});

test('device answers in the units ActivityManager.MemoryInfo does', async () => {
  const f = fixture();
  assert.deepEqual(await f.call('device'),
    { value: { totalMem: 12 * 1024 ** 3, availMem: 5 * 1024 ** 3, lowRam: false } });
  const low = fixture({ memory: { lowRam: async () => true } });
  assert.equal((await low.call('device')).value.lowRam, true);
});

test('what the system will not say stays absent, so the budget stays on its smallest tier', async () => {
  const unable = fixture({ memory: { capable: false } });
  assert.deepEqual(await unable.call('device'), { value: { lowRam: false } });
  const failing = fixture({ memory: { info() { throw new Error('hidebug'); } } });
  assert.deepEqual(await failing.call('device'), { value: { lowRam: false } });
  let reads = 0;
  const flaky = fixture({ memory: { info() {
    if (reads++) throw new Error('hidebug');
    return { totalMem: 12n * BigInt(GIB), availableMem: 5n * BigInt(GIB) };
  } } });
  assert.deepEqual(await flaky.call('device'), { value: { totalMem: 12 * 1024 ** 3, lowRam: false } });
  const noRam = fixture({ memory: { lowRam: () => Promise.reject(new Error('16000050')) } });
  assert.deepEqual(await noRam.call('device'), { value: { totalMem: 12 * 1024 ** 3, availMem: 5 * 1024 ** 3 } });
});

test('appPss is kB, as Debug.getPss; a failure is an error Dart reads as null', async () => {
  const f = fixture();
  assert.deepEqual(await f.call('appPss'), { value: 123456 });
  const failing = fixture({ memory: { pss: () => Promise.reject(new Error('hidebug')) } });
  assert.deepEqual(await failing.call('appPss'), { error: 'ohos_islands_memory' });
  const throwing = fixture({ memory: { pss() { throw new Error('hidebug'); } } });
  assert.deepEqual(await throwing.call('appPss'), { error: 'ohos_islands_memory' });
});

test('memory pressure reaches Dart in the levels the budget reads, only where Android forwards', () => {
  const f = fixture();
  const watcher = [...f.watchers.values()][0];
  watcher.onConfigurationUpdated({});
  for (const level of Object.values(MemoryLevel)) watcher.onMemoryLevel(level);
  assert.deepEqual(f.channel.invoked, [
    ['trimMemory', { level: 10 }], ['trimMemory', { level: 15 }],
    ['trimMemory', { level: 40 }], ['trimMemory', { level: 60 }], ['trimMemory', { level: 80 }],
  ]);
});

test('leaving the engine stops listening and stops reporting', async () => {
  const f = fixture();
  const view = f.webView(7);
  await attach(f, 7);
  const watcher = [...f.watchers.values()][0];
  f.plugin.onDetachedFromEngine(f.binding);
  assert.equal(f.channel.handler, null);
  assert.equal(f.watchers.size, 0);
  watcher.onMemoryLevel(MemoryLevel.MEMORY_LEVEL_CRITICAL);
  view.onRenderExited({ renderExitReason: RenderExitReason.ProcessCrashed });
  assert.deepEqual(f.channel.invoked, []);
});
