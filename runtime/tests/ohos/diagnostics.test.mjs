import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { join } from 'node:path';
import { diagnosticsFixture, deferred, until, plain, manifestFixture } from './diagnostics-fixture.mjs';

test('constructor, attach, facts and unknown method do not touch files or native host',async t => {
  const f=await diagnosticsFixture(t), i=f.attach();
  assert.deepEqual(f.operations,[]); assert.equal(plain(f.store.facts()).persistent,true);
  assert.deepEqual(await f.call(i,'unknown').done,{missing:true});assert.deepEqual(f.operations,[]);
  assert.deepEqual(await f.call(i,'engineLog').done,{value:[]});
  assert.deepEqual(f.operations.map(v=>v.op),['lstat']);await assert.rejects(fs.stat(f.directory),{code:'ENOENT'});
});

test('actual info uses OH facts, validated manifest and existing Dart section names',async t => {
  const manifest=manifestFixture();manifest.env={token:'not a diagnostic fact'};manifest.privatePath='/root/secrets';
  const f=await diagnosticsFixture(t,{manifest}),i=f.attach(),reply=await f.call(i,'info').done;
  assert.equal(reply.value.app.versionName,'1.2.fixture');assert.equal(reply.value.app.versionCode,42);
  assert.equal(reply.value.device.platform,'ohos');assert.equal(reply.value.device.apiVersion,26);
  assert.equal(reply.value.device.osVersion,'OpenHarmony fixture');assert.equal(reply.value.device.memoryMb,8192);
  assert.equal(reply.value.device.freeStorageMb,3072);assert.equal(reply.value.device.display.fontScale,1.25);
  assert.equal(reply.value.device.sdkInt,undefined);assert.equal(reply.value.device.android,undefined);
  assert.deepEqual(reply.value.manifest,{runtimeVersion:'fixture-runtime',dshVersion:'0.0.fixture',nodeVersion:'24.22.1',files:8,uncompressedBytes:116});
  assert.deepEqual(reply.value.voice,{});assert(!JSON.stringify(reply.value).includes('secrets'));
  assert(!f.operations.some(v=>['open','mkdir','write'].includes(v.op)));
  assert.deepEqual(f.operations.filter(v=>v.op==='resource').map(v=>v.name), ['dsh-runtime/runtime.zip']);
  assert.equal(f.operations.filter(v=>v.op==='raw-open').length,1);
  assert.equal(f.operations.filter(v=>v.op==='raw-close').length,1);
  assert.equal(f.fds.size,0);
  if(process.env.DIAGNOSTICS_CONSUMER_INPUT)await fs.writeFile(process.env.DIAGNOSTICS_CONSUMER_INPUT,JSON.stringify({info:reply.value,lines:['第一行','tail']}));
});

test('unavailable system facts and malformed manifest stay absent',async t => {
  const f=await diagnosticsFixture(t,{memoryError:true,displayError:true,bundle:()=>{throw Error('bundle');},free:()=>{throw Error('free');},manifest:{schema:99}}),i=f.attach();
  const value=(await f.call(i,'info').done).value;
  assert.equal(value.device.memoryMb,undefined);assert.equal(value.device.display,undefined);assert.equal(value.device.freeStorageMb,undefined);
  assert.equal(value.app.versionName,undefined);assert.deepEqual(value.manifest,{});assert.equal(value.device.platform,'ohos');
});

test('manifest uses the actual validator: bad paths and sizes never become facts',async t => {
  const f=await diagnosticsFixture(t),i=f.attach();
  for(const mutate of [m=>m.files.push({path:'../secret',size:1,sha256:'a'.repeat(64)}),m=>m.files[0].size=-1,
    m=>m.files[0].sha256='x',m=>m.runtimeVersion='v'.repeat(129)]) {
    const manifest=manifestFixture();mutate(manifest);f.change({manifest});assert.deepEqual((await f.call(i,'info').done).value.manifest,{});
  }
});

test('actual RuntimeLogs redaction precedes disk write and fresh module read',async t => {
  const f=await diagnosticsFixture(t);f.logs.rememberSecret('known-launch-secret');
  const entries=f.append(['ready http://localhost/?token=url-token&x=1','Authorization: Bearer credential','api_key=key-credential','raw known-launch-secret','普通日志']);
  await f.store.flush();const bytes=await f.disk();
  for(const secret of ['url-token','credential','key-credential','known-launch-secret'])assert(!bytes.includes(secret));
  assert.equal(bytes,entries.map(e=>e.line+'\n').join(''));assert.equal(f.fds.size,0);
  const next=f.reload();assert.deepEqual(Array.from(await next.store.tail(512*1024)),entries.map(e=>e.line));
  assert.equal(next.logs.snapshot(2000).entries.length,0);assert.equal(f.fds.size,0);
});

