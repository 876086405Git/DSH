import test from 'node:test';
import assert from 'node:assert/strict';
import fsp from 'node:fs/promises';
import { attachmentFixture, deferred, until } from './attachment-files-fixture.mjs';

const request = (owner = 'test-1', extra = {}) => ({ owner, limit: 9, maxFileBytes: 200 * 1024 * 1024,
  maxTotalBytes: 400 * 1024 * 1024, maxImageBytes: 20 * 1024 * 1024, allowEmpty: false, ...extra });
async function pick(f, uris, extra = {}, owner = 'test-1') {
  const call = f.invoke('pick', request(owner, extra));
  f.select(uris);
  const reply = await call.done;
  assert(!reply.error, JSON.stringify(reply));
  return reply.value;
}
async function release(f, owner = 'test-1') {
  assert.deepEqual(await f.invoke('release', { owner }).done, { value: null });
  assert.deepEqual(await f.cached(), []);
  assert.equal(f.descriptors.size, 0);
}

test('public URI bytes stream to unique private paths; short read/write offsets and Unicode names survive', async t => {
  const f = await attachmentFixture(t, { maxRead: 3, maxWrite: 1 });
  const a = Buffer.from('中文\nfirst'), b = Buffer.from('second\0末');
  const entries = await pick(f, [await f.file('同名.txt', a), await f.file('同名.txt', b)]);
  assert.deepEqual(entries.map(v => v.name), ['同名.txt', '同名.txt']);
  assert.notEqual(entries[0].path, entries[1].path);
  assert.deepEqual(await fsp.readFile(entries[0].path), a);
  assert.deepEqual(await fsp.readFile(entries[1].path), b);
  assert.deepEqual(entries.map(v => v.size), [a.length, b.length]);
  assert.equal(f.descriptors.size, 0);
  assert(f.operations.filter(v => v.op === 'read').every(v => v.length <= 256 * 1024));
  assert.equal((await f.invoke('pick', request('next')).done).error, 'ohos_attachment_busy');
  await f.invoke('release', { owner: 'not-the-owner' }).done;
  assert.equal((await fsp.readFile(entries[0].path)).length, a.length);
  await release(f);
});

test('a rejected item preserves selection order and later valid items within the remaining total budget', async t => {
  const f = await attachmentFixture(t);
  const entries = await pick(f, [await f.file('a', '123456'), await f.file('too-big', '12345678'),
    await f.file('c', 'abc')], { maxFileBytes: 8, maxTotalBytes: 10 });
  assert.deepEqual(entries.map(v => [v.name, v.size, v.problem]),
    [['a', 6, null], ['too-big', 0, 'total_too_large'], ['c', 3, null]]);
  assert.equal(await fsp.readFile(entries[2].path, 'utf8'), 'abc');
  await release(f);
});

test('stale metadata cannot authorize extra bytes and exact limit still permits EOF', async t => {
  const f = await attachmentFixture(t, { reportedSize: 0, maxRead: 3 });
  const entries = await pick(f, [await f.file('growth', '123456'), await f.file('exact', 'abcde')],
    { maxFileBytes: 5, maxTotalBytes: 5 });
  assert.equal(entries[0].problem, 'file_too_large');
  assert.equal(entries[0].path, null);
  assert.equal(entries[1].problem, null);
  assert.equal(await fsp.readFile(entries[1].path, 'utf8'), 'abcde');
  const files = (await f.cached()).filter(v => /\/\d+$/.test(v));
  assert.equal(files.length, 1);
  await release(f);
});

test('split true image prefix enforces image budget and does not spend the next file total', async t => {
  const f = await attachmentFixture(t, { reportedSize: 0, maxRead: 2 });
  const png = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4]);
  const entries = await pick(f, [await f.file('image.txt', png), await f.file('binary.png', 'abc')],
    { maxFileBytes: 20, maxTotalBytes: 20, maxImageBytes: 8 });
  assert.equal(entries[0].problem, 'image_too_large');
  assert.equal(entries[1].problem, null);
  assert.equal(await fsp.readFile(entries[1].path, 'utf8'), 'abc');
  await release(f);
});

