// Cumulative 1303+1304: actual capture/tap and ASR service/channel bodies.
// The small forwarding function is the explicit Flutter/Dart transport boundary;
// actual Dart consumer ownership and reset behavior run separately under Flutter.
import test from 'node:test';
import assert from 'node:assert/strict';
import { asrFixture } from './system-asr-fixture.mjs';
import { captureFixture, pcm, settle } from './call-capture-fixture.mjs';

test('the existing communication capturer sends exact owned PCM to external system ASR', async () => {
  const input = captureFixture(), call = input.make(), recognition = asrFixture(), channel = recognition.attach();
  const { VoicePcmTap } = input.load('VoicePcmTap'), forwards = [];
  const tap = VoicePcmTap.enable('call', 91, (_tap, bytes) => forwards.push(channel.invoke('feed', { run: 91, bytes })));
  try {
    await channel.invoke('start', { run: 91 });
    await call.start();
    assert.equal(input.capturers.length, 1);
    assert.equal(input.capturers[0].config.capturerInfo.source, 7);
    assert.equal(recognition.engines[0].starts[0].extraParams.recognitionMode, 1);
    const bytes = pcm(-12345);
    input.capturers[0].data(bytes.subarray(0, 320));
    input.capturers[0].data(bytes.subarray(320));
    await settle(); await Promise.all(forwards);
    assert.equal(recognition.engines[0].audio.length, 0, 'native pacing waits for its 20ms slot');
    await recognition.advance(20);
    assert.equal(recognition.engines[0].audio.length, 1);
    assert.deepEqual([...recognition.engines[0].audio[0].bytes], [...bytes], 'the recycled SDK readData buffer is not retained');
    recognition.engines[0].result('正在说话');
    assert.equal(recognition.channelEvents.at(-1).text, '正在说话');
    await channel.invoke('stop', { run: 91, finalize: false });
    assert.equal(input.capturers[0].stops, 0);
    assert.equal(input.capturers[0].releases, 0);
  } finally {
    VoicePcmTap.clear(tap); await channel.invoke('stop', { run: 91, finalize: false }); await call.stop();
  }
  assert.equal(input.capturers[0].releases, 1);
  assert.equal(recognition.timers.size, 0);
});

test('recognizer failure and tap retirement leave the real call WAV path running', async () => {
  const input = captureFixture(), call = input.make(), recognition = asrFixture(), channel = recognition.attach();
  const { VoicePcmTap } = input.load('VoicePcmTap'), forwards = [];
  const tap = VoicePcmTap.enable('call', 92, (_tap, bytes) => forwards.push(channel.invoke('feed', { run: 92, bytes })));
  try {
    await channel.invoke('start', { run: 92 }); await call.start();
    input.capturers[0].data(pcm(0)); await settle(); await Promise.all(forwards); await recognition.advance(20);
    recognition.engines[0].error(1002200004); await settle();
    assert(recognition.channelEvents.some(event => event.type === 'error' && event.run === 92));
    VoicePcmTap.clear(tap); await channel.invoke('stop', { run: 92, finalize: false });
    const recorder = input.capturers[0];
    assert.equal(recorder.releases, 0);
    for (let index = 0; index < 6; index++) { recorder.data(pcm(10000)); await settle(); }
    for (let index = 0; index < 50; index++) { recorder.data(pcm(0)); await settle(); }
    const utterances = input.events.filter(event => event.type === 'utterance');
    assert.equal(utterances.length, 1);
    assert(utterances[0].wav.length > 44);
    assert.equal(new DataView(utterances[0].wav.buffer).getUint32(24, true), 16000);
    assert.equal(input.events.some(event => event.type === 'callError'), false);
    assert.equal(input.capturers.length, 1);
    assert.equal(recognition.engines.length, 1);
  } finally {
    VoicePcmTap.clear(tap); await channel.invoke('stop', { run: 92, finalize: false }); await call.stop();
  }
  assert.equal(input.capturers[0].releases, 1);
  assert.equal(recognition.timers.size, 0);
});
