import test, { after, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { prepareManagedSkillModules } from './managed-skill-loader.mjs';
import { managedSkillIo } from './managed-skill-fixture.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-managed-skills-'));
const modules = await prepareManagedSkillModules({ source:path.join(repo, 'app/ohos/entry/src/main/ets/runtime'), directory:temp });
const core = await import(modules.coreUrl);
const { OhosManagedSkillStorage } = await import(modules.installerUrl);
const { ManagedSkillService } = await import(modules.serviceUrl);
after(async () => { await fs.rm(temp, { recursive:true, force:true }); });
afterEach(() => { assert.equal(managedSkillIo.opened.size, 0, 'all actual descriptors closed'); managedSkillIo.reset(); });
const SKILL = '---\n# dsh-go:managed\nname: dsh-go-ui\n---\n中文 🐳\n';
const TOKEN = 'fixture-only';
const payload = (value='value', skill=SKILL) => new Map([['SKILL.md', skill], ['nested/data.txt', value]]);
const wire = (root, id='one', files=payload(), generation=1, name='dsh-go-ui') => new Map([
  ['requestId', id], ['expectedRoot', root], ['expectedToken', TOKEN], ['expectedGeneration', generation], ['name', name], ['files', files],
]);
const parsed = (root, ...rest) => { const value=core.ManagedSkillRequest.parse(wire(root,...rest)); assert(value); return value; };
const plain = value => Object.fromEntries(value);
const deferred = () => { let resolve; const promise = new Promise(r => { resolve=r; }); return { promise, resolve }; };
let serial=0;
async function fixture() {
  const root=path.join(temp, `中文 ${++serial}/runtime/rootfs`);
  await fs.mkdir(path.join(root,'root/.dsh'), { recursive:true });
  const directory=path.join(root,'root/.dsh/skills/dsh-go-ui');
  return { root, directory, storage:new OhosManagedSkillStorage(root) };
}
async function noTemps(directory) {
  let entries;
  try { entries=await fs.readdir(directory,{withFileTypes:true}); } catch(error) { if(error.code==='ENOENT')return;throw error; }
  for(const entry of entries){
    assert(!entry.name.startsWith('.dsh-go-tmp-'), entry.name);
    if(entry.isDirectory())await noTemps(path.join(directory,entry.name));
  }
}
class QueueHarness {
  constructor(storage) {
    this.tasks=[];this.deliveries=[];this.results=[];this.owner=new core.ManagedSkillOwner();
    this.queue=new core.ManagedSkillQueue(storage,action=>this.tasks.push(action),action=>this.deliveries.push(action));
  }
  submit(root,id,files=payload(),owner=this.owner,current=()=>true) {
    this.queue.submit(owner,parsed(root,id,files),current,reply=>this.results.push({id,...plain(reply)}));
  }
  deliver(){while(this.deliveries.length)this.deliveries.shift()();}
  async drain(){while(this.tasks.length)await this.tasks.shift()();this.deliver();}
}

test('Service constructor/attach/ready/status/cancel have zero filesystem IO',()=>{
  const service=new ManagedSkillService('/does-not-exist/runtime/rootfs',()=>true);
  const owner=service.attachOwner();service.ready(1,TOKEN);
  assert.equal(service.generationFor(TOKEN),1);service.cancel(owner,'unknown');service.detachOwner(owner);
  assert.equal(managedSkillIo.calls.length,0);
});

test('wire grammar, names, limits and safe generations reject before IO',async()=>{
  const c=await fixture();
  const invalid=[];
  for(const p of ['../x','/x','x/../y','x//y','x/./y','.x','a/'])invalid.push(wire(c.root,'one',new Map([...payload(),[p,'bad']])));
  for(const generation of [null,0,-1,1.5,'1',NaN,Infinity,Number.MAX_SAFE_INTEGER+1])invalid.push(wire(c.root,'one',payload(),generation));
  invalid.push(wire(c.root,'x'.repeat(201)),wire(c.root,'one',payload(),1,'other'),wire(c.root,'one',new Map([['data','no skill']])));
  invalid.push(wire(c.root,'one',new Map([...payload(),['large','x'.repeat(524289)]])));
  for(const value of invalid)assert.equal(core.ManagedSkillRequest.parse(value),null);
  assert.equal(core.ManagedSkillRequest.parse(null),null);
  assert.equal(core.ManagedSkillRequest.parse({}),null);
  assert(core.ManagedSkillRequest.parse(wire(c.root)));
  assert.equal(managedSkillIo.calls.length,0);
});

