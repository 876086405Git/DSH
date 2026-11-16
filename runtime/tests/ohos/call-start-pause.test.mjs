import test from 'node:test';
import assert from 'node:assert/strict';
import { captureFixture, deferred, pcm, settle } from './call-capture-fixture.mjs';

function rig(t, options = {}) {
  const f = captureFixture(options), speech = f.speech();
  t.after(async () => { await speech.request('callStop'); });
  return { f, speech };
}
const utterances = r => r.f.events.filter(event => event.type === 'utterance');
async function feed(r, level, frames) {
  for (let index = 0; index < frames; index++) { r.f.capturers.at(-1).data(pcm(level)); await settle(); }
}
function completeWav(r, quietFrames) {
  const rows = utterances(r); assert.equal(rows.length, 1);
  // The first six voiced frames include five preroll frames. No wall-clock claim.
  assert.equal(rows[0].ms, (30 + quietFrames) * 20);
  assert.equal(rows[0].wav.length, 44 + (30 + quietFrames) * 640);
}
async function patient(r, alreadyFed = false) {
  if (!alreadyFed) { await feed(r, 20000, 30); await feed(r, 0, 55); }
  assert.equal(utterances(r).length, 0, 'patient must not end at the old normal frame threshold');
  await feed(r, 0, 25); completeWav(r, 80);
}

test('permission pending normal -> patient controls the first utterance boundary', async t => {
  const pending = deferred(), entered = deferred();
  const r = rig(t, { permission() { entered.resolve(); return pending.promise; } });
  const start = r.speech.request('callStart', { pause: 'normal', muted: false });
  await entered.promise; assert.equal(r.f.capturers.length, 0);
  assert.deepEqual(await r.speech.request('callPause', { pause: 'patient' }), { value: null });
  pending.resolve(); assert.deepEqual(await start, { value: 'ok' });
  await patient(r);
});

test('permission pending patient -> quick also honors the newer shorter boundary', async t => {
  const pending = deferred(), r = rig(t, { permission: () => pending.promise });
  const start = r.speech.request('callStart', { pause: 'patient' }); await settle();
  await r.speech.request('callPause', { pause: 'quick' }); pending.resolve();
  assert.deepEqual(await start, { value: 'ok' });
  await feed(r, 20000, 30); await feed(r, 0, 35); completeWav(r, 35);
});

test('multiple permission-pending pause changes retain the final selection', async t => {
  const pending = deferred(), r = rig(t, { permission: () => pending.promise });
  const start = r.speech.request('callStart', { pause: 'normal' }); await settle();
  for (const pause of ['patient', 'quick', 'patient']) await r.speech.request('callPause', { pause });
  pending.resolve(); assert.deepEqual(await start, { value: 'ok' }); await patient(r);
});

test('selected patient pause is installed before early SDK readData during start', async t => {
  const pending = deferred();
  const r = rig(t, { permission: () => pending.promise, start(capturer) {
    capturer.data(pcm(20000, 30)); capturer.data(pcm(0, 55));
  } });
  const start = r.speech.request('callStart', { pause: 'normal' }); await settle();
  await r.speech.request('callPause', { pause: 'patient' }); pending.resolve();
  assert.deepEqual(await start, { value: 'ok' }); await settle(); await patient(r, true);
});

test('pause change during old playback release reaches the next capture owner', async t => {
  const pending = deferred(), options = {}, r = rig(t, options);
  await r.speech.request('callStart', { pause: 'normal' });
  await r.speech.request('open', { id: 'old', call: true, rate: 24000 });
  options.pcmStop = () => pending.promise;
  const start = r.speech.request('callStart', { pause: 'normal' }); await settle();
  await r.speech.request('callPause', { pause: 'patient' }); pending.resolve();
  assert.deepEqual(await start, { value: 'ok' }); assert.equal(r.f.capturers[0].releases, 1);
  assert.equal(r.f.capturers.length, 2); await patient(r);
});

test('failed patient start does not overwrite a following explicit normal request', async t => {
  const options = { granted: false }, r = rig(t, options);
  assert.deepEqual(await r.speech.request('callStart', { pause: 'patient' }), { value: 'permission' });
  options.granted = true;
  assert.deepEqual(await r.speech.request('callStart', { pause: 'normal' }), { value: 'ok' });
  await feed(r, 20000, 30); await feed(r, 0, 55); completeWav(r, 50);
});

test('old stopped permission reply cannot erase a newer pending pause choice', async t => {
  const waits = [deferred(), deferred()]; let checks = 0;
  const r = rig(t, { permission: () => waits[checks++].promise });
  const old = r.speech.request('callStart', { pause: 'normal' }); await settle();
  await r.speech.request('callPause', { pause: 'patient' }); await r.speech.request('callStop');
  const next = r.speech.request('callStart', { pause: 'normal' }); await settle(); assert.equal(checks, 2);
  waits[0].resolve(); assert.deepEqual(await old, { value: 'unavailable' });
  await r.speech.request('callPause', { pause: 'patient' }); waits[1].resolve();
  assert.deepEqual(await next, { value: 'ok' }); assert.equal(r.f.capturers.length, 1); await patient(r);
});

test('background retirement leaves the following explicit normal request independent', async t => {
  const pending = deferred(); let checks = 0;
  const r = rig(t, { permission: () => ++checks === 1 ? pending.promise : undefined });
  const old = r.speech.request('callStart', { pause: 'normal' }); await settle();
  await r.speech.request('callPause', { pause: 'patient' }); r.speech.background(); await settle();
  pending.resolve(); assert.deepEqual(await old, { value: 'unavailable' }); assert.equal(r.f.capturers.length, 0);
  r.speech.foreground(); assert.deepEqual(await r.speech.request('callStart', { pause: 'normal' }), { value: 'ok' });
  await feed(r, 20000, 30); await feed(r, 0, 55); completeWav(r, 50);
});

test('active capture pause changes retain the quiet frames already accumulated', async t => {
  const r = rig(t); assert.deepEqual(await r.speech.request('callStart', { pause: 'normal' }), { value: 'ok' });
  await feed(r, 20000, 30); await feed(r, 0, 10);
  await r.speech.request('callPause', { pause: 'patient' }); await feed(r, 0, 45);
  assert.equal(utterances(r).length, 0); await feed(r, 0, 25); completeWav(r, 80);
});
