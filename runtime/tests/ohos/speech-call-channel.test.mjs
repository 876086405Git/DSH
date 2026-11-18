import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { captureFixture, pcm, settle, deferred } from './call-capture-fixture.mjs';

test('actual dsh/speech handler covers every Android method including callPause',async()=>{
  const source=fs.readFileSync(new URL('../../../app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/speech/SpeechPlugin.kt',import.meta.url),'utf8');
  const dispatch=source.slice(source.indexOf('override fun onMethodCall'),source.indexOf('private fun open'));
  const methods=[...dispatch.matchAll(/^\s*"([A-Za-z]+)"\s*->/gm)].map(m=>m[1]);
  assert.equal(methods.length,13);
  const f=captureFixture(),s=f.speech();assert.deepEqual(await s.request('callStart',{bargeIn:true,pause:'patient'}),{value:'ok'});
  const args={open:{id:'r',rate:24000,call:true,levels:true},write:{id:'r',bytes:pcm(1)},waiting:{id:'r'},end:{id:'r'},stop:{},duck:{id:'r',on:true},
    callStart:{bargeIn:true,pause:'normal'},callStop:{},callMute:{on:false},callBargeIn:{on:true},callPause:{pause:'quick'},callPlaying:{on:false},callSpeaker:{on:true}};
  for(const method of methods){const result=await s.request(method,args[method]);assert.equal(result.missing,undefined,method);assert.equal(result.error,undefined,method);}
  await s.request('callStop');
});

test('speaker preference reaches future call renderer and active SDK rejection is explicit',async()=>{
  const options={},f=captureFixture(options),s=f.speech();await s.request('callStart',{pause:'normal'});
  assert.deepEqual(await s.request('callSpeaker',{on:false}),{value:false});
  assert.deepEqual(await s.request('open',{id:'r',rate:24000,call:true,levels:true}),{value:true});
  assert.equal(f.streams[0].config.speaker,false);
  assert.deepEqual(await s.request('callSpeaker',{on:true}),{value:true});assert.equal(f.session.devices.at(-1),2);
  options.route=()=>{throw Error('route');};assert.equal((await s.request('callSpeaker',{on:false})).error,'speech-output');
  await s.request('callStop');
});

test('late speaker route cannot overwrite newer preference or return stale success after playback stop',async()=>{
  const route=deferred(),options={route:on=>on?undefined:route.promise,pcmStop:()=>route.promise};
  const f=captureFixture(options),s=f.speech();await s.request('callStart',{pause:'normal'});
  await s.request('open',{id:'old',rate:24000,call:true});
  const old=s.request('callSpeaker',{on:false});await settle();
  const stop=s.request('stop');await settle(); // playback may stop while the call's app route is pending
  const latest=s.request('callSpeaker',{on:true});await settle();
  route.resolve();assert.equal((await old).error,'speech-output');assert.deepEqual(await latest,{value:true});await stop;
  assert.deepEqual(await s.request('open',{id:'new',rate:24000,call:true}),{value:true});
  assert.equal(f.streams[1].config.speaker,true);await s.request('callStop');
});

test('call events have Android shape, playback barge-in ducks, callStop releases window and mic',async()=>{
  const f=captureFixture(),s=f.speech();await s.request('callStart',{bargeIn:true,pause:'quick'});
  await s.request('open',{id:'r',rate:24000,call:true,levels:true});f.streams[0].started();
  const r=f.capturers[0];for(let i=0;i<30;i++){r.data(pcm(20000));await settle();}
  const start=f.events.find(e=>e.type==='speechStart');assert.equal(start.over,true);assert.deepEqual(f.streams[0].ducks,[true]);
  for(let i=0;i<35;i++){r.data(pcm(0));await settle();}
  const utterance=f.events.find(e=>e.type==='utterance');assert(utterance.wav instanceof Uint8Array);assert.equal(typeof utterance.ms,'number');
  assert(f.events.some(e=>e.type==='micLevel'&&typeof e.value==='number'));
  await s.request('callStop');assert.equal(r.releases,1);assert.equal(f.screen.keep,false);assert.equal(f.streams[0].closed,true);
});

test('callStop leaves unrelated read-aloud stream but background retires both',async()=>{
  const f=captureFixture(),s=f.speech();await s.request('callStart');await s.request('open',{id:'read'});
  await s.request('callStop');assert.equal(f.streams[0].closed,false);assert.equal(f.capturers[0].releases,1);
  await s.request('callStart');s.background();await settle();
  assert.equal(f.streams[0].closed,true);assert.equal(f.capturers[1].releases,1);assert.equal(f.screen.keep,false);
});

test('callStop during previous playback close invalidates delayed callStart before new capture',async()=>{
  const pending=deferred(),options={},f=captureFixture(options),s=f.speech();await s.request('callStart');
  await s.request('open',{id:'old',call:true});options.pcmStop=()=>pending.promise;
  const start=s.request('callStart');await settle();const stop=s.request('callStop');await settle();pending.resolve();
  assert.deepEqual(await start,{value:'unavailable'});await stop;assert.equal(f.capturers.length,1);assert.equal(f.capturers[0].releases,1);
});
