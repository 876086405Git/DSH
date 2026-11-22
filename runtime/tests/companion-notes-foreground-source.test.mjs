// Actual F runner, Domain/JSON and filesystem. Model and fixed agent remain explicit peers.
import assert from 'node:assert/strict';
import test from 'node:test';
import {createServer, request as httpRequest} from 'node:http';
import {readFile,writeFile,stat,link} from 'node:fs/promises';
import {join} from 'node:path';
import {fixture, openFixture, until, load} from './fixtures/companion-notes-runner-fixture.mjs';

const snapshot = f => f.store.snapshot(f.body.taskId);
const body = f => ({v:1, hostStoreId:f.store.hostStoreId, taskRev:1,
  hostExecutionId:snapshot(f).hostExecutionId, sourceSessionId:f.body.origin.sourceSessionId});
const deferred = () => {let resolve;const promise=new Promise(done=>{resolve=done;});return {promise,resolve};};
async function paused(t, options) {
  const f=await fixture(t,options);f.body.afterExit='pause';const runner=f.start();
  await f.store.create(f.body);await runner.wake(f.body.taskId);return {...f,runner};
}

test('F foreground actual pause executes only during the explicit original request and produces one verified artifact',async t=>{
  const f=await paused(t);assert.equal(f.counters.modelCalls,0);assert.equal(f.counters.lists,0);
  const seq=snapshot(f).runnerReceiptSeq, frames=[];
  const unwatch=f.store.observe(f.body.taskId,value=>frames.push(value));
  await f.store.foreground(f.body.taskId,body(f),new AbortController().signal);unwatch();
  assert.equal(snapshot(f).state,'done');assert.equal(snapshot(f).artifacts.length,1);
  assert.equal(f.counters.modelCalls,1);assert.equal(f.counters.links,1);
  assert.match(await readFile(join(f.root,'notes',f.body.args.outputName),'utf8'),/周五配镜/);
  assert(frames.every(value=>value.taskId===f.body.taskId&&value.runnerReceiptSeq>seq));
  assert(frames.some(value=>value.steps.some(step=>step.state==='running')));
  assert.equal(f.runner.foregroundActive(f.body.taskId,1),false);
  await assert.rejects(async()=>f.store.foreground(f.body.taskId,body(f),new AbortController().signal),/not current/);
  await f.store.create(f.body);await f.runner.wake(f.body.taskId);
  assert.equal(f.counters.modelCalls,1);assert.equal(f.counters.links,1);
});

test('F pause create replay, ordinary snapshot, runner wake and actual reopen grant no execution opportunity',async t=>{
  const f=await paused(t);await f.store.create(f.body);snapshot(f);await f.runner.wake(f.body.taskId);
  assert.equal(f.counters.lists,0);assert.equal(f.counters.modelCalls,0);const originalId=snapshot(f).hostExecutionId;await f.close();
  const next=await openFixture(f.root);t.after(()=>next.close());const runner=next.start();
  await runner.wake(f.body.taskId);assert.equal(next.counters.lists,0);assert.equal(next.counters.modelCalls,0);
  assert.equal(next.store.snapshot(f.body.taskId).hostExecutionId,originalId);
});

test('F foreground rejects wrong room, execution, revision, store and extra keys before touching files',async t=>{
  const f=await paused(t),original=body(f);
  for(const bad of [{...original,sourceSessionId:'light:other'}, {...original,hostExecutionId:'other'},
    {...original,taskRev:2},{...original,hostStoreId:'other'},{...original,afterExit:'continue'}])
    await assert.rejects(async()=>f.store.foreground(f.body.taskId,bad,new AbortController().signal));
  const cancelled=new AbortController();cancelled.abort();
  await assert.rejects(async()=>f.store.foreground(f.body.taskId,original,cancelled.signal));
  assert.equal(f.counters.lists,0);assert.equal(f.counters.modelCalls,0);
});

