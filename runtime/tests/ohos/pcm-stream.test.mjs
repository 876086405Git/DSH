import test from 'node:test';
import assert from 'node:assert/strict';
import { pcmFixture, deferred, until } from './pcm-stream-fixture.mjs';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const terminals = h => h.events.filter(event => event.kind !== 'start');
const bytes = (...values) => new Uint8Array(values);

test('ring preserves byte order across wrap, copies caller storage, rejects the whole overflow', () => {
  const h = pcmFixture(), q = new h.Queue(8), original = bytes(1, 2, 3, 4, 5, 6);
  assert(q.append(original)); original.fill(99);
  const first = new Uint8Array(4); q.take(first, 4); assert.deepEqual([...first], [1, 2, 3, 4]);
  assert(q.append(bytes(7, 8, 9, 10, 11, 12)));
  assert.equal(q.append(bytes(13)), false); assert.equal(q.size, 8);
  const final = new Uint8Array(8); q.take(final, 8); assert.deepEqual([...final], [5, 6, 7, 8, 9, 10, 11, 12]);
  assert.equal(q.size, 0); assert.throws(() => q.take(new Uint8Array(2), 2));
});

test('open really creates, checks format twice, selects independent focus and starts before true', async () => {
  const h = pcmFixture(), s = h.make();
  assert.equal(await s.open(), true);
  const r = h.renderers[0];
  assert.equal(r.starts, 1); assert.equal(r.formatChecks, 2); assert.equal(r.mode, 1);
  assert.deepEqual({ ...r.settings.streamInfo }, { samplingRate: 24000, channels: 1, sampleFormat: 1, encodingType: 0 });
  assert.equal(r.settings.rendererInfo.usage, 12); assert.equal(r.settings.rendererInfo.rendererFlags, 0);
  assert.deepEqual(h.events, []); assert.equal(s.waiting(), 0);
  await s.stop(); await s.stop(); assert.equal(r.releases, 1); assert.equal(r.stops, 1);
  assert.deepEqual(terminals(h), [{ kind: 'stopped', reason: '' }]);
});

test('unsupported rate and capability fail before creating native output', async () => {
  for (const settings of [{ rate: 48000 }, { rate: NaN }]) {
    const h = pcmFixture(), s = h.make(settings);
    assert.equal(await s.open(), false); assert.equal(h.renderers.length, 0);
    assert(!h.calls.includes('create')); assert.equal(terminals(h)[0].kind, 'error');
  }
  const h = pcmFixture({ supported: false }); assert.equal(await h.make().open(), false);
  assert(!h.calls.includes('create'));
});

test('a rejected or absent renderer is an open failure and has no fabricated success event', async () => {
  for (const option of [{ create: async () => { throw Error('create'); } }, { createNull: true }]) {
    const h = pcmFixture(option), s = h.make();
    assert.equal(await s.open(), false); assert.equal(h.renderers.length, 0);
    assert.equal(terminals(h).length, 1); assert.equal(terminals(h)[0].kind, 'error');
    assert.equal(s.write(bytes(1, 2)), -1);
  }
});

test('every PCM field is verified before start and again after start', async () => {
  for (const wrong of [{ samplingRate: 48000 }, { channels: 2 }, { sampleFormat: 9 }, { encodingType: 1 }]) {
    const h = pcmFixture({ format: wrong }); assert.equal(await h.make().open(), false);
    assert.equal(h.renderers[0].starts, 0); assert.equal(h.renderers[0].releases, 1);
  }
  const h = pcmFixture({ afterFormat: { channels: 2 } }); assert.equal(await h.make().open(), false);
  assert.equal(h.renderers[0].starts, 1); assert.equal(h.renderers[0].stops, 1);
  assert.equal(h.renderers[0].releases, 1); assert.equal(terminals(h)[0].reason, 'format');
});

test('unusable buffer sizes, event registration and focus-mode failures release partial allocations', async () => {
  for (const option of [{ bufferSize: 0 }, { bufferSize: 3 }, { bufferSize: 65538 },
    { onFailure: 'audioInterrupt' }, { onFailure: 'stateChange' }, { onFailure: 'writeData' },
    { mode: async () => { throw Error('focus'); } }]) {
    const h = pcmFixture(option); assert.equal(await h.make().open(), false);
    assert.equal(h.renderers[0].starts, 0); assert.equal(h.renderers[0].releases, 1);
    assert.equal(terminals(h)[0].kind, 'error');
  }
});

