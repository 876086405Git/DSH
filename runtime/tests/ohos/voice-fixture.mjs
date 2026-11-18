// Executes real ETS bodies. Flutter, AudioCapturer, HMS and permission are explicit boundary doubles.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
assert(process.env.OHOS_TYPESCRIPT_PREFIX, 'set OHOS_TYPESCRIPT_PREFIX to the pinned TypeScript 5.9.3 installation');
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
const repo = fileURLToPath(new URL('../../../', import.meta.url));
export const deferred = () => Promise.withResolvers();
export const plain = value => value instanceof Map ? Object.fromEntries([...value].map(([k,v])=>[k,plain(v)])) : value;
export async function until(check, description = 'condition') {
  const deadline = Date.now() + 5000;
  while (!check()) { if (Date.now() > deadline) throw new Error('Timed out: ' + description); await new Promise(r => setImmediate(r)); }
}
export function voiceFixture(options = {}) {
  let current = options, inRead = false;
  const channels = [], capturers = [], engines = [], events = [], calls = [], cache = new Map();
  let asks = 0, checks = 0, settings = 0;
  const app = { applicationInfo: { accessTokenId: 321 } };
  const format = { samplingRate: 16000, channels: 1, sampleFormat: 1, encodingType: 0 };
  const api = name => { assert(!inRead, 'AudioCapturer API called inside readData: ' + name); calls.push(name); };
  class Capturer {
    constructor(config) { this.config = config; this.listeners = new Map(); this.started = false; this.released = false; this.stops = 0; this.releases = 0; capturers.push(this); }
    getStreamInfoSync() { api('format'); return { ...format, ...current.format }; }
    getOverflowCountSync() { api('overflow'); if (current.overflowFailure) throw Error('overflow failed'); return current.overflow ?? 0; }
    on(name, cb) { api('on:' + name); if (current.onFailure === name) throw Error('subscription failed'); this.listeners.set(name,cb); }
    off(name) { api('off:' + name); this.listeners.delete(name); }
    async start() { api('start'); if (current.start) await current.start(this); this.started = true; }
    async stop() { api('stop'); this.stops++; if (current.stop) await current.stop(this); this.started = false; }
    async release() { api('release'); this.releases++; if (current.release) await current.release(this); this.started = false; this.released = true; }
    data(bytes) { assert(bytes instanceof Uint8Array); const buf = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength); inRead = true;
      try { this.listeners.get('readData')?.(buf); } finally { inRead = false; }
      new Uint8Array(buf).fill(0x55); return buf;
    }
    interrupt(hintType) { this.listeners.get('audioInterrupt')?.({ hintType }); }
  }
  const audio = {
    AudioSamplingRate: { SAMPLE_RATE_16000:16000 }, AudioChannel:{ CHANNEL_1:1 },
    AudioSampleFormat:{ SAMPLE_FORMAT_S16LE:1 }, AudioEncodingType:{ ENCODING_TYPE_RAW:0 },
    SourceType:{ SOURCE_TYPE_VOICE_MESSAGE:10 }, InterruptHint:{ INTERRUPT_HINT_STOP:3, INTERRUPT_HINT_PAUSE:2, INTERRUPT_HINT_MUTE:6 },
    async createAudioCapturer(config) { calls.push('createAudio'); if (current.createAudio) await current.createAudio(config); if(current.audioNull) return null; return new Capturer(config); }
  };
  class Engine {
    constructor(config) { this.config=config; this.listener=null; this.started=[]; this.finishes=[]; this.cancels=[]; this.shutdowns=0; engines.push(this); }
    setListener(listener) { calls.push('setListener'); if(current.listenerFailure) throw Error('listener failed'); this.listener=listener; }
    startListening(params) { assert(this.listener, 'listener must be set before any engine call'); this.started.push(params); calls.push('recognizerStart'); if(current.recognizerStart) current.recognizerStart(this,params); }
    finish(id) { assert(this.listener); this.finishes.push(id); if(current.finish) current.finish(this,id); }
    cancel(id) { this.cancels.push(id); if(current.recognizerCancel) current.recognizerCancel(this,id); }
    shutdown() { this.shutdowns++; if(current.shutdown) current.shutdown(this); }
    result(text, last=false, id=this.started.at(-1)?.sessionId, final=last) { this.listener?.onResult(id,{result:text,isLast:last,isFinal:final}); }
    complete(id=this.started.at(-1)?.sessionId) { this.listener?.onComplete(id,''); }
    error(code,id=this.started.at(-1)?.sessionId) { this.listener?.onError(id,code,'private fixture text'); }
  }
  const kit={ async createEngine(config) { calls.push('createEngine'); if(current.createEngine) await current.createEngine(config); return new Engine(config); } };
  const access={ GrantStatus:{PERMISSION_GRANTED:0}, createAtManager:()=>({
    async checkAccessToken(token,permission) { checks++; assert.equal(token,321); assert.equal(permission,'ohos.permission.MICROPHONE'); if(current.check) await current.check(); return current.granted===false?-1:0; },
    async requestPermissionsFromUser(context,permissions) { asks++; assert.equal(context.applicationInfo.accessTokenId,321); assert.deepEqual([...permissions],['ohos.permission.MICROPHONE']); if(current.request) return current.request(); return current.permissionResult??{authResults:[0]}; },
    async requestPermissionOnSetting() { settings++; if(current.setting) return current.setting(); return [0]; }
  }) };
  class MethodChannel { constructor(messenger,name) {this.name=name;this.messenger=messenger;channels.push(this);} setMethodCallHandler(handler){this.handler=handler;} }
  class EventChannel { constructor(messenger,name){this.name=name;this.messenger=messenger;channels.push(this);} setStreamHandler(handler){this.handler=handler;} }
  const boundaries={ '@ohos.multimedia.audio':{default:audio}, '@kit.CoreSpeechKit':{speechRecognizer:kit}, '@ohos.abilityAccessCtrl':{default:access},
    '@ohos/flutter_ohos':{MethodChannel,EventChannel} };
  function load(path) {
    if(cache.has(path)) return cache.get(path).exports;
    const module={exports:{}};cache.set(path,module);
    const source=ts.transpileModule(fs.readFileSync(path,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
    try { vm.runInNewContext(source,{module,exports:module.exports,Map,Set,ArrayBuffer,Uint8Array,DataView,Promise,Error,
      canIUse:cap=>{assert.equal(cap,'SystemCapability.Multimedia.Audio.Capturer');return current.audioSupported!==false;},
      require(name){
        if(name==='./HmsSpeechKit'){calls.push('loadSpeechKit');return Promise.resolve(current.beforeKitLoad?.()).then(()=>load(resolve(dirname(path),name+'.ets')));}
        if(name.startsWith('.'))return load(resolve(dirname(path),name+'.ets'));
        if(name==='@kit.CoreSpeechKit'&&current.kitFailure)throw Error('controlled unavailable Core Speech Kit');
        assert(name in boundaries,'unadapted boundary '+name);return boundaries[name];}
    },{filename:path}); } catch(error) {cache.delete(path);throw error;} return module.exports;
  }
  const Plugin=load(resolve(repo,'app/ohos/entry/src/main/ets/plugins/VoicePlugin.ets')).default;
  const Pcm=load(resolve(repo,'app/ohos/entry/src/main/ets/plugins/VoicePcm.ets')).VoicePcm;
  function attach(plugin=new Plugin(), withAbility=true) {
    const messenger={setMessageHandler(){}};
    const engine={getApplicationContext:()=>app,getBinaryMessenger:()=>messenger};
    const ui={context:app}; const ability={getAbility:()=>ui};
    plugin.onAttachedToEngine(engine);if(withAbility){plugin.onAttachedToAbility(ability);Plugin.onForeground(ui);}
    const methods=channels.at(-2),stream=channels.at(-1);
    stream.handler.onListen(null,{success(event){ assert(!inRead,'Flutter event inside readData');events.push(plain(event));if(current.eventFailure)throw Error('retired sink'); }});
    return {plugin,engine,ability,methods,stream,foreground:()=>Plugin.onForeground(ui),background:()=>Plugin.onBackground(ui)};
  }
  function call(methods,method,args={}) {
    const result=deferred(),replies=[];
    const respond=value=>{replies.push(value);result.resolve(value);if(current.replyFailure)throw Error('retired reply');};
    methods.handler.onMethodCall({method,argument:key=>args[key]}, {success:value=>respond({value:plain(value)}),error:(error,message,details)=>respond({error,message,details:plain(details)}),notImplemented:()=>respond({missing:true})});
    return {done:result.promise,replies};
  }
  return { ...attach(),Pcm,attach,call,capturers,engines,events,channels,calls,change:next=>{current={...current,...next};},
    stats:()=>({asks,checks,settings}) };
}
