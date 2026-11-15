'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {performance}=require('node:perf_hooks');
const errno=require('node:os').constants.errno;
const input={};
for(const name of ['ADDON','ROOT','WORKSPACE','TEMP','PROTECTED']){
 input[name]=process.env['DSH_GUEST_TEST_'+name];
 assert(input[name]&&path.isAbsolute(input[name]),'absolute DSH_GUEST_TEST_'+name+' required');
}
const binding=require(input.ADDON);
const request=command=>({root:input.ROOT,protectedPaths:[input.PROTECTED],argv:['/bin/sh','-c',command],env:['PATH=/usr/bin:/bin:/usr/sbin:/sbin'],cwd:'/workspace',workspace:input.WORKSPACE,temporary:input.TEMP,readOnly:false});
const json=v=>JSON.stringify(v,(_,x)=>typeof x==='bigint'?x.toString():x);
async function held(method){
 const marker=path.join(input.WORKSPACE,method+'-term');fs.rmSync(marker,{force:true});
 let id,chunk,savedData,events=0,began,late='not-run';
 const result=await new Promise((resolve,reject)=>{
  id=binding.start(request(`trap 'printf term > /workspace/${method}-term' TERM; printf READY; printf MORE >&2; while :; do :; done`),event=>{
   try{
    if(event.type==='stdout'||event.type==='stderr'){
     events++;assert.equal(events,1,'no output may be delivered after stop');chunk=event;savedData=Buffer.from(event.data);began=performance.now();binding[method](id);
     if(method!=='abandon'){
      // Already-delivered output finishes late. This must not ACK it natively.
      binding.ack(id,event.type==='stdout'?1:2,event.end);late='ignored-active';
     }
    }
    if(event.type==='exit')resolve(event);
   }catch(e){reject(e);}
  });
 });
 const elapsedMs=performance.now()-began;
 console.log(json({phase:'held',method,result,status:binding.status(),elapsedMs,events,late,termMarker:fs.existsSync(marker)}));
 assert.equal(result.error,method==='abandon'?errno.ECANCELED:0);assert.equal(result.resourcesSettled,true);assert.equal(result.abandoned,true);assert.equal(result.exitCode,137);assert.equal(binding.status().state,'ready');
 assert.deepEqual(chunk.data,savedData,'consumer Buffer remains valid after native retirement');
 assert.equal(fs.existsSync(marker),method!=='kill','TERM vs KILL behavior must remain distinct');
 // A retired id stays stale, even while a replacement job is active.
 let nextId;await new Promise((resolve,reject)=>{
  nextId=binding.start(request('printf reuse-after-stop'),event=>{
   try{
    if(event.type==='stdout'){
     assert.throws(()=>binding.ack(id,chunk.type==='stdout'?1:2,chunk.end),e=>e.errno===errno.ESTALE);
     binding.ack(nextId,1,event.end);
    }
    if(event.type==='exit'){assert.equal(event.error,0);assert.equal(event.resourcesSettled,true);assert.equal(event.exitCode,0);resolve();}
   }catch(e){reject(e);}
  });
 });
 assert.deepEqual(chunk.data,savedData,'consumer Buffer remains valid after next job');
}
(async()=>{for(const method of ['cancel','kill','abandon'])await held(method);console.log('all held ACK modes, late ACK isolation and reuse PASS');})().catch(e=>{console.error(e);process.exitCode=1;});
