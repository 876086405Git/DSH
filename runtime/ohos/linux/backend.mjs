import { createRequire } from 'node:module';
import { isAbsolute } from 'node:path';
import { statSync } from 'node:fs';
import { LinuxController, failure, offset } from './controller.mjs';
import { GuestInput, GuestOutput } from './streams.mjs';
import { loadLinuxNative } from './native-session.mjs';
// Dependencies are composed beside the existing process runtime, not beside
// this optional provider. Use that fixed package context and its public export.
const requireProcess = createRequire(new URL('../process/runtime.mjs',import.meta.url));
const { OutputCollector } = requireProcess('@deepseek-ai/dsh-subprocess-local/output');
const deferred=()=>{const value=Promise.withResolvers();value.promise.catch(()=>{});return value;};
const argvValid=argv=>Array.isArray(argv)&&argv.length>0&&argv[0]&&argv.every(x=>typeof x==='string'&&!x.includes('\0'));
const checkedMode=mode=>mode==='pipe'||mode==='ignore'||mode==='inherit'||(mode&&typeof mode==='object'&&Number.isSafeInteger(mode.maxBytes)&&mode.maxBytes>=0&&(!mode.spill||(Number.isSafeInteger(mode.spill.maxBytes)&&mode.spill.maxBytes>0)));
const knownSignals=new Set(['SIGTERM','SIGKILL']);
const inside=(root,path)=>path===root||path.startsWith(root+'/');
const mountValid=item=>item&&typeof item.source==='string'&&typeof item.target==='string'&&isAbsolute(item.target)&&item.target!=='/'&&typeof item.readOnly==='boolean';

