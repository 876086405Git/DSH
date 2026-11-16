import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { systemTtsFixture, deferred, until } from './system-tts-fixture.mjs';

const call = (f, method, args) => f.call(f.methods, method, args).done;
const ready = f => call(f, 'ready', { language: 'zh-CN' });
const speak = (f, id, text = '这是一句系统朗读。', extra = {}) => call(f, 'speak', { id, text, rate: 1, pitch: 1.12, ...extra });
const phases = f => f.events.filter(e => e.channel === 'dsh/companion_voice').map(e => [e.type, e.id]);
const pcm = (f, id = 'pcm') => f.call(f.pcm, 'open', { id, rate: 24000, call: false, levels: false }).done;

test('actual EntryAbility registers Android companion-voice contract and offline system TTS', async () => {
  const f = systemTtsFixture();
  assert.deepEqual(await ready(f), { value: true }, 'SYSTEM_TTS_UNAVAILABLE');
  assert.equal(f.channels.filter(c => c.name === 'dsh/companion_voice').length, 1);
  assert.equal(f.trace.filter(s => s === 'tts.create').length, 1);
  assert.equal(f.engines[0].params.online, 1);
  assert.equal(f.engines[0].params.language, 'zh-CN');
  assert.equal(f.engines[0].params.person, 0);
  assert.equal(f.engines[0].params.extraParams.isBackStage, false);
  assert.deepEqual(phases(f), []);
  assert.deepEqual(await call(f, 'play', { id: 'x', path: '/private/audio.mp3' }), { value: false });
  assert.deepEqual(await call(f, 'unknown'), { missing: true });
  assert.deepEqual(await call(f, 'stop'), { value: null });
});

test('channel method names and argument keys agree with unchanged Android source', () => {
  const android = fs.readFileSync(new URL('../../../app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/companion/CompanionVoicePlugin.kt', import.meta.url), 'utf8');
  for (const method of ['ready', 'speak', 'play', 'stop']) assert(android.includes('"' + method + '" ->'));
  for (const key of ['language', 'id', 'text', 'rate', 'pitch', 'flush', 'path']) assert(android.includes('("' + key + '")'));
  for (const type of ['start', 'range', 'done', 'stopped', 'error']) assert(android.includes('send("' + type + '"'));
  assert(android.includes('CHANNEL = "dsh/companion_voice"'));
});

test('queued sentences use unique legal native IDs and wait for audible completion', async () => {
  const f = systemTtsFixture(); assert.deepEqual(await ready(f), { value: true });
  for (const id of ['read-1', 'read-2']) assert.deepEqual(await speak(f, id), { value: true });
  const engine = f.engines[0], ids = engine.calls.map(c => c.params.requestId);
  assert.equal(new Set(ids).size, 2);
  assert(ids.every(id => /^[A-Za-z0-9]+$/.test(id) && !id.includes('read')));
  assert(engine.calls.every(c => c.params.extraParams.queueMode === 0 && c.params.extraParams.playType === 1));
  engine.start(ids[0]); engine.start(ids[0]); engine.complete(ids[0], 0);
  assert.deepEqual(phases(f), [['start', 'read-1']]);
  engine.complete(ids[0], 1); engine.complete(ids[0], 1); engine.error(ids[0]);
  engine.start(ids[1]); engine.complete(ids[1], 1);
  assert.deepEqual(phases(f), [['start', 'read-1'], ['done', 'read-1'], ['start', 'read-2'], ['done', 'read-2']]);
  for (const event of f.events) assert.deepEqual(Object.keys(event).sort(), ['channel', 'end', 'id', 'messenger', 'method', 'start', 'type']);
  await call(f, 'stop');
});

