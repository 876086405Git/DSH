// Actual pinned FS provider bodies and real Linux IO; controlled faults are labelled.
import test from 'node:test';
import assert from 'node:assert/strict';
import {Dir} from 'node:fs';
import fsPromises, {mkdir,writeFile,utimes,rename,symlink,chmod,stat} from 'node:fs/promises';
import {syncBuiltinESMExports} from 'node:module';
import {spawn} from 'node:child_process';
import {join,basename} from 'node:path';
import {notesFixture,notesSourceRoot} from './fixtures/companion-notes-files-source.mjs';

assert.equal(process.platform,'linux','SOURCE_IO requires anchored Linux IO; no silent skips');
assert.ok(notesSourceRoot(),'Exact complete provider source pins are required');
const startAtMs=Date.parse('2026-11-20T00:00:00Z'),endAtMs=startAtMs+86400000;
const args={startAtMs,endAtMs,extensions:['md','txt']};
const list=f=>f.fs.dshGoListDrafts(f.directory,args);
async function put(f,name,at=startAtMs+1000,content='abc'){
 const path=join(f.root,'notes',name);await writeFile(path,content);await utimes(path,new Date(at),new Date(at));return path;
}
function trace(t){
 const names=[],metadata=[];let calls=0,closes=0;
 const actualRead=Dir.prototype.read,actualClose=Dir.prototype.close;
 t.mock.method(Dir.prototype,'read',async function(...args){calls++;const entry=await actualRead.apply(this,args);names.push(entry?.name??null);return entry;});
 t.mock.method(Dir.prototype,'close',function(...args){if(args[0]===undefined)closes++;return actualClose.apply(this,args);});
 const actualStat=fsPromises.lstat;
 const instrument=t.mock.method(fsPromises,'lstat',async(...args)=>{metadata.push(String(args[0]));return actualStat(...args);});
 syncBuiltinESMExports();t.after(()=>{instrument.mock.restore();syncBuiltinESMExports();});
 return {names,metadata,get calls(){return calls;},get closes(){return closes;}};
}