test('F foreground withdrawal during a real read drains only this original run and explicit resume uses the fixed inputs',async t=>{
  const f=await paused(t),entered=deferred(),release=deferred(),read=f.fs.dshGoReadNote.bind(f.fs);
  f.fs.dshGoReadNote=async(...args)=>{entered.resolve();await release.promise;return read(...args);};
  const first=new AbortController(),done=f.store.foreground(f.body.taskId,body(f),first.signal);
  await entered.promise;
  await assert.rejects(async()=>f.store.foreground(f.body.taskId,body(f),new AbortController().signal),/still draining/);
  first.abort();assert.equal(f.runner.foregroundActive(f.body.taskId,1),false);
  await assert.rejects(async()=>f.store.foreground(f.body.taskId,body(f),new AbortController().signal),/still draining/);
  release.resolve();await done;
  assert.equal(f.counters.modelCalls,0);assert.equal(f.counters.links,0);
  const before=snapshot(f);assert.equal(before.cancelRequested,false);assert.equal(before.taskRev,1);
  assert.equal(before.budget.heldMs,0);assert.equal(before.steps.at(-1).state,'waiting');
  await f.store.foreground(f.body.taskId,body(f),new AbortController().signal);
  assert.equal(snapshot(f).state,'done');assert.equal(f.counters.lists,1);assert.equal(f.counters.modelCalls,1);
  assert(snapshot(f).budget.spentMs>=before.budget.spentMs);
});

test('F foreground model already dispatched remains unknown after withdrawal and cannot be retried by another scope',async t=>{
  const entered=deferred();
  const f=await paused(t,{async *stream({signal}){entered.resolve();await new Promise(resolve=>signal.addEventListener('abort',resolve,{once:true}));signal.throwIfAborted();}});
  const control=new AbortController(),done=f.store.foreground(f.body.taskId,body(f),control.signal);
  await entered.promise;control.abort();await done;
  assert.equal(snapshot(f).state,'unknown');assert.equal(f.counters.modelCalls,1);assert.equal(f.counters.links,0);
  assert(snapshot(f).steps.find(value=>value.stepKey==='model').result.observations.some(value=>value.type==='dispatch'));
  await f.store.foreground(f.body.taskId,body(f),new AbortController().signal);
  assert.equal(snapshot(f).state,'unknown');assert.equal(f.counters.modelCalls,1);assert.equal(f.counters.links,0);
});

test('F queued foreground withdrawal never stops the unrelated allowed-continue task',async t=>{
  const entered=deferred(),release=deferred();let first=true;
  const f=await fixture(t,{beforeFinish:async()=>{if(first){first=false;entered.resolve();await release.promise;}}});
  const runner=f.start();await f.store.create(f.body);await entered.promise;
  const second={...f.body,taskId:'paused-second',afterExit:'pause',origin:{...f.body.origin,messageId:'second'},
    args:{...f.body.args,outputName:'second.md'}};
  await f.store.create(second);const before=f.store.snapshot(second.taskId),control=new AbortController();
  const done=f.store.foreground(second.taskId,{...body(f),hostExecutionId:before.hostExecutionId},control.signal);
  control.abort();await done;release.resolve();await runner.wake(f.body.taskId);
  assert.equal(snapshot(f).state,'done');assert.equal(f.store.snapshot(second.taskId).steps.length,0);
  assert.equal(f.counters.modelCalls,1);assert.equal(f.counters.links,1);
});

async function httpFixture(t,f) {
  const {createCompanionRoutes}=await load('companion/routes.js');
  const ctx={get:key=>key==='dshGoCompanionTasks'?f.store:key==='connection'?{admit:req=>
    req.headers.authorization==='owner'?{peer:{principal:{kind:'owner'}}}:{rejection:403}}:undefined};
  const send=(res,status,value)=>{res.writeHead(status,{'content-type':'application/json'});res.end(JSON.stringify(value));};
  const routes=createCompanionRoutes({ctx,send});
  const server=createServer((req,res)=>routes.handle(req,res,new URL(req.url,'http://local').pathname).catch(error=>res.destroy(error)));
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  t.after(async()=>{routes.dispose();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));});
  return {server,url:`http://127.0.0.1:${server.address().port}/dsh-go/v1/companion/tasks`};
}

test('F actual HTTP held response outlives normal request-body close and streams durable snapshots through completion',async t=>{
  const f=await paused(t),http=await httpFixture(t,f);
  const capability=await fetch(http.url+'/capabilities',{headers:{authorization:'owner'}}).then(value=>value.json());
  assert.deepEqual(capability.afterExit,['continue']);assert.equal(capability.pauseBehavior,'waiting');
  const response=await fetch(http.url+'/'+f.body.taskId+'/foreground',{method:'POST',headers:{authorization:'owner','content-type':'application/json'},body:JSON.stringify(body(f))});
  assert.equal(response.status,200);assert.equal(capability.notesForeground,true);
  assert.match(response.headers.get('content-type'),/application\/x-ndjson/);
  const frames=(await response.text()).trim().split('\n').map(line=>JSON.parse(line));
  assert.equal(frames.at(-1).state,'done');assert(frames.length>2);
  assert(frames.every((value,index)=>!index||value.runnerReceiptSeq>=frames[index-1].runnerReceiptSeq));
  assert.equal(f.counters.modelCalls,1);assert.equal(f.counters.links,1);
  if(process.env.F_NOTES_FOREGROUND_WIRE_FIXTURE)await writeFile(process.env.F_NOTES_FOREGROUND_WIRE_FIXTURE,
    JSON.stringify({scope:'ACTUAL_HOST_FOREGROUND_HTTP_WITH_CONTROLLED_MODEL_AND_FIXED_AGENT',
      capability,create:f.body,foreground:body(f),snapshots:frames},null,2)+'\n');
});

