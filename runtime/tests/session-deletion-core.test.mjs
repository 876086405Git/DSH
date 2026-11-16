// The bundled deletion seam: durable tombstones, generation cleanup, fences and
// subagent-tree cascade. In-memory storage over a throwaway temp directory; no
// engine, no user data.
//   node --test runtime/tests/session-deletion-core.test.mjs
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { afterEach, beforeEach, test } from 'node:test';

const { createDeletionSeam } = await import(pathToFileURL(resolve(
  process.env.DSH_SESSION_DELETION_CORE ?? 'runtime/session-deletion/core.mjs'
)));

const leases = new Set();
const acquire = async (dir) => {
  await mkdir(dir, { recursive: true, mode: 0o700 });
  if (leases.has(dir)) throw Object.assign(new Error('owned'), { name: 'SessionAlreadyOwnedError' });
  leases.add(dir);
  return { async release() { leases.delete(dir); } };
};
const parseGeneration = (name) => (/^session(?:\.v[1-9][0-9]*)?\.jsonl(?:\.zstd)?$/.test(name) ? {} : undefined);
const notFound = (id) => Object.assign(new Error(`missing ${id}`), { code: 'not-found' });

let root;
let seam;
let files;
let headers;
let live;
let header;
let corpus;
let taskRows;
let storedEvents;
let cleanups;
let validations;
let disposals;
let taskChecks;
let emitted;
let writers;

function storage() {
  return {
    root,
    ctx: {
      get: (name) => (name === 'sessions'
        ? { get: (id) => live.get(id), list: () => [...live.values()] }
        : undefined),
      emit: (_name, id) => emitted.push(id),
    },
    tracker: { writers, claimWrite() {}, releaseClaim() {} },
    coldLogMemo: new Map(),
    migrationPreparations: new Map(),
    async findLog(id) {
      const dir = join(root, 'aa', id);
      return files[id] === undefined ? undefined : { currentPath: join(dir, files[id][0]) };
    },
    async readGenerationHeader(_record, id) {
      const current = headers[id] ?? header;
      return current === undefined ? undefined : { header: current };
    },
    async list() {
      return corpus.filter((entry) => !seam.deleted(entry.id)).map((entry) => ({ header: entry }));
    },

    async requireStoredLog() {
      return { events: storedEvents };
    },
  };
}

const directory = (id) => join(root, 'aa', id);
const cascadeFile = (id) => join(root, '.dsh-go-lifecycle', createHash('sha256').update(id).digest('hex'), 'cascade.json');
const HEADER = (id, extra = {}) => ({ id, ...extra });
const hooks = (overrides = {}) => ({
  validate: async (id) => { validations.push(id); },
  dispose: async (id, options) => { disposals.push([id, options?.cascade === true]); },
  inspectTasks: async (id) => { taskChecks.push(id); return typeof taskRows === 'function' ? taskRows(id) : taskRows; },
  cleanup: async (id) => { cleanups.push(id); },
  ...overrides,
});

async function addSession(id, extra = {}, names = ['session.jsonl']) {
  headers[id] = HEADER(id, extra);
  corpus.push(headers[id]);
  await mkdir(directory(id), { recursive: true });
  for (const name of names) await writeFile(join(directory(id), name), '{}\n');
  files[id] = names;
}

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'dsh-del-'));
  leases.clear();
  files = {};
  headers = {};
  live = new Map();
  header = HEADER('s1');
  corpus = [];
  taskRows = false;
  storedEvents = [];
  cleanups = [];
  validations = [];
  disposals = [];
  taskChecks = [];
  emitted = [];
  writers = new Map();
  seam = createDeletionSeam(storage(), { acquire, parseGeneration, notFound });
  await addSession('s1');
});

afterEach(async () => {
  await rm(root, { recursive: true, force: true });
});

