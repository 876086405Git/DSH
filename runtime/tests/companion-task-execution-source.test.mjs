// Production task-execution + actual F01 driver/ApprovalService/approveEscalation.
// Factory/Cordis scope, Session persistence and remote answer delivery are explicit
// controlled peers. This is not a full engine or JSONL crash-recovery test.
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {randomUUID} from 'node:crypto';
assert.ok(process.env.COMPANION_TASK_HARNESS,'Exact source harness is required; never skip');
const load=path=>import(pathToFileURL(resolve(process.env.COMPANION_TASK_HARNESS,path)).href);
const {createNotesExecutionOwner}=await load('companion/task-execution.js');
const {openCompanionTaskStore}=await load('companion/task-store.js');
const {FULL_PRESET}=await load('companion/prompt-context.js');
const {JsonStorageBackend}=await load('node_modules/@deepseek-ai/dsh-storage-json/index.js');
const {DomainFacility}=await load('node_modules/@deepseek-ai/dsh-storage-domain/index.js');
const {BackendRegistry}=await load('node_modules/@deepseek-ai/dsh-storage/index.js');
const {ApprovalService,approvalStateDefinition}=await load('node_modules/@deepseek-ai/dsh-user-approval/index.js');
const {ReactLoopAgent}=await load('task-runtime.mjs');
const {NotesTaskError}=await load('companion/notes-content.js');
const {createNotesToTodosRunner}=await load('companion/notes-to-todos.js');
const tick=()=>new Promise(resolve=>setImmediate(resolve));