test('actual Unicode short reads/writes, last SKILL publication and unchanged/BOM preservation',async()=>{
  const c=await fixture();managedSkillIo.maxRead=2;managedSkillIo.maxWrite=3;
  const req=parsed(c.root,'one',payload('中文 🐳'));
  const result=await core.installManagedSkill(c.storage,req,()=>true);
  assert.equal(result.result,'installed');
  for(const [p,text]of req.files)assert.deepEqual(await fs.readFile(path.join(c.directory,p)),Buffer.from(text));
  const renames=managedSkillIo.calls.filter(x=>x.operation==='rename');
  assert.equal(path.basename(renames.at(-1).to),'SKILL.md');
  const before=await fs.stat(path.join(c.directory,'SKILL.md'));
  assert.equal((await core.installManagedSkill(c.storage,req,()=>true)).result,'unchanged');
  assert.equal(managedSkillIo.calls.filter(x=>x.operation==='rename').length,renames.length);
  assert.equal((await fs.stat(path.join(c.directory,'SKILL.md'))).mtimeMs,before.mtimeMs);
  for(const [p,text]of req.files)await fs.writeFile(path.join(c.directory,p),'\ufeff'+text);
  assert.equal((await core.installManagedSkill(c.storage,req,()=>true)).result,'unchanged');
  assert((await fs.readFile(path.join(c.directory,'SKILL.md'),'utf8')).startsWith('\ufeff'));
  await noTemps(c.directory);
});

test('UTF-8 byte budgets and malformed UTF-16 fail without a managed file',async()=>{
  const c=await fixture();
  assert.equal((await core.installManagedSkill(c.storage,parsed(c.root,'large',new Map([...payload(),['large','中'.repeat(200000)]])),()=>true)).reason,'invalid');
  assert.equal((await core.installManagedSkill(c.storage,parsed(c.root,'broken',payload('\ud800')),()=>true)).reason,'io');
  await assert.rejects(fs.access(c.directory),{code:'ENOENT'});
  assert(!managedSkillIo.calls.some(x=>x.operation==='write'||x.operation==='mkdir'));
});

test('removed marker, marker outside frontmatter and malformed existing UTF-8 remain user-owned',async()=>{
  const c=await fixture();await fs.mkdir(c.directory,{recursive:true});
  const file=path.join(c.directory,'SKILL.md');
  for(const data of [Buffer.from(SKILL.replace('# dsh-go:managed','# mine')),Buffer.from('---\nname: mine\n---\n# dsh-go:managed\n'),Buffer.from([0xc3,0x28])]){
    await fs.writeFile(file,data);
    assert.equal((await core.installManagedSkill(c.storage,parsed(c.root),()=>true)).result,'userOwned');
    assert.deepEqual(await fs.readFile(file),data);
  }
  await assert.rejects(fs.access(path.join(c.directory,'nested')),{code:'ENOENT'});
  assert(!managedSkillIo.calls.some(x=>x.operation==='write'));
});

test('wrong root is stale, canonical dot alias works, absent home creates nothing',async()=>{
  const c=await fixture();
  assert.equal((await core.installManagedSkill(c.storage,parsed(c.root+'/other'),()=>true)).reason,'stale');
  assert.equal((await core.installManagedSkill(c.storage,parsed(c.root+'/./'),()=>true)).result,'installed');
  await fs.rm(path.join(c.root,'root'),{recursive:true});
  assert.equal((await core.installManagedSkill(c.storage,parsed(c.root),()=>true)).result,'noHome');
  await assert.rejects(fs.access(path.join(c.root,'root')),{code:'ENOENT'});
});

test('static final and staging links cannot redirect managed data',async()=>{
  const c=await fixture(), outside=path.join(temp,'outside-'+serial);
  await fs.writeFile(outside,'sentinel');await fs.mkdir(path.join(c.directory,'nested'),{recursive:true});
  for(const filename of ['data.txt','.dsh-go-tmp-data.txt']){
    const p=path.join(c.directory,'nested',filename);await fs.symlink(outside,p);
    assert.equal((await core.installManagedSkill(c.storage,parsed(c.root),()=>true)).result,'userOwned');
    assert.equal(await fs.readFile(outside,'utf8'),'sentinel');await fs.unlink(p);
  }
  assert(!managedSkillIo.calls.some(x=>x.operation==='write'));
});

