import assert from 'node:assert/strict';
import { test } from 'node:test';
import { existsSync, mkdtempSync } from 'node:fs';
import { rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { CommandRouter } from '../../ohos/process/command-router.mjs';
import { createPythonRuntimeBackend } from '../../ohos/process/python-backend.mjs';

const aliases = ['python', 'python3', 'pip', '/bin/python', '/bin/python3', '/bin/pip',
  '/usr/bin/python', '/usr/bin/python3', '/usr/bin/pip'];
const spec = (argv, cwd) => ({ argv, cwd, graceMs: 1000,
  stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });

test('router and Python factory share the exact alias set; pip cannot silently fall through to Linux', async t => {
  const root = mkdtempSync(join(tmpdir(), 'python-router-'));
  let pythonStarts = 0, linuxStarts = 0;
  const python = createPythonRuntimeBackend({ native: {
    contract: 'dsh-python-1', stdin: 'unsupported',
    start({ argv }) {
      pythonStarts++;
      if (argv[0] === '-m') throw Object.assign(new Error('pip/-m require App Linux'), { code: 'ERR_OHOS_PYTHON_ARGUMENTS' });
      return { completion: Promise.resolve({ exitCode: 0 }), cancel() {} };
    },
    async dispose() {},
  } });
  const linux = { capabilities: { confinement: [] }, spawn() { linuxStarts++; }, async dispose() {} };
  const router = new CommandRouter({ workspaceRoots: [root] }, { nativePython: python, linux });
  t.after(async () => {
    try { await router.dispose(); } finally { await rm(root, { recursive: true, force: true }); }
  });
  for (const command of aliases) {
    assert.equal(python.supports(command), true, command);
    assert.strictEqual(router.select([command]), python, command);
    assert.equal(await router.resolveExecutable(command), command);
    assert.throws(() => router.select([command], { mode: 'workspace-write', workspaceRoot: root }),
      { code: 'ERR_OHOS_BACKEND_CONFINEMENT' });
    const job = router.spawnPlugin(spec([command, command.endsWith('pip') ? 'install' : '-c', 'example'], root));
    job.stdout.resume(); job.stderr.resume();
    if (command.endsWith('pip')) await assert.rejects(job.done, { code: 'ERR_OHOS_PYTHON_ARGUMENTS' });
    else assert.equal((await job.done).exitCode, 0);
  }
  for (const command of ['/untrusted/python3', './python3', '/bin/pip3', 'python3.14']) {
    assert.equal(python.supports(command), false);
    assert.strictEqual(router.select([command]), linux);
  }
  assert.equal(pythonStarts, aliases.length);
  assert.equal(linuxStarts, 0);
});

test('router keeps its shared temporary root until the Python provider has really disposed', async t => {
  const root = mkdtempSync(join(tmpdir(), 'python-dispose-'));
  const closed = Promise.withResolvers();
  let disposing = false;
  const python = createPythonRuntimeBackend({ native: {
    contract: 'dsh-python-1',
    async dispose() { disposing = true; await closed.promise; },
  } });
  const router = new CommandRouter({ workspaceRoots: [root] }, { nativePython: python });
  const temporaryRoot = router.temporaryRoot;
  t.after(async () => { closed.resolve(); await rm(root, { recursive: true, force: true }); });
  let finished = false;
  const disposed = router.dispose(); disposed.then(() => { finished = true; }, () => {});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(disposing, true);
  assert.equal(finished, false);
  assert.equal(existsSync(temporaryRoot), true);
  assert.throws(() => router.spawnPlugin(spec(['python3', '-c', 'pass'], root)), { code: 'ERR_OHOS_PROCESS_CLOSED' });
  closed.resolve(); await disposed;
  assert.equal(existsSync(temporaryRoot), false);
});