async function fixture(t,{full=false,approvalPolicy='ask',receipts=false,pause=false,realRunner=false}={}) {
 const root=await mkdtemp(join(tmpdir(),'task-exec-')),fs={sandboxMode:'workspace-write'};
 let backend,store;
 async function openStore(){
  backend=new JsonStorageBackend(root);
  backend.dshGoCompanionStatfs=async()=>({type:0xef53n});const registry=new BackendRegistry();registry.register('json',backend);
  const facility=new DomainFacility({storage:{backend:registry},emit(){},logger:{warn(){},error(){}},fiber:{assertActive(){}}},{backend:'json'});
  store=await openCompanionTaskStore({facility,fs});
 }
 await openStore();
 if(realRunner){
  // Only filesystem contents/policy responses are peers here. The real runner,
  // store.stop, execution owner, fixed turn and ApprovalService own the lifecycle.
  const directory={target:{targetKey:'/chosen',displayPath:'/chosen'},identity:'1:2'};
  Object.assign(fs,{
   async resolve(path){return {targetKey:path,displayPath:path};},async stat(){return null;},
   async checkedTarget(_target,policy){if(policy.mode==='read-only')throw Object.assign(new Error('read-only'),{code:'FS_SANDBOX_DENIED'});},
   async dshGoNotesPublicationSupport(){return {supported:true};},
   async dshGoListNotes(){return {directory,entries:[{name:'one.md',type:'file',version:'original',size:12,modifiedAtMs:Date.parse('2026-11-20T12:00:00Z')}]};},
   async dshGoReadNote(){return {text:'TODO: bring notes',sha256:'controlled-complete-read'};},
   async dshGoStageNotesFile(){assert.fail('no write before this approval regression ends');},
   async dshGoPublishNotesFile(){assert.fail('no publication in this approval regression');},
   async dshGoInspectNotesPublication(){assert.fail('no publication intent exists');},
   async dshGoReadNotesArtifact(){assert.fail('no artifact exists');},
   async dshGoReleaseNotesStage(){assert.fail('no stage exists');},
  });
 }
 await store.folders.put('folder',{folderRef:'folder',directory:{target:{targetKey:'/chosen',displayPath:'/chosen'},identity:'1:2'},createdAtMs:1});
 if(receipts)for(let i=0;i<4;i++)await store.inputs.put(`receipt-${i}`,{sourceRef:`receipt-${i}`,directory:{target:{targetKey:'/chosen',displayPath:'/chosen'},identity:'1:2'},entry:{name:`receipt-${i}.txt`,version:'original',size:4},createdAtMs:1});
 await store.create({v:1,hostStoreId:store.hostStoreId,taskId:'task-1',taskRev:1,kind:receipts?'host.receipts_to_sheet':'host.notes_to_todo',
  origin:{sourceSessionId:full?'full:phone-room':'light:phone-room',messageId:'message-1',itemNo:0},hostSessionId:full?'source-session':null,
  deadlineAtMs:null,afterExit:pause?'pause':'continue',allowQueue:true,args:receipts?{inputs:Array.from({length:4},(_,i)=>({sourceRef:`receipt-${i}`,version:'original'})),outputDirRef:'folder',outputName:'receipts.xlsx',writeMode:'createNew'}:{folderRef:'folder',outputDirRef:'folder',localDate:'2026-11-20',timeZone:'Asia/Shanghai',dateBy:'modified',outputName:'todo.md',writeMode:'createNew'}});
 let foreground=false;
 // The foreground gate is a peer here; actual runner/HTTP ownership is exercised
 // separately in companion-notes-foreground-source.test.mjs.
 if(pause&&!realRunner)store.attachRunner({wake(){},async stop(){},foreground(){assert.fail('no HTTP runner in this approval fixture');},
   foregroundActive:(id,rev)=>foreground&&id==='task-1'&&rev===1});
 const live=new Map(),persisted=new Map(),creates=[],resumes=[],delivered=[];let resolveAnswer,selected={provider:'chosen-provider',model:'chosen-model'},currentPolicy='read-only',flushResult=true;
 const values={fs,llm:{actualSelectedRoute:true},agentDefaultModel:{currentSelection:()=>structuredClone(selected)},
  sandboxPolicy:{resolve:()=>({mode:currentPolicy,workspaceRoot:'/original-root'})},agentPresets:{presetForSession:()=>FULL_PRESET}};
 const ctx={get:key=>values[key]};
 const projection=session=>session.events.reduce((state,event)=>approvalStateDefinition.apply(state,event),approvalStateDefinition.init());
 const sessions={async flush(session){if(flushResult)persisted.set(session.id,{events:structuredClone(session.events),header:session.header});return flushResult;}};
 const agents={get:id=>live.get(id),withInitiator:(_agent,job)=>job()};
 ctx.sessions=sessions;ctx.agents=agents;values.sessions=sessions;values.agents=agents;
 values.sessionPersistence={stat:async id=>persisted.has(id)?{header:persisted.get(id).header}:undefined};
 const approval=new ApprovalService(ctx,{policy:approvalPolicy});approval.approvalProjectionHandle={stateOf:projection};values.approval=approval;
 ctx.waterfall=async(_scope,_name,request)=>{
  const binding=approval.dshGoTaskApproval(request),eventId=randomUUID();
  await binding.observer.remote({approvalId:binding.approvalId,eventId,agentId:request.agent.id});
  const card={eventId,approvalId:binding.approvalId,snapshot:store.snapshot('task-1')};delivered.push(card);
  return new Promise(resolve=>{resolveAnswer=resolve;card.answer=resolve;});
 };
 function session(id,seed=[]){return {id,header:{id,cwd:'/original-root'},events:structuredClone(seed),append(type,data){
  this.events.push({seq:this.events.length,type,data:structuredClone(data)});},snapshotEvents(){return structuredClone(this.events);}};}
 const origin={id:'source-session',session:session('source-session'),model:{current:()=>structuredClone(selected)},loopCtx:ctx};
 if(full){live.set(origin.id,origin);origin.session.append('approval/policy',{policy:approvalPolicy});}
 values.sessionController={resolveAgent:async id=>({agent:live.get(id)})};
 async function factory(options,resume){
  const id=resume?options.resumeSessionId:options.sessionId;
  assert.equal(store.read('task-1').execution.agentId,id,'original ID must be durably reserved before factory');
  const original=persisted.get(id);if(resume)assert.ok(original);
  const current=session(id,original?.events??[]);
  const driver=Object.assign(Object.create(ReactLoopAgent.prototype),{id,session:current,loopCtx:ctx,ctx,
   phase:{kind:'idle',lastTurn:0},activityDone:Promise.resolve(),inbox:{hasPending:false,clear(){},recover(){}},dispatch:{emit(){}}});
  const setup=await options.setup(ctx,driver);setup?.commit();live.set(id,driver);
  (resume?resumes:creates).push({id,meta:options.meta,agentOptions:options.agentOptions});
  return {agent:driver,async dispose(){driver.cancel({kind:'disposed'});await driver.whenIdle();live.delete(id);}};
 }
 agents.create=options=>factory(options,false);agents.resume=options=>factory(options,true);
 let execution=createNotesExecutionOwner(ctx,store),runner;
 function startRunner(){
  runner=createNotesToTodosRunner({ctx,store,execution});
  store.attachRunner({wake:id=>runner.wake(id),foreground:(...args)=>runner.foreground(...args),
   foregroundActive:(...args)=>runner.foregroundActive(...args),
   async stop(){await runner.stop();await execution.close();}});
  for(const id of store.runnable())store.wake(id);
 }
 if(realRunner)startRunner();
 t.after(async()=>{resolveAnswer?.('cancelled');await execution.close();await store.close();await backend.close();await rm(root,{recursive:true,force:true});});
 return {get store(){return store;},ctx,live,persisted,creates,resumes,delivered,origin,get execution(){return execution;},
  answer:value=>resolveAnswer(value),setModel:value=>{selected=value;},setPolicy:value=>{currentPolicy=value;},setFlush:value=>{flushResult=value;},
  setForeground:value=>{foreground=value;},
  async reopen(){await execution.close();execution=createNotesExecutionOwner(ctx,store);return execution;},
  async restartStore(){assert(realRunner);await store.close();await backend.close();await openStore();
   execution=createNotesExecutionOwner(ctx,store);startRunner();await runner.wake('task-1');},
 };
}
test('real factory signature uses durable reserved ID and source policy root, never chosen folder',async t=>{
 const f=await fixture(t);const opened=await f.execution.openExecution(f.store.read('task-1'));
 assert.equal(f.creates.length,1);assert.equal(f.creates[0].meta.cwd,'/original-root');
 assert.equal(f.store.read('task-1').execution.prepared,false);assert.equal(opened.selected.provider,'chosen-provider');
 assert.equal(opened.agent.session.snapshotEvents().find(e=>e.type==='sandbox/mode').data.mode,'read-only');
 assert.notEqual(opened.agent.id,'light:phone-room');assert.equal(f.delivered.length,0);
});
test('same durable agent resumes after owner closes and never mints a replacement',async t=>{
 const f=await fixture(t);const first=await f.execution.openExecution(f.store.read('task-1'));await f.reopen();
 const second=await f.execution.openExecution(f.store.read('task-1'));
 assert.equal(first.agent.id,second.agent.id);assert.equal(f.creates.length,1);assert.equal(f.resumes.length,1);
});
test('prepared-false missing original Session stays unavailable instead of recreating',async t=>{
 const f=await fixture(t);const first=await f.execution.openExecution(f.store.read('task-1'));await f.reopen();f.persisted.delete(first.agent.id);
 await assert.rejects(f.execution.openExecution(f.store.read('task-1')),/cannot be recovered/);assert.equal(f.creates.length,1);
});
test('full model and original policy changes invalidate actual synchronous guard',async t=>{
 const f=await fixture(t,{full:true}),opened=await f.execution.openExecution(f.store.read('task-1'));
 f.setModel({provider:'other-provider',model:'other'});assert.throws(opened.guard,/changed/);
 f.setModel({provider:'chosen-provider',model:'chosen-model'});opened.guard();f.setPolicy('workspace-write');assert.throws(opened.guard,/changed/);
});
test('real F01 task turn and ApprovalService save distinct audit/wire IDs before delivery',async t=>{
 const f=await fixture(t),opened=await f.execution.openExecution(f.store.read('task-1'));
 const grant=opened.approve('writePage',{requestedMode:'workspace-write',justification:'只写已选择目录的新待办页'});
 while(!f.delivered.length)await tick();const card=f.delivered[0];
 assert.notEqual(card.approvalId,card.eventId);assert.equal(card.snapshot.approval.eventId,card.eventId);
 assert.equal(card.snapshot.approval.approvalId,card.approvalId);assert.equal(card.snapshot.approval.callId,null);
 assert.equal(card.snapshot.state,'waiting');assert.equal(card.snapshot.budget.heldMs,0);
 f.answer('allowed-once');const policy=await grant;assert.equal(policy.mode,'workspace-write');
 assert.equal(f.store.read('task-1').notes['1'].approval.outcome,'allowed-once');
 assert.equal(opened.agent.session.snapshotEvents().at(-1).type,'turn/end');
});
test('already decided original approval survives agent restart without another card',async t=>{
 const f=await fixture(t);let opened=await f.execution.openExecution(f.store.read('task-1'));
 const result=opened.approve('writePage',{requestedMode:'workspace-write',justification:'同一新文件'});
 while(!f.delivered.length)await tick();f.answer('allowed-once');await result;await f.reopen();
 opened=await f.execution.openExecution(f.store.read('task-1'));
 const grant=await opened.approve('writePage',{requestedMode:'workspace-write',justification:'同一新文件'});
 assert.equal(grant.mode,'workspace-write');assert.equal(f.delivered.length,1);
});
test('actual never policy still rejects without any remote card',async t=>{
 const f=await fixture(t,{full:true,approvalPolicy:'never'}),opened=await f.execution.openExecution(f.store.read('task-1'));
 await assert.rejects(opened.approve('writePage',{requestedMode:'workspace-write',justification:'有限任务写入'}),/user rejected/);
 assert.equal(f.delivered.length,0);assert.equal(f.store.read('task-1').notes['1'].approval.outcome,'rejected');
});
test('real turn flush must acknowledge durability before asking or granting',async t=>{
 const f=await fixture(t);const opened=await f.execution.openExecution(f.store.read('task-1'));f.setFlush(false);
 await assert.rejects(opened.approve('writePage',{requestedMode:'workspace-write',justification:'有限任务写入'}),/durab|persist|checkpoint/i);
 assert.equal(f.delivered.length,0);
});

