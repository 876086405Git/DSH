import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { voiceFixture, deferred, until } from './voice-fixture.mjs';

const start=(f,id=1,seconds=1)=>f.call(f.methods,'startRecorder',{sessionId:id,maxSeconds:seconds});
const recognize=(f,id=1,language)=>f.call(f.methods,'startRecognizer',{sessionId:id,language});
const call=(f,method,args)=>f.call(f.methods,method,args).done;
const ok=reply=>assert.equal(reply.error,undefined,JSON.stringify(reply));

test('missing speech module never blocks permissions or public recorder and reports recognizer unavailable on use', async()=>{
 const f=voiceFixture({kitFailure:true});assert(!f.calls.includes('loadSpeechKit'));
 assert.equal((await call(f,'requestPermission')).value,'granted');
 ok(await start(f).done);ok(await call(f,'cancel'));assert(!f.calls.includes('loadSpeechKit'));
 const caps=(await call(f,'capabilities')).value;assert.equal(caps.recognizer,false);assert.equal(caps.recorder,true);
 assert.equal(f.calls.filter(c=>c==='loadSpeechKit').length,1);assert.equal(f.engines.length,0);
 assert.equal((await recognize(f,2).done).details.code,5);assert.equal(f.engines.length,0);
 f.change({kitFailure:false});assert.equal((await call(f,'capabilities')).value.recognizer,true);
 assert.equal(f.calls.filter(c=>c==='loadSpeechKit').length,3);f.plugin.onDetachedFromEngine(f.engine);
});

test('pending speech module holds recognition admission but cancelled creation cannot start listening', async()=>{
 const gate=deferred(),f=voiceFixture({beforeKitLoad:()=>gate.promise});const pending=recognize(f);
 await until(()=>f.calls.includes('loadSpeechKit'));const cancel=f.call(f.methods,'cancel');
 assert.equal((await start(f,2).done).details.code,8);assert.equal(cancel.replies.length,0);
 gate.resolve();ok(await cancel.done);assert.equal((await pending.done).error,'cancelled');
 assert(f.engines.every(e=>e.started.length===0&&e.shutdowns===1));
});

test('actual channel contract; factory probe never requests permission or starts capture',async()=>{
 const f=voiceFixture();assert.deepEqual(f.channels.map(c=>c.name),['dsh/voice','dsh/voice/events']);
 const caps=await call(f,'capabilities');ok(caps);assert.equal(caps.value.recognizer,true);assert.equal(caps.value.recorder,true);
 assert.equal(caps.value.environmentId,null);assert.deepEqual([...caps.value.languages],['zh-CN']);
 assert.deepEqual(f.stats(),{asks:0,checks:0,settings:0});assert.equal(f.capturers.length,0);assert.equal(f.engines[0].started.length,0);
 assert.deepEqual(await call(f,'oldDownloadModel'),{missing:true});
});

test('unavailable HMS still advertises only public recorder, no fabricated environment identity',async()=>{
 const f=voiceFixture({createEngine:()=>{throw Error('kit unavailable');}});const c=(await call(f,'capabilities')).value;
 assert.equal(c.recognizer,false);assert.equal(c.recorder,true);assert.equal(c.environmentId,null);assert.equal(c.systemUnreliable,true);
 ok(await start(f).done);assert.equal(f.capturers.length,1);ok(await call(f,'cancel'));
});

test('real PCM bytes survive reused platform buffer; WAV header and payload match exactly',async()=>{
 const f=voiceFixture();ok(await start(f).done);const c=f.capturers[0];
 assert.equal(c.config.capturerInfo.source,10);assert.equal(c.config.streamInfo.samplingRate,16000);
 const pcm=Uint8Array.from([0,0,0xff,0x7f,0,0x80,0x34,0x12]);c.data(pcm);
 const response=await call(f,'stop');ok(response);const wav=Buffer.from(response.value);
 assert.equal(wav.subarray(0,4).toString(),'RIFF');assert.equal(wav.subarray(8,16).toString(),'WAVEfmt ');
 assert.equal(wav.readUInt32LE(4),44);assert.equal(wav.readUInt16LE(20),1);assert.equal(wav.readUInt16LE(22),1);
 assert.equal(wav.readUInt32LE(24),16000);assert.equal(wav.readUInt32LE(28),32000);assert.equal(wav.readUInt16LE(34),16);
 assert.equal(wav.readUInt32LE(40),pcm.length);assert.deepEqual(wav.subarray(44),Buffer.from(pcm));assert(c.released);
 if(process.env.OHOS_VOICE_WAV_OUTPUT)await fs.writeFile(process.env.OHOS_VOICE_WAV_OUTPUT,wav);
 assert.deepEqual(await call(f,'stop'),{value:null});
});

