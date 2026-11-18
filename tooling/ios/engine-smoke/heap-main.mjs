import {getHeapStatistics} from 'node:v8';
import {Worker} from 'node:worker_threads';

const round = Number(process.env.DSH_IOS_HEAP_SMOKE_ROUND);
const heapLimit = getHeapStatistics().heap_size_limit;
const note = (kind, extra = {}) => console.log(JSON.stringify({kind, round, pid: process.pid, heapLimit, ...extra}));
if (round !== 1 && round !== 2) throw new Error('HEAP_SMOKE_INVALID_ROUND');
// Do not turn a misconfigured runner into an unbounded device-memory stress test.
// V8 adds its own overhead to 256/4, and how much depends on the build: 268 MiB on Linux.
if (heapLimit < 256 * 1024 * 1024 || heapLimit > 300 * 1024 * 1024) throw new Error(`HEAP_SMOKE_UNEXPECTED_HEAP_LIMIT ${heapLimit}`);
note('js-start');
if (round === 1) {
  const retained = [];
  // Real main-isolate JS heap allocation, not external Buffer storage.
  // Fractional values force double elements (8 bytes each), independent of pointer compression.
  // The current 256/4 runner must stop before this bounded 384 MiB request completes.
  for (let i = 0; i < 384; i++) retained.push(new Array(131072).fill(i + 0.5));
  globalThis.retained = retained;
  note('pressure-completed-unexpectedly');
} else {
  const worker = new Worker("require('node:worker_threads').parentPort.postMessage(42)", {eval: true, execArgv: []});
  let value;
  let error;
  worker.on('message', message => { value = message; });
  worker.on('error', failure => { error = failure.code ?? failure.name; });
  const code = await new Promise(resolve => worker.once('exit', resolve));
  if (code !== 0 || value !== 42 || error !== undefined) throw new Error('HEAP_SMOKE_RECOVERY_WORKER_FAILED');
  note('recovery-ok', {workerCode: code, workerValue: value});
}
