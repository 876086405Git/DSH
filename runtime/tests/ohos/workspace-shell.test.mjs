import test from 'node:test';import assert from 'node:assert/strict';
import fs from 'node:fs';import fsp from 'node:fs/promises';import path from 'node:path';import os from 'node:os';
import {randomUUID} from 'node:crypto';import {createRequire} from 'node:module';import {Worker} from 'node:worker_threads';import {once} from 'node:events';
import {createGrantAuthority} from '../../ohos/process/files/authority.mjs';
const require=createRequire(import.meta.url);
const publisher=require(process.env.OHOS_GRANT_PUBLISHER),binding=require(process.env.OHOS_GRANT_ADDON);
const authority=createGrantAuthority({hostLibrary:process.env.OHOS_GRANT_HOST,binding});
function worker(data){return new Worker(new URL('./workspace-shell-worker.mjs',import.meta.url),{workerData:{...data,binding:process.env.OHOS_GRANT_ADDON,host:process.env.OHOS_GRANT_HOST}});}
async function fixture(t,writable=true){const root=await fsp.mkdtemp(path.join(os.tmpdir(),'dsh-grant-shell-')),selected=path.join(root,'selected'),temporary=path.join(root,'temporary');await fsp.mkdir(selected);await fsp.mkdir(temporary);await fsp.writeFile(path.join(selected,'marker'),'MARKER');
 const uuid=randomUUID(),id='trusted:'+uuid,mountPoint='/workspaces/'+uuid;const fd=fs.openSync(selected,'r');publisher.workspaceGrant('publish',id,1,fd,writable);fs.closeSync(fd);
 t.after(()=>{publisher.workspaceGrant('retire',id,1);return fsp.rm(root,{recursive:true,force:true});});
 return{root,selected,temporary,id,mountPoint,descriptor:{id,generation:1,mountPoint,writable}};}
async function run(f,script,readOnly=false,extra={}){const job=authority.issue([f.descriptor],{readOnly,workspaceRoot:f.mountPoint});const w=worker({mounts:job.mounts,temporary:f.temporary,cwd:f.mountPoint,script,readOnly,filesystem:process.env.OHOS_GRANT_BASELINE_FS,...extra});
 const exit=once(w,'exit');const [message]=await once(w,'message');await exit;assert.equal(job.retire(),true);return message;}

test('real shell ls/cat/printf redirection/mkdir/mv/rm modify only the selected FD root',async t=>{
 const f=await fixture(t);const response=await run(f,"ls; cat marker; printf 'hello\\n' > written; mkdir child; mv written child/moved; cat child/moved; rm child/moved; rmdir child");
 assert.equal(response.failure,undefined);assert.equal(response.result.exitCode,0,JSON.stringify(response));assert.match(response.result.stdout,/marker/);assert.match(response.result.stdout,/MARKER/);assert.match(response.result.stdout,/hello/,JSON.stringify(response));
 assert.deepEqual(await fsp.readdir(f.selected),['marker']);assert.equal(publisher.workspaceGrant('status',f.id,1).leases,0);
});
test('task RO rejects writes while preserving real file and allows reading',async t=>{
 const f=await fixture(t);const read=await run(f,'cat marker',true);assert.equal(read.result.stdout,'MARKER');const response=await run(f,"printf BAD > marker",true);assert.equal(response.failure?.code,'EACCES');assert.equal(await fsp.readFile(path.join(f.selected,'marker'),'utf8'),'MARKER');
});
test('OS/grant RO cannot be widened by task request or caller strings',async t=>{
 const f=await fixture(t,false);assert.throws(()=>binding.issue('1'.repeat(64),f.id,1,true),{code:'ERR_WORKSPACE_READ_ONLY'});
 assert.throws(()=>binding.consume('2'.repeat(64)),{code:'ERR_WORKSPACE_TICKET'});
 const response=await run(f,'cat marker');assert.equal(response.result.stdout,'MARKER');
});
test('append and binary redirection preserve actual bytes',async t=>{
 const f=await fixture(t);await fsp.writeFile(path.join(f.selected,'raw'),Buffer.from([255,0]));const response=await run(f,"printf A > marker; printf B >> marker; cat raw > bytes; cat marker");assert.equal(response.result.exitCode,0);assert.equal(await fsp.readFile(path.join(f.selected,'marker'),'utf8'),'AB',JSON.stringify(response));assert.deepEqual(await fsp.readFile(path.join(f.selected,'bytes')),Buffer.from([255,0]));
});
test('root rename keeps chosen object and does not grant the replacement path',async t=>{
 const f=await fixture(t);await fsp.rename(f.selected,path.join(f.root,'moved'));await fsp.mkdir(f.selected);await fsp.writeFile(path.join(f.selected,'marker'),'WRONG');
 const response=await run(f,'cat marker');assert.equal(response.result.stdout,'MARKER');
});
test('user Worker cannot issue tickets or rebind initialized owner',async()=>{
 const w=worker({probeOwner:true});const exit=once(w,'exit');const [message]=await once(w,'message');await exit;
 assert.equal(message.issue,'ERR_WORKSPACE_OWNER');assert.equal(message.bind,'ERR_WORKSPACE_OWNER_ALREADY_BOUND');
});
test('ticket retire rejects old IO but keeps lease until actual Worker exit',async t=>{
 const f=await fixture(t),job=authority.issue([f.descriptor],{workspaceRoot:f.mountPoint});const w=worker({mounts:job.mounts,temporary:f.temporary,cwd:f.mountPoint,script:'cat marker',hold:true});
 t.after(()=>w.terminate());const [first]=await once(w,'message');assert.equal(first.result.stdout,'MARKER');
 assert.equal(publisher.workspaceGrant('status',f.id,1).leases,1);assert.equal(job.retire(),false);
 const next=once(w,'message');w.postMessage('read');assert.equal((await next)[0].afterError,'ERR_WORKSPACE_TASK_RETIRED');
 await w.terminate();assert.equal(job.retire(),true);assert.equal(publisher.workspaceGrant('status',f.id,1).leases,0);
});
test('unconsumed ticket can be retired before Worker creation and never revived',async t=>{
 const f=await fixture(t),job=authority.issue([f.descriptor],{workspaceRoot:f.mountPoint});assert.equal(job.retire(),true);assert.throws(()=>binding.consume(job.mounts[0].ticket),{code:'ERR_WORKSPACE_TICKET'});assert.equal(publisher.workspaceGrant('status',f.id,1).leases,0);
});
test('symlink escape and unrelated host path remain denied',async t=>{
 const f=await fixture(t);await fsp.writeFile(path.join(f.root,'outside'),'OUTSIDE');await fsp.symlink('../outside',path.join(f.selected,'link'));
 const response=await run(f,'cat link');assert.notEqual(response.result.exitCode,0);assert(!response.result.stdout.includes('OUTSIDE'));
 const absolute=await run(f,`cat '${path.join(f.root,'outside')}'`);assert.notEqual(absolute.result.exitCode,0);assert(!absolute.result.stdout.includes('OUTSIDE'));
});

