import { symlinkFixture } from './host-link-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { constants, renameSync, mkdirSync, writeFileSync } from 'node:fs';
import { Worker } from 'node:worker_threads';
import { tmpdir } from 'node:os';
import { join, isAbsolute } from 'node:path';
import { createRequire } from 'node:module';
import { randomUUID } from 'node:crypto';
import { openOwnershipLedger } from '../../ohos/publication/ledger.mjs';
import { createOwnedGitResources } from '../../ohos/process/owned-resources.mjs';

const nativePath = process.env.DSH_TEST_PUBLICATION_BINDING;
assert.ok(typeof nativePath === 'string' && isAbsolute(nativePath), 'explicit rebuilt publication binding required');
const binding = createRequire(import.meta.url)(nativePath);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const deferred = () => Promise.withResolvers();
const errorCode = code => Object.assign(new Error('injected ' + code), { code });
const records = async path => JSON.parse(await fs.readFile(join(path, 'ledger.json'), 'utf8')).entries;
const absent = async path => {
  try { await fs.lstat(path); return false; } catch (error) { if (error.code === 'ENOENT') return true; throw error; }
};
const includesError = (error, code) => !!error && (error.code === code || includesError(error.cause, code)
  || (Array.isArray(error.errors) && error.errors.some(item => includesError(item, code))));
async function fixture(t, options = {}) {
  const root = await fs.mkdtemp(join(tmpdir(), 'dsh-parent-owned-'));
  const workspace = join(root, 'session-A'), other = join(root, 'session-B'), temporary = join(root, 'temporary');
  const directory = join(root, 'ownership');
  await Promise.all([workspace, other, temporary].map(path => fs.mkdir(path)));
  const ledger = await openOwnershipLedger({ directory, ownerId: randomUUID(), ...binding, ...options.ledger });
  const sessions = [];
  t.after(async () => {
    for (const session of sessions) await session.finish().catch(() => {});
    await ledger.close();
    await fs.rm(root, { recursive: true, force: true });
  });
  return { root, workspace, other, temporary, directory, ledger,
    session(overrides = {}) {
      const session = createOwnedGitResources({ roots: [workspace, temporary], getOwnership: () => ledger, ...overrides });
      sessions.push(session); return session;
    } };
}

test('idle owner and read-only rejection do not open or borrow another ledger', async t => {
  const f = await fixture(t); let borrowed = 0;
  const idle = f.session({ getOwnership() { borrowed++; throw new Error('must not borrow'); } });
  await idle.finish();
  const ro = f.session({ policy: { mode: 'read-only' }, getOwnership() { borrowed++; throw new Error('must not borrow'); } });
  await assert.rejects(ro.createIndex({ target: join(f.workspace, 'index'), content: new Uint8Array() }), { code: 'EACCES' });
  await ro.finish(); assert.equal(borrowed, 0);
});

test('real durable reserve and marker identification precede the first payload byte', async t => {
  const f = await fixture(t); const seen = [];
  const session = f.session({ async onStage(name, row) {
    if (name === 'reserved') {
      assert.equal(await absent(row.path), true);
      assert.equal((await records(f.directory)).find(x => x.token === row.token).state, 'reserved');
      seen.push('reserved');
    }
    if (name === 'created') {
      assert.equal((await fs.stat(row.path)).size, 0);
      assert.equal((await records(f.directory)).find(x => x.token === row.token).state, 'reserved');
      seen.push('created-empty');
    }
    if (name === 'identified') {
      assert.equal((await fs.stat(row.path)).size, 0);
      const rowOnDisk = (await records(f.directory)).find(x => x.token === row.token);
      assert.equal(rowOnDisk.state, 'identified');
      const fd = await fs.open(row.path, constants.O_RDONLY | constants.O_NOFOLLOW);
      try { assert.equal(binding.getOwnershipMarker(fd.fd), row.token); } finally { await fd.close(); }
      seen.push('identified-empty');
    }
  } });
  const index = await session.createIndex({ target: join(f.workspace, 'index'), content: Buffer.from('完整索引\n'), mode: 0o600 });
  assert.equal(await fs.readFile(index.path, 'utf8'), '完整索引\n');
  assert.deepEqual(seen, ['reserved', 'created-empty', 'identified-empty']);
  await session.releaseIndex(index.id);
  assert.deepEqual(await records(f.directory), []);
});

