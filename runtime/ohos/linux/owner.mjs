import { constants, createReadStream, createWriteStream } from 'node:fs';
import { mkdir, open } from 'node:fs/promises';
import { join, isAbsolute } from 'node:path';
import { createHash } from 'node:crypto';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { downloadLinuxBase } from './base-download.mjs';
import { prepareLinuxImages } from './prepare-images.mjs';
import { loadLinuxNative } from './native-session.mjs';
import { LinuxRuntimeBackend } from './backend.mjs';
import { linuxHostLock } from './host-paths.mjs';
import { openLinuxInstance, discardLinuxInstance, cleanGuestClose } from './instance.mjs';

const error=(code,message)=>Object.assign(new Error(message),{code});
const deferred=()=>{const d=Promise.withResolvers();d.promise.catch(()=>{});return d;};
function validAsset(asset){return asset&&isAbsolute(asset.path)&&Number.isSafeInteger(asset.bytes)&&asset.bytes>0&&/^[a-f0-9]{64}$/.test(asset.sha256);}
async function copyAsset(asset,destination,signal){
  let count=0;const hash=createHash('sha256');
  const check=new Transform({transform(chunk,_enc,callback){count+=chunk.length;if(count>asset.bytes)return callback(error('ERR_OHOS_LINUX_IMAGE_INTEGRITY','Asset exceeds pinned size'));hash.update(chunk);callback(null,chunk);},flush(callback){callback(count===asset.bytes&&hash.digest('hex')===asset.sha256?null:error('ERR_OHOS_LINUX_IMAGE_INTEGRITY','Asset SHA256/size mismatch'));}});
  await pipeline(createReadStream(asset.path,{flags:constants.O_RDONLY|constants.O_NOFOLLOW}),check,createWriteStream(destination,{flags:'wx',mode:0o600}),{signal});
}
// One owner, one native VM lifetime. Only the trusted application composition
// supplies manifests/native paths; ordinary argv/env cannot select these inputs.
export class LinuxInstallationOwner {
  state='idle';backend=undefined;active=undefined;nativeRetirement=undefined;
  #options;#internals;#promise;#session;#backend;#instance;#attempt;#epoch;#persistentId=null;#bootMode=null;#abort=new AbortController();#cleanup;#published=false;#retainedExisting=false;#disposed=false;#transportDebt=false;#creationQuarantined=false;
  constructor(options,internals={}){
    const {directory,manifest,nativeLibraryDirectory,exports=[],bootTimeoutMs=180000,onProgress=()=>{}}=options??{};
    if(!isAbsolute(directory??'')||!isAbsolute(nativeLibraryDirectory??'')||!manifest||!['bios','kernel','tools','bootstrap','empty'].every(key=>validAsset(manifest[key]))||!Number.isFinite(bootTimeoutMs)||bootTimeoutMs<=0||bootTimeoutMs>2147483647||typeof onProgress!=='function'||!Array.isArray(exports)||exports.length>4||!exports.every((item,index)=>item?.tag==='dsh'+index&&isAbsolute(item.path??'')))throw new TypeError('Trusted private directory, native directory, App exports and pinned Linux assets are required');
    const pinned=Object.freeze(Object.fromEntries(['bios','kernel','tools','bootstrap','empty','archive'].map(key=>[key,Object.freeze({...manifest[key]})])));
    this.#options={directory,manifest:pinned,nativeLibraryDirectory,exports:Object.freeze(exports.map(({tag,path})=>Object.freeze({tag,path}))),bootTimeoutMs,onProgress};this.#internals=internals;
  }
  get persistentInstanceId(){return this.#persistentId;}
  get bootMode(){return this.#bootMode;}
  get nativeOwnerCreated(){return !!this.#session;}
  // Progress is an observation. A display callback cannot invalidate verified
  // image bytes, kill a guest, or turn successful publication into rollback.
  #progress(stage,detail={}){try{this.#options.onProgress({stage,...detail});}catch{}}
  install({signal}={}){
    if(this.#disposed)return Promise.reject(error('ERR_OHOS_LINUX_OWNER_CLOSED','A stopped owner cannot create another VM'));
    if(this.#promise)return this.#promise;
    const abort=()=>this.#abort.abort(signal.reason);if(signal?.aborted)abort();else signal?.addEventListener('abort',abort,{once:true});
    this.#promise=this.#install().finally(()=>signal?.removeEventListener('abort',abort));this.#promise.catch(()=>{});return this.#promise;
  }
  async #install(){
    const signal=this.#abort.signal,{directory,manifest,nativeLibraryDirectory,exports,bootTimeoutMs}=this.#options;
    try{
      signal.throwIfAborted();
      this.#instance=await openLinuxInstance({directory,manifest,lockExclusive:this.#internals.lockExclusive??linuxHostLock()},this.#internals.instance);
      const store=this.#instance;
      this.#retainedExisting=store.existing;this.#attempt=store.directory;this.#persistentId=store.persistentInstanceId;this.#bootMode=store.existing?'resume':'install';
      const epoch=this.#epoch=store.epoch;let images;
      const paths=Object.fromEntries(['bios','kernel','tools'].map(name=>[name,join(this.#attempt,name+'.bin')]));
      signal.throwIfAborted();
      if(store.existing){this.state='resuming';this.#progress('resume-start');}
      else{
        this.state='downloading';this.#progress('download-start');
        const base=await downloadLinuxBase({directory:join(this.#attempt,'download'),artifact:manifest.archive,signal,onProgress:event=>this.#progress(event.stage,event)},this.#internals.download??{});
        this.state='preparing';this.#progress('prepare-start');
        images=await prepareLinuxImages({directory:this.#attempt,bootstrap:manifest.bootstrap,empty:manifest.empty,archive:{path:base.path,bytes:manifest.archive.bytes,sha256:manifest.archive.sha256},signal,onProgress:event=>this.#progress(event.stage,event)});
        await store.prepared(images.target);
        for(const name of ['bios','kernel','tools'])await copyAsset(manifest[name],paths[name],signal);
        await mkdir(join(this.#attempt,'spill'),{mode:0o700});
      }
      const config={version:1,machine:'riscv64',memory_size:512,bios:paths.bios,kernel:paths.kernel,cmdline:`console=hvc0 root=/dev/vda ${store.existing?'rw':'ro'} init=/sbin/dsh-init dsh.epoch=${epoch} dsh.time=${Math.floor(Date.now()/1000)}`,
        ...(store.existing?{drive0:{file:store.target}}:{drive0:{file:images.bootstrap,readOnly:true},drive1:{file:images.archive,readOnly:true},drive2:{file:store.target},drive3:{file:paths.tools,readOnly:true}}),eth0:{driver:'user'},
        // App-owned host directories over virtio-9p; each job mounts only its own.
        ...Object.fromEntries(exports.map((item,index)=>['fs'+index,{tag:item.tag,file:item.path}]))};
      const configPath=await store.config(store.existing?'resume.cfg':'guest.cfg',config);
      signal.throwIfAborted();
      // Consuming clean is a confirmed file+directory commit BEFORE native can
      // open the writable target. A crashed process leaves booting, never clean.
      await store.booting(epoch);await store.verify();
      signal.throwIfAborted();this.state='booting';this.#progress('boot-start');
      let raw;
      try{raw=(this.#internals.createSession??(path=>loadLinuxNative({nativeLibraryDirectory}).create(path)))(configPath);}
      catch(cause){this.#creationQuarantined=cause.code==='ERR_OHOS_LINUX_CREATE_QUARANTINED';this.#transportDebt=cause.linuxUnsettledFd!==undefined;if(cause.linuxJoin){this.#session={socket:{destroy(){}},requestStop(){},join:async()=>{const result=await cause.linuxJoin;this.nativeRetirement=result;return result;}};}throw cause;}
      let joining;this.#session={socket:raw.socket,requestStop:()=>raw.requestStop(),join:()=>joining??=(async()=>{const result=await raw.join();this.nativeRetirement=result;return result;})()};
      // Observe only fixed, bounded installer markers; these never imply READY.
      let line='';const installFailure=deferred();const observe=bytes=>{
        try{line+=bytes.toString('utf8');let index;while((index=line.indexOf('\n'))>=0){const item=line.slice(0,index).trim();line=line.slice(index+1);if(item==='__DSH_INSTALL_FAILED__')throw error('ERR_OHOS_LINUX_INSTALL_GUEST','Guest installer failed');if(/^__DSH_INSTALL_(BEGIN|BASE|TOOLS|PIVOT)__$/.test(item))this.#progress('guest-install',{step:item.slice(14,-2).toLowerCase()});}if(line.length>131072)line=line.slice(-131072);}catch(cause){installFailure.reject(cause);}
      };raw.socket.on('data',observe);
      this.#backend=new LinuxRuntimeBackend({nativeLibraryDirectory,configPath,epoch,temporaryRoot:join(this.#attempt,'spill'),exports:exports.map(item=>item.tag)},{createSession:()=>this.#session});
      const cancelled=deferred();const onAbort=()=>cancelled.reject(signal.reason??error('ABORT_ERR','Installation cancelled'));signal.addEventListener('abort',onAbort,{once:true});if(signal.aborted)onAbort();
      const timer=setTimeout(()=>installFailure.reject(error('ERR_OHOS_LINUX_INSTALL_TIMEOUT','Guest did not confirm opening before install deadline')),bootTimeoutMs);
      try{await Promise.race([this.#backend.opened,cancelled.promise,installFailure.promise]);}finally{clearTimeout(timer);signal.removeEventListener('abort',onAbort);raw.socket.removeListener('data',observe);}
      signal.throwIfAborted();
      // Publication is data, and happens only after actual 903 opened. It does
      // not authorize workspace mounts or assert full VM deallocation/restart.
      const descriptor={version:2,persistentInstanceId:this.#persistentId,bootMode:this.#bootMode,epoch,directory:this.#attempt,target:store.target,archiveSha256:manifest.archive.sha256,state:'opened-private-guest',workspaceLease:false};
      signal.throwIfAborted();await store.active();this.#published=true;signal.throwIfAborted();
      this.active=Object.freeze(descriptor);this.backend=this.#backend;this.state='active';this.#progress('opened-private-guest');return {backend:this.backend,active:this.active};
    }catch(cause){this.#retainedExisting||=cause.linuxDataRetained===true;await this.#retireAndClean();throw cause;}
  }
  async #retireAndClean(){
    if(this.#cleanup)return this.#cleanup;
    this.#cleanup=(async()=>{
      let fault,closed;this.state='stopping';
      if(this.#session){try{closed=await this.#backend?.dispose();}catch(cause){fault=cause;}try{this.#session.requestStop();await this.#session.join();}catch(cause){fault??=cause;}this.#session.socket.destroy();}
      let retired=!this.#creationQuarantined&&!this.#transportDebt&&(!this.#session||(this.nativeRetirement?.joined===true&&this.nativeRetirement.retirementError===false&&(this.nativeRetirement.fdRetirement===undefined||this.nativeRetirement.fdRetirement?.retired===true)));
      this.backend=undefined;this.active=undefined;this.state='quarantined';
      // Unpublished attempts can be removed only after native retirement.
      // Published writable instances belong to the user and survive shutdown.
      let filesRemoved=false,cleanCheckpoint=false;
      const guestClose=closed?.closed===true&&cleanGuestClose(closed.guestClose,this.#epoch)?Object.freeze({...closed.guestClose}):null;
      try{
        if(this.#published&&retired&&guestClose){await this.#instance.clean(closed);cleanCheckpoint=true;}
        else if(this.#instance&&!this.#published&&!this.#retainedExisting&&retired){await this.#instance.removeUnpublished();filesRemoved=true;}
      }catch(cause){fault??=cause;}
      if(retired&&this.#instance){try{await this.#instance.release();}catch(cause){fault??=cause;retired=false;cleanCheckpoint=false;}}
      if(retired)this.state=this.#session?'stopped-quarantined':'cancelled-before-vm';
      return {resourcesRetired:retired,filesRemoved,dataRetained:this.#published||this.#retainedExisting||!!this.#instance&&!filesRemoved,ownerQuarantined:!!this.#session||this.#creationQuarantined,native:this.nativeRetirement,guestClose,cleanCheckpoint,releaseError:fault};
    })();return this.#cleanup;
  }
  async dispose(){this.#disposed=true;this.#abort.abort(error('ABORT_ERR','Linux owner disposed'));if(this.#promise)await this.#promise.catch(()=>{});return this.#retireAndClean();}
}
export const createLinuxInstallationOwner=(options)=>new LinuxInstallationOwner(options);

// The explicit 重新安装 Linux: deletes every retained instance under the same
// trusted root and real flock an owner would take; no VM, download or manifest.
// Callers must first know that no owner of this process holds the data.
export function discardLinuxInstallation({directory},internals={}){
  if(!isAbsolute(directory??''))throw new TypeError('Trusted private directory is required');
  return discardLinuxInstance({directory,lockExclusive:internals.lockExclusive??linuxHostLock()},internals.instance);
}

// Fixed signed-resource layout. Only the host runtime publication supplies this
// directory; a manifest cannot select arbitrary host files for guest block IO.
export async function loadLinuxInstallationManifest({assetsDirectory}){
  if(typeof assetsDirectory!=='string'||!isAbsolute(assetsDirectory)||assetsDirectory.includes('\0'))throw new TypeError('Trusted Linux asset directory required');
  const file=await open(join(assetsDirectory,'install-manifest.json'),constants.O_RDONLY|constants.O_NOFOLLOW);let manifest;
  try{const info=await file.stat();if(!info.isFile()||info.size>65536)throw new TypeError('Invalid Linux manifest');manifest=JSON.parse(await file.readFile('utf8'));}finally{await file.close();}
  const names={bios:'bbl64.bin',kernel:'kernel-riscv64.bin',tools:'tools.block',bootstrap:'bootstrap.ext4.gz',empty:'empty.ext4.gz'};
  for(const [key,name] of Object.entries(names)){if(manifest[key]?.path!==name)throw new TypeError('Linux manifest asset name is not fixed');manifest[key]={...manifest[key],path:join(assetsDirectory,name)};}
  return manifest;
}
