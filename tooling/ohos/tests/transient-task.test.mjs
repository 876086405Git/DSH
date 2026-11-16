import test, {after} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {timers,osTask,continuous} from './transient-task-fixture.mjs';
const directory=await fs.mkdtemp(path.join(os.tmpdir(),'transient-owner-'));
const source=new URL('../../../app/ohos/entry/src/main/ets/runtime/TransientTaskOwner.ets',import.meta.url);
const text=(await fs.readFile(source,'utf8')).replace(/^import .+;\n/gm,'');
const continuousText=(await fs.readFile(new URL('../../../app/ohos/entry/src/main/ets/runtime/ContinuousTaskOwner.ets',import.meta.url),'utf8')).replace(/^import .+;\n/gm,'');
await fs.writeFile(path.join(directory,'continuous.mts'),`import {backgroundTaskManager,backgroundComputePermission,wantAgent,setTimeout} from '${new URL('./transient-task-fixture.mjs',import.meta.url)}';\n`+continuousText);
await fs.writeFile(path.join(directory,'owner.mts'),`import {ContinuousTaskOwner} from './continuous.mts';\nimport {backgroundTaskManager,setTimeout,clearTimeout} from '${new URL('./transient-task-fixture.mjs',import.meta.url)}';\n`+text);
const {TransientTaskOwner}=await import(pathToFileURL(path.join(directory,'owner.mts')));after(()=>fs.rm(directory,{recursive:true,force:true}));
function setup(t,context){
 Object.assign(continuous,{allowed:true,requests:[],stops:[],startError:null,startDeferred:null,stopError:null});continuous.listeners.clear();
 timers.clear();Object.assign(osTask,{requests:[],cancels:[],failCancel:false,callbackNow:false,duration:30000});
 const s={version:1,engineGeneration:1,ownerGeneration:0,revision:1,grantGeneration:0,nowMs:10000,deadlineMs:0,drainAtMs:0,phase:0,available:1,foreground:0,clockFailed:0};let t0=0,wakes=0;
 const writes=[];const host={lifecycleSnapshot:()=>({...s}),lifecycleUpdate(op,owner,grant,value){writes.push(op);
 if(op==='owner'){s.available=1;s.ownerGeneration++;s.foreground=value;s.revision++;return s.ownerGeneration;}
 if(owner!==s.ownerGeneration)return 0;
 if(op==='foreground'){s.foreground=value;s.phase=4;s.revision++;return 1;}
 if(op==='continuous'){s.phase=value?7:4;s.deadlineMs=s.drainAtMs=0;s.revision++;return 1;}
 if(op==='begin'){t0=s.nowMs;s.phase=1;s.grantGeneration++;s.revision++;return s.grantGeneration;}
 if(op==='activate'){if(s.phase!==1)return 0;s.deadlineMs=t0+value;s.drainAtMs=s.deadlineMs-6000;s.phase=2;s.revision++;return 1;}
 if(op==='drain'){s.phase=3;s.revision++;return 1;}
 if(op==='release'){s.phase=4;s.deadlineMs=s.drainAtMs=0;s.revision++;return 1;}
 if(op==='retire'){s.available=0;s.phase=4;s.revision++;return 1;}throw Error(op);
 }};
 const owner=new TransientTaskOwner(host,true,()=>{wakes++;},context);
 const ack=(busy=true,manualPaused=false)=>({nativeHost:{...s},busy,manualPaused,confirmedPause:s.phase!==2});
 const background=()=>{owner.acknowledge(ack());owner.observe(false);owner.acknowledge(ack());};
 t.after(()=>{osTask.failCancel=false;owner.retire();timers.clear();});
 return {s,host,owner,ack,background,writes,get wakes(){return wakes;}};
}
test('idle, unknown and manual pause consume no transient quota',t=>{for(const mode of ['unknown','idle','paused']){const f=setup(t);if(mode!=='unknown')f.owner.acknowledge(f.ack(mode==='paused',mode==='paused'));f.owner.observe(false);f.owner.acknowledge(f.ack());assert.equal(osTask.requests.length,0);}});
test('fresh actual work requires second current background ACK before requesting once',t=>{const f=setup(t);f.owner.acknowledge(f.ack());f.owner.observe(false);assert.equal(osTask.requests.length,0);f.owner.acknowledge(f.ack());assert.equal(osTask.requests.length,1);assert.equal(f.s.phase,2);const deadline=f.s.deadlineMs;f.owner.observe(false);f.owner.acknowledge(f.ack());assert.equal(osTask.requests.length,1);assert.equal(f.s.deadlineMs,deadline);});
test('busy to idle between observations does not spend quota',t=>{const f=setup(t);f.owner.acknowledge(f.ack());f.owner.observe(false);f.owner.acknowledge(f.ack(false));assert.equal(osTask.requests.length,0);});
test('foreground polling and background ACK tolerate bounded scheduling delay',t=>{
 for(const [foregroundAge,ackDelay] of [[1001,0],[0,1001],[2500,2500],[3000,3000]]){
  const f=setup(t);f.owner.acknowledge(f.ack());f.s.nowMs+=foregroundAge;f.owner.observe(false);
  assert.equal(osTask.requests.length,0,'foreground evidence cannot authorize alone');
  f.s.nowMs+=ackDelay;f.owner.acknowledge(f.ack());assert.equal(osTask.requests.length,1);
  assert.equal(f.s.deadlineMs,f.s.nowMs+30000,'grant starts at OS request, with its unchanged duration');
  const deadline=f.s.deadlineMs;f.owner.acknowledge(f.ack());f.owner.observe(false);
  assert.equal(osTask.requests.length,1);assert.equal(f.s.deadlineMs,deadline,'ACK cannot renew the grant');
 }
});
test('expired foreground evidence and delayed background ACK fail closed',t=>{
 for(const [foregroundAge,ackDelay] of [[3001,0],[0,3001]]){
  const f=setup(t);f.owner.acknowledge(f.ack());f.s.nowMs+=foregroundAge;f.owner.observe(false);
  f.s.nowMs+=ackDelay;f.owner.acknowledge(f.ack());assert.equal(osTask.requests.length,0);
  f.owner.acknowledge(f.ack());assert.equal(osTask.requests.length,0,'later ACK cannot reopen a spent transition');
 }
});
test('delayed evidence still rejects idle, manual pause, wrong identity and failed native clock',t=>{
 for(const invalid of ['idle','paused','engine','owner','revision','unavailable','clockFailed']){
  const f=setup(t);f.owner.acknowledge(f.ack());f.s.nowMs+=1500;f.owner.observe(false);f.s.nowMs+=1500;
  const ack=f.ack(invalid!=='idle',invalid==='paused');
  if(invalid==='engine')ack.nativeHost.engineGeneration++;
  if(invalid==='owner')ack.nativeHost.ownerGeneration++;
  if(invalid==='revision')ack.nativeHost.revision--;
  if(invalid==='unavailable')f.s.available=0;
  if(invalid==='clockFailed')f.s.clockFailed=1;
  f.owner.acknowledge(ack);assert.equal(osTask.requests.length,0,invalid);
 }
});
test('native clock rollback and future foreground timestamp cannot create fresh work',t=>{
 const f=setup(t),future=f.ack();future.nativeHost.nowMs++;f.owner.acknowledge(future);
 f.owner.observe(false);f.owner.acknowledge(f.ack());assert.equal(osTask.requests.length,0);
 const g=setup(t);g.owner.acknowledge(g.ack());g.owner.observe(false);g.s.nowMs--;
 g.owner.acknowledge(g.ack());assert.equal(osTask.requests.length,0);
});
test('old owner/revision ACK cannot activate a new background transition',t=>{const f=setup(t);const old=f.ack();f.owner.acknowledge(old);f.owner.observe(false);f.owner.acknowledge(old);assert.equal(osTask.requests.length,0);});
test('round completion closes native admission before OS cancellation',t=>{const f=setup(t);f.background();f.owner.acknowledge(f.ack(false));assert.equal(f.s.phase,4);assert.equal(osTask.cancels.length,1);assert.equal(f.writes.at(-1),'release');});
test('retirement never requests and late ACK does not reactivate',t=>{const f=setup(t);f.owner.acknowledge(f.ack());f.owner.retire();f.owner.observe(false);f.owner.acknowledge(f.ack());assert.equal(osTask.requests.length,0);assert.equal(f.s.available,0);});
test('synchronous OS callback before request returns cannot activate',t=>{const f=setup(t);osTask.callbackNow=true;f.background();assert.equal(f.s.phase,4);assert.equal(osTask.cancels.length,1);assert.equal(f.writes.includes('activate'),false);});
test('retired permanent cancel failure retains diagnosis but bounds retries and stops timers',t=>{const f=setup(t);f.background();osTask.failCancel=true;f.owner.retire();const wakes=f.wakes;for(let i=0;i<5;i++){const row=timers.entries().next().value;if(!row)break;timers.delete(row[0]);row[1].fn();}assert.equal(osTask.cancels.length,3);assert.equal(timers.size,0);assert.equal(f.wakes,wakes);assert.equal(f.owner.status().get('cleanupPending'),true);assert.equal(f.owner.status().get('error'),'ohos_transient_cancel_failed');assert.equal(f.s.available,0);});