test('a cached task agent takes stricter original policy and cannot reuse its old grant',async t=>{
 const f=await fixture(t,{full:true});const first=await f.execution.openExecution(f.store.read('task-1'));
 const grant=first.approve('writePage',{requestedMode:'workspace-write',justification:'同一有限任务'});
 while(!f.delivered.length)await tick();f.answer('allowed-once');await grant;
 f.origin.session.append('approval/policy',{policy:'never'});
 const next=await f.execution.openExecution(f.store.read('task-1'));
 await assert.rejects(next.approve('writePage',{requestedMode:'workspace-write',justification:'原屋已禁止批准'}),/user rejected/);
 assert.equal(f.delivered.length,1);assert.equal(f.creates.length,1);
});

for(const full of [false,true])test('J SOURCE_APPROVAL zero configured model still owns original real fixed turn and actual approval: '+(full?'full':'light'),async t=>{
 const f=await fixture(t,{full,receipts:true});f.setModel(null);
 const original=f.store.read('task-1');const opened=await f.execution.openExecution(original,undefined,{requireModel:false});
 assert.equal(opened.selected,null);assert.deepEqual(f.creates[0].agentOptions,{});
 f.setModel({provider:'now-configured',model:'other-model'});assert.doesNotThrow(opened.guard,'zero-model J is not bound to an unused model selection');
 assert.equal(f.store.read('task-1').execution.provider,undefined);
 const result=opened.approve('writeSheet',{requestedMode:'workspace-write',justification:'只写本人选定的四份原票到同一新文件'});
 while(!f.delivered.length)await tick();const card=f.delivered[0];
 assert.equal(card.snapshot.approval.stepKey,'writeSheet');assert.equal(card.snapshot.approval.eventId,card.eventId);
 assert.equal(card.snapshot.budget.heldMs,0);f.answer('allowed-once');assert.equal((await result).mode,'workspace-write');
 assert.equal(f.store.read('task-1').notes['1'].approval.stepKey,'writeSheet');
 const events=opened.agent.session.snapshotEvents();assert.equal(events.at(-1).type,'turn/end');
 assert(!events.some(event=>/message|model|llm|inbox/.test(event.type)));
 await f.reopen();const restored=await f.execution.openExecution(f.store.read('task-1'),undefined,{requireModel:false});
 assert.equal(restored.agent.id,opened.agent.id);assert.deepEqual(f.resumes[0].agentOptions,{});
 assert.equal((await restored.approve('writeSheet',{requestedMode:'workspace-write',justification:'同一四原件新表'})).mode,'workspace-write');
 assert.equal(f.delivered.length,1);
});
test('J SOURCE_APPROVAL optional zero-model path does not relax the original F configured-model requirement',async t=>{
 const f=await fixture(t);f.setModel(null);
 await assert.rejects(f.execution.openExecution(f.store.read('task-1')),/not configured/);
 await assert.rejects(f.execution.openExecution(f.store.read('task-1'),undefined,{requireModel:false}),/not configured/);
 assert.equal(f.creates.length,0);assert.equal(f.store.read('task-1').execution,null);
});

