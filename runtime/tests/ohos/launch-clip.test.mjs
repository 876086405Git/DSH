import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { launchFixture, barrier } from './launch-clip-fixture.mjs';
const repo = fileURLToPath(new URL('../../../', import.meta.url));
const settle = () => new Promise(resolve => setImmediate(resolve));
function rig(t, options) {
  const root = fs.mkdtempSync(resolve(os.tmpdir(), 'dsh-launch-clip-'));
  fs.mkdirSync(root + '/launch');
  const path = root + '/launch/custom-1.mp4', poster = root + '/launch/custom-1-poster.png';
  fs.writeFileSync(path, Buffer.from('synthetic input: MediaKit decoding is an explicit fixture boundary'));
  const f = launchFixture(repo, root, options);
  t.after(async () => { f.state.failRelease = false; f.detach(); await settle();
    assert.equal(f.fds.size, 0, 'all real descriptors released');
    assert.equal(f.textures.size, 0, 'all registered textures unregistered');
    fs.rmSync(root, { recursive: true, force: true }); });
  return { ...f, root, path, poster };
}

test('launch probe uses the actual registry, metadata, bounded PNG and exclusive media FD ownership', async t => {
  const f = rig(t);
  assert.deepEqual([...f.channels.keys()], ['dsh/launch', 'dsh/launch_clip']);
  const result = await f.invoke('probe', { path: f.path, poster: f.poster });
  assert.deepEqual(result, { value: { durationMs: 2900, width: 1080, height: 1920 } });
  const png = fs.readFileSync(f.poster);
  assert.deepEqual([...png.subarray(0, 8)], [137,80,78,71,13,10,26,10]);
  assert.equal(png.readUInt32BE(16), 810); assert.equal(png.readUInt32BE(20), 1440);
  assert.equal(f.fds.size, 0); assert.ok(f.objects.every(object => object.released));
  assert.ok(f.calls.findIndex(c => c.kind === 'extractor.release') < f.calls.findIndex(c => c.kind === 'generator.create'));
  assert.deepEqual(fs.readdirSync(f.root + '/launch').sort(), ['custom-1-poster.png', 'custom-1.mp4']);
  f.state.frameError = true;
  const failure = await f.invoke('probe', { path: f.path, poster: f.root + '/launch/new-poster.png' });
  assert.equal(failure.value, null); assert.deepEqual(fs.readFileSync(f.poster), png, 'old poster unchanged');
  f.state.frameError = false; f.state.metadata = { videoWidth: '0', videoHeight: '0' };
  assert.equal((await f.invoke('probe', { path: f.path, poster: f.root + '/launch/audio.png' })).value, null);
});

test('launch playback uses the real embedding register/unregister path, waits for play and reports done once', async t => {
  const f = rig(t);
  const opened = await f.invoke('open', { path: f.path }), id = opened.value.texture;
  assert.ok(Number.isSafeInteger(id)); assert.equal(f.textures.size, 1);
  assert.equal(f.calls.filter(c => c.kind === 'player.play').length, 0);
  assert.equal(f.players[0].surfaceId, '123456'); assert.equal(f.players[0].loop, false);
  assert.equal(f.calls.find(c => c.kind === 'player.volume').value, 0);
  assert.deepEqual(f.calls.find(c => c.kind === 'texture.size').value, { id, width: 1080, height: 1920 });
  assert.equal((await f.invoke('play', { texture: id })).value, true);
  await f.invoke('play', { texture: id });
  assert.equal(f.calls.filter(c => c.kind === 'player.play').length, 1);
  assert.deepEqual(f.events.map(e => e.method), ['showing']);
  f.players[0].emit('stateChange', 'completed'); f.players[0].emit('error', new Error('late'));
  assert.deepEqual(f.events.map(e => e.method), ['showing', 'done']);
  assert.equal(f.textures.size, 1, 'last texture remains until Dart closes it');
  await f.invoke('close', { texture: id }); await f.invoke('close', { texture: id });
  assert.ok(f.calls.findIndex(c => c.kind === 'player.release') < f.calls.findIndex(c => c.kind === 'texture.release'));
  const next = (await f.invoke('open', { path: f.path })).value.texture;
  f.state.playError = true;
  assert.equal((await f.invoke('play', { texture: next })).value, false);
  assert.equal(f.events.filter(e => e.method === 'done' && e.arguments.texture === next).length, 1);
  await f.invoke('close', { texture: next });
});

test('launch files reject traversal and symlinks, and follow the shipped path_provider ability context', async t => {
  const f = rig(t);
  fs.symlinkSync(f.path, f.root + '/launch/link.mp4');
  assert.equal((await f.invoke('open', { path: f.root + '/launch/link.mp4' })).value, null);
  assert.equal((await f.invoke('open', { path: f.root + '/launch/../launch/custom-1.mp4' })).value, null);
  const victim = f.root + '/outside'; fs.writeFileSync(victim, 'KEEP'); fs.symlinkSync(victim, f.poster);
  assert.equal((await f.invoke('probe', { path: f.path, poster: f.poster })).value, null);
  assert.equal(fs.readFileSync(victim, 'utf8'), 'KEEP');
  const abilityRoot = f.root + '/ability'; fs.mkdirSync(abilityRoot); fs.mkdirSync(abilityRoot + '/launch');
  const abilityPath = abilityRoot + '/launch/clip.mp4'; fs.copyFileSync(f.path, abilityPath);
  f.attachAbility(abilityRoot);
  assert.equal((await f.invoke('open', { path: f.path })).value, null);
  const id = (await f.invoke('open', { path: abilityPath })).value.texture;
  await f.invoke('close', { texture: id });
});

test('launch detach retires real in-flight media creation and cannot publish a late texture or poster', async t => {
  const playerGate = barrier(), f = rig(t, { playerGate });
  const opening = f.invoke('open', { path: f.path });
  await settle(); assert.ok(f.calls.some(c => c.kind === 'player.create'));
  f.detach(); playerGate.release();
  assert.equal((await opening).value, null); await settle();
  assert.equal(f.fds.size, 0); assert.equal(f.textures.size, 0);
  assert.equal(f.players.length, 1); assert.equal(f.players[0].released, true);
  const extractorGate = barrier(), other = rig(t, { extractorGate });
  const probing = other.invoke('probe', { path: other.path, poster: other.poster });
  await settle(); other.detach(); extractorGate.release();
  assert.equal((await probing).value, null); await settle();
  assert.equal(fs.existsSync(other.poster), false); assert.equal(other.fds.size, 0);
});

test('launch failed media release retains its live FD and texture until explicit close succeeds', async t => {
  const f = rig(t);
  const id = (await f.invoke('open', { path: f.path })).value.texture;
  f.state.failRelease = true;
  assert.equal((await f.invoke('close', { texture: id })).error, 'close');
  assert.equal(f.fds.size, 1); assert.equal(f.textures.size, 1);
  for (const fd of f.fds) assert.ok(fs.fstatSync(fd).isFile());
  assert.equal(f.calls.filter(c => c.kind === 'texture.release').length, 0);
  f.state.failRelease = false;
  assert.equal((await f.invoke('close', { texture: id })).value, null);
  assert.equal(f.fds.size, 0); assert.equal(f.textures.size, 0);
});