for (const failure of ['read', 'write']) {
  test(`partial ${failure} failure closes both streams, deletes partial cache, and preserves a later file`, async t => {
    let count = 0;
    const f = await attachmentFixture(t, { maxRead: 2, maxWrite: 1,
      [failure]: () => { if (++count === 2) throw new Error('controlled I/O failure'); } });
    const entries = await pick(f, [await f.file('failed', 'abcdef'), await f.file('good', 'xyz')]);
    assert.equal(entries[0].problem, 'unreadable');
    assert.equal(entries[0].path, null);
    assert.equal(entries[1].problem, null);
    assert.equal(await fsp.readFile(entries[1].path, 'utf8'), 'xyz');
    assert.equal(f.descriptors.size, 0);
    assert.equal((await f.cached()).filter(v => /\/\d+$/.test(v)).length, 1);
    await release(f);
  });
}

test('logical cancellation replies once but retains the physical picker slot until selection settles', async t => {
  const f = await attachmentFixture(t);
  const selected = f.invoke('pick', request());
  await until(() => f.pickers.length === 1);
  await f.invoke('cancel', { owner: 'wrong-owner' }).done;
  assert.equal(selected.replies.length, 0);
  await f.invoke('cancel', { owner: 'test-1' }).done;
  assert.deepEqual(await selected.done, { value: [] });
  assert.equal((await f.invoke('pick', request('next')).done).error, 'ohos_attachment_busy');
  f.select([await f.file('unused', 'private bytes')]);
  await until(() => f.pickers[0].settled);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(await f.cached(), []);
  assert.equal(f.operations.filter(v => v.op === 'open').length, 0);
  const next = f.invoke('pick', request('next')); f.select([]);
  assert.deepEqual(await next.done, { value: [] });
  assert.equal(selected.replies.length, 1);
});

test('Ability retirement during a pending read cleans the undisclosed cache and closes owned descriptors', async t => {
  const gate = deferred(); let entered = false;
  const f = await attachmentFixture(t, { read: async () => { entered = true; await gate.promise; } });
  const selected = f.invoke('pick', request()); f.select([await f.file('key', 'private bytes')]);
  await until(() => entered);
  f.plugin.onDetachedFromAbility();
  assert.deepEqual(await selected.done, { value: [] });
  assert.equal((await f.invoke('pick', request('next')).done).error, 'ohos_attachment_detached');
  gate.resolve();
  await until(() => f.descriptors.size === 0);
  await until(async () => (await f.cached()).length === 0);
  assert.deepEqual(await f.cached(), []);
  assert.equal(selected.replies.length, 1);
  assert.equal(f.operations.filter(v => v.op === 'write').length, 0);
});

test('engine detachment releases an already delivered cache without waiting for Dart to return a token', async t => {
  const f = await attachmentFixture(t);
  const entries = await pick(f, [await f.file('ready', 'abc')]);
  f.plugin.onDetachedFromEngine(f.engine);
  await until(() => f.operations.some(v => v.op === 'unlink' && v.path === entries[0].path));
  await until(async () => (await f.cached()).length === 0);
  assert.deepEqual(await f.cached(), []);
});

test('text mode permits empty files, honors a smaller byte limit and does not treat signatures as images', async t => {
  const f = await attachmentFixture(t, { maxRead: 1 });
  let entries = await pick(f, [await f.file('empty', '')], { limit: 1, maxFileBytes: 0, maxTotalBytes: 0,
    maxImageBytes: 0, allowEmpty: true });
  assert.equal(entries[0].size, 0); assert.equal(entries[0].problem, null); await release(f);
  entries = await pick(f, [await f.file('text', '中文')], { limit: 1, maxFileBytes: 5, maxTotalBytes: 5,
    maxImageBytes: 0, allowEmpty: true });
  assert.equal(entries[0].problem, 'file_too_large'); await release(f);
});

