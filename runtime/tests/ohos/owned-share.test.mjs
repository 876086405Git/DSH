import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { join } from 'node:path';
import { Worker } from 'node:worker_threads';
import { installPublication, borrowInstalledOwnership, publicationSymbol } from '../../ohos/publication/index.mjs';
import { createOwnedGitResources } from '../../ohos/process/owned-resources.mjs';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';

const home = process.env.DSH_HOME;
assert.ok(home, 'explicit isolated existing DSH_HOME required');
const workspace = join(home, 'workspace');
await fs.mkdir(workspace);
let ownership, installed;
const ledgerRows = async () => JSON.parse(await fs.readFile(join(home, 'ohos-ownership/ledger.json'), 'utf8')).entries;

test('an idle Git owner needs no installed publication service', async () => {
  assert.throws(() => borrowInstalledOwnership(), { code: 'ERR_OHOS_OWNERSHIP_UNAVAILABLE' });
  const idle = createOwnedGitResources({ roots: [workspace] });
  await idle.finish();
});

test('actual linked publication installs once and exposes only a frozen borrowing facade', async () => {
  installed = await installPublication();
  assert.equal(installed.installed, true);
  ownership = borrowInstalledOwnership();
  assert.equal(ownership, borrowInstalledOwnership());
  assert.ok(Object.isFrozen(ownership));
  assert.deepEqual(Object.keys(ownership).sort(), ['identify', 'ownerId', 'release', 'reserve']);
  assert.equal(ownership.ownerId, globalThis[publicationSymbol].ownerId);
  const first = createOwnedGitResources({ roots: [workspace] });
  const second = createOwnedGitResources({ roots: [workspace] });
  try {
    const a = await first.createIndex({ target: join(workspace, 'a'), content: Buffer.from('a') });
    const b = await second.createIndex({ target: join(workspace, 'b'), content: Buffer.from('b') });
    const rows = await ledgerRows();
    assert.equal(rows.length, 2); assert.ok(rows.every(row => row.ownerId === ownership.ownerId));
    await first.commitIndex(a.id); await second.releaseIndex(b.id);
    assert.deepEqual(await ledgerRows(), []);
  } finally { await Promise.all([first.finish(), second.finish()]); }
});

test('real Worker cannot borrow or reopen the main ledger', async () => {
  const before = await fs.readFile(join(home, 'ohos-ownership/ledger.json'));
  const worker = new Worker(new URL('./owned-share-worker.mjs', import.meta.url));
  const message = new Promise((resolve, reject) => { worker.once('message', resolve); worker.once('error', reject); });
  const exited = new Promise((resolve, reject) => { worker.once('exit', resolve); worker.once('error', reject); });
  const observation = await message;
  assert.equal(await exited, 0);
  assert.equal(observation.borrowCode, 'ERR_OHOS_OWNERSHIP_MAIN_THREAD');
  assert.deepEqual(observation.install, { installed: false, reason: 'not-main-thread' });
  assert.deepEqual(await fs.readFile(join(home, 'ohos-ownership/ledger.json')), before);
});

test('runtime disposal cannot close the shared ledger or drop its real flock', async () => {
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [workspace] });
  const task = runtime.spawn({ argv: ['bash', '-c', 'printf alive'], cwd: workspace,
    graceMs: 100, stdio: { stdin: 'ignore', stdout: { maxBytes: 1000 }, stderr: { maxBytes: 1000 } } });
  assert.equal((await task.done).exitCode, 0); assert.equal(await task.waitForExit(), true);
  assert.equal(task.collected.stdout.readFrom(0).text, 'alive');
  await runtime.dispose();
  const fd = await fs.open(join(home, 'ohos-ownership/.lock'), 'r+');
  try {
    assert.throws(() => process._linkedBinding('dsh_ohos_publication').lockExclusive(fd.fd),
      error => ['EAGAIN', 'EWOULDBLOCK'].includes(error.code));
  } finally { await fd.close(); }
  assert.equal(borrowInstalledOwnership(), ownership);
  const next = createOwnedGitResources({ roots: [workspace] });
  await next.writeMetadata({ target: join(workspace, 'after-dispose'), content: Buffer.from('still-open') });
  await next.finish();
  assert.equal(await fs.readFile(join(workspace, 'after-dispose'), 'utf8'), 'still-open');
  assert.deepEqual(await ledgerRows(), []);
});