test('SOURCE_IO fixed current level, half-open mtime and formats; no outside links or file body reads',async t=>{
 const f=await notesFixture(t,{injectLocalType:false});
 await put(f,'A.md');await put(f,'B.TXT');await put(f,'at-end.md',endAtMs);await put(f,'before.txt',startAtMs-1);
 await put(f,'other.pdf');await mkdir(join(f.root,'notes','child'));await writeFile(join(f.root,'notes','child','hidden.md'),'hidden');
 await writeFile(join(f.root,'outside.md'),'outside');await symlink(join(f.root,'outside.md'),join(f.root,'notes','link.md'));
 t.mock.method(f.fs,'dshGoReadNote',()=>assert.fail('enumeration never reads bodies'));
 const result=await list(f);
 assert.deepEqual(result.entries.map(x=>x.name).sort(),['A.md','B.TXT']);
 assert.equal(result.coverage.entriesChecked,7);assert.equal(result.coverage.supportedFilesChecked,4);
 assert.equal(result.coverage.matchingCandidates,2);assert.equal(result.coverage.enumerationComplete,true);
 assert.deepEqual(result.coverage.gaps,[]);
 assert.equal(result.entries.find(x=>x.name==='A.md').modifiedAtMs,startAtMs+1000);
});
test('SOURCE_IO explicit md subset and exact start boundary',async t=>{
 const f=await notesFixture(t);await put(f,'A.MD',startAtMs);await put(f,'B.txt',startAtMs);
 const result=await f.fs.dshGoListDrafts(f.directory,{...args,extensions:['md']});
 assert.deepEqual(result.entries.map(x=>x.name),['A.MD']);assert.equal(result.coverage.supportedFilesChecked,1);
});
test('SOURCE_IO a fully enumerated twelve-file zero-match result retains real coverage',async t=>{
 const f=await notesFixture(t);for(let i=0;i<12;i++)await put(f,`${i}.md`,startAtMs-1);
 const result=await list(f);assert.deepEqual(result.entries,[]);
 assert.deepEqual(result.coverage,{entriesChecked:12,supportedFilesChecked:12,matchingCandidates:0,
  enumerationComplete:true,entryLimitReached:false,candidateLimitReached:false,gaps:[]});
});
for(const count of [199,200,201])test(`SOURCE_IO ${count} entries: no stat beyond 200 and only one sentinel`,async t=>{
 const f=await notesFixture(t);for(let i=0;i<count;i++)await put(f,`${i}.md`,startAtMs-1);
 const observed=trace(t),result=await list(f);
 assert.equal(result.coverage.entriesChecked,Math.min(count,200));
 assert.equal(result.coverage.supportedFilesChecked,Math.min(count,200));
 assert.equal(observed.calls,Math.min(count+1,201));assert.equal(observed.closes,1);
 assert.equal(result.coverage.entryLimitReached,count===201);
 assert.equal(result.coverage.enumerationComplete,count<=200);
 const fileMetadata=observed.metadata.filter(path=>path.endsWith('.md'));
 assert.equal(fileMetadata.length,Math.min(count,200));
 if(count===201)assert.ok(!fileMetadata.some(path=>basename(path)===observed.names[200]));
});
for(const count of [19,20,21])test(`SOURCE_IO ${count} matches: 21st metadata only, never an extra candidate`,async t=>{
 const f=await notesFixture(t);for(let i=0;i<count;i++)await put(f,`${i}.txt`);
 const observed=trace(t),result=await list(f);
 assert.equal(result.entries.length,Math.min(count,20));assert.equal(result.coverage.matchingCandidates,count);
 assert.equal(result.coverage.candidateLimitReached,count===21);assert.equal(result.coverage.enumerationComplete,count<=20);
 assert.equal(observed.calls,Math.min(count+1,21));assert.equal(observed.closes,1);
 if(count===21)assert.ok(!result.entries.some(entry=>entry.name===observed.names[20]));
});
test('SOURCE_IO controlled stream fault retains three actual observations and closes its real descriptor',async t=>{
 const f=await notesFixture(t);for(let i=0;i<5;i++)await put(f,`${i}.txt`);
 const read=Dir.prototype.read;let calls=0,closes=0;
 t.mock.method(Dir.prototype,'read',async function(...args){
  if(++calls===4)throw Object.assign(new Error('controlled EIO'),{code:'EIO'});return read.apply(this,args);
 });
 const close=Dir.prototype.close;t.mock.method(Dir.prototype,'close',function(...args){if(args[0]===undefined)closes++;return close.apply(this,args);});
 const result=await list(f);assert.equal(result.entries.length,3);assert.equal(result.coverage.entriesChecked,3);
 assert.equal(result.coverage.enumerationComplete,false);assert.equal(closes,1);
 assert.deepEqual(result.coverage.gaps,[{relativePath:null,reason:'enumeration_unavailable'}]);
});
test('SOURCE_IO controlled metadata EACCES does not silently count a supported file as fully checked',async t=>{
 const f=await notesFixture(t);await put(f,'A.md');await put(f,'B.txt');const actual=fsPromises.lstat;
 const injected=t.mock.method(fsPromises,'lstat',async(...params)=>{
  if(String(params[0]).endsWith('/A.md'))throw Object.assign(new Error('controlled metadata EACCES'),{code:'EACCES'});
  return actual(...params);
 });syncBuiltinESMExports();t.after(()=>{injected.mock.restore();syncBuiltinESMExports();});
 const result=await list(f);assert.deepEqual(result.entries.map(x=>x.name),['B.txt']);
 assert.equal(result.coverage.entriesChecked,2);assert.equal(result.coverage.supportedFilesChecked,1);
 assert.deepEqual(result.coverage.gaps,[{relativePath:'A.md',reason:'metadata_unavailable'}]);
});
test('SOURCE_IO directory replacement after anchored enumeration retains observations but cannot open replacement files',async t=>{
 const f=await notesFixture(t);await put(f,'A.md');const resolve=f.fs.resolve.bind(f.fs);let count=0;
 t.mock.method(f.fs,'resolve',async(...params)=>{
  if(++count===3){await rename(join(f.root,'notes'),join(f.root,'old'));await mkdir(join(f.root,'notes'));await put(f,'A.md',startAtMs+1000,'new');}
  return resolve(...params);
 });
 const result=await list(f);assert.equal(result.entries.length,1);
 assert.deepEqual(result.coverage.gaps,[{relativePath:null,reason:'directory_changed'}]);
 await assert.rejects(f.fs.dshGoReadNote(result.directory,result.entries[0],65536),{code:'FS_STALE_VERSION'});
});
test('SOURCE_IO abort after an actual Dir.read closes before any complete report can be returned',async t=>{
 const f=await notesFixture(t);await put(f,'A.md');const controller=new AbortController();
 const read=Dir.prototype.read,close=Dir.prototype.close;let closes=0;
 t.mock.method(Dir.prototype,'read',async function(...params){const result=await read.apply(this,params);controller.abort();return result;});
 t.mock.method(Dir.prototype,'close',function(...params){if(params[0]===undefined)closes++;return close.apply(this,params);});
 await assert.rejects(f.fs.dshGoListDrafts(f.directory,args,controller.signal));assert.equal(closes,1);
});
test('SOURCE_IO same-size same-mtime replacement refuses A while the original B still opens',async t=>{
 const f=await notesFixture(t);const a=await put(f,'A.md');await put(f,'B.txt');
 const listing=await list(f),before=await stat(a);await rename(a,join(f.root,'old-A.md'));
 await writeFile(a,'xyz');await utimes(a,before.atime,before.mtime);
 const oldA=listing.entries.find(x=>x.name==='A.md'),oldB=listing.entries.find(x=>x.name==='B.txt');
 assert.equal((await stat(a)).size,before.size);assert.equal((await stat(a)).mtimeMs,before.mtimeMs);
 await assert.rejects(f.fs.dshGoReadNote(listing.directory,oldA,65536),{code:'FS_STALE_VERSION'});
 assert.equal((await f.fs.dshGoReadNote(listing.directory,oldB,65536)).text,'abc');
});
test('SOURCE_IO actual OS permission boundary: names/mtime visible but unreadable A never yields bytes',async t=>{
 const f=await notesFixture(t);await put(f,'A.md');await put(f,'B.txt');
 await chmod(f.root,0o755);await chmod(join(f.root,'notes'),0o755);await chmod(join(f.root,'notes','A.md'),0);
 t.after(()=>chmod(join(f.root,'notes','A.md'),0o600).catch(()=>{}));
 const helper=new URL('./fixtures/companion-notes-files-source.mjs',import.meta.url).href;
 const code=`import {notesProviders} from ${JSON.stringify(helper)};
 const {LocalFileSystem}=await notesProviders(process.env.DSH_FS_NOTES_SOURCE);
 const fs=new LocalFileSystem({},{cwd:process.env.DRAFT_ROOT,diffBasisMaxBytes:10485760});
 const directory=await fs.dshGoBindNotesDirectory(await fs.resolve(process.env.DRAFT_ROOT+'/notes'));
 const result=await fs.dshGoListDrafts(directory,${JSON.stringify(args)});
 const reads=[];for(const entry of result.entries){try{reads.push({name:entry.name,text:(await fs.dshGoReadNote(directory,entry,65536)).text});}catch(e){reads.push({name:entry.name,error:e.code});}}
 process.stdout.write(JSON.stringify({coverage:result.coverage,reads,uid:process.getuid(),gid:process.getgid()}));`;
 const outcome=await new Promise((resolve,reject)=>{
  const child=spawn(process.execPath,['--input-type=module','-e',code],{
   env:{...process.env,DSH_FS_NOTES_SOURCE:notesSourceRoot(),DRAFT_ROOT:f.root},
   ...(process.getuid()===0?{uid:65534,gid:65534}:{})});let out='',err='';
  child.stdout.on('data',data=>{out+=data;});child.stderr.on('data',data=>{err+=data;});
  child.on('error',reject);child.on('close',exit=>{if(exit!==0)reject(new Error(err));else resolve(JSON.parse(out));});
 });
 assert.equal(outcome.uid,process.getuid()===0?65534:process.getuid());assert.notEqual(outcome.uid,0);
 t.diagnostic(JSON.stringify({real_OS_EACCES_uid:outcome.uid,gid:outcome.gid}));
 assert.equal(outcome.coverage.supportedFilesChecked,2);assert.equal(outcome.coverage.enumerationComplete,true);
 assert.deepEqual(outcome.reads.find(row=>row.name==='A.md'),{name:'A.md',error:'EACCES'});
 assert.equal(outcome.reads.find(row=>row.name==='B.txt').text,'abc');
});