test('owned index writes preserve inode and use exact positional writes through short writes', async t => {
  const f = await fixture(t); const positions = [];
  const wrapped = { ...fs, async open(...args) {
    const file = await fs.open(...args);
    return new Proxy(file, { get(target, key) {
      if (key === 'write') return async (buffer, offset, length, position) => {
        positions.push(position);
        return target.write(buffer, offset, Math.min(length, 3), position);
      };
      const value = target[key]; return typeof value === 'function' ? value.bind(target) : value;
    } });
  } };
  const session = f.session({ fs: wrapped });
  const target = join(f.workspace, 'index');
  const index = await session.createIndex({ target, content: Buffer.from('abcdefghijk') });
  const before = await fs.stat(index.path, { bigint: true });
  await session.writeIndex(index.id, Buffer.from('Z'));
  const after = await fs.stat(index.path, { bigint: true });
  assert.equal(after.ino, before.ino); assert.equal(after.dev, before.dev);
  assert.equal(await fs.readFile(index.path, 'utf8'), 'Z');
  assert.deepEqual(positions, [0, 3, 6, 9, 0]);
  await session.commitIndex(index.id);
  assert.equal((await fs.stat(target, { bigint: true })).ino, before.ino);
  assert.equal(await fs.readFile(target, 'utf8'), 'Z');
  assert.equal(session.resourceCount, 0);
  assert.deepEqual(await records(f.directory), []);
});

for (const phase of ['write', 'truncate', 'sync']) test(`incomplete owned index ${phase} cannot commit a partly updated inode`, async t => {
  const f = await fixture(t);
  let armed = false;
  const wrapped = { ...fs, async open(...args) {
    const file = await fs.open(...args);
    return new Proxy(file, { get(target, key) {
      if (key === phase) return async (...values) => {
        if (!armed) return target[key](...values);
        if (key === 'write') {
          const [buffer, offset, length, position] = values;
          await target.write(buffer, offset, Math.min(length, 3), position);
        }
        throw errorCode('EIO');
      };
      const value = target[key]; return typeof value === 'function' ? value.bind(target) : value;
    } });
  } };
  const session = f.session({ fs: wrapped });
  const target = join(f.workspace, 'index');
  await fs.writeFile(target, 'original-final');
  const index = await session.createIndex({ target, content: Buffer.from('old-index-content') });
  armed = true;
  await assert.rejects(session.writeIndex(index.id, Buffer.from('updated')), error => includesError(error, 'EIO'));
  const attempt = await session.commitIndex(index.id).then(() => ({ committed: true }), error => ({ code: error.code }));
  t.diagnostic(JSON.stringify({ phase, attempt, final: await fs.readFile(target, 'utf8') }));
  assert.equal(attempt.code, 'ERR_OHOS_GIT_RESOURCE_DIRTY');
  assert.equal(await fs.readFile(target, 'utf8'), 'original-final');
  armed = false;
  await session.writeIndex(index.id, Buffer.from('complete-retry'));
  await session.commitIndex(index.id);
  assert.equal(await fs.readFile(target, 'utf8'), 'complete-retry');
});

test('input views are copied before queueing and shared buffers are rejected before reserve', async t => {
  const f = await fixture(t); const session = f.session();
  const source = Buffer.from('xxABCDEyy'), view = source.subarray(2, 7);
  const pending = session.createIndex({ target: join(f.workspace, 'index'), content: view });
  source.fill(122);
  const index = await pending;
  assert.equal(await fs.readFile(index.path, 'utf8'), 'ABCDE');
  await assert.rejects(session.writeIndex(index.id, new Uint8Array(new SharedArrayBuffer(5))), { code: 'ERR_OHOS_GIT_RESOURCE_CONTENT' });
  assert.equal((await records(f.directory)).length, 1);
});

