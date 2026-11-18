import { assertEntryAbilityImports, createEntryAbilityImports } from './entry-ability-fixture.mjs';
// Real product ETS; Window callbacks, Flutter transport and wall clock are boundaries.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const repo = process.env.OHOS_KEYBOARD_SOURCE_ROOT ?? fileURLToPath(new URL('../../../', import.meta.url));
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
assert.match(ts.version, /^5\.9\./);
export function plain(value) { return value instanceof Map ? Object.fromEntries([...value].map(([k,v]) => [k,plain(v)])) : Array.isArray(value) ? Array.from(value,plain) : value; }
export function keyboardFixture(options = {}) {
  let now = 1794744000000;
  const modules = new Map(), channels = [], lines = [], warnings = [];
  class MethodChannel {
    constructor(messenger, name) { this.messenger=messenger; this.name=name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler=handler; }
  }
  function load(name) {
    const path=name.startsWith('/')?name:resolve(repo,'app/ohos/entry/src/main/ets/plugins',name+'.ets');
    if(modules.has(path))return modules.get(path).exports;
    const module={exports:{}};modules.set(path,module);
    const text=fs.readFileSync(path,'utf8');
    const entry=path.endsWith('/entryability/EntryAbility.ets');
    if(entry)assertEntryAbilityImports(text);
    const entryImports=entry?createEntryAbilityImports({'../plugins/OhosKeyboardLog':()=>load('OhosKeyboardLog'),'../plugins/DiagnosticsPlugin':()=>load('DiagnosticsPlugin')}):null;
    const js=ts.transpileModule(text,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
    vm.runInNewContext(js,{module,exports:module.exports,Map,Set,Array,Number,String,JSON,Date:{now:()=>now},Promise,Error,
      require(specifier){
        if(specifier==='@ohos/flutter_ohos')return {MethodChannel,FlutterAbility:class {context={};configureFlutterEngine(){} onCreate(){} onNewWant(){} onWindowStageCreate(){} onWindowStageDestroy(){} onForeground(){} onBackground(){} onDestroy(){}}};
        if(entry && specifier==='../runtime/NativeHost')return {loadNativeHost(){throw Error('native runtime is outside keyboard scope');}};
        if(entry && specifier.startsWith('.'))return entryImports(specifier);
        if(specifier==='@ohos.window')return {default:{AvoidAreaType:{TYPE_KEYBOARD:3}}};
        if(specifier==='@ohos.hilog')return {default:{info:(...args)=>lines.push(args),warn:(...args)=>warnings.push(args)}};
        if(specifier==='./OhosDeviceFacts')return {ohosDeviceIdentity(){throw Error('unrelated info');},systemMemoryBytes(){throw Error('unrelated info');}};
        if(specifier==='../runtime/PersistedRuntimeLog')return {PersistedRuntimeLog:{get(){throw Error('geometry must not read system/runtime logs');}}};
        if(specifier==='../runtime/OhosRuntimeStorage')return {OhosRuntimeStorage:class{}};
        if(specifier==='../runtime/RuntimeCore')return {};
        if(specifier.startsWith('@ohos.'))return {default:{}};
        if(specifier.startsWith('.'))return load(resolve(dirname(path),specifier+'.ets'));
        throw Error('unadapted boundary '+specifier);
      }},{filename:path});return module.exports;
  }
  function window() {
    const listeners=new Map(),removed=[];
    const target={on(event,callback){if(options.failures?.has(event))throw options.failures.get(event);if(options.refuse?.includes(event))throw Object.assign(Error('Capability not supported'),{code:801});listeners.set(event,callback);},
      off(event,callback){removed.push([event,callback]);if(options.refuseOff)throw Object.assign(Error('Window state abnormal'),{code:1300002});if(listeners.get(event)===callback)listeners.delete(event);}};
    return {target,listeners,removed,stage:{getMainWindowSync(){if(options.noWindow)throw Object.assign(Error('Window state abnormal'),{code:1300002});return target;}}};
  }
  const Log=load('OhosKeyboardLog').OhosKeyboardLog,log=new Log();
  const Plugin=load('DiagnosticsPlugin').default,plugin=new Plugin(log),messenger={};
  const binding={getBinaryMessenger:()=>messenger,getApplicationContext(){throw Error('geometry must not scan application files');}};
  const ability={getAbility:()=>({context:{}})};
  plugin.onAttachedToEngine(binding);plugin.onAttachedToAbility(ability);
  const channel=channels.at(-1);
  function invokeOn(channel,method,args={}){return new Promise((resolve)=>channel.handler.onMethodCall({method,argument:key=>args[key]},
    {success:value=>resolve({value:plain(value)}),error:(error,message)=>resolve({error,message}),notImplemented:()=>resolve({missing:true})}));}
  function entry(){
    const Entry=load(resolve(repo,'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets')).default;
    const instance=new Entry(),plugins=[];instance.configureFlutterEngine({getPlugins:()=>({add:p=>plugins.push(p)})});
    const diagnostics=plugins.find(p=>p instanceof Plugin);assert(diagnostics,'real DiagnosticsPlugin registered');
    diagnostics.onAttachedToEngine(binding);diagnostics.onAttachedToAbility(ability);const current=channels.at(-1);
    return {instance,diagnostics,invoke:(method,args)=>invokeOn(current,method,args)};
  }
  return {log,plugin,binding,ability,channel,invoke:(method,args)=>invokeOn(channel,method,args),entry,window,lines,warnings,now:()=>now,advance:ms=>{now+=ms;}};
}
export const info = () => ({beginRect:{left:0,top:2400,width:1080,height:0},endRect:{left:0,top:1500,width:1080,height:900},animated:true,config:{curve:2,duration:250,param:[0.2,0,0.2,1]}});
