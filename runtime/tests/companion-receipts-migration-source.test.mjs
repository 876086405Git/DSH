import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL} from 'node:url';
assert(process.env.COMPANION_TASK_HARNESS, 'Exact pinned source harness is mandatory');
const load = name => import(pathToFileURL(resolve(process.env.COMPANION_TASK_HARNESS, name)).href);
const {JsonStorageBackend} = await load('node_modules/@deepseek-ai/dsh-storage-json/index.js');
const {DomainFacility} = await load('node_modules/@deepseek-ai/dsh-storage-domain/index.js');
const {BackendRegistry} = await load('node_modules/@deepseek-ai/dsh-storage/index.js');
const {openCompanionTaskStore} = await load('companion/task-store.js');
const legacy = {1: await load('legacy-v1/task-store.js'), 2: await load('legacy-v2/task-store.js')};
const directory = {target: {targetKey: '/original', displayPath: '/original'}, identity: 'original-directory:1'};
function storage(root) {
  const backend = new JsonStorageBackend(root); backend.dshGoCompanionStatfs = async () => ({type: 0xef53n});
  const registry = new BackendRegistry(); registry.register('actual', backend);
  const facility = new DomainFacility({storage: {backend: registry}, emit() {}, logger: {warn() {}, error() {}},
    fiber: {assertActive() {}}}, {backend: 'actual'});
  return {backend, facility};
}
for (const version of [1, 2]) for (const first of ['cancel-original', 'new-large-input'])
test(`J SOURCE_DOMAIN actual v${version} remains unchanged on open; first ${first} stamps v3 and the real old code refuses downgrade`, async t => {
  const root = await mkdtemp(join(tmpdir(), 'receipts-domain-')); t.after(() => rm(root, {recursive: true, force: true}));
  let peer = storage(root), store = await legacy[version].openCompanionTaskStore({facility: peer.facility, fs: {}});
  await store.folders.put('original-folder', {folderRef: 'original-folder', directory, createdAtMs: 1});
  const body = {v: 1, hostStoreId: store.hostStoreId, taskId: 'original-task', taskRev: 1, kind: 'host.notes_to_todo',
    origin: {sourceSessionId: 'light:original', messageId: 'original-message', itemNo: 0}, hostSessionId: null,
    args: {folderRef: 'original-folder', outputDirRef: 'original-folder', localDate: '2026-11-20', timeZone: 'UTC',
      dateBy: 'modified', outputName: 'original.md', writeMode: 'createNew'},
    deadlineAtMs: null, afterExit: 'continue', allowQueue: true};
  await store.create(body); const original = store.snapshot(body.taskId); await store.close(); await peer.backend.close();
  const path = join(root, 'companion_tasks.json'), oldBytes = await readFile(path);
  assert.equal(JSON.parse(oldBytes).unit.version, version);
  peer = storage(root); store = await openCompanionTaskStore({facility: peer.facility, fs: {}});
  assert.deepEqual(store.snapshot(body.taskId), original); assert.deepEqual(await readFile(path), oldBytes);
  if (first === 'cancel-original') await store.cancel(body.taskId, {v: 1, hostStoreId: body.hostStoreId,
    operationId: 'first-cancel', expectedTaskRev: 1, taskRev: 2});
  else await store.inputs.put('large-original', {sourceRef: 'large-original', directory,
    entry: {name: 'receipt.pdf', version: 'large-original-version', size: 4194304}, createdAtMs: 2});
  const current = store.snapshot(body.taskId), disk = JSON.parse(await readFile(path));
  assert.equal(disk.unit.version, 3); assert.equal(disk.global.hostStoreId, body.hostStoreId);
  assert.deepEqual(disk.tables.folders, JSON.parse(oldBytes).tables.folders);
  assert.deepEqual(current.steps, original.steps); assert.equal(current.hostExecutionId, original.hostExecutionId);
  await store.close(); await peer.backend.close();
  const newBytes = await readFile(path);
  peer = storage(root);
  try { await assert.rejects(legacy[version].openCompanionTaskStore({facility: peer.facility, fs: {}}),
    error => error.code === 'version-mismatch'); }
  finally { await peer.backend.close(); }
  assert.deepEqual(await readFile(path), newBytes);
  peer = storage(root); store = await openCompanionTaskStore({facility: peer.facility, fs: {}});
  try { assert.deepEqual(store.snapshot(body.taskId), current); assert.equal(store.hostStoreId, body.hostStoreId); }
  finally { await store.close(); await peer.backend.close(); }
});