test('start rejection and a non-running resolved start cannot pass the preflight', async () => {
  for (const option of [{ start: async () => { throw Error('start'); } }, { startState: 5 }]) {
    const h = pcmFixture(option); assert.equal(await h.make().open(), false);
    assert.equal(h.renderers[0].stops, 1); assert.equal(h.renderers[0].releases, 1);
    assert.equal(terminals(h)[0].kind, 'error');
  }
});

test('stop during create waits for the allocation then releases it without starting', async () => {
  const gate = deferred(), h = pcmFixture({ create: () => gate.promise }), s = h.make();
  const opening = s.open(); await until(() => h.calls.includes('create'));
  let closed = false; const stopping = s.stop().then(() => { closed = true; });
  await sleep(5); assert.equal(closed, false);
  gate.resolve(); assert.equal(await opening, false); await stopping;
  assert.equal(h.renderers[0].starts, 0); assert.equal(h.renderers[0].releases, 1);
  assert.equal(terminals(h).length, 1); assert.equal(terminals(h)[0].kind, 'stopped');
});

test('stop during start invalidates callbacks immediately and releases after start settles', async () => {
  const gate = deferred(), h = pcmFixture({ start: () => gate.promise }), s = h.make();
  const opening = s.open(); await until(() => h.renderers[0]?.starts === 1);
  const r = h.renderers[0], stopping = s.stop();
  assert.equal(r.pump().result, h.audio.AudioDataCallbackResult.INVALID);
  assert.equal(s.write(bytes(1, 2)), -1); gate.resolve();
  assert.equal(await opening, false); await stopping;
  assert.equal(r.stops, 1); assert.equal(r.releases, 1); assert.equal(h.events.some(e => e.kind === 'start'), false);
});

test('underrun retains bytes, never returns partially initialised VALID, and caller mutation is isolated', async () => {
  const h = pcmFixture(), s = h.make(); assert(await s.open()); const r = h.renderers[0];
  assert.equal(r.pump().result, -1);
  const part = bytes(1, 2, 3); assert.equal(s.write(part), 3); part.fill(99);
  assert.equal(r.pump().result, -1); assert.equal(s.waiting(), 3); assert.deepEqual(h.events, []);
  assert.equal(s.write(bytes(4, 5, 6, 7, 8)), 8);
  const output = r.pump(); assert.equal(output.result, 0); assert.deepEqual([...output.bytes], [1, 2, 3, 4, 5, 6, 7, 8]);
  assert.equal(s.waiting(), 0); await until(() => h.events.length === 1);
  assert.deepEqual(h.events, [{ kind: 'start' }]); await s.stop();
});

test('one chunk is consumed in partial callback-sized pieces; EOF pads only its last even tail', async () => {
  const h = pcmFixture(), s = h.make(); assert(await s.open()); const r = h.renderers[0];
  const input = Uint8Array.from({ length: 20 }, (_, i) => i + 1);
  assert.equal(s.write(input), 20); s.end(); assert.equal(s.write(bytes(99, 99)), -1);
  const first = r.pump(), second = r.pump(), final = r.pump();
  assert.deepEqual([...first.bytes, ...second.bytes, ...final.bytes], [...input, 0, 0, 0, 0]);
  assert.equal(s.waiting(), 0); assert.equal(r.uncommitted.length, 1);
  await sleep(5); assert.equal(r.drains, 0); assert.equal(terminals(h).length, 0);
  assert.equal(r.pump().result, -1);
  await until(() => terminals(h).length === 1);
  assert.equal(r.drains, 1); assert.equal(r.releases, 1); assert.equal(terminals(h)[0].kind, 'done');
});

test('done waits for drain completion; abort requests pause before waiting for the old drain and cannot revive late done', async () => {
  const gate = deferred(), h = pcmFixture({ drain: () => gate.promise, pause: () => gate.promise }), s = h.make();
  assert(await s.open()); const r = h.renderers[0]; s.write(bytes(1, 2)); s.end(); r.pump(); r.pump();
  await until(() => r.drains === 1); assert.equal(terminals(h).length, 0); assert.equal(r.releases, 0);
  const stopping = s.stop(); await sleep(5);
  assert.equal(r.pauses, 1); assert.equal(r.stops, 0);
  assert.equal(r.releases, 0); gate.resolve(); await stopping;
  assert.equal(r.flushes, 1); assert.equal(r.stops, 1);
  assert.equal(r.releases, 1); assert.equal(terminals(h).length, 1); assert.equal(terminals(h)[0].kind, 'stopped');
});

