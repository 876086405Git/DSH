// Host record mode uses native rg; replay mode uses only the virtual runtime.
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { fixtureFiles, cases } from './process-rg-m4-cases.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const mode = process.env.M4_RG_MODE || 'replay';
const oraclePath = join(here,'process-rg-m4-native.json');
const hash = data => createHash('sha256').update(data).digest('hex');
const caseHash = hash(await readFile(join(here,'process-rg-m4-cases.mjs')));
const root = await mkdtemp(join(tmpdir(),'ohos-rg-m4-')), work = join(root,'work'), temp = join(root,'temp');
await mkdir(temp); await mkdir(work);
for (const [file,data] of Object.entries(fixtureFiles)) { const path=join(work,file); await mkdir(dirname(path),{recursive:true}); await writeFile(path,data); }
const normalize = text => text.trim().split('\n').filter(Boolean).map(JSON.parse).filter(x=>x.type==='match').map(({data})=>({path:data.path,lines:data.lines,line_number:data.line_number,absolute_offset:data.absolute_offset,submatches:data.submatches})).sort((a,b)=>Buffer.compare(Buffer.from(JSON.stringify(a)),Buffer.from(JSON.stringify(b))));
let runtime;
try {
  if (mode === 'record') {
    const rg=process.env.OHOS_NATIVE_RG;
    if(!rg)throw new Error('OHOS_NATIVE_RG required');
    const records=cases.map(([name,...args])=>{ const result=spawnSync(rg,['--no-config',...args],{cwd:work,encoding:'utf8',stdio:['ignore','pipe','pipe'],maxBuffer:4*1024*1024});if(result.error)throw result.error;return {name,exitCode:result.status,matches:normalize(result.stdout),stderr:result.stderr.replaceAll(work,'<work>')}; });
    const result={caseSHA256:caseHash,rgSHA256:hash(await readFile(rg)),version:spawnSync(rg,['--version'],{encoding:'utf8'}).stdout,records};
    await writeFile(oraclePath,JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify({recorded:records.length,caseHash}));
  } else {
    const oracle=JSON.parse(await readFile(oraclePath,'utf8')); if(oracle.caseSHA256!==caseHash)throw new Error('native oracle is stale');
    const processRoot=process.env.M4_PROCESS_ROOT ? pathToFileURL(resolve(process.env.M4_PROCESS_ROOT)+'/') : new URL('../../ohos/process/',import.meta.url);
    const {VirtualSubprocessRuntime}=await import(new URL('runtime.mjs',processRoot));
    runtime=new VirtualSubprocessRuntime({workspaceRoots:[work],temporaryRoot:temp});
    const records=[];
    for(let i=0;i<cases.length;i++) {
      const [name,...args]=cases[i],expected=oracle.records[i];
      const handle=runtime.spawn({argv:['rg','--no-config',...args],cwd:work,graceMs:100,stdio:{stdin:'ignore',stdout:{maxBytes:4*1024*1024},stderr:{maxBytes:1024*1024}}});
      const timer=setTimeout(()=>handle.terminate(),15000);
      const done=await handle.done.finally(()=>clearTimeout(timer));
      const actual={exitCode:done.exitCode,matches:normalize(handle.collected.stdout.readFrom(0).text)};
      const equal=actual.exitCode===expected.exitCode && JSON.stringify(actual.matches)===JSON.stringify(expected.matches);
      records.push({name,equal,expected,actual,stderr:handle.collected.stderr.readFrom(0).text.replaceAll(work,'<work>')});
      console.error(`${equal?'PASS':'FAIL'} ${name}`);
    }
    console.log(JSON.stringify({mode,caseSHA256:caseHash,pass:records.filter(x=>x.equal).length,fail:records.filter(x=>!x.equal).length,records},null,2));
    if(records.some(x=>!x.equal))process.exitCode=1;
  }
}finally{await runtime?.dispose();await rm(root,{recursive:true,force:true});}
