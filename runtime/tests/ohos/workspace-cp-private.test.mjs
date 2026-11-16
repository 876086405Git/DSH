import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Worker } from 'node:worker_threads';
import { createGrantAuthority } from '../../ohos/process/files/authority.mjs';
import { NativeGrantFs } from '../../ohos/process/files/grant-fs.mjs';
import { createFilesystem } from '../../ohos/process/filesystem.mjs';

const processDirectory = fileURLToPath(new URL('../../ohos/process/', import.meta.url));
const require = createRequire(import.meta.url);
const publisher = require(process.env.OHOS_GRANT_PUBLISHER);
const binding = require(process.env.OHOS_GRANT_ADDON);
const authority = createGrantAuthority({ hostLibrary: process.env.OHOS_GRANT_HOST, binding });
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const errorInfo = e => ({ name: e?.name, code: e?.code ?? null, message: e?.message, stack: e?.stack });
const report = { schema: 1, productSource: { path: path.join(processDirectory, 'files/grant-fs.mjs'),
  sha256: digest(fs.readFileSync(path.join(processDirectory, 'files/grant-fs.mjs'))) },
  status: 'STARTING', cases: [], cleanup: [], startedUtc: new Date().toISOString() };
const save = () => { if (process.env.OHOS_CP_REPORT) fs.writeFileSync(process.env.OHOS_CP_REPORT, JSON.stringify(report, null, 2) + '\n'); };
save();
function check(name, action) {
  test(name, async t => {
    const row = { name, status: 'STARTING', facts: {} }; report.cases.push(row); save();
    try { await action(t, row.facts); row.status = 'PASS'; }
    catch (error) { row.status = 'FAIL'; row.error = errorInfo(error); save(); throw error; }
    finally { save(); }
  });
}
function fixture(t, writable = true) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cp-private-'));
  const selected = path.join(root, 'selected'), temporary = path.join(root, 'temporary');
  fs.mkdirSync(selected); fs.mkdirSync(temporary);
  const uuid = randomUUID(), id = 'trusted:' + uuid, mountPoint = '/workspaces/' + uuid;
  const fd = fs.openSync(selected, 'r');
  try { publisher.workspaceGrant('publish', id, 1, fd, writable); } finally { fs.closeSync(fd); }
  const f = { root, selected, temporary, id, mountPoint, descriptor: { id, generation: 1, mountPoint, writable },
    jobs: [], handles: [], workers: [], finished: false };
  t.after(() => finish(f));
  return f;
}
function issue(f, readOnly = false) {
  const job = authority.issue([f.descriptor], { workspaceRoot: f.mountPoint, readOnly }); f.jobs.push(job); return job;
}
function direct(f, forwarded = binding) {
  const job = issue(f), value = new NativeGrantFs(forwarded, job.mounts[0].ticket); f.handles.push(value); return value;
}
async function finish(f) {
  if (f.finished) return;
  const row = { id: f.id, forcedWorkerCleanup: false, errors: [] }; report.cleanup.push(row); save();
  for (const record of f.workers) if (!record.exited) {
    row.forcedWorkerCleanup = true; save();
    try { record.terminatedExit = await record.worker.terminate(); } catch (error) { row.errors.push(errorInfo(error)); }
  }
  for (const handle of f.handles) try { handle.close(); } catch (error) { row.errors.push(errorInfo(error)); }
  row.ticketRetirements = f.jobs.map(job => { try { return job.retire(); } catch (error) { row.errors.push(errorInfo(error)); return null; } });
  try { row.beforeGrantRetire = publisher.workspaceGrant('status', f.id, 1); }
  catch (error) { row.errors.push(errorInfo(error)); }
  try { row.grantRetired = publisher.workspaceGrant('retire', f.id, 1); }
  catch (error) { row.errors.push(errorInfo(error)); }
  f.finished = true; save();
  fs.rmSync(f.root, { recursive: true, force: true });
  assert.equal(row.forcedWorkerCleanup, false, 'normal test path must have observed actual Worker exit');
  assert.deepEqual(row.errors, []);
  assert(row.ticketRetirements.every(value => value === true));
  assert.equal(row.beforeGrantRetire.leases, 0);
  assert.equal(row.grantRetired.active, false); assert.equal(row.grantRetired.drained, true);
}
function observedView(root, facts) {
  const view = path.join(root, 'observed-process'); fs.mkdirSync(path.join(view, 'files'), { recursive: true });
  for (const file of ['filesystem.mjs', 'paths.mjs', 'files/authority.mjs']) {
    fs.copyFileSync(path.join(processDirectory, file), path.join(view, file));
  }
  for (const directory of ['build', 'node_modules']) {
    fs.symlinkSync(path.join(processDirectory, directory), path.join(view, directory), 'dir');
  }
  const source = fs.readFileSync(path.join(processDirectory, 'files/grant-fs.mjs'), 'utf8');
  const transformations = [];
  let next = source;
  function replace(old, value) {
    assert.equal(next.split(old).length - 1, 1, 'local observation requires one source site');
    transformations.push({ old, replacement: value }); next = next.replace(old, value);
  }
  const boundary = next.indexOf('\n  // Same 64 MiB'); assert(boundary > 0);
  const head = next.slice(0, boundary), oldReturn = '    return Buffer.concat(parts,size);}';
  assert.equal(head.split(oldReturn).length - 1, 1);
  const newHead = head.replace(oldReturn, '    const result=Buffer.concat(parts,size);observeRead(result,size,parts.length);return result;}');
  replace(head, newHead);
  replace('Buffer.from(content,encoding(options))', 'copyFrom(content,encoding(options))');
  replace('Buffer.from(content)', 'copyFrom(content)');
  replace('if(bytes.length>limit)', 'observeWrite(content,bytes,value);if(bytes.length>limit)');
  const imported = "import { copyFrom, observeRead, observeWrite } from './copy-observer.mjs';\n";
  next = imported + next;
  let reverse = next.slice(imported.length);
  for (const change of [...transformations].reverse()) reverse = reverse.replace(change.replacement, change.old);
  assert.equal(reverse, source);
  fs.writeFileSync(path.join(view, 'files/grant-fs.mjs'), next);
  fs.copyFileSync(fileURLToPath(new URL('./workspace-cp-private-observer.mjs', import.meta.url)), path.join(view, 'files/copy-observer.mjs'));
  facts.sourceObservation = { sourceSha256: digest(Buffer.from(source)), observedSha256: digest(Buffer.from(next)),
    inverseExact: true, sites: transformations.map(change => ({ originalSha256: digest(Buffer.from(change.old)), replacementSha256: digest(Buffer.from(change.replacement)) })) };
  return view;
}
async function stock(f, script, facts, { readOnly = false, observed = false } = {}) {
  const job = issue(f, readOnly);
  const directory = observed ? observedView(f.root, facts) : processDirectory;
  const worker = new Worker(new URL('./workspace-cp-private-worker.mjs', import.meta.url), { workerData: {
    binding: process.env.OHOS_GRANT_ADDON, processDirectory: directory,
    temporary: f.temporary, cwd: f.mountPoint, mounts: job.mounts, script, readOnly, observed } });
  const record = { worker, exited: false }; f.workers.push(record);
  const exit = new Promise(resolve => worker.once('exit', code => { record.exited = true; facts.workerExit = code; resolve(code); }));
  const message = new Promise((resolve, reject) => {
    worker.once('message', value => { facts.message = value; resolve(value); });
    worker.once('error', error => { facts.workerError = errorInfo(error); reject(error); });
    worker.once('exit', code => { if (!facts.message) reject(new Error('Worker exited without a result: ' + code)); });
  });
  const reply = await message; save(); await exit;
  assert.equal(facts.workerExit, 0); assert.equal(reply.closeFailure, undefined);
  assert.equal(reply.filesystemClosed, true);
  facts.ticketRetired = job.retire(); assert.equal(facts.ticketRetired, true);
  facts.afterWorkerExit = publisher.workspaceGrant('status', f.id, 1);
  assert.equal(facts.afterWorkerExit.leases, 0);
  return reply;
}
function expectStockSuccess(reply) {
  assert.equal(reply.failure, undefined, JSON.stringify(reply.failure)); assert.equal(reply.result.exitCode, 0, JSON.stringify(reply));
  assert.equal(reply.result.stdout, ''); assert.equal(reply.result.stderr, '');
}

