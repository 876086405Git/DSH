// Real ETS bodies. AudioCapturer and monotonic time are explicit OS boundaries.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

assert(process.env.OHOS_TYPESCRIPT_PREFIX, 'set OHOS_TYPESCRIPT_PREFIX');
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
const repo = fileURLToPath(new URL('../../../', import.meta.url));
export const deferred = () => Promise.withResolvers();
export const settle = () => new Promise(resolve => setImmediate(resolve));
export function pcm(value, frames = 1) {
  const bytes = new Uint8Array(frames * 640), view = new DataView(bytes.buffer);
  for (let i = 0; i < bytes.length; i += 2) view.setInt16(i, value, true);
  return bytes;
}
export function captureFixture(options = {}) {
  const cache = new Map(), capturers = [], events = [], api = [], screenCalls=[],channels=[],streams=[];
  let inRead = false, current = true, time = 0, released = 0;
  const check = name => { assert(!inRead, 'audio API inside readData: ' + name); api.push(name); };
  const session = { active: false, device: 1000, devices: [], callbacks: new Set(),
    isAudioSessionActivated() { return this.active; }, getDefaultOutputDevice() { return this.device; },
    on(name, callback) { this.callbacks.add(callback); }, off(name, callback) { this.callbacks.delete(callback); },
    async activateAudioSession() { this.active = true; }, async deactivateAudioSession() { this.active = false; },
    async setDefaultOutputDevice(device) {
      if (device !== 1000) await options.route?.(device === 2);
      this.device = device; this.devices.push(device);
    }
  };
  class Capturer {
    constructor(config) { this.config = config; this.listeners = new Map(); this.releases = 0; this.stops = 0; capturers.push(this); }
    getStreamInfoSync() { check('format'); return { samplingRate:16000, channels:1, sampleFormat:1, encodingType:0, ...options.format }; }
    getOverflowCountSync() { check('overflow'); return options.overflow ?? 0; }
    on(name, cb) { check('on:' + name); if (options.onFailure === name) throw Error('subscription'); this.listeners.set(name, cb); }
    off(name) { check('off:' + name); this.listeners.delete(name); }
    async start() { check('start'); await options.start?.(this); }
    async stop() { check('stop'); this.stops++; await options.stop?.(this); }
    async release() { check('release'); this.releases++; await options.release?.(this); }
    data(bytes, advance = bytes.length / 32) {
      time += advance;
      const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length);
      inRead = true;
      try { this.listeners.get('readData')?.(buffer); } finally { inRead = false; }
      new Uint8Array(buffer).fill(0x55); // SDK owns and may immediately recycle the read buffer.
    }
    interrupt(hintType = 3) { this.listeners.get('audioInterrupt')?.({ hintType }); }
  }
  const audio = {
    getAudioManager:()=>({getSessionManager:()=>session}),AudioConcurrencyMode:{CONCURRENCY_DEFAULT:0},DeviceType:{EARPIECE:1,SPEAKER:2,DEFAULT:1000},
    AudioSamplingRate:{SAMPLE_RATE_16000:16000}, AudioChannel:{CHANNEL_1:1},
    AudioSampleFormat:{SAMPLE_FORMAT_S16LE:1}, AudioEncodingType:{ENCODING_TYPE_RAW:0},
    SourceType:{SOURCE_TYPE_VOICE_COMMUNICATION:7}, InterruptHint:{INTERRUPT_HINT_STOP:3,INTERRUPT_HINT_PAUSE:2,INTERRUPT_HINT_MUTE:6},
    async createAudioCapturer(config) { check('create'); await options.create?.(); return new Capturer(config); }
  };
  const screen={keep:options.initialKeep===true,getWindowProperties(){return {isKeepScreenOn:this.keep};},
    async setWindowKeepScreenOn(on){screenCalls.push(on);this.keep=on;await options.keepScreen?.(on);}};
  class MethodChannel {
    constructor(messenger,name){this.messenger=messenger;this.name=name;channels.push(this);}
    setMethodCallHandler(handler){this.handler=handler;}
    invokeMethod(method,args){assert(!inRead);events.push({method,...Object.fromEntries(args)});}
  }
  class PcmBackend {
    constructor(config,current,listener){this.config=config;this.current=current;this.listener=listener;this.closed=false;this.ducks=[];this.speakers=[];this.bytes=0;streams.push(this);}
    async open(){await options.pcmOpen?.(this);return this.current();}
    write(bytes){this.bytes+=bytes.length;return this.bytes;}
    waiting(){return this.bytes;}
    end(){this.listener.terminal('done','');}
    stop(){if(this.closing)return this.closing;this.closing=(async()=>{await options.pcmStop?.(this);this.closed=true;this.listener.terminal('stopped','');})();return this.closing;}
    async duck(on){await options.duck?.(on);this.ducks.push(on);}
    async setSpeaker(on){await options.route?.(on);this.speakers.push(on);}
    started(){this.listener.started();}
  }
  const boundaries = {
    '@ohos/flutter_ohos':{MethodChannel},
    '@ohos.multimedia.audio':{default:audio},
    '@ohos.systemDateTime':{default:{TimeType:{STARTUP:0}, getUptime(kind, ns) { assert.equal(kind,0); assert.equal(ns,false); return time; }}},
    '@ohos.window':{default:{async getLastWindow(context){assert.equal(context.applicationInfo.accessTokenId,321);await options.getWindow?.();return screen;}}},
    '@ohos.abilityAccessCtrl':{default:{GrantStatus:{PERMISSION_GRANTED:0}, createAtManager:()=>({
      async checkAccessToken(token, permission) { assert.equal(token,321);assert.equal(permission,'ohos.permission.MICROPHONE');
        await options.permission?.();return options.granted===false?-1:0; }
    })}}
  };
  function load(name) {
    const path = name.startsWith('/') ? name : resolve(repo,'app/ohos/entry/src/main/ets/plugins',name+'.ets');
    if (cache.has(path)) return cache.get(path).exports;
    const module = { exports:{} }; cache.set(path,module);
    const source = ts.transpileModule(fs.readFileSync(path,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
    vm.runInNewContext(source,{module,exports:module.exports,Uint8Array,ArrayBuffer,DataView,Map,Set,Promise,Error,
      canIUse:cap=>{assert.equal(cap,'SystemCapability.Multimedia.Audio.Capturer');return options.supported!==false;},
      require(name) { if(name==='./OhosPcmStream')return {OhosPcmStream:PcmBackend};
        if (name.startsWith('.')) return load(resolve(dirname(path),name+'.ets'));
        assert(name in boundaries,'unadapted boundary '+name); return boundaries[name]; }
    },{filename:path});
    return module.exports;
  }
  function make() {
    const {OhosCallCapture} = load('OhosCallCapture');
    const send = event => { assert(!inRead,'Flutter callback inside readData'); events.push(event); };
    return new OhosCallCapture(()=>current,{
      speechStart:over=>send({type:'speechStart',over}),
      utterance:(wav,ms)=>send({type:'utterance',wav,ms}),
      level:value=>send({type:'micLevel',value}),
      error:reason=>send({type:'callError',reason})
    },()=>{ released++; });
  }
  function call() {
    const {OhosSpeechCall}=load('OhosSpeechCall');
    return new OhosSpeechCall(()=>current,{
      speechStart:over=>events.push({type:'speechStart',over}),
      utterance:(wav,ms)=>events.push({type:'utterance',wav,ms}),
      level:value=>events.push({type:'micLevel',value}),
      error:reason=>events.push({type:'callError',reason})
    },async on=>{await options.route?.(on);});
  }
  function speech(){
    const Plugin=load('SpeechPlugin').default,plugin=new Plugin(),messenger={};
    const context={applicationInfo:{accessTokenId:321}},ui={context},ability={getAbility:()=>ui},engine={getBinaryMessenger:()=>messenger};
    plugin.onAttachedToEngine(engine);plugin.onAttachedToAbility(ability);Plugin.onForeground(ui);
    const methods=channels.at(-1);
    function request(method,args={}){
      const done=deferred();methods.handler.onMethodCall({method,argument:key=>args[key]},
        {success:value=>done.resolve({value}),error:(error,message,details)=>done.resolve({error,message,details}),notImplemented:()=>done.resolve({missing:true})});
      return done.promise;
    }
    return {plugin,engine,ability,request,background(){Plugin.onBackground(ui);},foreground(){Plugin.onForeground(ui);}};
  }
  return {load,make,call,speech,screen,screenCalls,channels,streams,session,context:{applicationInfo:{accessTokenId:321}},capturers,events,api,retire(){current=false;},get released(){return released;}};
}
