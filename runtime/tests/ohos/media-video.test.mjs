import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { deferred, settle, until, videoFixture } from './media-video-fixture.mjs';

const count = (f, name) => f.calls.filter(c => c[0] === name).length;
async function open(f, attached) {
  const response = await f.call('open', { path: f.path }, attached).done;
  assert.equal(response.error, undefined, JSON.stringify(response));
  return response.value.texture;
}
async function close(f, texture, attached) {
  assert.deepEqual(await f.call('close', { texture }, attached).done, { value: null });
}
function retired(f) {
  assert.equal(f.fds.size, 0, 'all real FDs retired');
  assert.equal(f.textures.size, 0, 'all texture handles retired');
  assert(f.objects.every(o => o.released), 'all created media handles retired');
}

test('actual EntryAbility registers the Android media_video open contract', async t => {
  const f = await videoFixture(t);
  assert(f.channels.some(c => c.name === 'dsh/media_video'), 'CHAT_VIDEO_CHANNEL_MISSING');
  assert.equal(f.nativeLoads, 0, 'registration does not load native host');
  const opened = await f.call('open', { path: f.path }).done;
  assert.equal(opened.error, undefined);
  assert.deepEqual(opened.value, { texture: 1, width: 1920, height: 1080, durationMs: 5000 });
  assert.equal(f.players[0].volume, 1);
  assert.deepEqual(await f.call('close', { texture: 1 }).done, { value: null });
  retired(f);
});

test('seven method replies, texture lookup and unknown-method precedence match Android', async t => {
  const f = await videoFixture(t);
  assert.equal((await f.call('state', { texture: 9 }).done).error, 'closed');
  assert.equal((await f.call('unknown').done).error, 'closed');
  assert.deepEqual(await f.call('close', { texture: 9 }).done, { value: null });
  const texture = await open(f), player = f.players[0];
  assert.deepEqual(player.renderer, { usage: 10, rendererFlags: 0 });
  assert.equal(player.interruptMode, 1);
  assert.equal(player.loop, false);
  assert.deepEqual(await f.call('unknown', { texture }).done, { missing: true });
  assert.deepEqual(await f.call('state', { texture }).done,
    { value: { positionMs: 0, durationMs: 5000, playing: false } });
  assert.deepEqual(await f.call('play', { texture }).done, { value: null });
  assert.deepEqual(await f.call('play', { texture }).done, { value: null });
  assert.equal(count(f, 'player.play'), 1);
  assert.deepEqual(await f.call('pause', { texture }).done, { value: null });
  assert.deepEqual(await f.call('pause', { texture }).done, { value: null });
  assert.equal(count(f, 'player.pause'), 1);
  await close(f, texture); retired(f);
  assert.equal((await f.call('play', { texture }).done).error, 'closed');
});

test('seek clamps milliseconds and reports observed position, not requested frame accuracy', async t => {
  const f = await videoFixture(t), texture = await open(f), player = f.players[0];
  for (const [positionMs, target] of [[-4, 0], [7000, 5000], [1200.7, 1200]]) {
    assert.deepEqual(await f.call('seek', { texture, positionMs }).done, { value: null });
    assert.deepEqual(f.calls.findLast(c => c[0] === 'player.seek'), ['player.seek', target, 2]);
  }
  assert.equal((await f.call('state', { texture }).done).value.positionMs, 0);
  player.seekDone(1184);
  assert.equal((await f.call('state', { texture }).done).value.positionMs, 1184);
  player.emit('stateChange', 'completed');
  assert.equal((await f.call('state', { texture }).done).value.playing, false);
  await f.call('seek', { texture, positionMs: 0 }).done;
  await f.call('play', { texture }).done;
  assert.equal(player.state, 'playing');
  await close(f, texture); retired(f);
});

