import fs from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {createRequire} from 'node:module';
import vm from 'node:vm';
import {loadRecovery,RecoveryFiles} from './recovery-fixture.mjs';
const [root,mode,id]=process.argv.slice(2);const Recovery=await loadRecovery();
const store=new RecoveryFiles(root,async(op,paths)=>{
 if(mode==='reset'&&op==='after:write'&&paths[0].endsWith('/reset.json')&&JSON.parse(paths[1]).stage===id){
  console.log(JSON.stringify({ready:true,stage:id}));await new Promise(()=>{setInterval(()=>{},10000);});
 }
});
const r=new Recovery(store,root);
await r.initialize(Date.now(),async()=>{await fs.mkdir(join(root,'dsh-runtime/tree'),{recursive:true});await fs.writeFile(join(root,'dsh-runtime/tree/new.js'),'new');},()=>false);
if(mode==='arm'){await r.arm(id,Date.now());console.log(JSON.stringify({ready:true,status:r.status()}));setInterval(()=>{},10000);}
else if(mode==='nativeImport'||mode==='nativeDone'){
 const ts=createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX,'package.json'))('typescript');
 const text=await fs.readFile(new URL('../../../app/ohos/entry/src/main/ets/runtime/NativeHost.ets',import.meta.url),'utf8');
 if(text.split("import('libdsh_host.so')").length!==2)throw new Error('unique native boundary changed');
 const code=ts.transpileModule(text.replace("import('libdsh_host.so')",'nativeImport()'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
 const module={exports:{}};let starts=0;
 class RuntimeChannelError extends Error{constructor(code,message){super(message);this.code=code;}}
 vm.runInNewContext(code,{module,exports:module.exports,require:()=>({RuntimeChannelError}),nativeImport:()=>{
  if(mode==='nativeImport'){console.log(JSON.stringify({ready:true,stage:'nativeImport',status:r.status()}));return new Promise(()=>{setInterval(()=>{},10000);});}
  return Promise.resolve({default:{getState:()=>({phase:'idle'}),start:()=>{starts++;throw new Error('unexpected start');}}});
 }});
 module.exports.configureNativeRecovery({prepare:()=>r.initialize(Date.now(),async()=>{},()=>false),check:()=>{if(r.status().resetPending)throw new Error('pending');},begin:async()=>{await r.arm(id,Date.now(),'nativeLoad');return id;},finish:(attempt,ok)=>r.finish(attempt,ok,Date.now())});
 await module.exports.loadNativeHost();console.log(JSON.stringify({status:r.status(),starts}));
}else console.log(JSON.stringify(r.status()));
