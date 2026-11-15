// One isolated child per case. LinuxControl and its proxy/diagnostics are real.
// Owner/backend/guest completion are the explicit controlled boundary shape
// already used by linux-job-diagnostics-control.test.mjs. No guest/SDK claim.
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import { setTimeout as delay, setImmediate as tick } from 'node:timers/promises';
import { LinuxControl } from '../../ohos/linux/control.mjs';

const name = process.argv[2];
const allowed = new Set(['resume-forward', 'resume-backward', 'busy-forward', 'busy-backward',
  'ready-resume-before-expiry-check', 'ready-busy-before-expiry-check', 'already-ready-expired-budget',
  'first-install-refused', 'abort-during-wait', 'preaborted-ready']);
assert(allowed.has(name), 'one named fixture case is required');

async function until(predicate) {
  for (let n = 0; n < 400; n++) {
    if (predicate()) return;
    await delay(5);
  }
  assert.fail('explicit fixture transition did not arrive');
}

function fixture({ pending = false, bootMode = 'resume' } = {}) {
  const installed = Promise.withResolvers();
  const handles = [], starts = [];
  const backend = { state: 'opened', closed: false, spawn(spec) {
    const completion = Promise.withResolvers();
    const handle = { started: Promise.resolve(), done: completion.promise,
      finish: () => completion.resolve({ exitCode: 0, signal: null, cancelled: false }),
      terminate: () => completion.resolve({ exitCode: null, signal: 'SIGTERM', cancelled: true }),
      waitForExit: () => completion.promise.then(() => true),
      collected: Object.fromEntries(['stdout', 'stderr'].map(stream => [stream,
        { snapshot: () => ({ bytes: Buffer.alloc(0), totalBytes: 0 }) }])) };
    starts.push(spec.argv); handles.push(handle); return handle;
  } };
  const owner = { state: 'active', bootMode, persistentInstanceId: 'explicit-fixture-owner',
    nativeOwnerCreated: false,
    async install() { await installed.promise; return { backend }; },
    async dispose() { return { resourcesRetired: true, filesRemoved: true, dataRetained: false, native: null }; },
  };
  let created = 0;
  const control = new LinuxControl({ hostPaths: { directory: '/explicit-fixture/private', nativeLibraryDirectory: '/explicit-fixture/native' } },
    { loadModule: async () => ({ loadLinuxInstallationManifest: async () => ({}),
      createLinuxInstallationOwner: () => { created++; return owner; } }) });
  const command = (action, fields = {}) => {
    const current = control.status();
    return control.command({ v: 1, instanceId: current.instanceId, attemptId: current.attemptId, action, ...fields });
  };
  // Avoid reading any host proxy credentials through this unrelated fixture.
  command('setProxy', { proxy: { mode: 'direct' } });
  command('setEnabled', { enabled: true });
  if (!pending) installed.resolve();
  return { control, handles, starts, command, created: () => created, release: () => installed.resolve(),
    async close() {
      installed.resolve();
      await until(() => control.status().admission);
      for (const handle of handles) handle.finish();
      await tick(); await control.shutdown();
    } };
}

const originalDateNow = Object.getOwnPropertyDescriptor(Date, 'now');
const wallNow = Date.now;
let wallOffset = 0;
const timers = [];
const later = (milliseconds, callback) => {
  const timer = setTimeout(callback, milliseconds); timers.push(timer); return timer;
};
const jump = milliseconds => {
  wallOffset = milliseconds;
};
const spec = { argv: ['fixture-command'], cwd: '/workspace', env: {},
  stdio: { stdin: 'ignore', stdout: { maxBytes: 128 }, stderr: { maxBytes: 128 } } };
const waiting = name.startsWith('resume-') || name === 'ready-resume-before-expiry-check' || name === 'first-install-refused';
const f = fixture({ pending: waiting, bootMode: name === 'first-install-refused' ? 'install' : 'resume' });
const abort = new AbortController();
const guardReason = Object.assign(new Error('explicit test guard, not a product timeout'), { code: 'FIXTURE_GUARD' });
const cancellation = Object.assign(new Error('explicit caller cancellation'), { code: 'FIXTURE_CALLER_ABORT' });
let guarded = false, result;
try {
  await until(() => f.created() === 1);
  if (!waiting) await until(() => f.control.status().admission);
  let held;
  if (name.startsWith('busy-') || name === 'ready-busy-before-expiry-check' || name === 'abort-during-wait') {
    held = await f.control.spawnRouted(spec, { label: 'held-fixture-job' });
  }
  let waitMs = 250, resumeMs = 250;
  if (name.startsWith('ready-')) {
    waitMs = resumeMs = 30;
    later(70, () => { f.release(); held?.finish(); });
  }
  if (name === 'already-ready-expired-budget' || name === 'preaborted-ready') waitMs = resumeMs = -1;
  if (name === 'preaborted-ready') abort.abort(cancellation);
  // Change Date.now only in this dedicated test process. Timers and
  // performance.now remain real; no product clock/global is modified.
  Object.defineProperty(Date, 'now', { ...originalDateNow, value: () => wallNow() + wallOffset });
  if (name.endsWith('-forward')) later(20, () => jump(60000));
  if (name.endsWith('-backward') || name === 'abort-during-wait') later(20, () => jump(-60000));
  if (name === 'abort-during-wait') later(50, () => abort.abort(cancellation));
  // A finite independent real timer prevents a backward-jump baseline from
  // hanging. It is a fixture guard, never the asserted product error.
  later(1200, () => { guarded = true; abort.abort(guardReason); });
  const start = performance.now(), wallStart = wallNow();
  try {
    const handle = await f.control.spawnRouted(spec, { signal: abort.signal, waitMs, resumeMs, label: 'waiting-fixture-job' });
    result = { outcome: 'spawned', handle };
  } catch (error) {
    result = { outcome: 'rejected', errorCode: error.code, exitCode: error.exitCode,
      originalCancellation: error === cancellation || error.cause === cancellation };
  }
  const elapsedMs = performance.now() - start;
  result.handle?.finish();
  delete result.handle;
  let pass;
  if (/^(resume|busy)-(forward|backward)$/.test(name)) {
    const busy = name.startsWith('busy-');
    pass = !guarded && result.errorCode === (busy ? 'ERR_OHOS_LINUX_BUSY' : 'ERR_OHOS_LINUX_UNAVAILABLE')
      && result.exitCode === (busy ? 126 : 127) && elapsedMs >= 250;
  } else if (name === 'first-install-refused') {
    pass = !guarded && result.errorCode === 'ERR_OHOS_LINUX_INSTALLING' && result.exitCode === 127 && f.starts.length === 0;
  } else if (name === 'abort-during-wait' || name === 'preaborted-ready') {
    pass = !guarded && result.originalCancellation === true && f.starts.length === (held ? 1 : 0);
  } else {
    pass = !guarded && result.outcome === 'spawned' && f.starts.length === (held ? 2 : 1);
  }
  console.log(JSON.stringify({ name, pass, ...result, elapsedMs, wallElapsedMs: wallNow() - wallStart,
    wallOffsetMs: wallOffset, independentGuardFired: guarded, waitMs, resumeMs,
    starts: f.starts.length, clockBoundary: 'Date.now offset in isolated fixture child only; real monotonic clock and timers',
    nativeBoundary: 'explicit owner/backend completion shape; actual LinuxControl method' }));
  process.exitCode = pass ? 0 : 1;
} finally {
  Object.defineProperty(Date, 'now', originalDateNow);
  for (const timer of timers) clearTimeout(timer);
  await f.close();
}