test('flush cancels queued IDs once and old callbacks never target a reused Dart ID', async () => {
  const f = systemTtsFixture(); await ready(f); await speak(f, 'same'); await speak(f, 'queued');
  const old = f.engines[0], oldIds = old.calls.map(c => c.params.requestId);
  assert.deepEqual(await speak(f, 'same', '新句子。', { flush: true }), { value: true });
  const current = f.engines.at(-1), currentId = current.calls.at(-1).params.requestId;
  assert(!oldIds.includes(currentId));
  for (const id of oldIds) { old.start(id); old.complete(id); old.stopped(id); old.error(id); }
  assert.deepEqual(phases(f), [['stopped', 'same'], ['stopped', 'queued']]);
  current.start(currentId); current.complete(currentId);
  assert.deepEqual(phases(f).slice(-2), [['start', 'same'], ['done', 'same']]);
  await call(f, 'stop');
});

test('flush replaces earlier pending lane claims and preserves subsequent queued sentences', async () => {
  const gate = deferred(), f = systemTtsFixture({ pcmStop: () => gate.promise });
  await pcm(f); await ready(f);
  const old = speak(f, 'old', '旧的等待朗读。');
  await until(() => f.trace.includes('pcm.stop'));
  const replacement = speak(f, 'replacement', '新的替换朗读。', { flush: true });
  await until(() => f.trace.includes('tts.stop'));
  const queued = speak(f, 'queued', '替换之后的下一句。');
  assert.equal(f.engines[0].calls.length, 0);
  gate.resolve();
  assert.deepEqual(await old, { value: false }, 'FLUSH_MUST_CANCEL_PENDING_SPEAK');
  assert.deepEqual(await replacement, { value: true });
  assert.deepEqual(await queued, { value: true });
  assert.deepEqual(f.engines[0].calls.map(c => c.text), ['新的替换朗读。', '替换之后的下一句。']);
  for (const c of f.engines[0].calls) f.engines[0].complete(c.params.requestId);
  assert.deepEqual(phases(f), [['done', 'replacement'], ['done', 'queued']]);
  await call(f, 'stop');
});

test('flush replaces pending engine creation without invalidating the replacement or later queue', async () => {
  const f = systemTtsFixture(); await ready(f); await call(f, 'stop');
  const gate = deferred(); f.change({ create: () => gate.promise });
  const old = speak(f, 'old', '旧的创建等待。');
  await until(() => f.trace.filter(s => s === 'tts.create').length === 2);
  const replacement = speak(f, 'replacement', '替换创建等待。', { flush: true });
  const queued = speak(f, 'queued', '替换之后排队。');
  gate.resolve();
  assert.deepEqual(await old, { value: false }, 'FLUSH_MUST_CANCEL_PENDING_CREATION_SPEAK');
  assert.deepEqual(await replacement, { value: true });
  assert.deepEqual(await queued, { value: true });
  assert.equal(f.engines.length, 2);
  assert.deepEqual(f.engines[1].calls.map(c => c.text), ['替换创建等待。', '替换之后排队。']);
  await call(f, 'stop');
});

test('stop cancels pending creation; late engine shuts down and cannot start a queued line', async () => {
  const gate = deferred(), f = systemTtsFixture({ create: () => gate.promise });
  const one = ready(f), two = ready(f);
  await until(() => f.trace.includes('tts.create'));
  const stop = call(f, 'stop'); gate.resolve();
  assert.deepEqual(await one, { value: false }); assert.deepEqual(await two, { value: false });
  assert.deepEqual(await stop, { value: null });
  assert.equal(f.trace.filter(s => s === 'tts.create').length, 1);
  assert.equal(f.engines[0].closed, true); assert.equal(f.engines[0].calls.length, 0);
  assert.deepEqual(await ready(f), { value: true });
  assert.equal(f.engines.length, 2); await call(f, 'stop');
});

test('cached Dart readiness survives stop and PCM eviction without a second ready call', async () => {
  const f = systemTtsFixture();
  assert.deepEqual(await speak(f, 'not-ready'), { value: false });
  await ready(f); await speak(f, 'first'); const first = f.engines[0];
  assert.deepEqual(await call(f, 'stop'), { value: null });
  assert.equal(first.closed, true);
  assert.deepEqual(await speak(f, 'second'), { value: true });
  const second = f.engines[1]; assert.notEqual(second, first);
  assert.deepEqual(await pcm(f), { value: true }); assert.equal(second.closed, true);
  assert.deepEqual(await speak(f, 'third'), { value: true });
  const third = f.engines[2], id = third.calls[0].params.requestId;
  assert.equal(f.streams[0].closed, true);
  third.start(id); third.complete(id);
  assert.deepEqual(phases(f).at(-1), ['done', 'third']); await call(f, 'stop');
});

