// Real private files + the real Linux publication syscall/ownership fixture.
// Only the publication service/fault outcomes are injected; this is not a device test.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';
import { createAtomicPublisher } from '../../ohos/publication/atomic.mjs';
import { openOwnershipLedger } from '../../ohos/publication/ledger.mjs';

assert.equal(process.platform, 'openharmony', 'run with the OH simulator preload');
assert.equal(typeof process.env.DSH_SESSION_DELETION_CORE, 'string', 'use the actual generated OH deletion module');
const { createDeletionSeam } = await import(pathToFileURL(resolve(process.env.DSH_SESSION_DELETION_CORE)));
const native = process._linkedBinding('dsh_ohos_publication');
const publicationSymbol = Symbol.for('dsh.go.ohos.publication');
const fail = (code, syscall) => Object.assign(new Error('injected publication failure'), { code, syscall });
const absent = path => assert.rejects(fs.stat(path), { code: 'ENOENT' });

async function fixture(t, options = {}) {
  const directory = await fs.mkdtemp(join(tmpdir(), 'dsh-delete-publication-'));
  const root = join(directory, 'sessions'), logs = join(root, 'aa', 's1');
  await fs.mkdir(logs, { recursive: true });
  const log = join(logs, 'session.jsonl'), note = join(logs, 'notes.md');
  await fs.writeFile(log, '{"private":"retained until durable marker"}\n');
  await fs.writeFile(note, 'unrelated file');
  const original = await fs.readFile(log);
  const marker = join(root, '.dsh-go-lifecycle', createHash('sha256').update('s1').digest('hex'), 'deleted.json');
  const ledger = await openOwnershipLedger({ directory: join(directory, 'ownership'), ownerId: randomUUID(),
    lockExclusive: native.lockExclusive, setOwnershipMarker: native.setOwnershipMarker,
    getOwnershipMarker: native.getOwnershipMarker });
  const state = { commits: 0, fallbacks: 0, finalOpens: 0, publishes: 0, cleanups: 0, claimed: false };
  const io = { ...fs, async link() { throw fail('EACCES', 'link'); }, async open(path, ...args) {
    if (path === marker && args[0] === 'wx') state.finalOpens++;
    const handle = await fs.open(path, ...args);
    if (args[0] === 'wx') await options.onOutput?.(handle, path);
    return handle;
  } };
  const publish = createAtomicPublisher({ ledger, fs: io,
    renameNoReplace(from, to) { state.commits++; return (options.renameNoReplace ?? native.renameNoReplace)(from, to); },
    atomicFuse: options.atomicFuse, onFallback() { state.fallbacks++; } });
  const service = { protocolVersion: 1, atomic: options.atomic ?? 'available', async publishAtomic(from, to, callOptions) {
    state.publishes++;
    await options.beforePublish?.(from, to);
    return publish(from, to, { ...callOptions, requireAtomic: true });
  } };
  Object.defineProperty(globalThis, publicationSymbol, { configurable: true, value: service });
  const leases = new Set();
  const acquire = async path => {
    assert.equal(leases.has(path), false); leases.add(path);
    return { async release() { leases.delete(path); } };
  };
  const storage = { root, ctx: { get: () => ({ get: () => undefined, list: () => [] }), emit() {} },
    tracker: { writers: new Map(), claimWrite() { assert.equal(state.claimed, false); state.claimed = true; }, releaseClaim() { state.claimed = false; } },
    coldLogMemo: new Map(), migrationPreparations: new Map(),
    async list() { return [{ header: { id: 's1' } }]; },
    async findLog() { return { currentPath: log }; },
    async readGenerationHeader() { return { header: { id: 's1' } }; },
    async requireStoredLog() { return { events: [] }; } };
  const seam = createDeletionSeam(storage, { acquire,
    parseGeneration: name => name === 'session.jsonl' ? {} : undefined,
    notFound: () => fail('not-found') });
  const hooks = { async prepare() {}, async inspectTasks() { return false; }, async cleanup() {
    state.cleanups++; assert.equal(existsSync(log), false);
    assert.deepEqual(JSON.parse(readFileSync(marker, 'utf8')), { version: 1, directory: 'aa/s1' });
  } };
  const released = () => { assert.equal(seam.pending.size, 0); assert.equal(leases.size, 0); assert.equal(state.claimed, false); assert.equal(publish.pendingCount, 0); };
  const retained = async () => { assert.deepEqual(await fs.readFile(log), original); assert.equal(await fs.readFile(note, 'utf8'), 'unrelated file'); assert.equal(state.cleanups, 0); released(); };
  t.after(async () => { delete globalThis[publicationSymbol]; await ledger.close(); await fs.rm(directory, { recursive: true, force: true }); });
  return { directory, logs, log, note, marker, original, state, service, seam, hooks, leases, retained, released };
}