test('real pcm silence/limit/empty boundaries and memory length are bounded',async()=>{
 const f=voiceFixture();const p=new f.Pcm(1);p.append(new ArrayBuffer(32002));assert.equal(p.length,32000);assert(p.full);assert.equal(p.level,0);
 assert.equal(p.wav().byteLength,32044);p.discard();assert.equal(p.wav(),null);assert.throws(()=>new f.Pcm(601));
 ok(await start(f).done);assert.deepEqual(await call(f,'stop'),{value:null});
});

test('length limit releases native before limit and preserves PCM for later stop',async()=>{
 const f=voiceFixture();ok(await start(f).done);const c=f.capturers[0];c.data(new Uint8Array(32010));
 await until(()=>f.events.some(e=>e.type==='limit'));assert(c.released);assert.equal(f.events.filter(e=>e.type==='limit').length,1);
 const wav=(await call(f,'stop')).value;assert.equal(wav.length,32044);assert.equal(f.events.some(e=>e.type==='end'),false);
});

test('cancel during pending create blocks new engine until created resource actually releases',async()=>{
 const gate=deferred(),release=deferred();const f=voiceFixture({createAudio:()=>gate.promise,release:()=>release.promise});
 const first=start(f);await until(()=>f.calls.includes('createAudio'));const cancel=f.call(f.methods,'cancel');
 const newer=f.attach();assert.equal((await f.call(newer.methods,'startRecorder',{sessionId:2,maxSeconds:1}).done).details.code,8);
 assert.equal(cancel.replies.length,0);gate.resolve();await until(()=>f.capturers.length===1&&f.capturers[0].releases===1);
 assert.equal(f.capturers[0].started,false);assert.equal(cancel.replies.length,0);release.resolve();ok(await cancel.done);
 assert.equal((await first.done).error,'cancelled');
 ok(await f.call(newer.methods,'startRecorder',{sessionId:2,maxSeconds:1}).done);ok(await f.call(newer.methods,'cancel').done);
});

test('cancel during pending start retires data/events immediately and waits for physical stop/release',async()=>{
 const gate=deferred();const f=voiceFixture({start:()=>gate.promise});const first=start(f);await until(()=>f.calls.includes('start'));
 const c=f.capturers[0],cancel=f.call(f.methods,'cancel');c.data(new Uint8Array(20));await new Promise(r=>setImmediate(r));
 assert.equal(f.events.length,0);assert.equal(cancel.replies.length,0);gate.resolve();ok(await cancel.done);
 assert(c.released);assert.equal((await first.done).error,'cancelled');
});

test('stop waits for release and concurrent new start is busy',async()=>{
 const release=deferred();const f=voiceFixture({release:()=>release.promise});ok(await start(f).done);f.capturers[0].data(new Uint8Array(2));
 const stopped=f.call(f.methods,'stop');await until(()=>f.calls.includes('release'));
 assert.equal(stopped.replies.length,0);assert.equal((await start(f,2).done).details.code,8);release.resolve();ok(await stopped.done);
});

test('failed release does not free microphone lease; cancel retries real release',async()=>{
 const f=voiceFixture({release:()=>{throw Error('still active');}});ok(await start(f).done);
 assert.equal((await call(f,'cancel')).details.code,100);assert.equal((await start(f,2).done).details.code,8);
 f.change({release:undefined});ok(await call(f,'cancel'));assert.equal(f.capturers[0].releases,2);ok(await start(f,2).done);ok(await call(f,'cancel'));
});

test('wrong sample format, null factory and subscription failures release safely',async()=>{
 for(const settings of [{format:{samplingRate:48000}},{audioNull:true},{onFailure:'audioInterrupt'},{start:()=>{throw Error('start failed');}}]){
  const f=voiceFixture(settings);assert.equal((await start(f).done).details.code,100);
  assert(f.capturers.every(c=>c.released));assert.equal(f.capturers.some(c=>c.started),false);
 }
});

