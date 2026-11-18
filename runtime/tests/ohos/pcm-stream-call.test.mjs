import test from 'node:test';
import assert from 'node:assert/strict';
import { pcmFixture, until } from './pcm-stream-fixture.mjs';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const levels = h => h.events.filter(event => event.kind === 'level');
function pcm(samples, value = 8192) {
  const bytes = new Uint8Array(samples * 2), view = new DataView(bytes.buffer);
  for (let at = 0; at < samples; at++) view.setInt16(at * 2, at % 2 ? -value : value, true);
  return bytes;
}

test('call PCM uses the communication usage and preserves ordinary media usage', async () => {
  for (const call of [true, false]) {
    const h = pcmFixture(), s = h.make({ call });
    try {
      assert.equal(await s.open(), true, 'call playback must open before paid synthesis');
      assert.equal(h.renderers[0].settings.rendererInfo.usage, call ? 2 : 12);
      assert.equal(h.renderers[0].starts, 1);
    } finally { await s.stop(); }
  }
});

test('40ms levels wait for actual framePos, never callback submission or wall clock alone', async () => {
  const h = pcmFixture(), s = h.make({ call: true, levels: true });
  try {
    assert.equal(await s.open(), true);
    const r = h.renderers[0];
    s.write(pcm(1920)); r.pump(1920); r.pump(1920);
    await until(() => r.timestampReads > 0);
    await sleep(85); assert.equal(levels(h).length, 0, 'submitted data is not heard data');
    r.framePos = 959; await sleep(45); assert.equal(levels(h).length, 0);
    r.framePos = 960; await until(() => levels(h).length === 1);
    assert(Math.abs(levels(h)[0].value - ((20 * Math.log10(0.25) + 50) / 40)) < 1e-12);
    r.framePos = 1920; await until(() => levels(h).length === 2);
    const reads = r.timestampReads; await sleep(85);
    assert.equal(r.timestampReads, reads, 'no level polling without pending audio');
  } finally { await s.stop(); }
  assert.equal(h.timers.size, 0);
});

test('levels count signed samples across callback boundaries and never count EOF padding', async () => {
  const h = pcmFixture(), s = h.make({ levels: true });
  try {
    assert.equal(await s.open(), true);
    const r = h.renderers[0];
    s.write(pcm(1100, 32767)); r.pump(400); r.pump(1520);
    r.framePos = 960; await until(() => levels(h).length === 1);
    assert.equal(levels(h)[0].value, 1);
    s.end(); r.pump(1920); r.framePos = 1920;
    await sleep(85); assert.equal(levels(h).length, 1, '140 payload samples plus padding are not 40ms of speech');
    r.pump(); await until(() => h.events.some(e => e.kind === 'done'));
  } finally { await s.stop(); }
  assert.equal(h.timers.size, 0);
});

test('stop cancels heard-time work before any delayed level can escape', async () => {
  const h = pcmFixture(), s = h.make({ levels: true });
  assert.equal(await s.open(), true);
  const r = h.renderers[0]; s.write(pcm(960)); r.pump(1920);
  await until(() => r.timestampReads > 0);
  await s.stop(); r.framePos = 960; await sleep(85);
  assert.equal(levels(h).length, 0); assert.equal(h.timers.size, 0); assert.equal(r.releases, 1);
});

test('a reset playback position is an explicit stream error, not fabricated heard progress', async () => {
  const h = pcmFixture(), s = h.make({ levels: true });
  try {
    assert.equal(await s.open(), true);
    const r = h.renderers[0]; s.write(pcm(2880)); r.pump(5760);
    r.framePos = 960; await until(() => levels(h).length === 1);
    r.framePos = 0;
    await until(() => h.events.some(e => e.kind === 'error'));
    assert.equal(levels(h).length, 1);
    assert.equal(h.events.find(e => e.kind === 'error').reason, 'playback-position-reset');
  } finally { await s.stop(); }
});

test('ordinary playback does not query hardware progress or schedule level work', async () => {
  const h = pcmFixture(), s = h.make();
  try {
    assert.equal(await s.open(), true);
    s.write(pcm(960)); h.renderers[0].pump(1920);
    await until(() => h.events.some(e => e.kind === 'start'));
    await sleep(85);
    assert.equal(h.renderers[0].timestampReads, 0); assert.equal(levels(h).length, 0);
  } finally { await s.stop(); }
});


test('a route reset between timestamp polls cannot masquerade as later PCM progress', async () => {
  const h = pcmFixture(), s = h.make({ call: true, levels: true });
  try {
    assert.equal(await s.open(), true);
    const r = h.renderers[0]; s.write(pcm(2880)); r.pump(5760);
    r.framePos = 960; await until(() => levels(h).length === 1);
    r.listeners.get('outputDeviceChangeWithInfo')?.({ devices: [], changeReason: 1 });
    r.framePos = 1920;
    await until(() => h.events.some(e => e.kind === 'error'));
    assert.equal(levels(h).length, 1);
    assert.equal(h.events.find(e => e.kind === 'error').reason, 'playback-route-changed');
  } finally { await s.stop(); }
  assert.equal(h.timers.size, 0);
});


test('speaker routing uses the current communication renderer and surfaces SDK failure', async () => {
  const h = pcmFixture(), s = h.make({ call: true, speaker: false });
  try {
    assert.equal(await s.open(), true);
    const r = h.renderers[0];
    assert.deepEqual(r.outputDevices, [1]);
    await s.setSpeaker(true); assert.deepEqual(r.outputDevices, [1, 2]);
    h.change({ outputDevice: () => { throw Error('route refused'); } });
    await assert.rejects(s.setSpeaker(false), /route refused/);
    assert.deepEqual(r.outputDevices, [1, 2]);
  } finally { await s.stop(); }
  assert.equal(h.timers.size, 0);
});

test('route setup failure is false before synthesis and closes the created renderer', async () => {
  const h = pcmFixture({ outputDevice: () => { throw Error('route refused'); } });
  const s = h.make({ call: true });
  try {
    assert.equal(await s.open(), false);
    assert.equal(h.renderers[0].starts, 0); assert.equal(h.renderers[0].releases, 1);
    assert.equal(h.events.find(e => e.kind === 'error').kind, 'error');
  } finally { await s.stop(); }
});
