import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {loadRecovery,RecoveryFiles,ids} from './recovery-fixture.mjs';
const Recovery=await loadRecovery();
const childFlags=process.execArgv.filter(flag=>flag==='--jitless');
async function fixture(t,hook){const root=await fs.mkdtemp(join(tmpdir(),'dsh-rescue-'));t.after(()=>fs.rm(root,{recursive:true,force:true}));const store=new RecoveryFiles(root,hook);return {root,store,r:new Recovery(store,root)};}
async function put(root,path,text){const p=join(root,path);await fs.mkdir(join(p,'..'),{recursive:true});await fs.writeFile(p,text);}
async function setup(t,hook){const c=await fixture(t,hook);await put(c.root,'dsh-runtime/tree/old.js','old');await put(c.root,'runtime/rootfs/root/.dsh/profiles/config','plugins');await put(c.root,'runtime/rootfs/root/.dsh/dsh-go/ui.json','ui');await put(c.root,'runtime/rootfs/root/.dsh/credentials','engine credential');await put(c.root,'runtime/rootfs/root/workspace/out.txt','user output');await put(c.root,'dsh-secrets/vault.bin','app key');await put(c.root,'preferences/hosts.json','host config');
 c.install=async()=>{await put(c.root,'dsh-runtime/tree/new.js','new');};return c;}
