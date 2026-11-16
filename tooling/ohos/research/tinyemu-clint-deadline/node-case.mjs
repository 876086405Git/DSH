import assert from 'node:assert/strict';
import {Socket} from 'node:net';
import {setTimeout as delay} from 'node:timers/promises';
const [library,config]=process.argv.slice(2),module={exports:{}};
process.dlopen(module,library);const native=module.exports,owner=native.create(config);
const socket=new Socket({fd:owner.fd,readable:true,writable:true});let output='';
socket.on('data',b=>output+=b.toString());socket.on('error',()=>{});
const deadline=Date.now()+3000;
while(!output.includes('CLINT-IDLE-READY\n')){assert.ok(Date.now()<deadline);await delay(2);}
await delay(30);const before=native.__idleStats(),start=performance.now();
await delay(600);const end=performance.now(),after=native.__idleStats();
const requested=performance.now();owner.requestStop();const result=await owner.join();const joined=performance.now();
socket.destroy();assert.equal(result.joined,true);assert.equal(result.apiResult,-4);
const observed={scope:'actual production Node/TinyEMU with bare RISC-V WFI BIOS with MTIE and UINT64_MAX mtimecmp plus slirp, no Linux kernel or device claim',windowMs:end-start,
  deltas:Object.fromEntries(Object.keys(before).map(k=>[k,after[k]-before[k]])),before,after,stopJoinMs:joined-requested,result};
console.log(JSON.stringify(observed));
assert.equal(observed.deltas.zeroDelayCalls,0,'UINT64_MAX is a future unsigned deadline and must not wake WFI or spin zero-time select');
