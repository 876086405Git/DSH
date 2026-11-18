// Test entry only; actual Bash/createFilesystem/native addon, not a fake shell.
import {parentPort,workerData} from 'node:worker_threads';
import {createRequire} from 'node:module';
const binding=createRequire(import.meta.url)(workerData.binding);
if(workerData.probeOwner){
 let issue,bind;try{binding.issue('0'.repeat(64),'forged',1,true);}catch(error){issue=error.code;}
 try{binding.bindOwner(workerData.host);}catch(error){bind=error.code;}
 parentPort.postMessage({issue,bind});parentPort.close();
}else{
 const {Bash}=await import('../../ohos/process/build/just-bash/index.js');
 const {createFilesystem}=await import(workerData.filesystem??'../../ohos/process/filesystem.mjs');
 try{
  const filesystem=createFilesystem([workerData.temporary],{mode:workerData.readOnly?'read-only':'workspace-write'},
    {grantMounts:workerData.mounts,binding});
  const bash=new Bash({fs:filesystem.fs,cwd:workerData.cwd,env:{HOME:workerData.cwd},javascript:false,python:false,defenseInDepth:false});
  filesystem.seal();const result=await bash.exec(workerData.script);parentPort.postMessage({result});
  if(workerData.hold){parentPort.on('message',async()=>{
   try{parentPort.postMessage({after:await filesystem.fs.readFile(workerData.cwd+'/marker')});}catch(error){parentPort.postMessage({afterError:error.code});}
  });}else parentPort.close();
 }catch(error){parentPort.postMessage({failure:{code:error.code,message:error.message}});parentPort.close();}
}