test('path roots match existing materialized files and native helper refuses symlink escapes', async t => {
  const f = await videoFixture(t);
  const roots = [f.context.cacheDir, f.context.tempDir, f.uiContext.cacheDir, f.uiContext.tempDir,
    f.context.filesDir + '/runtime/rootfs/root/workspace'];
  for (const root of roots) {
    const path = root + '/sample.mp4'; fs.writeFileSync(path, 'video');
    const result = await f.call('open', { path }).done;
    assert.equal(result.error, undefined); await close(f, result.value.texture);
  }
  const privateFile = f.context.filesDir + '/private.mp4'; fs.writeFileSync(privateFile, 'private');
  const launch = f.context.filesDir + '/launch'; fs.mkdirSync(launch); fs.writeFileSync(launch + '/clip.mp4', 'launch');
  fs.symlinkSync(privateFile, f.context.cacheDir + '/link.mp4');
  fs.symlinkSync(f.context.filesDir, f.context.cacheDir + '/linkdir');
  for (const path of [privateFile, launch + '/clip.mp4', 'https://example.test/v.mp4', 'relative.mp4',
    'file://' + f.path, f.context.cacheDir + '/../files/private.mp4', f.context.cacheDir + '//movie.mp4',
    f.context.cacheDir + '/link.mp4', f.context.cacheDir + '/linkdir/private.mp4', f.context.cacheDir + '/missing.mp4',
    f.context.cacheDir + '/']) {
    assert.equal((await f.call('open', { path }).done).error, 'invalid', path);
  }
  await settle(); retired(f);
});

test('invalid native file does not retire an already playing video', async t => {
  const f = await videoFixture(t), texture = await open(f), player = f.players[0];
  await f.call('play', { texture }).done;
  const hidden = f.context.filesDir + '/private.mp4'; fs.writeFileSync(hidden, 'private');
  fs.symlinkSync(hidden, f.context.cacheDir + '/link.mp4');
  for (const path of [f.context.cacheDir + '/missing.mp4', f.context.cacheDir + '/link.mp4']) {
    assert.equal((await f.call('open', { path }).done).error, 'invalid');
    await settle();
    assert.equal(player.released, false, 'invalid input must not close current playback');
    assert.equal((await f.call('state', { texture }).done).value.playing, true);
  }
  await close(f, texture); retired(f);
});

test('replacement during native validation keeps only one staged FD and preserves old controls', async t => {
  const f = await videoFixture(t), texture = await open(f), old = f.players[0], gate = deferred();
  await f.call('play', { texture }).done;
  f.change({ stat: () => gate.promise });
  const pending = f.call('open', { path: f.path });
  await until(() => count(f, 'fd.stat') === 2);
  assert.equal(f.fds.size, 2); assert.equal(old.state, 'playing');
  const latest = f.call('open', { path: f.path });
  assert.equal((await pending.done).error, 'closed'); await settle();
  assert.equal(f.fds.size, 2); assert.equal(count(f, 'fd.open'), 2, 'no third staged FD');
  f.background(); await until(() => old.state === 'paused');
  f.foreground(); gate.resolve();
  const next = (await latest.done).value.texture;
  assert(old.released); assert.equal(f.fds.size, 1); assert.equal(pending.replies.length, 1);
  await close(f, next); retired(f);
});

test('replacement during create waits for old physical owner and does not expose its late texture', async t => {
  const gate = deferred(), f = await videoFixture(t, { create: () => gate.promise });
  const first = f.call('open', { path: f.path });
  await until(() => count(f, 'player.create') === 1);
  const second = f.call('open', { path: f.path });
  assert.equal((await first.done).error, 'closed');
  await settle(); assert.equal(second.replies.length, 0); assert.equal(count(f, 'player.create'), 1);
  gate.resolve();
  const value = (await second.done).value;
  assert.equal(value.texture, 1, 'superseded create never registers a texture');
  assert.equal(f.players.length, 2); assert(f.players[0].released);
  assert.equal(first.replies.length, 1);
  f.players[0].late('stateChange', 'prepared');
  assert.equal(f.textures.size, 1); assert.equal(f.fds.size, 1);
  await close(f, value.texture); retired(f);
});

test('open timeout answers once but holds FD/surface until pending prepare settles', async t => {
  const gate = deferred(), f = await videoFixture(t, { prepare: () => gate.promise });
  const first = f.call('open', { path: f.path });
  await until(() => count(f, 'player.prepare') === 1);
  await f.tick(19999); assert.equal(first.replies.length, 0);
  await f.tick(1); assert.equal((await first.done).error, 'timeout');
  assert.equal(f.fds.size, 1); assert.equal(f.textures.size, 1); assert.equal(count(f, 'player.release'), 0);
  const second = f.call('open', { path: f.path }); await settle();
  assert.equal(count(f, 'player.create'), 1); assert.equal(second.replies.length, 0);
  gate.resolve(); const texture = (await second.done).value.texture;
  assert.equal(first.replies.length, 1); assert(f.players[0].released);
  await close(f, texture); retired(f);
});