export class LinuxRuntimeBackend {
  capabilities=Object.freeze({confinement:Object.freeze([]),streamingStdin:true,workspaceLease:false,pty:false});
  live=new Set();closed=false;state='opening';
  #exports;#mounts=false;#opened=deferred();#closedFrame=deferred();#jobs=new Map();#queue=[];#active;#nextJob=0;#session;#controller;#failure;#disposePromise;#guestClose=null;
  constructor({nativeLibraryDirectory,configPath,epoch,temporaryRoot,exports=[],onSpillFailure=()=>{},closeTimeoutMs=10000}={},internals={}) {
    if(typeof temporaryRoot!=='string'||!isAbsolute(temporaryRoot)||temporaryRoot.includes('\0')||!statSync(temporaryRoot).isDirectory())throw new TypeError('Linux collector root must be a trusted existing private directory');
    if(typeof configPath!=='string'||!isAbsolute(configPath)||configPath.includes('\0')||!/^[a-f0-9]{64}$/.test(epoch))throw new TypeError('Trusted native config and private epoch are required');
    if(!Number.isFinite(closeTimeoutMs)||closeTimeoutMs<=0||closeTimeoutMs>2147483647)throw new TypeError('Invalid guest close timeout');
    this.closeTimeoutMs=closeTimeoutMs;
    // Tags of the App directories this VM booted with; jobs may mount only these.
    this.#exports=new Set(exports);
    this.temporaryRoot=temporaryRoot;this.onSpillFailure=onSpillFailure;this.opened=this.#opened.promise;
    // Explicit owner-only seam for protocol tests; never argv/env/SIM selected.
    const createSession=internals.createSession??(path=>loadLinuxNative({nativeLibraryDirectory}).create(path));
    this.#session=createSession(configPath);
    this.#controller=new LinuxController(this.#session.socket,epoch);
    this.#controller.on('frame',frame=>this.#frame(frame));
    this.#controller.on('fault',error=>this.#quarantine(error));
  }
  // A historical wire fact alone is not a clean checkpoint. Owners must use
  // successful dispose() plus actual native retirement, never this after catch.
  get guestClose(){return this.#guestClose;}
  prepare(_argv,_policy,signal){signal?.throwIfAborted();throw failure('ERR_OHOS_BACKEND_CONFINEMENT','Linux guest does not yet provide authorized workspace mounts or read-only confinement; no execution ticket was issued');}
  async resolveExecutable(command,_env,signal){signal?.throwIfAborted();if(typeof command!=='string'||!command||command.includes('\0')||(!isAbsolute(command)&&command.includes('/')))throw new TypeError('Invalid guest command');return command;}
  async terminalEnvironment(signal){signal?.throwIfAborted();return {platform:'posix',defaultShell:'/bin/sh'};}
  async spawnTerminal(){throw failure('ERR_OHOS_PTY_UNAVAILABLE','Linux PTY is not implemented');}
  spawn(spec){
    if(this.closed||this.#failure)throw this.#failure??failure('ERR_OHOS_PROCESS_CLOSED','Linux backend is closed');
    if(!spec||!argvValid(spec.argv))throw new TypeError('argv must contain NUL-free strings');
    if(spec.policy!==undefined||spec.argv[0]==='/dsh-go/ohos/confined'||spec.argv[0]==='/dsh-go/ohos/linux/confined')throw failure('ERR_OHOS_BACKEND_CONFINEMENT','Linux cannot consume an unenforced workspace policy or ticket');
    const mounts=spec.mounts??[];
    if(!Array.isArray(mounts)||mounts.length>4||!mounts.every(item=>mountValid(item)&&this.#exports.has(item.tag))||(mounts.length&&!this.#mounts))throw failure('ERR_OHOS_LINUX_WORKSPACE_UNAVAILABLE','Guest mounts must name App directories this VM exported, and the guest must support them');
    if(spec.cwd!=='/workspace'&&!mounts.some(item=>inside(item.target,spec.cwd)))throw failure('ERR_OHOS_LINUX_WORKSPACE_UNAVAILABLE','A host cwd must lie inside one of this job\'s App directory mounts; otherwise only the private guest /workspace is admitted');
    if(!Number.isFinite(spec.graceMs)||spec.graceMs<=0||spec.graceMs>2147483647)throw new TypeError('Invalid subprocess graceMs');
    spec.signal?.throwIfAborted();
    const io=spec.stdio;if(!io||io.control!==undefined||!checkedMode(io.stdout)||!checkedMode(io.stderr)||!(io.stdin==='pipe'||io.stdin==='ignore'||(io.stdin&&typeof io.stdin.data==='string')))throw failure('ERR_OHOS_LINUX_STDIO','Unsupported Linux stdio disposition');
    const env={PATH:'/usr/bin:/bin',HOME:'/workspace',TMPDIR:'/tmp',LANG:'C.UTF-8',...spec.env};
    for(const key of Object.keys(env)){if(env[key]===undefined){delete env[key];continue;}if(!key||key.includes('=')||key.includes('\0')||typeof env[key]!=='string'||env[key].includes('\0'))throw new TypeError('Invalid guest environment');}
    const command={argv:[...spec.argv],cwd:spec.cwd,env,...(mounts.length?{mounts:mounts.map(({tag,source,target,readOnly})=>({tag,source,target,readOnly}))}:{})};
    if(Buffer.byteLength(JSON.stringify(command))>60000)throw failure('ERR_OHOS_LINUX_ARGUMENTS','Guest start frame exceeds bound');
    if(this.#nextJob>=Number.MAX_SAFE_INTEGER)throw failure('ERR_OHOS_LINUX_PROTOCOL','Guest job identity exhausted');
    const job={id:++this.#nextJob,command,spec,wire:false,started:false,admitted:false,cancelRequested:false,complete:false,unknown:false,startedResult:deferred(),done:deferred(),gone:deferred(),outputs:{},collected:{}};
    const send=(op,fields={},sent)=>this.#controller.send(op,{job:job.id,...fields},sent);
    job.input=new GuestInput({send,onFault:error=>this.#quarantine(error)});
    for(const label of ['stdout','stderr']){
      const mode=io[label];const collector=typeof mode==='object'?new OutputCollector(mode.maxBytes,label,mode.spill&&{maxBytes:mode.spill.maxBytes,dir:this.temporaryRoot,onFailure:this.onSpillFailure}):undefined;
      if(collector)job.collected[label]=collector;
      job.outputs[label]=new GuestOutput({mode,collector,label,send:(stream,through,sent)=>send('ack',{stream,through:String(through)},sent),onFault:error=>this.#quarantine(error),onSinkClosed:()=>this.#cancel(job,'SIGTERM')});
    }
    const handle={stdin:io.stdin==='pipe'?job.input:undefined,stdout:job.outputs.stdout.readable,stderr:job.outputs.stderr.readable,control:undefined,collected:job.collected,started:job.startedResult.promise,done:job.done.promise,
      terminate:signal=>this.#cancel(job,typeof signal==='string'?signal:'SIGTERM'),
      waitForExit:async signal=>{if(job.unknown)throw this.#failure;if(job.complete)return true;if(signal?.aborted)return false;const interrupted=deferred();const abort=()=>interrupted.resolve(false);signal?.addEventListener('abort',abort,{once:true});try{return await Promise.race([job.gone.promise,interrupted.promise]);}finally{signal?.removeEventListener('abort',abort);}}};
    job.handle=handle;this.live.add(handle);this.#jobs.set(job.id,job);this.#queue.push(job);spec.signal?.addEventListener('abort',handle.terminate,{once:true});
    queueMicrotask(()=>this.#next());return handle;
  }
  #next(){
    if(this.state!=='opened'||this.#active||this.closed)return;
    while(this.#queue.length){const job=this.#queue.shift();if(job.complete)continue;this.#active=job;
      try{job.wire=true;this.#controller.send('start',{job:job.id,...job.command});job.input.enable();
        if(job.spec.stdio.stdin==='ignore')job.input.end();else if(typeof job.spec.stdio.stdin==='object')job.input.end(Buffer.from(job.spec.stdio.stdin.data));else if(job.input.destroyed)job.input.endNow();
      }catch(error){this.#quarantine(error);}break;
    }
  }
  #cancel(job,signal){
    if(!knownSignals.has(signal))throw failure('ERR_OHOS_LINUX_SIGNAL','Guest cancellation accepts SIGTERM or SIGKILL requests and uses PID-namespace SIGKILL; other signals are unsupported');
    if(job.complete||job.unknown||job.cancelRequested)return;
    job.cancelRequested=true;job.requestedSignal=signal;job.input.stop();
    if(!job.wire){this.#settle(job,{exitCode:null,signal:null,cancelled:true,notStarted:true,requestedSignal:signal});return;}
    try{job.cancelTimer=setTimeout(()=>this.#quarantine(failure('ERR_OHOS_LINUX_CANCEL_UNCONFIRMED','Cancellation grace expired without guest release and sink completion')),job.spec.graceMs);this.#controller.send('cancel',{job:job.id});}catch(error){this.#quarantine(error);}
  }
  #frame(frame){
    try{
      if(frame.kind==='opened'){
        if(this.state!=='opening'||frame.job!==null||frame.capabilities?.streamingStdin!==true||frame.capabilities?.pidNamespace!==true||frame.capabilities?.workspaceLease!==false)throw failure('ERR_OHOS_LINUX_PROTOCOL','Guest opened capability mismatch');
        this.#mounts=frame.capabilities.mounts===true;this.state='opened';this.#opened.resolve();this.#next();return;
      }
      if(frame.kind==='closed'||frame.kind==='close-failed'){
        if(this.#controller.agentClosed||this.state!=='closing'||frame.job!==null||this.live.size||this.#active)throw failure('ERR_OHOS_LINUX_PROTOCOL','Guest closed before all job release facts');
        if(frame.syncMethod!=='syncfs'||frame.syncScope!=='rootfs')throw failure('ERR_OHOS_LINUX_PROTOCOL','Guest close lacks fixed root filesystem sync evidence');
        if(frame.kind==='close-failed'){
          if(frame.rootfsSync!==false||frame.code!=='ERR_OHOS_GUEST_SYNC'||!(frame.errno===null||Number.isInteger(frame.errno)&&frame.errno>0&&frame.errno<=4095))throw failure('ERR_OHOS_LINUX_PROTOCOL','Invalid guest sync failure evidence');
          const error=failure('ERR_OHOS_LINUX_GUEST_SYNC','Guest root filesystem synchronization failed');error.errno=frame.errno;throw error;
        }
        if(frame.rootfsSync!==true)throw failure('ERR_OHOS_LINUX_PROTOCOL','Guest close did not confirm root filesystem synchronization');
        this.#guestClose=Object.freeze({epoch:frame.epoch,rootfsSync:true,syncMethod:'syncfs',syncScope:'rootfs'});
        this.#controller.agentClosed=true;this.#closedFrame.resolve();return;
      }
      const job=this.#active;if(!job||frame.job!==job.id||job.complete||job.unknown)throw failure('ERR_OHOS_LINUX_PROTOCOL','Guest active job identity mismatch');
      if(frame.kind==='started'){if(job.started)throw failure('ERR_OHOS_LINUX_PROTOCOL','Duplicate job start');job.started=true;return;}
      if(!job.started)throw failure('ERR_OHOS_LINUX_PROTOCOL','Job event precedes start');
      if(frame.kind==='admitted'){if(job.admitted)throw failure('ERR_OHOS_LINUX_PROTOCOL','Duplicate admission');job.admitted=true;job.startedResult.resolve();}
      else if(frame.kind==='data'){
        const stream=job.outputs[frame.stream];if(!stream||typeof frame.data!=='string'||frame.data.length>5464)throw failure('ERR_OHOS_LINUX_PROTOCOL','Invalid output frame');
        const bytes=Buffer.from(frame.data,'base64');if(bytes.toString('base64')!==frame.data)throw failure('ERR_OHOS_LINUX_PROTOCOL','Noncanonical output bytes');stream.data(offset(frame.offset),bytes);
      }else if(frame.kind==='eof'){const stream=job.outputs[frame.stream];if(!stream)throw failure('ERR_OHOS_LINUX_PROTOCOL','Unknown EOF stream');stream.end(offset(frame.through));}
      else if(frame.kind==='stdin-ack')job.input.acknowledge(offset(frame.through));
      else if(frame.kind==='stdin-closed'){if(job.stdinClosedEvent)throw failure('ERR_OHOS_LINUX_PROTOCOL','Duplicate stdin close');job.stdinClosedEvent=true;job.input.closeFromGuest();}
      else if(frame.kind==='cancel-requested'){if(!job.cancelRequested||job.cancelAck)throw failure('ERR_OHOS_LINUX_PROTOCOL','Unexpected cancellation acknowledgement');job.cancelAck=true;}
      else if(frame.kind==='complete'){
        if(typeof frame.cancelled!=='boolean'||!((Number.isInteger(frame.exitCode)&&frame.exitCode>=0&&frame.exitCode<=255&&frame.signal===null)||(frame.exitCode===null&&typeof frame.signal==='string'&&/^SIG[A-Z0-9]+$/.test(frame.signal))))throw failure('ERR_OHOS_LINUX_PROTOCOL','Invalid guest outcome');
        if(frame.cancelled&&(!job.cancelRequested||!job.cancelAck))throw failure('ERR_OHOS_LINUX_PROTOCOL','Unrequested guest cancellation');
        for(const label of ['stdout','stderr']){const stream=job.outputs[label];if(!stream.eof||!stream.ended||stream.received!==stream.acked||offset(frame.produced?.[label])!==stream.received)throw failure('ERR_OHOS_LINUX_PROTOCOL','Completion lacks dual EOF and sink ACK barrier');}
        this.#settle(job,{exitCode:frame.exitCode,signal:frame.signal,cancelled:frame.cancelled,...(job.cancelRequested?{requestedSignal:job.requestedSignal}:{})});
      }else if(frame.kind==='failed')throw failure('ERR_OHOS_LINUX_GUEST_REAP','Guest task tree release was not verified');
      else throw failure('ERR_OHOS_LINUX_PROTOCOL','Unknown guest event');
    }catch(error){this.#quarantine(error);}
  }
  #settle(job,outcome){
    if(job.complete||job.unknown)return;
    try{for(const collector of Object.values(job.collected))collector.seal();}catch(error){this.#quarantine(error);return;}
    clearTimeout(job.cancelTimer);job.complete=true;job.spec.signal?.removeEventListener('abort',job.handle.terminate);job.input.guestClosed=true;job.input.destroy();
    if(!job.admitted)job.startedResult.reject(failure('ERR_OHOS_NOT_STARTED','Guest command did not reach admission'));
    for(const stream of Object.values(job.outputs)){if(!stream.eof){stream.eof=true;stream.pump();}}
    this.live.delete(job.handle);this.#jobs.delete(job.id);if(this.#active===job)this.#active=undefined;
    job.gone.resolve(true);job.done.resolve(outcome);queueMicrotask(()=>this.#next());
  }
  #quarantine(cause){
    if(this.#failure)return;const error=failure('ERR_OHOS_LINUX_UNKNOWN','Guest completion/resource state is unknown; owner remains quarantined');error.cause=cause;
    this.#failure=error;this.closed=true;this.state='quarantined';this.#opened.reject(error);this.#closedFrame.reject(error);
    for(const job of this.#jobs.values()){clearTimeout(job.cancelTimer);job.unknown=true;job.spec.signal?.removeEventListener('abort',job.handle.terminate);job.input.cancelled=true;job.input.destroy(error);for(const stream of Object.values(job.outputs))stream.fail(error);for(const collector of Object.values(job.collected)){try{collector.seal();}catch{}}job.startedResult.reject(error);job.done.reject(error);job.gone.reject(error);}
    // Keep live jobs and the native owner as unresolved evidence. No synthetic
    // complete/closed or removal of caller workspace/spill roots.
    if(!this.#controller.failed)this.#controller.break(error);
  }
  dispose(){
    if(this.#disposePromise)return this.#disposePromise;this.closed=true;
    this.#disposePromise=(async()=>{
      let failureDuringClose=this.#failure;
      try{
        if(!failureDuringClose){if(this.state==='opening')throw failure('ERR_OHOS_LINUX_NOT_OPENED','Disposal requested before guest opening was confirmed');await this.opened;const jobs=[...this.#jobs.values()];for(const job of jobs){this.#cancel(job,'SIGTERM');for(const stream of Object.values(job.outputs))stream.disposeDrain();}
          await Promise.all(jobs.map(job=>job.gone.promise));this.state='closing';this.#controller.send('close');const timer=setTimeout(()=>this.#quarantine(failure('ERR_OHOS_LINUX_CLOSE_UNCONFIRMED','Guest close was not confirmed')),this.closeTimeoutMs);try{await this.#closedFrame.promise;}finally{clearTimeout(timer);}}
      }catch(error){failureDuringClose=error;}
      this.#session.requestStop();let native;
      try{native=await this.#session.join();if(!native.joined||native.retirementError!==false||![-3,-4].includes(native.apiResult)||(native.fdRetirement!==undefined&&native.fdRetirement?.retired!==true))throw failure('ERR_OHOS_LINUX_NATIVE_RELEASE','Native thread/drive/FD retirement did not confirm shutdown');}
      catch(error){failureDuringClose??=error;}
      this.#session.socket.destroy();
      failureDuringClose??=this.#failure;
      if(failureDuringClose){this.#quarantine(failureDuringClose);throw this.#failure??failureDuringClose;}
      this.state='closed';return {closed:true,guestClose:this.#guestClose,ownerQuarantined:true,native};
    })();this.#disposePromise.catch(()=>{});return this.#disposePromise;
  }
}
export function createLinuxRuntimeBackend(config){return new LinuxRuntimeBackend(config);}