test('removes every stored generation, clears derived state, and leaves a durable tombstone', async () => {
  for (const name of ['session.v2.jsonl', 'session.v3.jsonl.zstd', 'session.v4.jsonl.deadbeef.tmp']) {
    await writeFile(join(directory('s1'), name), 'x');
  }
  files.s1 = ['session.v2.jsonl', 'session.v3.jsonl.zstd', 'session.v4.jsonl.deadbeef.tmp'];
  await seam.delete('s1', hooks());
  assert.deepEqual(await readdir(directory('s1')), []);
  assert.deepEqual(cleanups, ['s1']);
  assert.equal(seam.deleted('s1'), true);
  assert.throws(() => seam.assertAdmit('s1'), (error) => error.code === 'not-found');
  // The tombstone records where the logs were so a retry can finish safely.
  assert.equal(existsSync(join(root, '.dsh-go-lifecycle')), true);
  // A stale id is not admitted into a new materialisation either.
  assert.throws(() => seam.assertParent({ id: 'child', origin: 'subagent', parentSession: 's1' }), (e) => e.code === 'not-found');
});

test('unrelated files beside the logs are left alone', async () => {
  await writeFile(join(directory('s1'), 'notes.md'), 'keep');
  await seam.delete('s1', hooks());
  assert.deepEqual(await readdir(directory('s1')), ['notes.md']);
});

test('a live agent, a subagent target and reminder rows are refused', async () => {
  live.set('s1', { header: { id: 's1' } });
  // A live agent the disposal hook fails to remove is still a writer: delete refuses.
  await assert.rejects(seam.delete('s1', hooks()), (e) => e.code === 'writer-held');
  live.clear();
  disposals = [];

  const setHeader = (next) => {
    header = next;
    headers.s1 = next;
    corpus.splice(corpus.findIndex((entry) => entry.id === 's1'), 1, next);
  };
  setHeader(HEADER('s1', { origin: 'subagent', parentSession: 'p' }));
  await assert.rejects(seam.delete('s1', hooks()), (e) => e.code === 'session-related');
  setHeader(HEADER('s1', { delegationDepth: 2 }));
  await assert.rejects(seam.delete('s1', hooks()), (e) => e.code === 'session-related');
  setHeader(HEADER('s1'));
  taskRows = true;
  await assert.rejects(seam.delete('s1', hooks()), (e) => e.code === 'session-related');
  assert.equal(seam.deleted('s1'), false);
  assert.deepEqual(cleanups, []);
  assert.deepEqual(disposals, []);
});

test('a chat with subagent history is deletable: log-local catalog/team events no longer block', async () => {
  storedEvents = [{ type: 'subagent/catalog' }, { type: 'team/task' }];
  await seam.delete('s1', hooks());
  assert.equal(seam.deleted('s1'), true);
  assert.deepEqual(cleanups, ['s1']);
});

test('deletes the whole subagent tree, leaves first, and cleans every session', async () => {
  await addSession('c1', { origin: 'subagent', parentSession: 's1' });
  await addSession('c2', { origin: 'subagent', parentSession: 's1' });
  await addSession('g1', { origin: 'subagent', parentSession: 'c1', delegationDepth: 2 });
  await seam.delete('s1', hooks());
  for (const id of ['s1', 'c1', 'c2', 'g1']) {
    assert.equal(seam.deleted(id), true, id);
    assert.deepEqual(await readdir(directory(id)), [], id);
  }
  assert.deepEqual([...cleanups].sort(), ['c1', 'c2', 'g1', 's1']);
  assert.deepEqual(emitted, ['g1', 'c2', 'c1', 's1']);
  // Every node is validated before anything is disposed; the requested chat is last.
  assert.deepEqual([...validations].sort(), ['c1', 'c2', 'g1', 's1']);
  assert.deepEqual(disposals, [['g1', true], ['c2', true], ['c1', true], ['s1', false]]);
  // The whole tree is fenced synchronously before the first await.
  assert.deepEqual([...seam.pending], []);
});

test('one active member refuses the whole tree and disposes nothing', async () => {
  await addSession('c1', { origin: 'subagent', parentSession: 's1' });
  await addSession('c2', { origin: 'subagent', parentSession: 's1' });
  const active = Object.assign(new Error('busy'), { code: 'session-active' });
  await assert.rejects(seam.delete('s1', hooks({ validate: async (id) => {
    validations.push(id);
    if (id === 'c2') throw active;
  } })), (e) => e.code === 'session-active');
  assert.deepEqual(disposals, []);
  assert.deepEqual(cleanups, []);
  // The user-visible chat was not touched, and every fence is released for a retry.
  assert.equal(seam.deleted('s1'), false);
  assert.equal(seam.pending.size, 0);
  assert.deepEqual(await readdir(directory('s1')), ['session.jsonl']);
  await seam.delete('s1', hooks());
  assert.equal(seam.deleted('s1'), true);
  assert.equal(seam.deleted('c1'), true);
  assert.equal(seam.deleted('c2'), true);
});