test('resource ids and owned paths cannot cross jobs even when roots are shared', async t => {
  const f = await fixture(t); const first = f.session(), second = f.session();
  const index = await first.createIndex({ target: join(f.workspace, 'index'), content: Buffer.from('first') });
  await assert.rejects(second.writeIndex(index.id, Buffer.from('bad')), { code: 'ERR_OHOS_GIT_RESOURCE_ID' });
  await assert.rejects(second.commitIndex(index.id), { code: 'ERR_OHOS_GIT_RESOURCE_ID' });
  await assert.rejects(second.releaseIndex(index.id), { code: 'ERR_OHOS_GIT_RESOURCE_ID' });
  await assert.rejects(second.writeMetadata({ target: index.path, content: Buffer.from('bad') }), { code: 'ERR_OHOS_GIT_RESOURCE_TARGET' });
  assert.equal(await fs.readFile(index.path, 'utf8'), 'first');
});

test('another host session root and live or dangling outward symlinks remain denied', async t => {
  const f = await fixture(t); const session = f.session();
  await fs.writeFile(join(f.other, 'foreign'), 'foreign');
  await symlinkFixture(f.other, join(f.workspace, 'outside'));
  await symlinkFixture(join(f.other, 'missing'), join(f.workspace, 'dangling'));
  for (const target of [join(f.other, 'foreign'), join(f.workspace, 'outside/foreign'), join(f.workspace, 'dangling')]) {
    await assert.rejects(session.writeMetadata({ target, content: Buffer.from('bad'), roots: [f.other] }), { code: 'EACCES' });
  }
  assert.equal(await fs.readFile(join(f.other, 'foreign'), 'utf8'), 'foreign');
  assert.equal(await absent(join(f.other, 'missing')), true);
  assert.equal(session.resourceCount, 0);
});

test('internal symlink and explicitly granted temporary root keep their authority', async t => {
  const f = await fixture(t); const session = f.session();
  await fs.mkdir(join(f.workspace, 'data'));
  await symlinkFixture(join(f.workspace, 'data'), join(f.workspace, 'alias'));
  await session.writeMetadata({ target: join(f.workspace, 'alias/ref'), content: Buffer.from('ref'), mode: 0o600 });
  await session.writeMetadata({ target: join(f.temporary, 'private-index'), content: Buffer.from('private') });
  assert.equal(await fs.readFile(join(f.workspace, 'data/ref'), 'utf8'), 'ref');
  assert.equal(await fs.readFile(join(f.temporary, 'private-index'), 'utf8'), 'private');
});

for (const phase of ['reserved', 'created', 'identified', 'before-write', 'before-commit']) {
  test('cancel at ' + phase + ' drains accepted work then clears only owned resources', async t => {
    const f = await fixture(t); const entered = deferred(), resume = deferred(); let staged;
    const target = join(f.workspace, 'index'), foreign = join(f.workspace, '.dsh-ohos-git-foreign.tmp');
    await fs.writeFile(target, 'original'); await fs.writeFile(foreign, 'foreign');
    const session = f.session({ async onStage(name, row) {
      if (name === phase) { staged = row.path; entered.resolve(); await resume.promise; }
    } });
    const work = session.writeMetadata({ target, content: Buffer.alloc(100001, 65), mode: 0o600 });
    const rejected = assert.rejects(work, { code: 'ERR_OHOS_GIT_RESOURCE_STOPPED' });
    await entered.promise;
    session.stop(); let finished = false;
    const ending = session.finish().then(() => { finished = true; });
    await delay(20); assert.equal(finished, false);
    await assert.rejects(session.createIndex({ target, content: new Uint8Array() }), { code: 'ERR_OHOS_GIT_RESOURCE_STOPPED' });
    resume.resolve(); await rejected; await ending;
    assert.equal(await absent(staged), true);
    assert.equal(await fs.readFile(target, 'utf8'), 'original');
    assert.equal(await fs.readFile(foreign, 'utf8'), 'foreign');
    assert.deepEqual(await records(f.directory), []);
    assert.equal(session.pendingCount, 0); assert.equal(session.resourceCount, 0);
    await delay(25); assert.equal(await fs.readFile(target, 'utf8'), 'original');
  });
}