test('pending queue is bounded and omission marker describes dropped lines',async t => {
  const gate=deferred();let first=true;
  const f=await diagnosticsFixture(t,{write:async()=>{if(first){first=false;await gate.promise;}}});
  f.append(['in-flight']);await until(()=>f.operations.some(v=>v.op==='write'));
  const many=Array.from({length:100},(_,i)=>String(i).padStart(3,'0')+':'+ 'x'.repeat(8190));f.append(many);
  const facts=plain(f.store.facts());assert(facts.queuedBytes<=256*1024);assert(facts.omittedLines>0);
  gate.resolve();await f.store.flush();const lines=Array.from(await f.store.tail(1024*1024));
  assert.equal(lines[0],'in-flight');assert.equal(lines[1],`[OHOS host: ${facts.omittedLines} persistent log lines omitted]`);
  assert(lines.at(-1).startsWith('099:'));assert.equal(f.maxConcurrentIO(),1);assert.equal(f.fds.size,0);
});

test('read and write serialize on real descriptors while append is in flight',async t => {
  const gate=deferred();let first=true;const f=await diagnosticsFixture(t,{write:async()=>{if(first){first=false;await gate.promise;}}});
  f.append(['first']);await until(()=>f.operations.some(v=>v.op==='write'));
  const read=f.store.tail(1024);f.append(['second']);gate.resolve();
  assert.deepEqual(Array.from(await read),['first']);await f.store.flush();
  assert.deepEqual(Array.from(await f.store.tail(1024)),['first','second']);assert.equal(f.maxConcurrentIO(),1);assert.equal(f.fds.size,0);
});

test('two-file rotation remains bounded and returns chronological complete lines',async t => {
  const f=await diagnosticsFixture(t);let sequence=0;
  for(let batch=0;batch<10;batch++){f.append(Array.from({length:30},()=>String(sequence++).padStart(4,'0')+':'+ 'x'.repeat(7900)));await f.store.flush();}
  const current=await fs.stat(f.path),older=await fs.stat(f.path+'.1');assert(current.size<=1024*1024);assert(older.size<=1024*1024);
  assert(current.size+older.size<=2*1024*1024);assert(f.operations.some(v=>v.op==='rename'));
  const lines=Array.from(await f.store.tail(4*1024*1024));assert(lines.length>30);assert.equal(lines.at(-1).slice(0,4),'0299');
  for(let i=1;i<lines.length;i++)assert.equal(Number(lines[i].slice(0,4)),Number(lines[i-1].slice(0,4))+1);
  assert.equal(f.fds.size,0);
});

test('tail byte cap preserves whole UTF-8 lines and excludes incomplete suffix',async t => {
  const f=await diagnosticsFixture(t),lines=Array.from({length:20},(_,i)=>`${i}:`+'中💡'.repeat(40));f.append(lines);await f.store.flush();
  await fs.appendFile(f.path,'不完整尾');const result=Array.from(await f.store.tail(1024));
  assert(result.length>0);assert.equal(result.at(-1),lines.at(-1));assert(Buffer.byteLength(result.join('\n')+'\n')<=1024);
  assert(!result.some(v=>v.includes('\ufffd')||v.includes('不完整尾')));
  assert(f.operations.filter(v=>v.op==='read').every(v=>v.length<=65536));assert.equal(f.fds.size,0);
});

test('short writes and reads use actual counts without duplication or gaps',async t => {
  const f=await diagnosticsFixture(t,{maxWrite:7,maxRead:3});const lines=['hello','中文💡','last line'];f.append(lines);await f.store.flush();
  assert.equal(await f.disk(),lines.join('\n')+'\n');assert.deepEqual(Array.from(await f.store.tail(1024)),lines);assert.equal(f.fds.size,0);
});

test('restart drops only an incomplete old suffix before a new entry',async t => {
  const f=await diagnosticsFixture(t);await fs.mkdir(f.directory);await fs.writeFile(f.path,'complete\nunfinished');
  f.append(['next']);await f.store.flush();assert.equal(await f.disk(),'complete\nnext\n');assert.equal(f.fds.size,0);
});

test('write failure rolls back partial bytes and accounts for lost batch once',async t => {
  let writes=0;const f=await diagnosticsFixture(t);f.append(['committed']);await f.store.flush();
  f.change({maxWrite:4,write:()=>{if(++writes===2)throw Error('injected write failure');}});
  f.append(['must-not-survive']);await assert.rejects(f.store.flush());assert.equal(await f.disk(),'committed\n');assert.equal(f.fds.size,0);
  assert.equal(plain(f.store.facts()).omittedLines,1);f.change({write:undefined,maxWrite:undefined});f.append(['recovered']);await f.store.flush();
  assert.equal(await f.disk(),'committed\n[OHOS host: 1 persistent log lines omitted]\nrecovered\n');assert.equal(f.fds.size,0);
});