test('an empty ended stream completes without inventing a start or a played sample', async () => {
  const h = pcmFixture(), s = h.make(); assert(await s.open()); s.end();
  await until(() => terminals(h).length === 1);
  assert.deepEqual(terminals(h), [{ kind: 'done', reason: '' }]); assert.equal(h.events.length, 1);
  assert.equal(h.renderers[0].drains, 0); assert.equal(h.renderers[0].releases, 1);
});

test('an unpaired byte at EOF is an explicit error, while odd transport chunks can combine into samples', async () => {
  const h = pcmFixture(), s = h.make(); assert(await s.open());
  s.write(bytes(1)); s.write(bytes(2, 3)); s.end();
  await until(() => terminals(h).length === 1); assert.equal(terminals(h)[0].reason, 'truncated-sample');
  assert.equal(terminals(h)[0].kind, 'error'); assert.equal(h.renderers[0].uncommitted.length, 0);
});

test('the entire over-cap chunk is rejected and a terminal error accompanies -1', async () => {
  const h = pcmFixture(), s = h.make(); assert(await s.open());
  assert.equal(s.write(new Uint8Array(2 * 1024 * 1024)), 2 * 1024 * 1024);
  assert.equal(s.write(bytes(1)), -1); assert.equal(s.waiting(), -1);
  await until(() => terminals(h).length === 1);
  assert.deepEqual(terminals(h), [{ kind: 'error', reason: 'queue-limit' }]);
  assert.equal(h.renderers[0].releases, 1);
});

test('malformed platform callback lengths fail without returning VALID', async () => {
  for (const length of [0, 3, 65538]) {
    const h = pcmFixture(), s = h.make(); assert(await s.open()); s.write(bytes(1, 2));
    assert.equal(h.renderers[0].pump(length).result, -1);
    await until(() => terminals(h).length === 1); assert.equal(terminals(h)[0].kind, 'error');
    assert.equal(h.renderers[0].releases, 1);
  }
});

test('release failure retains the physical lease across new stream attempts and permits one later successful retry', async () => {
  const h = pcmFixture({ release: async () => { throw Error('release'); } }), first = h.make();
  assert(await first.open()); const r = h.renderers[0];
  await assert.rejects(first.stop()); assert.equal(r.releases, 1); assert.equal(terminals(h)[0].kind, 'error');
  const blocked = h.make(); assert.equal(await blocked.open(), false); assert.equal(h.renderers.length, 1);
  assert.equal(r.releases, 2); assert.equal(terminals(h).length, 2);
  h.change({ release: undefined }); await first.stop(); assert.equal(r.releases, 3);
  assert.equal(terminals(h).length, 2, 'retry may not send another terminal event for the old stream');
  const next = h.make(); assert(await next.open()); await next.stop();
  await first.stop(); assert.equal(r.releases, 3);
});

test('a failed stop is visible even if release succeeds, and successful release permits replacement', async () => {
  const h = pcmFixture({ stop: async () => { throw Error('stop'); } }), s = h.make(); assert(await s.open());
  await s.stop(); assert.equal(h.renderers[0].releases, 1); assert.equal(terminals(h)[0].reason, 'stop');
  assert.equal(terminals(h)[0].kind, 'error'); h.change({ stop: undefined });
  const next = h.make(); assert(await next.open()); await next.stop();
});

test('failed unsubscription and late platform callbacks cannot resurrect a released stream', async () => {
  const h = pcmFixture({ offFailure: 'writeData' }), s = h.make(); assert(await s.open()); const r = h.renderers[0];
  await s.stop(); const count = h.events.length;
  assert.equal(r.pump(8, { late: true }).result, -1);
  r.interrupt(1, 1, { late: true }); r.stateChange(2, { late: true });
  await sleep(5); assert.equal(h.events.length, count); assert.equal(r.releases, 1); assert.equal(r.starts, 1);
});

