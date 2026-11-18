// Real ETS, FD validation and production openat helper. AVPlayer/Flutter remain explicit doubles.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { createRequire } from 'node:module';
import { resolve,dirname,join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { promisify } from 'node:util';
import vm from 'node:vm';
assert(process.env.OHOS_TYPESCRIPT_PREFIX&&process.env.OHOS_USER_FILE_ADDON);
const repo=fileURLToPath(new URL('../../../',import.meta.url));
const ts=createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX,'package.json'))('typescript');
const native=createRequire(import.meta.url)(resolve(process.env.OHOS_USER_FILE_ADDON));
export const deferred=()=>Promise.withResolvers();
export async function until(check,description='condition'){const end=Date.now()+5000;while(!check()){if(Date.now()>end)throw Error('timed out: '+description);await new Promise(r=>setImmediate(r));}}
export const key={owner:'a'.repeat(48),generation:1,lease:'bridge-lease'};
const plain=v=>v instanceof Map?Object.fromEntries([...v].map(([k,x])=>[k,plain(x)])):Array.isArray(v)?Array.from(v,plain):v;
export async function mediaFixture(t,options={}){
 let opt=options,inRead=false;const capturers=[],indicators=[],micEvents=[];const root=await fsp.mkdtemp(join(tmpdir(),'dsh-native-media-')),cache=new Map(),players=[],channels=[],events=[],streamErrors=[],operations=[],fds=new Set();
 const context={cacheDir:join(root,'缓存'),tempDir:join(root,'temp'),applicationInfo:{accessTokenId:321}};await fsp.mkdir(context.cacheDir);await fsp.mkdir(context.tempDir);
 const applicationContext={...context,cacheDir:join(root,'application-cache')};await fsp.mkdir(applicationContext.cacheDir);
 t.after(async()=>{for(const fd of fds){try{await promisify(fs.close)(fd);}catch{}}await fsp.rm(root,{recursive:true,force:true});});
 const api={async stat(fd){operations.push({op:'stat',fd});if(opt.stat)await opt.stat(fd);const s=await promisify(fs.fstat)(fd);return{size:opt.size??s.size,isFile:()=>s.isFile()};},
  async close(fd){operations.push({op:'close',fd});if(opt.close)await opt.close(fd);await promisify(fs.close)(fd);fds.delete(fd);}};
 async function opener(root,relative){operations.push({op:'opener',root,relative});assert.equal(root,context.cacheDir);if(opt.beforeOpen)await opt.beforeOpen(root,relative);
  const fd=native.openUserFile(root,relative);fds.add(fd);if(opt.afterOpen)await opt.afterOpen(fd);return fd;}
 class Player{
  constructor(){this.state='idle';this.listeners=new Map();this.history=new Map();this.plays=0;this.pauses=0;this.releases=0;this.released=false;players.push(this);}
  on(type,callback){if(opt.onFailure===type)throw Error('subscription failed');this.listeners.set(type,callback);this.history.set(type,callback);operations.push({op:'on',type});}
  off(type){this.listeners.delete(type);operations.push({op:'off',type});}
  set fdSrc(value){assert.equal(this.state,'idle');this.source={...value};assert(fds.has(value.fd));this.bytes=fs.readFileSync(`/proc/self/fd/${value.fd}`);operations.push({op:'source',value:{...value}});
   if(opt.sourceFailure)throw Error('source failed');if(opt.autoInitialize!==false)queueMicrotask(()=>this.stateEvent('initialized'));}
  set audioRendererInfo(value){assert.equal(this.state,'initialized');this.renderer={...value};operations.push({op:'renderer'});}
  set audioInterruptMode(value){assert(['prepared','playing','paused','completed'].includes(this.state));this.interruptMode=value;}
  stateEvent(state){this.state=state;this.listeners.get('stateChange')?.(state,0);}
  async prepare(){assert.equal(this.state,'initialized');operations.push({op:'prepare'});if(opt.prepare)await opt.prepare(this);this.stateEvent('prepared');}
  async play(){assert(['prepared','paused','completed'].includes(this.state));this.plays++;operations.push({op:'play'});if(opt.play)await opt.play(this);this.stateEvent('playing');}
  async pause(){assert.equal(this.state,'playing');this.pauses++;operations.push({op:'pause'});if(opt.pause)await opt.pause(this);this.stateEvent('paused');}
  async release(){this.releases++;operations.push({op:'release'});assert(this.source===undefined||fds.has(this.source.fd),'FD closed before player release');if(opt.release)await opt.release(this);
   this.released=true;this.stateEvent('released');}
  complete(){this.stateEvent('completed');}
  error(){this.stateEvent('error');this.listeners.get('error')?.({code:5400106,message:'fixture decoder failure'});}
  interrupt(hintType){this.listeners.get('audioInterrupt')?.({eventType:1,forceType:0,hintType});}
  late(state){this.history.get('stateChange')?.(state,0);}
 }
 const media={async createAVPlayer(){operations.push({op:'create'});if(opt.create)await opt.create();if(opt.undefinedPlayer)return undefined;return new Player();}};
 class Capturer {
  constructor(config){this.config=config;this.callbacks=new Map();this.released=false;capturers.push(this);}
  getStreamInfoSync(){return{samplingRate:16000,channels:1,sampleFormat:1,encodingType:0};}
  getOverflowCountSync(){return 0;}
  on(name,callback){assert(!inRead);this.callbacks.set(name,callback);}
  off(name){assert(!inRead);this.callbacks.delete(name);}
  async start(){assert(!inRead);operations.push({op:'capture-start'});if(opt.captureStart)await opt.captureStart(this);}
  async stop(){assert(!inRead);operations.push({op:'capture-stop'});}
  async release(){assert(!inRead);operations.push({op:'capture-release'});if(opt.captureRelease)await opt.captureRelease(this);this.released=true;}
  data(bytes){const buffer=bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength);inRead=true;try{this.callbacks.get('readData')?.(buffer);}finally{inRead=false;}new Uint8Array(buffer).fill(0x55);}
 }
 const audio={AudioSamplingRate:{SAMPLE_RATE_16000:16000},AudioChannel:{CHANNEL_1:1},AudioSampleFormat:{SAMPLE_FORMAT_S16LE:1},AudioEncodingType:{ENCODING_TYPE_RAW:0},SourceType:{SOURCE_TYPE_VOICE_MESSAGE:10,SOURCE_TYPE_VOICE_COMMUNICATION:7},
  async createAudioCapturer(config){assert(!inRead);operations.push({op:'capture-create'});if(opt.captureCreate)await opt.captureCreate(config);return new Capturer(config);},
  StreamUsage:{STREAM_USAGE_VOICE_MESSAGE:5},InterruptMode:{INDEPENDENT_MODE:1},
  InterruptHint:{INTERRUPT_HINT_PAUSE:2,INTERRUPT_HINT_STOP:3,INTERRUPT_HINT_MUTE:6}};
 class MethodChannel{constructor(messenger,name){this.name=name;channels.push(this);}setMethodCallHandler(handler){this.handler=handler;}}
 class EventChannel{constructor(messenger,name){this.name=name;channels.push(this);}setStreamHandler(handler){this.handler=handler;}}
 const access={GrantStatus:{PERMISSION_GRANTED:0},createAtManager:()=>({
  async checkAccessToken(token,permission){assert.equal(token,321);assert.equal(permission,'ohos.permission.MICROPHONE');operations.push({op:'mic-check'});return opt.micGranted===false?-1:0;},
  async requestPermissionsFromUser(context,permissions){assert.equal(context.applicationInfo.accessTokenId,321);assert.deepEqual([...permissions],['ohos.permission.MICROPHONE']);operations.push({op:'mic-request'});return{authResults:[0]};}
 })};
 const boundary={'@ohos.abilityAccessCtrl':{default:access},'@ohos.multimedia.media':{default:media},'@ohos.multimedia.audio':{default:audio},'@ohos.file.fs':{default:api},'@ohos/flutter_ohos':{MethodChannel,EventChannel}};
 function load(path){if(cache.has(path))return cache.get(path).exports;const module={exports:{}};cache.set(path,module);
  const compiled=ts.transpileModule(fs.readFileSync(path,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext(compiled,{module,exports:module.exports,Map,Set,WeakSet,ArrayBuffer,Uint8Array,DataView,Promise,Error,
   canIUse:cap=>{assert(['SystemCapability.Multimedia.Media.AVPlayer','SystemCapability.Multimedia.Audio.Capturer'].includes(cap));return cap.endsWith('AVPlayer')?opt.supported!==false:opt.captureSupported!==false;},
   require(name){if(name.startsWith('.'))return load(resolve(dirname(path),name+'.ets'));assert(name in boundary,'unadapted import '+name);return boundary[name];}
  },{filename:path});return module.exports;
 }
 const Plugin=load(resolve(repo,'app/ohos/entry/src/main/ets/plugins/NativeMediaPlugin.ets')).default;
 const indicator={async show(key,stop){indicators.push({op:'show',key,stop});if(opt.indicatorShow)await opt.indicatorShow(key);},async hide(key){indicators.push({op:'hide',key});if(opt.indicatorHide)await opt.indicatorHide(key);}};
 function attach(plugin=new Plugin(opener,opt.indicator?indicator:undefined),foreground=true){const engine={getApplicationContext:()=>applicationContext,getBinaryMessenger:()=>({setMessageHandler(){}})};
  const ui={context},ability={getAbility:()=>ui};plugin.onAttachedToEngine(engine);plugin.onAttachedToAbility(ability);if(foreground)Plugin.onForeground(ui);
  const methods=channels.at(-2),stream=channels.at(-1);stream.handler.onListen(null,{success:v=>events.push(plain(v)),error:(code,message)=>streamErrors.push({code,message}),endOfStream(){}});
  return{plugin,engine,ability,methods,stream,foreground:()=>Plugin.onForeground(ui),background:()=>Plugin.onBackground(ui)};
 }
 function call(methods,method,args={}){const wait=deferred(),replies=[];const respond=value=>{replies.push(value);wait.resolve(value);if(opt.replyFailure)throw Error('old messenger');};
  methods.handler.onMethodCall({method,args:new Map(Object.entries(args)),argument:key=>args[key]},
   {success:value=>respond({value:plain(value)}),error:(error,message,details)=>respond({error,message,details}),notImplemented:()=>respond({missing:true})});return{done:wait.promise,replies};}
 function attachVoice(){
  const Voice=load(resolve(repo,'app/ohos/entry/src/main/ets/plugins/VoicePlugin.ets')).default;
  const plugin=new Voice(),engine={getBinaryMessenger:()=>({setMessageHandler(){}})},ui={context},ability={getAbility:()=>ui};
  plugin.onAttachedToEngine(engine);plugin.onAttachedToAbility(ability);Voice.onForeground(ui);
  const methods=channels.at(-2),stream=channels.at(-1);
  stream.handler.onListen(null,{success:v=>{assert(!inRead);micEvents.push(plain(v));},error(){},endOfStream(){}});
  return{plugin,engine,methods,stream,background:()=>Voice.onBackground(ui)};
 }
 async function clip(owner=key.owner,bytes=Buffer.from([82,73,70,70,1,2,3,4])){const directory=join(context.cacheDir,'native-media',owner);await fsp.mkdir(directory,{recursive:true});const path=join(directory,'clip');await fsp.writeFile(path,bytes);return path;}
 async function providerTemporaryDirectory(engine,ability){assert(process.env.OHOS_PATH_PROVIDER_SOURCE);
  const Provider=load(resolve(process.env.OHOS_PATH_PROVIDER_SOURCE)).default;const provider=new Provider();provider.onAttachedToEngine(engine);provider.onAttachedToAbility(ability);
  return(await call(channels.at(-1),'getTemporaryDirectory').done).value;}
 return{...attach(),Plugin,attach,attachVoice,call,clip,capturers,indicators,micEvents,providerTemporaryDirectory,players,operations,fds,events,streamErrors,context,applicationContext,root,change:next=>{opt={...opt,...next};}};
}