test('native getter failure while handling ACK is consumed and retires the owner',t=>{const f=setup(t);f.background();f.host.lifecycleSnapshot=()=>{throw Error('native unavailable');};assert.doesNotThrow(()=>f.owner.acknowledge(f.ack()));assert.equal(f.s.available,0);assert.equal(osTask.cancels.length,1);});
test('retired cleanup status never borrows a replacement owner deadline',t=>{const f=setup(t);f.background();osTask.failCancel=true;f.owner.retire();f.s.ownerGeneration++;f.s.phase=2;f.s.deadlineMs=999999;const status=f.owner.status();assert.equal(status.get('retired'),true);assert.equal(status.get('deadlineMs'),null);assert.notEqual(status.get('ownerGeneration'),f.s.ownerGeneration);});
test('asynchronous OS callback native failure is consumed and retires before cleanup',t=>{
 const f=setup(t);f.background();const update=f.host.lifecycleUpdate;
 f.host.lifecycleUpdate=(operation,...args)=>{if(operation==='drain')throw Error('native drain failed');return update(operation,...args);};
 assert.doesNotThrow(()=>osTask.requests[0].callback());
 assert.equal(f.s.available,0);assert.equal(osTask.cancels.length,1);
 assert.equal(f.owner.status().get('error'),'ohos_transient_native_failed');
});