test('cancel after actual fsync stops rename, closes fd and removes temporary',async()=>{
  const c=await fixture();let current=true;
  managedSkillIo.after=async item=>{if(item.operation==='fsync'&&item.path.includes('.dsh-go-tmp-'))current=false;};
  const result=await core.installManagedSkill(c.storage,parsed(c.root),()=>current);
  assert.equal(result.reason,'cancelled');
  await assert.rejects(fs.access(path.join(c.directory,'nested/data.txt')),{code:'ENOENT'});
  await assert.rejects(fs.access(path.join(c.directory,'SKILL.md')),{code:'ENOENT'});await noTemps(c.directory);
});

test('cancel after first commit preserves that file and retry publishes SKILL last',async()=>{
  const c=await fixture();let current=true;
  managedSkillIo.after=async item=>{if(item.operation==='rename')current=false;};
  const result=await core.installManagedSkill(c.storage,parsed(c.root),()=>current);
  assert.equal(result.reason,'cancelled');assert.equal(await fs.readFile(path.join(c.directory,'nested/data.txt'),'utf8'),'value');
  await assert.rejects(fs.access(path.join(c.directory,'SKILL.md')),{code:'ENOENT'});await noTemps(c.directory);
  managedSkillIo.after=null;
  assert.equal((await core.installManagedSkill(c.storage,parsed(c.root),()=>true)).result,'installed');
});

test('cancelled update keeps earlier new data and old SKILL, without pretending rollback',async()=>{
  const c=await fixture();await core.installManagedSkill(c.storage,parsed(c.root,'one',payload('old')),()=>true);
  let current=true;managedSkillIo.after=async item=>{if(item.operation==='rename')current=false;};
  const req=parsed(c.root,'two',payload('new',SKILL+'new instruction\n'));
  assert.equal((await core.installManagedSkill(c.storage,req,()=>current)).reason,'cancelled');
  assert.equal(await fs.readFile(path.join(c.directory,'nested/data.txt'),'utf8'),'new');
  assert.equal(await fs.readFile(path.join(c.directory,'SKILL.md'),'utf8'),SKILL);
  managedSkillIo.after=null;assert.equal((await core.installManagedSkill(c.storage,req,()=>true)).result,'updated');
});

test('IO failure does not publish SKILL or poison the next physical writer',async()=>{
  const c=await fixture();await fs.mkdir(c.directory,{recursive:true});await fs.writeFile(path.join(c.directory,'nested'),'file');
  assert.equal((await core.installManagedSkill(c.storage,parsed(c.root),()=>true)).reason,'io');
  await assert.rejects(fs.access(path.join(c.directory,'SKILL.md')),{code:'ENOENT'});
  await fs.unlink(path.join(c.directory,'nested'));
  assert.equal((await core.installManagedSkill(c.storage,parsed(c.root),()=>true)).result,'installed');await noTemps(c.directory);
});

test('a legal supplied *.dsh-go-tmp file cannot collide with internal temporary names',async()=>{
  const c=await fixture();const files=new Map([['SKILL.md',SKILL],['data.dsh-go-tmp','keep'],['data','data']]);
  assert.equal((await core.installManagedSkill(c.storage,parsed(c.root,'one',files),()=>true)).result,'installed');
  for(const [p,text]of files)assert.equal(await fs.readFile(path.join(c.directory,p),'utf8'),text);await noTemps(c.directory);
});

test('actual writer honors a Uint8Array subview and never writes neighboring bytes',async()=>{
  const c=await fixture();const source=new Uint8Array([99,98,1,2,3,4,97,96]);
  const target=path.join(c.directory,'subview.bin');
  managedSkillIo.maxWrite=2;
  await c.storage.writeFile(target,source.subarray(2,6),()=>true);
  assert.deepEqual(await fs.readFile(target),Buffer.from([1,2,3,4]));await noTemps(c.directory);
});

test('ready/attachment replacement is idempotent, but old scopes and delayed stopped ready cannot revive',()=>{
  const gate=new core.ManagedSkillGate();gate.ready(4,TOKEN);assert.equal(gate.generationFor(TOKEN),null);
  const old=new core.ManagedSkillOwner();gate.attach(old);const first=gate.generationFor(TOKEN);const scope=gate.capture(old,TOKEN,first);
  gate.ready(4,TOKEN);assert.equal(gate.generationFor(TOKEN),first);
  const next=new core.ManagedSkillOwner();assert.equal(gate.attach(next),old);const second=gate.generationFor(TOKEN);
  assert(second>first);assert.equal(gate.current(scope),false);assert.equal(gate.capture(next,TOKEN,first),null);
  gate.detach(old);assert(gate.capture(next,TOKEN,second));gate.stop(4);gate.ready(4,TOKEN);assert.equal(gate.generationFor(TOKEN),null);
  gate.ready(5,TOKEN);assert(gate.generationFor(TOKEN)>second);gate.retire();assert.equal(gate.generationFor(TOKEN),null);
});

