import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { join } from 'node:path';
import { mediaFixture,deferred,until,key } from './native-media-fixture.mjs';
const call=(f,method,args={})=>f.call(f.methods,method,{...key,...args});
const activate=async f=>assert.deepEqual(await call(f,'activate').done,{value:null});
async function play(f,extra={}){const path=await f.clip();const reply=await call(f,'play',{privatePath:path,contentType:'audio/wav',...extra}).done;return{path,reply};}
async function playing(f){await activate(f);assert.equal((await play(f)).reply.value,null);await until(()=>f.players.at(-1)?.state==='playing');return f.players.at(-1);}
async function dispose(f){const reply=await call(f,'disposeOwner').done;assert.equal(reply.value,null,JSON.stringify(reply));assert.equal(f.fds.size,0);}

test('capability and activation do not open files, map native host or allocate AVPlayer',async t=>{
 const f=await mediaFixture(t);assert.deepEqual(await call(f,'capabilities').done,{value:{features:['audio']}});await activate(f);assert.equal(f.operations.length,0);
 f.change({supported:false});assert.deepEqual(await call(f,'capabilities').done,{value:{features:[]}});await dispose(f);
});
test('activation requires foreground and exact owner generation lease shapes',async t=>{
 const f=await mediaFixture(t);for(const input of [{owner:'bad'},{generation:1.5},{generation:-1},{lease:''},{lease:'x'.repeat(257)}])assert.equal((await call(f,'activate',input).done).error,'bad-request');
 f.background();assert.equal((await call(f,'activate').done).error,'not-foreground');assert.equal(f.operations.length,0);
});
test('voice needs the real indicator integration and overlay remains unsupported',async t=>{
 const f=await mediaFixture(t);await activate(f);
 assert.equal((await call(f,'startVoice').done).error,'indicator');
 assert.equal((await call(f,'stopVoice').done).value,null);
 for(const name of ['showOverlay','updateOverlay','hideOverlay'])assert.equal((await call(f,name).done).error,'unsupported');
 assert.equal(f.operations.length,0);await dispose(f);
});
test('play only accepts exact owner cache clip and allowlisted MIME before opener',async t=>{
 const f=await mediaFixture(t);await activate(f);const path=await f.clip();
 for(const input of [{privatePath:'https://host/clip'},{privatePath:join(f.context.tempDir,'native-media',key.owner,'clip')},{privatePath:path+'/../clip'},
  {privatePath:path.replace(key.owner,'b'.repeat(48))},{contentType:'video/mp4'},{contentType:'audio/wav; charset=utf-8'}])assert.equal((await call(f,'play',{privatePath:path,contentType:'audio/wav',...input}).done).error,'media-invalid');
 assert.equal(f.operations.length,0);await dispose(f);
});
test('actual openat helper rejects final/parent symlinks and empty/oversized clips',async t=>{
 const f=await mediaFixture(t);await activate(f);let path=await f.clip(key.owner,Buffer.alloc(0));assert.equal((await call(f,'play',{privatePath:path,contentType:'audio/wav'}).done).error,'media-invalid');assert.equal(f.fds.size,0);
 await fs.writeFile(path,Buffer.alloc(16*1024*1024+1));assert.equal((await call(f,'play',{privatePath:path,contentType:'audio/wav'}).done).error,'media-invalid');assert.equal(f.fds.size,0);
 const outside=join(f.root,'outside');await fs.writeFile(outside,'secret');await fs.unlink(path);await fs.symlink(outside,path);
 assert((await call(f,'play',{privatePath:path,contentType:'audio/wav'}).done).error);assert.equal(f.players.length,0);assert.equal(f.fds.size,0);
 await fs.unlink(path);await fs.rmdir(join(f.context.cacheDir,'native-media',key.owner));await fs.symlink(f.root,join(f.context.cacheDir,'native-media',key.owner));
 assert((await call(f,'play',{privatePath:path,contentType:'audio/wav'}).done).error);assert.equal(f.fds.size,0);await dispose(f);
});
test('actual descriptor and bounded range survive source path replacement without reopening',async t=>{
 const f=await mediaFixture(t);await activate(f);const bytes=Buffer.from('original clip bytes'),path=await f.clip(key.owner,bytes);
 f.change({afterOpen:async()=>{await fs.rename(path,path+'.old');await fs.writeFile(path,'replaced');}});
 assert.equal((await call(f,'play',{privatePath:path,contentType:'audio/wav'}).done).value,null);await until(()=>f.players[0]?.state==='playing');
 assert.deepEqual(f.players[0].bytes,bytes);assert.deepEqual(f.players[0].source,{fd:[...f.fds][0],offset:0,length:bytes.length});
 assert.deepEqual(f.players[0].renderer,{usage:5,rendererFlags:0});assert.equal(f.players[0].interruptMode,1);await dispose(f);
});
test('completion is emitted only after player release and owned descriptor close',async t=>{
 const gate=deferred();const f=await mediaFixture(t,{release:async()=>gate.promise}),p=await playing(f);p.complete();await until(()=>p.releases===1);
 assert.equal(f.events.length,0);assert.equal(f.fds.size,1);gate.resolve();await until(()=>f.events.length===1);
 assert.deepEqual(f.events[0],{...key,kind:'audio.ended'});assert.equal(f.fds.size,0);assert(p.released);await dispose(f);
});
test('focus loss closes first, emits one stopped event and never auto-resumes',async t=>{
 const f=await mediaFixture(t),p=await playing(f);p.interrupt(2);p.interrupt(3);await until(()=>f.events.length===1);
 assert.equal(f.events[0].kind,'audio.stopped');assert.equal(f.events[0].reason,'interrupted');assert.equal(f.fds.size,0);
 p.late('initialized');p.late('completed');await new Promise(r=>setImmediate(r));assert.equal(p.plays,1);assert.equal(f.events.length,1);await dispose(f);
});
test('decoder error and completed race yields one terminal only after physical release',async t=>{
 const f=await mediaFixture(t),p=await playing(f);p.error();p.complete();await until(()=>f.events.length===1);assert.equal(f.events[0].kind,'audio.error');assert.equal(f.fds.size,0);await dispose(f);
});
test('stop during prepare waits for prepare then releases without any late play',async t=>{
 const gate=deferred();let preparing=false;const f=await mediaFixture(t,{prepare:async()=>{preparing=true;await gate.promise;}});await activate(f);const started=await play(f);assert.equal(started.reply.value,null);await until(()=>preparing);
 const stopping=call(f,'stop');await new Promise(r=>setImmediate(r));assert.equal(stopping.replies.length,0);assert.equal(f.fds.size,1);
 gate.resolve();assert.equal((await stopping.done).value,null);assert.equal(f.players[0].plays,0);assert.equal(f.fds.size,0);assert.equal(f.events.length,0);await dispose(f);
});
test('stop during native host opener retires late FD and does not allocate player',async t=>{
 const gate=deferred();let opening=false;const f=await mediaFixture(t,{beforeOpen:async()=>{opening=true;await gate.promise;}});await activate(f);const path=await f.clip();
 const started=call(f,'play',{privatePath:path,contentType:'audio/wav'});await until(()=>opening);const stopping=call(f,'stop');await new Promise(r=>setImmediate(r));assert.equal(stopping.replies.length,0);
 gate.resolve();assert.equal((await started.done).error,'stale-owner');assert.equal((await stopping.done).value,null);assert.equal(f.players.length,0);assert.equal(f.fds.size,0);await dispose(f);
});
test('stop during AVPlayer allocation closes late player and descriptor without source assignment',async t=>{
 const gate=deferred();let creating=false;const f=await mediaFixture(t,{create:async()=>{creating=true;await gate.promise;}});await activate(f);const path=await f.clip();
 const started=call(f,'play',{privatePath:path,contentType:'audio/wav'});await until(()=>creating);const stopping=call(f,'stop');gate.resolve();
 assert.equal((await started.done).error,'stale-owner');assert.equal((await stopping.done).value,null);assert.equal(f.players[0].source,undefined);assert(f.players[0].released);assert.equal(f.fds.size,0);await dispose(f);
});
test('pause before initialized keeps prepared clip silent until an explicit resume',async t=>{
 const f=await mediaFixture(t,{autoInitialize:false});await activate(f);assert.equal((await play(f)).reply.value,null);
 assert.equal((await call(f,'pause').done).value,null);f.players[0].stateEvent('initialized');await until(()=>f.players[0].state==='prepared');assert.equal(f.players[0].plays,0);
 assert.equal((await call(f,'resume').done).value,null);assert.equal(f.players[0].plays,1);assert.equal((await call(f,'pause').done).value,null);assert.equal(f.players[0].state,'paused');await dispose(f);
});
test('old owner triple cannot pause, stop or release a new current owner',async t=>{
 const f=await mediaFixture(t),p=await playing(f);for(const input of [{owner:'b'.repeat(48)},{generation:2},{lease:'another'}]){
  assert.equal((await call(f,'stop',input).done).error,'stale-owner');assert.equal((await call(f,'disposeOwner',input).done).value,null);
 }assert.equal(p.releases,0);assert.equal(f.fds.size,1);await dispose(f);
});
test('release failure never emits ended/stopped or claims disposal success and remains globally busy',async t=>{
 let fail=true;const f=await mediaFixture(t,{release:async()=>{if(fail)throw Error('release failed');}}),p=await playing(f);p.complete();await until(()=>f.streamErrors.length===1);
 assert.equal(f.events.length,0);assert.equal(f.fds.size,1);assert.equal((await call(f,'disposeOwner').done).error,'close');
 const other=f.attach();assert.equal((await f.call(other.methods,'activate',{...key,owner:'b'.repeat(48)}).done).value,null);
 const path=await f.clip('b'.repeat(48));assert.equal((await f.call(other.methods,'play',{...key,owner:'b'.repeat(48),privatePath:path,contentType:'audio/wav'}).done).error,'busy');assert.equal(f.players.length,1);
 fail=false;await dispose(f);assert(p.released);assert.equal(f.fds.size,0);
});
test('FD close failure preserves only FD and retry does not release AVPlayer twice',async t=>{
 let fail=true;const f=await mediaFixture(t,{close:async()=>{if(fail)throw Error('close failed');}}),p=await playing(f);
 assert.equal((await call(f,'stop').done).error,'close');assert.equal(p.releases,1);assert.equal(f.fds.size,1);fail=false;
 assert.equal((await call(f,'stop').done).value,null);assert.equal(p.releases,1);assert.equal(f.fds.size,0);await dispose(f);
});
test('background retires immediately, completes revocation only after physical release',async t=>{
 const gate=deferred();const f=await mediaFixture(t,{release:async()=>gate.promise}),p=await playing(f);f.background();await until(()=>p.releases===1);
 assert.equal((await call(f,'resume').done).error,'stale-owner');assert.equal(f.events.length,0);gate.resolve();await until(()=>f.events.length===1);
 assert.deepEqual(f.events[0],{...key,kind:'owner.revoked',reason:'background'});assert.equal(f.fds.size,0);
});
test('stream cancellation closes local resources even with no event sink',async t=>{
 const f=await mediaFixture(t),p=await playing(f);f.stream.handler.onCancel(null);await until(()=>f.fds.size===0);assert(p.released);assert.equal(f.events.length,0);
});
test('late detach and old event listener cannot retire new engine owner',async t=>{
 const f=await mediaFixture(t),old=f.engine,stream=f.stream;const next=f.attach(f.plugin);assert.equal((await f.call(next.methods,'activate',key).done).value,null);
 const path=await f.clip();assert.equal((await f.call(next.methods,'play',{...key,privatePath:path,contentType:'audio/wav'}).done).value,null);await until(()=>f.players[0]?.state==='playing');
 f.plugin.onDetachedFromEngine(old);stream.handler.onCancel(null);assert.equal(f.players[0].releases,0);assert.equal(f.fds.size,1);
 assert.equal((await f.call(next.methods,'disposeOwner',key).done).value,null);assert.equal(f.fds.size,0);
});
test('stop supersedes a replacement play that is still waiting for the old clip close',async t=>{
 const gate=deferred();const f=await mediaFixture(t),p=await playing(f);f.change({release:async()=>gate.promise});const path=await f.clip();
 const replacement=call(f,'play',{privatePath:path,contentType:'audio/wav'});await until(()=>p.releases===1);const stopping=call(f,'stop');gate.resolve();
 assert.equal((await replacement.done).error,'stale-owner');assert.equal((await stopping.done).value,null);assert.equal(f.players.length,1);assert.equal(f.fds.size,0);await dispose(f);
});
test('subscription failure and unavailable factory close actual descriptor without terminal fiction',async t=>{
 const f=await mediaFixture(t,{onFailure:'error'});await activate(f);assert((await play(f)).reply.error);assert(f.players[0].released);assert.equal(f.fds.size,0);
 f.change({onFailure:null,undefinedPlayer:true});assert.equal((await play(f)).reply.error,'unsupported');assert.equal(f.fds.size,0);await dispose(f);
});
test('event stream cancellation during owner replacement cannot authorize later playback',async t=>{
 const gate=deferred();const f=await mediaFixture(t),p=await playing(f);f.change({release:async()=>gate.promise});
 const second={owner:'b'.repeat(48),generation:2,lease:'new-lease'};
 const activation=call(f,'activate',second);await until(()=>p.releases===1);f.stream.handler.onCancel(null);gate.resolve();
 assert.equal((await activation.done).error,'stale-owner');
 const path=await f.clip(second.owner);assert.equal((await call(f,'play',{...second,privatePath:path,contentType:'audio/wav'}).done).error,'stale-owner');
 assert.equal(f.players.length,1);assert.equal(f.fds.size,0);
});
test('actual pinned path_provider and media agree on UIAbility cache even when ApplicationContext differs',async t=>{
 const f=await mediaFixture(t);const path=await f.providerTemporaryDirectory(f.engine,f.ability);
 assert.equal(path,f.context.cacheDir);assert.notEqual(path,f.applicationContext.cacheDir);await activate(f);
 const clip=await f.clip();assert.equal((await call(f,'play',{privatePath:clip,contentType:'audio/wav'}).done).value,null);
 assert.equal(f.operations.find(x=>x.op==='opener').root,path);await dispose(f);
});
for(const failure of ['release','close'])test('new plugin recovers retired '+failure+' failure without an old method handler',async t=>{
 let fail=false,attempts=0;const f=await mediaFixture(t,{[failure]:async()=>{if(fail){attempts++;throw Error('transient '+failure);}}});
 const old=await playing(f);fail=true;f.plugin.onDetachedFromEngine(f.engine);await until(()=>attempts>0);await new Promise(r=>setImmediate(r));
 assert.equal(f.methods.handler,null);assert.equal(f.fds.size,1);fail=false;const next=f.attach();
 assert.equal((await f.call(next.methods,'activate',key).done).value,null);const path=await f.clip();
 assert.equal((await f.call(next.methods,'play',{...key,privatePath:path,contentType:'audio/wav'}).done).value,null);
 await until(()=>f.players.at(-1).state==='playing');assert(old.released);assert.equal(f.fds.size,1);
 assert.equal((await f.call(next.methods,'disposeOwner',key).done).value,null);assert.equal(f.fds.size,0);
});
test('two new plugins cannot overlap recovery or acquire the same retired playback lease',async t=>{
 let fail=false;const gate=deferred();let recovery=false;
 const f=await mediaFixture(t,{release:async()=>{if(fail)throw Error('first failure');if(recovery)await gate.promise;}}),old=await playing(f);
 fail=true;f.plugin.onDetachedFromEngine(f.engine);await until(()=>old.releases===1);await new Promise(r=>setImmediate(r));
 fail=false;recovery=true;const a=f.attach(),b=f.attach();await f.call(a.methods,'activate',key).done;await f.call(b.methods,'activate',key).done;const path=await f.clip();
 const first=f.call(a.methods,'play',{...key,privatePath:path,contentType:'audio/wav'});await until(()=>old.releases===2);
 const second=f.call(b.methods,'play',{...key,privatePath:path,contentType:'audio/wav'});await new Promise(r=>setImmediate(r));
 assert.equal(old.releases,2);assert.equal(f.players.length,1);gate.resolve();const replies=await Promise.all([first.done,second.done]);
 assert.equal(replies.filter(x=>!x.error).length,1);assert.equal(replies.filter(x=>x.error==='busy').length,1);assert.equal(f.players.length,2);
 await f.call(a.methods,'disposeOwner',key).done;await f.call(b.methods,'disposeOwner',key).done;assert.equal(f.fds.size,0);
});
test('cancel while awaiting a retired close cannot allocate a late replacement player',async t=>{
 const gate=deferred();let releaseStarted=false;const f=await mediaFixture(t,{release:async()=>{releaseStarted=true;await gate.promise;}});await playing(f);
 f.plugin.onDetachedFromEngine(f.engine);await until(()=>releaseStarted);const next=f.attach();await f.call(next.methods,'activate',key).done;const path=await f.clip();
 const started=f.call(next.methods,'play',{...key,privatePath:path,contentType:'audio/wav'});await new Promise(r=>setImmediate(r));
 const stopped=f.call(next.methods,'stop',key);gate.resolve();assert.equal((await started.done).error,'stale-owner');assert.equal((await stopped.done).value,null);
 assert.equal(f.players.length,1);assert.equal(f.fds.size,0);assert.equal(f.operations.filter(x=>x.op==='opener').length,1);
});

