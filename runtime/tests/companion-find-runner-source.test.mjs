// Real loopback route -> actual pinned Domain/JSON -> actual anchored FS; synthetic files.
// Controlled await/fault boundaries are named explicitly. No full engine/device/model run.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,writeFile,rename,unlink,chmod,utimes,mkdir} from 'node:fs/promises';
import {join} from 'node:path';
import {registerHooks} from 'node:module';
import {randomUUID} from 'node:crypto';
import {findFixture,openFind,putDraft,completeFind,completion,sourcePath,until,load} from './fixtures/companion-find-runner-fixture.mjs';
const {fingerprint,parseTask,amendSchema,cancelSchema}=await load('companion/task-schema.js');
const operation=(f,rev=1,id='operation-2')=>({v:1,hostStoreId:f.store.hostStoreId,kind:'host.find_draft',operationId:id,expectedTaskRev:rev,taskRev:rev+1});
const agreement=body=>({args:body.args,deadlineAtMs:body.deadlineAtMs,afterExit:body.afterExit,allowQueue:body.allowQueue});

test('SOURCE_MOUNT task services advertise receipt support without loading the workbook codec', async t => {
  const loads = [];
  const hook = registerHooks({load(url, context, next) {
    if (url.endsWith('/receipt-workbook.js') || url.endsWith('/fflate.mjs')) loads.push(url);
    return next(url, context);
  }});
  t.after(() => hook.deregister());
  const f = await findFixture(t, {mountService: true});
  assert((await f.request('/capabilities')).body.kinds.includes('host.receipts_to_sheet'));
  assert.deepEqual(loads, []);
});

