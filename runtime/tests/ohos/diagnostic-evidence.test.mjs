import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { diagnosticsFixture, deferred, until } from './diagnostics-fixture.mjs';

const evidencePath = (f, kind) => join(f.app.filesDir, 'diagnostic-evidence', kind + '.json');
const fault = (at, event = 'APP_CRASH', extra = {}) => ({
  domain:'OS', name:event, eventType:1,
  params:{time:at,crash_type:'NativeCrash',exception:{message:'synthetic private body'},hilog:['synthetic credential'],
    threads:[{frames:['synthetic private frame']}],...extra},
});
async function info(f, i) { const reply = await f.call(i, 'info').done; assert(!reply.error, reply.error); return reply.value.evidence; }

test('OH implements the Android recordAppError contract and exposes persisted evidence', async t => {
  const f = await diagnosticsFixture(t), i = f.attach();
  const recorded = await f.call(i, 'recordAppError', {
    source: 'flutter', errorType: 'StateError',
    stack: 'package:dsh_app/main.dart:12:4\nsynthetic secret body',
  }).done;
  assert.deepEqual(recorded, { value: null });
  const evidence = (await f.call(i, 'info').done).value.evidence;
  assert.equal(evidence.appErrors.length, 1);
  assert.equal(evidence.appErrors[0].source, 'flutter');
  assert.equal(evidence.appErrors[0].stack, 'package:dsh_app/main.dart:12:4');
  assert.equal(evidence.availability.appErrors, 'available');
});

test('OH implements the Android recordVoiceStage validation and persistence contract', async t => {
  const f = await diagnosticsFixture(t), i = f.attach();
  assert.deepEqual(await f.call(i, 'recordVoiceStage', { stage: 'failed', backend: 'system', code: 7 }).done,
    { value: null });
  assert.equal((await f.call(i, 'recordVoiceStage', { stage: 'user transcript', backend: 'system' }).done).error,
    'invalid_evidence');
  const evidence = (await f.call(i, 'info').done).value.evidence;
  assert.equal(evidence.voiceStages.length, 1);
  assert.equal(evidence.voiceStages[0].stage, 'failed');
  assert.equal(evidence.voiceStages[0].code, 7);
});

test('same-name records persist across fresh module state and contain only fixed fields', async t => {
  const f = await diagnosticsFixture(t), first = f.attach();
  await info(f, first);
  const stack = 'package:dsh_app/main.dart:12:4\nhttps://private.invalid/token\npackage:flutter/a.dart:1:2';
  assert.deepEqual(await f.call(first, 'recordAppError', { source:'platform',errorType:'private-error-body',stack,secret:'private' }).done,
    {value:null});
  first.detach();
  const next = f.reload(), second = f.attach(new next.Plugin()), value = await info(f, second);
  assert.equal(value.appErrors.length, 1);
  assert.equal(value.appErrors[0].errorType, 'OtherError');
  assert.equal(value.appErrors[0].stack, 'package:dsh_app/main.dart:12:4\npackage:flutter/a.dart:1:2');
  const disk = await fs.readFile(evidencePath(f,'appErrors'),'utf8');
  assert(!disk.includes('private')); assert.equal(f.fds.size, 0);
});

test('record validation matches Android fixed values, integer codes and bounded stack locations', async t => {
  const f = await diagnosticsFixture(t), i = f.attach(); await info(f,i);
  for (const source of ['', 'native', 1, null]) {
    assert.equal((await f.call(i,'recordAppError',{source,errorType:'StateError',stack:''}).done).error,'invalid_evidence');
  }
  for (const [stage,backend] of [['failed','private'],['unknown','system'],[4,'system']]) {
    assert.equal((await f.call(i,'recordVoiceStage',{stage,backend}).done).error,'invalid_evidence');
  }
  await f.call(i,'recordAppError',{source:'session',errorType:'TypeError',stack:'s'.repeat(2049)}).done;
  await f.call(i,'recordVoiceStage',{stage:'failed',code:1.5}).done;
  const value=await info(f,i);
  assert.equal(value.appErrors[0].stack,''); assert.equal(value.voiceStages[0].backend,'unknown');
  assert.equal(value.voiceStages[0].code,undefined);
});