async function preserved(c){assert.equal(await fs.readFile(join(c.root,'dsh-secrets/vault.bin'),'utf8'),'app key');assert.equal(await fs.readFile(join(c.root,'preferences/hosts.json'),'utf8'),'host config');}
test('actual SIGKILL leaves durable active marker; two new processes count exactly twice',{timeout:20000},async t=>{
 const c=await fixture(t);const actor=new URL('./recovery-actor.mjs',import.meta.url);
 for(const id of ids.slice(0,2)){
  const child=spawn(process.execPath,[...childFlags,actor.pathname,c.root,'arm',id],{env:process.env,stdio:['ignore','pipe','pipe']});t.after(()=>{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');});const exited=once(child,'exit');let line='';
  await new Promise((yes,no)=>{child.stdout.on('data',b=>{line+=b;if(line.includes('\n'))yes();});child.on('error',no);child.on('exit',()=>no(new Error('actor exited before armed')));});
  assert.equal(JSON.parse(line).ready,true);child.kill('SIGKILL');assert.deepEqual(await exited,[null,'SIGKILL']);
 }
 const inspect=spawn(process.execPath,[...childFlags,actor.pathname,c.root,'inspect'],{env:process.env,stdio:['ignore','pipe','pipe']});let result='';inspect.stdout.on('data',b=>result+=b);assert.equal((await once(inspect,'exit'))[0],0);const state=JSON.parse(result);assert.equal(state.strikes,2);assert.equal(state.failure.kind,'killed');
 const next=new Recovery(new RecoveryFiles(c.root),c.root);await next.initialize(300,async()=>{},()=>false);assert.equal(next.status().strikes,2);
});
test('same attempt settles once; old completion cannot clear a new attempt; clearFailure retains strikes',async t=>{
 const c=await fixture(t);await c.r.initialize(1,async()=>{},()=>false);await c.r.arm(ids[0],2);await c.r.finish(ids[0],false,3,23);await c.r.finish(ids[0],false,4,23);assert.equal(c.r.status().strikes,1);await c.r.clearFailure();assert.equal(c.r.status().strikes,1);assert.equal(c.r.status().failure,null);
 await c.r.arm(ids[1],5);await c.r.finish(ids[0],true,6);assert.equal(JSON.parse(await c.store.read(c.r.directory+'/boot.json')).active.id,ids[1]);await c.r.finish(ids[1],true,7);assert.equal(c.r.status().strikes,0);
});
test('a run that got past starting up starts the count over; its own unclean end counts once',async t=>{
 const c=await fixture(t);await c.r.initialize(1,async()=>{},()=>false);
 await c.r.arm(ids[0],2);await c.r.finish(ids[0],false,3,23);await c.r.arm(ids[1],4);await c.r.finish(ids[1],false,5,23);assert.equal(c.r.status().strikes,2);
 await c.r.arm(ids[2],6);await c.r.markHealthy(ids[0]);assert.equal(c.r.status().strikes,2,'an old run cannot speak for this one');
 await c.r.markHealthy(ids[2]);assert.equal(c.r.status().strikes,0);assert.equal(c.r.status().failure,null);
 const saved=JSON.parse(await c.store.read(c.r.directory+'/boot.json'));assert.equal(saved.strikes,0);assert.equal(saved.active.id,ids[2],'the mark stays: dying now is still unclean');
 const next=new Recovery(new RecoveryFiles(c.root),c.root);await next.initialize(7,async()=>{},()=>false);assert.equal(next.status().strikes,1);assert.equal(next.status().failure.kind,'killed');
});
test('explicit reinstall reset removes only runtime trees and preserves app hosts and keys',async t=>{
 const c=await setup(t);await c.r.requestReset([],ids[0],true);assert.equal(await fs.readFile(join(c.root,'dsh-runtime/tree/old.js'),'utf8'),'old');
 await c.r.initialize(1,c.install,()=>false);await preserved(c);assert.equal(await fs.readFile(join(c.root,'dsh-runtime/tree/new.js'),'utf8'),'new');assert.equal(await c.store.kind(join(c.root,'runtime/rootfs')),'missing');assert.equal(await c.store.read(c.r.directory+'/reset.json'),null);
});
test('a reset takes the last good config and a restore cut short with it, and no keys',async t=>{
 const c=await setup(t);const names=['lkg.json','lkg-restore.json','lkg-restore-backup.json'];
 for(const name of names)await put(c.root,'dsh-recovery/'+name,'{"snapshot":"the old profile"}');
 await c.r.requestReset([],ids[0],true);await c.r.initialize(1,c.install,()=>false);await preserved(c);
 for(const name of names)await assert.rejects(fs.access(join(c.root,'dsh-recovery',name)),{code:'ENOENT'});
});
test('both ResetKeep choices restore exact selected bytes, not unselected credentials/workspace',async t=>{
 const c=await setup(t);await c.r.requestReset(['uiAndSkills','pluginsAndSettings'],ids[0],true);await c.r.initialize(1,c.install,()=>false);await preserved(c);
 assert.equal(await fs.readFile(join(c.root,'runtime/rootfs/root/.dsh/profiles/config'),'utf8'),'plugins');assert.equal(await fs.readFile(join(c.root,'runtime/rootfs/root/.dsh/dsh-go/ui.json'),'utf8'),'ui');assert.equal(await c.store.kind(join(c.root,'runtime/rootfs/root/.dsh/credentials')),'missing');assert.equal(await c.store.kind(join(c.root,'runtime/rootfs/root/workspace')),'missing');
});
test('loaded native blocks reset before any move/delete/install and marker remains',async t=>{
 const c=await setup(t);await c.r.requestReset([],ids[0],true);let installs=0;await assert.rejects(c.r.initialize(1,async()=>{installs++;},()=>true),{code:'ohos_restart_required'});assert.equal(installs,0);assert.equal(await fs.readFile(join(c.root,'dsh-runtime/tree/old.js'),'utf8'),'old');assert.notEqual(await c.store.read(c.r.directory+'/reset.json'),null);
});
test('invalid choices and corrupted records fail closed, explicit reset can replace damaged boot state',async t=>{
 const c=await setup(t);for(const keep of [['../'],['uiAndSkills','uiAndSkills'],['/etc']])await assert.rejects(c.r.requestReset(keep,ids[0],true));await c.store.mkdir(c.r.directory);await c.store.write(c.r.directory+'/boot.json','{"schema":99}');await assert.rejects(c.r.initialize(1,c.install,()=>false));await c.r.requestReset([],ids[0],true);await c.r.initialize(2,c.install,()=>false);assert.equal(c.r.status().strikes,0);
});
test('crash after keep rename and install failure resume without losing either kept or external bytes',async t=>{
 let hit=false;const c=await setup(t,async(op)=>{if(op==='after:move'&&!hit){hit=true;throw new Error('interrupted rename receipt');}});await c.r.requestReset(['uiAndSkills'],ids[0],true);await assert.rejects(c.r.initialize(1,c.install,()=>false));
 let failed=true;const next=new Recovery(new RecoveryFiles(c.root),c.root);await assert.rejects(next.initialize(2,async()=>{if(failed){failed=false;throw new Error('install failure');}await c.install();},()=>false));assert.notEqual(await c.store.read(c.r.directory+'/reset.json'),null);
 await next.initialize(3,c.install,()=>false);assert.equal(await fs.readFile(join(c.root,'runtime/rootfs/root/.dsh/dsh-go/ui.json'),'utf8'),'ui');await preserved(c);
});
test('directory fsync failure after commit never allows successful initialization; retry reads disk',async t=>{
 let fail=false;const c=await fixture(t,async op=>{if(fail&&op==='before:directory-fsync'){fail=false;throw new Error('sync unavailable');}});await c.r.initialize(1,async()=>{},()=>false);fail=true;await assert.rejects(c.r.arm(ids[0],2));
 assert.notEqual(JSON.parse(await c.store.read(c.r.directory+'/boot.json')).active,null);
 const next=new Recovery(new RecoveryFiles(c.root),c.root);await next.initialize(3,async()=>{},()=>false);assert.equal(next.status().strikes,1);
});
test('existing keep directory cannot be adopted by a new reset request',async t=>{
 const c=await setup(t);await put(c.root,'dsh-recovery/keep-'+ids[0]+'/unrelated','prior data');
 await assert.rejects(c.r.requestReset([],ids[0],true));assert.equal(await c.store.read(c.r.directory+'/reset.json'),null);
});
test('a recorded kept item missing at both ends blocks before deleting other original data',async t=>{
 let hit=false;const c=await setup(t,async(op,paths)=>{
  if(op==='after:write'&&paths[0].endsWith('/reset.json')&&!hit){const record=JSON.parse(paths[1]);if(record.kept.length){hit=true;throw new Error('crash after kept receipt');}}
 });
 await c.r.requestReset(['uiAndSkills'],ids[0],true);await assert.rejects(c.r.initialize(1,c.install,()=>false));
 await fs.rm(join(c.root,'dsh-recovery/keep-'+ids[0]+'/root/.dsh/dsh-go'),{recursive:true});
 const next=new Recovery(new RecoveryFiles(c.root),c.root);await assert.rejects(next.initialize(2,c.install,()=>false));
 assert.equal(await fs.readFile(join(c.root,'dsh-runtime/tree/old.js'),'utf8'),'old');
});
test('missing kept bytes in deleting/installing phase block before further destructive work',async t=>{
 for(const phase of ['deleting','installing']){
  let stop=true;const c=await setup(t,async(op,paths)=>{
   if(stop&&op==='after:write'&&paths[0].endsWith('/reset.json')&&JSON.parse(paths[1]).stage===phase){stop=false;throw new Error('phase boundary interruption');}
  });
  await c.r.requestReset(['uiAndSkills'],ids[0],true);await assert.rejects(c.r.initialize(1,c.install,()=>false));
  await fs.rm(join(c.root,'dsh-recovery/keep-'+ids[0]+'/root/.dsh/dsh-go'),{recursive:true});
  const store=new RecoveryFiles(c.root);const next=new Recovery(store,c.root);let installs=0;
  await assert.rejects(next.initialize(2,async()=>{installs++;await c.install();},()=>false));
  assert.equal(store.events.filter(e=>e.op==='before:tree').length,0,'must verify keep before deletion');assert.equal(installs,0,'must verify keep before install');
  if(phase==='deleting')assert.equal(await fs.readFile(join(c.root,'dsh-runtime/tree/old.js'),'utf8'),'old');
 }
});
test('installer-created target cannot stand in for a missing kept item without a restore intent',async t=>{
 const c=await setup(t);await c.r.requestReset(['uiAndSkills'],ids[0],true);
 await assert.rejects(c.r.initialize(1,async()=>{
  await c.install();await fs.rm(join(c.root,'dsh-recovery/keep-'+ids[0]+'/root/.dsh/dsh-go'),{recursive:true});
  await put(c.root,'runtime/rootfs/root/.dsh/dsh-go/ui.json','fresh installer default');
 },()=>false));
 assert.notEqual(await c.store.read(c.r.directory+'/reset.json'),null);
});
test('ambiguous reset commit blocks subsequent native admission in the same process',async t=>{
 let armed=false;const c=await fixture(t,async(op,paths)=>{if(armed&&op==='after:commit'&&paths[0].endsWith('/reset.json'))throw new Error('reset commit acknowledgement lost');});
 await c.r.initialize(1,async()=>{},()=>false);armed=true;await assert.rejects(c.r.requestReset([],ids[0],true));
 assert.equal(c.r.status().resetPending,true);await assert.rejects(c.r.arm(ids[1],2));
});
test('actual SIGKILL at every persisted reset phase resumes and retains selected assets',{timeout:30000},async t=>{
 for(const phase of ['saving','deleting','installing','restoring','complete']){
  const c=await setup(t);await c.r.requestReset(['uiAndSkills','pluginsAndSettings'],ids[0],true);
  const child=spawn(process.execPath,[...childFlags,new URL('./recovery-actor.mjs',import.meta.url).pathname,c.root,'reset',phase],{env:process.env,stdio:['ignore','pipe','pipe']});t.after(()=>{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');});const exited=once(child,'exit');let line='';
  await new Promise((yes,no)=>{child.stdout.on('data',b=>{line+=b;if(line.includes('\n'))yes();});child.on('error',no);child.on('exit',()=>no(new Error('actor exited before phase '+phase)));});assert.equal(JSON.parse(line).stage,phase);child.kill('SIGKILL');assert.deepEqual(await exited,[null,'SIGKILL']);
  const next=new Recovery(new RecoveryFiles(c.root),c.root);await next.initialize(4,c.install,()=>false);assert.equal(await fs.readFile(join(c.root,'runtime/rootfs/root/.dsh/profiles/config'),'utf8'),'plugins');assert.equal(await fs.readFile(join(c.root,'runtime/rootfs/root/.dsh/dsh-go/ui.json'),'utf8'),'ui');assert.equal(await c.store.read(c.r.directory+'/reset.json'),null);await preserved(c);
 }
});
test('each file-sync/rename/phase-commit interruption is recoverable without clearing reset early',async t=>{
 const relevant=(op,paths)=>['before:move','after:move','before:file-fsync','after:file-fsync','before:directory-fsync','after:directory-fsync','before:tree','after:tree','before:commit','after:commit','before:unlink','after:unlink'].includes(op);
 const baseline=await setup(t);await baseline.r.requestReset(['uiAndSkills','pluginsAndSettings'],ids[0],true);baseline.store.events.length=0;await baseline.r.initialize(1,baseline.install,()=>false);const points=baseline.store.events.filter(e=>relevant(e.op,e.paths));
 assert(points.length>30);
 for(let target=0;target<points.length;target++){
  let active=false,count=0,hit=false;const c=await setup(t,async(op,paths)=>{if(active&&relevant(op,paths)&&count++===target){hit=true;throw new Error('fault '+target+' '+op);}});await c.r.requestReset(['uiAndSkills','pluginsAndSettings'],ids[0],true);active=true;await assert.rejects(c.r.initialize(1,c.install,()=>false));assert(hit);
  const next=new Recovery(new RecoveryFiles(c.root),c.root);await next.initialize(2,c.install,()=>false);await preserved(c);assert.equal(await fs.readFile(join(c.root,'runtime/rootfs/root/.dsh/profiles/config'),'utf8'),'plugins');assert.equal(await fs.readFile(join(c.root,'runtime/rootfs/root/.dsh/dsh-go/ui.json'),'utf8'),'ui');assert.equal(await c.store.read(c.r.directory+'/reset.json'),null);
 }
 console.log('RESET_FAULT_POINTS',points.length);
});
test('all four ResetKeep selections preserve exactly the six Android paths',async t=>{
 const ui=['root/.dsh/dsh-go/ui.json','root/.dsh/skills/one','root/.agents/skills/one'];const plugins=['root/.dsh/profiles/config','root/.dsh/cordis.patch.yml','root/.dsh/.env'];
 for(const keep of [[],['uiAndSkills'],['pluginsAndSettings'],['uiAndSkills','pluginsAndSettings']]){
  const c=await setup(t);for(const path of [...ui,...plugins])await put(c.root,'runtime/rootfs/'+path,'saved:'+path);
  await c.r.requestReset(keep,ids[0],true);await c.r.initialize(1,c.install,()=>false);
  for(const path of [...ui,...plugins]){const full=join(c.root,'runtime/rootfs',path);const retain=ui.includes(path)?keep.includes('uiAndSkills'):keep.includes('pluginsAndSettings');
   if(retain)assert.equal(await fs.readFile(full,'utf8'),'saved:'+path);else assert.equal(await c.store.kind(full),'missing');}
  await preserved(c);
 }
});
test('successful native import without engine start preserves earlier strikes and leaves no unclean run',async t=>{
 const c=await fixture(t);await c.r.initialize(1,async()=>{},()=>false);await c.r.arm(ids[0],2);await c.r.finish(ids[0],false,3);
 await c.r.arm(ids[1],4,'nativeLoad');await c.r.finish(ids[1],true,5);
 assert.equal(c.r.status().strikes,1);const next=new Recovery(new RecoveryFiles(c.root),c.root);await next.initialize(6,async()=>{},()=>false);assert.equal(next.status().strikes,1);
});
test('interrupted native import records launch failure, not an engine that never started',async t=>{
 const c=await fixture(t);await c.r.initialize(1,async()=>{},()=>false);await c.r.arm(ids[0],2,'nativeLoad');
 const next=new Recovery(new RecoveryFiles(c.root),c.root);await next.initialize(3,async()=>{},()=>false);assert.equal(next.status().strikes,1);assert.equal(next.status().failure.kind,'launchFailed');
});
test('uninstall mode deletes runtime only and waits for explicit installation across reopen',async t=>{
 const c=await setup(t);await c.r.requestReset(['uiAndSkills'],ids[0],false);let installs=0;const install=async()=>{installs++;await c.install();};
 await c.r.initialize(1,install,()=>false);assert.equal(installs,0);assert.equal(await c.store.kind(c.r.payloadRoot),'missing');assert.equal(await c.store.kind(c.r.guestRoot),'missing');await preserved(c);
 assert.equal(c.r.status().waitingInstall,true);assert.notEqual(await c.store.read(c.r.directory+'/reset.json'),null);await assert.rejects(c.r.arm(ids[1],2));
 const next=new Recovery(new RecoveryFiles(c.root),c.root);await next.initialize(3,install,()=>false);assert.equal(installs,0);await next.installPending(install,()=>false);assert.equal(installs,1);assert.equal(await fs.readFile(join(c.root,'runtime/rootfs/root/.dsh/dsh-go/ui.json'),'utf8'),'ui');assert.equal(next.status().resetPending,false);
});
test('cancel before host.start clears only that admission marker and preserves prior failures',async t=>{
 const c=await fixture(t);await c.r.initialize(1,async()=>{},()=>false);await c.r.arm(ids[0],2);await c.r.finish(ids[0],false,3);
 await c.r.arm(ids[1],4);await c.r.cancelBeforeStart(ids[0]);assert.equal(JSON.parse(await c.store.read(c.r.directory+'/boot.json')).active.id,ids[1]);
 await c.r.cancelBeforeStart(ids[1]);assert.equal(c.r.status().strikes,1);assert.equal(c.r.status().failure.kind,'killed');assert.equal(JSON.parse(await c.store.read(c.r.directory+'/boot.json')).active,null);
});
test('waiting-install keeps both choices through restart and refuses missing kept bytes before install',async t=>{
 const c=await setup(t);await c.r.requestReset(['uiAndSkills'],ids[0],false);await c.r.initialize(1,c.install,()=>false);
 await fs.rm(join(c.root,'dsh-recovery/keep-'+ids[0]+'/root/.dsh/dsh-go'),{recursive:true});const next=new Recovery(new RecoveryFiles(c.root),c.root);let installs=0;
 await assert.rejects(next.initialize(2,async()=>{installs++;},()=>false));assert.equal(installs,0);assert.notEqual(await c.store.read(c.r.directory+'/reset.json'),null);
});
test('complete receipt still requires restored bytes before clearing the pending reset',async t=>{
 let stopped=false;const c=await setup(t,async(op,paths)=>{if(!stopped&&op==='after:write'&&paths[0].endsWith('/reset.json')&&JSON.parse(paths[1]).stage==='complete'){stopped=true;throw new Error('crash after complete receipt');}});
 await c.r.requestReset(['uiAndSkills'],ids[0],true);await assert.rejects(c.r.initialize(1,c.install,()=>false));
 await fs.rm(join(c.root,'runtime/rootfs/root/.dsh/dsh-go'),{recursive:true});
 const next=new Recovery(new RecoveryFiles(c.root),c.root);await assert.rejects(next.initialize(2,c.install,()=>false));assert.notEqual(await c.store.read(c.r.directory+'/reset.json'),null);
});

test('actual SIGKILL inside the real native loader import boundary persists a launch failure',{timeout:20000},async t=>{
 const c=await fixture(t);const actor=new URL('./recovery-actor.mjs',import.meta.url).pathname;
 const child=spawn(process.execPath,[...childFlags,actor,c.root,'nativeImport',ids[0]],{env:process.env,stdio:['ignore','pipe','pipe']});t.after(()=>{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');});const exited=once(child,'exit');let line='';
 await new Promise((yes,no)=>{child.stdout.on('data',b=>{line+=b;if(line.includes('\n'))yes();});child.on('error',no);child.on('exit',()=>no(new Error('loader actor exited before import boundary')));});assert.equal(JSON.parse(line).stage,'nativeImport');
 const record=JSON.parse(await c.store.read(c.r.directory+'/boot.json'));assert.equal(record.active.phase,'nativeLoad');child.kill('SIGKILL');assert.deepEqual(await exited,[null,'SIGKILL']);
 const inspect=spawn(process.execPath,[...childFlags,actor,c.root,'inspect'],{env:process.env,stdio:['ignore','pipe','pipe']});let result='';inspect.stdout.on('data',b=>result+=b);assert.equal((await once(inspect,'exit'))[0],0);assert.equal(JSON.parse(result).failure.kind,'launchFailed');assert.equal(JSON.parse(result).strikes,1);
});
test('actual loader import completes without host.start, and the next process has no unclean run',{timeout:20000},async t=>{
 const c=await fixture(t);const actor=new URL('./recovery-actor.mjs',import.meta.url).pathname;
 const child=spawn(process.execPath,[...childFlags,actor,c.root,'nativeDone',ids[0]],{env:process.env,stdio:['ignore','pipe','pipe']});let result='';child.stdout.on('data',b=>result+=b);assert.equal((await once(child,'exit'))[0],0);assert.equal(JSON.parse(result).starts,0);
 const inspect=spawn(process.execPath,[...childFlags,actor,c.root,'inspect'],{env:process.env,stdio:['ignore','pipe','pipe']});let state='';inspect.stdout.on('data',b=>state+=b);assert.equal((await once(inspect,'exit'))[0],0);assert.equal(JSON.parse(state).strikes,0);assert.equal(JSON.parse(state).failure,null);
});


test('manual mode survives reopen, rejects corrupt mode and safe failure preserves main strikes',async t=>{
 const c=await fixture(t);await c.r.initialize(1,async()=>{},()=>false);
 await c.r.arm(ids[0],2);await c.r.finish(ids[0],false,3,23);
 assert.equal(await c.r.selectMode('safe'),'safe');
 const next=new Recovery(new RecoveryFiles(c.root),c.root);await next.initialize(4,async()=>{},()=>false);
 assert.equal(await next.selectMode(null),'safe');
 await next.arm(ids[1],5,'engineRun',true);await next.finish(ids[1],false,6,23);
 assert.equal(next.status().strikes,1);assert.equal(next.status().failure.safeMode,true);
 assert.equal(await next.selectMode('normal'),'normal');
 await c.store.write(c.r.directory+'/mode.json','{"schema":1,"mode":"../web"}');
 const invalid=new Recovery(new RecoveryFiles(c.root),c.root);await assert.rejects(invalid.initialize(7,async()=>{},()=>false));
 await invalid.requestReset([],ids[2],true);await invalid.initialize(8,async()=>{},()=>false);
 assert.equal(invalid.status().nextMode,'normal','explicit reset also repairs a corrupt mode record');
});