test('SOURCE_HTTP actual read-only sandbox search, atomic report/source commit and explicit source opening use zero model services',async t=>{
 const f=await findFixture(t,{sandboxed:true});await putDraft(f.root,'开场 A.md');await putDraft(f.root,'提纲 B.txt','B');
 await putDraft(f.root,'旧.txt','old',Date.parse('2026-11-19T12:00:00Z'));
 const commits=[],put=f.store.table.put.bind(f.store.table);
 t.mock.method(f.store.table,'put',async(id,record)=>{commits.push(structuredClone(record));return put(id,record);});
 const {response,snapshot}=await completeFind(f),report=completion(snapshot);
 assert.equal(snapshot.state,'done');assert.equal(snapshot.kind,'host.find_draft');assert.equal(snapshot.execution,undefined);
 assert.equal(f.counters.otherServices,0);assert.equal(f.counters.lists,1);assert.equal(f.counters.reads.length,2);
 assert.deepEqual(snapshot.steps.map(x=>x.stepKey),['selectInputs','readInputs']);assert.deepEqual(snapshot.artifacts,[]);
 assert.equal(report.coverage.entriesChecked,3);assert.equal(report.coverage.supportedFilesChecked,3);assert.equal(report.coverage.matchingCandidates,2);
 assert.equal(report.scope.timeZone,'UTC');assert(report.matches.every(x=>x.openable&&x.modifiedOffsetSeconds===0));
 for(const record of commits){const result=completion(record);assert.equal(!!result,!!record.notes['1']?.sources);}
 const disk=JSON.parse(await readFile(join(f.root,'storage','companion_tasks.json'),'utf8'));
 assert(!JSON.stringify(disk).includes('原稿'),'full body is never persisted in task storage');
 const cap=(await f.request('/capabilities')).body;assert.equal(cap.sourceRead,true);assert.deepEqual(cap.kinds,['host.find_draft']);
 const source=(await f.request(sourcePath(f,report.matches[0].sourceRef))).body;
 assert.equal(source.status,'available');assert.equal(source.version,report.matches[0].version);
 assert.equal(f.store.read(f.body.taskId).runnerReceiptSeq,snapshot.runnerReceiptSeq);assert.equal(f.counters.lists,1);
 const replay=await f.request('',f.body);assert.equal(replay.status,200);assert.equal(replay.body.hostExecutionId,snapshot.hostExecutionId);
 await new Promise(resolve=>setImmediate(resolve));assert.equal(f.counters.lists,1);
 if(process.env.H_FIND_WIRE_FIXTURE)await writeFile(process.env.H_FIND_WIRE_FIXTURE,JSON.stringify({scope:'ACTUAL_SOURCE_LOOPBACK_SYNTHETIC_IO',capabilities:cap,folder:f.folder,create:f.body,createReply:response.body,complete:snapshot,sourceAvailable:source},null,2)+'\n');
});
test('SOURCE_HTTP complete twelve-file zero-match search is done with real coverage and no reads',async t=>{
 const f=await findFixture(t);for(let i=0;i<12;i++)await putDraft(f.root,`${i}.md`,'old',Date.parse('2026-11-19T12:00:00Z'));
 const {snapshot}=await completeFind(f);assert.equal(snapshot.state,'done');assert.equal(completion(snapshot).coverage.entriesChecked,12);
 assert.deepEqual(completion(snapshot).matches,[]);assert.equal(f.counters.reads.length,0);
});
test('SOURCE_HTTP 21 matching candidates reports partial and verifies only the original 20',async t=>{
 const f=await findFixture(t);for(let i=0;i<21;i++)await putDraft(f.root,`${i}.md`);
 const {snapshot}=await completeFind(f),report=completion(snapshot);assert.equal(snapshot.state,'partial');
 assert.equal(report.coverage.matchingCandidates,21);assert.equal(report.coverage.candidateLimitReached,true);
 assert.equal(report.matches.length,20);assert.equal(f.counters.reads.length,20);
 assert.equal(f.store.read(f.body.taskId).notes['1'].sources.length,20);
});
test('find verifies originals without copying the task between file reads', async t => {
 const f=await findFixture(t);
 await putDraft(f.root,'a.md'); await putDraft(f.root,'b.md');
 const runner=f.start(), fileRead=f.fs.dshGoReadNote.bind(f.fs), taskRead=f.store.read.bind(f.store);
 const finish=f.store.finishFind.bind(f.store);
 let verifying=false, copies=0;
 t.mock.method(f.fs,'dshGoReadNote',(...args)=>{verifying=true;return fileRead(...args);});
 t.mock.method(f.store,'read',id=>{if(verifying)copies++;return taskRead(id);});
 t.mock.method(f.store,'finishFind',(...args)=>{verifying=false;return finish(...args);});
 await f.store.create(f.body); await runner.wake(f.body.taskId);
 assert.equal(f.counters.reads.length,2); assert.equal(copies,0);
});
test('SOURCE_HTTP 201 out-of-window entries retain the 200-entry bound and cannot claim zero complete',async t=>{
 const f=await findFixture(t);for(let i=0;i<201;i++)await putDraft(f.root,`${i}.md`,'old',Date.parse('2026-11-19T12:00:00Z'));
 const {snapshot}=await completeFind(f),report=completion(snapshot);assert.equal(snapshot.state,'partial');
 assert.equal(report.coverage.entriesChecked,200);assert.equal(report.coverage.entryLimitReached,true);assert.deepEqual(report.matches,[]);
});
test('SOURCE_HTTP actual nonroot EACCES retains A metadata while B remains openable',async t=>{
 assert.notEqual(process.getuid(),0,'This integration case requires real nonroot IO; H01 tests the root drop path');
 const f=await findFixture(t);const a=await putDraft(f.root,'A.md');await putDraft(f.root,'B.txt');await chmod(a,0);
 t.after(()=>chmod(a,0o600).catch(()=>{}));
 const {snapshot}=await completeFind(f),report=completion(snapshot);assert.equal(snapshot.state,'partial');
 const denied=report.matches.find(x=>x.relativePath==='A.md');assert.equal(denied.openable,false);assert.equal(denied.reason,'original_not_readable');
 assert.equal(report.matches.find(x=>x.relativePath==='B.txt').openable,true);
 const opened=(await f.request(sourcePath(f,denied.sourceRef))).body;assert.equal(opened.status,'not_readable');assert.equal(opened.content,null);
 t.diagnostic(JSON.stringify({actual_nonroot_uid:process.getuid(),gid:process.getgid()}));
});
test('SOURCE_HTTP whole 64KiB cap, binary and invalid UTF8 are not silently shortened into openable sources',async t=>{
 const f=await findFixture(t);await putDraft(f.root,'big.md','x'.repeat(65537));await putDraft(f.root,'nul.txt',Buffer.from([65,0,66]));
 await putDraft(f.root,'utf8.md',Buffer.from([0xc3,0x28]));await putDraft(f.root,'good.md');
 const {snapshot}=await completeFind(f);assert.equal(snapshot.state,'partial');
 assert.deepEqual(completion(snapshot).matches.filter(x=>x.openable).map(x=>x.relativePath),['good.md']);
 assert.equal(completion(snapshot).matches.find(x=>x.relativePath==='big.md').reason,'original_too_large');
});
test('SOURCE_HTTP actual equal-size/mtime replacement after selection refuses A and preserves B original version',async t=>{
 let f;f=await findFixture(t,{list:async(args,actual)=>{
  const listed=await actual();const old=listed.entries.find(x=>x.name==='A.md');await rename(join(f.root,'notes','A.md'),join(f.root,'old-A'));
  const path=await putDraft(f.root,'A.md','NEW',old.modifiedAtMs);await utimes(path,new Date(old.modifiedAtMs),new Date(old.modifiedAtMs));return listed;
 }});await putDraft(f.root,'A.md','OLD');await putDraft(f.root,'B.txt','B');
 const {snapshot}=await completeFind(f),report=completion(snapshot);assert.equal(snapshot.state,'partial');
 assert.equal(report.matches.find(x=>x.relativePath==='A.md').reason,'original_changed');assert.equal(report.matches.find(x=>x.relativePath==='B.txt').openable,true);
});
test('SOURCE_HTTP source open binds owner/store/task/execution/reference before IO and rejects replacement query paths',async t=>{
 const f=await findFixture(t);await putDraft(f.root,'A.md');const {snapshot}=await completeFind(f);const source=completion(snapshot).matches[0].sourceRef;
 const before=f.counters.reads.length;
 for(const [path,headers,status] of [[sourcePath(f,source),{authorization:'other'},403],
  [sourcePath(f,source,'wrong'),{},409],[sourcePath(f,'not-registered'),{},404],
  [sourcePath(f,source)+'&path=/etc/passwd',{},400],[sourcePath(f,source)+'&hostExecutionId=wrong',{},400],
  [sourcePath(f,source).replace(f.store.hostStoreId,'wrong-store'),{},409]]){
  const result=await f.request(path,undefined,headers);assert.equal(result.status,status);
 }
 assert.equal(f.counters.reads.length,before);assert.equal(f.counters.lists,1);
});
test('SOURCE_HTTP source disappearance/change/unavailable report current status without revising historical completion',async t=>{
 const f=await findFixture(t);await putDraft(f.root,'A.md','OLD');const {snapshot}=await completeFind(f),original=completion(snapshot),row=original.matches[0];
 await rename(join(f.root,'notes','A.md'),join(f.root,'old-A'));await putDraft(f.root,'A.md','NEW',row.modifiedAtMs);
 assert.equal((await f.request(sourcePath(f,row.sourceRef))).body.status,'changed');await unlink(join(f.root,'notes','A.md'));
 assert.equal((await f.request(sourcePath(f,row.sourceRef))).body.status,'missing');
 const read=f.fs.dshGoReadNote;t.mock.method(f.fs,'dshGoReadNote',async()=>{throw Object.assign(new Error('controlled EIO'),{code:'EIO'});});
 assert.equal((await f.request(sourcePath(f,row.sourceRef))).body.status,'unknown');
 assert.deepEqual(completion(f.store.snapshot(f.body.taskId)),original);assert.equal(f.store.snapshot(f.body.taskId).runnerReceiptSeq,snapshot.runnerReceiptSeq);
});
test('SOURCE_HTTP pre-create H cancel persists H kind, rejects cross-kind operations and never runs late rev1',async t=>{
 const f=await findFixture(t);f.start();const fence=await f.request(`/${f.body.taskId}/cancel`,operation(f));
 assert.equal(fence.body.kind,'host.find_draft');assert.equal(fence.body.state,'cancelled');
 const cross=await f.request(`/${f.body.taskId}/cancel`,{...operation(f),kind:'host.notes_to_todo'});assert.equal(cross.status,409);
 const late=await f.request('',f.body);assert.equal(late.status,200);assert.equal(late.body.hostExecutionId,fence.body.hostExecutionId);
 await new Promise(resolve=>setImmediate(resolve));assert.equal(f.counters.lists,0);
 const reopen=await f.request(`/${f.body.taskId}/amend`,{...operation(f,2,'amend-3'),changes:agreement(f.body)});assert.equal(reopen.status,409);
});
test('SOURCE_HTTP pre-create H amend runs only current agreement and keeps original create fingerprint',async t=>{
 const f=await findFixture(t);await putDraft(f.root,'A.md');await putDraft(f.root,'B.txt');f.start();
 const changed={...agreement(f.body),args:{...f.body.args,extensions:['txt']}};
 const fence=await f.request(`/${f.body.taskId}/amend`,{...operation(f),changes:changed});assert.equal(fence.body.originalCreatePresent,false);
 await f.request('',f.body);await until(()=>f.store.read(f.body.taskId).state==='done','amended result');
 const snapshot=f.store.snapshot(f.body.taskId);assert.equal(snapshot.taskRev,2);assert(snapshot.steps.every(x=>x.taskRev===2));
 assert.deepEqual(completion(snapshot).matches.map(x=>x.relativePath),['B.txt']);
 assert.equal(f.store.read(f.body.taskId).originalFingerprint,fingerprint(f.body));
});
test('SOURCE_HTTP strict fixed args and absent F operation kind preserve deployed fingerprints',async t=>{
 const f=await findFixture(t);f.start();
 for(const args of [{...f.body.args,extensions:['md','md']},{...f.body.args,scope:'recursive'},{...f.body.args,path:'/other'},{...f.body.args,outputName:'x.md'}])
  assert.equal((await f.request('',{...f.body,args})).status,400);
 const legacy={v:1,hostStoreId:f.store.hostStoreId,operationId:'old-cancel',expectedTaskRev:1,taskRev:2};
 const parsed=parseTask(cancelSchema,legacy);assert.deepEqual(parsed,legacy);assert.equal(Object.hasOwn(parsed,'kind'),false);
 assert.equal(fingerprint({cancel:true,body:parsed}),fingerprint({cancel:true,body:legacy}));
 assert.throws(()=>parseTask(amendSchema,{...legacy,changes:agreement(f.body)}));
});
test('SOURCE_HTTP pause remains waiting and consumes no list/read/model work',async t=>{
 const f=await findFixture(t);await putDraft(f.root,'A.md');const {snapshot}=await completeFind(f,{...f.body,afterExit:'pause'});
 assert.equal(snapshot.state,'waiting');assert.equal(snapshot.waitReason,'foreground_control_unavailable');
 assert.equal(f.counters.lists,0);assert.equal(f.counters.reads.length,0);assert.equal(f.counters.otherServices,0);
});
test('SOURCE_HTTP controlled cancel during first real read retains original partial and stops new reads',async t=>{
 let release,entered;const gate=new Promise(resolve=>{release=resolve;}),seen=new Promise(resolve=>{entered=resolve;});
 const f=await findFixture(t,{read:async(args,actual)=>{entered();await gate;return actual();}});await putDraft(f.root,'A.md');await putDraft(f.root,'B.txt');
 f.start();await f.request('',f.body);await seen;const cancelled=await f.request(`/${f.body.taskId}/cancel`,operation(f));assert.equal(cancelled.body.taskRev,2);
 release();await until(()=>f.store.read(f.body.taskId).steps.every(x=>x.finishedAtMs!==null),'cancelled read settled');
 const snapshot=f.store.snapshot(f.body.taskId);assert.equal(snapshot.state,'cancelled');assert.equal(snapshot.taskRev,2);
 const original=snapshot.steps.find(x=>x.stepKey==='readInputs').result.completion;
 assert.equal(original.matches.length,2);assert(original.matches.every(x=>!x.openable));assert.equal(f.counters.reads.length,1);
 assert.equal(f.store.read(f.body.taskId).notes['1'].sources.length,2);
});
test('SOURCE_HTTP explicit amend after done preserves old immutable report/source and only new revision drives head',async t=>{
 const f=await findFixture(t);await putDraft(f.root,'A.md');await putDraft(f.root,'B.txt');const {snapshot:one}=await completeFind(f);
 const old=completion(one),changes={...agreement(f.body),args:{...f.body.args,extensions:['txt']}};
 const accepted=await f.request(`/${f.body.taskId}/amend`,{...operation(f),changes});assert.equal(accepted.status,200);
 await until(()=>f.store.read(f.body.taskId).state==='done','new revision done');const two=f.store.snapshot(f.body.taskId);
 assert.equal(two.taskRev,2);assert.deepEqual(two.steps.find(x=>x.taskRev===1&&x.stepKey==='readInputs').result.completion,old);
 assert.deepEqual(completion(two).matches.map(x=>x.relativePath),['B.txt']);
 assert.equal((await f.request(sourcePath(f,old.matches[0].sourceRef))).body.taskRev,1);assert.equal(f.counters.lists,2);
});
test('SOURCE_HTTP wall-clock deadline crossing after a held actual read prevents the next IO but preserves observations',async t=>{
 let now=Date.now(),advance=false;const f=await findFixture(t,{now:()=>now,read:async(args,actual)=>{const read=await actual();if(advance)now+=20000;return read;}});
 await putDraft(f.root,'A.md');await putDraft(f.root,'B.txt');advance=true;
 const {snapshot}=await completeFind(f,{...f.body,deadlineAtMs:now+10000});assert.equal(snapshot.state,'partial');assert.equal(f.counters.reads.length,1);
 assert(completion(snapshot).coverage.gaps.some(x=>x.reason==='deadline_expired'));assert.equal(completion(snapshot).matches.filter(x=>x.openable).length,1);
});
test('SOURCE_HTTP actual postscan directory removal keeps both metadata and incomplete coverage',async t=>{
 let f;f=await findFixture(t,{list:async(args,actual)=>{const listing=await actual();await rename(join(f.root,'notes'),join(f.root,'old-notes'));return listing;}});
 await putDraft(f.root,'A.md');const {snapshot}=await completeFind(f);assert.equal(snapshot.state,'partial');
 assert.equal(completion(snapshot).matches[0].reason,'original_missing');assert.equal(completion(snapshot).coverage.entriesChecked,1);
});
test('SOURCE_HTTP initial nonexistent directory fails without fabricated zero complete result',async t=>{
 const f=await findFixture(t);await rename(join(f.root,'notes'),join(f.root,'old-notes'));const {snapshot}=await completeFind(f);
 assert.equal(snapshot.state,'failed');assert.equal(completion(snapshot),undefined);assert.equal(f.counters.reads.length,0);
});

