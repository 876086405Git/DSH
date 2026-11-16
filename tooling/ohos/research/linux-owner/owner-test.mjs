import assert from 'node:assert/strict';
import { readFile, readdir, readlink } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { Readable } from 'node:stream';
import { dirname } from 'node:path';
import { LinuxInstallationOwner, loadLinuxInstallationManifest } from './source/runtime/ohos/linux/owner.mjs';
import { loadLinuxNative } from './source/runtime/ohos/linux/native-session.mjs';
const [nativeLibraryDirectory,manifestPath,archive,directory,mode='normal']=process.argv.slice(2);
const manifest=manifestPath.endsWith('install-manifest.json')?await loadLinuxInstallationManifest({assetsDirectory:dirname(manifestPath)}):JSON.parse(await readFile(manifestPath,'utf8'));const abort=new AbortController();const events=[];let raw;let joinSawImages=false;
const checks=[];const check=(test,value,facts={})=>{console.log(JSON.stringify({test,pass:!!value,...facts}));assert.ok(value,test);checks.push(test);};
async function openFiles(){const result=[];for(const fd of await readdir('/proc/self/fd')){try{const path=await readlink('/proc/self/fd/'+fd);if(path.startsWith(directory+'/'))result.push(path);}catch{}}return result;}
const owner=new LinuxInstallationOwner({nativeLibraryDirectory,manifest,directory,onProgress:event=>{if(events.at(-1)?.stage!==event.stage||event.step||event.done===event.total)events.push(event);if(mode==='cancel-download'&&event.stage==='download'&&event.done>0)abort.abort();if(mode==='cancel-prepare'&&event.stage==='target'&&event.done>0)abort.abort();if(mode==='cancel-boot'&&event.stage==='guest-install'&&event.step==='begin')abort.abort();}}, {
 download:{fetch:async()=>new Response(Readable.toWeb(createReadStream(archive)),{status:200})},
 createSession:config=>{raw=loadLinuxNative({nativeLibraryDirectory}).create(config);return {...raw,join:async()=>{joinSawImages=(await readdir(directory)).length>0;const result=await raw.join();if(mode==='unknown-retire')return {...result,retirementError:true};return result;}}}
});
const timer=setTimeout(()=>{console.error('TEST_DEADLINE');process.exit(90);},180000);
try{
 if(mode==='unknown-retire'){const install=owner.install({signal:abort.signal});const interval=setInterval(()=>{if(raw)abort.abort();},5);await assert.rejects(install);clearInterval(interval);check('unknown retirement retains images and no active',owner.state==='quarantined'&&!owner.active&&(await readdir(directory)).filter(name=>name!=='.lock').length===1);const result=await owner.dispose();check('unknown retirement never reports removed',result.filesRemoved===false&&result.native.retirementError===true&&!result.cleanCheckpoint);}
 else if(mode!=='normal'){
  await assert.rejects(owner.install({signal:abort.signal}));const result=await owner.dispose();
  check('cancel clears all attempt data after actual retirement',(await readdir(directory)).filter(name=>name!=='.lock').length===0&&(await openFiles()).length===0&&result.filesRemoved);
  check('cancel never publishes active',!owner.active&&!owner.backend);
  if(mode==='cancel-boot')check('cancel joined real native VM and retains owner quarantine',result.native.joined===true&&result.native.retirementError===false&&result.ownerQuarantined&&joinSawImages,{native:result.native});
 }else{
  const result=await owner.install();check('download/prepare/pivot and real opened precede active',owner.state==='active'&&events.some(e=>e.stage==='download'&&e.done===manifest.archive.bytes)&&events.some(e=>e.step==='pivot')&&events.at(-1).stage==='opened-private-guest');
  check('fresh random epoch reaches guest',result.active.epoch!=='01'.repeat(32)&&/^[a-f0-9]{64}$/.test(result.active.epoch));
  check('active descriptor recorded while actual disks open',JSON.parse(await readFile(result.active.directory+'/instance.json','utf8')).epoch===result.active.epoch&&(await openFiles()).length>=4);
  const job=result.backend.spawn({argv:['python3','-c','import os; print("owner917"); print(os.path.exists("/oldroot/etc"))'],cwd:'/workspace',graceMs:5000,stdio:{stdin:'ignore',stdout:{maxBytes:1024},stderr:{maxBytes:1024}}});
  const done=await job.done;check('same VM executes job after pivot with old root detached',done.exitCode===0&&job.collected.stdout.snapshot().bytes.toString()==='owner917\nFalse\n');
  const retired=await owner.dispose();check('dispose joins and retains published writable instance',retired.resourcesRetired&&retired.filesRemoved===false&&retired.dataRetained&&retired.native.joined&&retired.native.retirementError===false&&joinSawImages&&(await openFiles()).length===0&&(await readdir(directory)).filter(name=>name!=='.lock').length===1);
  const checkpoint=JSON.parse(await readFile(result.active.directory+'/instance.json','utf8'));
  check('clean descriptor preserves the published target identity',retired.cleanCheckpoint&&checkpoint.state==='clean'&&checkpoint.target.name==='target.ext4'&&checkpoint.persistentInstanceId===result.active.persistentInstanceId&&checkpoint.guestClose.epoch===result.active.epoch);
  await assert.rejects(owner.install(),{code:'ERR_OHOS_LINUX_OWNER_CLOSED'});
  check('disposed owner stays quarantined and cannot start another VM',owner.state==='stopped-quarantined'&&retired.ownerQuarantined);
 }
 console.log(JSON.stringify({checks:checks.length,pass:true,state:owner.state,events:events.map(e=>({stage:e.stage,step:e.step}))}));
}finally{clearTimeout(timer);await owner.dispose();}
