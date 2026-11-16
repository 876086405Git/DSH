import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { workspaceFixture, deferred, until } from './authorized-workspaces-fixture.mjs';
const uri = 'file://docs/storage/Users/currentUser/Projects/one';
const other = 'file://docs/storage/Users/currentUser/Download/two';
const gesture = { userGesture: true };

async function selected(f, values = [uri]) {
  const request = f.call(f, 'select', gesture); await until(() => f.pickers.length > 0); f.select(values);
  const result = await request.done; assert.equal(result.error, undefined); return result.value;
}

test('directory support is reachable from the actual registered EntryAbility', async t => {
  const f = await workspaceFixture(t);
  assert.deepEqual(await f.call(f, 'capabilities').done, { value: { protocol: 1, folderSelection: true, folderAuthorization: true,
    persistencePermission: 'granted', engineAttached: false } });
  assert.equal(f.operations.length, 0, 'capability query cannot open picker, URI, or Preferences');
});

test('folder chooser uses API26 FOLDER plus multi-folder option and keeps Node unverified', async t => {
  const f = await workspaceFixture(t), value = await selected(f, [uri, other]);
  assert.equal(value.workspaces.length, 2); assert.equal(value.engineAttached, false);
  assert.deepEqual({ ...f.pickers[0].options }, { selectMode: 1, allowsMulFolderSelection: true });
  for (const item of value.workspaces) {
    assert.equal(item.nodeAccess, 'unverified'); assert.equal(item.engineAttached, false); assert.equal(item.authorization, 'selected');
    assert.equal(item.persistence, 'unknown'); assert.equal(item.candidatePath, new URL(item.uri).pathname);
  }
  const stored = JSON.parse(JSON.parse(await readFile(f.storage, 'utf8')).records);
  assert.deepEqual(stored.map(row => Object.keys(row).sort()), [['id', 'uri'], ['id', 'uri']]);
  assert.equal(f.operations.some(row => row.op === 'persist'), false);
});

test('unsolicited and background requests cannot invoke selection or mutate grants', async t => {
  const f = await workspaceFixture(t);
  assert.equal((await f.call(f, 'select').done).error, 'user_gesture');
  f.background(); assert.equal((await f.call(f, 'select', gesture).done).error, 'user_gesture');
  assert.equal(f.operations.length, 0);
});

test('missing folder capability gives explicit unsupported without a chooser', async t => {
  const f = await workspaceFixture(t, { missingCaps: ['SystemCapability.FileManagement.UserFileService.FolderSelection'] });
  assert.equal((await f.call(f, 'select', gesture).done).error, 'unsupported'); assert.equal(f.pickers.length, 0);
});

test('media URI and traversal cannot become authorized workspace records', async t => {
  const f = await workspaceFixture(t);
  for (const bad of ['file://media/Photo/1', 'file://docs/storage/%2e%2e/private', 'file://docs/storage/one?networkid=remote']) {
    const count = f.pickers.length, request = f.call(f, 'select', gesture);
    await until(() => f.pickers.length > count); f.select([bad]); assert.equal((await request.done).error, 'invalid');
  }
  assert.deepEqual((await f.call(f, 'list').done).value.workspaces, []);
});

test('caller path or URI cannot substitute for a picker-origin ID', async t => {
  const f = await workspaceFixture(t);
  for (const method of ['persist', 'activate', 'deactivate', 'revoke', 'forget']) {
    assert.equal((await f.call(f, method, { ...gesture, id: uri, uri, path: '/storage' }).done).error, 'not_found');
  }
  assert.equal(f.operations.some(row => ['persist', 'activate', 'revoke'].includes(row.op)), false);
});

test('no persistent permission preserves current selection but explicitly refuses persistence', async t => {
  const f = await workspaceFixture(t, { permissionDenied: true }), value = await selected(f);
  const id = value.workspaces[0].id;
  assert.equal((await f.call(f, 'persist', { ...gesture, id }).done).error, 'persistence_unavailable');
  assert.equal((await f.call(f, 'list').done).value.workspaces[0].authorization, 'selected');
  assert.equal(f.persisted.size, 0);
});