test('scoped group and persistent redirection preserve cursor semantics',async t=>{
 const f=await fixture(t);const response=await run(f,"{ printf ABC; printf DEF; } > marker; cat marker; exec 3>marker; printf G >&3; printf H >&3; exec 3>&-; cat marker");assert.equal(response.result.exitCode,0);assert.equal(response.result.stdout,'ABCDEFGH');assert.equal(await fsp.readFile(path.join(f.selected,'marker'),'utf8'),'GH');
});
test('same native ticket is single-use and construction cleanup releases consumed lease',async t=>{
 const f=await fixture(t),job=authority.issue([f.descriptor],{workspaceRoot:f.mountPoint});const handle=binding.consume(job.mounts[0].ticket);
 assert.throws(()=>binding.consume(job.mounts[0].ticket),{code:'ERR_WORKSPACE_TICKET'});binding.close(handle);assert.equal(job.retire(),true);assert.equal(publisher.workspaceGrant('status',f.id,1).leases,0);
});
test('immediate Worker termination leaves no pending or consumed ticket lease',async t=>{
 const f=await fixture(t),job=authority.issue([f.descriptor],{workspaceRoot:f.mountPoint});const w=worker({mounts:job.mounts,temporary:f.temporary,cwd:f.mountPoint,script:'cat marker'});
 await w.terminate();assert.equal(job.retire(),true);assert.equal(publisher.workspaceGrant('status',f.id,1).leases,0);
});
test('native generation mismatch cannot issue a task capability',async t=>{
 const f=await fixture(t);assert.throws(()=>authority.issue([{...f.descriptor,generation:2}],{workspaceRoot:f.mountPoint}),{code:'ERR_WORKSPACE_GENERATION'});assert.equal(publisher.workspaceGrant('status',f.id,1).leases,0);
});

test('grant RO rejects actual shell write even when outer proxy is workspace-write',async t=>{
 const f=await fixture(t,false);const result=await run(f,'printf BAD > marker');
 assert(result.failure?.code==='ERR_WORKSPACE_READ_ONLY'||result.result?.exitCode!==0);
 assert.equal(await fsp.readFile(path.join(f.selected,'marker'),'utf8'),'MARKER');
});
test('partial filesystem construction releases already-consumed lease and unused ticket',async t=>{
 const f=await fixture(t),second=await fixture(t),job=authority.issue([f.descriptor],{workspaceRoot:f.mountPoint}),secondJob=authority.issue([second.descriptor],{workspaceRoot:second.mountPoint});
 const malformed=[job.mounts[0],{...secondJob.mounts[0],mountPoint:job.mounts[0].mountPoint}];
 const w=worker({mounts:malformed,temporary:f.temporary,cwd:f.mountPoint,script:'cat marker'});const exit=once(w,'exit');const [message]=await once(w,'message');await exit;
 assert.equal(message.failure.code,'ERR_WORKSPACE_MOUNT');assert.equal(job.retire(),true);assert.equal(secondJob.retire(),true);
 assert.equal(publisher.workspaceGrant('status',f.id,1).leases,0);assert.equal(publisher.workspaceGrant('status',second.id,1).leases,0);
});

test('narrower task scope is rejected rather than expanded to the whole grant',async t=>{
 const f=await fixture(t);assert.throws(()=>authority.issue([f.descriptor],{workspaceRoot:f.mountPoint+'/sub'}),{code:'ERR_WORKSPACE_SCOPE_UNSUPPORTED'});
 assert.throws(()=>authority.issue([f.descriptor]),{code:'ERR_WORKSPACE_SCOPE_UNSUPPORTED'});assert.equal(publisher.workspaceGrant('status',f.id,1).leases,0);
});