test('overflow, odd PCM and focus interruption fail instead of returning truncated WAV',async()=>{
 const a=voiceFixture({overflow:1});ok(await start(a).done);a.capturers[0].data(new Uint8Array(4));assert.equal((await call(a,'stop')).details.code,100);
 for(const input of ['odd','interrupt']){const f=voiceFixture();ok(await start(f).done);
  if(input==='odd')f.capturers[0].data(new Uint8Array(3));else f.capturers[0].interrupt(2);
  await until(()=>f.events.some(e=>e.type==='end'));assert.equal(f.events.find(e=>e.type==='error').code,100);assert(f.capturers[0].released);
 }
});

test('permission is checked on every start; missing grant does not create microphone',async()=>{
 const f=voiceFixture({granted:false});const r=await start(f).done;assert.equal(r.details.code,9);assert.equal(f.capturers.length,0);assert.equal(f.stats().asks,0);
 f.change({granted:true});ok(await start(f,2).done);ok(await call(f,'cancel'));assert.equal(f.stats().checks,2);
});

test('permission outcomes do not invent blocked when dialog metadata is absent',async()=>{
 for(const [result,expected] of [[{authResults:[0]},'granted'],[{authResults:[-1]},'denied'],[{authResults:[-1],dialogShownResults:[true]},'denied'],[{authResults:[-1],dialogShownResults:[false]},'blocked'],[{authResults:[2],dialogShownResults:[false]},'denied']]){
  const f=voiceFixture({granted:false,permissionResult:result});assert.equal((await call(f,'requestPermission')).value,expected);
 }
});

test('permission dialog lease survives engine detach and does not open a second physical dialog',async()=>{
 const gate=deferred(),f=voiceFixture({granted:false,request:()=>gate.promise});const old=f.call(f.methods,'requestPermission');
 await until(()=>f.stats().asks===1);f.plugin.onDetachedFromEngine(f.engine);const next=f.attach();
 assert.equal((await f.call(next.methods,'requestPermission').done).details.code,8);assert.equal(f.stats().asks,1);
 gate.resolve({authResults:[0]});assert.equal((await old.done).value,'denied');
});

test('explicit settings uses public permission setting API; capability query never opens it',async()=>{
 const f=voiceFixture({granted:false});ok(await call(f,'openSettings'));assert.equal(f.stats().settings,1);assert.equal(f.stats().asks,0);
});

for(const method of ['requestPermission','openSettings'])test(method+' rechecks foreground after pending permission check; live foreground remains usable',async()=>{
 for(const background of [false,true]){
  const gate=deferred(),f=voiceFixture({granted:false,check:()=>gate.promise});
  const request=f.call(f.methods,method);await until(()=>f.stats().checks===1);if(background)f.background();gate.resolve();
  ok(await request.done);assert.equal(method==='requestPermission'?f.stats().asks:f.stats().settings,background?0:1);
  assert.equal(request.replies.length,1);
 }
});

test('permission UI gate uses actual current owner and foreground, not a blanket lifecycle generation',async()=>{
 for(const method of ['requestPermission','openSettings']){
  const gate=deferred(),f=voiceFixture({granted:false,check:()=>gate.promise});
  const request=f.call(f.methods,method);await until(()=>f.stats().checks===1);f.background();f.foreground();gate.resolve();
  ok(await request.done);assert.equal(method==='requestPermission'?f.stats().asks:f.stats().settings,1);
 }
});

test('engine or Ability replacement during permission check cannot open old permission UI',async()=>{
 for(const method of ['requestPermission','openSettings'])for(const replace of ['engine','ability']){
  const gate=deferred(),f=voiceFixture({granted:false,check:()=>gate.promise});
  const request=f.call(f.methods,method);await until(()=>f.stats().checks===1);
  if(replace==='engine')f.attach(f.plugin);
  else{const ui={context:f.ability.getAbility().context};f.plugin.onAttachedToAbility({getAbility:()=>ui});f.plugin.constructor.onForeground(ui);}
  gate.resolve();ok(await request.done);assert.equal(f.stats().asks,0);assert.equal(f.stats().settings,0);assert.equal(request.replies.length,1);
 }
});