test('write/fsync/close/rename complete before success and preserve previous committed evidence on failure', async t => {
  const f = await diagnosticsFixture(t), i = f.attach(); await info(f,i);
  await f.call(i,'recordVoiceStage',{stage:'failed',backend:'system',code:1}).done;
  const before=await fs.readFile(evidencePath(f,'voiceStages'),'utf8');
  f.change({fsync:()=>{throw Error('synthetic fsync failure');}});
  assert.equal((await f.call(i,'recordVoiceStage',{stage:'failed',backend:'system',code:2}).done).error,'evidence_unavailable');
  assert.equal(await fs.readFile(evidencePath(f,'voiceStages'),'utf8'),before); assert.equal(f.fds.size,0);
  assert.equal((await info(f,i)).availability.voiceStages,'unavailable');
  f.change({fsync:undefined});
  await f.call(i,'recordVoiceStage',{stage:'failed',backend:'system',code:3}).done;
  const value=await info(f,i);assert.deepEqual(value.voiceStages.map(r=>r.code),[1,3]);
  assert.equal(value.availability.voiceStages,'available');
});

test('read/write short counts and per-file retention caps use actual Linux descriptors', async t => {
  const f=await diagnosticsFixture(t,{maxRead:7,maxWrite:5}),i=f.attach();await info(f,i);
  for(let n=0;n<45;n++) {
    assert.deepEqual(await f.call(i,'recordVoiceStage',{stage:'failed',backend:'system',code:n}).done,{value:null});
  }
  const value=await info(f,i);assert.equal(value.voiceStages.length,40);assert.equal(value.voiceStages[0].code,5);
  assert.equal(value.voiceStages.at(-1).code,44);assert.equal(f.fds.size,0);
  assert((await fs.stat(evidencePath(f,'voiceStages'))).size<=24*1024);
});

test('bounded writer queue rejects excess immediately and does not alias record arguments', async t => {
  const gate=deferred(),f=await diagnosticsFixture(t),i=f.attach();await info(f,i);
  let first=true;f.change({write:async()=>{if(first){first=false;await gate.promise;}}});
  const fields={stage:'failed',backend:'system',code:0},pending=[];
  pending.push(f.call(i,'recordVoiceStage',fields));await until(()=>!first);
  fields.stage='private transcript';
  for(let n=1;n<70;n++)pending.push(f.call(i,'recordVoiceStage',{stage:'failed',backend:'system',code:n}));
  assert.equal((await pending[69].done).error,'evidence_unavailable');
  gate.resolve();const replies=await Promise.all(pending.map(r=>r.done));
  assert.equal(replies.filter(r=>r.value===null).length,64);assert.equal(replies.filter(r=>r.error).length,6);
  assert.equal((await info(f,i)).voiceStages.length,40);assert.equal(f.fds.size,0);
});

test('failed close retains the descriptor and blocks replacement until a later exact close succeeds', async t => {
  const f=await diagnosticsFixture(t),i=f.attach();await info(f,i);
  f.change({close:()=>{throw Error('synthetic close failure');}});
  assert.equal((await f.call(i,'recordVoiceStage',{stage:'failed'}).done).error,'evidence_unavailable');
  assert.equal(f.fds.size,1);const opens=f.operations.filter(o=>o.op==='open').length;
  assert.equal((await f.call(i,'recordVoiceStage',{stage:'failed'}).done).error,'evidence_unavailable');
  assert.equal(f.operations.filter(o=>o.op==='open').length,opens);
  f.change({close:undefined});assert.deepEqual(await f.call(i,'recordVoiceStage',{stage:'failed',code:3}).done,{value:null});
  assert.equal(f.fds.size,0);assert.deepEqual((await info(f,i)).voiceStages.map(r=>r.code),[3]);
});

