// Actual EntryAbility, CompanionVoicePlugin and playback lane. The existing
// fixture substitutes only explicit Flutter/HMS/audio boundaries. This process
// never delays or invents a native result; finite delivery gates live in Dart.
import readline from 'node:readline';
import { systemTtsFixture } from './system-tts-fixture.mjs';

const fixture = systemTtsFixture();
function snapshot() {
  return {
    trace: fixture.trace.slice(),
    engines: fixture.engines.map(engine => ({
      closed: engine.closed === true,
      stops: engine.stops,
      shutdowns: engine.shutdowns,
      calls: engine.calls.map(call => ({ text: call.text, requestId: call.params.requestId,
        queueMode: call.params.extraParams.queueMode }))
    })),
    events: fixture.events.map(event => ({ type: event.type, id: event.id }))
  };
}
async function handle(row) {
  if (row.method === 'voice') {
    return fixture.call(fixture.methods, row.args.method, row.args.arguments ?? {}).done;
  }
  if (row.method === 'unavailable') { fixture.change({ createError: true }); return null; }
  if (row.method === 'snapshot') return snapshot();
  if (row.method === 'close') {
    await fixture.call(fixture.methods, 'stop').done;
    return snapshot();
  }
  throw new Error('unknown RPC: ' + row.method);
}
readline.createInterface({ input: process.stdin }).on('line', line => {
  const row = JSON.parse(line);
  Promise.resolve(handle(row)).then(
    result => process.stdout.write(JSON.stringify({ id: row.id, result }) + '\n'),
    error => process.stdout.write(JSON.stringify({ id: row.id, error: String(error) }) + '\n')
  );
});
