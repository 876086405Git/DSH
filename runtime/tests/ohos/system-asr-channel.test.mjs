import test from 'node:test';
import assert from 'node:assert/strict';
import { asrFixture, deferred, settle } from './system-asr-fixture.mjs';
const pcm = () => new Uint8Array(640);

test('real EntryAbility registers external ASR; channel preserves run, sentence events and exact PCM', async () => {
  const f = asrFixture(), a = f.attach();
  await a.invoke('start', { run: 7 });
  await a.invoke('feed', { run: 7, bytes: pcm() }); await f.advance(20);
  assert.equal(f.engines[0].audio.length, 1);
  f.engines[0].result('句一', true); f.engines[0].result('句二');
  assert.deepEqual(f.channelEvents.map(e => [e.run, e.type, e.text]), [[7, 'final', '句一'], [7, 'partial', '句二']]);
  await a.invoke('stop', { run: 7, finalize: true });
  assert.equal(f.engines[0].shutdowns, 1);
  assert.equal(f.channelEvents.at(-1).text, '句二');
});

test('replaced engine cancels unresolved creation physically before the next ASR starts', async () => {
  const opening = deferred(), f = asrFixture({ create: () => opening.promise }), a = f.attach();
  const old = a.invoke('start', { run: 1 }); old.catch(() => {});
  await settle();
  const b = f.attach(); const next = b.invoke('start', { run: 2 });
  await settle(); assert.equal(f.engines.length, 0);
  opening.resolve(); await assert.rejects(old, /cancelled|retired/); await next;
  assert.equal(f.engines.length, 2); assert.equal(f.engines[0].starts.length, 0);
  assert.equal(f.engines[0].shutdowns, 1); assert.equal(f.engines[1].starts.length, 1);
  f.engines[0].listener.onResult('old', { result: '迟到', isFinal: false, isLast: false });
  assert.equal(f.channelEvents.filter(e => e.text === '迟到').length, 0);
  await b.invoke('stop', { run: 2, finalize: false });
});

test('late old-run stop cannot cancel a replacement; background denies restart until foreground', async () => {
  const f = asrFixture(), a = f.attach();
  await a.invoke('start', { run: 1 }); await a.invoke('start', { run: 2 });
  await a.invoke('stop', { run: 1, finalize: false });
  assert.equal(f.engines[1].shutdowns, 0);
  a.ui.onBackground(); await settle();
  assert.equal(f.engines[1].shutdowns, 1);
  assert(f.channelEvents.some(e => e.run === 2 && e.reason === 'background'));
  await assert.rejects(a.invoke('start', { run: 3 }), /no_ability/);
  a.ui.onForeground(); await a.invoke('start', { run: 4 });
  await a.invoke('stop', { run: 4, finalize: false });
});

test('shutdown failure keeps retry handle across Flutter owners and blocks another physical engine', async () => {
  const f = asrFixture(), a = f.attach(); await a.invoke('start', { run: 1 });
  f.change({ shutdownFailure: true });
  const b = f.attach(); await settle();
  await assert.rejects(b.invoke('start', { run: 2 }), /shutdown refused/);
  assert.equal(f.engines.length, 1);
  f.change({ shutdownFailure: false }); await b.invoke('start', { run: 3 });
  assert.equal(f.engines.length, 2);
  await b.invoke('stop', { run: 3, finalize: false });
});

test('channel rejects malformed PCM and reports queue overflow without fake recognition text', async () => {
  const f = asrFixture(), a = f.attach(); await a.invoke('start', { run: 8 });
  await assert.rejects(a.invoke('feed', { run: 8, bytes: [1, 2] }), /format/);
  for (let n = 0; n < 50; n++) await a.invoke('feed', { run: 8, bytes: pcm() });
  await assert.rejects(a.invoke('feed', { run: 8, bytes: pcm() }), /queue/);
  assert.deepEqual(f.channelEvents.filter(e => e.type === 'error').map(e => [e.reason, e.text]), [['queue', undefined]]);
  await a.invoke('stop', { run: 8, finalize: false });
});

test('explicit same-run stop retries failed background retirement without touching a new run', async () => {
  const f = asrFixture(), a = f.attach(); await a.invoke('start', { run: 1 });
  f.change({ shutdownFailure: true }); a.ui.onBackground(); await settle();
  assert.equal(f.engines[0].shutdowns, 1);
  f.change({ shutdownFailure: false });
  await a.invoke('stop', { run: 1, finalize: false });
  assert.equal(f.engines[0].shutdowns, 2, 'same owner/run can retry retained physical engine');
  a.ui.onForeground(); await a.invoke('start', { run: 2 });
  await a.invoke('stop', { run: 1, finalize: false });
  assert.equal(f.engines[1].shutdowns, 0);
  await a.invoke('stop', { run: 2, finalize: false });
});

test('failed replacement start keeps the older physical engine reachable by the new request stop', async () => {
  const f = asrFixture(), a = f.attach(); await a.invoke('start', { run: 1 });
  f.change({ shutdownFailure: true });
  await assert.rejects(a.invoke('start', { run: 2 }), /shutdown refused/);
  assert.equal(f.engines.length, 1); assert.equal(f.engines[0].shutdowns, 1);
  f.change({ shutdownFailure: false });
  await a.invoke('stop', { run: 2, finalize: false });
  assert.equal(f.engines[0].shutdowns, 2, 'failed new admission still owns retirement retry');
  const Dictation = f.load('HmsVoiceRecognizer').HmsVoiceRecognizer;
  assert.equal(await Dictation.available(), true); await Dictation.releaseIdle();
});