const context={applicationInfo:{accessTokenId:1,name:'test.dsh'},abilityInfo:{name:'EntryAbility'}};
test('status says whether the app is on screen, so the UI can tell a return from a lost task',t=>{const f=setup(t);assert.equal(f.owner.status().get('foreground'),true);f.owner.observe(false);assert.equal(f.owner.status().get('foreground'),false);});
test('granted TASK_KEEPING starts continuous task and avoids transient quota',async t=>{
 const f=setup(t,context);f.background();await new Promise(resolve=>setImmediate(resolve));
 assert.equal(continuous.requests.length,1);assert.deepEqual(continuous.requests[0].request.backgroundTaskModes,[9]);
 assert.equal(osTask.requests.length,0);assert.equal(f.s.phase,7);
});

const flush=()=>new Promise(resolve=>setImmediate(resolve));
test('missing ACL silently falls back to existing short request',async t=>{const f=setup(t,context);continuous.allowed=false;f.background();await flush();assert.equal(continuous.requests.length,0);assert.equal(osTask.requests.length,1);assert.equal(f.owner.status().get('error'),null);});
test('OS start rejection silently falls back to short request',async t=>{const f=setup(t,context);continuous.startError=Error('denied');f.background();await flush();assert.equal(osTask.requests.length,1);assert.equal(f.owner.status().get('error'),null);assert.equal(f.s.phase,2);});
test('eligibility and pending OS acceptance never open native admission',async t=>{const f=setup(t,context);continuous.startDeferred=Promise.withResolvers();f.background();await flush();assert.notEqual(f.s.phase,7);assert.equal(osTask.requests.length,0);continuous.startDeferred.resolve({continuousTaskId:73});await flush();assert.equal(f.s.phase,7);});
test('foreground before late OS acceptance cleans returned task without admission',async t=>{const f=setup(t,context);continuous.startDeferred=Promise.withResolvers();f.background();await flush();f.owner.observe(true);continuous.startDeferred.resolve({continuousTaskId:73});await flush();assert.equal(continuous.stops.length,1);assert.equal(f.writes.filter(x=>x==='continuous').length,0);assert.equal(osTask.requests.length,0);});
test('retirement before late OS acceptance cannot activate replacement owner',async t=>{const f=setup(t,context);continuous.startDeferred=Promise.withResolvers();f.background();await flush();f.owner.retire();f.s.ownerGeneration++;continuous.startDeferred.resolve({continuousTaskId:73});await flush();assert.equal(continuous.stops.length,1);assert.equal(f.s.phase,4);assert.equal(osTask.requests.length,0);});
test('manual pause closes continuous permission before asynchronous OS stop',async t=>{const f=setup(t,context);f.background();await flush();f.owner.acknowledge(f.ack(true,true));assert.equal(f.s.phase,4);await flush();assert.equal(continuous.stops.length,1);assert.equal(osTask.requests.length,0);});
test('idle completion stops continuous task and notification ownership',async t=>{const f=setup(t,context);f.background();await flush();f.owner.acknowledge(f.ack(false));assert.equal(f.s.phase,4);await flush();assert.equal(continuous.stops.length,1);assert.equal(continuous.listeners.size,0);});
test('OS cancellation revokes native admission and uses bounded short fallback',async t=>{const f=setup(t,context);f.background();await flush();for(const fn of [...continuous.listeners])if(fn.eventType==='continuousTaskCancel')fn({id:73,reason:0});assert.equal(f.s.phase,2);assert.equal(osTask.requests.length,1);assert.equal(continuous.requests.length,1);});