check('uninstrumented stock cp preserves the full 4 MiB plus partial tail and retires its lease', async (t, facts) => {
  const f = fixture(t), input = Buffer.alloc(4 * 1024 * 1024 + 17);
  for (let i = 0; i < input.length; i++) input[i] = (i * 37 + 11) & 255;
  fs.writeFileSync(path.join(f.selected, 'input.bin'), input);
  const reply = await stock(f, 'cp input.bin output.bin', facts); expectStockSuccess(reply);
  const output = fs.readFileSync(path.join(f.selected, 'output.bin')); assert.deepEqual(output, input);
  facts.bytes = input.length; facts.inputSha256 = digest(input); facts.outputSha256 = digest(output);
  assert.equal(reply.observation, undefined); await finish(f); facts.functionalAndLeaseControlsPassed = true;
});
check('stock cp privately read bytes avoid another full-input Buffer.from', async (t, facts) => {
  const f = fixture(t), input = Buffer.alloc(4 * 1024 * 1024 + 17);
  for (let i = 0; i < input.length; i++) input[i] = (i * 37 + 11) & 255;
  fs.writeFileSync(path.join(f.selected, 'input.bin'), input);
  const reply = await stock(f, 'cp input.bin output.bin', facts, { observed: true }); expectStockSuccess(reply);
  const output = fs.readFileSync(path.join(f.selected, 'output.bin')); assert.deepEqual(output, input);
  facts.bytes = input.length; facts.inputSha256 = digest(input); facts.outputSha256 = digest(output);
  const { reads, conversions, writes } = reply.observation;
  assert.equal(reads.length, 1); assert.equal(writes.length, 1);
  assert.equal(reads[0].size, input.length); assert.equal(reads[0].partCount, 5); assert.equal(reads[0].isBuffer, true);
  assert.equal(writes[0].readId, reads[0].id); assert.equal(writes[0].inputBytes, input.length); assert.equal(writes[0].outputBytes, input.length);
  assert.equal(writes[0].inputIsBuffer, true);
  assert(conversions.every(row => row.readId === reads[0].id && row.inputBytes === input.length && row.outputBytes === input.length));
  facts.extraCopy = { calls: conversions.length, bytes: conversions.reduce((sum, row) => sum + row.outputBytes, 0), goalCalls: 0 };
  await finish(f); facts.functionalAndLeaseControlsPassed = true; save();
  assert.equal(facts.extraCopy.calls, 0, 'private cp must not copy its owned whole read buffer again');
  assert.equal(writes[0].sameObject, true, 'the private writer must receive the original owned Buffer');
});
check('stock empty and shallow-recursive cp preserve bytes and truncation', async (t, facts) => {
  const f = fixture(t); fs.writeFileSync(path.join(f.selected, 'empty'), ''); fs.writeFileSync(path.join(f.selected, 'target'), 'OLD');
  fs.mkdirSync(path.join(f.selected, 'tree')); fs.writeFileSync(path.join(f.selected, 'tree', 'leaf'), Buffer.from([0, 255, 65]));
  const reply = await stock(f, 'cp empty target; cp -r tree copied', facts); expectStockSuccess(reply);
  assert.equal(fs.readFileSync(path.join(f.selected, 'target')).length, 0);
  assert.deepEqual(fs.readFileSync(path.join(f.selected, 'copied', 'leaf')), Buffer.from([0, 255, 65]));
  facts.emptyBytes = 0; facts.recursiveLeaf = [0, 255, 65];
});
check('public write snapshots before the position getter mutates its input', async (t, facts) => {
  const f = fixture(t), nfs = direct(f), input = Buffer.from('AB'), events = [];
  const result = nfs.writeFile('/written', input, { get ohosWritePosition() { events.push('getter'); input[0] = 90; return 0; } });
  events.push('returned'); assert(result instanceof Promise); await result;
  assert.equal(fs.readFileSync(path.join(f.selected, 'written'), 'utf8'), 'AB'); assert.equal(input.toString(), 'ZB');
  assert.deepEqual(events, ['getter', 'returned']); facts.events = events; facts.output = 'AB'; facts.callerAfter = input.toString();
});
check('public append also snapshots before the position getter', async (t, facts) => {
  const f = fixture(t), nfs = direct(f), input = Buffer.from('AB'); fs.writeFileSync(path.join(f.selected, 'written'), 'P');
  await nfs.appendFile('/written', input, { get ohosWritePosition() { input[0] = 90; return undefined; } });
  facts.output = fs.readFileSync(path.join(f.selected, 'written'), 'utf8'); assert.equal(facts.output, 'PAB');
});
check('public subviews and valueOf conversion/error remain on the original snapshot path', async (t, facts) => {
  const f = fixture(t), nfs = direct(f), bytes = new Uint8Array([99, 65, 66, 99]);
  await nfs.writeFile('/subview', bytes.subarray(1, 3)); assert.equal(fs.readFileSync(path.join(f.selected, 'subview'), 'utf8'), 'AB');
  let valueOfCalls = 0; const value = new Uint8Array([88]); value.valueOf = () => { valueOfCalls++; return Buffer.from('V'); };
  // Record the real current Buffer.from contract before the public operation; do not override the builtin.
  const expected = Buffer.from(value); valueOfCalls = 0; await nfs.writeFile('/converted', value);
  assert.deepEqual(fs.readFileSync(path.join(f.selected, 'converted')), expected); facts.valueOfCalls = valueOfCalls;
  facts.converted = [...expected]; facts.subview = [65, 66];
  let optionReads = 0; const failure = new Error('local content conversion failed'), bad = new Uint8Array([1]);
  bad.valueOf = () => { throw failure; };
  const result = nfs.writeFile('/failed', bad, { get ohosWritePosition() { optionReads++; return 0; } });
  assert(result instanceof Promise); await assert.rejects(result, error => error === failure);
  assert.equal(optionReads, 0); assert.equal(fs.existsSync(path.join(f.selected, 'failed')), false); facts.optionsReadAfterConversionFailure = optionReads;
});
check('real close between read and write awaits prevents every destination write', async (t, facts) => {
  const f = fixture(t), events = []; fs.writeFileSync(path.join(f.selected, 'source'), 'SOURCE'); fs.writeFileSync(path.join(f.selected, 'dest'), 'OLD');
  let readCalls = 0, writeCalls = 0, closeError;
  const forwarded = { ...binding, read(...args) { readCalls++; events.push('read'); return binding.read(...args); },
    write(...args) { writeCalls++; events.push('write'); return binding.write(...args); } };
  const nfs = direct(f, forwarded), operation = nfs.cp('/source', '/dest');
  queueMicrotask(() => { try { nfs.close(); events.push('close'); } catch (error) { closeError = errorInfo(error); } });
  await assert.rejects(operation, { code: 'ERR_WORKSPACE_LEASE' });
  assert.equal(closeError, undefined); assert(readCalls >= 2); assert.equal(writeCalls, 0); assert.equal(events.at(-1), 'close');
  assert.equal(fs.readFileSync(path.join(f.selected, 'dest'), 'utf8'), 'OLD'); facts.events = events; facts.readCalls = readCalls; facts.writeCalls = writeCalls;
});
check('actual read failure retains its rejected-Promise await checkpoint', async (t, facts) => {
  const f = fixture(t), events = []; fs.writeFileSync(path.join(f.selected, 'source'), 'SOURCE');
  let nativeError, markersDone; const markerPromise = new Promise(resolve => { markersDone = resolve; });
  const forwarded = { ...binding, stat(...args) { const result = binding.stat(...args); events.push('stat-return');
    queueMicrotask(() => { fs.unlinkSync(path.join(f.selected, 'source')); events.push('unlink'); }); return result; },
    read(...args) { events.push('read-enter'); try { return binding.read(...args); } catch (error) {
      nativeError = error; events.push('read-throw'); queueMicrotask(() => { events.push('Q1'); queueMicrotask(() => { events.push('Q2'); markersDone(); }); }); throw error;
    } } };
  const nfs = direct(f, forwarded); let caught;
  await nfs.cp('/source', 'invalid-destination').then(() => { events.push('unexpected-success'); }, error => { caught = error; events.push('cp-rejected'); });
  facts.events = events; facts.nativeError = errorInfo(nativeError); facts.error = errorInfo(caught); save();
  assert(nativeError, 'must reach an actual native read failure'); await markerPromise;
  assert.equal(nativeError.code, 'ENOENT'); assert.equal(caught, nativeError);
  assert.deepEqual(events, ['stat-return', 'unlink', 'read-enter', 'read-throw', 'Q1', 'Q2', 'cp-rejected']);
});
check('actual readonly write failure retains its rejected-Promise await checkpoint', async (t, facts) => {
  const f = fixture(t, false), events = []; fs.writeFileSync(path.join(f.selected, 'source'), 'SOURCE'); fs.writeFileSync(path.join(f.selected, 'dest'), 'OLD');
  let nativeError, markersDone; const markerPromise = new Promise(resolve => { markersDone = resolve; });
  const forwarded = { ...binding, write(...args) { events.push('write-enter'); try { return binding.write(...args); } catch (error) {
    nativeError = error; events.push('write-throw'); queueMicrotask(() => { events.push('Q1'); queueMicrotask(() => { events.push('Q2'); markersDone(); }); }); throw error;
  } } };
  const nfs = direct(f, forwarded); let caught;
  await nfs.cp('/source', '/dest').then(() => { events.push('unexpected-success'); }, error => { caught = error; events.push('cp-rejected'); });
  facts.events = events; facts.nativeError = errorInfo(nativeError); facts.error = errorInfo(caught); save();
  assert(nativeError, 'must reach actual native write refusal'); await markerPromise;
  assert.equal(typeof nativeError.code, 'string'); assert.equal(caught, nativeError);
  assert.deepEqual(events, ['write-enter', 'write-throw', 'Q1', 'Q2', 'cp-rejected']);
  assert.equal(fs.readFileSync(path.join(f.selected, 'dest'), 'utf8'), 'OLD');
});
check('public read still performs synchronous IO but returns its own rejected Promise for path errors', async (t, facts) => {
  const f = fixture(t), events = []; fs.writeFileSync(path.join(f.selected, 'source'), 'AB');
  const nfs = direct(f, { ...binding, read(...args) { events.push('read'); return binding.read(...args); } });
  const result = nfs.readFileBuffer('/source'); events.push('returned'); assert(result instanceof Promise);
  assert.deepEqual(await result, Buffer.from('AB')); assert.deepEqual(events, ['read', 'read', 'returned']);
  const rejected = nfs.readFileBuffer('invalid'); assert(rejected instanceof Promise); await assert.rejects(rejected, { code: 'EINVAL' }); facts.events = events;
});
check('stock cp task-readonly and native-readonly paths both preserve destination', async (t, facts) => {
  facts.paths = [];
  for (const [writable, readOnly] of [[true, true], [false, false]]) {
    const f = fixture(t, writable); fs.writeFileSync(path.join(f.selected, 'source'), 'SOURCE'); fs.writeFileSync(path.join(f.selected, 'dest'), 'OLD');
    const row = { writable, readOnly }; facts.paths.push(row);
    const reply = await stock(f, 'cp source dest', row, { readOnly });
    assert(reply.failure || reply.result.exitCode !== 0); assert.equal(fs.readFileSync(path.join(f.selected, 'dest'), 'utf8'), 'OLD');
    await finish(f);
  }
});
check('cross-grant and grant-to-host cp are denied before another filesystem copy path', async (t, facts) => {
  const first = fixture(t), second = fixture(t); fs.writeFileSync(path.join(first.selected, 'source'), 'SOURCE');
  const a = issue(first), b = issue(second);
  const filesystem = createFilesystem([first.temporary], { mode: 'workspace-write' }, { grantMounts: [...a.mounts, ...b.mounts], binding });
  first.handles.push(filesystem); filesystem.seal();
  assert.throws(() => filesystem.fs.cp(first.mountPoint + '/source', second.mountPoint + '/dest'), { code: 'EXDEV' });
  assert.throws(() => filesystem.fs.cp(first.mountPoint + '/source', path.join(first.temporary, 'dest')), { code: 'EXDEV' });
  assert.equal(fs.existsSync(path.join(second.selected, 'dest')), false); assert.equal(fs.existsSync(path.join(first.temporary, 'dest')), false);
  filesystem.close(); facts.results = ['EXDEV', 'EXDEV'];
});

after(() => {
  try { report.authorityClosed = authority.close(); assert.equal(report.authorityClosed, true); }
  catch (error) { report.authorityCloseError = errorInfo(error); throw error; }
  finally {
    report.status = report.cases.length === 12 && report.cases.every(row => row.status === 'PASS') && report.authorityClosed === true && report.cleanup.every(row => !row.forcedWorkerCleanup && row.errors.length === 0 && row.ticketRetirements.every(value => value === true) && row.beforeGrantRetire?.leases === 0 && row.grantRetired?.drained === true && row.grantRetired?.active === false) ? 'ALL_CONTROLS_AND_RESOURCE_TARGET_PASSED' : 'FAILED_ASSERTIONS_OR_CLEANUP';
    report.finishedUtc = new Date().toISOString(); save();
    console.log('CP_PRIVATE_REPORT ' + JSON.stringify(report));
  }
});