test('recognizer exact zh-CN offline microphone options, result session gate, single final/end',async()=>{
 const f=voiceFixture();ok(await recognize(f,7).done);const e=f.engines[0],p=e.started[0];
 assert.equal(e.config.language,'zh-CN');assert.equal(e.config.online,1);assert.equal(e.config.extraParams.locate,'CN');
 assert.match(p.sessionId,/^[A-Za-z0-9_-]{1,63}$/);assert.equal(p.extraParams.recognitionMode,0);assert.equal(p.extraParams.maxAudioDuration,60000);
 assert.equal(p.extraParams.recognizerOption.enablePartialResult,true);assert.equal(p.audioInfo.sampleRate,16000);
 e.result('other',false,'wrong');e.result('中');e.result('中文',true);e.result('duplicate',true);e.complete();e.complete();
 assert.deepEqual(f.events.map(x=>[x.type,x.text,x.sessionId]),[['partial','中',7],['final','中文',7],['end',undefined,7]]);
 ok(await recognize(f,8).done);assert.equal(f.engines.length,1,'reuse singleton after completion');ok(await call(f,'cancel'));
});

test('explicit foreign language rejects before opening factory/microphone',async()=>{
 const f=voiceFixture();assert.equal((await recognize(f,1,'en-US').done).details.code,12);assert.equal(f.engines.length,0);assert.equal(f.stats().checks,0);
});

test('recognizer stop means finish, holds lease through final until complete',async()=>{
 const f=voiceFixture();ok(await recognize(f).done);const e=f.engines[0];
 assert.deepEqual(await call(f,'stop'),{value:null});assert.equal(e.finishes.length,1);e.result('完成',true);
 assert.equal((await start(f,2).done).details.code,8);e.complete();ok(await start(f,2).done);ok(await call(f,'cancel'));
});

test('completion without isLast returns latest hypothesis and end once',async()=>{
 const f=voiceFixture();ok(await recognize(f).done);const e=f.engines[0];e.result('假设',false);e.complete();
 assert.deepEqual(f.events.map(x=>x.type),['partial','final','end']);assert.equal(f.events[1].text,'假设');
});

test('recognizer cancel invalidates late callbacks before cancel/shutdown',async()=>{
 const f=voiceFixture({recognizerCancel:e=>{e.result('late',true);e.error(1002200011);e.complete();}});ok(await recognize(f).done);
 ok(await call(f,'cancel'));assert.equal(f.events.length,0);assert.equal(f.engines[0].shutdowns,1);ok(await start(f,2).done);ok(await call(f,'cancel'));
});

test('HMS asynchronous errors map permission/busy/other into actual Dart numeric categories',async()=>{
 for(const [code,expected] of [[1002200012,9],[1002200006,8],[1002200011,5]]){
  const f=voiceFixture();ok(await recognize(f).done);f.engines[0].error(code);await until(()=>f.events.some(x=>x.type==='end'));
  assert.equal(f.events.find(x=>x.type==='error').code,expected);assert.equal(f.engines[0].shutdowns,1);
 }
});

test('engine replacement and old detach never route old PCM/events into new subscription',async()=>{
 const f=voiceFixture();ok(await start(f).done);const c=f.capturers[0];const next=f.attach(f.plugin,false);
 f.plugin.onDetachedFromEngine(f.engine);assert.equal((await f.call(next.methods,'startRecorder',{sessionId:2,maxSeconds:1}).done).error,'no_ability');
 c.data(new Uint8Array(20));await until(()=>c.released);assert.equal(f.events.length,0);f.plugin.onAttachedToAbility(next.ability);next.foreground();
 ok(await f.call(next.methods,'startRecorder',{sessionId:2,maxSeconds:1}).done);ok(await f.call(next.methods,'cancel').done);
});

test('Ability detach and EventChannel cancel both retire capture and release microphone',async()=>{
 for(const kind of ['ability','stream']){const f=voiceFixture();ok(await start(f).done);const c=f.capturers[0];
  if(kind==='ability')f.plugin.onDetachedFromAbility();else f.stream.handler.onCancel(null);
  c.data(new Uint8Array(20));await until(()=>c.released);assert.equal(f.events.length,0);
 }
});

test('throwing transport does not leave an active recorder or send a second reply',async()=>{
 const f=voiceFixture({replyFailure:true,eventFailure:true});const begun=start(f);ok(await begun.done);
 f.capturers[0].data(new Uint8Array(4));const cancelled=f.call(f.methods,'cancel');ok(await cancelled.done);
 assert.equal(begun.replies.length,1);assert.equal(cancelled.replies.length,1);assert(f.capturers[0].released);
});