test('restart checks OS persistence and activates only a known selected URI', async t => {
  const f = await workspaceFixture(t), first = await selected(f), id = first.workspaces[0].id;
  const persisted = await f.call(f, 'persist', { ...gesture, id }).done;
  assert.equal(persisted.value.workspaces[0].persistence, 'persisted');
  assert.equal(f.operations.find(row => row.op === 'persist').policies[0].operationMode, 3);
  const reboot = f.boot(), before = (await f.call(reboot, 'list').done).value;
  assert.notEqual(before.bootId, first.bootId); assert.equal(before.workspaces[0].persistence, 'unknown');
  assert.equal(before.workspaces[0].authorization, 'needsRestore');
  const after = (await f.call(reboot, 'activate', { ...gesture, id }).done).value;
  assert.equal(after.workspaces[0].authorization, 'activated'); assert.equal(after.engineAttached, false);
  assert.deepEqual(f.operations.filter(row => ['checkPersistent', 'activate'].includes(row.op)).map(row => row.op), ['checkPersistent', 'activate']);
});

test('temporary record after process restart cannot claim persistence or bypass the picker', async t => {
  const f = await workspaceFixture(t), first = await selected(f), id = first.workspaces[0].id, reboot = f.boot();
  assert.equal((await f.call(reboot, 'activate', { ...gesture, id }).done).error, 'reauthorize');
  assert.equal((await f.call(reboot, 'persist', { ...gesture, id }).done).error, 'reauthorize');
  assert.equal(f.active.size, 0); assert.equal(f.persisted.size, 0);
});

test('deactivate and revoke have different OS and local outcomes; forget never claims revocation', async t => {
  const f = await workspaceFixture(t), first = await selected(f), id = first.workspaces[0].id;
  await f.call(f, 'persist', { ...gesture, id }).done; await f.call(f, 'activate', { ...gesture, id }).done;
  const inactive = await f.call(f, 'deactivate', { ...gesture, id }).done;
  assert.equal(inactive.value.workspaces[0].authorization, 'needsActivation'); assert(f.persisted.has(uri)); assert(!f.active.has(uri));
  const revoked = await f.call(f, 'revoke', { ...gesture, id }).done;
  assert.equal(revoked.value.workspaces[0].persistence, 'absent'); assert(!f.persisted.has(uri));
  const forgotten = await f.call(f, 'forget', { ...gesture, id }).done;
  assert.equal(forgotten.value.osGrantChanged, false); assert.deepEqual(forgotten.value.workspaces, []);
});

test('a failed revoke retains the record, reports OS codes, and cannot masquerade as success', async t => {
  const f = await workspaceFixture(t), first = await selected(f), id = first.workspaces[0].id;
  await f.call(f, 'persist', { ...gesture, id }).done;
  f.change({ revoke: async () => { throw Object.assign(Error('private URI must not reach generic errors'),
    { code: 13900001, data: [{ uri, code: 3, message: uri }] }); } });
  const error = await f.call(f, 'revoke', { ...gesture, id }).done;
  assert.equal(error.error, 'system_authorization_failed'); assert.deepEqual(error.details, { operation: 'revoke', id, systemCode: 13900001, policyCode: 3 });
  assert(!JSON.stringify(error).includes(uri)); assert(f.persisted.has(uri));
  assert.equal((await f.call(f, 'list').done).value.workspaces.length, 1);
});

test('late picker callback after detach cannot create records or release its physical lease early', async t => {
  const f = await workspaceFixture(t), request = f.call(f, 'select', gesture); await until(() => f.pickers.length === 1);
  f.plugin.onDetachedFromAbility(); assert.equal((await request.done).error, 'cancelled');
  f.plugin.onAttachedToAbility(f.ability);
  assert.equal((await f.call(f, 'select', gesture).done).error, 'busy');
  f.select([uri]); await until(() => request.replies.length === 1 && !f.operations.some(row => row.op === 'put'));
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual((await f.call(f, 'list').done).value.workspaces, []); assert.equal(request.replies.length, 1);
});