test('real pending parent write must settle before cleanup and completion', async t => {
  const f = await fixture(t); const entered = deferred(), resume = deferred(); const events = [];
  let blocked = false, staged;
  const io = { ...fs, async open(...args) {
    const file = await fs.open(...args);
    return new Proxy(file, { get(target, key) {
      if (key === 'write') return async (...writeArgs) => {
        events.push('write-issued');
        const result = await target.write(...writeArgs);
        if (!blocked) { blocked = true; entered.resolve(); await resume.promise; }
        events.push('write-returned'); return result;
      };
      if (key === 'close') return async () => { await target.close(); events.push('file-closed'); };
      const value = target[key]; return typeof value === 'function' ? value.bind(target) : value;
    } });
  } };
  const session = f.session({ fs: io, onStage(name, row) {
    staged = row.path;
    if (name === 'after-release') events.push('ledger-released');
  } });
  const work = session.writeMetadata({ target: join(f.workspace, 'index'), content: Buffer.alloc(200000, 88) });
  const rejected = assert.rejects(work, { code: 'ERR_OHOS_GIT_RESOURCE_STOPPED' });
  await entered.promise; session.stop(); let done = false;
  const ending = session.finish().then(() => { events.push('finished'); done = true; });
  await delay(20); assert.equal(done, false); assert.equal(await absent(staged), false);
  resume.resolve(); await rejected; await ending;
  assert.equal(await absent(staged), true);
  assert.ok(events.indexOf('write-returned') < events.indexOf('file-closed'));
  assert.ok(events.indexOf('file-closed') < events.indexOf('ledger-released'));
  assert.ok(events.indexOf('ledger-released') < events.indexOf('finished'));
});

test('an already-issued real rename settles after cancel and the committed final is retained', async t => {
  const f = await fixture(t); const entered = deferred(), resume = deferred(); const events = [];
  const target = join(f.workspace, 'index'); await fs.writeFile(target, 'original');
  const io = { ...fs, async rename(source, final) {
    events.push('rename-issued'); await fs.rename(source, final);
    events.push('rename-committed'); entered.resolve(); await resume.promise;
    events.push('rename-returned');
  } };
  const session = f.session({ fs: io, onStage(name) { if (name === 'after-release') events.push('ledger-released'); } });
  const work = session.writeMetadata({ target, content: Buffer.from('new') });
  await entered.promise; assert.equal(await fs.readFile(target, 'utf8'), 'new');
  session.stop(); let done = false;
  const ending = session.finish().then(() => { events.push('finished'); done = true; });
  await delay(20); assert.equal(done, false);
  resume.resolve(); await work; await ending;
  assert.equal(await fs.readFile(target, 'utf8'), 'new');
  assert.deepEqual(events, ['rename-issued', 'rename-committed', 'rename-returned', 'ledger-released', 'finished']);
  assert.deepEqual(await records(f.directory), []);
});

test('successful metadata commit plus real ledger persistence failure preserves final and rejects even after stop', async t => {
  let armed = false;
  const ledgerFs = { ...fs, async rename(source, target) {
    if (armed && target.endsWith('/ledger.json')) throw errorCode('EIO');
    return fs.rename(source, target);
  } };
  const f = await fixture(t, { ledger: { fs: ledgerFs } });
  const target = join(f.workspace, 'index'); await fs.writeFile(target, 'original');
  const session = f.session({ onStage(name) { if (name === 'after-commit') armed = true; } });
  await assert.rejects(session.writeMetadata({ target, content: Buffer.from('committed') }),
    error => error.code === 'ERR_OHOS_GIT_COMMITTED_CLEANUP' && error.committed === true && includesError(error, 'EIO'));
  assert.equal(await fs.readFile(target, 'utf8'), 'committed');
  session.stop();
  await assert.rejects(session.finish(), error => includesError(error, 'EIO'));
  const leftover = await records(f.directory);
  assert.equal(leftover.length, 1); assert.equal(leftover[0].state, 'identified');
  assert.equal(await absent(leftover[0].path), true);
  assert.equal(await absent(join(f.directory, 'ledger.pending')), false);
  assert.equal(await fs.readFile(target, 'utf8'), 'committed');
});