test('a reminder on any member refuses the tree before disposal', async () => {
  await addSession('c1', { origin: 'subagent', parentSession: 's1' });
  taskRows = (id) => id === 'c1';
  await assert.rejects(seam.delete('s1', hooks()), (e) => e.code === 'session-related');
  assert.deepEqual(disposals, []);
  assert.equal(seam.deleted('s1'), false);
  assert.equal(seam.deleted('c1'), false);
});

test('a failed child cleanup is retried and the tree still completes', async () => {
  await addSession('c1', { origin: 'subagent', parentSession: 's1' });
  await addSession('c2', { origin: 'subagent', parentSession: 's1' });
  let failed = false;
  const cleanup = async (id) => {
    cleanups.push(id);
    if (id === 'c2' && !failed) {
      failed = true;
      throw Object.assign(new Error('cache down'), { code: 'failed' });
    }
  };
  await assert.rejects(seam.delete('s1', hooks({ cleanup })), (e) => e.code === 'failed');
  assert.equal(seam.deleted('s1'), false);
  assert.equal(seam.deleted('c2'), true);
  assert.equal(seam.deleted('c1'), false);
  // Retry resumes from the tombstoned child and finishes the requested chat.
  await seam.delete('s1', hooks());
  for (const id of ['s1', 'c1', 'c2']) assert.equal(seam.deleted(id), true, id);
  assert.deepEqual(cleanups, ['c2', 'c2', 'c1', 's1']);
  assert.deepEqual(emitted, ['c2', 'c1', 's1']);
});

test('a failed parent cleanup retains descendants across reopen and retires the completed cascade', async () => {
  await addSession('c1', { origin: 'subagent', parentSession: 's1' });
  await assert.rejects(seam.delete('s1', hooks({ cleanup: async (id) => {
    cleanups.push(id);
    if (id === 's1') throw new Error('parent cleanup failed');
  } })), /parent cleanup failed/);
  assert.equal(seam.deleted('s1'), true);
  assert.equal(seam.deleted('c1'), true);
  assert.equal(existsSync(cascadeFile('s1')), true);
  seam = createDeletionSeam(storage(), { acquire, parseGeneration, notFound });
  validations = []; disposals = []; taskChecks = [];
  await seam.delete('s1', hooks());
  assert.deepEqual(cleanups, ['c1', 's1', 'c1', 's1']);
  assert.deepEqual(validations, []);
  assert.deepEqual(disposals, []);
  assert.deepEqual(taskChecks, []);
  assert.equal(existsSync(cascadeFile('s1')), false);
  await seam.delete('s1', hooks());
  assert.deepEqual(cleanups, ['c1', 's1', 'c1', 's1', 's1']);
});

for (const gate of ['active', 'scheduled']) {
  test(`a ${gate} surviving member still blocks a retry before further cleanup`, async () => {
    await addSession('c1', { origin: 'subagent', parentSession: 's1' });
    await addSession('c2', { origin: 'subagent', parentSession: 's1' });
    await assert.rejects(seam.delete('s1', hooks({ cleanup: async (id) => {
      cleanups.push(id); throw new Error('cleanup failed');
    } })), /cleanup failed/);
    const blocked = gate === 'active'
      ? { validate: async (id) => { if (id === 'c1') throw Object.assign(new Error('active'), { code: 'session-active' }); } }
      : { inspectTasks: async (id) => id === 'c1' };
    disposals = [];
    await assert.rejects(seam.delete('s1', hooks(blocked)), { code: gate === 'active' ? 'session-active' : 'session-related' });
    assert.deepEqual(cleanups, ['c2']);
    assert.deepEqual(disposals, []);
    for (const id of ['s1', 'c1']) {
      assert.equal(seam.deleted(id), false);
      assert.deepEqual(await readdir(directory(id)), ['session.jsonl']);
    }
    await seam.delete('s1', hooks());
    assert.deepEqual(cleanups, ['c2', 'c2', 'c1', 's1']);
  });
}

