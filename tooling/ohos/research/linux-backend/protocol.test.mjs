import test from 'node:test';
import assert from 'node:assert/strict';
import { Duplex } from 'node:stream';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { mkdtemp,rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { LinuxRuntimeBackend } from './source/runtime/ohos/linux/backend.mjs';
const epoch='01'.repeat(32);
const cleanClose={rootfsSync:true,syncMethod:'syncfs',syncScope:'rootfs'};
class Transport extends Duplex {
 commands=[];sequence=0;
 _read(){}
 _write(bytes,_encoding,callback){for(const line of bytes.toString().trimEnd().split('\n'))this.commands.push(JSON.parse(line));callback();}
 frame(kind,fields={}){this.push(Buffer.from('DSHG1 '+JSON.stringify({v:1,epoch,seq:++this.sequence,kind,job:null,...fields})+'\n'));}
}
const spec=(extra={})=>({argv:['python3','-c','print(1)'],cwd:'/workspace',graceMs:1000,stdio:{stdin:'ignore',stdout:'pipe',stderr:'pipe'},...extra});
async function fixture(fn){const root=await mkdtemp(join(tmpdir(),'linux-backend-'));const socket=new Transport();let stops=0,joins=0;const backend=new LinuxRuntimeBackend({configPath:'/trusted/config',epoch,temporaryRoot:root},{createSession:()=>({socket,requestStop(){stops++;},async join(){joins++;return {joined:true,ownerQuarantined:true,retirementError:false,apiResult:-4};}})});try{await fn({backend,socket,counts:()=>({stops,joins})});}finally{socket.destroy();await rm(root,{recursive:true,force:true});}}
async function open({backend,socket}){socket.frame('opened',{capabilities:{streamingStdin:true,pidNamespace:true,workspaceLease:false}});await backend.opened;}
async function started(f,extra){const job=f.backend.spawn(spec(extra));await delay(0);const start=f.socket.commands.find(x=>x.op==='start');assert.ok(start);f.socket.frame('started',{job:start.job});f.socket.frame('admitted',{job:start.job});await job.started;return {job,id:start.job};}
async function complete(f,id,counts={stdout:'0',stderr:'0'},extra={}){for(const stream of ['stdout','stderr'])f.socket.frame('eof',{job:id,stream,through:counts[stream]});await delay(0);f.socket.frame('complete',{job:id,exitCode:0,signal:null,cancelled:false,produced:counts,...extra});}

test('no fabricated opening, no policy bypass, no host cwd remapping',()=>fixture(async f=>{
 assert.equal(f.backend.state,'opening');assert.deepEqual(f.backend.capabilities.confinement,[]);
 assert.throws(()=>f.backend.prepare(['gh'],{mode:'read-only',workspaceRoot:'/workspace'}),{code:'ERR_OHOS_BACKEND_CONFINEMENT'});
 assert.throws(()=>f.backend.spawn(spec({policy:{mode:'workspace-write'}})),{code:'ERR_OHOS_BACKEND_CONFINEMENT'});
 assert.throws(()=>f.backend.spawn(spec({cwd:'/host/grant'})),{code:'ERR_OHOS_LINUX_WORKSPACE_UNAVAILABLE'});
 assert.equal(f.backend.live.size,0);await open(f);assert.equal(f.backend.state,'opened');
}));
test('Writable callbacks wait actual stdin ACK and windows remain 64 KiB',()=>fixture(async f=>{
 await open(f);const {job,id}=await started(f,{stdio:{stdin:'pipe',stdout:'ignore',stderr:'ignore'}});const data=Buffer.alloc(153600,173);let accepted=false;
 job.stdin.write(data,error=>{assert.ifError(error);accepted=true;});await delay(0);
 let frames=f.socket.commands.filter(x=>x.op==='stdin');assert.equal(frames.reduce((n,x)=>n+Buffer.from(x.data,'base64').length,0),65536);assert.equal(accepted,false);
 let through=0;for(let round=0;round<4&&!accepted;round++){frames=f.socket.commands.filter(x=>x.op==='stdin');through=frames.reduce((n,x)=>n+Buffer.from(x.data,'base64').length,0);f.socket.frame('stdin-ack',{job:id,through:String(through)});await delay(0);}
 assert.equal(accepted,true);frames=f.socket.commands.filter(x=>x.op==='stdin');assert.deepEqual(Buffer.concat(frames.map(x=>Buffer.from(x.data,'base64'))),data);
 job.stdin.end();await once(job.stdin,'finish');assert.equal(f.socket.commands.at(-1).op,'stdin-end');await complete(f,id);assert.equal((await job.done).exitCode,0);
}));
test('output Readable bounds plus queued credit, ACK follows sink progress',()=>fixture(async f=>{
 await open(f);const {job,id}=await started(f);const bytes=Buffer.alloc(4096,120);
 for(let i=0;i<31;i++)f.socket.frame('data',{job:id,stream:'stdout',offset:String(i*4096),data:bytes.toString('base64')});await delay(0);
 assert.equal(job.stdout.readableLength,65536);let acks=f.socket.commands.filter(x=>x.op==='ack'&&x.stream==='stdout');assert.equal(acks.at(-1).through,'61440');
 let finished=false;job.done.then(()=>finished=true,()=>{});f.socket.frame('eof',{job:id,stream:'stdout',through:String(31*4096)});f.socket.frame('eof',{job:id,stream:'stderr',through:'0'});await delay(0);assert.equal(finished,false);
 const chunks=[];for await(const chunk of job.stdout)chunks.push(chunk);assert.equal(Buffer.concat(chunks).length,31*4096);
 acks=f.socket.commands.filter(x=>x.op==='ack'&&x.stream==='stdout');assert.equal(acks.at(-1).through,String(31*4096));
 f.socket.frame('complete',{job:id,exitCode:0,signal:null,cancelled:false,produced:{stdout:String(31*4096),stderr:'0'}});assert.equal((await job.done).exitCode,0);assert.equal(f.backend.live.size,0);
}));
test('bounded collector keeps raw binary bytes and ignore still ACKs',()=>fixture(async f=>{
 await open(f);const {job,id}=await started(f,{stdio:{stdin:'ignore',stdout:{maxBytes:3},stderr:'ignore'}});const b=Buffer.from([255,0,1,2]);f.socket.frame('data',{job:id,stream:'stdout',offset:'0',data:b.toString('base64')});f.socket.frame('data',{job:id,stream:'stderr',offset:'0',data:'eA=='});await complete(f,id,{stdout:'4',stderr:'1'});await job.done;assert.deepEqual(job.collected.stdout.snapshot().bytes,Buffer.from([0,1,2]));assert.equal(job.collected.stdout.snapshot().totalBytes,4);
}));
test('cancel request preserves actual leader outcome and cancelled fact',()=>fixture(async f=>{
 await open(f);const {job,id}=await started(f);job.terminate('SIGTERM');assert.equal(f.socket.commands.at(-1).op,'cancel');assert.deepEqual(f.counts(),{stops:0,joins:0});
 f.socket.frame('cancel-requested',{job:id});await complete(f,id,undefined,{cancelled:true,exitCode:0,signal:null});assert.deepEqual(await job.done,{exitCode:0,signal:null,cancelled:true,requestedSignal:'SIGTERM'});
}));
test('transport loss rejects done and keeps unknown owner/live evidence',()=>fixture(async f=>{
 await open(f);const {job}=await started(f);f.socket.push(null);await assert.rejects(job.done,{code:'ERR_OHOS_LINUX_UNKNOWN'});await assert.rejects(job.waitForExit(),{code:'ERR_OHOS_LINUX_UNKNOWN'});assert.equal(f.backend.live.size,1);assert.equal(f.backend.state,'quarantined');assert.deepEqual(f.counts(),{stops:0,joins:0});await assert.rejects(f.backend.dispose());assert.deepEqual(f.counts(),{stops:1,joins:1});assert.equal(f.backend.state,'quarantined');
}));
for(const bad of ['epoch','seq','job','credit','early-complete','early-closed','stdin-ack'])test('quarantines '+bad,()=>fixture(async f=>{
 await open(f);const {job,id}=await started(f);
 if(bad==='epoch')f.socket.frame('eof',{job:id,epoch:'ff'.repeat(32),stream:'stdout',through:'0'});
 if(bad==='seq')f.socket.frame('eof',{job:id,seq:99,stream:'stdout',through:'0'});
 if(bad==='job')f.socket.frame('eof',{job:id+1,stream:'stdout',through:'0'});
 if(bad==='credit'){const data=Buffer.alloc(4096).toString('base64');for(let i=0;i<32;i++)f.socket.frame('data',{job:id,stream:'stdout',offset:String(i*4096),data});}
 if(bad==='early-closed')f.socket.frame('closed');
 if(bad==='stdin-ack')f.socket.frame('stdin-ack',{job:id,through:'1'});
 if(bad==='early-complete')f.socket.frame('complete',{job:id,exitCode:0,signal:null,cancelled:false,produced:{stdout:'0',stderr:'0'}});
 await assert.rejects(job.done,{code:'ERR_OHOS_LINUX_UNKNOWN'});assert.equal(f.backend.live.size,1);
}));
test('dispose cannot close/native-stop before true guest job and closed facts',()=>fixture(async f=>{
 await open(f);const {job,id}=await started(f);const disposed=f.backend.dispose();await delay(0);assert.deepEqual(f.counts(),{stops:0,joins:0});assert.equal(f.socket.commands.at(-1).op,'cancel');f.socket.frame('cancel-requested',{job:id});await complete(f,id,undefined,{exitCode:null,signal:'SIGKILL',cancelled:true});await job.done;await delay(0);assert.equal(f.socket.commands.at(-1).op,'close');assert.deepEqual(f.counts(),{stops:0,joins:0});f.socket.frame('closed',cleanClose);assert.equal((await disposed).closed,true);assert.deepEqual(f.counts(),{stops:1,joins:1});assert.equal(f.backend.state,'closed');
}));
test('duplicate closed cannot promote a quarantined owner to clean disposal',()=>fixture(async f=>{
 await open(f);const disposed=f.backend.dispose();await delay(0);f.socket.frame('closed',cleanClose);f.socket.frame('closed',cleanClose);await assert.rejects(disposed,{code:'ERR_OHOS_LINUX_UNKNOWN'});assert.equal(f.backend.state,'quarantined');
}));
test('queued pipe EOF stays behind start and signal rejection is explicit',()=>fixture(async f=>{
 const job=f.backend.spawn(spec({stdio:{stdin:'pipe',stdout:'ignore',stderr:'ignore'}}));job.stdin.end();await delay(0);assert.equal(f.socket.commands.length,0);await open(f);await delay(0);assert.deepEqual(f.socket.commands.map(c=>c.op),['start','stdin-end']);assert.throws(()=>job.terminate('SIGINT'),{code:'ERR_OHOS_LINUX_SIGNAL'});
 const id=f.socket.commands[0].job;f.socket.frame('started',{job:id});f.socket.frame('admitted',{job:id});await complete(f,id);await job.done;
}));
test('cancel grace expiry is unknown and never an invented reap',()=>fixture(async f=>{
 await open(f);const {job}=await started(f,{graceMs:20});job.terminate('SIGKILL');await assert.rejects(job.done,{code:'ERR_OHOS_LINUX_UNKNOWN'});assert.equal(f.backend.live.size,1);assert.equal(f.backend.state,'quarantined');assert.deepEqual(f.counts(),{stops:0,joins:0});await assert.rejects(f.backend.dispose());
}));
test('canonical parent scrub, guest paths, explicit opt-in and tombstones',()=>fixture(async f=>{
 await open(f);const saved=process.env.DSH_914_PROBE;process.env.DSH_914_PROBE='ambient';
 try{const {job,id}=await started(f,{env:{DSH_914_PROBE:'explicit',HOME:undefined,PATH:'/bin',TOKEN_914:'provided'}});const env=f.socket.commands.find(c=>c.op==='start').env;assert.equal(env.DSH_914_PROBE,'explicit');assert.equal(env.TOKEN_914,'provided');assert.equal(env.PATH,'/bin');assert.equal(env.TMPDIR,'/tmp');assert.equal(Object.hasOwn(env,'HOME'),false);await complete(f,id);await job.done;}finally{if(saved===undefined)delete process.env.DSH_914_PROBE;else process.env.DSH_914_PROBE=saved;}
}));
