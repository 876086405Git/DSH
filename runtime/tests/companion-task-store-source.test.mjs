// SOURCE_CONTROLLED: actual Domain, JSON backend, PID lock and temp-file IO.
// The harness omits unused Cordis configuration schemas, not storage behavior.
// statfs is overridden only to exercise the verified-local branch on CI overlay.
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, rm, readFile, writeFile, symlink, stat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve, join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';

const harness = process.env.COMPANION_TASK_HARNESS;
assert.ok(harness, 'Set COMPANION_TASK_HARNESS to the prepared exact-source modules; absence is NOT a pass/skip');
const load = path => import(pathToFileURL(resolve(harness, path)).href);
const {JsonStorageBackend} = await load('node_modules/@deepseek-ai/dsh-storage-json/index.js');
const {DomainFacility, defineDomain, domainTable} = await load('node_modules/@deepseek-ai/dsh-storage-domain/index.js');
const {BackendRegistry, StorageError} = await load('node_modules/@deepseek-ai/dsh-storage/index.js');
const {openCompanionTaskStore} = await load('companion/task-store.js');
const {recordSchema, dayRange} = await load('companion/task-schema.js');
const {z} = await load('node_modules/zod/index.js');

const directory = {target: {targetKey: '/chosen/notes', displayPath: '/chosen/notes'}, identity: '1:2'};
const fs = {resolve: async path => ({targetKey:path,displayPath:path}),
  dshGoBindNotesDirectory: async target => ({target,identity:'1:2'})};
function owners(root, options = {}) {
  const backend = new JsonStorageBackend(root);
  if (options.injectLocal !== false) backend.dshGoCompanionStatfs = async () => ({type: 0xef53n});
  const registry = new BackendRegistry(); registry.register('routed-json', backend);
  const ctx = {storage:{backend:registry},emit(){},logger:{warn(){},error(){}},fiber:{assertActive(){}}};
  const facility = new DomainFacility(ctx,{backend:'unrelated',routes:{companion_tasks:'routed-json',ordinary:'routed-json'}});
  return {backend,facility};
}
async function opened(t, root) {
  root ??= await mkdtemp(join(tmpdir(),'companion-task-'));
  const owner = owners(root), store = await openCompanionTaskStore({...owner,fs});
  t.after(async()=>{await store.close();await owner.backend.close();await rm(root,{recursive:true,force:true});});
  await store.folders.put('folder', {folderRef:'folder',directory,createdAtMs:1});
  return {...owner,store,root};
}
const agreement = {args:{folderRef:'folder',outputDirRef:'folder',localDate:'2026-11-20',timeZone:'Asia/Shanghai',
  dateBy:'modified',outputName:'今日待办.md',writeMode:'createNew'},deadlineAtMs:null,afterExit:'continue',allowQueue:true};
function create(store,id='t-1') {return {v:1,hostStoreId:store.hostStoreId,taskId:id,taskRev:1,kind:'host.notes_to_todo',
  origin:{sourceSessionId:'light:room',messageId:'message-1',itemNo:0},hostSessionId:null,...structuredClone(agreement)};}
function cancel(store,rev=1,id='cancel-1'){return {v:1,hostStoreId:store.hostStoreId,operationId:id,expectedTaskRev:rev,taskRev:rev+1};}
function amend(store,rev=1,id='amend-1'){return {...cancel(store,rev,id),changes:{...structuredClone(agreement),args:{...agreement.args,outputName:'new.md'}}};}
const finish = {state:'done',reason:null,result:null,elapsedMs:1};
async function readyToPublish(store,id='t-1') {
  await store.create(create(store,id));
  const model = await store.claimStep(id,1,'model',{reserveMs:100});
  await store.saveCandidate(model,{content:'# 待办\n',mediaType:'text/markdown',sourceCount:1,usage:null});
  await store.finishStep(model,finish);
  const claim = await store.claimStep(id,1,'writePage',{reserveMs:100});
  await store.savePublishIntent(claim,{directory,outputName:'今日待办.md',stageName:'.stage',fileIdentity:'1:3',size:9,sha256:'a'.repeat(64)});
  return claim;
}
const artifact = {relativePath:'今日待办.md',mediaType:'text/markdown',size:9,sha256:'a'.repeat(64),
  identity:'1:3',verifiedAtMs:2,sourceCount:1};

