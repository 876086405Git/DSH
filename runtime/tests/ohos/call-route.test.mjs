import test from 'node:test';
import assert from 'node:assert/strict';
import { routeFixture, deferred, settle, until } from './call-route-fixture.mjs';

test('app session activation completes before the first recording stream starts', async () => {
  const gate = deferred(), f = routeFixture({ activate: () => gate.promise });
  const starting = f.speech('callStart');
  try {
    await until(() => f.trace.some(row => row.method === 'session.activate'));
    assert.equal(f.capturers.length, 0, 'recording must not start before the documented session activation boundary');
    gate.resolve(); assert.equal((await starting).value, 'ok');
    const accepted = f.trace.findIndex(row => row.method === 'session.setDefaultOutputDevice' && row.phase === 'accepted');
    const recording = f.trace.findIndex(row => row.method === 'capturer.start');
    assert(accepted >= 0 && recording > accepted);
  } finally { gate.resolve(); await starting; await f.close(); }
});

const speak = f => f.tts('speak', { id: 'reply', text: '通话回复', rate: 1, pitch: 1, call: true });
const start = async f => assert.deepEqual(await f.speech('callStart'), { value: 'ok' });
const ready = async f => assert.deepEqual(await f.tts('ready', { language: 'zh-CN' }), { value: true });
const accepted = f => f.trace.filter(x => x.method === 'session.setDefaultOutputDevice' && x.phase === 'accepted');

test('future PCM preference still reaches the actual renderer, before and during a call', async () => {
  const f = routeFixture();
  try {
    assert.deepEqual(await f.speech('callSpeaker', { on: false }), { value: false });
    assert.equal(f.trace.length, 0);
    await start(f);
    assert.deepEqual(await f.speech('open', { id: 'pcm', rate: 24000, call: true }), { value: true });
    assert.deepEqual(f.renderers[0].devices, [1]);
  } finally { await f.close(); }
  assert.equal(f.session.device, 1000); assert.equal(f.session.active, false);
});

test('active system TTS speaker changes request the SDK default before returning success', async () => {
  const f = routeFixture();
  try {
    await start(f); await ready(f); assert.deepEqual(await speak(f), { value: true }); f.engines[0].start();
    await f.speech('callPlaying', { on: true });
    assert.deepEqual(await f.speech('callSpeaker', { on: false }), { value: false });
    assert.equal(accepted(f).at(-1)?.device, 1, 'SYSTEM_TTS_SPEAKER_PREFERENCE_UNAPPLIED');
    assert.equal(f.engines[0].calls[0].params.extraParams.soundChannel, 2);
    assert.equal(f.renderers.length, 0);
  } finally { await f.close(); }
});

test('speaker preference before the next system TTS reply has an active session consumer', async () => {
  const f = routeFixture();
  try {
    await start(f); assert.deepEqual(await f.speech('callSpeaker', { on: false }), { value: false });
    await ready(f); assert.deepEqual(await speak(f), { value: true });
    assert.equal(f.session.device, 1, 'FUTURE_SYSTEM_TTS_SPEAKER_PREFERENCE_UNAPPLIED'); assert.equal(f.session.active, true);
    const routeIndex = f.trace.findLastIndex(x => x.method === 'session.setDefaultOutputDevice' && x.device === 1 && x.phase === 'accepted');
    assert(routeIndex >= 0 && routeIndex < f.trace.findIndex(x => x.method === 'tts.speak'));
  } finally { await f.close(); }
});

test('an existing foreign app session is never modified or deactivated by a failed call', async () => {
  const f = routeFixture({ initialActive: true, initialDevice: 1 });
  assert.deepEqual(await f.speech('callStart'), { value: 'unavailable' });
  await f.close(); assert.equal(f.session.active, true); assert.equal(f.session.device, 1);
  assert.equal(f.trace.filter(x => x.method.startsWith('session.')).length, 0);
});

test('session activation rejection or inactive resolution cannot produce callStart ok', async () => {
  for (const options of [{ activate() { throw Error('denied'); } }, { resolveInactive: true }]) {
    const f = routeFixture(options);
    assert.deepEqual(await f.speech('callStart'), { value: 'unavailable' });
    assert.equal(accepted(f).length, 0); await f.close(); assert.equal(f.session.active, false);
  }
});

test('SDK route rejection is speech-output and does not claim the requested preference', async () => {
  const f = routeFixture();
  try {
    await start(f); await ready(f); assert.deepEqual(await speak(f), { value: true });
    f.change({ route(device) { if (device === 1) throw Error('route denied'); } });
    assert.equal((await f.speech('callSpeaker', { on: false })).error, 'speech-output');
    assert.equal(f.session.device, 2);
    assert.deepEqual(await f.speech('open', { id: 'pcm', call: true }), { value: true });
    assert.deepEqual(f.renderers[0].devices, [2]);
  } finally { await f.close(); }
});

test('stop while activation is pending never starts capture or sets a late route', async () => {
  const wait = deferred(), f = routeFixture({ activate: () => wait.promise });
  const starting = f.speech('callStart'); await until(() => f.trace.some(x => x.method === 'session.activate'));
  const stopping = f.speech('callStop'); await settle(); assert.equal(f.capturers.length, 0);
  wait.resolve(); assert.deepEqual(await starting, { value: 'unavailable' }); await stopping;
  assert.equal(accepted(f).length, 0); assert.equal(f.session.active, false); await f.close();
});