test('F actual HTTP response close withdraws before the next model and preserves the original task rather than cancelling it',async t=>{
  const f=await paused(t),entered=deferred(),release=deferred(),read=f.fs.dshGoReadNote.bind(f.fs);
  f.fs.dshGoReadNote=async(...args)=>{entered.resolve();await release.promise;return read(...args);};
  const http=await httpFixture(t,f),received=deferred();
  const request=httpRequest(http.url+'/'+f.body.taskId+'/foreground',{method:'POST',headers:{authorization:'owner','content-type':'application/json'}},res=>{
    res.once('data',()=>received.resolve(res));res.on('error',()=>{});
  });request.on('error',()=>{});request.end(JSON.stringify(body(f)));
  const response=await received.promise;await entered.promise;response.destroy();request.destroy();
  await until(()=>!f.runner.foregroundActive(f.body.taskId,1),'Host observed response close');
  release.resolve();await until(()=>snapshot(f).steps.at(-1)?.finishedAtMs!==null,'read drain');
  assert.equal(f.counters.modelCalls,0);assert.equal(f.counters.links,0);assert.equal(snapshot(f).cancelRequested,false);
  assert.equal(snapshot(f).taskRev,1);
});

test('F withdrawal after actual staging retains that object and resumes without regenerating the model or stage',async t=>{
  const f=await paused(t),entered=deferred(),release=deferred(),stage=f.fs.dshGoStageNotesFile.bind(f.fs);let stages=0;
  f.fs.dshGoStageNotesFile=async(...args)=>{const result=await stage(...args);stages++;entered.resolve();await release.promise;return result;};
  const controller=new AbortController(),done=f.store.foreground(f.body.taskId,body(f),controller.signal);
  await entered.promise;controller.abort();release.resolve();await done;
  const original=f.store.read(f.body.taskId).notes['1'].publishIntent;
  assert(original);assert.equal(f.counters.modelCalls,1);assert.equal(f.counters.links,0);
  assert.equal(snapshot(f).steps.at(-1).result.completion.publicationNotAttempted,true);
  await f.store.foreground(f.body.taskId,body(f),new AbortController().signal);
  assert.equal(snapshot(f).state,'done');assert.equal(stages,1);assert.equal(f.counters.modelCalls,1);assert.equal(f.counters.links,1);
  assert.deepEqual(f.store.read(f.body.taskId).notes['1'].publishIntent,original);
});

test('F withdrawal inside marker commit prevents link and retains consumed unknown publication instead of retrying',async t=>{
  const f=await paused(t),entered=deferred(),release=deferred(),put=f.store.table.put.bind(f.store.table);let first=true;
  f.store.table.put=async(id,value)=>{
    if(first&&value.notes['1']?.publicationAttempted){first=false;entered.resolve();await release.promise;}
    return put(id,value);
  };
  const controller=new AbortController(),done=f.store.foreground(f.body.taskId,body(f),controller.signal);
  await entered.promise;controller.abort();release.resolve();await done;
  assert.equal(f.counters.links,0);assert.equal(f.counters.modelCalls,1);assert.equal(snapshot(f).state,'unknown');
  assert.equal(f.store.read(f.body.taskId).notes['1'].publicationAttempted,true);
  await assert.rejects(stat(join(f.root,'notes',f.body.args.outputName)),{code:'ENOENT'});
  const before=snapshot(f).budget.heldMs;assert(before>0);
  await f.store.foreground(f.body.taskId,body(f),new AbortController().signal);
  assert.equal(f.counters.links,0);assert.equal(f.counters.modelCalls,1);assert.equal(snapshot(f).budget.heldMs,before);
});