test('actual routed backend persists host identity; close/reopen keeps it',async t=>{
  const {store,root}=await opened(t);const id=store.hostStoreId;
  assert.equal(JSON.parse(await readFile(join(root,'companion_tasks.json'),'utf8')).global.hostStoreId,id);
  await store.close();const next=owners(root);const reopened=await openCompanionTaskStore({...next,fs});
  assert.equal(reopened.hostStoreId,id);await reopened.close();await next.backend.close();
});
test('different task-store identity rejects before creation',async t=>{
  const {store}=await opened(t);assert.throws(()=>store.create({...create(store),hostStoreId:'other-store'}),/another task store/);
  assert.equal(store.table.size,0);
});
test('same creation races commit one execution and one original plan',async t=>{
  const {store}=await opened(t);const body=create(store);
  const [a,b]=await Promise.all([store.create(body),store.create(structuredClone(body))]);
  assert.equal(a.snapshot.hostExecutionId,b.snapshot.hostExecutionId);assert.equal(a.snapshot.runnerReceiptSeq,1);
  assert.equal(b.snapshot.runnerReceiptSeq,1);assert.equal(store.table.size,1);assert.equal(b.created,false);
  await assert.rejects(store.create({...body,args:{...body.args,outputName:'other.md'}}),/another original creation/);
});
test('cancel before create holds stable execution and late original cannot run',async t=>{
  const {store}=await opened(t);const fence=await store.cancel('t-1',cancel(store));
  assert.equal(fence.state,'cancelled');assert.equal(fence.originalCreatePresent,false);assert.equal(fence.approval,null);
  const result=(await store.create(create(store))).snapshot;
  assert.equal(result.hostExecutionId,fence.hostExecutionId);assert.equal(result.taskRev,2);assert.equal(result.state,'cancelled');
  assert.equal(result.originalCreatePresent,true);assert.deepEqual(store.runnable(),[]);
  const old=await store.amend('t-1',amend(store));assert.equal(old.state,'cancelled');assert.equal(old.runnerReceiptSeq,result.runnerReceiptSeq);
});
test('amend before create keeps original fingerprint and only current complete agreement',async t=>{
  const {store}=await opened(t);const first=await store.amend('t-1',amend(store));
  assert.equal(first.waitReason,'original_create_missing');assert.equal(first.originalCreatePresent,false);
  const current=(await store.create(create(store))).snapshot;
  assert.equal(current.hostExecutionId,first.hostExecutionId);assert.equal(current.agreement.args.outputName,'new.md');
  assert.deepEqual(current.revisions.map(r=>r.taskRev),[1,2]);assert.equal(current.state,'running');
  assert.equal((await store.create(create(store))).snapshot.runnerReceiptSeq,current.runnerReceiptSeq);
});
test('operation exact replay is idempotent; changed operation body and stale CAS reject',async t=>{
  const {store}=await opened(t);await store.create(create(store));const body=amend(store);const a=await store.amend('t-1',body);
  assert.deepEqual(await store.amend('t-1',body),a);
  await assert.rejects(store.amend('t-1',{...body,changes:agreement}),/another request/);
  await assert.rejects(store.amend('t-1',amend(store,1,'other-operation')),/revision changed/);
});
test('pause is durably waiting and rejects a physical step',async t=>{
  const {store}=await opened(t);const a=(await store.create({...create(store),afterExit:'pause'})).snapshot;
  assert.equal(a.waitReason,'foreground_control_unavailable');
  await assert.rejects(store.claimStep('t-1',1,'model',{reserveMs:100}),/not runnable/);
  await store.amend('t-1',amend(store));assert.equal(store.read('t-1').state,'running');
});
test('original date boundaries include actual 25-hour DST day and reject skipped local day',()=>{
  const range=dayRange({args:{localDate:'2026-11-01',timeZone:'America/New_York'}});
  assert.equal(range.endAtMs-range.startAtMs,25*60*60*1000);
  assert.throws(()=>dayRange({args:{localDate:'2011-12-30',timeZone:'Pacific/Apia'}}),/do not identify a day/);
});
test('stored selection and whole input are private and cannot change on recovery',async t=>{
  const {store}=await opened(t);await store.create(create(store));
  const select=await store.claimStep('t-1',1,'selectInputs',{reserveMs:100});
  await store.saveSelection(select,{directory,entries:[{name:'one.md',version:'opaque'}],scope:{dateBy:'modified'}});
  await store.finishStep(select,finish);
  const read=await store.claimStep('t-1',1,'readInputs',{reserveMs:100});
  await store.saveInputs(read,{directory,entries:[{name:'one.md',version:'opaque',text:'独有正文'}],scope:{}});
  assert.equal(JSON.stringify(store.snapshot('t-1')).includes('独有正文'),false);
  const record=store.read('t-1'),input=record.notes['1'].inputs.entries[0];
  assert.equal(input.text,'独有正文');
  // The public projection must not walk private notes (they may hold a whole workbook).
  let bodyReads=0;
  Object.defineProperty(input,'text',{enumerable:true,get(){bodyReads++;return '独有正文';}});
  store.project(record);
  assert.equal(bodyReads,0);
  await assert.rejects(store.saveSelection(select,{directory,entries:[],scope:{}}),/already saved/);
});
test('unknown model claim reserves time and cannot make another physical attempt',async t=>{
  const {store}=await opened(t);await store.create(create(store));const claim=await store.claimStep('t-1',1,'model',{reserveMs:300000});
  await store.observeStep(claim,{dispatched:null,usage:null});
  await store.finishStep(claim,{state:'unknown',reason:'stream_lost',result:null,elapsedMs:null});
  assert.equal(store.snapshot('t-1').budget.heldMs,300000);
  await assert.rejects(store.claimStep('t-1',1,'model',{reserveMs:1}),/original step/);
  await assert.rejects(store.claimStep('t-1',1,'writePage',{reserveMs:1}),/budget is exhausted/);
});
test('old unknown model finish preserves confirmed cancellation and observed usage',async t=>{
  const {store}=await opened(t);await store.create(create(store));const claim=await store.claimStep('t-1',1,'model',{reserveMs:100});
  const pending=await store.cancel('t-1',cancel(store));assert.equal(pending.state,'unknown');
  await store.observeStep(claim,{dispatched:true,usage:{output_tokens:7}});
  const a=await store.finishStep(claim,{...finish,state:'unknown',reason:'stream_lost',elapsedMs:8});
  assert.equal(a.taskRev,2);assert.equal(a.state,'cancelled');assert.equal(a.steps[0].result.observations[0].usage.output_tokens,7);
  assert.equal(a.steps[0].state,'unknown');assert.ok(a.steps[0].finishedAtMs!==null);
  assert.deepEqual(a.budget,{limitMs:300000,spentMs:8,heldMs:0});
  await assert.rejects(store.claimStep('t-1',2,'writePage',{reserveMs:10}),/no longer authorizes/);
});
test('known write is one complete snapshot; cancelled head keeps original artifact',async t=>{
  const {store}=await opened(t);const claim=await readyToPublish(store);
  const a=await store.publish(claim,async()=>({artifact,elapsedMs:3,state:'partial',reason:'unreadable_source'}));
  assert.equal(a.state,'partial');assert.equal(a.artifacts.length,1);assert.equal(a.steps.length,2);
  assert.equal('reference' in a.artifacts[0],false);
  const b=await store.cancel('t-1',cancel(store));assert.equal(b.state,'cancelled');assert.deepEqual(b.artifacts,a.artifacts);
  assert.ok(b.runnerReceiptSeq>a.runnerReceiptSeq);
});
test('old revision verified publication reconciles without another link or flipping amended head',async t=>{
  const {store}=await opened(t);const claim=await readyToPublish(store);
  await assert.rejects(store.publish(claim,async()=>{throw new Error('physical call returned no receipt');}),/physical call/);
  await store.amend('t-1',amend(store));
  const a=await store.recordArtifact(claim,{artifact,elapsedMs:null,state:'done',reason:null});
  assert.equal(a.taskRev,2);assert.equal(a.state,'partial');assert.equal(a.waitReason,'prior_revision_effect');
  assert.equal(a.artifacts[0].taskRev,1);assert.equal(a.budget.heldMs,100);
  assert.deepEqual(await store.recordArtifact(claim,{artifact,elapsedMs:null,state:'done',reason:null}),a);
});
test('backend failed-before-write leaves live cached object and reopened medium unchanged',async t=>{
  const {store,backend,root}=await opened(t);await store.create(create(store));const before=store.snapshot('t-1');
  const unit=backend.open.get('companion_tasks'), put=unit.putRecord.bind(unit);
  unit.putRecord=async()=>{throw new Error('injected before actual write');};
  await assert.rejects(store.amend('t-1',amend(store)),/injected/);
  assert.deepEqual(store.snapshot('t-1'),before);unit.putRecord=put;await store.close();
  const other=owners(root), reopened=await openCompanionTaskStore({...other,fs});
  assert.deepEqual(reopened.snapshot('t-1'),before);await reopened.close();await other.backend.close();
});
test('actual commit followed by unknown-state quarantines live cache; restart sees original durable result',async t=>{
  const {store,backend,root}=await opened(t);await store.create(create(store));const unit=backend.open.get('companion_tasks'),put=unit.putRecord.bind(unit);
  unit.putRecord=async(...args)=>{await put(...args);throw new StorageError('unknown-state','injected lost commit acknowledgement');};
  await assert.rejects(store.amend('t-1',amend(store)),/lost commit acknowledgement/);
  assert.throws(()=>store.snapshot('t-1'),/lost commit acknowledgement/);
  unit.putRecord=put;await store.close();const other=owners(root),reopened=await openCompanionTaskStore({...other,fs});
  assert.equal(reopened.snapshot('t-1').taskRev,2);await reopened.close();await other.backend.close();
});
test('ordinary Domain.close still rejects a synchronous following write immediately',async t=>{
  const root=await mkdtemp(join(tmpdir(),'ordinary-domain-')),owner=owners(root);
  t.after(async()=>{await owner.backend.close();await rm(root,{recursive:true,force:true});});
  const domain=await owner.facility.open(defineDomain({name:'ordinary',version:1,tables:{items:domainTable(z.object({n:z.number()}))}}));
  const done=domain.close();await assert.rejects(domain.table('items').put('key',{n:1}),/closed/);await done;
});
test('two actual backend owners of one root cannot simultaneously load the domain',async t=>{
  const {store,root}=await opened(t);const other=owners(root);let loaded=false;
  const next=openCompanionTaskStore({...other,fs}).then(value=>{loaded=true;return value;});
  await delay(40);assert.equal(loaded,false);await store.close();const second=await next;assert.equal(loaded,true);
  await second.close();await other.backend.close();
});
test('a symlink alias of the actual storage root takes the same writer lock',async t=>{
  const {store,root}=await opened(t);const parent=await mkdtemp(join(tmpdir(),'task-alias-')),alias=join(parent,'alias');
  t.after(()=>rm(parent,{recursive:true,force:true}));await symlink(root,alias,'dir');
  const other=owners(alias);let loaded=false;const next=openCompanionTaskStore({...other,fs}).then(value=>{loaded=true;return value;});
  await delay(40);assert.equal(loaded,false);await store.close();const second=await next;
  await second.close();await other.backend.close();
});
test('real backend.close waits held physical publication before releasing the lifetime lock',async t=>{
  const {store,backend,root}=await opened(t);const claim=await readyToPublish(store);
  let release;const gate=new Promise(resolve=>{release=resolve;});
  let entered;const active=new Promise(resolve=>{entered=resolve;});
  let operation;
  store.attachRunner({wake(){},async stop(){await operation;}});
  operation=store.publish(claim,async()=>{entered();await gate;await writeFile(join(root,'actual-effect.md'),'one actual effect');
    assert.equal((await stat(join(root,'actual-effect.md'))).isFile(),true);return {artifact,elapsedMs:4,state:'done',reason:null};});
  await active;const closing=backend.close();const other=owners(root);let loaded=false;
  const next=openCompanionTaskStore({...other,fs}).then(value=>{loaded=true;return value;});
  await delay(40);assert.equal(loaded,false);assert.equal(store.stopping,true);
  release();await operation;await closing;const second=await next;
  assert.equal(second.snapshot('t-1').artifacts.length,1);assert.equal(await readFile(join(root,'actual-effect.md'),'utf8'),'one actual effect');
  await second.close();await other.backend.close();
});
test('unsupported backend route fails before loading an unprotected task domain',async()=>{
  const registry=new BackendRegistry();let opened=0;registry.register('other',{kv:{open(){opened++;}}});
  const facility=new DomainFacility({storage:{backend:registry}},{backend:'other'});
  await assert.rejects(openCompanionTaskStore({facility,fs}),/no companion task lifetime lock/);assert.equal(opened,0);
});
test('malformed stored task is not skipped or silently replaced on open',async t=>{
  const {store,root}=await opened(t);await store.create(create(store));const host=store.hostStoreId;await store.close();
  const file=join(root,'companion_tasks.json'),doc=JSON.parse(await readFile(file,'utf8'));
  doc.tables.tasks['t-1'].state='not-a-state';await writeFile(file,JSON.stringify(doc));const other=owners(root);
  await assert.rejects(openCompanionTaskStore({...other,fs}),/does not match its schema/);
  assert.equal(JSON.parse(await readFile(file,'utf8')).global.hostStoreId,host);await other.backend.close();
});

