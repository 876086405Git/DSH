import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { join, isAbsolute } from 'node:path';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { randomUUID } from 'node:crypto';
import { Worker } from 'node:worker_threads';
import { openOwnershipLedger } from '../../ohos/publication/ledger.mjs';
import { createOwnedGitServer } from '../../ohos/process/owned-server.mjs';

assert.ok(isAbsolute(process.env.DSH_TEST_PUBLICATION_BINDING || ''));
const binding = createRequire(import.meta.url)(process.env.DSH_TEST_PUBLICATION_BINDING);
const deferred = () => Promise.withResolvers();
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const includes = (error, code) => !!error && (error.code === code || includes(error.cause, code)
  || (Array.isArray(error.errors) && error.errors.some(item => includes(item, code))));
async function fixture(t, overrides = {}, workerOptions = {}) {
  const root = await fs.mkdtemp(join(tmpdir(), 'dsh-owned-rpc-'));
  const workspace = join(root, 'workspace'), directory = join(root, 'ledger');
  await fs.mkdir(workspace);
  const ledger = await openOwnershipLedger({ directory, ownerId: randomUUID(), ...binding });
  const messages = [], fatalErrors = [];
  const exit = deferred(), outcome = deferred();
  const target = join(workspace, 'index');
  const worker = new Worker(new URL('./owned-worker-fixture.mjs', import.meta.url), {
    workerData: { target, ...workerOptions }, stdout: true, stderr: true,
  });
  const server = createOwnedGitServer({
    roots: [workspace], getOwnership: () => ledger,
    send: message => worker.postMessage(message),
    onFailure: error => { fatalErrors.push(error); void worker.terminate(); },
    ...overrides,
  });
  worker.on('message', message => {
    if (!server.handle(message)) {
      messages.push(message);
      if (message.kind === 'outcome') outcome.resolve(message);
    }
  });
  worker.on('error', error => exit.reject(error));
  worker.once('exit', code => exit.resolve(code));
  t.after(async () => {
    await worker.terminate();
    await server.finish({ cancelled: true }).catch(() => {});
    await ledger.close();
    await fs.rm(root, { recursive: true, force: true });
  });
  return { root, workspace, directory, target, ledger, worker, server, messages,
    fatalErrors, exit: exit.promise, outcome: outcome.promise };
}
const ledgerRows = async f => JSON.parse(await fs.readFile(join(f.directory, 'ledger.json'), 'utf8')).entries;

test('real Worker uses five-operation client and acknowledges replies before successful exit', async t => {
  const f = await fixture(t, {}, { operation: 'index' });
  assert.equal(await f.exit, 0);
  assert.equal((await f.outcome).exitCode, 0);
  await f.server.finish();
  assert.equal(await fs.readFile(f.target, 'utf8'), 'second');
  assert.deepEqual(await ledgerRows(f), []);
  assert.equal(f.server.resourceCount, 0); assert.equal(f.server.pendingCount, 0);
});

test('real Worker termination does not release parent write or its resource early', async t => {
  const entered = deferred(), resume = deferred(); let staged, once = false;
  const io = { ...fs, async open(...args) {
    const file = await fs.open(...args);
    return new Proxy(file, { get(target, key) {
      if (key === 'write') return async (...a) => {
        const result = await target.write(...a);
        if (!once) { once = true; entered.resolve(); await resume.promise; }
        return result;
      };
      const value = target[key]; return typeof value === 'function' ? value.bind(target) : value;
    } });
  } };
  const f = await fixture(t, { fs: io, onStage(name, row) { staged = row.path; } });
  await entered.promise;
  f.server.stop(); await f.worker.terminate(); await f.exit;
  let finished = false;
  const finish = f.server.finish({ cancelled: true }).then(() => { finished = true; });
  await delay(20); assert.equal(finished, false); assert.equal((await fs.stat(staged)).size > 0, true);
  resume.resolve(); await finish;
  await assert.rejects(fs.stat(staged), { code: 'ENOENT' });
  await assert.rejects(fs.stat(f.target), { code: 'ENOENT' });
  assert.deepEqual(await ledgerRows(f), []);
});

test('reply failure terminates the real Worker and retains parent ownership until exact cleanup', async t => {
  let trigger;
  const delivery = new Error('injected reply delivery failure');
  const f = await fixture(t, { send() { throw delivery; }, onStage(name, row) {
    if (name === 'identified') trigger = row.path;
  } }, { operation: 'index', hold: true });
  await f.exit;
  await assert.rejects(f.server.finish(), error => includes(error, 'ERR_OHOS_GIT_RESOURCE_DELIVERY'));
  assert.equal(f.fatalErrors.length, 1);
  await assert.rejects(fs.stat(trigger), { code: 'ENOENT' });
  assert.deepEqual(await ledgerRows(f), []);
});

test('exit zero cannot hide a later real rename error whose response was never acknowledged', async t => {
  const entered = deferred(), resume = deferred();
  const io = { ...fs, async rename(source, target) {
    entered.resolve(); await resume.promise;
    // Real filesystem error after the Worker has already reported exit zero.
    await fs.mkdir(target);
    return fs.rename(source, target);
  } };
  const f = await fixture(t, { fs: io });
  await entered.promise;
  f.worker.postMessage({ kind: 'exit-now' });
  assert.equal((await f.outcome).exitCode, 0);
  assert.equal(await f.exit, 0);
  const ending = f.server.finish();
  const rejection = assert.rejects(ending, error => includes(error, 'ERR_OHOS_GIT_RESOURCE_UNACKNOWLEDGED')
    && includes(error, 'EISDIR'));
  resume.resolve(); await rejection;
  assert.deepEqual(await ledgerRows(f), []);
  assert.equal((await fs.stat(f.target)).isDirectory(), true);
});

test('acknowledged ordinary error may be handled by the caller without forcing provider failure', async t => {
  const io = { ...fs, async rename(source, target) {
    await fs.mkdir(target);
    return fs.rename(source, target);
  } };
  const f = await fixture(t, { fs: io }, { catchAsSuccess: true });
  const result = await f.outcome;
  assert.equal(result.exitCode, 0); assert.equal(result.handledCode, 'EISDIR');
  assert.equal(await f.exit, 0);
  await f.server.finish();
  assert.deepEqual(await ledgerRows(f), []);
  assert.equal(f.fatalErrors.length, 0);
});

test('stop still consumes an already-issued error acknowledgement before real Worker exit', async t => {
  const entered = deferred(), resume = deferred();
  const io = { ...fs, async rename(source, target) {
    entered.resolve(); await resume.promise;
    await fs.mkdir(target); return fs.rename(source, target);
  } };
  const f = await fixture(t, { fs: io }, { catchAsSuccess: true });
  await entered.promise; f.server.stop(); resume.resolve();
  assert.equal((await f.outcome).handledCode, 'EISDIR');
  assert.equal(await f.exit, 0);
  await f.server.finish();
  assert.equal(f.fatalErrors.length, 0);
  assert.deepEqual(await ledgerRows(f), []);
});