test('reserve persistence failure poisons retries and cannot be masked by cancellation', async t => {
  let failReserve = false;
  const ledgerFs = { ...fs, async rename(source, target) {
    if (failReserve && target.endsWith('/ledger.json')) throw errorCode('EIO');
    return fs.rename(source, target);
  } };
  const f = await fixture(t, { ledger: { fs: ledgerFs } }); failReserve = true;
  const session = f.session(); const target = join(f.workspace, 'index');
  await assert.rejects(session.writeMetadata({ target, content: Buffer.from('new') }), { code: 'EIO' });
  await assert.rejects(session.writeMetadata({ target, content: Buffer.from('retry') }), { code: 'ERR_OHOS_GIT_RESOURCE_POISONED' });
  session.stop(); await assert.rejects(session.finish(), error => includesError(error, 'EIO'));
  assert.equal(await absent(target), true);
});

test('foreign replacement is preserved, recorded and visible after stop', async t => {
  const f = await fixture(t); const session = f.session();
  const index = await session.createIndex({ target: join(f.workspace, 'index'), content: Buffer.from('ours') });
  await fs.unlink(index.path); await fs.writeFile(index.path, 'foreign');
  session.stop();
  await assert.rejects(session.finish(), error => includesError(error, 'ERR_OHOS_PUBLICATION_TEMP_REPLACED'));
  assert.equal(await fs.readFile(index.path, 'utf8'), 'foreign');
  assert.equal((await records(f.directory)).length, 1);
});

test('cleanup must not retry an identity-only unlink after closing its held fd', async t => {
  const f = await fixture(t); let failOnce = true;
  const session = f.session({ onStage(name) {
    if (name === 'before-cleanup' && failOnce) { failOnce = false; throw errorCode('EIO'); }
  } });
  const index = await session.createIndex({ target: join(f.workspace, 'index'), content: Buffer.from('preserve') });
  await assert.rejects(session.releaseIndex(index.id), { code: 'EIO' });
  await assert.rejects(session.finish(), error => includesError(error, 'EIO'));
  // The first failing cleanup closed the live handle. Existing receipts alone
  // cannot safely establish ownership on a later attempt; restart uses marker.
  assert.equal(await fs.readFile(index.path, 'utf8'), 'preserve');
  assert.equal((await records(f.directory)).length, 1);
});

