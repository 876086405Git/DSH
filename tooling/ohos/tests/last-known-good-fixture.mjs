import fs from 'node:fs/promises';
import {createRequire} from 'node:module';
import {resolve,join} from 'node:path';
import {tmpdir} from 'node:os';
import vm from 'node:vm';
import {fileIo,fileHash,util} from './runtime-storage-fixture.mjs';

// Actual ETS methods; only SDK metadata and FS boundary are Linux fixtures.
export async function modules(hook=async()=>{},bundleHash='hap-fixture-v1') {
 const ts=createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX,'package.json'))('typescript');
 const fio={...fileIo};
 for(const name of ['open','lstat','stat','listFile','close','fsync','rename','unlink','read','write'])fio[name]=async(...args)=>{
  await hook('before:'+name,args);
  let result;try{result=await fileIo[name](...args);}catch(e){if(e.code==='ENOENT')e.code=13900002;throw e;}
  await hook('after:'+name,args);return result;
 };
 const bundleManager={BundleFlag:{GET_BUNDLE_INFO_WITH_HAP_MODULE:2},async getBundleInfoForSelf(){return {name:'test.dsh',versionCode:1,hapModulesInfo:[{name:'entry',hashValue:bundleHash}]};}};
 const loaded={};const imports={'@ohos.file.fs':{default:fio},'@ohos.file.hash':{default:fileHash},'@ohos.util':{default:util},'@ohos.bundle.bundleManager':{default:bundleManager},'./OhosRuntimeArchive':{OhosRuntimeArchive:class{}}};
 for(const name of ['RuntimeCore','OhosRuntimeStorage','RuntimeLastKnownGood','OhosLastKnownGoodStorage']){
  const text=await fs.readFile(new URL('../../../app/ohos/entry/src/main/ets/runtime/'+name+'.ets',import.meta.url),'utf8');
  const code=ts.transpileModule(text,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  const module={exports:{}};vm.runInNewContext(code,{module,exports:module.exports,require:key=>{const value=loaded[key]||imports[key];if(!value)throw new Error(key);return value;}});loaded['./'+name]=module.exports;
 }
 return {Core:loaded['./RuntimeLastKnownGood'].RuntimeLastKnownGood,Storage:loaded['./OhosLastKnownGoodStorage'].OhosLastKnownGoodStorage};
}
export function pkg(bundles=['builtin'],dependencies={}) {return JSON.stringify({name:'web',other:{untouched:123},dependencies,dsh:{profile:{bundles},other:'retained'}});}
export async function put(path,text){await fs.mkdir(join(path,'..'),{recursive:true});await fs.writeFile(path,text);}
export async function fixture(t,hook=async()=>{}){
 const root=await fs.mkdtemp(join(tmpdir(),'dsh-lkg-'));t.after(()=>fs.rm(root,{recursive:true,force:true}));
 const home=join(root,'runtime/rootfs/root/.dsh/profiles/web');
 await put(join(root,'hap/libs/arm64/libnode.so'),'fixture-node');await put(join(root,'hap/libs/arm64/libdsh_host.so'),'fixture-host');
 await put(join(root,'dsh-runtime/installed.json'),'actual-test-manifest');await put(join(home,'package.json'),pkg());
 await put(join(home,'cordis.patch.yml'),'old: true\n');
 const context={filesDir:root,resourceManager:{},bundleCodeDir:join(root,'hap'),applicationInfo:{nativeLibraryPath:'libs/arm64/'}};
 const {Core,Storage}=await modules(hook);const storage=new Storage(context);const lkg=new Core(storage);
 return {root,home,context,Core,Storage,storage,lkg};
}