test('a consumed publication claim never calls the physical job twice, including restart',async t=>{
  const {store,root}=await opened(t);const claim=await readyToPublish(store);let calls=0;
  await assert.rejects(store.publish(claim,async()=>{calls++;throw new Error('after physical link, receipt unavailable');}),/after physical/);
  await assert.rejects(store.publish(claim,async()=>{calls++;return {artifact,elapsedMs:1};}),/not runnable/);
  assert.equal(calls,1);assert.equal(store.read('t-1').notes['1'].publicationAttempted,true);
  await store.close();const next=owners(root),reopened=await openCompanionTaskStore({...next,fs});
  await assert.rejects(reopened.publish(claim,async()=>{calls++;return {artifact,elapsedMs:1};}),/not runnable/);
  assert.equal(calls,1);const result=await reopened.recordArtifact(claim,{artifact,elapsedMs:null,state:'done',reason:null});
  assert.equal(result.artifacts.length,1);await reopened.close();await next.backend.close();
});

test('publication rechecks absolute deadline after the real possible-send commit',async t=>{
  const {store,backend}=await opened(t);let clock=100;store.now=()=>clock;
  const body={...create(store),deadlineAtMs:200};await store.create(body);
  const model=await store.claimStep('t-1',1,'model',{reserveMs:20});
  await store.saveCandidate(model,{content:'候选',mediaType:'text/markdown',sourceCount:1,usage:null});await store.finishStep(model,finish);
  const claim=await store.claimStep('t-1',1,'writePage',{reserveMs:20});
  await store.savePublishIntent(claim,{directory,outputName:'今日待办.md'});
  const unit=backend.open.get('companion_tasks'),put=unit.putRecord.bind(unit);
  unit.putRecord=async(...args)=>{await put(...args);if(args[2].notes['1'].publicationAttempted) clock=201;};
  let calls=0;await assert.rejects(store.publish(claim,async()=>{calls++;return {artifact,elapsedMs:1};}),/not runnable/);
  assert.equal(calls,0);assert.equal(store.read('t-1').notes['1'].publicationAttempted,true);
});