test('a saved surviving member must still belong to the recorded parent', async () => {
  await addSession('c1', { origin: 'subagent', parentSession: 's1' });
  await addSession('c2', { origin: 'subagent', parentSession: 's1' });
  await assert.rejects(seam.delete('s1', hooks({ cleanup: async (id) => {
    cleanups.push(id); throw new Error('cleanup failed');
  } })), /cleanup failed/);
  headers.c1.parentSession = 'unrelated-chat';
  disposals = [];
  await assert.rejects(seam.delete('s1', hooks()), { code: 'session-related' });
  assert.deepEqual(cleanups, ['c2']);
  assert.deepEqual(disposals, []);
  assert.equal(seam.deleted('s1'), false);
  assert.equal(seam.deleted('c1'), false);
  assert.deepEqual(await readdir(directory('c1')), ['session.jsonl']);
  headers.c1.parentSession = 's1';
  await seam.delete('s1', hooks());
  assert.deepEqual(cleanups, ['c2', 'c2', 'c1', 's1']);
});

test('a retry includes new descendants without forgetting the tombstoned member', async () => {
  await addSession('c1', { origin: 'subagent', parentSession: 's1' });
  await addSession('c2', { origin: 'subagent', parentSession: 's1' });
  await assert.rejects(seam.delete('s1', hooks({ cleanup: async (id) => {
    cleanups.push(id); throw new Error('cleanup failed');
  } })), /cleanup failed/);
  await addSession('g1', { origin: 'subagent', parentSession: 'c1' });
  await seam.delete('s1', hooks());
  assert.deepEqual(cleanups, ['c2', 'g1', 'c2', 'c1', 's1']);
  for (const id of ['s1', 'c1', 'c2', 'g1']) assert.equal(seam.deleted(id), true, id);
});

test('a damaged cascade record refuses deletion without losing the remaining logs', async () => {
  await addSession('c1', { origin: 'subagent', parentSession: 's1' });
  await assert.rejects(seam.delete('s1', hooks({ cleanup: async () => { throw new Error('cleanup failed'); } })), /cleanup failed/);
  const saved = await readFile(cascadeFile('s1'));
  const record = JSON.parse(saved);
  record.children[0].parentSession = 'unrelated-chat';
  await writeFile(cascadeFile('s1'), JSON.stringify(record));
  await assert.rejects(seam.delete('s1', hooks()), { code: 'failed' });
  assert.equal(seam.deleted('s1'), false);
  assert.deepEqual(await readdir(directory('s1')), ['session.jsonl']);
  assert.deepEqual(cleanups, []);
  assert.equal(seam.pending.size, 0);
  assert.equal(leases.size, 0);
  await writeFile(cascadeFile('s1'), saved);
  await seam.delete('s1', hooks());
  assert.deepEqual(cleanups, ['c1', 's1']);
});

test('a symlinked session directory is refused instead of deleting elsewhere', async () => {
  const outside = await mkdtemp(join(tmpdir(), 'dsh-outside-'));
  try {
    await writeFile(join(outside, 'session.jsonl'), 'x');
    await rm(directory('s1'), { recursive: true, force: true });
    await symlink(outside, directory('s1'));
    await assert.rejects(seam.delete('s1', hooks()), (e) => e.code === 'failed');
    assert.equal(existsSync(join(outside, 'session.jsonl')), true);
    assert.equal(seam.deleted('s1'), false);
  } finally {
    await rm(outside, { recursive: true, force: true });
  }
});

test('a failed cleanup still leaves the durable tombstone so a retry completes', async () => {
  await seam.delete('s1', hooks({
    cleanup: async () => { throw Object.assign(new Error('cache down'), { code: 'failed' }); },
  })).catch((error) => assert.equal(error.code, 'failed'));
  assert.equal(seam.deleted('s1'), true);
  assert.deepEqual(await readdir(directory('s1')), []);
  assert.deepEqual(cleanups, []);
  await seam.delete('s1', hooks());
  assert.deepEqual(cleanups, ['s1']);
});

