import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {createRequire} from 'node:module';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import vm from 'node:vm';
import {fileIo,fileHash,util} from './runtime-storage-fixture.mjs';
import {ids} from './recovery-fixture.mjs';
const ts=createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX,'package.json'))('typescript');
async function modules(hooks={}){
 const fio={...fileIo,async lstat(path){try{return await fs.lstat(path);}catch(e){if(e.code==='ENOENT')e.code=13900002;throw e;}},
  async fsync(fd){await hooks.fsync?.(fd);await fileIo.fsync(fd);},async close(f){await hooks.close?.(f);await fileIo.close(f);},async listFile(path,options){await hooks.list?.(path,options);return fileIo.listFile(path,options);}};
 const loaded={};
 const imports={'@ohos.file.fs':{default:fio},'@ohos.file.hash':{default:fileHash},'@ohos.util':{default:util},'./OhosRuntimeArchive':{OhosRuntimeArchive:class{constructor(resources){}}}};
 for(const name of ['RuntimeCore','OhosRuntimeStorage','OhosRecoveryStorage']){
  const text=await fs.readFile(new URL('../../../app/ohos/entry/src/main/ets/runtime/'+name+'.ets',import.meta.url),'utf8');const code=ts.transpileModule(text,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  const module={exports:{}};vm.runInNewContext(code,{module,exports:module.exports,require:key=>{const x=imports[key]||loaded[key];assert(x,key);return x;}});loaded['./'+name]=module.exports;
 }
 return loaded['./OhosRecoveryStorage'].OhosRecoveryStorage;
}
async function fixture(t,hooks){const root=await fs.mkdtemp(join(tmpdir(),'dsh-recovery-storage-'));t.after(()=>fs.rm(root,{recursive:true,force:true}));const Storage=await modules(hooks);return {root,s:new Storage({filesDir:root,resourceManager:{}})};}
async function put(root,path,text='bytes'){const p=join(root,path);await fs.mkdir(join(p,'..'),{recursive:true});await fs.writeFile(p,text);}
test('actual OH storage metadata adapter atomically writes/reads only fixed records',async t=>{
 const c=await fixture(t);await c.s.mkdir(c.root+'/dsh-recovery');await c.s.write(c.root+'/dsh-recovery/boot.json','record');assert.equal(await c.s.read(c.root+'/dsh-recovery/boot.json'),'record');
 await assert.rejects(c.s.write(c.root+'/preferences/hosts.json','bad'));await assert.rejects(c.s.removeTree(c.root));await assert.rejects(c.s.mkdir(c.root+'/runtime/rootfs-escape'));
});
test('fixed root symlinks and parent symlinks are refused; nested link is unlinked without following',async t=>{
 const c=await fixture(t);const outside=await fs.mkdtemp(join(tmpdir(),'dsh-recovery-outside-'));t.after(()=>fs.rm(outside,{recursive:true,force:true}));await fs.writeFile(join(outside,'keep'),'outside');
 await fs.symlink(outside,c.root+'/dsh-runtime');await assert.rejects(c.s.removeTree(c.root+'/dsh-runtime'));await fs.unlink(c.root+'/dsh-runtime');
 await put(c.root,'dsh-runtime/tree/a');await fs.symlink(outside,c.root+'/dsh-runtime/tree/link');await c.s.removeTree(c.root+'/dsh-runtime');assert.equal(await fs.readFile(join(outside,'keep'),'utf8'),'outside');
 await fs.symlink(outside,c.root+'/runtime');await assert.rejects(c.s.kind(c.root+'/runtime/rootfs'));assert.equal(await fs.readFile(join(outside,'keep'),'utf8'),'outside');
});
test('deletion uses bounded nonrecursive batches and never touches unrelated hosts/secrets',async t=>{
 const batches=[];const c=await fixture(t,{list:(path,opts)=>batches.push(opts)});for(let i=0;i<300;i++)await put(c.root,'dsh-runtime/tree/'+i);await put(c.root,'dsh-secrets/vault','key');await put(c.root,'preferences/hosts','host');
 await c.s.removeTree(c.root+'/dsh-runtime');assert(batches.every(x=>x.recursion===false&&x.listNum===128));assert(batches.length>=4);assert.equal(await fs.readFile(c.root+'/dsh-secrets/vault','utf8'),'key');assert.equal(await fs.readFile(c.root+'/preferences/hosts','utf8'),'host');
});
test('preserve moves sync both parents and reject target conflicts',async t=>{
 let syncs=0;const c=await fixture(t,{fsync:()=>syncs++});const from=c.root+'/runtime/rootfs/root/.dsh/.env',to=c.root+'/dsh-recovery/keep-'+ids[0]+'/root/.dsh/.env';await put(c.root,'runtime/rootfs/root/.dsh/.env','private');await c.s.mkdir(join(to,'..'));const before=syncs;await c.s.move(from,to);assert.equal(syncs-before,2);assert.equal(await fs.readFile(to,'utf8'),'private');await put(c.root,'runtime/rootfs/root/.dsh/.env','new');await assert.rejects(c.s.move(from,to));assert.equal(await fs.readFile(from,'utf8'),'new');
});
test('ENOENT only is missing; permission/not-directory errors remain failures',async t=>{
 const c=await fixture(t);assert.equal(await c.s.kind(c.root+'/absent'),'missing');await put(c.root,'runtime','file');await assert.rejects(c.s.kind(c.root+'/runtime/rootfs'));await assert.rejects(c.s.kind(c.root+'/runtime/../dsh-secrets'));
});
test('failed directory close retains descriptor for retry and never reports successful move',async t=>{
 let failed=false;const c=await fixture(t,{close:()=>{if(!failed){failed=true;throw new Error('close failed');}}});const from=c.root+'/runtime/rootfs/root/.dsh/.env',to=c.root+'/dsh-recovery/keep-'+ids[0]+'/root/.dsh/.env';await put(c.root,'runtime/rootfs/root/.dsh/.env');await fs.mkdir(join(to,'..'),{recursive:true});await assert.rejects(c.s.move(from,to));assert.equal(await fs.readFile(to,'utf8'),'bytes');await c.s.removeTree(c.root+'/dsh-recovery/keep-'+ids[0]);
});
