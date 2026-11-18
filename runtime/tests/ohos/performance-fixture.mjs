// Actual ETS; public thermal/memory/clock and Flutter are explicit boundary doubles.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
const repo = fileURLToPath(new URL('../../../', import.meta.url));
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
export const plain = value => value instanceof Map ? Object.fromEntries([...value].map(([k,v]) => [k,plain(v)])) :
  Array.isArray(value) ? value.map(plain) : value;

export function performanceFixture(options = {}) {
  let opt = options, currentLevel = opt.level ?? 0, clock = 1000, wall = 1762084800000, timerId = 0, registered = null;
  const modules = new Map(), timers = new Map(), channels = [], callbacks = [], calls = [], instances = [], views = new Map(), reads = [];
  const thermal = {
    ThermalLevel: { COOL:0, NORMAL:1, WARM:2, HOT:3, OVERHEATED:4, WARNING:5, EMERGENCY:6, ESCAPE:7 },
    registerThermalLevelCallback(callback) { calls.push('register'); if (opt.registerError) throw Error('register'); registered = callback; callbacks.push(callback); },
    unregisterThermalLevelCallback() { calls.push('unregister'); if (opt.unregisterError) throw Error('unregister'); registered = null; },
    getLevel() { calls.push('level'); if (opt.levelError) throw Error('level'); return currentLevel; },
  };
  class MethodChannel { constructor(messenger,name) { this.name=name; channels.push(this); } setMethodCallHandler(value) { this.handler=value; } }
  class EventChannel { constructor(messenger,name) { this.name=name; channels.push(this); } setStreamHandler(value) { this.handler=value; } }
  const boundaries = {
    '@ohos.thermal': {default:thermal},
    '@ohos.systemDateTime': {default:{TimeType:{ACTIVE:1},getUptime(type){assert.equal(type,1);calls.push('clock');if(opt.clockError)throw Error('clock');return clock;}}},
    '@ohos.hidebug': {default:{getSystemMemInfo(){calls.push('memory');if(opt.memoryError)throw Error('memory');return {totalMem:opt.memoryKb ?? 8n*1024n*1024n};}}},
    // sysconf answers -1 for what it can't tell; a fixture that says nothing knows nothing.
    '@ohos.process': {default:{ProcessManager:class { getSystemConfig(name){reads.push('sysconf '+name);if(opt.sysconfError)throw Error('sysconf');return name===83?opt.cores??-1:name===84?opt.online??opt.cores??-1:-1;} }}},
    '@ohos.display': {default:{getDefaultDisplaySync(){reads.push('display');if(opt.displayError)throw Error('display');return {supportedRefreshRates:opt.refreshRates};}}},
    '@ohos.deviceInfo': {default:{sdkApiVersion:26,manufacture:'fixture maker',brand:'fixture brand',productModel:'fixture model',osFullName:'OpenHarmony fixture',abiList:'arm64-v8a,x86_64'}},
    '@ohos/flutter_ohos': {MethodChannel,EventChannel,FlutterManager:{getInstance:()=>({getFlutterViewList:()=>views})}},
  };
  class ClockDate extends Date { static now() { return wall; } }
  function load(path) {
    if(modules.has(path))return modules.get(path).exports;
    const module={exports:{}};modules.set(path,module);
    const compiled=ts.transpileModule(readFileSync(path,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
    vm.runInNewContext(compiled,{module,exports:module.exports,Map,Set,ArrayBuffer,Uint8Array,Promise,Error,Date:ClockDate,
      canIUse:cap=>!(opt.missingCaps??[]).includes(cap),
      setTimeout:(callback,delay)=>{assert(delay>=1);const id=++timerId;timers.set(id,{callback,at:clock+delay,delay});return id;},
      clearTimeout:id=>timers.delete(id),
      require(name){if(name.startsWith('.'))return load(resolve(dirname(path),name+'.ets'));assert(name in boundaries,'unadapted/forbidden import '+name);return boundaries[name];}
    },{filename:path});return module.exports;
  }
  const Plugin=load(resolve(repo,'app/ohos/entry/src/main/ets/plugins/PerformancePlugin.ets')).default;
  const Policy=load(resolve(repo,'app/ohos/entry/src/main/ets/plugins/OhosThermalState.ets')).OhosThermalPolicy;
  function attach(plugin=new Plugin()) {
    const engine={getBinaryMessenger:()=>({setMessageHandler(){}})};
    plugin.onAttachedToEngine(engine);const methods=channels.at(-2),stream=channels.at(-1),events=[];
    const instance={plugin,engine,methods,stream,events,
      listen(){stream.handler.onListen(null,{success:value=>events.push(plain(value)),error(){throw Error('unexpected stream error');}});},
      cancel(){stream.handler.onCancel(null);}, detach(){plugin.onDetachedFromEngine(engine);}};
    instances.push(instance);return instance;
  }
  function invoke(instance,method='snapshot',args={}) {
    const replies=[];
    instance.methods.handler.onMethodCall({method,argument(name){return args[name] ?? null;}},{
      success:value=>replies.push({value:plain(value)}),error:(error,message)=>replies.push({error,message}),notImplemented:()=>replies.push({missing:true})});
    assert.equal(replies.length,1);return replies[0];
  }
  function advance(amount) {
    clock+=amount;
    for(let count=0;count<100;count++) {
      const due=[...timers].find(([,value])=>value.at<=clock);if(!due)return;
      timers.delete(due[0]);due[1].callback();
    }
    throw Error('timer loop');
  }
  const addView=id=>{const view={frameCache:[],enableFrameCache(value){if(opt.viewError)throw Error('view');this.frameCache.push(value);}};views.set(id,view);return view;};
  return {Plugin,Policy,attach,invoke,calls,reads,timers,callbacks,addView,
    change:next=>{opt={...opt,...next};},level:value=>{currentLevel=value;registered?.(value);},setLevel:value=>{currentLevel=value;},
    advance,setClock:value=>{clock=value;},setWall:value=>{wall=value;},dispose:()=>instances.forEach(i=>i.detach())};
}
