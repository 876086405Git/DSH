import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { registerHooks } from 'node:module';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';
import { setObserver } from './core-fs-shim.mjs';
assert.equal(process.platform, 'openharmony');
assert.equal(typeof globalThis[Symbol.for('dsh.go.ohos.publication')].publishAtomic, 'function');
const coreURL = pathToFileURL(process.env.DSH_DELETION_SYNC_SOURCE).href;
const shimURL = new URL('./core-fs-shim.mjs', import.meta.url).href;
let redirected = 0;
const hooks = registerHooks({ resolve(specifier, context, next) {
  if (specifier === 'node:fs/promises' && context.parentURL === coreURL) {
    redirected++; return { url: shimURL, shortCircuit: true };
  }
  return next(specifier, context);
} });
const { createDeletionSeam } = await import(coreURL);
hooks.deregister();
assert.equal(redirected, 1);

test('directory sync failures preserve logs on both first commit and retry before successful cleanup', { timeout: 15000 }, async t => {
  const temporary = await fs.mkdtemp(join(tmpdir(), 'dsh-dir-sync-'));
  const root = join(temporary, 'sessions'), directory = join(root, 'aa', 's1');
  await fs.mkdir(directory, { recursive: true });
  const log = join(directory, 'session.jsonl'), original = '{"private":"directory-sync-proof"}\n';
  await fs.writeFile(log, original);
  const control = join(root, '.dsh-go-lifecycle');
  const slot = join(control, createHash('sha256').update('s1').digest('hex'));
  const marker = join(slot, 'deleted.json');
  const expected = [slot, control, root, dirname(root)];
  let failing = true, cleanups = 0, claimed = false;
  const events = [], records = [], leases = new Set();
  setObserver(async (type, path) => {
    events.push({ type, path });
    if (type === 'sync-before' && path === control && failing) {
      throw Object.assign(new Error('injected control-directory fsync failure'), { code: 'EIO', syscall: 'fsync' });
    }
  });
  t.after(async () => { setObserver(() => {}); await fs.rm(temporary, { recursive: true, force: true }); });
  const seam = createDeletionSeam({ root,
    ctx: { get: () => ({ list: () => [], get: () => undefined }), emit() {} },
    tracker: { writers: new Map(), claimWrite() { claimed = true; }, releaseClaim() { claimed = false; } },
    coldLogMemo: new Map(), migrationPreparations: new Map(),
    async list() { return [{ header: { id: 's1' } }]; }, async findLog() { return { currentPath: log }; },
    async readGenerationHeader() { return { header: { id: 's1' } }; }, async requireStoredLog() { return { events: [] }; },
  }, { async acquire(path) { assert.equal(leases.has(path), false); leases.add(path); return { async release() { leases.delete(path); } }; },
    parseGeneration: name => name === 'session.jsonl' ? {} : undefined,
    notFound: () => Object.assign(new Error('missing'), { code: 'not-found' }) });
  const callbacks = { async prepare() {}, async inspectTasks() { return false; }, async cleanup() { cleanups++; } };
  async function phase(label) {
    events.length = 0;
    let error;
    try { await seam.delete('s1', callbacks); } catch (value) { error = value; }
    const logBytes = await fs.readFile(log).catch(value => { if (value.code === 'ENOENT') return null; throw value; });
    const markerBytes = await fs.readFile(marker);
    records.push({ label, error: error ? { name: error.name, code: error.code, message: error.message } : null,
      logHex: logBytes?.toString('hex') ?? null, markerHex: markerBytes.toString('hex'),
      events: [...events], cleanups, pending: seam.pending.size, leases: leases.size, claimed });
    await fs.writeFile(process.env.DSH_DELETION_SYNC_TRACE, JSON.stringify({ coreURL, redirected, records }, null, 2) + '\n');
    assert.equal(seam.pending.size, 0); assert.equal(leases.size, 0); assert.equal(claimed, false);
    return { error, logBytes, markerBytes };
  }
  const first = await phase('first-publication-sync-fails');
  assert.equal(first.error?.code, 'EIO'); assert.equal(first.logBytes?.toString(), original);
  assert.deepEqual(JSON.parse(first.markerBytes), { version: 1, directory: 'aa/s1' }); assert.equal(cleanups, 0);
  const retry = await phase('retry-same-sync-fails');
  assert.equal(retry.error?.code, 'EIO', 'retry must revisit the failing directory sync before deleting logs');
  assert.equal(retry.logBytes?.toString(), original); assert.equal(cleanups, 0);
  assert.deepEqual(retry.markerBytes, first.markerBytes);
  failing = false;
  const success = await phase('retry-sync-succeeds');
  assert.equal(success.error, undefined); assert.equal(success.logBytes, null); assert.equal(cleanups, 1);
  const removal = events.findIndex(event => event.type === 'rm' && event.path === log);
  assert(removal >= 0);
  assert.deepEqual(events.slice(0, removal).filter(event => event.type === 'sync-done').map(event => event.path), expected);
  assert.deepEqual(success.markerBytes, first.markerBytes);
});