test('pause, permanent stop and mute focus events terminate once; resume cannot restart', async () => {
  for (const hint of [2, 3, 6]) {
    const h = pcmFixture(), s = h.make(); assert(await s.open()); const r = h.renderers[0];
    r.interrupt(hint); r.interrupt(1); r.interrupt(hint);
    assert.equal(s.write(bytes(1, 2)), -1);
    await until(() => terminals(h).length === 1);
    assert.equal(terminals(h)[0].kind, 'stopped'); assert.equal(r.starts, 1); assert.equal(r.releases, 1);
  }
});

test('an unexpected released renderer is a terminal error, not successful completion', async () => {
  const h = pcmFixture(), s = h.make(); assert(await s.open()); h.renderers[0].stateChange(4);
  await until(() => terminals(h).length === 1); assert.equal(terminals(h)[0].kind, 'error');
});

test('duck operations are ordered and close waits for a previous volume operation before release', async () => {
  const gate = deferred(), h = pcmFixture({ volume: () => gate.promise }), s = h.make(); assert(await s.open());
  const r = h.renderers[0], down = s.duck(true); await until(() => r.volumes.length === 1);
  const up = s.duck(false), stopping = s.stop(); await until(() => r.stops === 1);
  assert.equal(r.releases, 0); gate.resolve(); await Promise.all([down, up, stopping]);
  assert.deepEqual(r.volumes, [0.25]); assert.equal(r.releases, 1);
});

test('a later volume failure emits the existing error terminal', async () => {
  const h = pcmFixture({ volume: async () => { throw Error('volume'); } }), s = h.make(); assert(await s.open());
  await s.duck(true); await until(() => terminals(h).length === 1);
  assert.deepEqual(terminals(h), [{ kind: 'error', reason: 'volume' }]);
});

test('two concurrent opens cannot create two physical renderers', async () => {
  const gate = deferred(), h = pcmFixture({ create: () => gate.promise }), first = h.make(), second = h.make();
  const firstOpen = first.open(); await until(() => h.calls.includes('create'));
  assert.equal(await second.open(), false); assert.equal(h.calls.filter(c => c === 'create').length, 1);
  gate.resolve(); assert.equal(await firstOpen, true); await first.stop();
});

test('listener throws cannot turn completed cleanup into an unhandled rejection or duplicate event', async () => {
  const h = pcmFixture({ listenerThrows: true }), s = h.make(); assert(await s.open());
  s.write(bytes(1, 2, 3, 4, 5, 6, 7, 8)); h.renderers[0].pump(); await until(() => h.events.length === 1);
  await s.stop(); await s.stop(); assert.equal(terminals(h).length, 1); assert.equal(h.renderers[0].releases, 1);
});

test('drain rejection emits error and never done', async () => {
  const h = pcmFixture({ drain: async () => { throw Error('drain'); } }), s = h.make(); assert(await s.open());
  s.write(bytes(1, 2)); s.end(); const r = h.renderers[0]; r.pump(); r.pump();
  await until(() => terminals(h).length === 1);
  assert.deepEqual(terminals(h), [{ kind: 'error', reason: 'drain' }]); assert.equal(r.releases, 1);
});

test('owner invalidation during start fails open and releases without granting write admission', async () => {
  const gate = deferred(), h = pcmFixture({ start: () => gate.promise }), s = h.make();
  const opening = s.open(); await until(() => h.renderers[0]?.starts === 1);
  h.setCurrent(false); gate.resolve(); assert.equal(await opening, false);
  assert.equal(s.waiting(), -1); assert.equal(s.write(bytes(1, 2)), -1); assert.equal(h.renderers[0].releases, 1);
});

test('open with no PCM owns no application polling timer; callbacks with underrun create none', async () => {
  const h = pcmFixture(), s = h.make(); assert(await s.open()); const r = h.renderers[0];
  for (let i = 0; i < 10; i++) assert.equal(r.pump().result, -1);
  const before = h.calls.length; await sleep(25);
  assert.equal(h.calls.length, before); assert.equal(h.timers.size, 0); assert.deepEqual(h.events, []);
  await s.stop();
});

test('a retired one-use backend cannot return its cached successful open result', async () => {
  const h = pcmFixture(), s = h.make(); assert(await s.open()); await s.stop();
  assert.equal(await s.open(), false); assert.equal(h.renderers.length, 1); assert.equal(h.renderers[0].releases, 1);
});