test('invalid session and duration fail before permission/native resources',async()=>{
 for(const args of [{sessionId:0,maxSeconds:1},{sessionId:NaN,maxSeconds:1},{sessionId:1,maxSeconds:Infinity},{sessionId:1,maxSeconds:'1'}]){
  const f=voiceFixture();assert.equal((await call(f,'startRecorder',args)).error,'arguments');assert.equal(f.stats().checks,0);assert.equal(f.capturers.length,0);
 }
});

test('a full callback before start resolves still returns bounded WAV after a real limit',async()=>{
 const gate=deferred();const f=voiceFixture({start:()=>gate.promise});const request=start(f);
 await until(()=>f.calls.includes('start'));f.capturers[0].data(new Uint8Array(32000));
 await new Promise(r=>setImmediate(r));assert.equal(f.capturers[0].releases,0);gate.resolve();
 ok(await request.done);await until(()=>f.events.some(e=>e.type==='limit'));
 assert.equal((await call(f,'stop')).value.length,32044);
});

test('failed setListener plus failed shutdown does not create overlapping HMS engines on repeated probes',async()=>{
 const f=voiceFixture({listenerFailure:true,shutdown:()=>{throw Error('native still allocated');}});
 assert.equal((await call(f,'capabilities')).value.recognizer,false);
 assert.equal((await call(f,'capabilities')).value.recognizer,false);assert.equal(f.engines.length,1);
});

test('late granted permission check from a retired engine does not claim a current grant',async()=>{
 const gate=deferred();const f=voiceFixture({check:()=>gate.promise});const request=f.call(f.methods,'requestPermission');
 await until(()=>f.stats().checks===1);f.plugin.onDetachedFromEngine(f.engine);f.attach();gate.resolve();
 assert.equal((await request.done).value,'denied');assert.equal(f.stats().asks,0);
});

test('completion synchronously delivered from start is a completed session, not a start cancellation error',async()=>{
 const f=voiceFixture({recognizerStart:(e,p)=>{e.result('同步完成',true,p.sessionId);e.complete(p.sessionId);}});
 ok(await recognize(f).done);assert.deepEqual(f.events.map(e=>e.type),['final','end']);
});

test('pending HMS creation cancellation cannot release microphone lease early',async()=>{
 const gate=deferred(),f=voiceFixture({createEngine:()=>gate.promise});const request=recognize(f);
 await until(()=>f.calls.includes('createEngine'));const cancelled=f.call(f.methods,'cancel');
 assert.equal((await start(f,2).done).details.code,8);assert.equal(cancelled.replies.length,0);gate.resolve();
 ok(await cancelled.done);assert.equal((await request.done).error,'cancelled');assert.equal(f.engines[0].started.length,0);assert.equal(f.engines[0].shutdowns,1);
});

test('failed HMS shutdown blocks subsequent capture until successful cleanup retry',async()=>{
 const f=voiceFixture({shutdown:()=>{throw Error('not released');}});ok(await recognize(f).done);
 assert.equal((await call(f,'cancel')).details.code,5);assert.equal((await start(f,2).done).details.code,8);
 f.change({shutdown:undefined});ok(await call(f,'cancel'));assert.equal(f.engines[0].shutdowns,2);ok(await start(f,2).done);ok(await call(f,'cancel'));
});

test('real Ability background gate retires pending capture, prevents restart, and ignores stale Ability events',async()=>{
 const f=voiceFixture();ok(await start(f).done);f.background();await until(()=>f.capturers[0].released);
 assert.equal((await start(f,2).done).error,'no_ability');assert.equal((await call(f,'requestPermission')).error,'no_ability');
 f.foreground();ok(await start(f,2).done);ok(await call(f,'cancel'));
 const next=f.attach();f.background();ok(await f.call(next.methods,'startRecorder',{sessionId:3,maxSeconds:1}).done);
 ok(await f.call(next.methods,'cancel').done);
});

test('synchronous HMS failures use the same Dart numeric mapping and still release resources',async()=>{
 for(const [code,expected] of [[1002200012,9],[1002200006,8],[1002200011,5]]){
  const f=voiceFixture({recognizerStart:()=>{const e=Error('private service detail');e.code=code;throw e;}});
  assert.equal((await recognize(f).done).details.code,expected);assert.equal(f.engines[0].shutdowns,1);
  ok(await start(f,2).done);ok(await call(f,'cancel'));
 }
});