for (const mode of ['removed','file']) test(`SOURCE_IO postscan directory ${mode} retains original observations without opening a substitute`,async t=>{
 const f=await notesFixture(t);await put(f,'A.md');const resolve=f.fs.resolve.bind(f.fs);let count=0;
 t.mock.method(f.fs,'resolve',async(...params)=>{
  if(++count===3){await rename(join(f.root,'notes'),join(f.root,'old'));if(mode==='file')await writeFile(join(f.root,'notes'),'replacement');}
  return resolve(...params);
 });
 const result=await list(f);assert.deepEqual(result.entries.map(x=>x.name),['A.md']);
 assert.equal(result.coverage.entriesChecked,1);assert.equal(result.coverage.enumerationComplete,true);
 assert.deepEqual(result.coverage.gaps,[{relativePath:null,reason:'directory_changed'}]);
 await assert.rejects(f.fs.dshGoReadNote(result.directory,result.entries[0],65536),{code:mode==='file'?'FS_NOT_DIRECTORY':'ENOENT'});
});
for (const mode of ['removed','file']) test(`SOURCE_IO initial directory ${mode} has no fabricated partial or empty-complete result`,async t=>{
 const f=await notesFixture(t);await put(f,'A.md');await rename(join(f.root,'notes'),join(f.root,'old'));
 if(mode==='file')await writeFile(join(f.root,'notes'),'replacement');
 await assert.rejects(list(f),{code:mode==='file'?'FS_NOT_DIRECTORY':'ENOENT'});
});
test('SOURCE_IO controlled late permission recheck failure preserves metadata and marks coverage unavailable',async t=>{
 const f=await notesFixture(t);await put(f,'A.md');const resolve=f.fs.resolve.bind(f.fs);let count=0;
 t.mock.method(f.fs,'resolve',async(...params)=>{if(++count===3)throw Object.assign(new Error('controlled late EACCES'),{code:'EACCES'});return resolve(...params);});
 const result=await list(f);assert.equal(result.entries.length,1);
 assert.deepEqual(result.coverage.gaps,[{relativePath:null,reason:'directory_unavailable'}]);
});
test('SOURCE_IO late abort remains aborted after actual observations and is not turned into partial',async t=>{
 const f=await notesFixture(t);await put(f,'A.md');const controller=new AbortController(),resolve=f.fs.resolve.bind(f.fs);let count=0;
 t.mock.method(f.fs,'resolve',async(...params)=>{if(++count===3)controller.abort();return resolve(...params);});
 await assert.rejects(f.fs.dshGoListDrafts(f.directory,args,controller.signal),{code:'FS_ABORTED'});
});
test('SOURCE_IO unexpected late programming error is not relabelled as an IO observation',async t=>{
 const f=await notesFixture(t);await put(f,'A.md');const resolve=f.fs.resolve.bind(f.fs);let count=0;
 t.mock.method(f.fs,'resolve',async(...params)=>{if(++count===3)throw new TypeError('controlled programming error');return resolve(...params);});
 await assert.rejects(list(f),TypeError);
});
