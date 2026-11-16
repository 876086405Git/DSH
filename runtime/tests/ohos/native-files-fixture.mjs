// Executes production ETS against real Linux descriptors. OH picker/URI/grants and Flutter are explicit doubles.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { createRequire } from 'node:module';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { promisify } from 'node:util';
import { randomUUID } from 'node:crypto';
import vm from 'node:vm';
const repo=fileURLToPath(new URL('../../../',import.meta.url));
assert(process.env.OHOS_TYPESCRIPT_PREFIX);
const ts=createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX,'package.json'))('typescript');
export const deferred=()=>Promise.withResolvers();
export const plain=value=>value instanceof Map?Object.fromEntries([...value].map(([k,v])=>[k,plain(v)])):
  Array.isArray(value)?Array.from(value,plain):value;
export async function until(check,description='condition'){
 const end=Date.now()+5000;while(!check()){if(Date.now()>end)throw Error('timed out: '+description);await new Promise(r=>setImmediate(r));}
}
export async function filesFixture(t,options={}){
 let opt=options,timerNext=0;const channels=[],pickers=[],operations=[],fds=new Set(),uris=new Map(),timers=new Map(),modules=new Map(),utd=[];
 const root=await fsp.mkdtemp(join(tmpdir(),'dsh-native-files-'));t.after(async()=>{
  for(const fd of fds){try{await promisify(fs.close)(fd);}catch{}}
  await fsp.rm(root,{recursive:true,force:true});
 });
 const app={filesDir:join(root,'files'),cacheDir:join(root,'cache')};
 const stat=s=>({size:opt.statSize??s.size,isFile:()=>s.isFile(),isDirectory:()=>s.isDirectory()});
 const api={OpenMode:{READ_ONLY:fs.constants.O_RDONLY,NONBLOCK:fs.constants.O_NONBLOCK},
  async open(uri,flags){operations.push({op:'open',uri,flags});if(opt.open)await opt.open(uri);assert(uris.has(uri),'URI was not system-granted');
   const fd=await promisify(fs.open)(uris.get(uri),flags);fds.add(fd);return{fd};},
  async stat(fd){operations.push({op:'stat',fd});if(opt.stat)await opt.stat(fd);return stat(await promisify(fs.fstat)(fd));},
  async read(fd,buffer,args){operations.push({op:'read',fd,length:args.length,offset:args.offset});if(opt.read)await opt.read(fd,buffer,args);
   if(opt.readCount!==undefined)return opt.readCount;
   return(await promisify(fs.read)(fd,Buffer.from(buffer),0,Math.min(args.length,opt.maxRead??Infinity),args.offset)).bytesRead;},
  async close(file){const fd=typeof file==='number'?file:file.fd;operations.push({op:'close',fd});if(opt.close)await opt.close(fd);
   await promisify(fs.close)(fd);fds.delete(fd);}
 };
 class DocumentPicker{constructor(context){assert.equal(context,app);}select(options){const wait=deferred();pickers.push({kind:'document',options:{...options},wait});if(opt.pickThrow)throw Error('picker unavailable');return wait.promise;}}
 class PhotoPicker{select(options){const wait=deferred();pickers.push({kind:'photo',options:{...options},wait});if(opt.pickThrow)throw Error('picker unavailable');return wait.promise;}}
 class MethodChannel{constructor(messenger,name){this.name=name;channels.push(this);}setMethodCallHandler(handler){this.handler=handler;}}
 class Uri{constructor(value){const parsed=new URL(value);this.scheme=parsed.protocol.slice(0,-1);this.authority=parsed.host;this.path=parsed.pathname;this.query=parsed.search.slice(1);this.fragment=parsed.hash.slice(1);}}
 const boundaries={
  '@ohos.file.fs':{default:api},'@ohos.file.picker':{default:{DocumentViewPicker:DocumentPicker,DocumentSelectOptions:class{},DocumentSelectMode:{FILE:0}}},
  '@ohos.file.photoAccessHelper':{default:{PhotoViewPicker:PhotoPicker,PhotoSelectOptions:class{},PhotoViewMIMETypes:{IMAGE_TYPE:'image/*',IMAGE_VIDEO_TYPE:'*/*'}}},
  '@ohos.file.fileuri':{default:{FileUri:class{constructor(value){this.name=decodeURIComponent(new URL(value).pathname.split('/').at(-1));}}}},
  '@ohos.uri':{default:{URI:Uri}},'@ohos.data.uniformTypeDescriptor':{default:{getUniformDataTypeByFilenameExtension:value=>{utd.push(value);if(opt.utdThrow)throw Error('UTD unavailable');return value;},
   getTypeDescriptor:value=>({mimeTypes:[opt.utdMime??({'.txt':'text/plain','.jpg':'image/jpeg','.mp4':'video/mp4'})[value]??'application/octet-stream']})}},
  '@ohos.util':{default:{generateRandomUUID:()=>randomUUID()}},'@ohos.hilog':{default:{warn(){operations.push({op:'warning'});}}},
  '@ohos/flutter_ohos':{MethodChannel}
 };
 function load(path){if(modules.has(path))return modules.get(path).exports;const module={exports:{}};modules.set(path,module);
  const source=ts.transpileModule(fs.readFileSync(path,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext(source,{module,exports:module.exports,Map,Set,WeakSet,ArrayBuffer,Uint8Array,Promise,Error,
   setTimeout:(callback,delay)=>{const id=++timerNext;timers.set(id,{callback,delay});return id;},clearTimeout:id=>timers.delete(id),
   canIUse:cap=>!(opt.missingCaps??[]).includes(cap),require(name){if(name.startsWith('.'))return load(resolve(dirname(path),name+'.ets'));
    assert(name in boundaries,'unadapted boundary '+name);return boundaries[name];}
  },{filename:path});return module.exports;
 }
 const Plugin=load(resolve(repo,'app/ohos/entry/src/main/ets/plugins/NativeFilesPlugin.ets')).default;
 const policy=load(resolve(repo,'app/ohos/entry/src/main/ets/plugins/NativeFilePolicy.ets'));
 function attach(plugin=new Plugin(),foreground=true){const engine={getApplicationContext:()=>app,getBinaryMessenger:()=>({})};
  const ui={context:app},ability={getAbility:()=>ui};plugin.onAttachedToEngine(engine);plugin.onAttachedToAbility(ability);if(foreground)Plugin.onForeground(ui);
  return{plugin,engine,ability,methods:channels.at(-1),foreground:()=>Plugin.onForeground(ui),background:()=>Plugin.onBackground(ui)};
 }
 function call(methods,method,args={}){const wait=deferred(),replies=[];const respond=v=>{replies.push(v);wait.resolve(v);if(opt.replyFailure)throw Error('retired reply transport');};
  methods.handler.onMethodCall({method,args:new Map(Object.entries(args)),argument:key=>args[key]},
   {success:value=>respond({value:plain(value)}),error:(error,message,details)=>respond({error,message,details:plain(details)}),notImplemented:()=>respond({missing:true})});
  return{done:wait.promise,replies};
 }
 async function file(name,bytes,kind='docs'){const path=join(root,'source-'+uris.size);await fsp.writeFile(path,bytes);
  const uri=`file://${kind}/storage/${uris.size}/${encodeURIComponent(name)}`;uris.set(uri,path);return{uri,path};}
 function select(values,picker=pickers.at(-1)){picker.wait.resolve(picker.kind==='photo'?{photoUris:values}:values);}
 return{...attach(),Plugin,policy,attach,call,file,select,root,app,uris,pickers,operations,fds,timers,utd,
  change:next=>{opt={...opt,...next};},expire:()=>{for(const [id,timer]of timers){timers.delete(id);timer.callback();}},
  before:()=>({fds:fds.size,operations:operations.length})};
}
export const owner='a'.repeat(32);
export const args=(extra={})=>({owner,images:false,maxFiles:4,maxBytes:8*1024*1024,maxTotalBytes:16*1024*1024,userGesture:true,...extra});