test('F SOURCE_APPROVAL actual cancelled decision may reask only after proven foreground withdrawal and a new explicit opportunity',async t=>{
 const f=await fixture(t,{pause:true});
 await assert.rejects(f.execution.openExecution(f.store.read('task-1')),/changed/);assert.equal(f.creates.length,0);
 f.setForeground(true);const first=new AbortController();
 let owner=await f.execution.openExecution(f.store.read('task-1'),first.signal);
 const rejected=assert.rejects(owner.approve('writePage',{requestedMode:'workspace-write',justification:'原笔记任务新文件'}));
 while(f.delivered.length<1)await tick();const old=f.delivered[0];
 f.setForeground(false);first.abort(new NotesTaskError('foreground_withdrawn'));await rejected;
 const saved=f.store.read('task-1').notes['1'].approval;
 assert.equal(saved.outcome,'cancelled');assert.equal(saved.foregroundInterrupted,true);
 assert.equal(f.store.snapshot('task-1').approval,null);assert.equal(f.store.snapshot('task-1').cancelRequested,false);
 await assert.rejects(f.execution.openExecution(f.store.read('task-1')),/changed/);
 f.setForeground(true);owner=await f.execution.openExecution(f.store.read('task-1'),new AbortController().signal);
 let settled=false;const next=owner.approve('writePage',{requestedMode:'workspace-write',justification:'同一目录同一新文件'})
   .then(value=>{settled=true;return value;});
 while(f.delivered.length<2)await tick();const fresh=f.delivered[1];
 assert.notEqual(fresh.eventId,old.eventId);assert.notEqual(fresh.approvalId,old.approvalId);
 assert.equal(fresh.snapshot.approval.agentId,old.snapshot.approval.agentId);
 old.answer('allowed-once');await tick();assert.equal(settled,false,'late answer to cancelled original card is not the new decision');
 fresh.answer('allowed-once');assert.equal((await next).mode,'workspace-write');
 assert.equal(f.creates.length,1);assert.equal(f.store.read('task-1').notes['1'].approval.foregroundInterrupted,undefined);
 assert.equal(owner.agent.session.snapshotEvents().filter(e=>e.type==='approval/decided').length,2);
});