test('engine detach revokes the reply while durable writes serialize with a replacement plugin', async t => {
  const gate=deferred(),f=await diagnosticsFixture(t),old=f.attach();await info(f,old);
  let first=true;f.change({write:async()=>{if(first){first=false;await gate.promise;}}});
  const pending=f.call(old,'recordVoiceStage',{stage:'failed',code:1});await until(()=>!first);old.detach();
  const next=f.attach(),fresh=f.call(next,'recordVoiceStage',{stage:'failed',code:2});
  gate.resolve();assert.equal((await pending.done).error,'detached');assert.deepEqual(await fresh.done,{value:null});
  assert.deepEqual((await info(f,next)).voiceStages.map(r=>r.code),[1,2]);assert.equal(pending.replies.length,1);
});

test('oversized/corrupt evidence is unavailable and replaced only by a valid bounded record', async t => {
  const f=await diagnosticsFixture(t),i=f.attach();await info(f,i);
  await fs.mkdir(join(f.app.filesDir,'diagnostic-evidence'));
  await fs.writeFile(evidencePath(f,'appErrors'),'x'.repeat(24*1024+1));
  assert.equal((await info(f,i)).availability.appErrors,'unavailable');
  assert.deepEqual(await f.call(i,'recordAppError',{source:'flutter',errorType:'StateError',stack:''}).done,{value:null});
  assert.equal((await info(f,i)).availability.appErrors,'available');assert.equal(f.fds.size,0);
});

test('evidence directory and file symlinks are rejected without reading the outside target', async t => {
  const f=await diagnosticsFixture(t),i=f.attach();await info(f,i);
  const outside=join(f.root,'outside');await fs.mkdir(outside);
  await fs.writeFile(join(outside,'appErrors.json'),'synthetic outside bytes');
  await fs.symlink(outside,join(f.app.filesDir,'diagnostic-evidence'));
  assert.equal((await f.call(i,'recordAppError',{source:'flutter'}).done).error,'evidence_unavailable');
  assert.equal((await info(f,i)).availability.appErrors,'unavailable');
  await fs.unlink(join(f.app.filesDir,'diagnostic-evidence'));await fs.mkdir(join(f.app.filesDir,'diagnostic-evidence'));
  await fs.symlink(join(outside,'appErrors.json'),evidencePath(f,'appErrors'));
  assert.equal((await f.call(i,'recordAppError',{source:'flutter'}).done).error,'evidence_unavailable');
  assert.equal(await fs.readFile(join(outside,'appErrors.json'),'utf8'),'synthetic outside bytes');assert.equal(f.fds.size,0);
});

test('next attachment recovers HiAppEvent crash/freeze with explicit OH provenance and no trace content', async t => {
  const f=await diagnosticsFixture(t);
  f.faults.queue.push(fault(100),fault(200,'APP_FREEZE'));
  const i=f.attach(),value=await info(f,i);
  assert.deepEqual(value.processExits,[{at:100,source:'hiAppEvent',event:'APP_CRASH',crashType:'NativeCrash'},
    {at:200,source:'hiAppEvent',event:'APP_FREEZE'}]);
  assert.equal(value.availability.processExits,'available');
  const bytes=await fs.readFile(evidencePath(f,'processExits'),'utf8');
  for(const privatePart of ['synthetic','exception','hilog','threads','reason','status'])assert(!bytes.includes(privatePart));
  assert.deepEqual(JSON.parse(JSON.stringify(f.faults.operations[0].filters)),[{domain:'OS',names:['APP_CRASH','APP_FREEZE']}]);
  assert.equal(f.fds.size,0);
});

test('live watcher extracts only fixed fields and timestamp, ignores unrelated event/path input', async t => {
  const f=await diagnosticsFixture(t),i=f.attach();await info(f,i);
  f.emitFault({...fault(1),domain:'private'});f.emitFault(fault(2,'CPU_USAGE_HIGH'));f.emitFault(fault(NaN));
  f.emitFault(fault(3,'APP_CRASH',{crash_type:'JsError',external_log:['/outside/APP_CRASH_3_4.log','/data/storage/el2/log/hiappevent/../secret']}));
  const value=await info(f,i);assert.deepEqual(value.processExits,[{at:3,source:'hiAppEvent',event:'APP_CRASH',crashType:'JsError'}]);
  assert(!f.operations.some(o=>o.op==='unlink'));assert.equal(f.timers.size,0);
});

