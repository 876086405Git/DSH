import fs from 'node:fs/promises';
import { constants } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve, dirname, relative, join } from 'node:path';
import vm from 'node:vm';
export async function loadRecovery() {
  const ts=createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX,'package.json'))('typescript');
  const text=await fs.readFile(new URL('../../../app/ohos/entry/src/main/ets/runtime/RuntimeRecovery.ets',import.meta.url),'utf8');
  const code=ts.transpileModule(text,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  class RuntimeChannelError extends Error {constructor(code,message){super(message);this.code=code;}}
  const module={exports:{}};vm.runInNewContext(code,{module,exports:module.exports,require:name=>{if(name==='./RuntimeCore')return {RuntimeChannelError};throw new Error(name);}});
  return module.exports.RuntimeRecovery;
}
// Real Linux files, rename and fsync. The platform adapter has separate tests;
// this fixture is the RecoveryStorage boundary, not a copy of recovery logic.
export class RecoveryFiles {
  constructor(root,hook=async()=>{}){this.root=resolve(root);this.hook=hook;this.events=[];}
  async event(op,paths=[]){this.events.push({op,paths});await this.hook(op,paths);}
  async check(path){
    const rel=relative(this.root,path);if(!rel||rel.startsWith('../')||rel==='..'||rel.includes('\0'))throw new Error('outside');
    let parent=this.root;
    for(const part of rel.split('/').slice(0,-1)){parent=join(parent,part);let stat;try{stat=await fs.lstat(parent);}catch(e){if(e.code==='ENOENT')return;throw e;}if(!stat.isDirectory()||stat.isSymbolicLink())throw new Error('parent link');}
  }
  async kind(path){await this.check(path);try{const s=await fs.lstat(path);return s.isSymbolicLink()?'symlink':s.isFile()?'file':s.isDirectory()?'directory':(()=>{throw new Error('special file');})();}catch(e){if(e.code==='ENOENT')return 'missing';throw e;}}
  async read(path){const kind=await this.kind(path);if(kind==='missing')return null;if(kind!=='file')throw new Error('record not regular');return fs.readFile(path,'utf8');}
  async mkdir(path){await this.check(path);const rel=relative(this.root,path);let parent=this.root;for(const part of rel.split('/')){parent=join(parent,part);await fs.mkdir(parent).catch(e=>{if(e.code!=='EEXIST')throw e;});const s=await fs.lstat(parent);if(!s.isDirectory()||s.isSymbolicLink())throw new Error('directory link');}}
  async sync(path){const f=await fs.open(path,constants.O_RDONLY|constants.O_DIRECTORY);try{await this.event('before:directory-fsync',[path]);await f.sync();await this.event('after:directory-fsync',[path]);}finally{await f.close();}}
  async write(path,text){
    await this.check(path);await this.event('before:write',[path,text]);
    const tmp=path+'.tmp';const f=await fs.open(tmp,constants.O_WRONLY|constants.O_CREAT|constants.O_TRUNC|constants.O_NOFOLLOW,0o600);
    try{await f.writeFile(text);await this.event('before:file-fsync',[path]);await f.sync();await this.event('after:file-fsync',[path]);}finally{await f.close();}
    await this.event('before:commit',[path]);await fs.rename(tmp,path);await this.event('after:commit',[path]);await this.sync(dirname(path));await this.event('after:write',[path,text]);
  }
  async move(from,to){await this.check(from);await this.check(to);if(await this.kind(to)!=='missing')throw new Error('move destination exists');await this.event('before:move',[from,to]);await fs.rename(from,to);await this.event('after:move',[from,to]);await this.sync(dirname(from));await this.sync(dirname(to));}
  async removeFile(path){await this.check(path);if(await this.kind(path)==='missing')return;await this.event('before:unlink',[path]);await fs.unlink(path);await this.sync(dirname(path));await this.event('after:unlink',[path]);}
  async removeTree(path){await this.check(path);const k=await this.kind(path);if(k==='missing')return;if(k==='symlink')throw new Error('root link');await this.event('before:tree',[path]);
    const walk=async p=>{const s=await fs.lstat(p);if(s.isDirectory()&&!s.isSymbolicLink()){for(const name of await fs.readdir(p))await walk(join(p,name));await fs.rmdir(p);}else await fs.unlink(p);};
    await walk(path);await this.event('after:tree',[path]);await this.sync(dirname(path));
  }
}
export const ids=['00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003'];
