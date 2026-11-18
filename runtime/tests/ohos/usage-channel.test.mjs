import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import path from 'node:path';
import vm from 'node:vm';
import { assertEntryAbilityImports, createEntryAbilityImports } from './entry-ability-fixture.mjs';
const ts=createRequire(process.env.OHOS_TYPESCRIPT_PREFIX+'/package.json')('typescript');
const root=process.env.OHOS_USAGE_ROOT??new URL('../../../',import.meta.url).pathname;
const deferred=()=>Promise.withResolvers();
function fixture({bundle,info={sdkApiVersion:23,abiList:'arm64-v8a,armeabi-v7a',manufacture:'HUAWEI'}}={}){
 const channels=[],plugins=[];class Channel{constructor(_messenger,name){this.name=name;channels.push(this);}setMethodCallHandler(h){this.handler=h;}}
 class Stub{configureFlutterEngine(){}onAttachedToEngine(){}}
 const binding={getBinaryMessenger:()=>({})};
 const bundleManager={BundleFlag:{GET_BUNDLE_INFO_DEFAULT:0},async getBundleInfoForSelf(flag){assert.equal(flag,0);return bundle?await bundle():{versionName:'0.9.9',versionCode:123};}};
 const entryImports=createEntryAbilityImports({'../plugins/UsagePlugin':()=>load('plugins/UsagePlugin'),'../runtime/NativeHost':()=>({loadNativeHost(){throw Error('Usage fixture must not load NativeHost');}})});
 function load(name){const module={exports:{}};const source=readFileSync(path.join(root,'app/ohos/entry/src/main/ets',name+'.ets'),'utf8');if(name==='entryability/EntryAbility')assertEntryAbilityImports(source);const js=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext(js,{module,exports:module.exports,require(key){
   if(key==='@ohos/flutter_ohos')return {MethodChannel:Channel,FlutterAbility:Stub};
   if(key==='@ohos.bundle.bundleManager')return {default:bundleManager};
   if(key==='@ohos.deviceInfo')return {default:info};
   if(name==='entryability/EntryAbility'&&key.startsWith('.'))return entryImports(key);
   throw new Error('Unadapted usage import: '+key);
  }});return module.exports;
 }
 const entry=new (load('entryability/EntryAbility').default)();entry.configureFlutterEngine({getPlugins:()=>({add(p){plugins.push(p);p.onAttachedToEngine?.(binding);}})});
 const channel=channels.find(c=>c.name==='dsh/usage');
 const handler=channel?.handler;
 const call=(method='device')=>new Promise((resolve,reject)=>{assert(channel,'EntryAbility must register an actual dsh/usage MethodChannel');handler.onMethodCall({method},{success:resolve,error:(code,message)=>reject(Object.assign(new Error(message),{code})),notImplemented:()=>resolve('notImplemented')});});
 return {channel,channels,plugins,call,binding,info};
}
test('EntryAbility registers the actual usage device channel',async()=>{
 const f=fixture();const data=await f.call();assert.equal(data.get('versionName'),'0.9.9');assert.equal(data.get('versionCode'),123);
 if(process.env.OHOS_USAGE_FACTS)writeFileSync(process.env.OHOS_USAGE_FACTS,JSON.stringify(Object.fromEntries(data)));
});
test('OH API23 and API26 stay separate from unavailable Android sdk',async()=>{
 for(const api of [23,26]){const f=fixture();f.info.sdkApiVersion=api;const m=await f.call();assert.equal(m.get('platform'),'ohos');assert.equal(m.get('apiVersion'),api);assert.equal(m.get('sdk'),0);assert.equal(m.get('abi'),'arm64-v8a');}
});
test('manufacturer is normalized without identifiers/model/network input',async()=>{
 const f=fixture();f.info.manufacture='  HUAWEI/汉字 🐱 ';for(const key of ['serial','udid','productModel','marketName'])Object.defineProperty(f.info,key,{get(){throw Error('private property read');}});
 const m=await f.call();assert.equal(m.get('maker'),'huawei');assert.deepEqual([...m.keys()].sort(),['abi','apiVersion','maker','platform','sdk','versionCode','versionName']);
});
test('empty ABI remains unknown and unknown methods do not query device',async()=>{
 let count=0;const f=fixture({bundle:()=>{count++;return {versionName:'x',versionCode:1};}});f.info.abiList=' , ';assert.equal(await f.call('install'),'notImplemented');assert.equal(count,0);assert.equal((await f.call()).get('abi'),'');
});
test('bundle failure is a stable error and does not echo raw system details',async()=>{
 const f=fixture({bundle:()=>{throw Error('sensitive raw path');}});await assert.rejects(f.call(),e=>e.code==='ohos_usage_unavailable'&&!e.message.includes('sensitive'));
});
test('detach during bundle query cannot deliver old success',async()=>{
 const wait=deferred(),f=fixture({bundle:()=>wait.promise});const result=f.call();const plugin=f.plugins.find(p=>p.getUniqueClassName?.()==='DshUsagePlugin');plugin.onDetachedFromEngine(f.binding);wait.resolve({versionName:'old',versionCode:1});await assert.rejects(result,e=>e.code==='ohos_detached');
});
test('old binding detach does not remove a replacement usage channel',async()=>{
 const f=fixture(),plugin=f.plugins.find(p=>p.getUniqueClassName?.()==='DshUsagePlugin');plugin.onAttachedToEngine({getBinaryMessenger:()=>({})});plugin.onDetachedFromEngine(f.binding);assert.equal(plugin.getUniqueClassName(),'DshUsagePlugin');
 // Old handler identity cannot be used to read through the new binding.
 await assert.rejects(f.call(),e=>e.code==='ohos_detached');
 const current=f.channels.at(-1);const data=await new Promise((resolve,reject)=>current.handler.onMethodCall({method:'device'},{success:resolve,error:reject}));assert.equal(data.get('apiVersion'),23);
});
test('failed public device getter becomes controlled native error',async()=>{
 const f=fixture();Object.defineProperty(f.info,'sdkApiVersion',{get(){throw Error('raw device failure');}});await assert.rejects(f.call(),e=>e.code==='ohos_usage_unavailable'&&!e.message.includes('raw'));
});
