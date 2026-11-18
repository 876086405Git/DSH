// Combined actual SpeechPlugin and actual OhosPcmStream/queue, with explicit
// Flutter/AudioRenderer/timer boundaries. No actual Dart or audible device run.
import test from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { pcmFixture, deferred, until } from './pcm-stream-fixture.mjs';

function combined(options = {}) {
  const native = pcmFixture(options), channels = [], events = [];
  class MethodChannel {
    constructor(messenger, name) { this.messenger = messenger; this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod(method, args) { events.push({ method, ...Object.fromEntries(args) }); }
  }
  const path = fileURLToPath(new URL('../../../app/ohos/entry/src/main/ets/plugins/SpeechPlugin.ets', import.meta.url));
  const Plugin = native.load(path, { '@ohos/flutter_ohos': { MethodChannel } }).default;
  function attach() {
    const plugin = new Plugin(), messenger = {}, ui = { context: {} };
    const engine = { getBinaryMessenger: () => messenger }, ability = { getAbility: () => ui };
    plugin.onAttachedToEngine(engine); plugin.onAttachedToAbility(ability); Plugin.onForeground(ui);
    return { plugin, engine, ability, methods: channels.at(-1), background: () => Plugin.onBackground(ui) };
  }
  function call(methods, method, args = {}) {
    const done = deferred();
    methods.handler.onMethodCall({ method, argument: name => args[name] }, {
      success: value => done.resolve({ value }),
      error: (error, message, details) => done.resolve({ error, message, details }),
      notImplemented: () => done.resolve({ missing: true }),
    });
    return done.promise;
  }
  return { ...native, ...attach(), attach, call, channels, protocolEvents: events };
}

test('call and level options reach real PCM; playLevel follows hardware progress and stream identity', async () => {
  const f = combined(), call = (method, args) => f.call(f.methods, method, args);
  try {
    assert.deepEqual(await call('open', { id: 'call-1', call: true, levels: true, rate: 24000 }), { value: true });
    const renderer = f.renderers[0];
    assert.equal(renderer.settings.rendererInfo.usage, 2);
    const bytes = new Uint8Array(1920), view = new DataView(bytes.buffer);
    for (let at = 0; at < 960; at++) view.setInt16(at * 2, 8192, true);
    assert.deepEqual(await call('write', { id: 'call-1', bytes }), { value: 1920 });
    renderer.pump(1920);
    await until(() => renderer.timestampReads > 0);
    assert.equal(f.protocolEvents.filter(event => event.type === 'playLevel').length, 0);
    renderer.framePos = 960;
    await until(() => f.protocolEvents.some(event => event.type === 'playLevel'));
    const event = f.protocolEvents.find(event => event.type === 'playLevel');
    assert.equal(event.method, 'event'); assert.equal(event.id, 'call-1');
    assert(Math.abs(event.value - ((20 * Math.log10(0.25) + 50) / 40)) < 1e-12);
    await call('stop');
    const count = f.protocolEvents.length;
    renderer.framePos = 1920;
    await new Promise(resolve => setTimeout(resolve, 85));
    assert.equal(f.protocolEvents.length, count); assert.equal(f.timers.size, 0);
  } finally { await call('stop'); }
});

test('real channel and real PCM backend preserve split samples and wait for drain/release before done', async () => {
  const f = combined(), call = (name, args) => f.call(f.methods, name, args);
  assert.deepEqual(await call('open', { id: 'ds1', rate: 24000 }), { value: true });
  assert.equal(f.renderers.length, 1); assert.equal(f.renderers[0].starts, 1);
  assert.equal(f.protocolEvents.length, 0);
  await call('write', { id: 'ds1', bytes: Uint8Array.from([0, 127, 128]) });
  await call('write', { id: 'ds1', bytes: Uint8Array.from([255, 1, 2]) });
  await call('end', { id: 'ds1' });
  const rendered = f.renderers[0].pump();
  assert.equal(rendered.result, f.audio.AudioDataCallbackResult.VALID);
  assert.deepEqual([...rendered.bytes], [0, 127, 128, 255, 1, 2, 0, 0]);
  assert.equal(f.renderers[0].drains, 0, 'last VALID callback alone cannot prove native submission');
  f.renderers[0].pump();
  await until(() => f.protocolEvents.some(event => event.what === 'done'));
  assert.equal(f.renderers[0].drains, 1); assert.equal(f.renderers[0].releases, 1);
  assert.deepEqual(f.protocolEvents.map(event => event.what), ['start', 'done']);
  assert.deepEqual(await call('waiting', { id: 'ds1' }), { value: -1 });
  await call('stop'); assert.equal(f.renderers[0].releases, 1);
  assert.equal(f.timers.size, 0);
});

test('real native preflight failures are false plus play:error; explicit design gate starts no synthesis', async () => {
  for (const options of [
    { supported: false }, { createNull: true }, { format: { samplingRate: 48000 } },
    { afterFormat: { channels: 2 } }, { start: () => { throw Error('start failed'); } },
    { start: renderer => { renderer.interrupt(2, 0); } },
  ]) {
    const f = combined(options);
    const reply = await f.call(f.methods, 'open', { id: 'ds1', rate: 24000 });
    let synthesisEntries = 0; // Design gate only, not the unchanged pinned Dart.
    if (reply.value === true) synthesisEntries++;
    assert.deepEqual(reply, { value: false }); assert.equal(synthesisEntries, 0);
    assert.deepEqual(f.protocolEvents.map(event => event.what), ['error']);
    assert(f.renderers.every(renderer => renderer.released));
    await f.call(f.methods, 'stop'); assert.equal(f.timers.size, 0);
  }
});

test('real pending create is retired by stop and never begins renderer playback', async () => {
  const gate = deferred(), f = combined({ create: () => gate.promise });
  const opening = f.call(f.methods, 'open', { id: 'ds1' });
  await until(() => f.calls.includes('create'));
  const stopping = f.call(f.methods, 'stop'); gate.resolve();
  assert.deepEqual(await opening, { value: false }); assert.deepEqual(await stopping, { value: null });
  assert.equal(f.renderers[0].starts, 0); assert.equal(f.renderers[0].releases, 1);
  assert.deepEqual(f.protocolEvents.map(event => event.what), ['stopped']); assert.equal(f.timers.size, 0);
});

test('real queue overflow and malformed EOF produce protocol errors rather than silent -1', async () => {
  for (const bytes of [new Uint8Array(2 * 1024 * 1024 + 1), Uint8Array.from([1])]) {
    const f = combined(); await f.call(f.methods, 'open', { id: 'ds1' });
    await f.call(f.methods, 'write', { id: 'ds1', bytes });
    await f.call(f.methods, 'end', { id: 'ds1' });
    await until(() => f.protocolEvents.some(event => event.what === 'error'));
    assert.deepEqual(f.protocolEvents.map(event => event.what), ['error']);
    assert.equal(f.renderers[0].releases, 1); assert.equal(f.timers.size, 0);
  }
});

test('real focus loss terminates current stream and late resume cannot recreate it', async () => {
  const f = combined(); await f.call(f.methods, 'open', { id: 'ds1' });
  const renderer = f.renderers[0]; renderer.interrupt(2, 0);
  await until(() => f.protocolEvents.some(event => event.what === 'stopped'));
  assert.equal(renderer.releases, 1);
  renderer.interrupt(1, 1, { late: true });
  assert.equal(renderer.starts, 1); assert.equal(f.renderers.length, 1);
  assert.deepEqual(await f.call(f.methods, 'write', { id: 'ds1', bytes: new Uint8Array(8) }), { value: -1 });
  assert.deepEqual(f.protocolEvents.map(event => event.what), ['stopped']); assert.equal(f.timers.size, 0);
});
