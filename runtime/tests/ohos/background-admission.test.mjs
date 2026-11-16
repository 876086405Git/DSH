import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {setImmediate as nextTurn} from 'node:timers/promises';
import {installPublication} from '../../ohos/publication/index.mjs';
import {engineFixture} from './lifecycle-engine-fixture.mjs';
let home;
before(async()=>{globalThis[Symbol.for('dsh.go.ohos.sim')]=true;home=await fs.mkdtemp(join(tmpdir(),'admission-home-'));process.env.DSH_HOME=home;await installPublication();});
after(()=>fs.rm(home,{recursive:true,force:true}));
async function fixture(t){const root=await fs.mkdtemp(join(tmpdir(),'admission-'));const state={version:1,engineGeneration:1,ownerGeneration:1,revision:1,grantGeneration:0,nowMs:1000,deadlineMs:0,drainAtMs:0,phase:0,available:1,foreground:1,clockFailed:0};const f=await engineFixture({root,readHost:()=>state,sourcePath:process.env.DSH_BACKGROUND_SCHEDULER_BEFORE});t.after(async()=>{await f.close();await fs.rm(root,{recursive:true,force:true});});return {...f,state};}
test('actual scheduler rechecks synchronous admission after resolved gate microtask before appending a call',async t=>{
 const f=await fixture(t),owner=await f.create();let appendedCalls=0;const append=owner.session.append.bind(owner.session);owner.session.append=(type,...args)=>{if(type==='tool/call')appendedCalls++;return append(type,...args);};let effects=0;f.register('effect',async()=>{effects++;return[{type:'text',text:'once'}];});
 const gate=f.coordinator.gate.bind(f.coordinator);let checks=0;
 f.coordinator.gate=(...args)=>{const ready=gate(...args);if(++checks===1)ready.then(()=>{f.state.foreground=0;f.state.revision++;});return ready;};
 const running=owner.run([{}]);await nextTurn();await nextTurn();
 const calls=appendedCalls;
 const dispatched=effects;
 f.state.foreground=1;f.state.revision++;await f.coordinator.observeHost({revision:1,foreground:true,computePermission:'unknown'});await running;
 assert.equal(dispatched,0);assert.equal(calls,0,'no call preparation crosses final-await revoke');assert.equal(effects,1);
});
test('actual coordinator rejects expiry in final gate continuation before dispatch and admits once after foreground',async t=>{
 const f=await fixture(t),owner=await f.create();let effects=0;f.register('effect',async()=>{effects++;return[{type:'text',text:'once'}];});
 const gate=f.coordinator.gate.bind(f.coordinator);let checks=0;const crossed=Promise.withResolvers();
 f.coordinator.gate=(...args)=>{const ready=gate(...args);if(++checks===4)ready.then(()=>{f.state.foreground=0;f.state.phase=2;f.state.deadlineMs=2000;f.state.drainAtMs=1500;f.state.nowMs=1500;f.state.revision++;crossed.resolve();});return ready;};
 const running=owner.run([{}]);await crossed.promise;await nextTurn();const dispatched=effects;
 f.state.foreground=1;f.state.revision++;await f.coordinator.observeHost({revision:1,foreground:true,computePermission:'unknown'});await running;
 assert.equal(dispatched,0,'expiry across final await must not enter tool');assert.equal(effects,1);
});