test('concurrent deletion of one id cannot run twice, and the fence clears', async () => {
  let release;
  const gate = new Promise((done) => { release = done; });
  const blocked = seam.delete('s1', hooks({ dispose: async () => gate }));
  await new Promise((done) => setImmediate(done));
  assert.equal(seam.pending.has('s1'), true);
  await assert.rejects(seam.delete('s1', hooks()), (e) => e.code === 'writer-held');
  release();
  await blocked;
  assert.equal(seam.pending.has('s1'), false);
  assert.equal(seam.deleted('s1'), true);
});

test('a deleted id cannot be recreated, materialised, opened or written', async () => {
  await seam.delete('s1', hooks());
  assert.throws(() => seam.assertAdmit('s1'), (e) => e.code === 'not-found');
  await assert.rejects(() => seam.materialize({ id: 's1' }, async () => 'created'), (e) => e.code === 'not-found');
  await assert.rejects(() => seam.acquireWriter('s1', directory('s1')), (e) => e.code === 'not-found');
  let wrote = false;
  await seam.cacheWrite('s1', async () => { wrote = true; });
  assert.equal(wrote, false);
});

test('writers take both the identity and the directory lease, released together', async () => {
  const lease = await seam.acquireWriter('s1', directory('s1'));
  assert.equal(leases.size, 2);
  await lease.release();
  assert.equal(leases.size, 0);
  // A pre-existing writer on the same directory blocks a second writer.
  const first = await seam.acquireWriter('s1', directory('s1'));
  await assert.rejects(seam.acquireWriter('s1', directory('s1')), (e) => e.name === 'SessionAlreadyOwnedError');
  await first.release();
  assert.equal(leases.size, 0);
});

test('a deletion fence held while another writer owns the directory fails without a tombstone', async () => {
  const lease = await acquire(directory('s1'));
  await assert.rejects(seam.delete('s1', hooks()), (e) => e.name === 'SessionAlreadyOwnedError');
  assert.equal(seam.deleted('s1'), false);
  await lease.release();
  await seam.delete('s1', hooks());
  assert.equal(seam.deleted('s1'), true);
});

test('only the captured writer header can drain while deletion admission stays closed', async () => {
  const writer = { header };
  writers.set('s1', writer);
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  let entered;
  const ready = new Promise((resolve) => { entered = resolve; });
  const deleting = seam.delete('s1', hooks({ dispose: async () => {
    entered();
    await gate;
    writers.delete('s1');
  } }));
  await ready;
  assert.throws(() => seam.assertAdmit('s1'), (e) => e.code === 'not-found');
  await assert.rejects(() => seam.materialize({ ...header }, async () => {}), (e) => e.code === 'not-found');
  await assert.rejects(() => seam.acquireWriter('s1', directory('s1')), (e) => e.code === 'not-found');
  await assert.rejects(() => seam.acquireWriter('s1', directory('s1'), { ...header }), (e) => e.code === 'not-found');
  const lease = await seam.acquireWriter('s1', directory('s1'), header);
  await seam.materialize(header, async () => {});
  await lease.release();
  writers.delete('s1');
  await assert.rejects(() => seam.materialize(header, async () => {}), (e) => e.code === 'not-found');
  release();
  await deleting;
  assert.equal(seam.deleted('s1'), true);
  writers.set('s1', writer);
  await assert.rejects(() => seam.materialize(header, async () => {}), (e) => e.code === 'not-found');
});

test('dispose failure clears the captured drain allowance and deletion can retry', async () => {
  writers.set('s1', { header });
  await assert.rejects(seam.delete('s1', hooks({ dispose: async () => {
    await seam.materialize(header, async () => {});
    throw new Error('dispose failed');
  } })), /dispose failed/);
  assert.equal(seam.pending.has('s1'), false);
  assert.equal(seam.deleted('s1'), false);
  await seam.delete('s1', hooks());
  assert.equal(seam.deleted('s1'), true);
});