// Public native handler, explicitly granted SDK permission; this never starts a
// microphone and does not assert that the visible-stop UI has been integrated.
test('without a visible stop control voice is not offered and asks for no permission',async t=>{
 const f=await mediaFixture(t,{micGranted:true});await activate(f);
 assert.deepEqual((await call(f,'capabilities').done).value,{features:['audio']});
 assert.equal((await call(f,'requestVoiceGrant').done).error,'unsupported');
 assert.equal(f.operations.filter(x=>x.op==='mic-check'||x.op==='mic-request').length,0);await dispose(f);
});
test('foreground owned native media obtains the actual microphone grant without capture',async t=>{
 const f=await mediaFixture(t,{micGranted:true,indicator:true});await activate(f);let reply;
 try{reply=await call(f,'requestVoiceGrant').done;}finally{await dispose(f);}
 assert.equal(reply.value,true,JSON.stringify(reply));
 assert.equal(f.operations.filter(x=>x.op==='mic-check').length,1);
 assert.equal(f.operations.filter(x=>x.op==='mic-request').length,0);
 assert.equal(f.players.length,0);assert.equal(f.fds.size,0);
});

const grantVoice=async f=>assert.equal((await call(f,'requestVoiceGrant').done).value,true);
const startVoice=async f=>assert.equal((await call(f,'startVoice').done).value,null);
const micStart=(f,v,id=1)=>f.call(v.methods,'startRecorder',{sessionId:id,maxSeconds:1});
const micCancel=(f,v)=>f.call(v.methods,'cancel');
function pcmFrames(count,value=0){const bytes=Buffer.alloc(count*320*2);for(let i=0;i<bytes.length;i+=2)bytes.writeInt16LE(value,i);return bytes;}