test('accepted opaque operation names do not collide with Object prototype keys',async t=>{
  const {store}=await opened(t);await store.create(create(store));
  const changed=await store.amend('t-1',amend(store,1,'constructor'));assert.equal(changed.taskRev,2);
  const stopped=await store.cancel('t-1',cancel(store,2,'toString'));assert.equal(stopped.taskRev,3);assert.equal(stopped.state,'cancelled');
  assert.deepEqual(await store.cancel('t-1',cancel(store,2,'toString')),stopped);
});

test('known waiting before model stream can retry with a new attempt and cumulative time',async t=>{
 const {store}=await opened(t);await store.create(create(store));
 const first=await store.claimStep('t-1',1,'model',{reserveMs:100});
 await store.finishStep(first,{state:'waiting',reason:'model_channel_unavailable',result:{preflightDispatched:false,streamEntered:false},elapsedMs:4});
 await assert.rejects(store.claimStep('t-1',1,'model',{reserveMs:100}),/original step/);
 const second=await store.claimStep('t-1',1,'model',{reserveMs:100,retryKnownSafe:true});
 assert.notEqual(second.attemptId,first.attemptId);assert.equal(store.snapshot('t-1').steps.length,2);
 assert.equal(store.snapshot('t-1').budget.spentMs,4);assert.equal(store.snapshot('t-1').budget.heldMs,100);
});
test('known preflight model-finish false allows waiting retry but any physical observation defeats it',async t=>{
 for(const observation of [null,{type:'handoff'},{type:'dispatch'},{type:'http',status:200},{type:'usage',raw:{}},{type:'runtime-usage',usage:{}}]){
  const {store}=await opened(t);await store.create(create(store));const first=await store.claimStep('t-1',1,'model',{reserveMs:100});
  if(observation)await store.observeStep(first,observation);
  await store.observeStep(first,{type:'model-finish',dispatched:false,usage:null});
  await store.finishStep(first,{state:'waiting',reason:'configuration',result:{preflightDispatched:false},elapsedMs:4});
  const next=store.claimStep('t-1',1,'model',{reserveMs:100,retryKnownSafe:true});
  if(observation)await assert.rejects(next,/original step/);else assert.notEqual((await next).attemptId,first.attemptId);
 }
});
test('unknown dispatch and saved candidate never qualify as a known preflight retry',async t=>{
 for(const kind of ['unknown','candidate']){
  const {store}=await opened(t);await store.create(create(store));const first=await store.claimStep('t-1',1,'model',{reserveMs:100});
  if(kind==='candidate')await store.saveCandidate(first,{content:'原候选',mediaType:'text/markdown',sourceCount:1,usage:null});
  await store.observeStep(first,{type:'model-finish',dispatched:kind==='unknown'?null:false,usage:null});
  await store.finishStep(first,{state:'waiting',reason:'configuration',result:{preflightDispatched:false,streamEntered:false},elapsedMs:4});
  await assert.rejects(store.claimStep('t-1',1,'model',{reserveMs:100,retryKnownSafe:true}),/original step/);
 }
});
test('read retries keep immutable selection; saved input and writes without proof cannot retry',async t=>{
 const {store}=await opened(t);await store.create(create(store));
 const a=await store.claimStep('t-1',1,'selectInputs',{reserveMs:100});await store.finishStep(a,{state:'waiting',reason:'permission',result:null,elapsedMs:3});
 const b=await store.claimStep('t-1',1,'selectInputs',{reserveMs:100,retryKnownSafe:true});
 const selected={directory,entries:[{name:'first.md',version:'original'}],scope:{}};
 await store.saveSelection(b,selected);await store.finishStep(b,finish);
 const read=await store.claimStep('t-1',1,'readInputs',{reserveMs:100});await store.finishStep(read,{state:'waiting',reason:'permission',result:null,elapsedMs:3});
 const reread=await store.claimStep('t-1',1,'readInputs',{reserveMs:100,retryKnownSafe:true});assert.deepEqual(store.read('t-1').notes['1'].selection,selected);
 await store.saveInputs(reread,{...selected,entries:[{...selected.entries[0],text:'完整原文'}]});await store.finishStep(reread,{state:'waiting',reason:'later',result:null,elapsedMs:3});
 await assert.rejects(store.claimStep('t-1',1,'readInputs',{reserveMs:100,retryKnownSafe:true}),/original step/);
 const write=await store.claimStep('t-1',1,'writePage',{reserveMs:100});await store.finishStep(write,{state:'waiting',reason:'permission',result:null,elapsedMs:3});
 await assert.rejects(store.claimStep('t-1',1,'writePage',{reserveMs:100,retryKnownSafe:true}),/original step/);
});

