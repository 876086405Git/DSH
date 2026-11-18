import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {join} from 'node:path';
import {fixture,modules,pkg,put} from './last-known-good-fixture.mjs';
const plain=value=>JSON.parse(JSON.stringify(value));

test('captured boot image is pinned, never later unread configuration; restore retains other package keys',async t=>{
 const c=await fixture(t);const boot=await c.lkg.captureBoot();
 await put(join(c.home,'package.json'),pkg(['broken']));await put(join(c.home,'cordis.patch.yml'),'later: bad\n');
 await c.lkg.pinBooted(boot,120000);const preview=await c.lkg.preview();assert.equal(preview.get('available'),true);assert.deepEqual(plain(preview.get('disable')),['broken']);
 await c.lkg.restore();const actual=JSON.parse(await fs.readFile(join(c.home,'package.json'),'utf8'));assert.deepEqual(actual.dsh.profile.bundles,['builtin']);assert.equal(actual.other.untouched,123);assert.equal(actual.dsh.other,'retained');assert.equal(await fs.readFile(join(c.home,'cordis.patch.yml'),'utf8'),'old: true\n');assert.equal(c.lkg.blocked(),false);
});
test('a restore writes the plugin list and settings layer and nothing else: keys and newer fields stay',async t=>{
 const c=await fixture(t);await c.lkg.pinBooted(await c.lkg.captureBoot(),120000);
 const dsh=join(c.home,'../..');const kept={[join(dsh,'.env')]:'DEEPSEEK_API_KEY=keep\n',[join(dsh,'credentials.yml')]:'token: keep\n',[join(dsh,'cordis.patch.yml')]:'global: keep\n',
  [join(c.home,'node_modules/added/package.json')]:JSON.stringify({version:'2'}),[join(c.root,'dsh-secrets/vault.bin')]:'app key'};
 for(const [file,text] of Object.entries(kept))await put(file,text);
 const newer=JSON.parse(pkg(['builtin','added'],{added:'2'}));newer.addedSince={keep:true};newer.dsh.addedSince='keep';
 await put(join(c.home,'package.json'),JSON.stringify(newer));await put(join(c.home,'cordis.patch.yml'),'later: bad\n');
 await c.lkg.restore();
 for(const [file,text] of Object.entries(kept))assert.equal(await fs.readFile(file,'utf8'),text,file);
 const actual=JSON.parse(await fs.readFile(join(c.home,'package.json'),'utf8'));
 assert.deepEqual(actual.dsh.profile.bundles,['builtin']);assert.deepEqual(actual.addedSince,{keep:true});assert.equal(actual.dsh.addedSince,'keep');assert.deepEqual(actual.dependencies,{added:'2'});
 assert.equal(await fs.readFile(join(c.home,'cordis.patch.yml'),'utf8'),'old: true\n');
 const before=JSON.parse(await c.storage.readRecord('lkg-restore-backup.json')).before;assert.equal(before.patchText,'later: bad\n','what it replaced stays readable');
});
test('missing startup profile does not create a last-good record',async t=>{
 const c=await fixture(t);await fs.unlink(join(c.home,'package.json'));const boot=await c.lkg.captureBoot();assert.equal(boot,null);await c.lkg.pinBooted(boot,120000);assert.equal((await c.lkg.preview()).get('available'),false);
});
test('native/payload/HAP identity change refuses restore; a sideloaded HAP with no module hash still pins',async t=>{
 const c=await fixture(t);await c.lkg.pinBooted(await c.lkg.captureBoot(),120000);
 for(const [file,bytes] of [['dsh-runtime/installed.json','new-manifest'],['hap/libs/arm64/libnode.so','new-node']]){
  const path=join(c.root,file),old=await fs.readFile(path);await fs.writeFile(path,bytes);const other=new c.Core(new c.Storage(c.context));assert.equal((await other.preview()).get('available'),false);await assert.rejects(other.restore());await fs.writeFile(path,old);
 }
 for(const hash of ['changed-hap','']){const {Core,Storage}=await modules(async()=>{},hash);const other=new Core(new Storage(c.context));assert.equal((await other.preview()).get('available'),false);
  if(hash==='')assert.notEqual(await other.captureBoot(),null,'no module hash is what a sideload has, not a reason to refuse');}
});
test('uninstalled, upgraded, unknown and shadowing dependencies are not enabled',async t=>{
 const c=await fixture(t);await put(join(c.home,'package.json'),pkg(['builtin','same','changed','gone','unknown'],{same:'1',changed:'1',gone:'1',unknown:'1'}));
 for(const name of ['same','changed','gone'])await put(join(c.home,'node_modules',name,'package.json'),JSON.stringify({version:'1'}));
 await c.lkg.pinBooted(await c.lkg.captureBoot(),120000);
 await put(join(c.home,'package.json'),pkg(['builtin','changed'],{builtin:'3',same:'1',changed:'2',unknown:'1'}));await put(join(c.home,'node_modules/changed/package.json'),JSON.stringify({version:'2'}));
 await c.lkg.restore();assert.deepEqual(JSON.parse(await fs.readFile(join(c.home,'package.json'),'utf8')).dsh.profile.bundles,['same']);
});
test('unknown locks and all exact takeover-prefix claims are preserved and block writes',async t=>{
 const c=await fixture(t);await c.lkg.pinBooted(await c.lkg.captureBoot(),120000);const before=await fs.readFile(join(c.home,'package.json'));
 for(const name of ['package.json.lock','cordis.patch.yml.lock','package.json.lock.takeover-deadbeef','cordis.patch.yml.lock.takeover-unknown']){
  await put(join(c.home,name),'unknown writer');await assert.rejects(c.lkg.restore(),{code:'ohos_lkg_locked'});assert.deepEqual(await fs.readFile(join(c.home,'package.json')),before);assert.equal(await fs.readFile(join(c.home,name),'utf8'),'unknown writer');await fs.unlink(join(c.home,name));
 }
});
test('failure after first target rename keeps intent; reopen completes exact second target',async t=>{
 let fail=false,hit=false;const c=await fixture(t,async(op,args)=>{if(fail&&!hit&&op==='after:rename'&&args[1]===join(c.home,'package.json')){hit=true;throw new Error('after first rename');}});
 await c.lkg.pinBooted(await c.lkg.captureBoot(),120000);await put(join(c.home,'package.json'),pkg(['broken']));await put(join(c.home,'cordis.patch.yml'),'broken: true');fail=true;
 await assert.rejects(c.lkg.restore(),/after first rename/);assert(hit);assert(c.lkg.blocked());assert.notEqual(await c.storage.readRecord('lkg-restore.json'),null);
 const next=new c.Core(new c.Storage(c.context));await next.recoverPending();assert.equal(await fs.readFile(join(c.home,'cordis.patch.yml'),'utf8'),'old: true\n');assert.equal(await c.storage.readRecord('lkg-restore.json'),null);
});
test('interrupted restore refuses unrelated external edits and keeps backup',async t=>{
 let fail=false;const c=await fixture(t,async(op,args)=>{if(fail&&op==='before:rename'&&args[1]===join(c.home,'package.json'))throw new Error('interrupt');});await c.lkg.pinBooted(await c.lkg.captureBoot(),120000);await put(join(c.home,'package.json'),pkg(['broken']));fail=true;await assert.rejects(c.lkg.restore());fail=false;
 await put(join(c.home,'cordis.patch.yml'),'external: keep');const next=new c.Core(new c.Storage(c.context));await assert.rejects(next.recoverPending(),{code:'ohos_lkg_conflict'});assert.equal(await fs.readFile(join(c.home,'cordis.patch.yml'),'utf8'),'external: keep');assert.notEqual(await c.storage.readRecord('lkg-restore-backup.json'),null);
});
test('delete-patch recovery re-establishes directory durability after uncertain unlink',async t=>{
 let fail=false,hit=false;const c=await fixture(t,async(op,args)=>{if(fail&&!hit&&op==='after:unlink'&&args[0]===join(c.home,'cordis.patch.yml')){hit=true;throw new Error('uncertain unlink');}});await fs.unlink(join(c.home,'cordis.patch.yml'));await c.lkg.pinBooted(await c.lkg.captureBoot(),120000);await put(join(c.home,'cordis.patch.yml'),'bad');fail=true;await assert.rejects(c.lkg.restore());assert(hit);
 const next=new c.Core(new c.Storage(c.context));await next.recoverPending();await assert.rejects(fs.stat(join(c.home,'cordis.patch.yml')),{code:'ENOENT'});assert.equal(await c.storage.readRecord('lkg-restore.json'),null);
});
test('symlink parents/leaf and malformed records fail without touching outside bytes',async t=>{
 const c=await fixture(t);const out=join(c.root,'outside');await put(out,'untouched');await fs.unlink(join(c.home,'cordis.patch.yml'));await fs.symlink(out,join(c.home,'cordis.patch.yml'));await assert.rejects(c.lkg.captureBoot());assert.equal(await fs.readFile(out,'utf8'),'untouched');await fs.unlink(join(c.home,'cordis.patch.yml'));
 await c.storage.writeRecord('lkg.json','{"schema":99}');await assert.rejects(c.lkg.preview());
 await fs.rename(c.home,c.home+'-old');await fs.symlink(c.home+'-old',c.home);await assert.rejects(c.storage.profile());
});