test('release failure loses no cleanup work and the next pick retries without the old Dart owner', async t => {
  let once = true;
  const f = await attachmentFixture(t, { unlink: () => {
    if (once) { once = false; throw new Error('controlled cleanup failure'); }
  } });
  const [entry] = await pick(f, [await f.file('old', 'abc')]);
  assert.equal((await f.invoke('release', { owner: 'test-1' }).done).error, 'ohos_attachment_cleanup');
  assert.equal(await fsp.readFile(entry.path, 'utf8'), 'abc');
  const next = f.invoke('pick', request('new'));
  await until(() => f.pickers.length === 2 || next.replies.length > 0);
  assert.equal(next.replies.length, 0, 'cleanup failure must not strand the live Ability busy');
  f.pickers[1].wait.resolve([]);
  assert.deepEqual(await next.done, { value: [] });
  await until(async () => (await f.cached()).length === 0);
  assert.equal(f.operations.filter(v => v.op === 'unlink' && v.path === entry.path).length, 2);
});

test('retry failure permits consecutive picks, then a later retry cleans only the abandoned batch', async t => {
  let denied = true, oldPath;
  const f = await attachmentFixture(t, { unlink: path => {
    if (denied && path === oldPath) throw new Error('persistent cleanup denial');
  } });
  const [old] = await pick(f, [await f.file('old', 'old')]); oldPath = old.path;
  assert.equal((await f.invoke('release', { owner: 'test-1' }).done).error, 'ohos_attachment_cleanup');
  for (const owner of ['second', 'third']) {
    const next = f.invoke('pick', request(owner));
    await until(() => f.pickers.length >= (owner === 'second' ? 2 : 3) || next.replies.length > 0);
    assert.equal(next.replies.length, 0);
    f.pickers.at(-1).wait.resolve([]);
    assert.deepEqual(await next.done, { value: [] });
    await new Promise(resolve => setImmediate(resolve));
  }
  assert.equal(await fsp.readFile(oldPath, 'utf8'), 'old');
  denied = false;
  const [fresh] = await pick(f, [await f.file('fresh', 'new')], {}, 'fourth');
  await until(() => f.operations.filter(v => v.op === 'unlink' && v.path === oldPath).length === 4);
  await f.invoke('release', { owner: 'test-1' }).done;
  assert.equal(await fsp.readFile(fresh.path, 'utf8'), 'new');
  assert.equal((await f.invoke('pick', request('busy')).done).error, 'ohos_attachment_busy');
  await release(f, 'fourth');
});

test('hung retry does not block new picker or duplicate cleanup; late completion cannot clear new admission', async t => {
  const gate = deferred(); let calls = 0, oldPath;
  const f = await attachmentFixture(t, { unlink: async path => {
    if (path !== oldPath) return;
    if (++calls === 1) throw new Error('first cleanup failure');
    await gate.promise;
  } });
  const [old] = await pick(f, [await f.file('old', 'old')]); oldPath = old.path;
  assert.equal((await f.invoke('release', { owner: 'test-1' }).done).error, 'ohos_attachment_cleanup');
  const next = f.invoke('pick', request('new'));
  await until(() => f.pickers.length === 2 || next.replies.length > 0);
  assert.equal(next.replies.length, 0);
  f.pickers[1].wait.resolve([await f.file('fresh', 'fresh')]);
  const fresh = (await next.done).value[0];
  assert.equal((await f.invoke('pick', request('busy')).done).error, 'ohos_attachment_busy');
  assert.equal(calls, 2, 'one in-flight retry per abandoned batch');
  gate.resolve();
  await until(async () => { try { await fsp.stat(oldPath); return false; } catch (e) { if (e.code === 'ENOENT') return true; throw e; } });
  await f.invoke('release', { owner: 'test-1' }).done;
  await f.invoke('release', { owner: 'test-1' }).done;
  assert.equal(await fsp.readFile(fresh.path, 'utf8'), 'fresh');
  assert.equal((await f.invoke('pick', request('still-busy')).done).error, 'ohos_attachment_busy');
  await release(f, 'new');
});

for (const wholeDirectory of [false, true]) {
  test(`cache removed externally before release is already clean (directory=${wholeDirectory})`, async t => {
    const f = await attachmentFixture(t);
    const [entry] = await pick(f, [await f.file('external-removal', 'bytes')]);
    if (wholeDirectory) await fsp.rm(entry.path.slice(0, entry.path.lastIndexOf('/')), { recursive: true });
    else await fsp.unlink(entry.path);
    await release(f);
    assert.deepEqual(await pick(f, [], {}, 'next'), []);
  });
}