test('engine replacement rejects stale callbacks and waits for old create retirement', async t => {
  const gate = deferred(), f = await videoFixture(t, { create: () => gate.promise });
  const oldHandler = f.methods.handler, request = f.call('open', { path: f.path });
  await until(() => count(f, 'player.create') === 1);
  const fresh = f.attach();
  assert.equal((await request.done).error, 'closed');
  const replacement = f.call('open', { path: f.path }, fresh); await settle();
  assert.equal(count(f, 'player.create'), 1);
  const stale = deferred();
  oldHandler.onMethodCall({ method: 'open', argument: () => f.path }, {
    success: value => stale.resolve({ value }), error: code => stale.resolve({ error: code }), notImplemented: () => stale.resolve({ missing: true }),
  });
  assert.equal((await stale.promise).error, 'closed');
  gate.resolve(); const texture = (await replacement.done).value.texture;
  f.detach();
  assert.equal((await f.call('state', { texture }, fresh).done).value.playing, false);
  await close(f, texture, fresh); retired(f);
});

test('background while play is pending settles paused; foreground does not resume', async t => {
  const gate = deferred(), f = await videoFixture(t, { play: () => gate.promise });
  const texture = await open(f), playing = f.call('play', { texture });
  await until(() => count(f, 'player.play') === 1);
  f.background(); gate.resolve();
  assert.deepEqual(await playing.done, { value: null }); await settle();
  assert.equal(f.players[0].state, 'paused');
  assert.equal((await f.call('play', { texture }).done).error, 'background');
  f.foreground(); await settle(); assert.equal(count(f, 'player.play'), 1);
  await close(f, texture); retired(f);
});

test('FORCE and SHARE PAUSE/STOP/DUCK pause actual player; RESUME/UNDUCK never autoplay', async t => {
  const f = await videoFixture(t), texture = await open(f), player = f.players[0];
  for (const forceType of [0, 1]) for (const hint of [2, 3, 4]) {
    await f.call('play', { texture }).done;
    player.interrupt(hint, forceType);
    assert.equal(player.state, 'playing', 'SDK event alone did not change state');
    await until(() => player.state === 'paused');
    const starts = count(f, 'player.play');
    player.interrupt(1, 1); player.interrupt(5, forceType); await settle();
    assert.equal(count(f, 'player.play'), starts);
  }
  await close(f, texture); retired(f);
});

test('focus interruption during pending play suppresses late playback', async t => {
  const gate = deferred(), f = await videoFixture(t, { play: () => gate.promise });
  const texture = await open(f), response = f.call('play', { texture });
  await until(() => count(f, 'player.play') === 1);
  f.players[0].interrupt(4, 0); gate.resolve(); await response.done;
  await until(() => f.players[0].state === 'paused');
  await close(f, texture); retired(f);
});

test('player release failure preserves ownership and a later close can retry', async t => {
  const f = await videoFixture(t, { playerRelease: () => { throw Error('release unavailable'); } });
  const texture = await open(f);
  assert.equal((await f.call('close', { texture }).done).error, 'playback');
  assert.equal(f.fds.size, 1); assert.equal(f.textures.size, 1); assert(!f.players[0].released);
  assert.equal((await f.call('state', { texture }).done).error, 'closed');
  assert.equal((await f.call('open', { path: f.path }).done).error, 'unsupported');
  assert.equal(count(f, 'player.create'), 1, 'new decoder cannot overtake failed release');
  f.change({ playerRelease: undefined });
  await close(f, texture); retired(f);
  await close(f, await open(f)); retired(f);
});

test('FD close failure does not unregister texture and retry does not re-release player', async t => {
  const f = await videoFixture(t, { fdClose: () => { throw Error('close unavailable'); } });
  const texture = await open(f);
  assert.equal((await f.call('close', { texture }).done).error, 'playback');
  assert.equal(f.fds.size, 1); assert.equal(f.textures.size, 1); assert(f.players[0].released);
  f.change({ fdClose: undefined }); await close(f, texture);
  assert.equal(count(f, 'player.release'), 1); retired(f);
});

test('async player error closes resource; unclassified play failure remains playback', async t => {
  const f = await videoFixture(t), texture = await open(f);
  f.players[0].emit('error', { code: 5400102, message: 'operation failed' });
  await until(() => f.fds.size === 0); retired(f);
  assert.equal((await f.call('state', { texture }).done).error, 'closed');
  const next = await open(f);
  f.change({ play: () => { throw Object.assign(Error('unclassified SDK failure'), { code: 5400107 }); } });
  assert.equal((await f.call('play', { texture: next }).done).error, 'playback');
  await until(() => f.fds.size === 0); retired(f);
});