test('saved intent known not published can first-dispatch a new time claim without replacing stage',async t=>{
 const {store}=await opened(t);const old=await readyToPublish(store),intent=structuredClone(store.read('t-1').notes['1'].publishIntent);
 await assert.rejects(store.recordArtifact(old,{artifact,elapsedMs:null,state:'done',reason:null}),/not bound/);
 await store.finishStep(old,{state:'waiting',reason:'publication_not_started',result:{publicationNotAttempted:true},elapsedMs:null});
 const next=await store.claimStep('t-1',1,'writePage',{reserveMs:100,retryKnownSafe:true});
 assert.notEqual(next.attemptId,old.attemptId);assert.equal(store.snapshot('t-1').budget.heldMs,200);
 assert.deepEqual(store.read('t-1').notes['1'].publishIntent,intent);
 let calls=0;await assert.rejects(store.publish(next,async()=>{calls++;throw new Error('after the one physical attempt');}),/one physical/);
 assert.equal(store.read('t-1').notes['1'].publicationAttemptId,next.attemptId);
 await assert.rejects(store.recordArtifact(old,{artifact,elapsedMs:null,state:'done',reason:null}),/not bound/);
 const recovered=await store.recordArtifact(next,{artifact,elapsedMs:null,state:'done',reason:null});
 assert.equal(recovered.artifacts.length,1);assert.equal(calls,1);assert.equal(recovered.budget.heldMs,200);
});
test('repeated pre-publication crashes keep held time and eventually stop new claims',async t=>{
 const {store}=await opened(t);const old=await readyToPublish(store);let current=old;
 for(let n=0;n<3;n++){
  await store.finishStep(current,{state:'waiting',reason:'publication_not_started',result:{publicationNotAttempted:true},elapsedMs:null});
  current=await store.claimStep('t-1',1,'writePage',{reserveMs:100000,retryKnownSafe:true});
 }
 await store.finishStep(current,{state:'waiting',reason:'publication_not_started',result:{publicationNotAttempted:true},elapsedMs:null});
 await assert.rejects(store.claimStep('t-1',1,'writePage',{reserveMs:1,retryKnownSafe:true}),/budget is exhausted/);
 assert.equal(store.read('t-1').budget.spentMs+store.read('t-1').budget.heldMs,300000);
 assert.equal(store.read('t-1').state,'failed');
});
test('stopPlan terminates known unfinished work but preserves an unresolved possible model effect',async t=>{
 const {store}=await opened(t);await store.create(create(store));
 const failed=await store.stopPlan('t-1',1,'failed','deadline_expired');assert.equal(failed.state,'failed');
 await store.create(create(store,'t-2'));const claim=await store.claimStep('t-2',1,'model',{reserveMs:100});
 const unknown=await store.stopPlan('t-2',1,'failed','deadline_expired');assert.equal(unknown.state,'unknown');
 assert.equal(unknown.budget.heldMs,100);assert.equal(unknown.steps[0].attemptId,claim.attemptId);
});