test('fsync and rollback failures retain ownership until a later exact cleanup succeeds',async t => {
  const f=await diagnosticsFixture(t,{fsync:()=>{throw Error('fsync');},truncate:()=>{throw Error('truncate');}});
  f.append(['uncommitted']);await assert.rejects(f.store.flush());assert.equal(f.fds.size,1);assert.equal(plain(f.store.facts()).error,'persistence_failed');
  f.change({fsync:undefined,truncate:undefined});const i=f.attach();assert.deepEqual(await f.call(i,'engineLog').done,{value:[]});assert.equal(f.fds.size,0);
  await f.store.flush();assert.equal(await f.disk(),'[OHOS host: 1 persistent log lines omitted]\n');assert.equal(f.fds.size,0);
});

test('close failure after fsync is recoverable across new plugin instance without duplicate write',async t => {
  const f=await diagnosticsFixture(t,{close:()=>{throw Error('close');}});f.append(['durably-written']);await assert.rejects(f.store.flush());
  assert.equal(f.fds.size,1);assert.equal(plain(f.store.facts()).omittedLines,0);assert.equal(await f.disk(),'durably-written\n');
  const old=f.attach();old.detach();f.change({close:undefined});const next=f.attach();
  assert.deepEqual(await f.call(next,'engineLog').done,{value:['durably-written']});await f.store.flush();assert.equal(f.fds.size,0);
  assert.equal(await f.disk(),'durably-written\n');
});

test('stat/read errors close the owned descriptor and do not return invented log lines',async t => {
  const f=await diagnosticsFixture(t);f.append(['existing']);await f.store.flush();
  for(const name of ['stat','read']) {f.change({[name]:()=>{throw Error(name);}});await assert.rejects(f.store.tail(1024));assert.equal(f.fds.size,0);f.change({[name]:undefined});}
  assert.deepEqual(Array.from(await f.store.tail(1024)),['existing']);
});

test('symlink, FIFO and directory in the final log slot are rejected without descriptor leak',async t => {
  const f=await diagnosticsFixture(t);await fs.mkdir(f.directory);const outside=join(f.root,'outside');await fs.writeFile(outside,'outside\n');
  for(const kind of ['symlink','fifo','directory']) {
    if(kind==='symlink')await fs.symlink(outside,f.path);
    else if(kind==='fifo'){assert(process.env.DIAGNOSTICS_FIFO_PATH,'Python runner creates an actual FIFO');await fs.rename(process.env.DIAGNOSTICS_FIFO_PATH,f.path);}
    else await fs.mkdir(f.path);
    await assert.rejects(f.store.tail(1024));assert.equal(f.fds.size,0);
    f.append(['forbidden']);await assert.rejects(f.store.flush());assert.equal(f.fds.size,0);
    await fs.rm(f.path,{recursive:true});
  }
  assert.equal(await fs.readFile(outside,'utf8'),'outside\n');
});

test('a substituted log directory or archived symlink is not followed',async t => {
  const f=await diagnosticsFixture(t);const outside=join(f.root,'outside');await fs.mkdir(outside);await fs.writeFile(join(outside,'engine.log'),'outside\n');
  await fs.symlink(outside,f.directory);await assert.rejects(f.store.tail(1024));assert.equal(f.fds.size,0);
  await fs.unlink(f.directory);await fs.mkdir(f.directory);await fs.symlink(join(outside,'engine.log'),f.path+'.1');
  await assert.rejects(f.store.tail(1024));assert.equal(f.fds.size,0);
});

test('failed rotation keeps the current committed file and later retries recover',async t => {
  const f=await diagnosticsFixture(t);await fs.mkdir(f.directory);const initial='x'.repeat(1024*1024-1)+'\n';await fs.writeFile(f.path,initial);
  f.change({rename:()=>{throw Error('rename');}});f.append(['rotate']);await assert.rejects(f.store.flush());assert.equal(await f.disk(),initial);assert.equal(f.fds.size,0);
  f.change({rename:undefined});f.append(['recovered']);await f.store.flush();
  assert.equal(await fs.readFile(f.path+'.1','utf8'),initial);assert.equal(await f.disk(),'[OHOS host: 1 persistent log lines omitted]\nrecovered\n');assert.equal(f.fds.size,0);
});

test('flush includes append while the last batch is awaiting close',async t => {
  const gate=deferred();let first=true;const f=await diagnosticsFixture(t,{close:async()=>{if(first){first=false;await gate.promise;}}});
  f.append(['first']);const flushed=f.store.flush();await until(()=>f.operations.some(v=>v.op==='close'));
  f.append(['during-close']);gate.resolve();await flushed;assert.equal(await f.disk(),'first\nduring-close\n');assert.equal(f.fds.size,0);
});