test('fault log cleanup follows metadata fsync/rename and never opens external log content', async t => {
  const f=await diagnosticsFixture(t),path='/data/storage/el2/log/hiappevent/APP_CRASH_100_7.log';
  await fs.mkdir(f.faultDirectory);await fs.writeFile(join(f.faultDirectory,'APP_CRASH_100_7.log'),'synthetic private log');
  f.faults.queue.push(fault(100,'APP_CRASH',{external_log:[path]}));
  const i=f.attach(),value=await info(f,i);assert.equal(value.processExits.length,1);
  const deleted=f.operations.findIndex(o=>o.op==='unlink'&&o.path===path);
  const committed=f.operations.findIndex(o=>o.op==='rename'&&o.to===evidencePath(f,'processExits'));
  assert(committed>=0&&deleted>committed);assert(!f.operations.some(o=>o.op==='open'&&o.path===path));
  await assert.rejects(fs.stat(join(f.faultDirectory,'APP_CRASH_100_7.log')),{code:'ENOENT'});
  assert(!JSON.stringify(value).includes('logs'));assert(!JSON.stringify(value).includes(path));
});

test('failed log cleanup remains journalled and is retried on fresh process state without new SDK events', async t => {
  const f=await diagnosticsFixture(t),path='/data/storage/el2/log/hiappevent/APP_FREEZE_200_8.log';
  await fs.mkdir(f.faultDirectory);await fs.writeFile(join(f.faultDirectory,'APP_FREEZE_200_8.log'),'synthetic private log');
  f.change({unlink:()=>{throw Error('synthetic cleanup failure');}});
  f.faults.queue.push(fault(200,'APP_FREEZE',{external_log:[path]}));
  const old=f.attach(),before=await info(f,old);
  assert.equal(before.availability.processExits,'unavailable');assert.equal(before.processExits.length,1);
  assert((await fs.readFile(evidencePath(f,'processExits'),'utf8')).includes(path));
  old.detach();f.change({unlink:undefined});const next=f.reload(),i=f.attach(new next.Plugin());
  const after=await info(f,i);assert.equal(after.availability.processExits,'available');
  assert.equal(after.processExits.length,1);assert(!JSON.stringify(after).includes(path));
  assert(!(await fs.readFile(evidencePath(f,'processExits'),'utf8')).includes(path));
  await assert.rejects(fs.stat(join(f.faultDirectory,'APP_FREEZE_200_8.log')),{code:'ENOENT'});
});

test('storage failure retains one sanitized consumed event and retries without consuming later events', async t => {
  const f=await diagnosticsFixture(t);f.faults.queue.push(fault(100),fault(200,'APP_FREEZE'));
  f.change({fsync:()=>{throw Error('write blocked');}});const i=f.attach();
  const before=await info(f,i);assert.equal(before.availability.processExits,'unavailable');
  assert.equal(f.faults.queue.length,1);f.change({fsync:undefined});
  const after=await info(f,i);assert.deepEqual(after.processExits.map(r=>r.at),[100,200]);assert.equal(after.availability.processExits,'available');
});

test('old watcher callbacks and old detach cannot consume or remove a newer owner', async t => {
  const f=await diagnosticsFixture(t),old=f.attach();await info(f,old);
  const prior=[...f.faults.watchers.values()][0],fresh=f.attach();await info(f,fresh);
  const before=f.faults.operations.filter(o=>o.op==='takeNext').length;
  prior.onTrigger(1,1,{});old.detach();await new Promise(r=>setImmediate(r));
  assert.equal(f.faults.operations.filter(o=>o.op==='takeNext').length,before);assert.equal(f.faults.watchers.size,1);
  f.emitFault(fault(30));assert.equal((await info(f,fresh)).processExits[0].at,30);
});

test('absent capability and failing system subscription are explicit, while app record storage still works', async t => {
  for(const [options,state] of [[{missingCaps:['SystemCapability.HiviewDFX.HiAppEvent']},'unsupported'],[{addWatcherError:true},'unavailable']]) {
    const f=await diagnosticsFixture(t,options),i=f.attach();await f.call(i,'recordVoiceStage',{stage:'failed'}).done;
    const value=await info(f,i);assert.equal(value.availability.processExits,state);assert.equal(value.availability.voiceStages,'available');
  }
});

