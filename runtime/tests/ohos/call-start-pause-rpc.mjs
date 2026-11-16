// Actual SpeechPlugin/CallCapture/VoicePcmTap bodies. Only Flutter/OS audio,
// permission, window and monotonic-clock boundaries come from the existing fixture.
import assert from 'node:assert/strict';
import readline from 'node:readline';
import { captureFixture, pcm, settle } from './call-capture-fixture.mjs';

let permissionGate, permissionEntered;
const fixture = captureFixture({ permission: async () => {
  permissionEntered?.resolve();
  await permissionGate?.promise;
} }), speech = fixture.speech();
const { VoicePcmTap } = fixture.load('VoicePcmTap');
const frames = [];
const tap = VoicePcmTap.enable('call', 1321, (_tap, bytes) => frames.push(bytes));
function snapshot() {
  return {
    pcmFrames: frames.length,
    wavUtterances: fixture.events.filter(event => event.type === 'utterance').length,
    speechStarts: fixture.events.filter(event => event.type === 'speechStart').length,
    nonzeroLevels: fixture.events.filter(event => event.type === 'micLevel' && event.value > 0).length,
    capturers: fixture.capturers.length,
    releases: fixture.capturers.reduce((sum, capturer) => sum + capturer.releases, 0),
    keepScreenOn: fixture.screen.keep
  };
}
async function handle(row) {
  switch (row.method) {
    case 'permission.hold': permissionGate = Promise.withResolvers(); permissionEntered = Promise.withResolvers(); return null;
    case 'permission.entered': await permissionEntered.promise; return null;
    case 'permission.release': permissionGate.resolve(); permissionGate = undefined; return null;
    case 'speech': return speech.request(row.args.method, row.args.arguments ?? {});
    case 'input': {
      const capturer = fixture.capturers.at(-1);
      assert(capturer, 'a real production call must create its capturer first');
      const loud = row.args?.loud ?? 0, quiet = row.args?.quiet ?? 0;
      assert(Number.isInteger(loud) && loud >= 0 && loud <= 100);
      assert(Number.isInteger(quiet) && quiet >= 0 && quiet <= 100);
      for (let i = 0; i < loud; i++) { capturer.data(pcm(20000)); await settle(); }
      for (let i = 0; i < quiet; i++) { capturer.data(pcm(0)); await settle(); }
      return snapshot();
    }
    case 'close': {
      await speech.request('callStop');
      VoicePcmTap.clear(tap);
      return snapshot();
    }
    default: throw new Error('unknown RPC: ' + row.method);
  }
}
const input = readline.createInterface({ input: process.stdin });
input.on('line', line => {
  const row = JSON.parse(line);
  Promise.resolve(handle(row)).then(
    result => process.stdout.write(JSON.stringify({ id: row.id, result }) + '\n'),
    error => process.stdout.write(JSON.stringify({ id: row.id, error: String(error) }) + '\n')
  );
});