test('supported integration still requires per-owner grant before capture',async t=>{
 const f=await mediaFixture(t,{indicator:true});await activate(f);
 assert.deepEqual((await call(f,'capabilities').done).value,{features:['audio','voice']});
 assert.equal((await call(f,'startVoice').done).error,'permission');
 assert.equal(f.capturers.length,0);assert.equal(f.indicators.length,0);await dispose(f);
});
test('ordinary dictation and plugin activity use the same physical lease',async t=>{
 const f=await mediaFixture(t,{indicator:true}),v=f.attachVoice();await activate(f);await grantVoice(f);
 assert.equal((await micStart(f,v).done).value,null);
 assert.equal((await call(f,'startVoice').done).error,'busy');assert.equal(f.capturers.length,1);
 assert.equal((await micCancel(f,v).done).value,null);await dispose(f);assert(f.capturers.every(c=>c.released));
});
test('dictation waits for actual plugin release before acquiring microphone',async t=>{
 const release=deferred(),f=await mediaFixture(t,{indicator:true,captureRelease:()=>release.promise}),v=f.attachVoice();
 await activate(f);await grantVoice(f);await startVoice(f);const dictation=micStart(f,v);
 await until(()=>f.operations.some(x=>x.op==='capture-release'));
 assert.equal(dictation.replies.length,0);assert.equal(f.capturers.length,1);
 release.resolve();assert.equal((await dictation.done).value,null);
 assert.equal(f.capturers.length,2);assert(f.capturers[0].released);
 assert(f.events.some(x=>x.kind==='owner.revoked'&&x.reason==='dictation'));
 assert.equal((await micCancel(f,v).done).value,null);assert(f.capturers.every(c=>c.released));
});
test('failed physical release blocks dictation until explicit original-owner close succeeds',async t=>{
 const f=await mediaFixture(t,{indicator:true,captureRelease:()=>{throw Error('release failed');}}),v=f.attachVoice();
 await activate(f);await grantVoice(f);await startVoice(f);
 assert((await micStart(f,v).done).error);assert.equal(f.capturers.length,1);assert(!f.capturers[0].released);
 f.change({captureRelease:undefined});await dispose(f);
 assert.equal((await micStart(f,v,2).done).value,null);assert.equal(f.capturers.length,2);
 assert.equal((await micCancel(f,v).done).value,null);assert(f.capturers.every(c=>c.released));
});
test('background while indicator mount is pending never opens microphone and hides late UI',async t=>{
 const shown=deferred(),f=await mediaFixture(t,{indicator:true,indicatorShow:()=>shown.promise}),v=f.attachVoice();
 await activate(f);await grantVoice(f);assert.equal((await play(f)).reply.value,null);const pending=call(f,'startVoice');
 await until(()=>f.indicators.some(x=>x.op==='show'));f.background();assert.equal(f.capturers.length,0);
 await until(()=>f.players[0].released&&f.fds.size===0);assert.equal(f.fds.size,0);
 assert.equal(pending.replies.length,0,'UI mount has not settled, but playback is already closed');
 shown.resolve();assert.equal((await pending.done).error,'stale-owner');
 await until(()=>f.indicators.some(x=>x.op==='hide'));
 assert.equal(f.capturers.length,0);assert.equal((await micStart(f,v).done).value,null);
 assert.equal((await micCancel(f,v).done).value,null);assert(f.capturers.every(c=>c.released));
});
test('late capturer allocation after disposal releases before another owner starts',async t=>{
 const creation=deferred(),f=await mediaFixture(t,{indicator:true,captureCreate:()=>creation.promise}),v=f.attachVoice();
 await activate(f);await grantVoice(f);const pending=call(f,'startVoice');
 await until(()=>f.operations.some(x=>x.op==='capture-create'));const closed=call(f,'disposeOwner');
 assert.equal(closed.replies.length,0);assert.equal(f.capturers.length,0);creation.resolve();
 assert((await pending.done).error);assert.equal((await closed.done).value,null);
 assert.equal(f.capturers.length,1);assert(f.capturers[0].released);
 assert(!f.operations.some(x=>x.op==='capture-start'));
 f.change({captureCreate:undefined});assert.equal((await micStart(f,v).done).value,null);
 assert.equal((await micCancel(f,v).done).value,null);assert(f.capturers.every(c=>c.released));
});
test('activity publishes localStopped only after actual player and FD release',async t=>{
 const release=deferred(),f=await mediaFixture(t,{indicator:true,release:()=>release.promise});
 await activate(f);await grantVoice(f);await startVoice(f);assert.equal((await play(f)).reply.value,null);
 const capture=f.capturers[0];capture.data(pcmFrames(35,10000));
 await until(()=>f.players[0].releases>0);
 assert(!f.events.some(x=>x.kind==='voice.speechStart'));assert.equal(f.fds.size,1);
 release.resolve();await until(()=>f.events.some(x=>x.kind==='voice.speechStart'));
 const starts=f.events.filter(x=>x.kind==='voice.speechStart');assert.equal(starts.length,1);assert.equal(starts[0].localStopped,true);
 assert(f.players[0].released);assert.equal(f.fds.size,0);
 capture.data(pcmFrames(35));await until(()=>f.events.some(x=>x.kind==='voice.speechEnd'));
 assert.equal(f.events.filter(x=>x.kind==='voice.speechEnd').length,1);await dispose(f);assert(capture.released);
});
test('visible stop callback retires only its actual current owner and does not restart',async t=>{
 const f=await mediaFixture(t,{indicator:true});await activate(f);await grantVoice(f);await startVoice(f);
 const visible=f.indicators.find(x=>x.op==='show');visible.stop();
 await until(()=>f.capturers[0].released&&f.events.some(x=>x.kind==='owner.revoked'));
 const count=f.events.length;f.capturers[0].data(pcmFrames(10,10000));await Promise.resolve();
 assert.equal(f.events.length,count);assert.equal(f.capturers.length,1);assert.equal(f.indicators.filter(x=>x.op==='hide').length,1);
});