for(const outcome of ['rejected','cancelled'])test(outcome==='rejected'
 ? 'F SOURCE_APPROVAL an actual explicit rejection is not converted into another card by later foreground opportunity'
 : 'F SOURCE_APPROVAL a cancelled decision without a proven scope interruption is not converted into another card',async t=>{
 const f=await fixture(t,{pause:true});f.setForeground(true);const controller=new AbortController();
 let owner=await f.execution.openExecution(f.store.read('task-1'),controller.signal);
 const rejected=assert.rejects(owner.approve('writePage',{requestedMode:'workspace-write',justification:'原新文件'}),/user rejected|was cancelled/);
 while(!f.delivered.length)await tick();f.answer(outcome);await rejected;
 assert.equal(f.store.read('task-1').notes['1'].approval.foregroundInterrupted,undefined);
 f.setForeground(false);controller.abort(new NotesTaskError('foreground_withdrawn'));f.setForeground(true);
 owner=await f.execution.openExecution(f.store.read('task-1'),new AbortController().signal);
 await assert.rejects(owner.approve('writePage',{requestedMode:'workspace-write',justification:'原新文件'}),/did not authorize/);
 assert.equal(f.delivered.length,1);
});

for(const boundary of ['decision append','decision flush'])for(const reason of ['foreground_withdrawn','task_owner_stopping'])
test(`F SOURCE_APPROVAL independent cancellation before its ${boundary} cannot inherit later ${reason}`,async t=>{
 const f=await fixture(t,{pause:true});f.setForeground(true);const controller=new AbortController();
 let owner=await f.execution.openExecution(f.store.read('task-1'),controller.signal);
 const rejected=assert.rejects(owner.approve('writePage',{requestedMode:'workspace-write',justification:'原新文件'}),/was cancelled/);
 while(!f.delivered.length)await tick();const old=f.delivered[0];
 let abortedAtDecision,decisionVisible,enter,release;
 const entered=new Promise(resolve=>{enter=resolve;}),held=new Promise(resolve=>{release=resolve;});
 const withdraw=()=>{f.setForeground(false);controller.abort(new NotesTaskError(reason));};
 const observe=session=>{
  const decision=session.snapshotEvents().find(event=>event.type==='approval/decided'&&event.data.id===old.approvalId);
  if(decision?.data.outcome!=='cancelled'||decisionVisible!==undefined)return false;
  decisionVisible=true;abortedAtDecision=controller.signal.aborted;return true;
 };
 if(boundary==='decision append'){
  const session=owner.agent.session,append=session.append.bind(session);
  session.append=(type,data)=>{append(type,data);if(observe(session))withdraw();};
 }else{
  const flush=f.ctx.sessions.flush.bind(f.ctx.sessions);
  f.ctx.sessions.flush=async session=>{if(observe(session)){enter();await held;}return flush(session);};
 }
 old.answer('cancelled');
 if(boundary==='decision flush'){
  await entered;withdraw();release();
 }
 await rejected;
 assert.equal(decisionVisible,true);assert.equal(abortedAtDecision,false,'the independent decision existed before any signal cancellation');
 const saved=f.store.read('task-1').notes['1'].approval;
 assert.equal(saved.outcome,'cancelled');assert.equal(saved.foregroundInterrupted,undefined);
 assert.equal(f.store.snapshot('task-1').cancelRequested,false);
 f.setForeground(true);owner=await f.execution.openExecution(f.store.read('task-1'),new AbortController().signal);
 await assert.rejects(owner.approve('writePage',{requestedMode:'workspace-write',justification:'同一原任务'}),/did not authorize/);
 assert.equal(f.delivered.length,1,'a later foreground opportunity cannot replace the independently cancelled card');
 assert.equal(f.creates.length,1);
});

