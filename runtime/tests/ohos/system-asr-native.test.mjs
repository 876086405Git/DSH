import test from 'node:test';
import assert from 'node:assert/strict';
import { asrFixture, deferred, settle } from './system-asr-fixture.mjs';
const frame = () => new Uint8Array(640);

test('external PCM recognizer is offline zh-CN long mode and never opens a second microphone', async () => {
  const f = asrFixture(), asr = f.make();
  await asr.start();
  const e = f.engines[0];
  assert.equal(e.params.language, 'zh-CN'); assert.equal(e.params.online, 1);
  assert.equal(e.params.extraParams.recognizerMode, 'long');
  assert.equal(e.starts[0].extraParams.recognitionMode, 1);
  assert.equal(e.starts[0].extraParams.maxAudioDuration, 60000);
  assert.deepEqual(f.calls, ['create', 'setListener', 'start']);
  await asr.stop(false); assert.equal(e.shutdowns, 1); assert.equal(f.timers.size, 0);
});

test('PCM copy and 20ms pacing preserve order without bursting queued frames', async () => {
  const f = asrFixture(), asr = f.make(); await asr.start();
  const a = frame(); a[0] = 1; asr.feed(a); a[0] = 99;
  const b = frame(); b[0] = 2; asr.feed(b);
  await f.advance(19); assert.equal(f.engines[0].audio.length, 0);
  await f.advance(21);
  assert.deepEqual(f.engines[0].audio.map(v => [v.bytes[0], v.time]), [[1, 20], [2, 40]]);
  assert.equal(f.timers.size, 0); await asr.stop(false);
});

test('sentence final is separate from session completion and late cancelled results are ignored', async () => {
  const f = asrFixture(), asr = f.make(); await asr.start(); const e = f.engines[0];
  e.result('你'); e.result('你好', true); e.result('下一句');
  assert.deepEqual(f.events.map(v => [v.type, v.text]), [['partial', '你'], ['final', '你好'], ['partial', '下一句']]);
  assert.equal(e.shutdowns, 0); await asr.stop(false); e.result('晚到', true, true);
  assert.equal(f.events.length, 3); assert.equal(e.shutdowns, 1);
});

test('stop while create is pending retires the late allocation before it can listen', async () => {
  const gate = deferred(), f = asrFixture({ create: () => gate.promise }), asr = f.make();
  const opening = asr.start(); const rejected = assert.rejects(opening, /cancel|retired/);
  await settle(); const stopped = asr.stop(false); gate.resolve(); await rejected; await stopped;
  assert.equal(f.engines[0].starts.length, 0); assert.equal(f.engines[0].shutdowns, 1);
  assert.equal(f.events.length, 0);
});

test('55 second rollover waits for completion and keeps transition audio bounded and paced', async () => {
  const f = asrFixture({ autoComplete: false }), asr = f.make(); await asr.start(); const e = f.engines[0];
  for (let n = 0; n < 2750; n++) { asr.feed(frame()); await f.advance(20); }
  assert.equal(e.audio.length, 2750); assert.equal(e.finishes.length, 1); assert.equal(e.starts.length, 1);
  asr.feed(frame()); await f.advance(100); assert.equal(e.audio.length, 2750);
  const old = e.starts[0].sessionId; e.complete(); await settle();
  assert.equal(e.starts.length, 2); assert.notEqual(e.starts[1].sessionId, old);
  e.result('旧结果', false, false, old); assert.equal(f.events.length, 0);
  await f.advance(20); assert.equal(e.audio.length, 2751);
  assert.equal(e.audio.at(-1).id, e.starts[1].sessionId); await asr.stop(false);
});

test('a full pending PCM queue is an observable failure rather than silent frame loss', async () => {
  const f = asrFixture(), asr = f.make(); await asr.start();
  for (let n = 0; n < 50; n++) asr.feed(frame());
  assert.throws(() => asr.feed(frame()), /queue/); await settle();
  assert.equal(f.events.at(-1).type, 'error'); assert.equal(f.events.at(-1).reason, 'queue');
  assert.equal(f.timers.size, 0); await asr.stop(false);
});