test('an oversized preexisting current file refuses writes while its tail stays bounded',async t => {
  const f=await diagnosticsFixture(t);await fs.mkdir(f.directory);await fs.writeFile(f.path,'x'.repeat(1024*1024)+'\nend\n');
  f.append(['new']);await assert.rejects(f.store.flush());assert.equal(f.fds.size,0);
  assert.deepEqual(Array.from(await f.store.tail(1024)),['end']);assert.equal(f.fds.size,0);
});

test('detached old info cannot release a new request busy slot or reply as current',async t => {
  const bundleGate=deferred(),readGate=deferred();let blocked=true;
  const f=await diagnosticsFixture(t,{bundle:async()=>{if(blocked)await bundleGate.promise;}});f.append(['line']);await f.store.flush();
  const old=f.attach(),pending=f.call(old,'info');assert.equal((await f.call(old,'engineLog').done).error,'busy');old.detach();
  const next=f.attach(old.plugin);f.change({read:()=>readGate.promise});const current=f.call(next,'engineLog');await until(()=>f.operations.some(v=>v.op==='read'));
  blocked=false;bundleGate.resolve();assert.equal((await pending.done).error,'detached');
  assert.equal((await f.call(next,'info').done).error,'busy');readGate.resolve();assert.deepEqual(await current.done,{value:['line']});
  assert.equal(pending.replies.length,1);assert.equal(current.replies.length,1);assert.equal(f.fds.size,0);
});

test('synchronous Context mismatch errors release busy and later correct calls work',async t => {
  const f=await diagnosticsFixture(t),i=f.attach(),files=f.app.filesDir;f.app.filesDir+='/different';
  assert.equal((await f.call(i,'info').done).error,'failed');assert.equal((await f.call(i,'engineLog').done).error,'failed');
  f.app.filesDir=files;assert.deepEqual(await f.call(i,'engineLog').done,{value:[]});
});

test('callback transport exceptions are caught and every request replies at most once',async t => {
  const f=await diagnosticsFixture(t,{replyError:true}),i=f.attach(),request=f.call(i,'engineLog');
  assert.deepEqual(await request.done,{value:[]});await new Promise(r=>setImmediate(r));assert.equal(request.replies.length,1);
  assert.deepEqual(await f.call(i,'engineLog',{maxBytes:NaN}).done,{value:[]});
});

test('empty append and facts do not create a persistent file',async t => {
  const f=await diagnosticsFixture(t);f.append([]);assert.equal(plain(f.store.facts()).queuedBytes,0);await f.store.flush();
  assert.deepEqual(f.operations,[]);assert.equal(f.fds.size,0);
});


test('real RuntimeController persists only redacted collected entries and retains final native tail',async t => {
  const f=await diagnosticsFixture(t),controller=f.controller();
  assert.deepEqual(f.operations,[]);controller.snapshot();controller.logSnapshot(10);
  assert.equal(f.native.loads,0);assert.deepEqual(f.operations,[]);
  f.native.state={...f.native.state,phase:'running',consumed:true,baseUrl:'http://127.0.0.1:1234',token:'synthetic-controller-secret'};
  f.native.events.push({kind:'ready',token:'synthetic-controller-secret'},
    {kind:'log',stream:'stdout',line:'first synthetic-controller-secret'},
    {kind:'log',stream:'stderr',line:'URL ?token=synthetic-query-secret'});
  controller.collect();await f.store.flush();
  f.native.state.phase='exited';f.native.state.exitCode=7;
  f.native.events.push({kind:'log',stream:'stdout',line:'最后一行'}, {kind:'exit',exitCode:7});
  controller.collect();await f.store.flush();
  const expected=Array.from(controller.recentLogs(20));assert.equal(expected.length,4);
  assert.deepEqual(Array.from(await f.store.tail(4096)),expected);
  const disk=await f.disk();assert(!disk.includes('synthetic-controller-secret'));assert(!disk.includes('synthetic-query-secret'));
  const next=f.reload();assert.deepEqual(Array.from(await next.store.tail(4096)),expected);
  assert.equal(f.native.loads,0);assert.equal(f.fds.size,0);
});

test('controller terminal persistence failure is bounded and visible in diagnostics facts',async t => {
  const f=await diagnosticsFixture(t,{write:()=>{throw Error('synthetic private write failure');}}),controller=f.controller();
  f.native.state={...f.native.state,phase:'exited',consumed:true,exitCode:1};
  f.native.events.push({kind:'log',stream:'stderr',line:'last'}, {kind:'exit',exitCode:1});
  controller.collect();await until(()=>plain(f.store.facts()).error==='persistence_failed');
  assert.equal(plain(f.store.facts()).error,'persistence_failed');
  assert(plain(f.store.facts()).omittedLines>0);assert.equal(f.fds.size,0);
  f.change({write:undefined});await f.store.flush();assert.equal(f.fds.size,0);
});