async function cloneFixture(fn) {
  const root=await fs.mkdtemp(join(tmpdir(),'clone-native-'));
  try {await fn(root);} finally {await fs.rm(root,{recursive:true,force:true});}
}
async function cloneHeld(root) {
  const found=[];
  for(const fd of await fs.readdir('/proc/self/fd')) {
    try {if((await fs.readlink('/proc/self/fd/'+fd)).startsWith(root)) found.push(fd);} catch{}
  }
  return found;
}
test('native cleanup clears only owned contents and keeps an empty root; worktree symlinks never traverse',()=>cloneFixture(async root=>{
  const owner=createOwnedGitResources({clearOwnedClone:binding.clearOwnedClone,roots:[root]});
  const item=await owner.createClone({target:join(root,'destination')});
  const external=join(root,'external'); await fs.mkdir(external);await fs.writeFile(join(external,'user'),'keep');
  await fs.mkdir(join(item.path,'nested'));await fs.writeFile(join(item.path,'nested','owned'),'clear');
  await symlinkFixture(external,join(item.path,'link'));
  await owner.releaseClone(item.id);await owner.finish();
  assert.deepEqual(await fs.readdir(item.path),[]);
  assert.equal(await fs.readFile(join(external,'user'),'utf8'),'keep');
  assert.deepEqual(await cloneHeld(root),[]);
}));
for(const when of ['before-verify','before-native']) test(`real replacement ${when} preserves foreign and moved content and closes descriptors`,()=>cloneFixture(async root=>{
  let item, foreign;
  const swap=()=>{renameSync(item.path,item.path+'-moved');mkdirSync(item.path);foreign=join(item.path,'user');writeFileSync(foreign,'keep');};
  const owner=createOwnedGitResources({clearOwnedClone:binding.clearOwnedClone,roots:[root],clearOwnedClone(...args){swap();return binding.clearOwnedClone(...args);}});
  item=await owner.createClone({target:join(root,'destination')});
  await fs.writeFile(join(item.path,'own'),'owned-original');
  if(when==='before-verify') swap();
  await assert.rejects(owner.releaseClone(item.id));await assert.rejects(owner.finish());
  assert.equal(await fs.readFile(foreign,'utf8'),'keep');
  assert.equal(await fs.readFile(join(item.path+'-moved','own'),'utf8'),'owned-original');
  assert.deepEqual(await cloneHeld(root),[]);
}));
test('native clone cleanup rejects wrong receipt, invalid descriptors, and Worker access',()=>cloneFixture(async root=>{
  await fs.mkdir(join(root,'owned'));await fs.writeFile(join(root,'owned','user'),'keep');
  const parent=await fs.open(root,'r'), directory=await fs.open(join(root,'owned'),'r');
  try {
    const info=await directory.stat({bigint:true}), args=[directory.fd,parent.fd,'owned',String(info.dev),String(info.ino)];
    assert.throws(()=>binding.clearOwnedClone(...args.slice(0,4),'0'),{code:'ERR_OHOS_GIT_CLONE_REPLACED'});
    assert.throws(()=>binding.clearOwnedClone(-1,...args.slice(1)),{code:'ERR_INVALID_ARG_VALUE'});
    const worker=new Worker(`const {parentPort,workerData}=require('node:worker_threads');try{require(process.env.DSH_TEST_PUBLICATION_BINDING).clearOwnedClone(...workerData);parentPort.postMessage('accepted');}catch(e){parentPort.postMessage(e.code)}`,{eval:true,workerData:args});
    const result=await new Promise((resolve,reject)=>{worker.once('message',resolve);worker.once('error',reject);});
    await new Promise(resolve=>worker.once('exit',resolve));
    assert.equal(result,'ERR_OHOS_OWNERSHIP_MAIN_THREAD');
    assert.equal(await fs.readFile(join(root,'owned','user'),'utf8'),'keep');
  } finally {await directory.close();await parent.close();}
}));
test('clone refuses readonly, workspace root, outward symlink and foreign owner id',()=>cloneFixture(async root=>{
  const workspace=join(root,'workspace'),outside=join(root,'outside');await fs.mkdir(workspace);await fs.mkdir(outside);
  await symlinkFixture(outside,join(workspace,'link'));
  const owner=createOwnedGitResources({clearOwnedClone:binding.clearOwnedClone,roots:[workspace]});
  const ro=createOwnedGitResources({clearOwnedClone:binding.clearOwnedClone,roots:[workspace],policy:{mode:'read-only'}});
  await assert.rejects(ro.createClone({target:join(workspace,'repo')}),{code:'EACCES'});
  await assert.rejects(owner.createClone({target:workspace}),{code:'EACCES'});
  await assert.rejects(owner.createClone({target:join(workspace,'link','repo')}),{code:'EACCES'});
  await assert.rejects(owner.releaseClone('not-owned'),{code:'ERR_OHOS_GIT_RESOURCE_ID'});
  await owner.finish();await ro.finish();
  assert.deepEqual(await fs.readdir(outside),[]);
}));