test('F withdrawal after the actual hardlink records the real original artifact without undo or second publication',async t=>{
  const controller=new AbortController();
  const f=await paused(t,{link:async(from,to)=>{await link(from,to);controller.abort();}});
  await f.store.foreground(f.body.taskId,body(f),controller.signal);
  assert.equal(f.counters.links,1);assert.equal(f.counters.modelCalls,1);
  const result=snapshot(f);assert.equal(result.state,'done');assert.equal(result.artifacts.length,1);
  assert.equal(result.cancelRequested,false);assert.equal(result.taskRev,1);
  const actual=await f.store.artifact(f.body.taskId,result.artifacts[0].artifactId);
  assert.equal(actual.status,'available');assert.match(actual.content,/周五配镜/);
  await assert.rejects(async()=>f.store.foreground(f.body.taskId,body(f),new AbortController().signal),/not current/);
  assert.equal(f.counters.links,1);
});

test('F foreground handoff window during an older unheld pause commit keeps the newly registered request alive',async t=>{
  const f=await fixture(t);f.body.afterExit='pause';const entered=deferred(),release=deferred();
  const put=f.store.table.put.bind(f.store.table);let first=true;
  f.store.table.put=async(id,value)=>{
    if(first&&value.runnerReceiptSeq>1&&value.waitReason==='foreground_required'&&!value.steps.length){
      first=false;entered.resolve();await release.promise;
    }
    return put(id,value);
  };
  f.start();await f.store.create(f.body);await entered.promise;
  const done=f.store.foreground(f.body.taskId,body(f),new AbortController().signal);
  release.resolve();await done;
  assert.equal(snapshot(f).state,'done');assert.equal(f.counters.modelCalls,1);assert.equal(f.counters.links,1);
});

test('F unentered model claim withdrawn during its actual commit remains provably unsent and can resume once',async t=>{
  const f=await paused(t),entered=deferred(),release=deferred(),put=f.store.table.put.bind(f.store.table);let first=true;
  f.store.table.put=async(id,value)=>{
    if(first&&value.steps.some(step=>step.stepKey==='model'&&step.finishedAtMs===null)){
      first=false;entered.resolve();await release.promise;
    }
    return put(id,value);
  };
  const controller=new AbortController(),done=f.store.foreground(f.body.taskId,body(f),controller.signal);
  await entered.promise;controller.abort();release.resolve();await done;
  assert.equal(f.counters.modelCalls,0);assert.equal(f.counters.links,0);
  assert.equal(snapshot(f).steps.at(-1).state,'waiting');
  await f.store.foreground(f.body.taskId,body(f),new AbortController().signal);
  assert.equal(snapshot(f).state,'done');assert.equal(f.counters.modelCalls,1);assert.equal(f.counters.links,1);
  assert.equal(snapshot(f).steps.filter(step=>step.stepKey==='model').length,2);
});

for(const key of ['model','writePage'])test(`F normal owner stop during an unentered ${key} claim survives reopen and needs a fresh explicit scope`,async t=>{
  const f=await paused(t),entered=deferred(),release=deferred(),put=f.store.table.put.bind(f.store.table);let first=true;
  f.store.table.put=async(id,value)=>{
    if(first&&value.steps.some(step=>step.stepKey===key&&step.finishedAtMs===null)){
      first=false;entered.resolve();await release.promise;
    }
    return put(id,value);
  };
  const original=body(f),done=f.store.foreground(f.body.taskId,original,new AbortController().signal);
  await entered.promise;const stopped=f.store.stop();release.resolve();await Promise.all([done,stopped]);
  assert.equal(f.counters.modelCalls,key==='model'?0:1);assert.equal(f.counters.links,0);
  assert.equal(snapshot(f).steps.at(-1).state,'waiting');assert.equal(snapshot(f).cancelRequested,false);
  await f.close();
  const next=await openFixture(f.root);t.after(()=>next.close());const runner=next.start();
  await runner.wake(f.body.taskId);
  assert.equal(next.counters.modelCalls,0);assert.equal(next.counters.links,0,'restart alone grants no foreground opportunity');
  await next.store.foreground(f.body.taskId,original,new AbortController().signal);
  const after=next.store.snapshot(f.body.taskId);
  assert.equal(after.state,'done');assert.equal(after.hostExecutionId,original.hostExecutionId);
  assert.equal(after.taskRev,1);assert.equal(after.artifacts.length,1);
  assert.equal(f.counters.modelCalls+next.counters.modelCalls,1);assert.equal(next.counters.links,1);
  assert.equal(after.steps.filter(step=>step.stepKey===key).length,2);
});