test('directory permission failure remains a release error, then next pick retries the empty directory', async t => {
  let denied = true;
  const f = await attachmentFixture(t, { rmdir: () => {
    if (denied) throw Object.assign(new Error('permission denied'), { code: 13900012 });
  } });
  const [entry] = await pick(f, [await f.file('old', 'old')]);
  assert.equal((await f.invoke('release', { owner: 'test-1' }).done).error, 'ohos_attachment_cleanup');
  assert.deepEqual(await fsp.readdir(entry.path.slice(0, entry.path.lastIndexOf('/'))), []);
  denied = false;
  assert.deepEqual(await pick(f, [], {}, 'new'), []);
  await until(async () => (await f.cached()).length === 0);
});

test('late failed retry cannot retire the new batch and stays retryable on another pick', async t => {
  const gate = deferred(); let calls = 0, oldPath;
  const f = await attachmentFixture(t, { unlink: async path => {
    if (path !== oldPath) return;
    if (++calls === 1) throw new Error('initial failure');
    await gate.promise;
  } });
  const [old] = await pick(f, [await f.file('old', 'old')]); oldPath = old.path;
  assert.equal((await f.invoke('release', { owner: 'test-1' }).done).error, 'ohos_attachment_cleanup');
  const [fresh] = await pick(f, [await f.file('new', 'new')], {}, 'new');
  gate.reject(new Error('late cleanup failure'));
  await until(() => f.operations.filter(v => v.op === 'cleanup-warning').length === 2);
  assert.equal(await fsp.readFile(fresh.path, 'utf8'), 'new');
  assert.equal((await f.invoke('pick', request('busy')).done).error, 'ohos_attachment_busy');
  f.change({ unlink: undefined });
  assert.deepEqual(await f.invoke('release', { owner: 'new' }).done, { value: null });
  assert.deepEqual(await pick(f, [], {}, 'third'), []);
  await until(async () => (await f.cached()).length === 0);
});

test('real read failure plus failed cleanup remains an I/O error, while a later valid pick is usable', async t => {
  let oldPath;
  const f = await attachmentFixture(t, {
    read: () => { throw new Error('read failed'); },
    unlink: path => { oldPath ??= path; if (path === oldPath) throw new Error('cleanup failed'); },
  });
  const selected = f.invoke('pick', request()); f.select([await f.file('failed', 'private')]);
  assert.equal((await selected.done).error, 'ohos_attachment_io');
  await until(() => f.operations.some(v => v.op === 'cleanup-warning'));
  assert.equal(f.descriptors.size, 0);
  f.change({ read: undefined });
  const [fresh] = await pick(f, [await f.file('good', 'real data')], {}, 'new');
  assert.equal(await fsp.readFile(fresh.path, 'utf8'), 'real data');
  assert.equal(fresh.problem, null);
  f.change({ unlink: undefined });
  assert.deepEqual(await f.invoke('release', { owner: 'new' }).done, { value: null });
  assert.deepEqual(await pick(f, [], {}, 'third'), []);
  await until(async () => (await f.cached()).length === 0);
});

test('invalid budgets do not launch a picker; returned excess selection is bounded and empty cancel creates no cache', async t => {
  const f = await attachmentFixture(t);
  for (const extra of [{ limit: 10 }, { maxFileBytes: 200 * 1024 * 1024 + 1 },
    { maxTotalBytes: 400 * 1024 * 1024 + 1 }, { maxImageBytes: 20 * 1024 * 1024 + 1 }]) {
    assert.equal((await f.invoke('pick', request('invalid', extra)).done).error, 'ohos_attachment_arguments');
  }
  assert.equal(f.pickers.length, 0);
  const entries = await pick(f, [await f.file('first', 'a'), await f.file('second', 'b')], { limit: 1 });
  assert.deepEqual(entries.map(v => v.problem), [null, 'too_many']);
  assert.equal(f.operations.filter(v => v.op === 'open' && v.path.startsWith('file:')).length, 1);
  await release(f);
  assert.deepEqual(await pick(f, []), []); await release(f);
});


