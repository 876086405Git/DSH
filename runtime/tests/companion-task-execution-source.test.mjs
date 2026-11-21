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
const tick=()=>new Promise(resolve=>setImmediate(resolve));

async function fixture(t,{full=false,approvalPolicy='ask'}={}) {
 const root=await mkdtemp(join(tmpdir(),'task-exec-')),backend=new JsonStorageBackend(root);
 backend.dshGoCompanionStatfs=async()=>({type:0xef53n});const registry=new BackendRegistry();registry.register('json',backend);
 const facility=new DomainFacility({storage:{backend:registry},emit(){},logger:{warn(){},error(){}},fiber:{assertActive(){}}},{backend:'json'});
 const fs={sandboxMode:'workspace-write'};const store=await openCompanionTaskStore({facility,fs});
 await store.folders.put('folder',{folderRef:'folder',directory:{target:{targetKey:'/chosen',displayPath:'/chosen'},identity:'1:2'},createdAtMs:1});
 await store.create({v:1,hostStoreId:store.hostStoreId,taskId:'task-1',taskRev:1,kind:'host.notes_to_todo',
  origin:{sourceSessionId:full?'full:phone-room':'light:phone-room',messageId:'message-1',itemNo:0},hostSessionId:full?'source-session':null,
  deadlineAtMs:null,afterExit:'continue',allowQueue:true,args:{folderRef:'folder',outputDirRef:'folder',localDate:'2026-11-20',timeZone:'Asia/Shanghai',dateBy:'modified',outputName:'todo.md',writeMode:'createNew'}});
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
  delivered.push({eventId,approvalId:binding.approvalId,snapshot:store.snapshot('task-1')});
  return new Promise(resolve=>{resolveAnswer=resolve;});
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
 let execution=createNotesExecutionOwner(ctx,store);
 t.after(async()=>{resolveAnswer?.('cancelled');await execution.close();await store.close();await backend.close();await rm(root,{recursive:true,force:true});});
 return {store,ctx,live,persisted,creates,resumes,delivered,origin,get execution(){return execution;},
  answer:value=>resolveAnswer(value),setModel:value=>{selected=value;},setPolicy:value=>{currentPolicy=value;},setFlush:value=>{flushResult=value;},
  async reopen(){await execution.close();execution=createNotesExecutionOwner(ctx,store);return execution;}};
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