test('a newer PCM request supersedes TTS waiting for a previous PCM close', async () => {
  const gate = deferred(), f = systemTtsFixture({ pcmStop: () => gate.promise });
  await pcm(f, 'first'); await ready(f);
  const speaking = speak(f, 'superseded'); await until(() => f.trace.includes('pcm.stop'));
  const reopening = pcm(f, 'latest'); gate.resolve();
  assert.deepEqual(await speaking, { value: false });
  assert.deepEqual(await reopening, { value: true });
  assert.equal(f.engines[0].calls.length, 0); assert.equal(f.streams.length, 2);
  await f.call(f.pcm, 'stop').done; await call(f, 'stop');
});

test('reusing a plugin with a new engine retires old IDs only on their captured messenger', async () => {
  const f = systemTtsFixture(); await ready(f); await speak(f, 'old');
  const old = f.engines[0], oldId = old.calls[0].params.requestId;
  const replacement = f.attach(f.plugin);
  assert.deepEqual(await f.call(replacement.methods, 'ready').done, { value: true });
  assert.equal(old.closed, true);
  const stopped = f.events.find(e => e.type === 'stopped' && e.id === 'old');
  assert.equal(stopped.messenger, f.messenger);
  assert.notEqual(stopped.messenger, replacement.messenger);
  old.start(oldId); old.complete(oldId); old.error(oldId);
  assert.equal(f.events.filter(e => e.id === 'old').length, 1);
  assert.deepEqual(await f.call(replacement.methods, 'speak', { id: 'new', text: '新连接。' }).done, { value: true });
  const next = f.engines.at(-1), id = next.calls[0].params.requestId;
  next.complete(id);
  assert.equal(f.events.at(-1).messenger, replacement.messenger);
  await f.call(replacement.methods, 'stop').done;
});

test('Kit/factory failure is false and is retryable without acquiring microphone or playing', async () => {
  for (const initial of [{ loadError: true }, { createError: true }]) {
    const f = systemTtsFixture(initial);
    assert.deepEqual(await ready(f), { value: false });
    assert.deepEqual(phases(f), []); assert.equal(f.engines.length, 0);
    f.change({ loadError: false, createError: false });
    assert.deepEqual(await ready(f), { value: true }); await call(f, 'stop');
  }
});

test('unsupported language and malformed/too-long text reject before native speak', async () => {
  const f = systemTtsFixture();
  assert.deepEqual(await call(f, 'ready', { language: 'not-a-language' }), { value: false });
  assert.equal(f.engines.length, 0); await ready(f);
  for (const args of [{ id: 2, text: 'a' }, { id: '', text: 'a' }, { id: 'x', text: '' }, { id: 'x', text: 'a'.repeat(10001) },
    { id: 'x', text: 'a', rate: 0.1 }, { id: 'x', text: 'a', pitch: 3 }, { id: 'x', text: 'a', rate: '1' }]) {
    assert.deepEqual(await call(f, 'speak', args), { value: false });
  }
  assert.equal(f.engines[0].calls.length, 0); await call(f, 'stop');
});

test('synchronous speak rejection returns false; asynchronous native error is one terminal event', async () => {
  const f = systemTtsFixture({ speakError: true }); await ready(f);
  assert.deepEqual(await speak(f, 'x'), { value: false }); assert.deepEqual(phases(f), []);
  f.change({ speakError: false }); assert.deepEqual(await speak(f, 'x'), { value: true });
  const engine = f.engines[0], id = engine.calls[0].params.requestId;
  engine.error(id); engine.error(id); engine.complete(id); engine.start(id);
  assert.deepEqual(phases(f), [['error', 'x']]); await call(f, 'stop');
});

