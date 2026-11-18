// Actual product ETS after TypeScript erasure; timers, thermal, the engine and Flutter are test doubles.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const prefix = process.env.OHOS_TYPESCRIPT_PREFIX;
assert(prefix, 'Set OHOS_TYPESCRIPT_PREFIX to the locked process npm-ci directory');
const ts = createRequire(resolve(prefix, 'package.json'))('typescript');
const compile = file => ts.transpileModule(
  readFileSync(new URL(`../../../app/ohos/entry/src/main/ets/plugins/${file}.ets`, import.meta.url), 'utf8'),
  { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } },
).outputText;
const sources = { AppLinksPlugin: compile('AppLinksPlugin'), OhosFrameRate: compile('OhosFrameRate') };

function fixture({ lightweight = false } = {}) {
  const timers = new Map(), periods = [], logs = [], observers = new Set();
  const napi = { attached: true, calls: 0, throws: false,
    isAttached() { return this.attached; },
    LTPODispatchHighFrameRate() { if (this.throws) throw new Error('native gone'); this.calls++; },
  };
  let nextTimer = 0, cool = !lightweight;
  const thermal = {
    subscribe: observer => observers.add(observer),
    unsubscribe: observer => observers.delete(observer),
    snapshot: () => new Map([['lightweight', !cool]]),
  };
  const context = {
    setInterval(callback, period) { periods.push(period); timers.set(++nextTimer, callback); return nextTimer; },
    clearInterval(id) { assert(timers.delete(id), 'cleared a timer that was not running'); },
  };
  const modules = new Map();
  const load = name => {
    if (!modules.has(name)) {
      const module = { exports: {} };
      modules.set(name, module);
      vm.runInNewContext(sources[name], { ...context, module, exports: module.exports, require }, { filename: name });
    }
    return modules.get(name).exports;
  };
  function require(name) {
    if (name === './OhosFrameRate') return load('OhosFrameRate');
    if (name === './OhosThermalState') return { ohosThermal: thermal };
    if (name === '@ohos.hilog') return { default: { info: (...args) => logs.push(args) } };
    if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel };
    return { default: {} };
  }
  const channels = [];
  class Channel {
    constructor(_messenger, name) { this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod() {}
  }
  const Plugin = load('AppLinksPlugin').default;
  const engine = {
    getBinaryMessenger: () => ({}),
    getFlutterEngine: () => ({ getFlutterNapi: () => napi }),
  };
  const ability = { launchWant: {}, context: {} };
  const binding = { getAbility: () => ability, addOnNewWantListener() {}, removeOnNewWantListener() {} };
  const attach = () => {
    const plugin = new Plugin();
    plugin.onAttachedToEngine(engine);
    plugin.onAttachedToAbility(binding);
    return plugin;
  };
  const plugin = attach();
  const call = (method, args = {}, target = channels.filter(c => c.name === 'dsh/app').at(-1)) =>
    new Promise(done => target.handler.onMethodCall({ method, argument: name => args[name] }, {
      success: value => done({ value }),
      error: (code, message) => done({ error: code, message }),
      notImplemented: () => done({ missing: true }),
    }));
  const tick = (count = 1) => {
    for (let i = 0; i < count; i++) for (const callback of [...timers.values()]) callback();
  };
  return { Plugin, plugin, attach, engine, ability, binding, napi, timers, periods, logs, observers, channels, call, tick,
    foreground: () => Plugin.onForeground(ability),
    background: () => Plugin.onBackground(ability),
    setLightweight(value) { cool = !value; for (const observer of [...observers]) observer(); },
  };
}

/** Attached, on screen, auto and no motion yet: where the app sits after launch. */
async function ready(options) {
  const f = fixture(options);
  f.foreground();
  assert.deepEqual(await f.call('setRefreshRateMode', { mode: 'auto' }), { value: null });
  return f;
}

/** The timer is off and stays off: nothing more reaches the engine. */
function assertStopped(f) {
  assert.equal(f.timers.size, 0, 'a timer is still running');
  const before = f.napi.calls;
  f.tick(5);
  assert.equal(f.napi.calls, before);
}

