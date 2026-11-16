import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { speechChannelFixture, deferred, until } from './speech-channel-fixture.mjs';

const call = (fixture, name, args) => fixture.call(fixture.methods, name, args).done;
const open = (fixture, id = 'ds1', extra = {}) => call(fixture, 'open', { id, rate: 24000, call: false, levels: false, ...extra });
const success = reply => assert.equal(reply.error, undefined, JSON.stringify(reply));
const contract = JSON.parse(fs.readFileSync(new URL('./speech-channel-contract.json', import.meta.url), 'utf8'));

test('actual EntryAbility registers the dsh/speech playback protocol', async () => {
  const fixture = speechChannelFixture();
  const opened = await open(fixture);
  assert.deepEqual(opened, { value: true }, 'SPEECH_CHANNEL_NOT_REGISTERED_OR_UNAVAILABLE');
  assert.equal(fixture.channels.filter(channel => channel.name === contract.channel).length, 1);
  assert.equal(fixture.channels.some(channel => channel.name === 'dsh/speech/events'), false);
  assert.equal(fixture.plugin.getUniqueClassName(), 'DshSpeechPlugin');
  assert.deepEqual(fixture.streams[0].configuration, { rate: 24000, call: false, levels: false, speaker: true });
  assert.equal(contract.referenceCommit, 'dd130b31061e305cd9c06e103c3e5210fee1922f');
  assert.equal(contract.pcm.sampleRate, fixture.streams[0].configuration.rate);
  success(await call(fixture, 'stop'));
});

test('failed open reports play:error before cleanup can look like a normal stop', async () => {
  const fixture = speechChannelFixture({ openFalse: true });
  assert.deepEqual(await open(fixture), { value: false });
  assert.deepEqual(fixture.events.map(event => event.what), ['error']);
  assert.equal(fixture.streams[0].closed, true);
});

test('new engine can retry a retired engine physical release failure before creating a stream', async () => {
  const fixture = speechChannelFixture({ stop: () => { throw Error('physical renderer still owned'); } });
  assert.deepEqual(await open(fixture), { value: true });
  const old = fixture.streams[0];
  const next = fixture.attach();
  await until(() => old.stops === 1);
  assert.deepEqual(await fixture.call(next.methods, 'open', { id: 'ds2', rate: 24000 }).done, { value: false });
  assert.equal(fixture.streams.length, 1, 'new renderer must not be constructed while an old release failed');
  fixture.change({ stop: undefined });
  success(await fixture.call(next.methods, 'stop').done);
  assert.equal(old.closed, true);
  assert.deepEqual(await fixture.call(next.methods, 'open', { id: 'ds2', rate: 24000 }).done, { value: true });
  success(await fixture.call(next.methods, 'stop').done);
});

test('PCM bytes, waiting, EOF and terminal events follow the same method channel', async () => {
  const fixture = speechChannelFixture();
  assert.deepEqual(await open(fixture), { value: true });
  assert.equal(fixture.events.length, 0, 'preflight alone is not audible playback');
  const stream = fixture.streams[0];
  const a = Uint8Array.from([0, 255, 3]), b = Uint8Array.from([128, 4]);
  assert.deepEqual(await call(fixture, 'write', { id: 'ds1', bytes: a }), { value: 3 });
  assert.deepEqual(await call(fixture, 'write', { id: 'ds1', bytes: b }), { value: 5 });
  assert.deepEqual(await call(fixture, 'waiting', { id: 'ds1' }), { value: 5 });
  assert.deepEqual(stream.chunks, [a, b]);
  stream.startEvent(); stream.startEvent();
  success(await call(fixture, 'duck', { id: 'ds1', on: true }));
  success(await call(fixture, 'duck', { id: 'ds1', on: false }));
  assert.deepEqual(stream.ducks, [true, false]);
  success(await call(fixture, 'end', { id: 'ds1' }));
  assert.equal(stream.finished, true);
  assert.deepEqual(await call(fixture, 'write', { id: 'ds1', bytes: a }), { value: -1 });
  stream.notice('done'); stream.late('error'); stream.startEvent();
  assert.deepEqual(fixture.events.map(({ method, type, what, id }) => ({ method, type, what, id })), [
    { method: 'event', type: 'play', what: 'start', id: 'ds1' },
    { method: 'event', type: 'play', what: 'done', id: 'ds1' },
  ]);
  for (const event of fixture.events) {
    assert.equal(event.method, contract.eventMethod); assert.equal(event.type, contract.eventType);
    assert(contract.playPhases.includes(event.what));
  }
  assert.deepEqual(await call(fixture, 'waiting', { id: 'ds1' }), { value: -1 });
  success(await call(fixture, 'stop'));
});

