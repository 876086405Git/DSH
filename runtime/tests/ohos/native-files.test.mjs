import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { filesFixture,deferred,until,args,owner } from './native-files-fixture.mjs';
const call=(f,method,input={})=>f.call(f.methods,method,input);
async function picked(f,files,options={}){const result=call(f,'pick',args(options));f.select(files.map(v=>v.uri));const reply=await result.done;assert(!reply.error,JSON.stringify(reply));return reply.value;}
const read=(f,entry,who=owner)=>call(f,'read',{owner:who,handle:entry.handle}).done;
async function cancel(f){await call(f,'cancel',{owner}).done;await until(()=>f.fds.size===0,'all descriptors closed');}

test('capabilities queries no picker, descriptor or storage',async t=>{
 const f=await filesFixture(t);assert.deepEqual(await call(f,'capabilities').done,{value:{files:true}});assert.equal(f.operations.length,0);assert.equal(f.pickers.length,0);
 f.change({missingCaps:['SystemCapability.FileManagement.UserFileService']});assert.equal((await call(f,'capabilities').done).value.files,false);
});
test('foreground and explicit user gesture gate selection before UI work',async t=>{
 const f=await filesFixture(t);f.background();assert.equal((await call(f,'pick',args()).done).error,'unavailable');
 f.foreground();assert.equal((await call(f,'pick',args({userGesture:false})).done).error,'unavailable');assert.equal(f.pickers.length,0);
});
test('owners and exact Android hard budgets reject invalid data',async t=>{
 const f=await filesFixture(t);
 for(const extra of [{owner:'short'},{maxFiles:5},{maxFiles:1.5},{maxBytes:0},{maxBytes:8*1024*1024+1},{maxTotalBytes:16*1024*1024+1},
  {own:true,maxFiles:2},{own:true,maxFiles:1,maxBytes:30*1024*1024+1}])assert.equal((await call(f,'pick',args(extra)).done).error,'invalid');
 assert.equal(f.pickers.length,0);
 const p=call(f,'pick',args({own:true,maxFiles:1,maxBytes:30*1024*1024,maxTotalBytes:30*1024*1024}));f.select([]);assert.equal((await p.done).value,null);
});
test('document selection preserves unknown size and performs zero IO in picker callback',async t=>{
 const f=await filesFixture(t),file=await f.file('中文 文件.txt','hello');const entries=await picked(f,[file]);
 assert.equal(f.pickers[0].kind,'document');assert.equal(f.pickers[0].options.maxSelectNumber,4);assert.equal(entries[0].name,'中文 文件.txt');
 assert.equal(entries[0].mediaType,'text/plain');assert.equal(entries[0].bytes,null);assert.equal(f.operations.length,0);await cancel(f);
});
test('photos and app visual requests use exact system MIME options without opening result URI',async t=>{
 const f=await filesFixture(t),file=await f.file('相片.jpg','photo','media');
 await picked(f,[file],{images:true,maxFiles:1});assert.deepEqual(f.pickers[0].options,{maxSelectNumber:1,MIMEType:'image/*'});assert.equal(f.operations.length,0);await cancel(f);
 await picked(f,[file],{visual:true,own:true,maxFiles:1,maxBytes:30*1024*1024,maxTotalBytes:30*1024*1024});assert.equal(f.pickers[1].options.MIMEType,'*/*');await cancel(f);
});
test('missing photo capability does not silently issue a broader picker',async t=>{
 const f=await filesFixture(t,{missingCaps:['SystemCapability.FileManagement.PhotoAccessHelper.Core']});
 assert.equal((await call(f,'pick',args({images:true})).done).error,'unavailable');assert.equal(f.pickers.length,0);
});
test('count overflow is rejected before URI processing or descriptor work',async t=>{
 const f=await filesFixture(t),p=call(f,'pick',args({maxFiles:1}));f.select(['file://docs/a','file://docs/b']);assert.equal((await p.done).error,'too-large');assert.equal(f.operations.length,0);
});
test('only system docs/media URI authorities survive policy; duplicates and encoded escapes fail',async t=>{
 const f=await filesFixture(t);const invalid=['/tmp/secret','file:///tmp/secret','file://bundle/data/file','https://host/file',
  'file://docs/a?x=1','file://docs/a#x','file://docs/a/%2e%2e/b','file://docs/a/%2Ftmp','file://media/a/%5cfile',
  'file://docs/a/%00b','file://docs/a/%zz','file://docs\\evil/a'];
 for(const value of invalid)assert.throws(()=>f.policy.nativeFileUris([value],1));
 assert.throws(()=>f.policy.nativeFileUris(['file://docs/a','file://docs/a'],2));
 assert.deepEqual(Array.from(f.policy.nativeFileUris(['file://media/Photo/1/图片.jpg'],1)),['file://media/Photo/1/图片.jpg']);
});
test('metadata names and MIME are bounded and controls stripped',async t=>{
 const f=await filesFixture(t);assert.equal(f.policy.nativeFileName('path\\x\nname'),'xname');assert.equal(f.policy.nativeFileName('..'),'file');
 assert.equal([...f.policy.nativeFileName('图'.repeat(300))].length,128);assert.equal(f.policy.nativeFileMime('text/plain'),'text/plain');
 assert.equal(f.policy.nativeFileMime('text/plain\nprivate'),'application/octet-stream');
});
test('real files stream in bounded chunks, survive short reads and close at EOF',async t=>{
 const f=await filesFixture(t,{maxRead:7319}),bytes=Buffer.alloc(200001);for(let i=0;i<bytes.length;i++)bytes[i]=i%251;
 const file=await f.file('data.bin',bytes),[entry]=await picked(f,[file]);const chunks=[];
 while(true){const reply=await read(f,entry);assert(!reply.error,JSON.stringify(reply));if(reply.value===null)break;assert(reply.value.length>0&&reply.value.length<=65536);chunks.push(Buffer.from(reply.value));}
 assert.deepEqual(Buffer.concat(chunks),bytes);assert.equal(f.fds.size,0);assert.equal((await read(f,entry)).value,null);await cancel(f);
});
test('exact cap performs one extra-byte EOF probe, never returns empty byte array',async t=>{
 const f=await filesFixture(t),file=await f.file('exact',Buffer.alloc(10,3)),[entry]=await picked(f,[file],{maxBytes:10,maxTotalBytes:10});
 assert.equal((await read(f,entry)).value.length,10);assert.equal((await read(f,entry)).value,null);
 assert.deepEqual(f.operations.filter(x=>x.op==='read').map(x=>x.length),[11,1]);await cancel(f);
});
test('lying size is bounded by actual bytes and the overshoot byte is not disclosed',async t=>{
 const f=await filesFixture(t,{statSize:3,maxRead:3}),file=await f.file('lie','abcd'),[entry]=await picked(f,[file],{maxBytes:3,maxTotalBytes:3});
 assert.equal(Buffer.from((await read(f,entry)).value).toString(),'abc');assert.equal((await read(f,entry)).error,'too-large');await until(()=>f.fds.size===0);
});
test('total budget spans all selected handles and rejects growth beyond total',async t=>{
 const f=await filesFixture(t,{statSize:1,maxRead:3}),a=await f.file('a','abc'),b=await f.file('b','def'),entries=await picked(f,[a,b],{maxBytes:4,maxTotalBytes:5});
 assert.equal((await read(f,entries[0])).value.length,3);assert.equal((await read(f,entries[1])).error,'too-large');await until(()=>f.fds.size===0);
});
test('known stat size rejects oversized file before reading, directories and FIFO are rejected',async t=>{
 const f=await filesFixture(t),file=await f.file('large','12345'),[entry]=await picked(f,[file],{maxBytes:4});assert.equal((await read(f,entry)).error,'too-large');
 await until(()=>f.fds.size===0);assert.equal(f.operations.filter(x=>x.op==='read').length,0);
 const dir=await f.file('directory','');await fs.unlink(dir.path);await fs.mkdir(dir.path);const [d]=await picked(f,[dir]);assert.equal((await read(f,d)).error,'invalid');await until(()=>f.fds.size===0);
 const fifo=await f.file('fifo','');assert(process.env.OHOS_NATIVE_FIFO);f.uris.set(fifo.uri,process.env.OHOS_NATIVE_FIFO);
 const [pipe]=await picked(f,[fifo]);assert.equal((await read(f,pipe)).error,'invalid');await until(()=>f.fds.size===0);
});
test('empty ordinary file returns null, without a zero-length chunk',async t=>{
 const f=await filesFixture(t),file=await f.file('empty',''),[entry]=await picked(f,[file]);assert.equal((await read(f,entry)).value,null);assert.equal(f.fds.size,0);await cancel(f);
});
test('read requires both current owner and unguessable handle, path arguments grant nothing',async t=>{
 const f=await filesFixture(t),file=await f.file('data','secret'),[entry]=await picked(f,[file]);assert.equal((await read(f,entry,'b'.repeat(32))).error,'cancelled');
 assert.equal((await call(f,'read',{owner,handle:file.uri,path:file.path}).done).error,'cancelled');assert.equal(f.operations.length,0);await cancel(f);
});
test('cancel pending picker completes Flutter once but keeps physical gate across engine replacement',async t=>{
 const f=await filesFixture(t),p=call(f,'pick',args());await call(f,'cancel',{owner}).done;assert.equal((await p.done).value,null);
 const next=f.attach();assert.equal((await f.call(next.methods,'pick',args()).done).error,'busy');f.select(['file://docs/ignored']);
 await until(()=>p.replies.length===1);await new Promise(r=>setImmediate(r));const q=f.call(next.methods,'pick',args());f.select([]);assert.equal((await q.done).value,null);assert.equal(p.replies.length,1);
});
test('cancel in-flight read withholds its bytes and keeps descriptor until operation actually returns',async t=>{
 const gate=deferred();let entered=false;const f=await filesFixture(t,{read:async()=>{entered=true;await gate.promise;}}),file=await f.file('data','secret'),[entry]=await picked(f,[file]);
 const pending=read(f,entry);await until(()=>entered);await call(f,'cancel',{owner}).done;assert.equal(f.fds.size,1);assert.equal((await call(f,'pick',args()).done).error,'busy');
 gate.resolve();assert.equal((await pending).error,'cancelled');await until(()=>f.fds.size===0);
});
test('cancel during open adopts late descriptor only to close it',async t=>{
 const gate=deferred();let entered=false;const f=await filesFixture(t,{open:async()=>{entered=true;await gate.promise;}}),file=await f.file('data','secret'),[entry]=await picked(f,[file]);
 const pending=read(f,entry);await until(()=>entered);await call(f,'cancel',{owner}).done;gate.resolve();assert.equal((await pending).error,'cancelled');await until(()=>f.fds.size===0&&f.operations.some(x=>x.op==='close'));
 assert.equal(f.operations.some(x=>x.op==='read'),false);
});
test('only one IO operation exists and extra reads fail busy without queuing',async t=>{
 const gate=deferred();let entered=false;const f=await filesFixture(t,{read:async()=>{entered=true;await gate.promise;}}),file=await f.file('data','x'),[entry]=await picked(f,[file]);
 const pending=read(f,entry);await until(()=>entered);assert.equal((await read(f,entry)).error,'busy');assert.equal(f.operations.filter(x=>x.op==='read').length,1);
 gate.resolve();assert.equal((await pending).value.length,1);f.change({read:null});await cancel(f);
});
test('physical close blocks new selection and close failure retains descriptor for explicit retry',async t=>{
 let fail=true;const f=await filesFixture(t,{close:async()=>{if(fail)throw Error('close failed');}}),file=await f.file('data','x'),[entry]=await picked(f,[file]);
 await read(f,entry);await call(f,'cancel',{owner}).done;await until(()=>f.operations.some(x=>x.op==='warning'));assert.equal(f.fds.size,1);
 assert.equal((await call(f,'pick',args()).done).error,'busy');fail=false;await call(f,'cancel',{owner}).done;await until(()=>f.fds.size===0);
 const p=call(f,'pick',args());f.select([]);assert.equal((await p.done).value,null);
});
test('fixed five-minute expiry revokes bytes and is not renewed by reads',async t=>{
 const f=await filesFixture(t),file=await f.file('data','x'),[entry]=await picked(f,[file]);assert.deepEqual([...f.timers.values()].map(x=>x.delay),[300000]);
 await read(f,entry);assert.equal(f.timers.size,1);f.expire();assert.equal((await read(f,entry)).error,'cancelled');await until(()=>f.fds.size===0);
});
test('late detach of replaced engine cannot revoke current engine selection',async t=>{
 const f=await filesFixture(t),old=f.engine;const next=f.attach(f.plugin);const file=await f.file('data','x');
 const p=f.call(next.methods,'pick',args());f.select([file.uri]);const entry=(await p.done).value[0];f.plugin.onDetachedFromEngine(old);
 assert.equal((await f.call(next.methods,'read',{owner,handle:entry.handle}).done).value.length,1);await f.call(next.methods,'cancel',{owner}).done;await until(()=>f.fds.size===0);
});
test('stat and invalid count failures close descriptors and do not leak partial data',async t=>{
 const f=await filesFixture(t,{stat:async()=>{throw Error('stat failed');}}),file=await f.file('data','x'),[entry]=await picked(f,[file]);assert.equal((await read(f,entry)).error,'failed');await until(()=>f.fds.size===0);
 f.change({stat:null,readCount:1.5});const [again]=await picked(f,[file]);assert.equal((await read(f,again)).error,'failed');await until(()=>f.fds.size===0);
});
test('retired result transport cannot interrupt revocation or duplicate a completion',async t=>{
 const f=await filesFixture(t),pending=call(f,'pick',args());f.change({replyFailure:true});
 assert.doesNotThrow(()=>call(f,'cancel',{owner}));assert.equal(pending.replies.length,1);f.change({replyFailure:false});
 f.select([]);await new Promise(r=>setImmediate(r));assert.equal(pending.replies.length,1);
 const next=call(f,'pick',args());f.select([]);assert.equal((await next.done).value,null);
});
test('new plugin can retry an idle retired physical lease after the old engine handler is gone',async t=>{
 let fail=false;const f=await filesFixture(t,{close:async()=>{if(fail)throw Error('transient close');}}),file=await f.file('数据.txt','abc'),[entry]=await picked(f,[file]);
 await read(f,entry);fail=true;f.plugin.onDetachedFromEngine(f.engine);await until(()=>f.operations.some(x=>x.op==='warning'));await new Promise(r=>setImmediate(r));
 assert.equal(f.methods.handler,null);assert.equal(f.fds.size,1);fail=false;const next=f.attach();
 assert.equal((await f.call(next.methods,'pick',args()).done).error,'busy');await until(()=>f.fds.size===0);
 assert.equal(f.pickers.length,1,'cleanup must not open a delayed picker');const pending=f.call(next.methods,'pick',args());f.select([]);
 assert.equal((await pending.done).value,null);assert.equal(f.fds.size,0);
});
test('new plugin cannot retry a retired close until the earlier attempt has finished',async t=>{
 const gate=deferred();const f=await filesFixture(t,{close:async()=>gate.promise}),file=await f.file('data','abc'),[entry]=await picked(f,[file]);
 await read(f,entry);f.plugin.onDetachedFromEngine(f.engine);await until(()=>f.operations.some(x=>x.op==='close'));
 const next=f.attach();for(let i=0;i<3;i++)assert.equal((await f.call(next.methods,'pick',args()).done).error,'busy');
 assert.equal(f.operations.filter(x=>x.op==='close').length,1);assert.equal(f.pickers.length,1);gate.resolve();await until(()=>f.fds.size===0);
 const pending=f.call(next.methods,'pick',args());f.select([]);assert.equal((await pending.done).value,null);
});
test('a new plugin retry that still cannot close reports busy and retains the real descriptor',async t=>{
 const f=await filesFixture(t),file=await f.file('data','abc'),[entry]=await picked(f,[file]);await read(f,entry);
 f.change({close:async()=>{throw Error('still failing');}});f.plugin.onDetachedFromEngine(f.engine);await until(()=>f.operations.some(x=>x.op==='warning'));await new Promise(r=>setImmediate(r));
 const next=f.attach();assert.equal((await f.call(next.methods,'pick',args()).done).error,'busy');
 await until(()=>f.operations.filter(x=>x.op==='warning').length===2);assert.equal(f.fds.size,1);assert.equal(f.pickers.length,1);
 f.change({close:null});assert.equal((await f.call(next.methods,'pick',args()).done).error,'busy');await until(()=>f.fds.size===0);
});
test('a new owner in the same engine can recover the retired prior owner without its token',async t=>{
 let fail=true;const f=await filesFixture(t,{close:async()=>{if(fail)throw Error('old owner close');}}),file=await f.file('data','abc'),[entry]=await picked(f,[file]);
 await read(f,entry);await call(f,'cancel',{owner}).done;await until(()=>f.operations.some(x=>x.op==='warning'));await new Promise(r=>setImmediate(r));
 fail=false;const next=args({owner:'b'.repeat(32)});assert.equal((await call(f,'pick',next).done).error,'busy');await until(()=>f.fds.size===0);
 const p=call(f,'pick',next);f.select([]);assert.equal((await p.done).value,null);
});
test('mismatched cancellation owner leaves the current grant intact',async t=>{
 const f=await filesFixture(t),file=await f.file('data','x'),[entry]=await picked(f,[file]);await call(f,'cancel',{owner:'b'.repeat(32)}).done;
 assert.equal((await read(f,entry)).value.length,1);await cancel(f);
});