test('poster serializes FD service ownership, bounds longest side 512 and requests JPEG quality 80', async t => {
  const f = await videoFixture(t);
  const result = await f.call('poster', { path: f.path }).done;
  assert.deepEqual(result, { value: Uint8Array.from([255, 216, 255, 217]) });
  assert.deepEqual(f.calls.find(c => c[0] === 'generator.frame'), ['generator.frame', 0, 2, { width: 512, height: 288 }]);
  assert.deepEqual(f.calls.find(c => c[0] === 'packer.pack'), ['packer.pack', { format: 'image/jpeg', quality: 80 }]);
  assert(f.calls.findIndex(c => c[0] === 'extractor.release') < f.calls.findIndex(c => c[0] === 'generator.create'));
  assert(f.calls.findIndex(c => c[0] === 'packer.release') < f.calls.findIndex(c => c[0] === 'pixels.release'));
  retired(f);
});

test('poster rejects unsupported metadata and a codec ignoring target size without creating packer', async t => {
  const f = await videoFixture(t, { posterWidth: 0 });
  assert.deepEqual(await f.call('poster', { path: f.path }).done, { value: null });
  assert.equal(count(f, 'generator.create'), 0); retired(f);
  f.change({ posterWidth: 1920, frameWidth: 1920, frameHeight: 1080 });
  assert.deepEqual(await f.call('poster', { path: f.path }).done, { value: null });
  assert.equal(count(f, 'packer.create'), 0); retired(f);
  f.change({ posterWidth: 120, posterHeight: 80, frameWidth: undefined, frameHeight: undefined });
  assert((await f.call('poster', { path: f.path }).done).value instanceof Uint8Array);
  assert.deepEqual(f.calls.findLast(c => c[0] === 'generator.frame').at(-1), { width: 120, height: 80 });
  retired(f);
});

test('poster timeout retains one in-flight decoder; busy returns null and playback remains independent', async t => {
  const gate = deferred(), f = await videoFixture(t, { frame: () => gate.promise });
  const first = f.call('poster', { path: f.path });
  await until(() => count(f, 'generator.frame') === 1);
  await f.tick(9999); assert.equal(first.replies.length, 0);
  await f.tick(1); assert.equal((await first.done).error, 'timeout');
  assert.equal(f.fds.size, 1); assert(!f.objects.find(o => o.kind === 'generator').released);
  assert.deepEqual(await f.call('poster', { path: f.path }).done, { value: null });
  assert.equal(count(f, 'generator.create'), 1);
  const texture = await open(f); assert.equal(f.fds.size, 2);
  gate.resolve(); await until(() => f.objects.find(o => o.kind === 'generator').released);
  await settle(); assert.equal(first.replies.length, 1); assert.equal(count(f, 'packer.create'), 0);
  assert((await f.call('poster', { path: f.path }).done).value instanceof Uint8Array);
  await close(f, texture); retired(f);
});

test('poster encoding timeout keeps PixelMap until encoding finishes and answers once', async t => {
  const gate = deferred(), f = await videoFixture(t, { pack: () => gate.promise });
  const first = f.call('poster', { path: f.path });
  await until(() => count(f, 'packer.pack') === 1);
  await f.tick(10000); assert.equal((await first.done).error, 'timeout');
  assert(!f.objects.find(o => o.kind === 'pixels').released);
  assert(!f.objects.find(o => o.kind === 'packer').released);
  assert.deepEqual(await f.call('poster', { path: f.path }).done, { value: null });
  gate.resolve(); await until(() => f.fds.size === 0);
  assert.equal(first.replies.length, 1); retired(f);
});

test('poster failed release retains one owner and next request retries before any new decoder', async t => {
  const f = await videoFixture(t, { generatorRelease: () => { throw Error('release unavailable'); } });
  assert.deepEqual(await f.call('poster', { path: f.path }).done, { value: null });
  assert.equal(f.fds.size, 1); assert.equal(count(f, 'generator.create'), 1);
  assert.deepEqual(await f.call('poster', { path: f.path }).done, { value: null });
  assert.equal(count(f, 'extractor.create'), 1);
  f.change({ generatorRelease: undefined });
  assert((await f.call('poster', { path: f.path }).done).value instanceof Uint8Array);
  assert.equal(count(f, 'extractor.create'), 2); retired(f);
});