test('timeout retires the response without pretending the OS call ended', async t => {
  const f = await workspaceFixture(t), request = f.call(f, 'select', gesture); await until(() => f.pickers.length === 1);
  f.expire(); assert.equal((await request.done).error, 'cancelled');
  assert.equal((await f.call(f, 'select', gesture).done).error, 'busy');
  f.select([]); await new Promise(resolve => setImmediate(resolve));
  assert.equal(request.replies.length, 1); assert.deepEqual((await f.call(f, 'list').done).value.workspaces, []);
});

test('physical picker lease survives a new plugin and Flutter engine binding', async t => {
  const f = await workspaceFixture(t), request = f.call(f, 'select', gesture);
  await until(() => f.pickers.length === 1); f.plugin.onDetachedFromEngine(f.binding);
  const replacement = f.attach(); assert.equal((await request.done).error, 'cancelled');
  assert.equal((await f.call(replacement, 'select', gesture).done).error, 'busy');
  f.select([uri]); await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual((await f.call(replacement, 'list').done).value.workspaces, []);
  assert.equal(request.replies.length, 1);
});

test('background invalidates prior access evidence without inventing OS revocation', async t => {
  const f = await workspaceFixture(t), first = await selected(f), id = first.workspaces[0].id;
  await f.call(f, 'persist', { ...gesture, id }).done; f.background(); f.foreground();
  const now = (await f.call(f, 'list').done).value.workspaces[0];
  assert(now.generation > first.workspaces[0].generation); assert.equal(now.authorization, 'needsRevalidation');
  assert.equal(now.persistence, 'persisted'); assert(f.persisted.has(uri)); assert.equal(now.engineAttached, false);
});

// Real ETS state machine; the delayed Preferences and Ability events remain
// explicit SDK doubles. Test both async publication boundaries and new records.
for (const stage of ['put', 'flush']) for (const existing of [false, true]) for (const returnForeground of [false, true]) {
  test(`background during pending ${stage} publication keeps ${existing ? 'existing' : 'new'} record invalidated; foreground=${returnForeground}`, async t => {
    const f = await workspaceFixture(t);
    if (existing) await selected(f);
    const waiting = deferred(); f.change({ [stage]: () => waiting.promise });
    const pickerCount = f.pickers.length, stageCount = f.operations.filter(row => row.op === stage).length;
    const request = f.call(f, 'select', gesture);
    await until(() => f.pickers.length > pickerCount); f.select([uri]);
    await until(() => f.operations.filter(row => row.op === stage).length > stageCount);
    f.background(); if (returnForeground) f.foreground();
    waiting.resolve();
    const response = await request.done;
    assert.equal(response.error, undefined);
    const item = response.value.workspaces[0];
    assert.equal(item.authorization, 'needsRevalidation'); assert(item.generation > 1);
    assert.equal(item.engineAttached, false); assert.equal(item.nodeAccess, 'unverified');
    const listed = (await f.call(f, 'list').done).value.workspaces[0];
    assert.equal(listed.authorization, 'needsRevalidation'); assert.equal(listed.generation, item.generation);
    f.foreground();
    assert.equal((await f.call(f, 'persist', { ...gesture, id: item.id }).done).error, 'reauthorize');
    assert.equal(f.operations.some(row => row.op === 'persist'), false);
  });
}

test('path conversion failure is reported as absent candidate, not a fake valid Node path', async t => {
  const f = await workspaceFixture(t, { pathThrow: true }), first = await selected(f);
  assert.equal(first.workspaces[0].candidatePath, null); assert.equal(first.workspaces[0].nodeAccess, 'unverified');
});

test('record flush failure is not reported as a completed selection', async t => {
  const f = await workspaceFixture(t, { flush: async () => { throw Object.assign(Error('full'), { code: 'ENOSPC' }); } });
  const request = f.call(f, 'select', gesture); await until(() => f.pickers.length === 1); f.select([uri]);
  assert.equal((await request.done).error, 'failed'); assert.equal(f.persisted.size, 0);
  assert.deepEqual((await f.call(f, 'list').done).value.workspaces, []);
});