test('real atomic commit waits for file sync before log removal and preserves unrelated files', { timeout: 15000 }, async t => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  const f = await fixture(t, { onOutput(handle) {
    const sync = handle.sync.bind(handle);
    handle.sync = async () => { await sync(); entered.resolve(); await release.promise; };
  } });
  const deletion = f.seam.delete('s1', f.hooks);
  try {
    await entered.promise;
    // The parent's deletion record, the mutation fence, the session identity and its directory.
    assert.equal(f.seam.pending.has('s1'), true); assert.equal(f.leases.size, 4);
    assert.deepEqual(await fs.readFile(f.log), f.original); await absent(f.marker);
    assert.equal(f.state.commits, 0); assert.equal(f.state.cleanups, 0);
  } finally { release.resolve(); }
  await deletion;
  assert.equal(f.state.commits, 1); assert.equal(f.state.finalOpens, 0); assert.equal(f.state.cleanups, 1);
  assert.equal(f.seam.deleted('s1'), true); assert.equal(await fs.readFile(f.note, 'utf8'), 'unrelated file');
  f.released();
});

for (const reason of ['unsupported', 'disabled-after-crash']) {
  test(`required atomic publication refuses ${reason} without creating a final or deleting logs`, { timeout: 15000 }, async t => {
    const f = await fixture(t, { atomic: reason, atomicFuse: { async run() { return { atomic: false, reason }; } } });
    assert.equal(f.seam.supported, false);
    await assert.rejects(f.seam.delete('s1', f.hooks), error => error.code === 'unavailable'
      && error.cause.code === 'ERR_OHOS_PUBLICATION_ATOMIC_REQUIRED' && error.cause.reason === reason);
    await absent(f.marker); await f.retained();
    assert.equal(f.state.commits, 0); assert.equal(f.state.finalOpens, 0); assert.equal(f.state.fallbacks, 0);
    assert.deepEqual(await fs.readdir(dirname(f.marker)), []);
  });
}

test('an actual-path injected renameat2 EINVAL cannot fall back to partial marker copy', { timeout: 15000 }, async t => {
  const f = await fixture(t, { renameNoReplace() { throw fail('EINVAL', 'renameat2'); } });
  await assert.rejects(f.seam.delete('s1', f.hooks), error => error.code === 'unavailable'
    && error.cause.code === 'ERR_OHOS_PUBLICATION_ATOMIC_REQUIRED');
  await absent(f.marker); await f.retained();
  assert.equal(f.state.commits, 1); assert.equal(f.state.finalOpens, 0); assert.equal(f.state.fallbacks, 0);
});

test('file sync failure prevents marker commit and all log deletion', { timeout: 15000 }, async t => {
  const error = fail('EIO', 'fsync');
  const f = await fixture(t, { onOutput(handle) { handle.sync = async () => { throw error; }; } });
  await assert.rejects(f.seam.delete('s1', f.hooks), value => value === error);
  await absent(f.marker); await f.retained();
  assert.equal(f.state.commits, 0); assert.equal(f.state.finalOpens, 0);
});

test('no-clobber preserves an existing complete marker; retry needs no publication service', { timeout: 15000 }, async t => {
  const bytes = JSON.stringify({ version: 1, directory: 'aa/s1' });
  const f = await fixture(t, { beforePublish: async (_, path) => { await fs.writeFile(path, bytes, { flag: 'wx' }); } });
  await assert.rejects(f.seam.delete('s1', f.hooks), { code: 'EEXIST' });
  assert.equal(await fs.readFile(f.marker, 'utf8'), bytes); await f.retained();
  delete globalThis[publicationSymbol];
  assert.equal(f.seam.supported, false);
  await f.seam.delete('s1', f.hooks);
  assert.equal(f.state.publishes, 1); assert.equal(f.state.cleanups, 1);
  assert.equal(await fs.readFile(f.marker, 'utf8'), bytes); await absent(f.log); f.released();
});

test('an invalid pre-existing marker is preserved and never authorizes log deletion', { timeout: 15000 }, async t => {
  const f = await fixture(t);
  await fs.mkdir(dirname(f.marker), { recursive: true }); await fs.writeFile(f.marker, '{partial');
  await assert.rejects(f.seam.delete('s1', f.hooks), SyntaxError);
  assert.equal(await fs.readFile(f.marker, 'utf8'), '{partial'); assert.equal(f.state.publishes, 0);
  await f.retained();
});

test('capability only reads known publication state; missing atomic method is unavailable', { timeout: 15000 }, async t => {
  const f = await fixture(t);
  for (const state of ['untried', 'trying', 'available', 'unsupported', 'disabled-after-crash']) {
    f.service.atomic = state;
    assert.equal(f.seam.supported, !['unsupported', 'disabled-after-crash'].includes(state));
  }
  assert.equal(f.state.publishes, 0); assert.equal(f.state.commits, 0);
  delete f.service.publishAtomic;
  assert.equal(f.seam.supported, false);
  await assert.rejects(f.seam.delete('s1', f.hooks), { code: 'unavailable' });
  await absent(f.marker); await f.retained();
});