test('late old route must finish and restore before the next call can activate', async () => {
  const wait = deferred(), f = routeFixture(); await start(f);
  f.change({ route: device => device === 1 ? wait.promise : undefined });
  const old = f.speech('callSpeaker', { on: false }); await settle();
  const stopping = f.speech('callStop'); const next = f.speech('callStart'); await settle();
  assert.equal(f.capturers.length, 1); assert.equal(f.capturers[0].releases, 1);
  wait.resolve(); assert.equal((await old).error, 'speech-output'); await stopping;
  assert.deepEqual(await next, { value: 'ok' }); assert.equal(f.session.device, 2);
  const devices = accepted(f).map(x => x.device); assert.deepEqual(devices, [2, 1, 1000, 2]);
  await f.close();
});

test('concurrent routes are serialized and an old reply cannot overwrite the newer accepted preference', async () => {
  const wait = deferred(), f = routeFixture(); await start(f);
  f.change({ route: device => device === 1 ? wait.promise : undefined });
  const old = f.speech('callSpeaker', { on: false }); await settle();
  const next = f.speech('callSpeaker', { on: true }); await settle();
  assert.equal(accepted(f).length, 1); wait.resolve();
  assert.equal((await old).error, 'speech-output'); assert.deepEqual(await next, { value: true });
  assert.equal(f.session.device, 2); await f.close();
});

test('failed default restoration blocks replacement until the existing call cleanup is retried', async () => {
  const f = routeFixture(); await start(f);
  f.change({ route: device => { if (device === 1000) throw Error('restore'); } });
  assert.equal((await f.speech('callStop')).error, 'speech-output');
  assert.equal((await f.speech('callStart')).value, 'microphone'); assert.equal(f.capturers.length, 1);
  f.change({ route: undefined }); await start(f); assert.equal(f.capturers.length, 2); await f.close();
});

test('failed session deactivation keeps a debt and retry restores the same owner before a new call', async () => {
  const f = routeFixture(); await start(f);
  f.change({ deactivate() { throw Error('deactivate'); } });
  assert.equal((await f.speech('callStop')).error, 'speech-output'); assert.equal(f.session.active, true);
  assert.equal((await f.speech('callStart')).value, 'microphone'); assert.equal(f.capturers.length, 1);
  f.change({ deactivate: undefined }); await start(f); await f.close(); assert.equal(f.session.active, false);
});

test('passive session loss ends this capture and a late old callback cannot affect a new call', async () => {
  const f = routeFixture(); await start(f); const old = f.session.history[0];
  f.session.lose(); await until(() => f.capturers[0].releases === 1);
  assert(f.events.some(x => x.type === 'callError' && x.reason === 'audio-session'));
  await f.speech('callStop'); assert.equal(f.session.device, 1000, 'passive loss must restore its persisted default');
  await start(f); const before = f.trace.length; old({ reason: 0 }); await settle();
  assert.equal(f.trace.length, before); assert.equal(f.capturers[1].releases, 0); await f.close();
});

test('route completion checks SDK activation even if the deactivation notification is delayed', async () => {
  const f = routeFixture(); await start(f);
  f.change({ route(device) { if (device === 1) f.session.active = false; } });
  assert.equal((await f.speech('callSpeaker', { on: false })).error, 'speech-output');
  await until(() => f.capturers[0].releases === 1); await f.speech('callStop');
  assert.equal(f.session.device, 1000); await f.close();
});

test('a pending set after passive loss is awaited before the original default is restored', async () => {
  const wait = deferred(), f = routeFixture(); await start(f);
  f.change({ route: device => device === 1 ? wait.promise : undefined });
  const pending = f.speech('callSpeaker', { on: false }); await settle();
  f.session.lose(); await until(() => f.capturers[0].releases === 1);
  wait.resolve(); assert.equal((await pending).error, 'speech-output'); await f.speech('callStop');
  assert.equal(f.session.device, 1000); assert.equal(f.session.active, false); await f.close();
});

test('conditional SDK ownership boundary: a reactivated foreign session is not restored or stopped', async () => {
  const f = routeFixture(); await start(f); const before = f.trace.length;
  f.session.lose(); f.session.active = true; f.session.device = 1;
  await until(() => f.capturers[0].releases === 1);
  assert.equal((await f.speech('callStop')).error, 'speech-output');
  assert.equal(f.session.active, true); assert.equal(f.session.device, 1);
  assert.equal(f.trace.slice(before).filter(x => x.method.startsWith('session.')).length, 0);
  // Current product has no second session client: this is a boundary guard,
  // not a claimed user-reachable audio focus reproduction.
  f.session.active = false; await f.speech('callStop'); assert.equal(f.session.device, 1000); await f.close();
});

test('only this callback is removed and its failed off retains bounded cleanup debt', async () => {
  const f = routeFixture(); const foreign = () => {}; f.session.callbacks.add(foreign); await start(f);
  f.change({ offError: true }); assert.equal((await f.speech('callStop')).error, 'speech-output');
  f.change({ offError: false }); await f.speech('callStop');
  assert.deepEqual([...f.session.callbacks], [foreign]); await f.close();
});

test('call stop restores the original default; ordinary system TTS does not activate a session', async () => {
  const f = routeFixture({ initialDevice: 1 }); await start(f); await f.speech('callStop');
  assert.equal(f.session.device, 1); assert.equal(f.session.active, false);
  const before = f.trace.length; await ready(f);
  assert.deepEqual(await f.tts('speak', { id: 'ordinary', text: '朗读', rate: 1, pitch: 1 }), { value: true });
  assert.equal(f.engines[0].calls[0].params.extraParams.soundChannel, 3);
  assert.equal(f.trace.slice(before).filter(x => x.method.startsWith('session.')).length, 0); await f.close();
});