test('foreground is rechecked after pending record load before opening a picker', async t => {
  const waiting = deferred(), f = await workspaceFixture(t, { preferences: () => waiting.promise });
  const request = f.call(f, 'select', gesture); await until(() => f.operations.some(row => row.op === 'preferences'));
  f.background(); waiting.resolve();
  assert.equal((await request.done).error, 'user_gesture'); assert.equal(f.pickers.length, 0);
});

test('background round trip cannot revive an old click that was still loading records', async t => {
  const waiting = deferred(), f = await workspaceFixture(t, { preferences: () => waiting.promise });
  const request = f.call(f, 'select', gesture); await until(() => f.operations.some(row => row.op === 'preferences'));
  f.background(); f.foreground(); waiting.resolve();
  await until(() => f.pickers.length > 0 || request.replies.length > 0);
  if (f.pickers.length) f.select([]);
  assert.equal((await request.done).error, 'user_gesture'); assert.equal(f.pickers.length, 0);
});

test('background during pending activate cannot overwrite revalidation with active status', async t => {
  const f = await workspaceFixture(t), first = await selected(f), id = first.workspaces[0].id;
  await f.call(f, 'persist', { ...gesture, id }).done;
  const waiting = deferred(); f.change({ activate: () => waiting.promise });
  const request = f.call(f, 'activate', { ...gesture, id });
  await until(() => f.operations.some(row => row.op === 'activate')); f.background(); waiting.resolve();
  const response = await request.done;
  assert.equal(response.value.workspaces[0].authorization, 'needsRevalidation'); assert.equal(response.value.engineAttached, false);
});

test('OS already revoked is an absent grant result, not a request to reauthorize before removal', async t => {
  const f = await workspaceFixture(t), first = await selected(f), id = first.workspaces[0].id;
  const result = await f.call(f, 'revoke', { ...gesture, id }).done;
  assert.equal(result.value.workspaces[0].persistence, 'absent');
  assert.equal(f.operations.some(row => row.op === 'revoke'), false);
});

test('actual producer snapshots are available for the pure Dart decoder/client (Dart executes separately)', async t => {
  const f = await workspaceFixture(t), first = await selected(f), id = first.workspaces[0].id;
  const snapshots = [{ wire: first, authorization: 'selected' }];
  for (const [method, authorization] of [['persist', 'selected'], ['activate', 'activated'], ['deactivate', 'needsActivation'],
    ['revoke', 'needsReauthorization'], ['forget', null]]) {
    const result = await f.call(f, method, { ...gesture, id }).done;
    assert.equal(result.error, undefined); snapshots.push({ wire: result.value, authorization });
  }
  const capabilities = (await f.call(f, 'capabilities').done).value;
  if (process.env.OHOS_WORKSPACE_CASES) await writeFile(process.env.OHOS_WORKSPACE_CASES, JSON.stringify({ capabilities, snapshots }));
  assert.equal(snapshots.length, 6);
});

test('911 restart without persistence reports reselect in list without user guessing activation', async t => {
  const f = await workspaceFixture(t, {permissionDenied:true});
  await selected(f); const reboot=f.boot();
  const record=(await f.call(reboot,'list').done).value.workspaces[0];
  assert.equal(record.authorization,'needsReauthorization');
  assert.equal(record.persistence,'unavailable');
});


test('911 actual directory FD is duplicated into native owner, never candidatePath',async t=>{
 const f=await workspaceFixture(t,{pathThrow:true});const item=(await selected(f)).workspaces[0];
 const result=await f.call(f,'attach',{...gesture,id:item.id}).done;assert.equal(result.error,undefined);
 const row=result.value.workspaces[0];assert.equal(row.nativeGrant,'ready');assert.equal(row.candidatePath,null);
 assert.equal(row.engineAttached,false,'publishing FD is not mounting either engine');assert.equal(f.fds.size,0);
 assert.deepEqual(f.native.workspaceGrant('status',row.nativeKey,row.nativeGeneration),{active:true,drained:false,writable:true,leases:0,generation:row.generation});
 f.background();assert.equal(f.native.workspaceGrant('status',row.nativeKey,row.nativeGeneration).drained,true);
});

