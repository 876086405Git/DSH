// Actual EntryAbility/CompanionVoicePlugin/playback lane. Only HMS callbacks,
// Flutter transport and the existing fixture's SDK boundaries are controlled.
import readline from 'node:readline';
import { deferred, systemTtsFixture } from './system-tts-fixture.mjs';

const f = systemTtsFixture();
let delivered = 0, creation = null;
function drainEvents() {
  for (; delivered < f.events.length; delivered++) {
    const e = f.events[delivered];
    process.stdout.write(JSON.stringify({ event: { type: e.type, id: e.id, start: e.start, end: e.end } }) + '\n');
  }
}
function snapshot() {
  return { trace: f.trace.slice(), events: f.events.map(e => ({ type: e.type, id: e.id })),
    engines: f.engines.map(e => ({ closed: e.closed === true,
      calls: e.calls.map(c => ({ text: c.text, requestId: c.params.requestId })) })) };
}
async function handle(row) {
  if (row.method === 'voice') return f.call(f.methods, row.args.method, row.args.arguments ?? {}).done;
  if (row.method === 'snapshot') return snapshot();
  if (row.method === 'gate-create') {
    creation = deferred(); f.change({ create: () => creation.promise }); return null;
  }
  if (row.method === 'release-create') { creation?.resolve(); return null; }
  if (row.method === 'unavailable') { f.change({ createError: true }); return null; }
  if (row.method === 'sdk') {
    const engine = f.engines.findLast(e => e.calls.some(c => c.text === row.args.text));
    const call = engine?.calls.findLast(c => c.text === row.args.text);
    if (!engine || !call) throw new Error('no actual accepted SDK request for ' + row.args.text);
    if (row.args.kind === 'start') engine.start(call.params.requestId);
    else if (row.args.kind === 'done') engine.complete(call.params.requestId, 1);
    else throw new Error('unsupported SDK callback');
    return null;
  }
  if (row.method === 'close') {
    creation?.resolve(); await f.call(f.methods, 'stop').done; return snapshot();
  }
  throw new Error('unknown RPC ' + row.method);
}
readline.createInterface({ input: process.stdin }).on('line', line => {
  const row = JSON.parse(line);
  Promise.resolve(handle(row)).then(result => {
    drainEvents(); process.stdout.write(JSON.stringify({ id: row.id, result }) + '\n');
  }, error => {
    drainEvents(); process.stdout.write(JSON.stringify({ id: row.id, error: String(error) }) + '\n');
  });
});
