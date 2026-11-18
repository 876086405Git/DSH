import test from 'node:test';
import assert from 'node:assert/strict';
import { captureFixture, deferred, settle, pcm } from './call-capture-fixture.mjs';

test('callStart returns Android outcome vocabulary and never asks permission',async()=>{
  for(const [options,result] of [[{granted:false},'permission'],[{supported:false},'unavailable'],[{start(){throw Error('SDK');}},'microphone'],[{},'ok']]){
    const f=captureFixture(options),call=f.call();assert.equal(await call.start(f.context,true,'normal'),result);
    if(result==='permission'||result==='unavailable')assert.equal(f.capturers.length,0);
    await call.stop();
  }
});

test('call owns the same physical lease as dictation and retires a plugin before opening',async()=>{
  const f=captureFixture(),{VoiceMicLease,VoiceMicToken}=f.load('VoiceMicLease'),call=f.call();let retired=0;
  const token=new VoiceMicToken('plugin',async()=>{retired++;VoiceMicLease.release(token);});assert.equal(VoiceMicLease.plugin(token),true);
  assert.equal(await call.start(f.context,true,'normal'),'ok');assert.equal(retired,1);
  assert.throws(()=>VoiceMicLease.assertDictationAvailable(),/麦克风/);
  await call.stop();assert.doesNotThrow(()=>VoiceMicLease.assertDictationAvailable());
});

test('unreleased previous plugin cannot be overridden by call success',async()=>{
  const f=captureFixture(),{VoiceMicLease,VoiceMicToken}=f.load('VoiceMicLease'),call=f.call();
  const token=new VoiceMicToken('plugin',async()=>{});VoiceMicLease.plugin(token);
  assert.equal(await call.start(f.context,true,'normal'),'microphone');assert.equal(f.capturers.length,0);
});

test('stop during permission await or late SDK start cannot resurrect call',async()=>{
  for(const boundary of ['permission','start']){
    const wait=deferred(),f=captureFixture({[boundary]:()=>wait.promise}),call=f.call();
    const started=call.start(f.context,true,'normal');await settle();f.retire();const stopped=call.stop();wait.resolve();
    assert.equal(await started,'unavailable');await stopped;
    for(const c of f.capturers)assert.equal(c.releases,1);
    assert.equal(f.events.length,0);
  }
});

test('call controls preserve mute, pause, playing, and speaker preference with failed route unchanged',async()=>{
  const options={},f=captureFixture(options),call=f.call();assert.equal(call.speaker,true);
  assert.equal(await call.start(f.context,true,'patient'),'ok');const r=f.capturers[0];
  call.mute(true);r.data(pcm(10000,2));await settle();assert.equal(f.events.at(-1).value,0);
  call.mute(false);call.pause('quick');call.bargeIn(false);call.setPlaying(false);
  for(let i=0;i<6;i++){r.data(pcm(10000));await settle();}
  for(let i=0;i<35;i++){r.data(pcm(0));await settle();}
  assert.equal(f.events.filter(e=>e.type==='utterance').length,1);
  assert.equal(await call.setSpeaker(false),false);assert.equal(call.speaker,false);
  options.route=()=>{throw Error('route unavailable');};await assert.rejects(call.setSpeaker(true));assert.equal(call.speaker,false);
  await call.stop();
});

test('failed call release keeps lease, explicit stop retries, next call may then open',async()=>{
  let failed=true;const f=captureFixture({release(){if(failed)throw Error('release');}}),call=f.call();
  assert.equal(await call.start(f.context,true,'normal'),'ok');await assert.rejects(call.stop());
  const {VoiceMicLease}=f.load('VoiceMicLease');assert.throws(()=>VoiceMicLease.assertDictationAvailable());
  failed=false;await call.stop();assert.equal(await call.start(f.context,true,'normal'),'ok');await call.stop();
});

test('call keeps only its own window awake and restores the previous setting',async()=>{
  for(const initialKeep of [false,true]){
    const f=captureFixture({initialKeep}),call=f.call();assert.equal(await call.start(f.context,true,'normal'),'ok');
    assert.equal(f.screen.keep,true);await call.stop();assert.equal(f.screen.keep,initialKeep);
    assert.deepEqual(f.screenCalls,initialKeep?[]:[true,false]);
  }
});

test('late window lookup and late keep-screen mutation are cancelled and restored',async()=>{
  for(const boundary of ['getWindow','keepScreen']){
    const pending=deferred(),f=captureFixture({[boundary]:on=>on===false?undefined:pending.promise}),call=f.call();
    const started=call.start(f.context,true,'normal');await settle();const stopped=call.stop();await settle();
    assert.equal(f.capturers[0].releases,1,'late window promise must not delay microphone release');pending.resolve();
    assert.equal(await started,'unavailable');await stopped;assert.equal(f.screen.keep,false);
    assert.deepEqual(f.screenCalls,boundary==='getWindow'?[]:[true,false]);assert.equal(f.capturers[0].releases,1);
  }
});

test('uncertain keep-screen failure rolls back; failed restore can be retried by replacement owner',async()=>{
  const options={keepScreen(on){if(on)throw Error('uncertain set');}},f=captureFixture(options),call=f.call();
  assert.equal(await call.start(f.context,true,'normal'),'unavailable');assert.equal(f.screen.keep,false);
  assert.deepEqual(f.screenCalls,[true,false]);options.keepScreen=undefined;
  assert.equal(await call.start(f.context,true,'normal'),'ok');
  options.keepScreen=on=>{if(!on)throw Error('restore failed');};await assert.rejects(call.stop());
  options.keepScreen=undefined;const next=f.call();assert.equal(await next.start(f.context,true,'normal'),'ok');
  await next.stop();assert.equal(f.screen.keep,false);
});

test('stale controller cannot close a current call and destroyed old window cannot block next call',async()=>{
  const options={},f=captureFixture(options),{OhosSpeechCall}=f.load('OhosSpeechCall');let oldCurrent=true;
  const listener={speechStart(){},utterance(){},level(){},error(){}};
  const old=new OhosSpeechCall(()=>oldCurrent,listener,async()=>{}),next=f.call();
  assert.equal(await old.start(f.context,true,'normal'),'ok');oldCurrent=false;
  assert.equal(await next.start(f.context,true,'normal'),'ok');const active=f.capturers.at(-1);
  assert.equal(await old.start(f.context,true,'normal'),'unavailable');assert.equal(active.releases,0);
  options.keepScreen=on=>{if(!on)throw Object.assign(Error('destroyed'),{code:1300002});};
  await next.stop();options.keepScreen=undefined;assert.equal(await f.call().start(f.context,true,'normal'),'ok');
});