test('911 background while real URI open is pending closes returned FD without publication',async t=>{
 const blocked=deferred();const f=await workspaceFixture(t,{open:()=>blocked.promise});const item=(await selected(f)).workspaces[0];
 const attach=f.call(f,'attach',{...gesture,id:item.id});await until(()=>f.operations.some(x=>x.op==='openDirectory'));
 f.background();f.foreground();blocked.resolve();assert.equal((await attach.done).error,'user_gesture');assert.equal(f.fds.size,0);
 assert.equal((await f.call(f,'list').done).value.workspaces[0].nativeGeneration,0);
});

test('911 revoke closes native admission before OS revoke completes',async t=>{
 const f=await workspaceFixture(t);const item=(await selected(f)).workspaces[0];await f.call(f,'persist',{...gesture,id:item.id}).done;
 const row=(await f.call(f,'attach',{...gesture,id:item.id}).done).value.workspaces[0];
 const blocked=deferred();f.change({revoke:()=>blocked.promise});const revoke=f.call(f,'revoke',{...gesture,id:item.id});
 await until(()=>f.operations.some(x=>x.op==='revoke'));
 assert.equal(f.native.workspaceGrant('status',row.nativeKey,row.nativeGeneration).active,false);
 blocked.resolve();assert.equal((await revoke.done).value.workspaces[0].persistence,'absent');
});

test('911 missing OS persist still retires native temporary grant on revoke request',async t=>{
 const f=await workspaceFixture(t,{permissionDenied:true});const item=(await selected(f)).workspaces[0];
 const row=(await f.call(f,'attach',{...gesture,id:item.id}).done).value.workspaces[0];
 assert.equal((await f.call(f,'revoke',{...gesture,id:item.id}).done).error,'persistence_unavailable');
 assert.equal(f.native.workspaceGrant('status',row.nativeKey,row.nativeGeneration).drained,true);
});

test('911 close failure quarantines grant and denies subsequent attach',async t=>{
 const f=await workspaceFixture(t);const item=(await selected(f)).workspaces[0];f.change({close:async()=>{throw Error('close unresolved')}});
 assert.equal((await f.call(f,'attach',{...gesture,id:item.id}).done).error,'native_close_failed');
 const row=(await f.call(f,'list').done).value.workspaces[0];assert.equal(row.nativeGrant,'quarantined');
 assert.equal(f.native.workspaceGrant('status',row.nativeKey,row.nativeGeneration).active,false);
 assert.equal((await f.call(f,'attach',{...gesture,id:item.id}).done).error,'native_quarantined');
});

test('911 cancelling attach during descriptor close retires already-published native grant',async t=>{
 const f=await workspaceFixture(t);const first=await selected(f),firstBoot=first.bootId,item=first.workspaces[0];const blocked=deferred();f.change({close:()=>blocked.promise});
 t.after(()=>blocked.resolve());
 const attach=f.call(f,'attach',{...gesture,id:item.id});await until(()=>f.operations.some(x=>x.op==='closeDirectory'));
 await f.call(f,'cancel').done;assert.equal((await attach.done).error,'cancelled');
 const key=(await f.call(f,'list').done); // physical operation is still busy
 assert.equal(key.error,'busy');
 const nativeKey=(await f.call(f,'capabilities').done);assert.equal(nativeKey.error,undefined);
 // Boot id is from the actual selection, not guessed by the fixture.
 assert.equal(f.native.workspaceGrant('status',firstBoot+':'+item.id,item.generation).active,false);
 blocked.resolve();await until(()=>f.fds.size===0);
});

test('911 engine replacement retires old native root and old handler cannot regain authority',async t=>{
 const f=await workspaceFixture(t);const item=(await selected(f)).workspaces[0];
 const row=(await f.call(f,'attach',{...gesture,id:item.id}).done).value.workspaces[0];const replacement=f.attach();
 assert.equal(f.native.workspaceGrant('status',row.nativeKey,row.nativeGeneration).drained,true);
 assert.equal((await f.call(f,'attach',{...gesture,id:item.id}).done).error,'cancelled');
 assert.equal((await f.call(replacement,'attach',{...gesture,id:item.id}).done).error,'reauthorize');
});
