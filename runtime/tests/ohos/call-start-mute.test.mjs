import test from 'node:test';
import assert from 'node:assert/strict';
import { captureFixture, deferred, pcm, settle } from './call-capture-fixture.mjs';

function rig(t, options = {}) {
  const f = captureFixture(options), speech = f.speech(), frames = [], resets = [];
  const { VoicePcmTap } = f.load('VoicePcmTap');
  const tap = VoicePcmTap.enable('call', 1320, (owner, bytes) => frames.push(bytes.slice()),
    (owner, reason) => resets.push({ session: owner.id, reason }));
  t.after(async () => { await speech.request('callStop'); VoicePcmTap.clear(tap); });
  return { f, speech, frames, resets };
}

async function audio(r, expectedMuted) {
  const before = r.frames.length, eventStart = r.f.events.length;
  const capturer = r.f.capturers.at(-1);
  for (let index = 0; index < 8; index++) { capturer.data(pcm(12000)); await settle(); }
  for (let index = 0; index < 40; index++) { capturer.data(pcm(0)); await settle(); }
  const events = r.f.events.slice(eventStart);
  assert.equal(r.frames.length - before, expectedMuted ? 0 : 48, 'application PCM admission follows current mute');
  assert.equal(events.filter(event => event.type === 'speechStart').length, expectedMuted ? 0 : 1);
  assert.equal(events.filter(event => event.type === 'utterance').length, expectedMuted ? 0 : 1);
  assert.equal(events.some(event => event.type === 'micLevel' && event.value > 0), !expectedMuted);
  assert.equal(capturer.stops, 0, 'application mute does not claim physical capturer shutdown');
}

test('callStart initial mute is applied before SDK early readData and the first application PCM', async t => {
  const r = rig(t, { start(capturer) { capturer.data(pcm(12000)); } });
  assert.deepEqual(await r.speech.request('callStart', { muted: true, pause: 'quick' }), { value: 'ok' });
  await settle(); assert.equal(r.frames.length, 0, 'early readData must be suppressed too');
  await audio(r, true);
});

for (const [initial, changes, expected] of [
  [false, [true], true], [true, [false], false], [false, [true, false, true], true]
]) {
  test(`permission pending: mute ${initial} -> ${changes.join(' -> ')} keeps the latest choice`, async t => {
    const pending = deferred(), entered = deferred();
    const r = rig(t, { permission() { entered.resolve(); return pending.promise; } });
    const start = r.speech.request('callStart', { muted: initial, pause: 'quick' });
    await entered.promise; assert.equal(r.f.capturers.length, 0);
    for (const on of changes) assert.deepEqual(await r.speech.request('callMute', { on }), { value: null });
    pending.resolve(); assert.deepEqual(await start, { value: 'ok' });
    await audio(r, expected);
  });
}

test('mute during awaited old call playback release reaches the next call before capture', async t => {
  const pending = deferred(), options = {}, r = rig(t, options);
  assert.deepEqual(await r.speech.request('callStart', { pause: 'quick' }), { value: 'ok' });
  assert.deepEqual(await r.speech.request('open', { id: 'old', rate: 24000, call: true }), { value: true });
  options.pcmStop = () => pending.promise;
  const start = r.speech.request('callStart', { muted: false, pause: 'quick' });
  await settle(); assert.equal(r.f.capturers.length, 1);
  assert.deepEqual(await r.speech.request('callMute', { on: true }), { value: null });
  pending.resolve(); assert.deepEqual(await start, { value: 'ok' });
  assert.equal(r.f.capturers[0].releases, 1); assert.equal(r.f.capturers.length, 2);
  await audio(r, true);
});

test('a failed muted start does not make the following legacy/default call muted', async t => {
  const options = { granted: false }, r = rig(t, options);
  assert.deepEqual(await r.speech.request('callStart', { muted: true }), { value: 'permission' });
  options.granted = true;
  assert.deepEqual(await r.speech.request('callStart', { pause: 'quick' }), { value: 'ok' });
  await audio(r, false);
});

test('stop retires a muted permission wait and the following default call has fresh state', async t => {
  const pending = deferred(); let checks = 0;
  const r = rig(t, { permission: () => ++checks === 1 ? pending.promise : undefined });
  const old = r.speech.request('callStart', { muted: true, pause: 'quick' });
  await settle(); assert.equal(checks, 1);
  await r.speech.request('callStop');
  const next = r.speech.request('callStart', { pause: 'quick' });
  pending.resolve(); assert.deepEqual(await old, { value: 'unavailable' });
  assert.deepEqual(await next, { value: 'ok' }); assert.equal(r.f.capturers.length, 1);
  await audio(r, false);
});

test('retired start completion cannot erase the next pending start mute updates', async t => {
  const waits = [deferred(), deferred()]; let checks = 0;
  const r = rig(t, { permission: () => waits[checks++].promise });
  const old = r.speech.request('callStart', { muted: false, pause: 'quick' });
  await settle(); await r.speech.request('callStop');
  const next = r.speech.request('callStart', { muted: false, pause: 'quick' });
  await settle(); assert.equal(checks, 2);
  waits[0].resolve(); assert.deepEqual(await old, { value: 'unavailable' });
  assert.deepEqual(await r.speech.request('callMute', { on: true }), { value: null });
  waits[1].resolve(); assert.deepEqual(await next, { value: 'ok' });
  assert.equal(r.f.capturers.length, 1); await audio(r, true);
});

test('background retires a muted pending request and foreground starts a fresh default call', async t => {
  const pending = deferred(); let checks = 0;
  const r = rig(t, { permission: () => ++checks === 1 ? pending.promise : undefined });
  const old = r.speech.request('callStart', { muted: true, pause: 'quick' });
  await settle(); r.speech.background(); await settle();
  pending.resolve(); assert.deepEqual(await old, { value: 'unavailable' });
  assert.equal(r.f.capturers.length, 0); r.speech.foreground();
  assert.deepEqual(await r.speech.request('callStart', { pause: 'quick' }), { value: 'ok' });
  await audio(r, false);
});

test('after-start mute still resets PCM and resume admits only fresh frames', async t => {
  const r = rig(t);
  assert.deepEqual(await r.speech.request('callStart', { pause: 'quick' }), { value: 'ok' });
  await r.speech.request('callMute', { on: true }); await audio(r, true);
  assert(r.resets.some(event => event.reason === 'muted' && event.session === 1320));
  await r.speech.request('callMute', { on: false }); await audio(r, false);
  assert(r.resets.some(event => event.reason === 'resumed' && event.session === 1320));
});