test('takeNext failure stays unavailable until the next explicit read succeeds', async t => {
  const f=await diagnosticsFixture(t,{takeFaultError:true}),i=f.attach();
  assert.equal((await info(f,i)).availability.processExits,'unavailable');f.change({takeFaultError:false});
  assert.equal((await info(f,i)).availability.processExits,'available');
});

test('one recovery batch is bounded and later reads drain the backlog without polling', async t => {
  const f=await diagnosticsFixture(t);for(let n=1;n<=40;n++)f.faults.queue.push(fault(n));
  const i=f.attach(),first=await info(f,i);assert.equal(f.faults.queue.length,8);
  assert.equal(first.availability.processExits,'unavailable');assert.deepEqual(first.processExits.map(r=>r.at),[25,26,27,28,29,30,31,32]);
  const second=await info(f,i);assert.equal(second.availability.processExits,'available');
  assert.deepEqual(second.processExits.map(r=>r.at),[33,34,35,36,37,38,39,40]);assert.equal(f.timers.size,0);
});

test('a corrupt fault store remains unavailable until a new valid OS event replaces it', async t => {
  const f=await diagnosticsFixture(t);await fs.mkdir(join(f.app.filesDir,'diagnostic-evidence'));
  await fs.writeFile(evidencePath(f,'processExits'),'{');const i=f.attach();
  assert.equal((await info(f,i)).availability.processExits,'unavailable');f.emitFault(fault(80));
  const value=await info(f,i);assert.equal(value.availability.processExits,'available');assert.equal(value.processExits[0].at,80);
});

test('consumed failed event survives engine replacement in the same process', async t => {
  const f=await diagnosticsFixture(t);f.faults.queue.push(fault(400));f.change({fsync:()=>{throw Error('not durable');}});
  const old=f.attach();assert.equal((await info(f,old)).availability.processExits,'unavailable');old.detach();
  f.change({fsync:undefined});const next=f.attach(),value=await info(f,next);
  assert.equal(value.availability.processExits,'available');assert.equal(value.processExits[0].at,400);
});

test('actual native channel replies form the wire consumed by the real Dart data test', async t => {
  const f=await diagnosticsFixture(t);f.faults.queue.push(fault(100),fault(200,'APP_FREEZE'));
  const i=f.attach();await f.call(i,'recordAppError',{source:'flutter',errorType:'StateError',stack:'package:dsh_app/main.dart:12:4'}).done;
  await f.call(i,'recordVoiceStage',{stage:'failed',backend:'system',code:7}).done;
  const reply=await f.call(i,'info').done;assert.equal(reply.value.evidence.processExits.length,2);
  if(process.env.OHOS_DIAGNOSTIC_EVIDENCE_WIRE)await fs.writeFile(process.env.OHOS_DIAGNOSTIC_EVIDENCE_WIRE,JSON.stringify(reply.value));
});

test('actual Android fixed value lists remain accepted by the same OH record method names', async t => {
  const repo=fileURLToPath(new URL('../../../',import.meta.url));
  const source=await fs.readFile(join(repo,'app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/diagnostics/EvidenceStore.kt'),'utf8');
  const values=name=>{const block=source.match(new RegExp('val '+name+' = setOf\\(([\\s\\S]*?)\\)'));assert(block);return [...block[1].matchAll(/"([A-Za-z_]+)"/g)].map(v=>v[1]);};
  const f=await diagnosticsFixture(t),i=f.attach();await info(f,i);
  for(const stage of values('STAGES'))assert.deepEqual(await f.call(i,'recordVoiceStage',{stage,backend:'system'}).done,{value:null});
  for(const backend of values('BACKENDS'))assert.deepEqual(await f.call(i,'recordVoiceStage',{stage:'failed',backend}).done,{value:null});
  for(const errorType of values('ERROR_TYPES'))assert.deepEqual(await f.call(i,'recordAppError',{source:'flutter',errorType}).done,{value:null});
  const value=await info(f,i);assert.deepEqual(value.appErrors.map(r=>r.errorType),values('ERROR_TYPES'));
});

