// Native record creates real Git worktrees/submodules. Replay never spawns a process.
import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, writeFile, readdir, lstat, readlink, symlink } from 'node:fs/promises';
import { join, dirname, resolve, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import { fixtureFiles, cases } from './process-rg-gitfile-cases.mjs';
const here=dirname(fileURLToPath(import.meta.url));
const mode=process.env.M6_GITFILE_MODE || 'replay';
const oraclePath=resolve(process.env.M6_GITFILE_ORACLE || join(here,'process-rg-gitfile-native.json'));
const hash=data=>createHash('sha256').update(data).digest('hex');
const caseSHA256=hash(await readFile(join(here,'process-rg-gitfile-cases.mjs')));
const scriptSHA256=hash(await readFile(fileURLToPath(import.meta.url)));
const normalize=text=>text.split('\n').filter(Boolean).map(JSON.parse).filter(x=>x.type==='match').map(({data})=>({path:data.path.text===undefined?data.path:{text:data.path.text.replace(/^\.\//,'')},lines:data.lines,line_number:data.line_number,absolute_offset:data.absolute_offset,submatches:data.submatches})).sort((a,b)=>Buffer.compare(Buffer.from(JSON.stringify(a)),Buffer.from(JSON.stringify(b))));
async function treeIdentity(root) {
 const entries=[];
 async function walk(path) {
  for(const name of (await readdir(path)).sort()) {
   const entry=join(path,name),st=await lstat(entry),rel=relative(root,entry);
   if(st.isSymbolicLink())entries.push([rel,'symlink',await readlink(entry)]);
   else if(st.isDirectory()){entries.push([rel,'directory',st.mode&0o777]);await walk(entry);}
   else if(st.isFile())entries.push([rel,'file',st.mode&0o777,hash(await readFile(entry))]);
   else throw new Error('unexpected fixture entry: '+entry);
  }
 }
 await walk(root);return {sha256:hash(JSON.stringify(entries)),entries:entries.length};
}
if(mode==='record') {
 const git=process.env.M6_NATIVE_GIT || 'git',rg=process.env.OHOS_NATIVE_RG;
 if(!rg)throw new Error('OHOS_NATIVE_RG must name the pinned rg 15.0.0');
 const parent=resolve(process.env.M6_GITFILE_FIXTURE_PARENT || dirname(oraclePath));await mkdir(parent,{recursive:true});
 const root=await mkdtemp(join(parent,'gitfile-real-'));
 const env={...process.env,GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:'/dev/null',GIT_TERMINAL_PROMPT:'0',GIT_AUTHOR_NAME:'DSH fixture',GIT_AUTHOR_EMAIL:'fixture@example.invalid',GIT_COMMITTER_NAME:'DSH fixture',GIT_COMMITTER_EMAIL:'fixture@example.invalid'};
 const commands=[];
 function run(program,args,cwd,accepted=[0]) {
  const result=spawnSync(program,args,{cwd,env,encoding:'utf8',stdio:['ignore','pipe','pipe'],maxBuffer:8*1024*1024});
  if(result.error)throw result.error;
  commands.push({program,args,cwd,exitCode:result.status,stdout:result.stdout,stderr:result.stderr});
  if(!accepted.includes(result.status))throw new Error(`fixture command failed: ${program} ${JSON.stringify(args)}\n${result.stderr}`);
  return result;
 }
 async function populate(path){for(const [name,text] of Object.entries(fixtureFiles)){await mkdir(dirname(join(path,name)),{recursive:true});await writeFile(join(path,name),text);}}
 async function repo(path){await mkdir(path);run(git,['init','-b','main'],path);await populate(path);run(git,['add','--all'],path);run(git,['commit','-m','fixture'],path);}
 const directory=join(root,'directory');await repo(directory);
 const source=join(root,'source');await repo(source);
 const worktree=join(root,'worktree');run(git,['worktree','add','--detach',worktree,'HEAD'],source);await populate(worktree);
 const superproject=join(root,'superproject');await mkdir(superproject);run(git,['init','-b','main'],superproject);
 run(git,['-c','protocol.file.allow=always','submodule','add',source,'module'],superproject);
 const submodule=join(superproject,'module');await populate(submodule);
 const repositories={directory,worktree,submodule};
 const outside=join(root,'outside');await mkdir(outside);await writeFile(join(outside,'secret.txt'),'needle SECRET_OUTSIDE_ROOT\n');
 const gitMetadata={};
 for(const [name,path] of Object.entries(repositories)){
  const dotgit=join(path,'.git'),st=await lstat(dotgit);
  assert.equal(st.isFile(),name!=='directory');assert.equal(st.isDirectory(),name==='directory');
  const absoluteGitDir=run(git,['rev-parse','--absolute-git-dir'],path).stdout.trim();
  const commonRaw=run(git,['rev-parse','--git-common-dir'],path).stdout.trim();const common=resolve(path,commonRaw);
  await mkdir(join(common,'info'),{recursive:true});await writeFile(join(common,'info/exclude'),'external-only.txt\n');
  await symlink(outside,join(path,'outside-link'));
  gitMetadata[name]={dotgitKind:st.isFile()?'file':'directory',dotgitText:st.isFile()?await readFile(dotgit,'utf8'):undefined,absoluteGitDir,commonGitDir:common,commonOutsideSearchRoot:!common.startsWith(path+'/')};
 }
 const version=run(rg,['--version'],directory).stdout;assert.match(version,/^ripgrep 15\.0\.0\b/);
 const records=cases.map(c=>{const cwd=join(repositories[c.repo],c.cwd);const r=run(rg,['--no-config',...c.args],cwd,[0,1,2]);return {name:c.name,exitCode:r.status,matches:normalize(r.stdout),stderr:r.stderr};});
 for(const c of cases.filter(c=>c.equivalence==='documented-extra-result')){const row=records.find(r=>r.name===c.name);assert.equal(row.exitCode,1);assert.deepEqual(row.matches,[]);assert.equal(row.stderr,'');}
 const fixtureIdentity=await treeIdentity(root);
 const oracle={schema:1,scope:'real Git worktree and local submodule; no forged .git pointer',root,repositories,gitMetadata,caseSHA256,scriptSHA256,rgSHA256:hash(await readFile(rg)),rgVersion:version,gitVersion:run(git,['--version'],directory).stdout,fixtureIdentity,records,commands};
 await mkdir(dirname(oraclePath),{recursive:true});await writeFile(oraclePath,JSON.stringify(oracle,null,2)+'\n');
 console.log(JSON.stringify({recorded:records.length,oraclePath,root,gitMetadata,fixtureIdentity}));
} else {
 const oracle=JSON.parse(await readFile(oraclePath,'utf8'));assert.equal(oracle.caseSHA256,caseSHA256);assert.equal(oracle.scriptSHA256,scriptSHA256);
 assert.deepEqual(await treeIdentity(oracle.root),oracle.fixtureIdentity,'fixture changed since native recording');
 const processRoot=process.env.M6_PROCESS_ROOT?pathToFileURL(resolve(process.env.M6_PROCESS_ROOT)+'/'):new URL('../../ohos/process/',import.meta.url);
 const {VirtualSubprocessRuntime}=await import(new URL('runtime.mjs',processRoot));
 const temporaryRoot=await mkdtemp(join(dirname(oraclePath),'m6-temp-'));
 const rows=[];let failureCount=0;
 const quote=s=>"'"+s.replaceAll("'","'\\''")+"'";
 try {
  for(const c of cases) {
   const expected=oracle.records.find(r=>r.name===c.name),workspaceRoot=oracle.repositories[c.repo],cwd=join(workspaceRoot,c.cwd);
   const runtime=new VirtualSubprocessRuntime({workspaceRoots:[workspaceRoot],temporaryRoot});
   try {
    const command=['rg','--no-config',...c.args];const argv=c.shell?['bash','-c',command.map(quote).join(' ')]:command;
    const confined=runtime.prepare(argv,{mode:'read-only',workspaceRoot});
    const handle=runtime.spawn({argv:confined,cwd,graceMs:100,stdio:{stdin:'ignore',stdout:{maxBytes:4*1024*1024},stderr:{maxBytes:1024*1024}}});
    const timer=setTimeout(()=>handle.terminate(),15000);const done=await handle.done.finally(()=>clearTimeout(timer));
    const actual={exitCode:done.exitCode,matches:normalize(handle.collected.stdout.readFrom(0).text),stderr:handle.collected.stderr.readFrom(0).text};
    const row={name:c.name,equivalence:c.equivalence,expected,actual};
    try {
     if(c.equivalence==='exact')assert.deepEqual(actual,{exitCode:expected.exitCode,matches:expected.matches,stderr:expected.stderr});
     else {
      assert.equal(expected.exitCode,1);assert.equal(actual.exitCode,0);assert.equal(actual.stderr,'');
      assert.deepEqual(actual.matches.map(r=>r.path.text),[c.extraPath]);
      assert.deepEqual(actual.matches.map(r=>r.lines.text),['CONTROL_EXCLUDE_ONLY\n']);
     }
     assert(!JSON.stringify(actual).includes('SECRET_OUTSIDE_ROOT'));
     row.ok=true;
    }catch(error){row.ok=false;row.error=error.message;failureCount++;}
    rows.push(row);console.error(`${row.ok?'PASS':'FAIL'} ${c.name}`);
   }finally{await runtime.dispose();}
  }
 }finally{const {rm}=await import('node:fs/promises');await rm(temporaryRoot,{recursive:true,force:true});}
 const after=await treeIdentity(oracle.root);assert.deepEqual(after,oracle.fixtureIdentity,'search must not write worktree, index, object, or metadata');
 const result={caseSHA256,scriptSHA256,processRoot:processRoot.href,selectorSHA256:hash(await readFile(new URL('rg-select.mjs',processRoot))),rgSHA256:hash(await readFile(new URL('rg.mjs',processRoot))),node:process.version,execArgv:process.execArgv,platform:process.platform,simMarker:globalThis[Symbol.for('dsh.go.ohos.sim')]===true,webAssemblyType:typeof WebAssembly,pass:rows.length-failureCount,fail:failureCount,exactCases:cases.filter(c=>c.equivalence==='exact').length,documentedExtraResultCases:cases.filter(c=>c.equivalence!=='exact').length,fixtureIdentityBefore:oracle.fixtureIdentity,fixtureIdentityAfter:after,rows};
 if(process.env.M6_GITFILE_REPORT)await writeFile(resolve(process.env.M6_GITFILE_REPORT),JSON.stringify(result,null,2)+'\n');
 console.log(JSON.stringify({pass:result.pass,fail:result.fail,exactCases:result.exactCases,documentedExtraResultCases:result.documentedExtraResultCases,fixtureIdentity:after}));
 if(failureCount)process.exitCode=1;
}