/** Exactly one timer is on and every tick reaches the engine. */
function assertRunning(f) {
  assert.equal(f.timers.size, 1);
  const before = f.napi.calls;
  f.tick(3);
  assert.equal(f.napi.calls, before + 3);
}

test('a tick comes well inside the engine\'s 100 ms hold', async () => {
  const f = await ready();
  await f.call('setFrameActive', { active: true });
  assert.deepEqual(f.periods, [80]);
});

test('auto: asks at once when active and on every tick, stops when inactive', async () => {
  const f = await ready();
  assert.equal(f.napi.calls, 0);
  assertStopped(f);
  assert.deepEqual(await f.call('setFrameActive', { active: true }), { value: null });
  assert.equal(f.napi.calls, 1, 'the first ask does not wait for a tick');
  assertRunning(f);
  assert.deepEqual(await f.call('setFrameActive', { active: false }), { value: null });
  assertStopped(f);
});

test('active twice is one timer', async () => {
  const f = await ready();
  await f.call('setFrameActive', { active: true });
  await f.call('setFrameActive', { active: true });
  await f.call('setFrameActive', { active: true });
  assert.equal(f.periods.length, 1);
  assertRunning(f);
});

test('max runs without active; system never runs; a mode change ends active', async () => {
  const f = await ready();
  await f.call('setRefreshRateMode', { mode: 'max' });
  assertRunning(f);
  await f.call('setRefreshRateMode', { mode: 'system' });
  assertStopped(f);
  await f.call('setFrameActive', { active: true });
  assertStopped(f);
  await f.call('setRefreshRateMode', { mode: 'auto' });
  assertStopped(f);
  await f.call('setFrameActive', { active: true });
  assertRunning(f);
  await f.call('setRefreshRateMode', { mode: 'max' });
  assertRunning(f);
  await f.call('setRefreshRateMode', { mode: 'auto' });
  assertStopped(f);
});

test('an unknown mode is an error and changes nothing; a malformed active is ignored', async () => {
  const f = await ready();
  await f.call('setFrameActive', { active: true });
  for (const mode of ['fast', undefined]) {
    assert.equal((await f.call('setRefreshRateMode', { mode })).error, 'ohos_unsupported');
  }
  assertRunning(f);
  assert.deepEqual(await f.call('setFrameActive', {}), { value: null });
  assertRunning(f);
});

test('background stops both modes; foreground brings back max but not an old active', async () => {
  const auto = await ready();
  await auto.call('setFrameActive', { active: true });
  auto.background();
  assertStopped(auto);
  auto.foreground();
  assertStopped(auto);
  await auto.call('setFrameActive', { active: true });
  assertRunning(auto);

  const max = await ready();
  await max.call('setRefreshRateMode', { mode: 'max' });
  max.background();
  assertStopped(max);
  max.foreground();
  assertRunning(max);
});

test('active in the background waits for the screen and forgets itself', async () => {
  const f = await ready();
  f.background();
  await f.call('setFrameActive', { active: true });
  assertStopped(f);
  f.background();
  f.foreground();
  assertStopped(f);
});

test('nothing runs before the ability is on screen', async () => {
  const f = fixture();
  await f.call('setRefreshRateMode', { mode: 'max' });
  assertStopped(f);
  f.foreground();
  assertRunning(f);
});

test('losing the ability stops it; getting it back on screen resumes max', async () => {
  const f = await ready();
  await f.call('setRefreshRateMode', { mode: 'max' });
  f.plugin.onDetachedFromAbility();
  assertStopped(f);
  f.plugin.onAttachedToAbility(f.binding);
  assertRunning(f);
});

test('engine detach stops it, lets go of thermal, and nothing can start it again', async () => {
  const f = await ready();
  const handler = f.channels.find(c => c.name === 'dsh/app');
  await f.call('setRefreshRateMode', { mode: 'max' });
  assert.equal(f.observers.size, 1);
  f.plugin.onDetachedFromEngine(f.engine);
  assertStopped(f);
  assert.equal(f.observers.size, 0);
  assert.equal(handler.handler, null);
  assert.equal(f.Plugin.attached.size, 0);
  f.foreground();
  f.background();
  f.foreground();
  assertStopped(f);
});