test('retired never-returning picker cannot block a new Ability; late old result and duplicate release stay isolated', async t => {
  const f = await attachmentFixture(t);
  const old = f.invoke('pick', request('old'));
  await until(() => f.pickers.length === 1);
  f.plugin.onDetachedFromAbility();
  assert.deepEqual(await old.done, { value: [] });
  f.plugin.onAttachedToAbility({ getAbility: () => ({ context: f.context }) });
  const next = f.invoke('pick', request('new'));
  await until(() => f.pickers.length === 2 || next.replies.length > 0);
  assert.equal(next.replies.length, 0, 'new Ability must not inherit the retired busy slot');
  f.pickers[1].wait.resolve([await f.file('new', 'new data')]);
  const reply = await next.done;
  assert.equal(reply.value.length, 1);
  const path = reply.value[0].path;
  f.pickers[0].wait.resolve([await f.file('old', 'old data')]);
  await until(() => f.pickers[0].settled);
  await new Promise(resolve => setImmediate(resolve));
  await f.invoke('release', { owner: 'old' }).done;
  await f.invoke('release', { owner: 'old' }).done;
  assert.equal(await fsp.readFile(path, 'utf8'), 'new data');
  assert.equal(f.operations.filter(v => v.op === 'open' && v.path.startsWith('file:')).length, 1);
  assert.equal(old.replies.length, 1);
  assert.equal((await f.invoke('pick', request('third')).done).error, 'ohos_attachment_busy');
  await release(f, 'new');
});

test('engine retirement after release failure frees the slot and a new attach can retry selection', async t => {
  const f = await attachmentFixture(t, { unlink: () => { throw new Error('cleanup denied'); } });
  await pick(f, [await f.file('old', 'retained')]);
  assert.equal((await f.invoke('release', { owner: 'test-1' }).done).error, 'ohos_attachment_cleanup');
  f.plugin.onDetachedFromEngine(f.engine);
  const attached = f.attach(f.plugin);
  const next = f.invoke('pick', request('new'), attached.channel);
  await until(() => f.pickers.length === 2 || next.replies.length > 0);
  assert.equal(next.replies.length, 0);
  f.pickers[1].wait.resolve([]);
  assert.deepEqual(await next.done, { value: [] });
  f.plugin.onDetachedFromEngine(attached.engine);
});

test('startup reclaims killed attachment batches before copying and preserves unrelated caches and source files', async t => {
  const f = await attachmentFixture(t, { seedCache: async cache => {
    await fsp.mkdir(cache + '/dsh-attachments-Ab12CD');
    await fsp.writeFile(cache + '/dsh-attachments-Ab12CD/0', 'orphan');
    await fsp.mkdir(cache + '/share-inbox');
    await fsp.writeFile(cache + '/share-inbox/0', 'share');
    await fsp.mkdir(cache + '/dsh-attachments-not-owned');
    await fsp.writeFile(cache + '/dsh-attachments-not-owned/0', 'other');
    await fsp.symlink(cache + '/share-inbox', cache + '/dsh-attachments-Link12');
    await fsp.mkdir(cache + '/dsh-attachments-Mixed1');
    await fsp.writeFile(cache + '/dsh-attachments-Mixed1/marker', 'unknown');
  } });
  const uri = await f.file('source', 'source data');
  const entries = await pick(f, [uri]);
  assert.equal((await f.cached()).includes('dsh-attachments-Ab12CD'), false);
  assert.equal(await fsp.readFile(f.context.cacheDir + '/share-inbox/0', 'utf8'), 'share');
  assert.equal(await fsp.readFile(f.context.cacheDir + '/dsh-attachments-not-owned/0', 'utf8'), 'other');
  assert.equal((await fsp.lstat(f.context.cacheDir + '/dsh-attachments-Link12')).isSymbolicLink(), true);
  assert.equal(await fsp.readFile(f.context.cacheDir + '/dsh-attachments-Mixed1/marker', 'utf8'), 'unknown');
  assert.equal(await fsp.readFile(f.uris.get(uri), 'utf8'), 'source data');
  assert.equal(await fsp.readFile(entries[0].path, 'utf8'), 'source data');
  await f.invoke('release', { owner: 'test-1' }).done;
});


