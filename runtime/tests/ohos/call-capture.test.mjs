import test from 'node:test';
import assert from 'node:assert/strict';
import { captureFixture, pcm, settle, deferred } from './call-capture-fixture.mjs';

// Expected vectors follow the unchanged Android SpeechGate/TurnPause constants:
// 6 loud frames; 20 ms each; quick/normal/patient hangover 700/1000/1600 ms.
test('energy fallback has Android three pause thresholds and dynamic pause changes', () => {
  for (const [pause, quiet] of [['quick',35],['normal',50],['patient',80]]) {
    const f=captureFixture(), {CallEnergyGate,CallEdge}=f.load('CallEnergyGate');
    const gate=new CallEnergyGate(false);gate.pause=pause;
    gate.consume(-80,0);
    for(let i=1;i<6;i++)assert.equal(gate.consume(-20,i*20),CallEdge.None);
    assert.equal(gate.consume(-20,120),CallEdge.Start);
    for(let i=1;i<quiet;i++)assert.equal(gate.consume(-80,120+i*20),CallEdge.None);
    assert.equal(gate.consume(-80,120+quiet*20),CallEdge.End);
  }
  const f=captureFixture(),{CallEnergyGate,CallEdge}=f.load('CallEnergyGate'),g=new CallEnergyGate(false);
  g.pause='PATIENT';g.consume(-80,0);for(let i=0;i<6;i++)g.consume(-20,20*i);
  for(let i=0;i<40;i++)assert.equal(g.consume(-80,200+i*20),CallEdge.None);
  g.pause='quick';assert.equal(g.consume(-80,1000),CallEdge.End);
});

test('energy playback waits 400 ms and distinguishes unknown AEC margin', () => {
  const f=captureFixture(),{CallEnergyGate,CallEdge}=f.load('CallEnergyGate');
  const gate=new CallEnergyGate(false);gate.consume(-60,0);gate.setPlaying(true,0);
  for(let now=20;now<400;now+=20)assert.equal(gate.consume(-20,now),CallEdge.None);
  for(let now=400;now<580;now+=20)assert.equal(gate.consume(-20,now),CallEdge.None);
  assert.equal(gate.consume(-20,580),CallEdge.Start);
  for(const aec of [false,true]) {
    const g=new CallEnergyGate(aec);g.consume(-60,0);g.setPlaying(true,0);
    const result=Array.from({length:10},(_,i)=>g.consume(-33,400+i*20));
    assert.equal(result.at(-1),aec?CallEdge.Start:CallEdge.None);
  }
});

test('capture uses communication source and exact 300 ms preroll + WAV, outside read callback', async () => {
  const f=captureFixture(), c=f.make(); await c.start();
  const r=f.capturers[0];assert.equal(r.config.capturerInfo.source,7);
  for(let i=0;i<20;i++){r.data(pcm(0));await settle();}
  for(let i=0;i<6;i++){r.data(pcm(10000));await settle();}
  for(let i=0;i<50;i++){r.data(pcm(0));await settle();}
  const [e]=f.events.filter(e=>e.type==='utterance');assert(e);
  assert.equal(e.ms,1320);assert.equal(e.wav.length,44+66*640);
  const view=new DataView(e.wav.buffer);assert.equal(view.getUint32(24,true),16000);
  assert.equal(view.getUint16(22,true),1);assert.equal(view.getUint16(34,true),16);
  assert.equal(view.getUint32(40,true),66*640);assert.equal(view.getInt16(44+10*640,true),10000);
  assert.equal(f.events.filter(e=>e.type==='speechStart').length,1);
  await c.stop();assert.equal(f.released,1);assert.equal(r.releases,1);
});

test('mute invalidates queued PCM, partial frames and utterance even after unmute', async () => {
  const f=captureFixture(),c=f.make(),{VoicePcmTap}=f.load('VoicePcmTap');const taps=[];
  VoicePcmTap.enable('call',8,(_tap,bytes)=>taps.push(bytes));await c.start();
  const r=f.capturers[0];r.data(pcm(1234));c.muted=true;c.muted=false;await settle();
  assert.equal(taps.length,0);
  r.data(pcm(2345).subarray(0,320));c.muted=true;c.muted=false;
  r.data(pcm(3456).subarray(0,320));await settle();assert.equal(taps.length,0);
  r.data(pcm(3456).subarray(0,320));await settle();assert.equal(taps.length,1);
  assert.equal(new DataView(taps[0].buffer).getInt16(0,true),3456);
  for(let i=0;i<6;i++){r.data(pcm(10000));await settle();}
  c.muted=true;for(let i=0;i<60;i++){r.data(pcm(0));await settle();}
  assert.equal(f.events.filter(e=>e.type==='utterance').length,0);
  assert.equal(f.events.at(-1).value,0);await c.stop();
});

test('retire while create/start is pending really releases and emits no late events', async () => {
  const opened=deferred(), f=captureFixture({start:()=>opened.promise}),c=f.make();
  const start=c.start();await settle();f.retire();const stop=c.stop();
  assert.equal(f.released,0);opened.resolve();await assert.rejects(start);await stop;
  assert.equal(f.capturers[0].releases,1);assert.equal(f.released,1);assert.equal(f.events.length,0);
});

test('PCM arriving during pending SDK start waits for successful start and preserves the first syllable', async () => {
  const opened=deferred(),f=captureFixture({start:()=>opened.promise}),c=f.make(),{VoicePcmTap}=f.load('VoicePcmTap'),taps=[];
  VoicePcmTap.enable('call',41,(_t,bytes)=>taps.push(bytes));
  const start=c.start();await settle();const r=f.capturers[0];
  r.data(pcm(1111));r.data(pcm(2222));await settle();
  assert.equal(taps.length,0);assert.equal(f.events.length,0);assert.equal(f.api.includes('overflow'),false);
  opened.resolve();await start;await settle();
  assert.deepEqual(taps.map(b=>new DataView(b.buffer).getInt16(0,true)),[1111,2222]);
  assert.equal(f.api.includes('overflow'),true);assert.equal(f.events.filter(e=>e.type==='micLevel').length,1);
  await c.stop();
});

