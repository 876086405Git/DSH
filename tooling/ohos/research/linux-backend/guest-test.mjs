import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { loadLinuxNative } from './source/runtime/ohos/linux/native-session.mjs';
import { LinuxRuntimeBackend } from './source/runtime/ohos/linux/backend.mjs';
const [nativeLibraryDirectory,configPath,temporaryRoot,mode='normal']=process.argv.slice(2);const timeout=setTimeout(()=>{console.error('TEST_DEADLINE');process.exit(90);},180000);
let ownedSocket;
const config={nativeLibraryDirectory,configPath,temporaryRoot,epoch:'01'.repeat(32)};
const backend=new LinuxRuntimeBackend(config,mode==='disconnect'?{createSession:path=>{const session=loadLinuxNative({nativeLibraryDirectory}).create(path);ownedSocket=session.socket;return session;}}:{});
const checks=[];const check=(test,condition,facts={})=>{const row={test,pass:!!condition,...facts};checks.push(row);console.log(JSON.stringify(row));assert.ok(condition,test);};
const spec=(argv,extra={})=>({argv,cwd:'/workspace',graceMs:5000,stdio:{stdin:'ignore',stdout:{maxBytes:65536},stderr:{maxBytes:65536}},...extra});
async function run(argv){const job=backend.spawn(spec(argv));const outcome=await job.done;assert.equal(outcome.exitCode,0);return {outcome,out:job.collected.stdout.snapshot().bytes,err:job.collected.stderr.snapshot().bytes};}
async function read(stream){const chunks=[];for await(const b of stream)chunks.push(b);return Buffer.concat(chunks);}
try{
 const start=Date.now();await backend.opened;check('real opened handshake',backend.state==='opened',{bootMs:Date.now()-start});
 assert.throws(()=>backend.spawn(spec(['gh','--version'],{cwd:'/host/grant'})),{code:'ERR_OHOS_LINUX_WORKSPACE_UNAVAILABLE'});
 assert.throws(()=>backend.prepare(['gh'],{mode:'read-only',workspaceRoot:'/workspace'}),{code:'ERR_OHOS_BACKEND_CONFINEMENT'});
 if(mode==='disconnect'){
  const job=backend.spawn(spec(['python3','-c','import time;print("started",flush=True);time.sleep(60)'],{stdio:{stdin:'ignore',stdout:'pipe',stderr:'pipe'}}));
  await once(job.stdout,'data');
  // Explicit test seam still uses the real 912 native session/socket.
  ownedSocket.destroy();
  await assert.rejects(job.done,{code:'ERR_OHOS_LINUX_UNKNOWN'});await assert.rejects(job.waitForExit(),{code:'ERR_OHOS_LINUX_UNKNOWN'});
  check('real transport loss retains unknown live owner',backend.state==='quarantined'&&backend.live.size===1);
  await assert.rejects(backend.dispose());check('dispose cannot promote lost guest tree to closed',backend.state==='quarantined');
 }else{
  for(const [argv,pattern] of [[['python3','-c','print(1)'],/^1\n$/],[['gh','--version'],/^gh version /],[['git','--version'],/^git version /],[['rg','needle','/workspace/needle.txt'],/beta needle/]]){
   const {out,err}=await run(argv);check(argv[0],pattern.test(out.toString())&&err.length===0,{stdout:out.toString()});
  }
  const data=Buffer.alloc(153600);for(let i=0;i<data.length;i++)data[i]=i%251;
  const job=backend.spawn(spec(['python3','-c','import sys,hashlib;print("early",flush=True);b=sys.stdin.buffer.read();print(len(b),hashlib.sha256(b).hexdigest(),flush=True)'],{stdio:{stdin:'pipe',stdout:'pipe',stderr:'pipe'}}));
  const first=await once(job.stdout,'data');check('early output before stdin EOF',first[0].toString()==='early\n');
  const stdout=read(job.stdout),stderr=read(job.stderr);await new Promise((resolve,reject)=>job.stdin.write(data,e=>e?reject(e):resolve()));job.stdin.end();await once(job.stdin,'finish');const outcome=await job.done;const out=await stdout;await stderr;
  check('153600 binary stdin ACK and separated streams',outcome.exitCode===0&&out.toString().includes(`153600 ${createHash('sha256').update(data).digest('hex')}`));
  const blocked=backend.spawn(spec(['python3','-c','import os,time;os.write(1,b"x"*262144);time.sleep(60)'],{stdio:{stdin:'ignore',stdout:'pipe',stderr:'pipe'}}));await blocked.started;const fullDeadline=Date.now()+10000;while(blocked.stdout.readableLength<65536&&Date.now()<fullDeadline)await delay(20);let settled=false;blocked.done.then(()=>settled=true,()=>{});
  check('real bounded unconsumed output',blocked.stdout.readableLength===65536&&!settled,{buffered:blocked.stdout.readableLength});blocked.terminate('SIGTERM');await delay(80);check('cancel request does not invent release before sink drain',!settled);
  const drained=read(blocked.stdout),errDrain=read(blocked.stderr);const cancelled=await blocked.done;const bytes=await drained;await errDrain;
  check('cancel while output credit full reaps then completes',cancelled.cancelled===true&&cancelled.signal==='SIGKILL',{bytes:bytes.length,outcome:cancelled});
  const code='import os,time; p=os.fork();\nif p: os._exit(0)\nos.setsid();f=open("tick914","w");f.write("0");f.flush();os.write(1,b"ready\\n");os.close(0);os.close(1);os.close(2);i=0\nwhile True:\n i+=1;f.seek(0);f.write(str(i));f.flush();time.sleep(.01)';
  const tree=backend.spawn(spec(['python3','-c',code],{stdio:{stdin:'ignore',stdout:'pipe',stderr:'pipe'}}));const ready=await read(tree.stdout);assert.equal(ready.toString(),'ready\n');tree.stderr.resume();tree.terminate('SIGKILL');const treeOutcome=await tree.done;
  const probe=await run(['python3','-c','import time;a=open("tick914").read();time.sleep(.2);b=open("tick914").read();print(a==b,bool(a))']);
  check('setsid child reaped even after leader exit',treeOutcome.cancelled===true&&treeOutcome.exitCode===0&&treeOutcome.signal===null&&probe.out.toString()==='True True\n',{outcome:treeOutcome});
  const jobs=[backend.spawn(spec(['python3','-c','print("one")'])),backend.spawn(spec(['python3','-c','print("two")'])),backend.spawn(spec(['python3','-c','print("never")']))];jobs[2].terminate();const results=await Promise.all(jobs.map(j=>j.done));
  check('one guest lane and queued cancellation',jobs[0].collected.stdout.snapshot().bytes.toString()==='one\n'&&jobs[1].collected.stdout.snapshot().bytes.toString()==='two\n'&&results[2].notStarted===true);
  const disposed=await backend.dispose();check('protocol synced closed after real jobs then native join',disposed.closed&&disposed.guestClose?.epoch===config.epoch&&disposed.guestClose.rootfsSync===true&&disposed.guestClose.syncMethod==='syncfs'&&disposed.guestClose.syncScope==='rootfs'&&disposed.native.joined&&backend.state==='closed'&&backend.live.size===0);
 }
}finally{clearTimeout(timeout);console.log(JSON.stringify({checks:checks.length,pass:checks.every(c=>c.pass),state:backend.state}));}
