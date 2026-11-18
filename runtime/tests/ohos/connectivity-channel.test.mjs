// Runs the actual ArkTS channel body after TypeScript erasure with controlled
// OS/Flutter boundaries. This is not an ArkTS compiler or a device test.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const prefix = process.env.OHOS_TYPESCRIPT_PREFIX;
assert(prefix, 'Set OHOS_TYPESCRIPT_PREFIX to the fixed runtime/ohos/process npm-ci directory');
const ts = createRequire(resolve(prefix, 'package.json'))('typescript');
const source = readFileSync(new URL('../../../app/ohos/entry/src/main/ets/plugins/ConnectivityPlugin.ets', import.meta.url), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
} });
const turn = () => new Promise(resolve => setImmediate(resolve));
const plain = value => JSON.parse(JSON.stringify(value));

function fixture({ createError = false, unregisterError = false } = {}) {
  const channels = [], observers = [], events = [], errors = [], requests = [];
  let current = { netId: 1 }, bearers = [1];
  const sdk = {
    NetBearType: { BEARER_CELLULAR: 0, BEARER_WIFI: 1, BEARER_BLUETOOTH: 2, BEARER_ETHERNET: 3, BEARER_VPN: 4 },
    getDefaultNet: () => Promise.resolve(current),
    getNetCapabilities: () => {
      const result = requests.shift();
      return result ?? Promise.resolve({ bearerTypes: bearers });
    },
    createNetConnection: () => {
      if (createError) throw new Error('service unavailable');
      const callbacks = new Map();
      const observer = {
        unregisterCount: 0,
        on(name, callback) { callbacks.set(name, callback); },
        register(callback) { this.registered = callback; },
        unregister(callback) {
          this.unregisterCount++;
          if (unregisterError) throw new Error('service unavailable');
          callback();
        },
        emit(name) { callbacks.get(name)?.(); },
      };
      observers.push(observer);
      return observer;
    },
  };
  class Channel {
    constructor(_messenger, name) { this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    setStreamHandler(handler) { this.handler = handler; }
  }
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, {
    exports: module.exports, module,
    require(name) {
      if (name === '@ohos.net.connection') return { default: sdk };
      if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel, EventChannel: Channel };
      if (name === '@ohos.hilog') return { default: { warn() {} } };
      throw new Error(`Unexpected import ${name}`);
    },
  });
  const plugin = new module.exports.default();
  const messenger = { setMessageHandler(name, handler) {
    assert.equal(name, 'dev.fluttercommunity.plus/connectivity_status');
    channels.find(channel => channel.name === name).handler = handler;
  } };
  const binding = { getBinaryMessenger: () => messenger };
  plugin.onAttachedToEngine(binding);
  const sink = { success: value => events.push(plain(value)), error: (...values) => errors.push(values) };
  return {
    plugin, channels, observers, events, errors, requests, sink, binding,
    state(net, types) { current = { netId: net }; bearers = types; },
    check(method = 'check') {
      return new Promise(resolve => plugin.onMethodCall({ method }, {
        success: value => resolve({ value: plain(value) }),
        error: code => resolve({ error: code }), notImplemented: () => resolve({ missing: true }),
      }));
    },
  };
}

test('matches the locked connectivity_plus method and event channel, including a list result', async () => {
  const f = fixture();
  assert.deepEqual(f.channels.map(c => c.name), [
    'dev.fluttercommunity.plus/connectivity', 'dev.fluttercommunity.plus/connectivity_status',
  ]);
  assert.deepEqual(await f.check(), { value: ['wifi'] });
  f.state(4, [0, 1, 4, 1, 2, 3, 99]);
  assert.deepEqual(await f.check(), { value: ['bluetooth', 'ethernet', 'mobile', 'other', 'vpn', 'wifi'] });
  f.state(0, []);
  assert.deepEqual(await f.check(), { value: ['none'] });
  assert.deepEqual(await f.check('unknown'), { missing: true });
});

test('query service failure is an error, not a fabricated disconnected network', async () => {
  const f = fixture();
  f.requests.push(Promise.reject(new Error('service unavailable')));
  assert.deepEqual(await f.check(), { error: 'ohos_network_query' });
});

test('initial state and changed state are emitted once, and cancellation unregisters', async () => {
  const f = fixture();
  f.plugin.onListen(null, f.sink);
  assert.equal(f.events.length, 0);
  f.observers[0].registered();
  await turn();
  f.observers[0].emit('netCapabilitiesChange');
  await turn();
  assert.deepEqual(f.events, [['wifi']]);
  f.state(0, []);
  f.observers[0].emit('netLost');
  await turn();
  assert.deepEqual(f.events, [['wifi'], ['none']]);
  f.plugin.onCancel(null);
  f.plugin.onCancel(null);
  assert.equal(f.observers[0].unregisterCount, 1);
});

test('late subscription completion after cancel unregisters without publishing stale data', async () => {
  const f = fixture();
  f.plugin.onListen(null, f.sink);
  f.plugin.onCancel(null);
  f.observers[0].registered();
  await turn();
  assert.equal(f.observers[0].unregisterCount, 1);
  assert.deepEqual(f.events, []);
});

test('out-of-order network queries and events from a detached subscription cannot overwrite new state', async () => {
  const f = fixture();
  const old = Promise.withResolvers();
  f.requests.push(old.promise);
  f.plugin.onListen(null, f.sink);
  f.observers[0].registered();
  await turn();
  f.state(2, [0]);
  f.observers[0].emit('netAvailable');
  await turn();
  old.resolve({ bearerTypes: [1] });
  await turn();
  assert.deepEqual(f.events, [['mobile']]);
  f.plugin.onDetachedFromEngine(f.binding);
  f.observers[0].emit('netAvailable');
  await turn();
  assert.deepEqual(f.events, [['mobile']]);
  assert(f.channels.every(c => c.handler === null));
});

test('synchronous OS registration failure returns a stable channel error', () => {
  const f = fixture({ createError: true });
  assert.doesNotThrow(() => f.plugin.onListen(null, f.sink));
  assert.equal(f.errors[0]?.[0], 'ohos_network_watch');
});

test('a retired observer event cannot invalidate the initial query of a new subscription', async () => {
  const f = fixture();
  f.plugin.onListen(null, f.sink);
  f.observers[0].registered();
  await turn();
  const current = Promise.withResolvers();
  f.requests.push(current.promise);
  f.plugin.onListen(null, f.sink);
  f.observers[1].registered();
  await turn();
  f.observers[0].emit('netLost');
  current.resolve({ bearerTypes: [0] });
  await turn();
  assert.deepEqual(f.events, [['wifi'], ['mobile']]);
});

test('synchronous OS unregister failure cannot leave Flutter handlers attached', () => {
  const f = fixture({ unregisterError: true });
  f.plugin.onListen(null, f.sink);
  f.observers[0].registered();
  assert.doesNotThrow(() => f.plugin.onDetachedFromEngine(f.binding));
  assert(f.channels.every(c => c.handler === null));
});