test('pending start failure or start-time overflow never leaks provisional PCM', async () => {
  for(const failure of ['start','overflow']){
    const opened=deferred(),f=captureFixture({start:()=>opened.promise,overflow:failure==='overflow'?1:0});
    const c=f.make(),{VoicePcmTap}=f.load('VoicePcmTap'),taps=[];VoicePcmTap.enable('call',42,(_t,b)=>taps.push(b));
    const start=c.start();await settle();f.capturers[0].data(pcm(3333));await settle();assert.equal(taps.length,0);
    if(failure==='start'){opened.reject(Error('start failed'));await assert.rejects(start);}
    else {opened.resolve();await start;await settle();assert.deepEqual(f.events,[{type:'callError',reason:'capture'}]);}
    await c.stop();await settle();assert.equal(taps.length,0);assert.equal(f.released,1);
  }
});

test('release failure holds the physical reservation and explicit stop retries', async () => {
  let attempts=0;const f=captureFixture({release(){if(++attempts===1)throw Error('release failed');}}),c=f.make();
  await c.start();await assert.rejects(c.stop());assert.equal(f.released,0);
  await c.stop();assert.equal(f.released,1);assert.equal(attempts,2);
});

test('interrupt and malformed read fail explicitly, not partial successful WAV', async () => {
  for(const action of [r=>r.interrupt(),r=>r.data(new Uint8Array(3)),r=>r.data(new Uint8Array(65538))]) {
    const f=captureFixture(),c=f.make();await c.start();action(f.capturers[0]);await settle();
    assert.deepEqual(f.events.filter(e=>e.type==='callError'),[{type:'callError',reason:'capture'}]);
    assert.equal(f.events.filter(e=>e.type==='utterance').length,0);await c.stop();
  }
});

test('PCM tap replacement is identity-bound and recorder reframe drops old partial', async () => {
  const f=captureFixture(),{VoicePcmTap,VoicePcmFrames}=f.load('VoicePcmTap'),frames=new VoicePcmFrames('dictation');
  const a=[],b=[],old=VoicePcmTap.enable('dictation',3,(_t,bytes)=>a.push(bytes));
  frames.append(pcm(123).subarray(0,320),()=>true);
  const next=VoicePcmTap.enable('dictation',3,(_t,bytes)=>b.push(bytes));
  VoicePcmTap.clear(old);assert.equal(VoicePcmTap.current('dictation'),next);
  frames.append(pcm(456),()=>true);frames.flush();await settle();assert.equal(a.length,0);assert.equal(b.length,1);
  assert.equal(new DataView(b[0].buffer).getInt16(0,true),456);
});

test('110 second hard bound produces one complete bounded WAV without a pause', async () => {
  const f=captureFixture(),c=f.make();await c.start();const r=f.capturers[0];
  for(let i=0;i<20;i++){r.data(pcm(0));await settle();}
  for(let i=0;i<5500;i++){r.data(pcm(10000));await settle();}
  const utterances=f.events.filter(e=>e.type==='utterance');assert.equal(utterances.length,1);
  assert.equal(utterances[0].ms,110000);assert.equal(utterances[0].wav.length,3520044);
  await c.stop();
});

test('SDK overflow is explicit capture failure before returning any audio', async () => {
  const options={overflow:0},f=captureFixture(options),c=f.make();await c.start();
  const {VoicePcmTap}=f.load('VoicePcmTap'),taps=[];
  VoicePcmTap.enable('call',9,(_t,bytes)=>taps.push(bytes));
  options.overflow=1;f.capturers[0].data(pcm(10000));await settle();
  assert.deepEqual(f.events,[{type:'callError',reason:'capture'}]);assert.equal(f.released,1);assert.equal(taps.length,0);
});

test('bargeIn=false ignores playback speech; stopping playback restores ordinary gate', async () => {
  const f=captureFixture(),c=f.make();c.bargeIn=false;await c.start();const r=f.capturers[0];
  c.setPlaying(true);
  for(let i=0;i<35;i++){r.data(pcm(20000));await settle();}
  for(let i=0;i<50;i++){r.data(pcm(0));await settle();}
  assert.equal(f.events.some(e=>e.type==='speechStart'||e.type==='utterance'),false);
  c.setPlaying(false);for(let i=0;i<6;i++){r.data(pcm(10000));await settle();}
  assert.equal(f.events.filter(e=>e.type==='speechStart').length,1);await c.stop();
});

test('mute/resume/stop send session-bound reset without silence PCM or stale owner reset', async () => {
  const f=captureFixture(),c=f.make(),{VoicePcmTap}=f.load('VoicePcmTap'),reset=[],bytes=[];
  VoicePcmTap.enable('call',7,(_t,frame)=>bytes.push(frame),(tap,reason)=>reset.push([tap.source,tap.id,reason]));
  await c.start();f.capturers[0].data(pcm(10000));c.muted=true;await settle();
  assert.equal(bytes.length,0);c.muted=false;await settle();await c.stop();await settle();
  assert.deepEqual(reset,[['call',7,'muted'],['call',7,'resumed'],['call',7,'stopped']]);
  const next=VoicePcmTap.enable('call',8,()=>{},(_t,reason)=>reset.push(reason));
  c.muted=true;await c.stop();await settle();assert.equal(reset.length,3);assert.equal(VoicePcmTap.current('call'),next);
});