test('100 pending requests retain one active plus only the latest pending payload',async()=>{
  const c=await fixture(),h=new QueueHarness(c.storage);h.submit(c.root,'active');
  for(let i=0;i<100;i++)h.submit(c.root,'pending-'+i,payload('value-'+i));
  assert.equal(h.tasks.length,1);await h.drain();assert.equal(h.results.length,101);
  assert.equal(h.results.filter(x=>x.result!==null).length,2);
  assert(h.results.filter(x=>x.result===null).every(x=>x.reason==='stale'&&!x.current));
  assert.equal(await fs.readFile(path.join(c.directory,'nested/data.txt'),'utf8'),'value-99');
});

test('exact active cancellation retains the executor slot; old owner cannot cancel replacement with same id',async()=>{
  const c=await fixture(),h=new QueueHarness(c.storage);h.submit(c.root,'same');h.submit(c.root,'same');h.deliver();
  assert.equal(h.results[0].reason,'duplicate');h.owner.detach();h.queue.cancel(h.owner,'same');
  const next=new core.ManagedSkillOwner();h.submit(c.root,'same',payload('new'),next);h.queue.cancel(h.owner,'same');
  assert.equal(h.tasks.length,1);await h.drain();assert.equal(h.results.length,3);assert.equal(h.results.at(-1).current,true);
  assert.equal(await fs.readFile(path.join(c.directory,'nested/data.txt'),'utf8'),'new');
});

test('callback checks readiness again after successful IO and preserves the physical result',async()=>{
  const c=await fixture(),h=new QueueHarness(c.storage);let current=true;h.submit(c.root,'done',payload(),h.owner,()=>current);
  await h.tasks.shift()();assert.equal(await fs.readFile(path.join(c.directory,'SKILL.md'),'utf8'),SKILL);
  current=false;h.deliver();assert.deepEqual(h.results,[{id:'done',result:'installed',current:false,reason:'stale'}]);
});

test('real Service cancels while rename is already in flight, responds once and holds physical slot',async()=>{
  const c=await fixture();const service=new ManagedSkillService(c.root,()=>true);const owner=service.attachOwner();service.ready(1,TOKEN);
  const generation=service.generationFor(TOKEN);const entered=deferred(),release=deferred();let blocked=false;
  managedSkillIo.before=async item=>{if(item.operation==='rename'&&!blocked){blocked=true;entered.resolve();await release.promise;}};
  let oldCount=0;const oldDone=deferred();service.install(owner,wire(c.root,'old',new Map([['SKILL.md',SKILL]]),generation),reply=>{oldCount++;oldDone.resolve(plain(reply));});
  await entered.promise;service.cancel(owner,'old');assert.deepEqual(await oldDone.promise,{result:null,current:false,reason:'stale'});
  const before=managedSkillIo.calls.length;const nextDone=deferred();
  service.install(owner,wire(c.root,'next',payload('successor'),generation),reply=>nextDone.resolve(plain(reply)));
  await Promise.resolve();assert.equal(managedSkillIo.calls.length,before,'pending successor must not start physical IO');
  release.resolve();assert.equal((await nextDone.promise).current,true);assert.equal(oldCount,1);
  assert.equal(await fs.readFile(path.join(c.directory,'nested/data.txt'),'utf8'),'successor');await noTemps(c.directory);
});

test('Service stop retires matching grant before delayed ready; invalid/stale requests never start IO',async()=>{
  const c=await fixture(),service=new ManagedSkillService(c.root,()=>true);const owner=service.attachOwner();service.ready(1,TOKEN);
  const grant=service.generationFor(TOKEN);service.stop(1);service.ready(1,TOKEN);assert.equal(service.generationFor(TOKEN),null);
  let result;service.install(owner,wire(c.root,'stale',payload(),grant),reply=>{result=plain(reply);});
  assert.deepEqual(result,{result:null,current:false,reason:'stale'});assert.equal(managedSkillIo.calls.length,0);
  service.install(owner,null,reply=>{result=plain(reply);});assert.deepEqual(result,{result:null,current:false,reason:'invalid'});
});