test('old in-flight copy closes after detach without deleting a newly attached batch', async t => {
  const gate = deferred(); let entered = false;
  const f = await attachmentFixture(t, { read: async () => { entered = true; await gate.promise; } });
  const old = f.invoke('pick', request('old'));
  f.select([await f.file('old', 'old data')]);
  await until(() => entered);
  f.plugin.onDetachedFromAbility();
  f.plugin.onAttachedToAbility({ getAbility: () => ({ context: f.context }) });
  f.change({ read: undefined });
  const entries = await pick(f, [await f.file('new', 'new data')], {}, 'new');
  gate.resolve();
  await until(() => f.descriptors.size === 0);
  await until(async () => (await f.cached()).filter(v => !v.includes('/')).length === 1);
  assert.deepEqual(await old.done, { value: [] });
  assert.equal(await fsp.readFile(entries[0].path, 'utf8'), 'new data');
  await release(f, 'new');
});

test('failed startup cleanup diagnoses retained cache but does not prevent a fresh selection', async t => {
  const f = await attachmentFixture(t, {
    seedCache: async cache => {
      await fsp.mkdir(cache + '/dsh-attachments-Ab12CD');
      await fsp.writeFile(cache + '/dsh-attachments-Ab12CD/0', 'orphan');
    },
    unlink: () => { throw new Error('cleanup denied'); },
  });
  const entries = await pick(f, [await f.file('new', 'read succeeds')]);
  assert.equal(await fsp.readFile(entries[0].path, 'utf8'), 'read succeeds');
  assert.equal(await fsp.readFile(f.context.cacheDir + '/dsh-attachments-Ab12CD/0', 'utf8'), 'orphan');
  assert.equal(f.operations.filter(v => v.op === 'cleanup-warning').length, 1);
  f.change({ unlink: undefined });
  assert.deepEqual(await f.invoke('release', { owner: 'test-1' }).done, { value: null });
});

for (const retirement of ['ability','engine']) test(`throwing retired reply cannot retain global picker slot (${retirement})`, async t=>{
 const f=await attachmentFixture(t); let replyAttempts=0;
 const args=new Map(Object.entries(request('old')));
 f.channel.handler.onMethodCall({method:'pick',args}, {
  success(){replyAttempts++;throw new Error('retired transport');},
  error(){replyAttempts++;throw new Error('retired transport');},
  notImplemented(){assert.fail('pick must be implemented');}
 });
 await until(()=>f.pickers.length===1);
 let detachError;
 try { if(retirement==='ability')f.plugin.onDetachedFromAbility(); else f.plugin.onDetachedFromEngine(f.engine); }
 catch(error){detachError=error;}
 let channel=f.channel;
 if(retirement==='ability') f.plugin.onAttachedToAbility({getAbility:()=>({context:f.context})});
 else channel=f.attach().channel;
 const next=f.invoke('pick',request('new'),channel);
 await until(()=>f.pickers.length===2||next.replies.length>0);
 assert.equal(next.replies.length,0,'new Ability must acquire picker before the retired picker returns');
 assert.equal(detachError,undefined,'transport reply failure must not abort detach');
 assert.equal(f.pickers[0].settled,false);
 f.pickers[1].wait.resolve([await f.file('new.txt','actual new bytes')]);
 const reply=await next.done; assert.equal(reply.value.length,1);
 const path=reply.value[0].path;
 assert.equal(await fsp.readFile(path,'utf8'),'actual new bytes');
 f.pickers[0].wait.resolve([await f.file('old.txt','old bytes')]);
 await until(()=>f.pickers[0].settled);await new Promise(resolve=>setImmediate(resolve));
 assert.equal(replyAttempts,1,'retired result receives no second logical reply');
 assert.equal(await fsp.readFile(path,'utf8'),'actual new bytes');
 assert.equal(f.operations.filter(v=>v.op==='open'&&v.path.startsWith('file:')).length,1);
 await f.invoke('release',{owner:'new'},channel).done;
 assert.deepEqual(await f.cached(),[]);assert.equal(f.descriptors.size,0);
});
