// Measurement worker: exact transpiled ETS logic, actual Linux files and libz.
// It intentionally does not load the TypeScript compiler in this measured PID.
import fs from 'node:fs/promises';
import {writeFileSync} from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {performance} from 'node:perf_hooks';
import {ArchiveResources, observation, activeInflaters, nativeZlibVersion} from './runtime-archive-fixture.mjs';

const [staged, description, target, mode, reportPath] = process.argv.slice(2);
await fs.writeFile(reportPath+'.identity.json',JSON.stringify({namespacePID:process.pid,procPID:Number(await fs.readlink('/proc/self'))})+'\n');
const metadata = JSON.parse(await fs.readFile(description,'utf8'));
const {OhosRuntimeStorage} = await import(pathToFileURL(path.join(staged,'OhosRuntimeStorage.mjs')));
const {RuntimeInstaller} = await import(pathToFileURL(path.join(staged,'RuntimeCore.mjs')));
await fs.mkdir(target,{recursive:true});
const resources = new ArchiveResources(metadata.hap, metadata.offset, metadata.length);
const storage = new OhosRuntimeStorage(resources,target);
const installer = new RuntimeInstaller(storage,target+'/dsh-runtime');
const memoryBefore = process.memoryUsage();
let extracted = 0;
const began = performance.now();
try {
  await storage.withBundledRuntime(async()=>{
    const manifest=await storage.readBundledManifest();
    await installer.install(manifest,event=>{
      if(event.step==='verify' && event.done%2000===0) process.stdout.write(JSON.stringify({phase:'verify',files:event.done,ms:performance.now()-began})+'\n');
      if(event.step==='extract') {
        extracted++;
        if(extracted%2000===0) process.stdout.write(JSON.stringify({phase:'extract',events:extracted,done:event.done,total:event.total,ms:performance.now()-began})+'\n');
        if(mode==='interrupt' && extracted===1001) {
          const stopped={mode,interrupt:'SIGKILL',complete:false,afterFileEvents:1000,done:event.done,pid:process.pid,
            elapsedMs:performance.now()-began,maxRSSKiB:process.resourceUsage().maxRSS,memory:process.memoryUsage(),
            scope:'real process killed after 1000 committed members; journal and absence of installed marker checked by parent'};
          writeFileSync(reportPath,JSON.stringify(stopped,null,2)+'\n');
          process.stdout.write(JSON.stringify(stopped)+'\n');
          process.kill(process.pid,'SIGKILL');
        }
      }
    });
  });
  const elapsedMs=performance.now()-began;
  const installed=await installer.installed();
  if(installed===null || installed.runtimeVersion!==metadata.runtimeVersion) throw new Error('installed version mismatch');
  if(observation.fd.size!==0 || activeInflaters()!==0) throw new Error('unreleased real file or libz resources');
  const report={mode,pid:process.pid,elapsedMs,files:installed.files.length,payloadBytes:installed.files.reduce((n,f)=>n+f.size,0),
    runtimeVersion:installed.runtimeVersion,memoryBefore,memoryAfter:process.memoryUsage(),maxRSSKiB:process.resourceUsage().maxRSS,
    rawAssetOpens:observation.opens,rawAssetCloses:observation.closes,rawReads:observation.reads,rawReadBytes:observation.readBytes,
    maxRawReadBuffer:observation.maxRead,writeCalls:observation.writes,writeBytes:observation.writeBytes,
    inflatedMembers:observation.initialized,inflateCalls:observation.inflates,maxInflateInput:observation.maxInput,
    maxInflateOutput:observation.maxOutput,activeFds:observation.fd.size,activeInflaters:activeInflaters(),
    node:process.version,nodeZlib:process.versions.zlib,nativeZlib:nativeZlibVersion(),platform:process.platform,arch:process.arch,
    scope:'Linux exact ETS methods + real filesystem/libz test boundary; NOT Ark runtime/HAP ResourceManager/device',
    cache:'new Node process; target state explicit in mode; OS page cache not cleared'};
  await fs.writeFile(reportPath,JSON.stringify(report,null,2)+'\n');
  process.stdout.write(JSON.stringify({result:'completed',...report})+'\n');
} catch(error) {
  const report={mode,pid:process.pid,error:String(error),code:error.code,elapsedMs:performance.now()-began,
    maxRSSKiB:process.resourceUsage().maxRSS,activeFds:observation.fd.size,activeInflaters:activeInflaters()};
  await fs.writeFile(reportPath,JSON.stringify(report,null,2)+'\n');
  process.stderr.write(JSON.stringify(report)+'\n');process.exitCode=1;
}