async function persistSelection(f){
 await f.store.create(f.body);const claim=await f.store.claimStep(f.body.taskId,1,'selectInputs',{reserveMs:300000});
 const listing=await f.fs.dshGoListDrafts(f.store.folder(f.folder.folderRef),{...f.store.read(f.body.taskId).notes['1'].dayRange,extensions:f.body.args.extensions});
 const selection={...listing,entries:listing.entries.map(e=>({...e,sourceRef:randomUUID()})),
  scope:{...f.body.args,displayPath:listing.directory.target.displayPath,...f.store.read(f.body.taskId).notes['1'].dayRange}};
 await f.store.finishFindSelection(claim,selection,7);return selection;
}
test('SOURCE_RESTART persisted scan plus uncompleted read recovers original metadata without any new IO and retains held budget',async t=>{
 const f=await findFixture(t);await putDraft(f.root,'A.md');const selection=await persistSelection(f);
 const before=f.store.snapshot(f.body.taskId);assert.equal(before.budget.heldMs,299993);await f.close();
 await putDraft(f.root,'later.txt');const next=await openFind(f.root);t.after(()=>next.close());next.start();
 await until(()=>next.store.read(f.body.taskId).state==='partial','read recovery');const after=next.store.snapshot(f.body.taskId);
 assert.deepEqual(after.budget,before.budget);assert.equal(next.counters.lists,0);assert.equal(next.counters.reads.length,0);
 const report=completion(after);assert.deepEqual(report.matches.map(x=>x.relativePath),['A.md']);assert.equal(report.matches[0].reason,'verification_interrupted');
 assert.equal(report.matches[0].sourceRef,selection.entries[0].sourceRef);
 const opened=await next.store.source(f.body.taskId,report.matches[0].sourceRef,after.hostExecutionId);assert.equal(opened.status,'available');
 assert.equal(next.store.snapshot(f.body.taskId).runnerReceiptSeq,after.runnerReceiptSeq);
});
test('SOURCE_RESTART complete zero-candidate persisted scan needs no body IO and recovers done while retaining unknown elapsed hold',async t=>{
 const f=await findFixture(t);await putDraft(f.root,'old.md','old',Date.parse('2026-11-19T12:00:00Z'));await persistSelection(f);
 const held=f.store.read(f.body.taskId).budget.heldMs;await f.close();const next=await openFind(f.root);t.after(()=>next.close());next.start();
 await until(()=>next.store.read(f.body.taskId).state==='done','zero recovery');assert.equal(next.store.read(f.body.taskId).budget.heldMs,held);
 assert.equal(next.counters.lists,0);assert.equal(next.counters.reads.length,0);assert.deepEqual(completion(next.store.snapshot(f.body.taskId)).coverage.gaps,[]);
});
test('SOURCE_RESTART interrupted unsaved scan never re-enumerates on restart, GET or original-create replay',async t=>{
 const f=await findFixture(t);await f.store.create(f.body);await f.store.claimStep(f.body.taskId,1,'selectInputs',{reserveMs:300000});
 await f.close();await putDraft(f.root,'new.md');const next=await openFind(f.root);t.after(()=>next.close());next.start();
 await until(()=>next.store.read(f.body.taskId).state==='unknown','scan unknown');
 const one=next.store.snapshot(f.body.taskId);assert.equal(one.waitReason,'scan_interrupted');assert.equal(one.budget.heldMs,300000);
 await next.request(`/${f.body.taskId}?hostStoreId=${next.store.hostStoreId}`);await next.request('',f.body);
 await new Promise(resolve=>setImmediate(resolve));assert.equal(next.counters.lists,0);assert.equal(next.counters.reads.length,0);
});
test('SOURCE_HTTP actual mtime offsets use each instant across the original 25-hour New York civil day',async t=>{
 const f=await findFixture(t);await putDraft(f.root,'before.md','a',Date.parse('2026-11-01T05:30:00Z'));
 await putDraft(f.root,'after.txt','b',Date.parse('2026-11-01T06:30:00Z'));
 const {snapshot}=await completeFind(f,{...f.body,args:{...f.body.args,localDate:'2026-11-01',timeZone:'America/New_York'}});
 const report=completion(snapshot);assert.equal(snapshot.state,'done');assert.equal(report.scope.endAtMs-report.scope.startAtMs,25*3600000);
 assert.equal(report.matches.find(x=>x.relativePath==='before.md').modifiedOffsetSeconds,-14400);
 assert.equal(report.matches.find(x=>x.relativePath==='after.txt').modifiedOffsetSeconds,-18000);
});
test('SOURCE_MOUNT production task service dispatches find through real runner without touching Agent or model; Cordis lifecycle is supplied',async t=>{
 const f=await findFixture(t,{mountService:true});await putDraft(f.root,'A.md');const {snapshot}=await completeFind(f);
 const capabilities=(await f.request('/capabilities')).body;assert.deepEqual(capabilities.kinds,['host.notes_to_todo','host.find_draft','host.compare_drafts','host.receipts_to_sheet']);
 assert.equal(capabilities.sourceRead,true);assert.equal(snapshot.state,'done');assert.equal(f.counters.otherServices,0);
 const notes={...f.body,taskId:'notes-pause',kind:'host.notes_to_todo',afterExit:'pause',args:{folderRef:f.folder.folderRef,outputDirRef:f.folder.folderRef,
  localDate:'2026-11-20',timeZone:'UTC',dateBy:'modified',outputName:'todo.md',writeMode:'createNew'}};
 const paused=await f.request('',notes);assert.equal(paused.status,201);assert.equal(paused.body.waitReason,'foreground_required');
 assert.equal(capabilities.notesForeground,true);
 const findPaused=await f.request('',{...f.body,taskId:'find-pause',afterExit:'pause'});
 assert.equal(findPaused.body.waitReason,'foreground_control_unavailable');
 const refused=await f.request('/find-pause/foreground',{v:1,hostStoreId:f.store.hostStoreId,
   taskRev:1,hostExecutionId:findPaused.body.hostExecutionId,sourceSessionId:f.body.origin.sourceSessionId});
 assert.equal(refused.status,409);assert.equal(f.store.snapshot('find-pause').steps.length,0);
 assert.equal(f.counters.otherServices,0);
});
test('SOURCE_HTTP amendment during a controlled held read preserves old report and later executes only the new revision',async t=>{
 let release,entered,held=false;const gate=new Promise(resolve=>{release=resolve;}),seen=new Promise(resolve=>{entered=resolve;});
 const f=await findFixture(t,{read:async(args,actual)=>{if(!held){held=true;entered();await gate;}return actual();}});
 await putDraft(f.root,'A.md');await putDraft(f.root,'B.txt');f.start();await f.request('',f.body);await seen;
 const changes={...agreement(f.body),args:{...f.body.args,extensions:['txt']}};
 assert.equal((await f.request(`/${f.body.taskId}/amend`,{...operation(f),changes})).status,200);release();
 await until(()=>f.store.read(f.body.taskId).state==='done','new revision after held old read');const snapshot=f.store.snapshot(f.body.taskId);
 assert.equal(snapshot.taskRev,2);assert.equal(snapshot.steps.find(x=>x.taskRev===1&&x.stepKey==='readInputs').state,'partial');
 assert.deepEqual(completion(snapshot).matches.map(x=>x.relativePath),['B.txt']);assert.equal(f.counters.lists,2);
 assert.equal(f.store.read(f.body.taskId).notes['1'].sources.length,2);
});
test('SOURCE_HTTP cancel after actual scan before selection commit still stores original coverage and zero-time read claim without new IO',async t=>{
 let f;f=await findFixture(t,{list:async(args,actual)=>{const listing=await actual();await f.store.cancel(f.body.taskId,operation(f));return listing;}});
 await putDraft(f.root,'A.md');f.start();await f.request('',f.body);
 await until(()=>f.store.read(f.body.taskId).steps.some(x=>x.stepKey==='readInputs'&&x.finishedAtMs!==null),'late scan settled');
 const snapshot=f.store.snapshot(f.body.taskId),original=snapshot.steps.find(x=>x.stepKey==='readInputs');
 assert.equal(snapshot.taskRev,2);assert.equal(snapshot.state,'cancelled');assert.equal(original.state,'partial');
 assert.equal(f.store.read(f.body.taskId).steps.find(x=>x.stepKey==='readInputs').reserveMs,0);assert.equal(f.counters.reads.length,0);
 assert.equal(original.result.completion.coverage.entriesChecked,1);assert.equal(original.result.completion.matches.length,1);
 const row=original.result.completion.matches[0];const opened=(await f.request(sourcePath(f,row.sourceRef))).body;
 assert.equal(opened.status,'available');assert.equal(opened.taskRev,1);assert.equal(f.store.snapshot(f.body.taskId).state,'cancelled');
});
test('SOURCE_RESTART controlled report commit failure cannot expose success without sources; recovery retains only durable read evidence',async t=>{
 const f=await findFixture(t);await putDraft(f.root,'A.md');const put=f.store.table.put.bind(f.store.table);let failed=false;
 t.mock.method(f.store.table,'put',async(id,record)=>{
  if(!failed&&completion(record)){failed=true;throw new Error('controlled before-commit failure');}return put(id,record);
 });
 f.start();await f.request('',f.body);await until(()=>failed,'report commit fault');
 assert.equal(completion(f.store.snapshot(f.body.taskId)),undefined);assert.equal(f.store.read(f.body.taskId).notes['1'].sources,undefined);
 await f.close();const next=await openFind(f.root);t.after(()=>next.close());next.start();
 await until(()=>next.store.read(f.body.taskId).state==='partial','fault recovery');
 assert.equal(completion(next.store.snapshot(f.body.taskId)).matches[0].openable,false);assert.equal(next.counters.reads.length,0);
});
test('SOURCE_HTTP controlled exhausted cumulative budget survives explicit amendment and never resets for another scan',async t=>{
 const f=await findFixture(t);await putDraft(f.root,'A.md');const {snapshot}=await completeFind(f),old=completion(snapshot);
 const record=f.store.read(f.body.taskId);record.budget={limitMs:300000,spentMs:300000,heldMs:0};await f.store.commit(record);
 await f.request(`/${f.body.taskId}/amend`,{...operation(f),changes:agreement(f.body)});
 await until(()=>f.store.read(f.body.taskId).state==='failed','exhausted amendment');
 assert.equal(f.counters.lists,1);assert.equal(f.store.read(f.body.taskId).budget.spentMs,300000);
 assert.deepEqual(f.store.snapshot(f.body.taskId).steps.find(x=>x.taskRev===1&&x.stepKey==='readInputs').result.completion,old);
});