test('OH call playback selects communication usage; ordinary TTS keeps voice assistant usage', async () => {
  const f = systemTtsFixture(); await ready(f);
  assert.deepEqual(await speak(f, 'call', '通话回复。', { call: true }), { value: true });
  assert.equal(f.engines[0].calls[0].params.extraParams.soundChannel, 2);
  assert.deepEqual(await speak(f, 'read', '普通朗读。'), { value: true });
  assert.equal(f.engines[0].calls[1].params.extraParams.soundChannel, 3);
  assert.deepEqual(await speak(f, 'invalid', '错误场景值。', { call: 'true' }), { value: false });
  await call(f, 'stop');
});

test('background releases TTS; stale Ability/background/engine detach cannot revoke replacement', async () => {
  const f = systemTtsFixture(); await ready(f); await speak(f, 'old'); const old = f.engines[0];
  f.background(); await until(() => old.closed);
  assert.deepEqual(await ready(f), { value: false });
  const next = f.attach();
  assert.deepEqual(await f.call(next.methods, 'ready', { language: 'zh-CN' }).done, { value: true });
  const current = f.engines.at(-1); f.background();
  f.plugin.onDetachedFromEngine(f.engine);
  assert.notEqual(current.closed, true);
  const before = f.events.length; old.start(old.calls[0].params.requestId); old.complete(old.calls[0].params.requestId);
  assert.equal(f.events.length, before);
  next.destroy(); await until(() => current.closed);
});

test('prewarming system TTS does not interrupt PCM; speaking waits for physical PCM retirement', async () => {
  const gate = deferred(), f = systemTtsFixture({ pcmStop: () => gate.promise });
  assert.deepEqual(await pcm(f), { value: true });
  assert.deepEqual(await ready(f), { value: true });
  assert.equal(f.trace.includes('pcm.stop'), false);
  const speaking = speak(f, 'system');
  await until(() => f.trace.includes('pcm.stop'));
  assert.equal(f.trace.includes('tts.speak'), false);
  gate.resolve(); assert.deepEqual(await speaking, { value: true });
  assert.equal(f.streams[0].closed, true);
  assert(f.trace.indexOf('pcm.stop') < f.trace.indexOf('tts.speak'));
  assert.deepEqual(await pcm(f, 'again'), { value: true });
  assert.equal(f.engines[0].closed, true);
  await f.call(f.pcm, 'stop').done;
});

test('failed PCM release blocks system playback and a later request can retry', async () => {
  const f = systemTtsFixture({ pcmStopError: true }); await pcm(f); await ready(f);
  assert.deepEqual(await speak(f, 'blocked'), { value: false });
  assert.equal(f.engines[0].calls.length, 0);
  f.change({ pcmStopError: false }); assert.deepEqual(await speak(f, 'retry'), { value: true });
  await call(f, 'stop');
});

test('failed TTS shutdown retains the resource and blocks PCM until stop retries', async () => {
  const f = systemTtsFixture(); await ready(f); await speak(f, 'x');
  f.change({ shutdownError: true });
  assert.equal((await call(f, 'stop')).error, 'speech-output');
  assert.deepEqual(await pcm(f), { value: false }); assert.equal(f.streams.length, 0);
  f.change({ shutdownError: false }); assert.deepEqual(await call(f, 'stop'), { value: null });
  assert.equal(f.engines[0].closed, true); assert.deepEqual(await pcm(f), { value: true });
  await f.call(f.pcm, 'stop').done;
});

test('retired reply/event transports never produce a second method reply', async () => {
  const f = systemTtsFixture({ replyError: true, eventError: true });
  const pending = f.call(f.methods, 'ready', { language: 'zh-CN' });
  assert.deepEqual(await pending.done, { value: true }); assert.equal(pending.replies.length, 1);
  await speak(f, 'x'); const engine = f.engines[0], id = engine.calls[0].params.requestId;
  engine.start(id); engine.complete(id); assert.deepEqual(await call(f, 'stop'), { value: null });
});