test('native failure during OS cancellation stays inside the callback and still stops the task',async t=>{
 const f=setup(t,context);f.background();await flush();const update=f.host.lifecycleUpdate;
 f.host.lifecycleUpdate=(op,...rest)=>{if(op==='continuous'||op==='begin')throw Error('native failed');return update(op,...rest);};
 t.after(()=>{f.host.lifecycleUpdate=update;});
 for(const fn of [...continuous.listeners])if(fn.eventType==='continuousTaskSuspend')fn({continuousTaskId:73,suspendState:true,suspendReason:0});
 await flush();assert.equal(continuous.listeners.size,0);assert.deepEqual(continuous.stops.map(row=>row.id),[73]);
 assert.notEqual(f.owner.status().get('error'),null);
});
test('OS suspension revokes native admission, stops its task and never trusts activation',async t=>{const f=setup(t,context);f.background();await flush();for(const fn of [...continuous.listeners])if(fn.eventType==='continuousTaskSuspend')fn({continuousTaskId:73,suspendState:true,suspendReason:0});assert.equal(f.s.phase,2);await flush();assert.equal(continuous.stops.length,1);assert.equal(osTask.requests.length,1);assert.equal(continuous.listeners.size,0);});
test('cancellation before async start result cannot grant native permission',async t=>{const f=setup(t,context);continuous.startDeferred=Promise.withResolvers();f.background();await flush();for(const fn of [...continuous.listeners])if(fn.eventType==='continuousTaskCancel')fn({id:73,reason:0});continuous.startDeferred.resolve({continuousTaskId:73});await flush();assert.equal(f.s.phase,2);assert.equal(osTask.requests.length,1);assert.equal(continuous.stops.length,1);});
test('current native background busy ACK starts permitted continuous work even before a foreground poll',async t=>{const f=setup(t,context);f.owner.observe(false);f.owner.acknowledge(f.ack());await flush();assert.equal(continuous.requests.length,1);assert.equal(f.s.phase,7);});

test('retired pending owner remains observable and missing id never stops a replacement task',async t=>{
 const f=setup(t,context);const old=Promise.withResolvers();continuous.startDeferred=old;f.background();await flush();
 f.owner.retire();assert.equal(f.owner.cleanupPending(),true);
 continuous.startDeferred=null;const newer=new (await import(pathToFileURL(path.join(directory,'owner.mts')))).TransientTaskOwner(f.host,true,()=>{},context);
 const ack=()=>({nativeHost:{...f.s},busy:true,manualPaused:false,confirmedPause:false});
 newer.acknowledge(ack());newer.observe(false);newer.acknowledge(ack());await flush();assert.equal(f.s.phase,7);
 old.resolve({notificationId:91});await flush();assert.equal(f.s.phase,7);assert.equal(continuous.stops.length,0);
 assert.equal(f.owner.cleanupPending(),true);assert.equal(f.owner.status().get('error'),'ohos_continuous_missing_id');newer.retire();
});
test('same owner reentry missing-id late result cannot stop its newer continuous task',async t=>{
 const f=setup(t,context);const old=Promise.withResolvers();continuous.startDeferred=old;f.background();await flush();
 f.owner.observe(true);continuous.startDeferred=null;f.background();await flush();assert.equal(f.s.phase,7);
 old.resolve({notificationId:91});await flush();assert.equal(f.s.phase,7);assert.equal(continuous.stops.length,0);
 assert.equal(f.owner.cleanupPending(),true);assert.equal(f.owner.status().get('error'),'ohos_continuous_missing_id');
});

test('continuous stop failure retains bounded observable cleanup after retirement',async t=>{const f=setup(t,context);f.background();await flush();continuous.stopError=Error('stop failed');f.owner.retire();assert.equal(f.s.available,0);assert.equal(f.owner.cleanupPending(),true);await flush();for(let i=0;i<5;i++){const row=timers.entries().next().value;if(!row)break;timers.delete(row[0]);row[1].fn();await flush();}assert.equal(continuous.stops.length,3);assert.equal(timers.size,0);assert.equal(f.owner.cleanupPending(),true);assert.equal(f.owner.status().get('error'),'ohos_continuous_cancel_failed');continuous.stopError=null;});
