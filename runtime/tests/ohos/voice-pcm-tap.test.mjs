import test from 'node:test';
import assert from 'node:assert/strict';
import { voiceFixture, deferred, until } from './voice-fixture.mjs';
import { pcm, settle } from './call-capture-fixture.mjs';

test('dsh/voice streamingPcm preserves Android source/session and 640 byte frames', async () => {
  const f=voiceFixture();
  assert.deepEqual(await f.call(f.methods,'streamingPcm',{source:'dictation',pcmSession:11}).done,{value:null});
  assert.deepEqual(await f.call(f.methods,'startRecorder',{sessionId:1,maxSeconds:1}).done,{value:null});
  f.capturers[0].data(pcm(123).subarray(0,318));f.capturers[0].data(pcm(123).subarray(318));await settle();
  const [e]=f.events.filter(e=>e.type==='pcm');assert(e);assert.equal(e.pcmSession,11);assert.equal(e.rate,16000);
  assert.equal(e.source,'dictation');assert.equal(e.bytes.length,640);assert.equal(new DataView(e.bytes.buffer).getInt16(0,true),123);
  assert.deepEqual(await f.call(f.methods,'streamingPcm',{source:'unknown',pcmSession:12}).done,
    {error:'pcm-source',message:'unknown PCM source',details:null});
  await f.call(f.methods,'cancel').done;
});

test('old disable does not retire new session and source=call never leaks dictation bytes', async () => {
  const f=voiceFixture();await f.call(f.methods,'startRecorder',{sessionId:1,maxSeconds:1}).done;
  await f.call(f.methods,'streamingPcm',{source:'dictation',pcmSession:1}).done;
  await f.call(f.methods,'streamingPcm',{source:'dictation',pcmSession:2}).done;
  await f.call(f.methods,'streamingPcm',{pcmSession:1}).done;
  f.capturers[0].data(pcm(1));await settle();assert.equal(f.events.filter(e=>e.type==='pcm').at(-1).pcmSession,2);
  await f.call(f.methods,'streamingPcm',{source:'call',pcmSession:3}).done;
  f.capturers[0].data(pcm(2));await settle();assert.equal(f.events.filter(e=>e.type==='pcm').length,1);
  await f.call(f.methods,'cancel').done;
});

test('background and event cancellation discard pending tap and do not publish into new sink', async () => {
  for(const stop of [f=>f.background(),f=>f.stream.handler.onCancel(null)]) {
    const f=voiceFixture();await f.call(f.methods,'startRecorder',{sessionId:1,maxSeconds:1}).done;
    await f.call(f.methods,'streamingPcm',{source:'dictation',pcmSession:1}).done;
    f.capturers[0].data(pcm(123));stop(f);await settle();
    assert.equal(f.events.filter(e=>e.type==='pcm').length,0);assert.equal(f.capturers[0].released,true);
  }
});

test('dictation tap holds early PCM until SDK start and overflow admission, retaining source bytes', async () => {
  const started=deferred(),f=voiceFixture({start:()=>started.promise});
  await f.call(f.methods,'streamingPcm',{source:'dictation',pcmSession:17}).done;
  const start=f.call(f.methods,'startRecorder',{sessionId:1,maxSeconds:2}).done;
  await until(()=>f.capturers.length===1&&f.calls.includes('start'));
  f.capturers[0].data(pcm(1234));await settle();assert.equal(f.events.filter(e=>e.type==='pcm').length,0);
  started.resolve();assert.deepEqual(await start,{value:null});await settle();
  const frames=f.events.filter(e=>e.type==='pcm');assert.equal(frames.length,1);
  assert.equal(new DataView(frames[0].bytes.buffer).getInt16(0,true),1234);
  await f.call(f.methods,'cancel').done;
});

test('dictation start failure and per-read overflow discard PCM before streaming delivery', async () => {
  for(const failure of ['start','overflow']){
    const started=deferred(),f=voiceFixture({start:()=>started.promise});
    await f.call(f.methods,'streamingPcm',{source:'dictation',pcmSession:18}).done;
    const start=f.call(f.methods,'startRecorder',{sessionId:1,maxSeconds:2}).done;
    await until(()=>f.capturers.length===1&&f.calls.includes('start'));
    f.capturers[0].data(pcm(1234));await settle();assert.equal(f.events.filter(e=>e.type==='pcm').length,0);
    if(failure==='start'){started.reject(Error('start failed'));assert.equal((await start).error,'audio');}
    else{f.change({overflow:1});started.resolve();await start;await settle();}
    await f.call(f.methods,'cancel').done;assert.equal(f.events.filter(e=>e.type==='pcm').length,0);
    assert.equal(f.capturers[0].released,true);
  }
});
