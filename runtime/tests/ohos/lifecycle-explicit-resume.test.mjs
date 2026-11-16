import test from 'node:test';
import assert from 'node:assert/strict';
import {BoundaryCoordinator} from '../../ohos/lifecycle/coordinator.mjs';
function setup(t,foreground=1){
 const records=[];
 const journal={records,async append(body){const row={body};records.push(row);return row;},async flush(){},async close(){}};
 const native={version:1,engineGeneration:1,ownerGeneration:1,revision:1,grantGeneration:0,nowMs:100,deadlineMs:0,drainAtMs:0,phase:0,available:1,foreground,clockFailed:0};
 let renewals=0;
 const c=new BoundaryCoordinator({journal,bootId:'resume-contract',flushSession:async()=>true,readEvents:async()=>[],readHost:()=>({...native}),revalidateTransport:async()=>{renewals++;}});
 t.after(()=>c.close());return {c,native,journal,renewals:()=>renewals};
}
test('explicit resume without observed pause renews transport on each invocation',async t=>{
 const f=setup(t);await f.c.observeHost({});assert.equal(f.renewals(),0);
 await f.c.resume();assert.equal(f.renewals(),1);await f.c.resume();assert.equal(f.renewals(),2);
 assert.deepEqual(f.journal.records.map(x=>x.body.kind),['resume','resume']);
});
test('manual pause then allowed resume schedules one transport renewal',async t=>{
 const f=setup(t);await f.c.pause();await f.c.resume();assert.equal(f.renewals(),1);assert.equal(f.c.status().manualPaused,false);assert.equal(f.c.status().paused,false);
 assert.deepEqual(f.journal.records.map(x=>x.body.kind),['pause','resume']);
});
test('native background resume releases manual cause durably but keeps admission closed',async t=>{
 const f=setup(t,0);await f.c.pause();await f.c.resume();assert.equal(f.renewals(),0);assert.equal(f.c.status().paused,true);assert.equal(f.c.status().manualPaused,false);
 assert.equal(f.journal.records.at(-1).body.manualPaused,false);assert.equal(f.c.admit('s'),false);
});
test('native foreground transition plus explicit resume renews once, not twice',async t=>{
 const f=setup(t,0);await f.c.observeHost({});f.native.foreground=1;f.native.revision++;await f.c.resume();assert.equal(f.renewals(),1);
 assert.deepEqual(f.journal.records.map(x=>x.body.kind),['pause','resume']);
});
test('explicit resume joins serialized transport revalidation before acknowledgement',async t=>{
 const f=setup(t);const release=Promise.withResolvers(),entered=Promise.withResolvers();let done=false;
 f.c.revalidateTransport=async()=>{entered.resolve();await release.promise;};
 const resumed=f.c.resume().then(()=>{done=true;});
 await Promise.race([entered.promise,new Promise((_,reject)=>setTimeout(()=>reject(new Error('resume skipped revalidation')),500))]);
 assert.equal(done,false);release.resolve();await resumed;assert.equal(done,true);
});