test('unsupported rate and malformed options fail before renderer creation; absent capture capability is explicit', async () => {
  const fixture = speechChannelFixture();
  for (const extra of [{ rate: 48000 }, { rate: '24000' }, { call: 'false' }, { levels: 'true' }]) {
    assert.deepEqual(await open(fixture, 'ds1', extra), { value: false });
  }
  assert.deepEqual(await call(fixture, 'open', { rate: 24000 }), { value: false });
  assert.equal(fixture.streams.length, 0);
  assert.deepEqual(await call(fixture, 'callStart', { bargeIn: true }), { value: 'unavailable' });
  assert.deepEqual(await call(fixture, 'callSpeaker', { on: true }), { value: true }); // next-call preference, no renderer
  for (const method of ['callStop', 'callMute', 'callBargeIn', 'callPlaying']) success(await call(fixture, method, { on: true }));
  assert.deepEqual(await call(fixture, 'capabilities'), { missing: true }, 'do not invent an unconsumed capability protocol');
  assert.equal(fixture.streams.length, 0);
});

test('stale stream IDs never write, end or duck the current stream', async () => {
  const fixture = speechChannelFixture(); await open(fixture, 'new');
  for (const method of ['write', 'waiting']) assert.deepEqual(await call(fixture, method, { id: 'old', bytes: new Uint8Array(2) }), { value: -1 });
  for (const method of ['end', 'duck']) success(await call(fixture, method, { id: 'old', on: true }));
  assert.equal(fixture.streams[0].bytes, 0); assert.equal(fixture.streams[0].finished, false);
  assert.equal(fixture.streams[0].ducks.length, 0);
  success(await call(fixture, 'stop'));
});

test('malformed PCM reports play:error and physically closes instead of only returning a swallowed error', async () => {
  const fixture = speechChannelFixture(); await open(fixture);
  assert.deepEqual(await call(fixture, 'write', { id: 'ds1', bytes: [0, 1] }), { value: -1 });
  assert.deepEqual(fixture.events.map(event => event.what), ['error']);
  assert.equal(fixture.streams[0].closed, true);
});

test('stop during pending open invalidates immediately, waits for close, and cannot later start', async () => {
  const gate = deferred(), fixture = speechChannelFixture({ open: () => gate.promise });
  const pending = fixture.call(fixture.methods, 'open', { id: 'ds1' });
  await until(() => fixture.streams.length === 1);
  const stream = fixture.streams[0], stopped = fixture.call(fixture.methods, 'stop');
  assert.equal(stream.current(), false); stream.startEvent();
  assert.equal(fixture.events.length, 0); assert.equal(stopped.replies.length, 0);
  gate.resolve();
  assert.deepEqual(await pending.done, { value: false }); success(await stopped.done);
  assert.equal(stream.closed, true); assert.equal(stream.accepting, false);
  assert.deepEqual(fixture.events.map(event => event.what), ['stopped']);
});

test('latest replacement wins while physical close is pending and old callbacks cannot target reused id', async () => {
  const release = deferred(), fixture = speechChannelFixture({ stop: () => release.promise });
  await open(fixture, 'same'); const old = fixture.streams[0];
  const second = fixture.call(fixture.methods, 'open', { id: 'middle' });
  const latest = fixture.call(fixture.methods, 'open', { id: 'same' });
  assert.equal(fixture.streams.length, 1); assert.equal(old.current(), false);
  release.resolve();
  assert.deepEqual(await second.done, { value: false }); assert.deepEqual(await latest.done, { value: true });
  assert.equal(fixture.streams.length, 2);
  const before = fixture.events.length; old.late(); old.startEvent();
  assert.equal(fixture.events.length, before);
  fixture.streams[1].startEvent();
  assert.equal(fixture.events.at(-1).what, 'start');
  assert.equal(fixture.streams[1].current(), true);
  success(await call(fixture, 'stop'));
});