test('F SOURCE_APPROVAL actual store stop drains the pending scope and only a new explicit scope can reask after reopening',async t=>{
 const f=await fixture(t,{pause:true,realRunner:true});
 const card=async count=>{const deadline=Date.now()+5000;while(f.delivered.length<count){
  assert(Date.now()<deadline,'the expected actual approval card was not delivered');await tick();}return f.delivered[count-1];};
 const initial=f.store.snapshot('task-1');
 const body={v:1,hostStoreId:initial.hostStoreId,hostExecutionId:initial.hostExecutionId,
  taskRev:1,sourceSessionId:initial.origin.sourceSessionId};
 const first=f.store.foreground('task-1',body,new AbortController().signal);
 const old=await card(1);
 assert.equal(old.snapshot.approval.stepKey,'writePage');
 assert.deepEqual(f.store.snapshot('task-1').steps.map(value=>[value.stepKey,value.state]),
  [['selectInputs','done'],['readInputs','done']]);
 await f.store.stop();await first;
 const stopped=f.store.read('task-1');
 assert.equal(stopped.notes['1'].approval.outcome,'cancelled');
 assert.equal(stopped.notes['1'].approval.foregroundInterrupted,true);
 assert.equal(stopped.cancelRequested,false);assert.equal(f.live.size,0);
 assert.equal(f.persisted.get(stopped.execution.agentId).events.at(-1).type,'turn/end');
 await f.restartStore();
 const restored=f.store.snapshot('task-1');
 assert.equal(restored.hostStoreId,initial.hostStoreId);assert.equal(restored.hostExecutionId,initial.hostExecutionId);
 assert.equal(restored.taskRev,1);assert.equal(restored.state,'waiting');
 assert.equal(f.delivered.length,1,'reopen and wake cannot create a foreground opportunity');
 const next=f.store.foreground('task-1',body,new AbortController().signal);
 const fresh=await card(2);
 assert.notEqual(fresh.approvalId,old.approvalId);assert.notEqual(fresh.eventId,old.eventId);
 assert.equal(fresh.snapshot.approval.agentId,old.snapshot.approval.agentId);
 old.answer('allowed-once');await tick();
 assert.equal(f.store.snapshot('task-1').approval.eventId,fresh.eventId,'the old card cannot decide the new request');
 fresh.answer('rejected');await next;
 assert.equal(f.store.read('task-1').notes['1'].approval.outcome,'rejected');
 assert.equal(f.store.read('task-1').notes['1'].approval.foregroundInterrupted,undefined);
 assert.equal(f.creates.length,1);assert.equal(f.resumes.length,1);
 assert.equal(f.store.snapshot('task-1').steps.length,2,'neither a model nor a write started');
});