test('a second engine attach on the same plugin retires the first timer', async () => {
  const f = await ready();
  await f.call('setRefreshRateMode', { mode: 'max' });
  f.plugin.onAttachedToEngine(f.engine);
  assertStopped(f);
  assert.equal(f.observers.size, 1);
});

test('background reaches every attached plugin, not only the newest', async () => {
  const f = await ready();
  await f.call('setRefreshRateMode', { mode: 'max' });
  const first = f.channels.filter(c => c.name === 'dsh/app').at(-1);
  const second = f.attach();
  await f.call('setRefreshRateMode', { mode: 'max' });
  assert.equal(f.timers.size, 2);
  assert.notEqual(f.channels.filter(c => c.name === 'dsh/app').at(-1), first);
  f.background();
  assert.equal(f.timers.size, 0);
  second.onDetachedFromEngine(f.engine);
});

test('hot: lightweight stops it and cooling resumes what is still wanted', async () => {
  const f = await ready();
  await f.call('setRefreshRateMode', { mode: 'max' });
  f.setLightweight(true);
  assertStopped(f);
  f.setLightweight(false);
  assertRunning(f);
  await f.call('setRefreshRateMode', { mode: 'auto' });
  await f.call('setFrameActive', { active: true });
  f.setLightweight(true);
  assertStopped(f);
  f.setLightweight(false);
  assertRunning(f);
  await f.call('setFrameActive', { active: false });
  f.setLightweight(true);
  f.setLightweight(false);
  assertStopped(f);
});

test('hot at the start: it never starts until the device cools', async () => {
  const f = await ready({ lightweight: true });
  await f.call('setFrameActive', { active: true });
  assertStopped(f);
  await f.call('setRefreshRateMode', { mode: 'max' });
  assertStopped(f);
  assert.equal(f.napi.calls, 0);
  f.setLightweight(false);
  assertRunning(f);
});

test('an engine that has gone away stops the timer for good', async () => {
  const f = await ready();
  await f.call('setRefreshRateMode', { mode: 'max' });
  f.napi.attached = false;
  f.tick();
  assert.equal(f.timers.size, 0);
  f.napi.attached = true;
  f.background();
  f.foreground();
  await f.call('setRefreshRateMode', { mode: 'max' });
  assertStopped(f);
  assert.equal(f.observers.size, 0);
});

test('a throwing engine call stops the timer rather than reaching the main thread', async () => {
  const f = await ready();
  await f.call('setFrameActive', { active: true });
  f.napi.throws = true;
  f.tick();
  assert.equal(f.timers.size, 0);
  const g = await ready();
  g.napi.throws = true;
  await g.call('setRefreshRateMode', { mode: 'max' });
  assert.equal(g.timers.size, 0, 'the first ask fails the same way');
});

test('no renewal: auto gives up after 50 ticks; a renewal extends it; max has no such limit', async () => {
  const f = await ready();
  await f.call('setFrameActive', { active: true });
  f.tick(49);
  assert.equal(f.timers.size, 1);
  await f.call('setFrameActive', { active: true });
  f.tick(49);
  assert.equal(f.timers.size, 1);
  f.tick();
  assertStopped(f);
  await f.call('setFrameActive', { active: true });
  assertRunning(f);
  await f.call('setRefreshRateMode', { mode: 'max' });
  f.tick(500);
  assert.equal(f.timers.size, 1);
});

test('a late inactive after the lease ran out is harmless', async () => {
  const f = await ready();
  await f.call('setFrameActive', { active: true });
  f.tick(50);
  await f.call('setFrameActive', { active: false });
  assertStopped(f);
});

test('each start and stop leaves one public line, each tick none', async () => {
  const f = await ready();
  await f.call('setFrameActive', { active: true });
  f.tick(20);
  await f.call('setFrameActive', { active: false });
  assert.deepEqual(JSON.parse(JSON.stringify(f.logs)), [
    [0x3F00, 'DshFrameRate', '%{public}s: %{public}s', 'start', 'active'],
    [0x3F00, 'DshFrameRate', '%{public}s: %{public}s', 'stop', 'inactive'],
  ]);
});

test('the rest of dsh/app is untouched', async () => {
  const f = fixture();
  assert.deepEqual(await f.call('unknown'), { missing: true });
});
