import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
import {createRequire} from 'node:module';
import {resolve} from 'node:path';
const ts=createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX,'package.json'))('typescript');
async function fixture(importer=async()=>({default:{getState:()=>({phase:'idle'})}})){
 const text=await fs.readFile(new URL('../../../app/ohos/entry/src/main/ets/runtime/NativeHost.ets',import.meta.url),'utf8');
 assert.equal(text.split("import('libdsh_host.so')").length,2,'one actual import boundary');
 const code=ts.transpileModule(text.replace("import('libdsh_host.so')",'nativeImport()'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
 class RuntimeChannelError extends Error {constructor(code,message){super(message);this.code=code;}}
 let imports=0;const module={exports:{}};vm.runInNewContext(code,{exports:module.exports,module,nativeImport:()=>{imports++;return importer();},require:()=>({RuntimeChannelError})});
 const marks=[];let blocked=false;let prepare=async()=>{};
 const gate={prepare:()=>prepare(),check:()=>{if(blocked)throw new RuntimeChannelError('ohos_restart_required','pending');},begin:async()=>{marks.push('begin');return 'load-1';},finish:async(id,ok)=>marks.push([id,ok])};
 return {api:module.exports,gate,marks,imports:()=>imports,block:()=>{blocked=true;},prepare:fn=>{prepare=fn;}};
}
test('consumer before Controller configuration cannot import native library',async()=>{const c=await fixture();await assert.rejects(c.api.loadNativeHost(),{code:'ohos_recovery_unconfigured'});assert.equal(c.imports(),0);});
test('two consumer-first callers await one recovery and one import attempt',async()=>{const c=await fixture();let release;c.prepare(()=>new Promise(r=>release=r));c.api.configureNativeRecovery(c.gate);const a=c.api.loadNativeHost(),b=c.api.loadNativeHost();await Promise.resolve();assert.equal(c.imports(),0);release();assert.equal(await a,await b);assert.equal(c.imports(),1);assert.deepEqual(c.marks,['begin',['load-1',true]]);});
test('bad journal and resetPending each prevent import; reset after async preparation is checked again',async()=>{
 for(const mode of ['journal','pending','late']){const c=await fixture();c.api.configureNativeRecovery(c.gate);if(mode==='pending')c.block();else c.prepare(async()=>{if(mode==='journal')throw new Error('bad journal');c.block();});await assert.rejects(c.api.loadNativeHost());assert.equal(c.imports(),0);}
});
test('reset during loading rejects old consumers and later calls, without pretending the library was never touched',async()=>{
 let release;const c=await fixture(()=>new Promise(r=>release=r));c.api.configureNativeRecovery(c.gate);const loading=c.api.loadNativeHost();while(!release)await Promise.resolve();c.block();release({default:{getState:()=>({phase:'idle'})}});await assert.rejects(loading,{code:'ohos_restart_required'});assert.equal(c.api.nativeHostTouched(),true);await assert.rejects(c.api.loadNativeHost());assert.equal(c.imports(),1);
});
test('missing default export is a failed import attempt, retains touched state and does not retry import',async()=>{const c=await fixture(async()=>({}));c.api.configureNativeRecovery(c.gate);await assert.rejects(c.api.loadNativeHost(),{code:'ohos_native_unavailable'});assert.equal(c.api.nativeHostTouched(),true);assert.deepEqual(c.marks,['begin',['load-1',false]]);await assert.rejects(c.api.loadNativeHost());assert.equal(c.imports(),1);});
test('reset after durable begin but before import prevents import; gate owner cannot be replaced',async()=>{
 const c=await fixture();c.gate.begin=async()=>{c.block();return 'load-1';};c.api.configureNativeRecovery(c.gate);
 assert.throws(()=>c.api.configureNativeRecovery({...c.gate}),{code:'ohos_recovery_owner'});
 await assert.rejects(c.api.loadNativeHost(),{code:'ohos_restart_required'});assert.equal(c.imports(),0);assert.equal(c.api.nativeHostTouched(),false);
});