test('a constructing claim does not gain a drain allowance', async () => {
  writers.set('s1', null);
  await seam.delete('s1', hooks({ dispose: async () => {
    await assert.rejects(seam.materialize(header, async () => {}), (e) => e.code === 'not-found');
    await assert.rejects(seam.acquireWriter('s1', directory('s1'), header), (e) => e.code === 'not-found');
  } }));
});

test('workspace stop can finish before deletion cleanup without losing per-session fences', { timeout: 30_000 }, async () => {
  const events = [];
  const providerErrors = [];
  const sessionLeases = new Set();
  const backend = storage();
  let claimed = false;
  backend.tracker.claimWrite = () => { claimed = true; };
  backend.tracker.releaseClaim = () => { claimed = false; };
  backend.ctx.emit = (event, id) => { events.push([event, id]); };
  let startStop;
  const archiveWrite = new Promise((resolve) => { startStop = resolve; });
  let observedContention;
  const contention = new Promise((resolve) => { observedContention = resolve; });
  seam = createDeletionSeam(backend, {
    parseGeneration, notFound,
    acquire: async (dir, id) => {
      if (id === 'dsh-go-mutations' && leases.has(dir)) observedContention();
      const lease = await acquire(dir);
      if (id === 's1') sessionLeases.add(dir);
      return lease;
    },
  });

  // Explicit peers for Workspace's serial queue and one Schedule stop provider.
  // Register the unrelated archive before delete, outside its ALS context.
  let operationTail = Promise.resolve();
  const enqueue = (operation) => {
    const pending = operationTail.then(operation);
    operationTail = pending.then(() => {}, () => {});
    return pending;
  };
  const archive = enqueue(async () => {
    await archiveWrite;
    try {
      await seam.withMutation(async () => { events.push(['schedule-stop', 's2']); });
    } catch (error) { providerErrors.push(error.name); }
  });
  const cleanupError = new Error('derived cleanup unavailable');
  let failCleanup = true;
  const cleanup = () => enqueue(async () => {
    assert.equal(seam.pending.has('s1'), true);
    assert.equal(claimed, true);
    assert.equal(sessionLeases.size, 2);
    for (const dir of sessionLeases) assert.equal(leases.has(dir), true);
    assert.equal(seam.deleted('s1'), true);
    assert.deepEqual(await readdir(directory('s1')), []);
    assert.throws(() => seam.assertAdmit('s1'), (error) => error.code === 'not-found');
    await assert.rejects(seam.acquireWriter('s1', directory('s1')), (error) => error.code === 'not-found');
    await assert.rejects(seam.materialize({ id: 's1' }, async () => {}), (error) => error.code === 'not-found');
    await assert.rejects(seam.delete('s1', hooks()), (error) => error.code === 'writer-held');
    let wrote = false;
    await seam.cacheWrite('s1', async () => { wrote = true; });
    assert.equal(wrote, false);
    events.push(['forget', 's1']);
    if (failCleanup) throw cleanupError;
  });
  let taskReads = 0;
  await assert.rejects(seam.delete('s1', {
    ...hooks(),
    inspectTasks: async (id) => {
      assert.equal(id, 's1');
      // The tree-wide preflight runs before deleteOne takes the mutation lease.
      if (++taskReads === 1) return false;
      startStop();
      await contention;
      return false;
    },
    cleanup,
  }), (error) => error === cleanupError);
  await archive;
  assert.equal(taskReads, 2);
  assert.equal(seam.deleted('s1'), true);
  assert.equal(seam.pending.has('s1'), false);
  assert.equal(claimed, false);
  assert.equal(leases.size, 0);
  assert.equal(events.some(([event]) => event === 'dsh-go/session-deleted'), false);

  failCleanup = false;
  await seam.delete('s1', { ...hooks(), cleanup });
  assert.equal(seam.pending.has('s1'), false);
  assert.equal(claimed, false);
  assert.equal(leases.size, 0);
  assert.deepEqual(providerErrors, [], 'an unrelated archive stop must not exhaust the mutation lease retries');
  assert.deepEqual(events, [
    ['schedule-stop', 's2'], ['forget', 's1'], ['forget', 's1'], ['dsh-go/session-deleted', 's1'],
  ]);
});