test('late system delivery retains the eight newest event times and deduplicates exact repeats', async t => {
  const f=await diagnosticsFixture(t);
  for(const at of [10,20,30,40,50,60,70,80,1,80,75])f.faults.queue.push(fault(at));
  const i=f.attach(),value=await info(f,i);
  assert.deepEqual(value.processExits.map(r=>r.at),[20,30,40,50,60,70,75,80]);
});

test('late fault older than retained metadata is journalled before cleanup and never leaks a ninth public record', async t => {
  const f=await diagnosticsFixture(t),path='/data/storage/el2/log/hiappevent/APP_CRASH_50_7.log';
  for(let at=100;at<108;at++)f.faults.queue.push(fault(at));
  const i=f.attach();await info(f,i);
  await fs.mkdir(f.faultDirectory);await fs.writeFile(join(f.faultDirectory,'APP_CRASH_50_7.log'),'synthetic private log');
  let witnessed=false;
  f.change({unlink:async ({path:deleted})=>{
    assert.equal(deleted,path);
    const disk=JSON.parse(await fs.readFile(evidencePath(f,'processExits'),'utf8'));
    assert(disk.some(row=>row.at===50&&row.logs?.includes(path)),'late cleanup debt must be durable before unlink');
    assert.equal(disk.length,9);assert((await fs.stat(evidencePath(f,'processExits'))).size<=8*1024);
    witnessed=true;
  }});
  f.faults.queue.push(fault(50,'APP_CRASH',{external_log:[path]}));
  const value=await info(f,i);
  assert.equal(witnessed,true);assert.equal(value.availability.processExits,'available');
  assert.deepEqual(value.processExits.map(row=>row.at),[100,101,102,103,104,105,106,107]);
  assert.equal(JSON.parse(await fs.readFile(evidencePath(f,'processExits'),'utf8')).length,8);
  await assert.rejects(fs.stat(join(f.faultDirectory,'APP_CRASH_50_7.log')),{code:'ENOENT'});
  assert(!JSON.stringify(value).includes(path));assert.equal(f.fds.size,0);
});

test('failed late fault cleanup keeps bounded durable debt across reload and blocks further SDK consumption', async t => {
  const f=await diagnosticsFixture(t),path='/data/storage/el2/log/hiappevent/APP_FREEZE_50_7.log';
  for(let at=100;at<108;at++)f.faults.queue.push(fault(at));
  const old=f.attach();await info(f,old);
  await fs.mkdir(f.faultDirectory);await fs.writeFile(join(f.faultDirectory,'APP_FREEZE_50_7.log'),'synthetic private log');
  f.change({unlink:()=>{throw Error('synthetic cleanup failure');}});
  f.faults.queue.push(fault(50,'APP_FREEZE',{external_log:[path]}),fault(200));
  const before=await info(f,old);
  assert.equal(before.availability.processExits,'unavailable');assert.equal(f.faults.queue.length,1);
  assert.deepEqual(before.processExits.map(row=>row.at),[100,101,102,103,104,105,106,107]);
  let disk=JSON.parse(await fs.readFile(evidencePath(f,'processExits'),'utf8'));
  assert.equal(disk.length,9);assert(disk.some(row=>row.at===50&&row.logs?.includes(path)));
  assert((await fs.stat(evidencePath(f,'processExits'))).size<=8*1024);
  old.detach();f.change({unlink:undefined});const next=f.reload(),i=f.attach(new next.Plugin());
  const after=await info(f,i);assert.equal(after.availability.processExits,'available');
  assert.deepEqual(after.processExits.map(row=>row.at),[101,102,103,104,105,106,107,200]);
  disk=JSON.parse(await fs.readFile(evidencePath(f,'processExits'),'utf8'));assert.equal(disk.length,8);
  assert(!JSON.stringify(disk).includes(path));assert.equal(f.faults.queue.length,0);
  await assert.rejects(fs.stat(join(f.faultDirectory,'APP_FREEZE_50_7.log')),{code:'ENOENT'});
  assert(!JSON.stringify(after).includes(path));assert.equal(f.fds.size,0);
});