test('shutdown failure retains the shared ASR lease until explicit retry succeeds', async () => {
  const f = asrFixture({ shutdownFailure: true }), a = f.make(); await a.start();
  await assert.rejects(a.stop(false), /shutdown/);
  const b = f.make(); await assert.rejects(b.start(), /busy/); assert.equal(f.engines.length, 1);
  f.change({ shutdownFailure: false }); await a.stop(false);
  const c = f.make(); await c.start(); assert.equal(f.engines.length, 2); await c.stop(false);
});

test('finalizing stop flushes queued PCM, waits for complete, then releases the engine', async () => {
  const f = asrFixture({ autoComplete: false }), asr = f.make(); await asr.start(); const e = f.engines[0];
  asr.feed(frame()); const ending = asr.stop(true); let done = false; ending.then(() => { done = true; });
  await f.advance(20); assert.equal(e.audio.length, 1); assert.equal(e.finishes.length, 1); assert.equal(done, false);
  e.result('完成', true, true); e.complete(); await ending;
  assert.equal(e.shutdowns, 1); assert.equal(f.events.at(-1).text, '完成'); assert.equal(f.timers.size, 0);
});


test('finalizing during rollover preserves queued tail before releasing', async () => {
  const f = asrFixture({ autoComplete: false }), asr = f.make(); await asr.start(); const e = f.engines[0];
  for (let n = 0; n < 2750; n++) { asr.feed(frame()); await f.advance(20); }
  asr.feed(frame()); const ending = asr.stop(true); let done = false; ending.then(() => { done = true; });
  await settle(); assert.equal(done, false);
  e.complete(); await settle(); assert.equal(e.starts.length, 2);
  await f.advance(20); assert.equal(e.audio.length, 2751);
  e.result('尾句', true, true); e.complete(); await ending;
  assert.equal(f.events.at(-1).text, '尾句'); assert.equal(e.shutdowns, 1);
});

test('active ordinary dictation excludes captions; idle prewarm is physically retired first', async () => {
  const f = asrFixture(), Voice = f.load('HmsVoiceRecognizer').HmsVoiceRecognizer;
  const voice = new Voice(() => {}, () => true, () => {}); await voice.start();
  const blocked = f.make(); await assert.rejects(blocked.start(), /busy/); assert.equal(f.engines.length, 1);
  await voice.cancel(); assert.equal(f.engines[0].shutdowns, 1);
  assert.equal(await Voice.available(), true); assert.equal(f.engines.length, 2);
  const asr = f.make(); await asr.start();
  assert.equal(f.engines[1].shutdowns, 1); assert.equal(f.engines.length, 3); await asr.stop(false);
});


test('finalize during rollover restart waits for delayed onStart and preserves the queued tail', async () => {
  const f = asrFixture({ autoComplete: false }), asr = f.make();
  await asr.start(); const e = f.engines[0];
  for (let n = 0; n < 2750; n++) { asr.feed(new Uint8Array(640)); await f.advance(20); }
  const tail = new Uint8Array(640).fill(9); asr.feed(tail);
  f.change({ autoStart: false }); e.complete(); await settle();
  assert.equal(e.starts.length, 2);
  let done = false; const stopping = asr.stop(true); stopping.then(() => { done = true; }, () => {});
  assert.equal(asr.stop(true), stopping, 'repeated finalize shares the pending completion');
  await settle(); assert.equal(done, false); assert.equal(e.shutdowns, 0);
  e.listener.onStart(e.starts[1].sessionId, ''); await f.advance(20);
  assert.equal(e.audio.length, 2751); assert.equal(e.audio.at(-1).bytes[0], 9);
  e.complete(); await stopping; assert.equal(e.shutdowns, 1);
});