test('focus loss after acquire resolves but before open result delivery cannot report playable', async () => {
  const h = pcmFixture({ formatHook(renderer) {
    if (renderer.formatChecks === 2) queueMicrotask(() => renderer.interrupt(3));
  } }), s = h.make();
  assert.equal(await s.open(), false);
  await until(() => h.renderers[0].releases === 1);
  assert.equal(terminals(h)[0].kind, 'stopped'); assert.equal(s.write(bytes(1, 2)), -1);
});

test('ordinary VALID buffers after the start event create no application control timer', async () => {
  const h = pcmFixture(), s = h.make(); assert(await s.open()); const r = h.renderers[0];
  s.write(new Uint8Array(32)); r.pump(); await until(() => h.events.some(e => e.kind === 'start'));
  assert.equal(h.timers.size, 0); assert.equal(r.pump().result, 0); assert.equal(h.timers.size, 0);
  assert.equal(r.pump().result, 0); assert.equal(h.timers.size, 0); await s.stop();
});

test('focus stateChange arriving before the interrupt still reports stopped and does not stop an already-stopped renderer', async () => {
  const h = pcmFixture({ stop: async renderer => {
    if (renderer.state === 3) throw Error('cannot stop twice');
  } }), s = h.make(); assert(await s.open()); const r = h.renderers[0];
  r.stateChange(3); r.interrupt(3);
  await until(() => terminals(h).length === 1);
  assert.equal(terminals(h)[0].kind, 'stopped'); assert.equal(r.stops, 0); assert.equal(r.releases, 1);
});

test('forced platform duck and unduck do not overwrite manual duck or resume playback', async () => {
  const h = pcmFixture(), s = h.make(); assert(await s.open()); const r = h.renderers[0];
  await s.duck(true); r.interrupt(4, 0); r.interrupt(5, 0); r.interrupt(1, 1);
  await sleep(5); assert.deepEqual(r.volumes, [0.25]); assert.equal(r.starts, 1); assert.equal(terminals(h).length, 0);
  await s.duck(false); assert.deepEqual(r.volumes, [0.25, 1]); await s.stop();
});

test('abort silences and discards queued output with pause then flush before stop and release', async () => {
  const h = pcmFixture(), s = h.make(); assert(await s.open()); const r = h.renderers[0];
  s.write(new Uint8Array(16)); r.pump();
  const offset = h.calls.length; await s.stop();
  assert.deepEqual(h.calls.slice(offset).filter(name => ['pause', 'flush', 'stop', 'release'].includes(name)),
    ['pause', 'flush', 'stop', 'release']);
  assert.equal(r.uncommitted.length, 0); assert.equal(r.committed.length, 0);
  assert.equal(terminals(h)[0].kind, 'stopped');
});

test('natural completion does not discard its tail with an abort flush', async () => {
  const h = pcmFixture(), s = h.make(); assert(await s.open()); const r = h.renderers[0];
  s.write(bytes(1, 2)); s.end(); r.pump(); r.pump();
  await until(() => terminals(h).length === 1);
  assert.equal(terminals(h)[0].kind, 'done'); assert.equal(r.drains, 1);
  assert.equal(r.pauses, 0); assert.equal(r.flushes, 0); assert.deepEqual([...r.committed[0]], [1, 2, 0, 0, 0, 0, 0, 0]);
});

test('abort pause or flush failures remain observable while release still runs', async () => {
  for (const option of [{ pause: async () => { throw Error('pause'); } }, { flush: async () => { throw Error('flush'); } }]) {
    const h = pcmFixture(option), s = h.make(); assert(await s.open()); await s.stop();
    assert.equal(terminals(h)[0].kind, 'error'); assert.equal(h.renderers[0].releases, 1);
  }
});

test('a forced stop winning during pause rejection is already quiet and still reports stopped', async () => {
  const h = pcmFixture({ pause: async renderer => { renderer.stateChange(3); throw Error('forced stopped'); } });
  const s = h.make(); assert(await s.open()); await s.stop(); const r = h.renderers[0];
  assert.equal(r.pauses, 1); assert.equal(r.stops, 0); assert.equal(r.releases, 1);
  assert.equal(terminals(h)[0].kind, 'stopped');
});