test('background and destroy stop playback; a stale Ability cannot revoke a new one', async () => {
  const fixture = speechChannelFixture(); await open(fixture);
  const old = fixture.streams[0]; fixture.background();
  assert.equal(old.current(), false); await until(() => old.closed);
  assert.deepEqual(await open(fixture, 'background'), { value: false });
  const next = fixture.attach();
  assert.deepEqual(await fixture.call(next.methods, 'open', { id: 'new' }).done, { value: true });
  const current = fixture.streams.at(-1); fixture.background();
  assert.equal(current.current(), true);
  next.destroy(); assert.equal(current.current(), false); await until(() => current.closed);
});

test('same plugin engine replacement never emits late old events into the new messenger', async () => {
  const fixture = speechChannelFixture(); await open(fixture); const old = fixture.streams[0];
  const next = fixture.attach(fixture.plugin);
  assert.deepEqual(await fixture.call(next.methods, 'open', { id: 'ds1' }).done, { value: true });
  const before = fixture.events.length; old.startEvent(); old.late('error');
  fixture.plugin.onDetachedFromEngine(fixture.engine); // late detach for the old binding
  assert.equal(fixture.events.length, before);
  assert.equal(fixture.streams.at(-1).current(), true);
  success(await fixture.call(next.methods, 'stop').done);
});

test('release failure has one error event, refuses new open, and remains retryable by stop', async () => {
  const fixture = speechChannelFixture({ stop: () => { throw Error('not closed'); } });
  await open(fixture);
  assert.equal((await call(fixture, 'stop')).error, 'speech-output');
  assert.deepEqual(fixture.events.map(event => event.what), ['error']);
  assert.deepEqual(await open(fixture, 'next'), { value: false }); assert.equal(fixture.streams.length, 1);
  fixture.change({ stop: undefined }); success(await call(fixture, 'stop'));
  assert.equal(fixture.streams[0].closed, true);
  assert.deepEqual(fixture.events.map(event => event.what), ['error']);
  assert.deepEqual(await open(fixture, 'next'), { value: true }); success(await call(fixture, 'stop'));
});

test('retired event transport and method reply do not trigger a second reply or retain playback', async () => {
  const fixture = speechChannelFixture({ eventFailure: true, replyFailure: true });
  const opened = fixture.call(fixture.methods, 'open', { id: 'ds1' });
  assert.deepEqual(await opened.done, { value: true }); assert.equal(opened.replies.length, 1);
  fixture.streams[0].startEvent(); fixture.streams[0].startEvent();
  const stopped = fixture.call(fixture.methods, 'stop'); success(await stopped.done);
  assert.equal(stopped.replies.length, 1); assert.equal(fixture.streams[0].closed, true);
});

// This coordinator is a DESIGN MODEL only. The pinned dd130b31 Dart source does
// not await native open before synthesize; these cases cannot certify that app.
class PreflightDesignModel {
  constructor(fixture) { this.fixture = fixture; this.pending = null; this.cancelled = false; this.syntheses = 0; }
  async synthesize() {
    const opened = await (this.pending ??= open(this.fixture));
    if (this.cancelled || opened.value !== true) return false;
    this.syntheses++; return true;
  }
  async stop() { this.cancelled = true; await call(this.fixture, 'stop'); }
}

test('design model only: failed native open permits zero billable synthesis entries', async () => {
  for (const options of [{ openFalse: true }, { open: () => { throw Error('create/start failed'); } }]) {
    const fixture = speechChannelFixture(options), model = new PreflightDesignModel(fixture);
    assert.deepEqual(await Promise.all([model.synthesize(), model.synthesize(), model.synthesize()]), [false, false, false]);
    assert.equal(model.syntheses, 0); assert.equal(fixture.streams.length, 1);
  }
});

test('design model only: stop during native preflight permits zero synthesis entries', async () => {
  const gate = deferred(), fixture = speechChannelFixture({ open: () => gate.promise });
  const model = new PreflightDesignModel(fixture), first = model.synthesize();
  await until(() => fixture.streams.length === 1); const stopped = model.stop();
  gate.resolve(); await stopped; assert.equal(await first, false); assert.equal(model.syntheses, 0);
  assert.equal(fixture.streams[0].closed, true);
});

test('design model only: concurrent pieces share one successful native preflight', async () => {
  const fixture = speechChannelFixture(), model = new PreflightDesignModel(fixture);
  assert.deepEqual(await Promise.all([model.synthesize(), model.synthesize(), model.synthesize()]), [true, true, true]);
  assert.equal(fixture.streams.length, 1); assert.equal(model.syntheses, 3); await model.stop();
});
