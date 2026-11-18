import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { createPythonHost } from '../../ohos/python/host.mjs';
import { createPythonRuntimeBackend } from '../../ohos/process/python-backend.mjs';
import { beforeJobExit } from './python-test-observation.mjs';

const root = mkdtempSync(join(tmpdir(), 'python-owner-'));
const config = JSON.parse(process.env.OHOS_PYTHON_HOST_CONFIG);
const native = createPythonHost({ ...config, roots: [root] });
const backend = createPythonRuntimeBackend({ native });
const spec = argv => ({ argv, cwd: root, env: {}, graceMs: 1000,
  stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
const aliases = ['python', 'python3', '/bin/python', '/bin/python3', '/usr/bin/python', '/usr/bin/python3'];
after(async () => {
  if (typeof backend.dispose === 'function') await backend.dispose();
  rmSync(root, { recursive: true, force: true });
});

test('each accepted Python alias executes in the real shared-library owner', async () => {
  for (const command of aliases) {
    assert.equal(backend.supports(command), true, command);
    const job = backend.spawn(spec([command, '-c', 'print(123)']));
    let output = '', errors = '';
    job.stdout.on('data', chunk => { output += chunk; });
    job.stderr.on('data', chunk => { errors += chunk; });
    assert.equal((await job.done).exitCode, 0, errors);
    assert.equal(output, '123\n');
  }
});

test('pip aliases retain the actual unsupported-arguments error', async () => {
  for (const command of ['pip', '/bin/pip', '/usr/bin/pip']) {
    assert.equal(backend.supports(command), true, command);
    const job = backend.spawn(spec([command, 'install', 'example']));
    job.stdout.resume(); job.stderr.resume();
    await assert.rejects(job.done, { code: 'ERR_OHOS_PYTHON_ARGUMENTS' });
    if (job.started) await assert.rejects(job.started, { code: 'ERR_OHOS_PYTHON_ARGUMENTS' });
  }
});

test('an actual Python failure before the marker cannot become a dispose timeout', { timeout: 5000 }, async t => {
  const job = backend.spawn(spec(['python3', '-c', "raise RuntimeError('expected-marker-observation-failure')"]));
  let errors = ''; job.stdout.resume(); job.stderr.on('data', chunk => { errors += chunk; });
  const missing = join(root, 'must-not-exist');
  await assert.rejects(beforeJobExit(job, async signal => {
    while (!existsSync(missing)) await delay(5, undefined, { signal });
    return readFileSync(missing, 'utf8');
  }, { label: 'absent owner marker', stderr: () => errors, signal: t.signal }), error =>
    error.code === 'ERR_OHOS_TEST_JOB_ENDED_EARLY' && error.outcome.exitCode === 1 &&
    error.message.includes('expected-marker-observation-failure'));
});

test('dispose waits for cooperative tail output and the actual owner OS thread exit', { timeout: 15000 }, async t => {
  const job = backend.spawn(spec(['python3', '-c',
    "import threading,sys\nprint('stdout-tail')\nprint('stderr-tail', file=sys.stderr)\nwith open('owner-tid','w') as f: f.write(str(threading.get_native_id()))\nwhile True: pass"]));
  let output = '', errors = '';
  job.stdout.on('data', chunk => { output += chunk; });
  job.stderr.on('data', chunk => { errors += chunk; });
  t.after(async () => { job.terminate(); await job.done.catch(() => {}); });
  const marker = join(root, 'owner-tid');
  const tid = await beforeJobExit(job, async signal => {
    for (;;) {
      const value = existsSync(marker) ? readFileSync(marker, 'utf8') : '';
      if (value) return value;
      await delay(5, undefined, { signal });
    }
  }, { label: 'owner OS thread marker', stderr: () => errors, signal: t.signal });
  assert.match(tid, /^\d+$/);
  const task = readdirSync('/proc/self/task').find(id => {
    const status = readFileSync(`/proc/self/task/${id}/status`, 'utf8');
    return status.match(/^NSpid:\s+(.+)$/m)?.[1].trim().split(/\s+/).at(-1) === tid;
  });
  assert(task, 'the native owner thread really exists, including nested PID namespaces');
  assert.equal(typeof backend.dispose, 'function', '905 provider must satisfy 910 dispose contract');
  assert.equal(backend.live.has(job), true);
  assert(job.started instanceof Promise, 'started must be an observed admission event');
  await job.started;
  const disposed = backend.dispose();
  assert.strictEqual(backend.dispose(), disposed, 'dispose is idempotent');
  assert.throws(() => backend.spawn(spec(['python3', '-c', "print('late')"])), { code: 'ERR_OHOS_PYTHON_CLOSED' });
  assert.equal((await job.done).exitCode, 130);
  await disposed;
  assert.match(output, /stdout-tail\n$/);
  assert.equal(errors, 'stderr-tail\n');
  assert.equal(backend.live.size, 0);
  assert.equal(existsSync(`/proc/self/task/${task}`), false, 'unref/job completion is not owner thread exit');
});
