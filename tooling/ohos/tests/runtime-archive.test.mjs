import test, {after, afterEach} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
import {randomBytes} from 'node:crypto';
import {prepareArchiveModules, makeArchive, observation, resetObservation, activeInflaters,
  fileIo, nativeZlib, ArchiveResources} from './runtime-archive-fixture.mjs';

const root = process.env.OHOS_ARCHIVE_ROOT ?? path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const temporary = await fs.mkdtemp(path.join(process.env.OHOS_ARCHIVE_TEST_DIR ?? os.tmpdir(), 'archive-tests-'));
const modules = await prepareArchiveModules(root, path.join(temporary,'modules'));
const {OhosRuntimeStorage, RuntimeInstaller, runtimeCrc32} = modules;
const baseFiles = {
  'node_modules/@deepseek-ai/dsh/lib/bin.js': 'console.log("fixture bin");',
  'runtime/ohos/preload.mjs': 'export const preload = true;',
  'runtime/ohos/process/index.mjs': 'export const process = true;',
  'runtime/ohos/process/sandbox.mjs': 'export const sandbox = true;',
  'runtime/ohos/lifecycle/index.mjs': 'export const lifecycle = true;',
  'runtime/ohos/phone/index.mjs': 'export const phone = true;',
  'runtime/ohos/capabilities/index.mjs': 'export const capabilities = true;',
  'runtime/bridge/dsh-go-bridge/lib/index.js': 'export function apply() {}',
  'runtime/ohos/process/child-process.mjs': 'export const childProcess = true;',
  'runtime/ohos/.manifest.json': '{"dotfile":true}',
  'runtime/ohos/中文 空格/client.node.js': '导入 🐳 .node.js 是 JavaScript',
  'empty.txt': '',
};

async function scenario(name, files=baseFiles, version='v1', adjust) {
  const directory = path.join(temporary,name);
  await fs.mkdir(directory);
  const pack = await makeArchive(path.join(directory,'payload.hap'), files, version, adjust);
  const storage = new OhosRuntimeStorage(pack.resources,directory);
  const installer = new RuntimeInstaller(storage, directory+'/runtime');
  return {directory,...pack,storage,installer};
}
async function install(c, progress=()=>{}) {
  await c.storage.withBundledRuntime(async()=>{
    const manifest=await c.storage.readBundledManifest();
    await c.installer.install(manifest, progress);
  });
}
async function mutate(c, apply) {
  const bytes=Buffer.from(c.inner.bytes); apply(bytes,c.inner.rows);
  const handle=await fs.open(c.resources.name,'r+');
  try { await handle.write(bytes,0,bytes.length,c.resources.offset); } finally { await handle.close(); }
}
afterEach(()=>{ assert.equal(observation.fd.size,0,'all actual owned file descriptors closed'); assert.equal(activeInflaters(),0,'all actual libz states ended'); resetObservation(); });
after(async()=>{ await fs.rm(temporary,{recursive:true,force:true}); });

test('constructor is I/O-free; only the one stored raw archive is read; manifest stays schema 1',async()=>{
  const c=await scenario('constructor');
  assert.equal(observation.opens,0); assert.equal(observation.reads,0); assert.equal(observation.initialized,0);
  const manifest=await c.storage.readBundledManifest();
  assert.deepEqual(manifest,c.manifest); assert.equal(observation.opens,1); assert.equal(observation.closes,1);
  assert.deepEqual(c.resources.assets,['dsh-runtime/runtime.zip']); assert.equal(observation.initialized,0);
  await c.storage.readBundledManifest(); assert.equal(observation.opens,1,'cached immutable HAP metadata');
});

test('actual ZIP Deflate, raw FD offset, Chinese/dotfiles/empty/.node.js, file SHA and atomic completion',async()=>{
  const c=await scenario('install'); const progress=[];
  await install(c,e=>progress.push(e));
  assert.equal(observation.opens,1); assert.equal(observation.closes,1);
  assert.equal(observation.initialized,Object.keys(baseFiles).length);
  assert.deepEqual(progress.at(-1),{step:'configure',done:1,total:1});
  assert.equal((await c.installer.installed()).runtimeVersion,'v1');
  for(const [name,bytes] of Object.entries(baseFiles)) assert.deepEqual(await fs.readFile(c.installer.root+'/'+name),Buffer.from(bytes));
  assert.ok(c.resources.offset>0); assert.ok(observation.maxInput<=256*1024); assert.ok(observation.maxOutput<=256*1024);
});

test('real random input crossing compressed and output chunk boundaries is byte-identical',async()=>{
  const data=randomBytes(1024*1024+19); const c=await scenario('chunked',{...baseFiles,'large.bin':data});
  await install(c); assert.deepEqual(await fs.readFile(c.installer.root+'/large.bin'),data);
  assert.ok(observation.inflates>Object.keys(baseFiles).length+4); assert.equal(observation.maxInput,256*1024);
  assert.equal(observation.maxOutput,256*1024);
});

test('small members and the output-cap boundary finish with exact bytes and CRC',async()=>{
  const sizes=[1,3,4,256*1024-2,256*1024-1,256*1024,256*1024+1];
  const files={...baseFiles};
  for(const size of sizes) files['boundary-'+size+'.txt']=Buffer.alloc(size,0x61);
  const c=await scenario('output-boundary',files); await install(c);
  for(const [name,bytes] of Object.entries(files)) assert.deepEqual(await fs.readFile(c.installer.root+'/'+name),Buffer.from(bytes));
  assert.equal((await c.installer.installed()).runtimeVersion,'v1');
  assert.equal(observation.maxOutput,256*1024);
});

test('reinstall skips every inflate and every payload rewrite; changed-only upgrade retains old inode',async()=>{
  const c=await scenario('upgrade'); await install(c);
  const before=await fs.stat(c.installer.root+'/runtime/ohos/preload.mjs');
  resetObservation(); await install(c); assert.equal(observation.initialized,0);
  assert.equal((await fs.stat(c.installer.root+'/runtime/ohos/preload.mjs')).ino,before.ino);
  const nextFiles={...baseFiles,'new.txt':'new'}; delete nextFiles['empty.txt'];
  const next=await makeArchive(path.join(c.directory,'next.hap'),nextFiles,'v2');
  const storage=new OhosRuntimeStorage(next.resources,c.directory);
  const installer=new RuntimeInstaller(storage,c.directory+'/runtime');
  resetObservation(); await install({...c,...next,storage,installer});
  assert.equal(observation.initialized,1); assert.equal((await installer.installed()).runtimeVersion,'v2');
  assert.equal((await fs.stat(installer.root+'/runtime/ohos/preload.mjs')).ino,before.ino);
  await assert.rejects(fs.access(installer.root+'/empty.txt'));
});

test('interruption after an actual file rename leaves journal; retry skips committed file and completes',async()=>{
  const c=await scenario('interrupted'); let committed;
  await assert.rejects(install(c,e=>{ if(e.step==='extract'&&e.done>0){committed=e.done;throw new Error('injected interruption');} }),/injected interruption/);
  assert.ok(committed>0); assert.equal(await c.installer.installed(),null);
  await fs.access(c.directory+'/runtime/installing.json');
  const oldInflates=observation.initialized; resetObservation(); await install(c);
  assert.ok(observation.initialized<Object.keys(baseFiles).length); assert.equal(oldInflates+observation.initialized,Object.keys(baseFiles).length);
  assert.equal((await c.installer.installed()).runtimeVersion,'v1');
  assert.deepEqual(await fs.readdir(c.directory+'/runtime/staging'),[]);
});

test('new HAP after interrupted install removes only journal-owned stale files and keeps foreign contents',async()=>{
  const old={...baseFiles,'000-old/path.txt':'old'};const c=await scenario('new-after-kill',old,'uncommitted');
  await assert.rejects(install(c,e=>{if(e.step==='extract'&&e.done>0)throw new Error('interrupt');}),/interrupt/);
  await fs.writeFile(c.installer.root+'/foreign.txt','user data');
  const next=await makeArchive(path.join(c.directory,'next.hap'),baseFiles,'v2');
  const storage=new OhosRuntimeStorage(next.resources,c.directory);const installer=new RuntimeInstaller(storage,c.directory+'/runtime');
  await install({...c,...next,storage,installer});
  await assert.rejects(fs.access(installer.root+'/000-old/path.txt'));
  assert.equal(await fs.readFile(installer.root+'/foreign.txt','utf8'),'user data');
  assert.equal((await installer.installed()).runtimeVersion,'v2');
});

test('SHA mismatch cannot publish the member or installed marker even when ZIP CRC is valid',async()=>{
  const c=await scenario('sha',baseFiles,'bad',m=>{m.files.find(f=>f.path==='empty.txt').sha256='0'.repeat(64);});
  await assert.rejects(install(c),{code:'ohos_checksum_failed'});
  assert.equal(await c.installer.installed(),null); await fs.access(c.directory+'/runtime/installing.json');
  await assert.rejects(fs.access(c.installer.root+'/empty.txt'));
});

test('ELF bytes are rejected in a harmless extension; .node.js remains allowed',async()=>{
  const c=await scenario('elf',{...baseFiles,'native-disguised.js':Buffer.from([127,69,76,70,0,0,0,0])});
  await assert.rejects(install(c),{code:'ohos_native_payload'});
  assert.equal(await c.installer.installed(),null); await assert.rejects(fs.access(c.installer.root+'/native-disguised.js'));
});

for(const suffix of ['library.node','library.so','library.so.1','library.SO.1.2']){
  test(`terminal native suffix is rejected before installation: ${suffix}`,async()=>{
    const c=await scenario('suffix-'+suffix,{...baseFiles,[suffix]:'not ELF'});
    await assert.rejects(install(c),{code:'ohos_archive_invalid'}); await assert.rejects(fs.access(c.directory+'/runtime'));
  });
}

test('short native reads and writes preserve buffer offsets and complete exact bytes',async()=>{
  const c=await scenario('short',{...baseFiles,'data.txt':'逐字节\n'.repeat(50)});
  observation.maxReadChunk=7; observation.maxWriteChunk=3;
  await install(c); assert.equal(await fs.readFile(c.installer.root+'/data.txt','utf8'),'逐字节\n'.repeat(50));
});

test('retired raw close rejection is retried by a different storage instance before opening another descriptor',async()=>{
  const c=await scenario('close-retry');c.resources.failClose=1;
  await assert.rejects(c.storage.readBundledManifest(),/injected raw close/);
  assert.equal(observation.fd.size,1);
  const d=await scenario('close-next');await d.storage.readBundledManifest();
  assert.equal(c.resources.opened,null); assert.equal(d.resources.opened,null);
});

test('retired inflateEnd rejection is retried by a new session, keeping actual libz memory owned',async()=>{
  const c=await scenario('end-retry');observation.failEnd=1;
  await assert.rejects(install(c),/injected inflateEnd/);assert.equal(activeInflaters(),1);
  const d=await scenario('end-next');await install(d); assert.equal(activeInflaters(),0);
});

test('another diagnostics reader cannot close the active install raw descriptor',async()=>{
  const c=await scenario('serialization');const other=new OhosRuntimeStorage(c.resources,c.directory);
  let release,entered;const gate=new Promise(resolve=>release=resolve);const ready=new Promise(resolve=>entered=resolve);
  let held=false;observation.beforeWrite=async()=>{if(!held){held=true;entered();await gate;}};
  const active=install(c);await ready;
  let queried=false;const reading=other.readBundledManifest().then(()=>{queried=true;});
  await Promise.resolve();await Promise.resolve();assert.equal(queried,false);assert.equal(observation.opens,1);
  release();await active;await reading;assert.equal(observation.opens,2);assert.equal(observation.closes,2);
});

test('registered parent symlink remains rejected and outside data remains untouched',async()=>{
  const c=await scenario('link');await fs.mkdir(c.directory+'/runtime/tree',{recursive:true});
  const outside=path.join(temporary,'outside');await fs.mkdir(outside);await fs.writeFile(outside+'/keep','outside');
  await fs.symlink(outside,c.directory+'/runtime/tree/runtime');
  await assert.rejects(install(c),{code:'ohos_path_link'});assert.equal(await fs.readFile(outside+'/keep','utf8'),'outside');
});

const malformed = [
  ['encrypted', (b,r)=>b.writeUInt16LE(1,r[0].centralOffset+8)],
  ['data-descriptor', (b,r)=>b.writeUInt16LE(8,r[1].centralOffset+8)],
  ['zip64-entry', (b,r)=>b.writeUInt32LE(0xffffffff,r[1].centralOffset+20)],
  ['multi-disk', b=>b.writeUInt16LE(1,b.length-22+4)],
  ['archive-comment', b=>b.writeUInt16LE(1,b.length-2)],
  ['central-extra', (b,r)=>b.writeUInt16LE(1,r[1].centralOffset+30)],
  ['central-comment', (b,r)=>b.writeUInt16LE(1,r[1].centralOffset+32)],
  ['symlink-entry', (b,r)=>b.writeUInt32LE((0o120777<<16)>>>0,r[1].centralOffset+38)],
  ['local-name-mismatch', (b,r)=>b[r[1].localOffset+30]^=1],
  ['local-size-mismatch', (b,r)=>b.writeUInt32LE(1,r[1].localOffset+22)],
  ['local-version-mismatch', (b,r)=>b.writeUInt16LE(10,r[1].localOffset+4)],
  ['local-extra', (b,r)=>b.writeUInt16LE(1,r[1].localOffset+28)],
  ['overlap-offset', (b,r)=>b.writeUInt32LE(r[0].localOffset,r[1].centralOffset+42)],
  ['central-offset-outside', b=>b.writeUInt32LE(b.length+100,b.length-6)],
  ['central-count', b=>{b.writeUInt16LE(2,b.length-14);b.writeUInt16LE(2,b.length-12);}],
  ['manifest-crc', (b,r)=>{b.writeUInt32LE(0,r[0].centralOffset+16);b.writeUInt32LE(0,r[0].localOffset+14);}],
  ['manifest-not-stored', (b,r)=>{b.writeUInt16LE(8,r[0].centralOffset+10);b.writeUInt16LE(8,r[0].localOffset+8);}],
];
for(const [name,change] of malformed){
  test(`archive rejects ${name} before creating installation directories`,async()=>{
    const c=await scenario('bad-'+name);await mutate(c,change);
    await assert.rejects(install(c),{code:'ohos_archive_invalid'});await assert.rejects(fs.access(c.directory+'/runtime'));
  });
}

test('corrupt actual Deflate bytes fail without installed marker; decompressor is ended',async()=>{
  const c=await scenario('bad-deflate');await mutate(c,(b,r)=>{const f=r.find(x=>x.name.endsWith('bin.js'));b[f.dataOffset]=0xff;});
  await assert.rejects(install(c));assert.equal(await c.installer.installed(),null);
});

for(const declaredSize of [0,1]) test('decompression beyond declared size '+declaredSize+' is stopped before any output is written',async()=>{
  const c=await scenario('expanded-bomb-'+declaredSize,{...baseFiles,'000-bomb.txt':'x'.repeat(1024*1024)},'v1',m=>{m.files[0].size=declaredSize;});
  await mutate(c,(b,r)=>{const row=r.find(x=>x.name==='files/000-bomb.txt');b.writeUInt32LE(declaredSize,row.centralOffset+24);b.writeUInt32LE(declaredSize,row.localOffset+22);});
  await assert.rejects(install(c),{code:'ohos_size_mismatch'});assert.equal(await c.installer.installed(),null);
  const temps=await fs.readdir(c.directory+'/runtime/staging');assert.equal(temps.length,1);
  assert.equal((await fs.stat(c.directory+'/runtime/staging/'+temps[0])).size,0);
});

test('CRC streaming uses the native standard polynomial and supports empty/chunked input',()=>{
  assert.equal(runtimeCrc32(new Uint8Array(Buffer.from('123456789'))),0xcbf43926);
  let crc=0;for(const text of ['123','456','789'])crc=runtimeCrc32(new Uint8Array(Buffer.from(text)),crc);
  assert.equal(crc,0xcbf43926);assert.equal(runtimeCrc32(new Uint8Array(0)),0);
});

test('a staging close rejection retains explicit ownership and a new storage instance retries it',async()=>{
  const c=await scenario('output-close-recovery');
  const originalOpen=fileIo.open,originalClose=fileIo.close;
  let failed=null;
  fileIo.open=async(name,flags)=>{const file=await originalOpen(name,flags);file.testPath=name;return file;};
  fileIo.close=async(file)=>{
    if(failed===null&&file.testPath.includes('/staging/')){failed=file;throw new Error('injected staging close');}
    return originalClose(file);
  };
  try{
    await assert.rejects(install(c),/injected staging close/);
    assert.equal(await c.installer.installed(),null);
    const storage=new OhosRuntimeStorage(c.resources,c.directory);const installer=new RuntimeInstaller(storage,c.directory+'/runtime');
    await install({...c,storage,installer});
    assert.equal(observation.fd.size,0,'the failed copy descriptor must be explicitly recovered by the next owner');
  }finally{
    fileIo.open=originalOpen;fileIo.close=originalClose;
    // Keep the failing preimage executable without polluting later tests.
    // The assertion above is evaluated before this test-only final cleanup.
    if(failed!==null&&observation.fd.has(failed.fd))await originalClose(failed);
  }
});


for (const kind of ['metadata', 'payload']) {
  test(`actual installer ${kind} staging hardlink preserves the other inode name`, async () => {
    const c = await scenario('hardlink-' + kind);
    const member = c.manifest.files.find(file => file.path === 'runtime/ohos/preload.mjs');
    const staging = kind === 'metadata' ? c.installer.base + '/installing.json.tmp'
      : c.installer.base + '/staging/' + member.sha256 + '.tmp';
    const victim = path.join(c.directory, 'outside-runtime-sentinel');
    await fs.mkdir(path.dirname(staging), { recursive:true });
    await fs.writeFile(victim, 'unchanged user bytes'); await fs.link(victim, staging);
    assert.equal((await fs.stat(staging)).ino, (await fs.stat(victim)).ino);
    await install(c);
    assert.equal((await c.installer.installed()).runtimeVersion, 'v1');
    for (const [name, bytes] of Object.entries(baseFiles))
      assert.deepEqual(await fs.readFile(c.installer.root + '/' + name), Buffer.from(bytes));
    assert.equal(await fs.readFile(victim, 'utf8'), 'unchanged user bytes');
    assert.equal((await fs.stat(victim)).size, Buffer.byteLength('unchanged user bytes'));
  });
}


async function hardlinkStage(name, kind) {
  const c = await scenario(name);
  const member = c.manifest.files.find(file => file.path === 'runtime/ohos/preload.mjs');
  c.staging = kind === 'metadata' ? c.installer.base + '/installing.json.tmp'
    : c.installer.base + '/staging/' + member.sha256 + '.tmp';
  c.target = kind === 'metadata' ? c.installer.base + '/installing.json'
    : c.installer.root + '/runtime/ohos/preload.mjs';
  c.previous = kind === 'metadata' ? JSON.stringify({schema:1, ownedPaths:[], stagingHashes:[]}) : 'old target';
  c.victim = path.join(c.directory, 'victim');
  await fs.mkdir(path.dirname(c.staging), {recursive:true});
  await fs.mkdir(path.dirname(c.target), {recursive:true});
  await fs.writeFile(c.victim, 'outside data'); await fs.link(c.victim, c.staging);
  await fs.writeFile(c.target, c.previous);
  return c;
}

for (const kind of ['metadata', 'payload']) {
  for (const errorCode of [13900005, 13900018]) {
    test(`${kind} staging unlink error ${errorCode} preserves both files and permits explicit retry`, async () => {
      const c = await hardlinkStage(`unlink-${kind}-${errorCode}`, kind), originalUnlink = fileIo.unlink;
      fileIo.unlink = async name => {
        if (name === c.staging) throw Object.assign(new Error('injected unlink failure'), {code:errorCode});
        return originalUnlink(name);
      };
      try { await assert.rejects(install(c), {code:errorCode}); }
      finally { fileIo.unlink = originalUnlink; }
      assert.equal(await fs.readFile(c.victim, 'utf8'), 'outside data');
      assert.equal(await fs.readFile(c.staging, 'utf8'), 'outside data');
      assert.equal(await fs.readFile(c.target, 'utf8'), c.previous);
      await install(c); assert.equal((await c.installer.installed()).runtimeVersion, 'v1');
      assert.equal(await fs.readFile(c.victim, 'utf8'), 'outside data');
    });
  }
  for (const entryKind of ['directory', 'symlink', 'danglingSymlink']) {
    test(`${kind} staging ${entryKind} is rejected without touching its contents or target`, async () => {
      const c = await hardlinkStage(`wrong-type-${kind}-${entryKind}`, kind);
      await fs.unlink(c.staging);
      if (entryKind === 'directory') {
        await fs.mkdir(c.staging); await fs.writeFile(path.join(c.staging, 'keep'), 'child');
      } else await fs.symlink(entryKind === 'danglingSymlink' ? c.victim + '.missing' : c.victim, c.staging);
      if (entryKind === 'danglingSymlink') await assert.rejects(install(c));
      else await assert.rejects(install(c), {code:'ohos_path_link'});
      assert.equal(await fs.readFile(c.victim, 'utf8'), 'outside data');
      assert.equal(await fs.readFile(c.target, 'utf8'), c.previous);
      if (entryKind === 'directory') assert.equal(await fs.readFile(path.join(c.staging, 'keep'), 'utf8'), 'child');
      else assert((await fs.lstat(c.staging)).isSymbolicLink());
    });
  }
  if (kind === 'payload') {
    test('payload staging directory batch commit failure blocks installed publication and retry succeeds', async () => {
      const c = await hardlinkStage('batch-directory-fsync', kind);
      const originalOpen = fileIo.open, originalClose = fileIo.close, originalSync = fileIo.fsync;
      const directories = new Set();
      let failed = false;
      fileIo.open = async (name, flags) => {
        const file = await originalOpen(name, flags);
        if (name === path.dirname(c.staging) && (flags & fileIo.OpenMode.DIR) !== 0) directories.add(file.fd);
        return file;
      };
      fileIo.close = async file => { await originalClose(file); directories.delete(file.fd); };
      fileIo.fsync = async fd => {
        if (directories.has(fd) && !failed) { failed = true; throw new Error('injected staging directory commit failure'); }
        return originalSync(fd);
      };
      try { await assert.rejects(install(c), /staging directory commit failure/); }
      finally { fileIo.open = originalOpen; fileIo.close = originalClose; fileIo.fsync = originalSync; }
      assert.equal(failed, true);
      await assert.rejects(fs.access(c.staging), {code:'ENOENT'});
      assert.equal(await fs.readFile(c.victim, 'utf8'), 'outside data');
      assert.deepEqual(await fs.readFile(c.target), Buffer.from(baseFiles['runtime/ohos/preload.mjs']));
      assert.equal(await c.installer.installed(), null);
      await fs.access(c.installer.base + '/installing.json');
      await assert.rejects(fs.access(c.installer.base + '/installed.json'), {code:'ENOENT'});
      await install(c);
      assert.equal((await c.installer.installed()).runtimeVersion, 'v1');
      for (const [name, bytes] of Object.entries(baseFiles))
        assert.deepEqual(await fs.readFile(c.installer.root + '/' + name), Buffer.from(bytes));
      assert.equal(await fs.readFile(c.victim, 'utf8'), 'outside data');
    });
    test('payload data fsync failure preserves the old target and outside hardlink bytes', async () => {
      const c = await hardlinkStage('payload-data-fsync', kind);
      const originalOpen = fileIo.open, originalClose = fileIo.close, originalSync = fileIo.fsync;
      const payloads = new Set();
      let failed = false;
      fileIo.open = async (name, flags) => {
        const file = await originalOpen(name, flags);
        if (name === c.staging && (flags & fileIo.OpenMode.DIR) === 0) payloads.add(file.fd);
        return file;
      };
      fileIo.close = async file => { await originalClose(file); payloads.delete(file.fd); };
      fileIo.fsync = async fd => {
        if (payloads.has(fd) && !failed) { failed = true; throw new Error('injected payload data fsync failure'); }
        return originalSync(fd);
      };
      try { await assert.rejects(install(c), /payload data fsync failure/); }
      finally { fileIo.open = originalOpen; fileIo.close = originalClose; fileIo.fsync = originalSync; }
      assert.equal(failed, true);
      assert.equal(await fs.readFile(c.target, 'utf8'), c.previous);
      assert.equal(await fs.readFile(c.victim, 'utf8'), 'outside data');
      assert.deepEqual(await fs.readFile(c.staging), Buffer.from(baseFiles['runtime/ohos/preload.mjs']));
      assert.notEqual((await fs.stat(c.staging)).ino, (await fs.stat(c.victim)).ino);
      assert.equal(await c.installer.installed(), null);
      await fs.access(c.installer.base + '/installing.json');
      await install(c);
      assert.equal((await c.installer.installed()).runtimeVersion, 'v1');
      assert.equal(await fs.readFile(c.victim, 'utf8'), 'outside data');
    });
    continue;
  }
  test(`${kind} staging unlink fsync failure stops before replacement and retry succeeds`, async () => {
    const c = await hardlinkStage('unlink-fsync-' + kind, kind);
    const originalUnlink = fileIo.unlink, originalSync = fileIo.fsync;
    let removed = false, failed = false;
    fileIo.unlink = async name => { await originalUnlink(name); if (name === c.staging) removed = true; };
    fileIo.fsync = async fd => {
      if (removed && !failed) { failed = true; throw new Error('injected unlink parent fsync failure'); }
      return originalSync(fd);
    };
    try { await assert.rejects(install(c), /unlink parent fsync failure/); }
    finally { fileIo.unlink = originalUnlink; fileIo.fsync = originalSync; }
    assert.equal(failed, true);
    await assert.rejects(fs.access(c.staging), {code:'ENOENT'});
    assert.equal(await fs.readFile(c.victim, 'utf8'), 'outside data');
    assert.equal(await fs.readFile(c.target, 'utf8'), c.previous);
    await install(c); assert.equal((await c.installer.installed()).runtimeVersion, 'v1');
    assert.equal(await fs.readFile(c.victim, 'utf8'), 'outside data');
  });
}

// This is the failure contract of the new native CRC boundary, not evidence
// that the former synchronous CRC accepted corrupt bytes.
test('native CRC failure refuses completion and an explicit retry preserves all payload bytes', async () => {
  const c = await scenario('native-crc-failure');
  observation.failCrc = 1;
  await assert.rejects(install(c), /injected native CRC failure/);
  assert.equal(await c.installer.installed(), null);
  await fs.access(c.directory + '/runtime/installing.json');
  assert.equal(observation.fd.size, 0); assert.equal(activeInflaters(), 0);
  await install(c);
  assert.equal((await c.installer.installed()).runtimeVersion, 'v1');
  for (const [name, bytes] of Object.entries(baseFiles))
    assert.deepEqual(await fs.readFile(c.installer.root + '/' + name), Buffer.from(bytes));
});

test('native CRC uses unsigned incremental standard vectors and empty input', async () => {
  const checksum = await nativeZlib.createChecksum();
  const buffer = text => Uint8Array.from(Buffer.from(text)).buffer;
  assert.equal(await checksum.crc32(0, buffer('123456789')), 0xcbf43926);
  let crc = 0;
  for (const text of ['123', '456', '789']) crc = await checksum.crc32(crc, buffer(text));
  assert.equal(crc, 0xcbf43926);
  assert.equal(await checksum.crc32(0, new ArrayBuffer(0)), 0);
});

test('asynchronous native CRC checks only valid output bytes and retains them until write', async () => {
  const data = randomBytes(256 * 1024 + 29);
  const files = {...baseFiles, 'chunked.bin': data, 'full-output.bin': Buffer.alloc(2 * 256 * 1024, 0x61),
    'short.txt': '123456789'};
  const c = await scenario('native-crc-valid-count', files);
  observation.beforeCrc = async (_previous, buffer) => {
    const before = Buffer.from(buffer).toString('base64');
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(Buffer.from(buffer).toString('base64'), before);
  };
  await install(c);
  assert.equal(observation.checksumCreates, 1);
  assert.equal(observation.crcBytes, Object.values(files).reduce((n, bytes) => n + Buffer.byteLength(bytes), 0));
  assert.ok(observation.crcCalls > Object.keys(files).length - 1);
  assert.equal(observation.maxCrcBuffer, 256 * 1024);
  for (const [name, bytes] of Object.entries(files))
    assert.deepEqual(await fs.readFile(c.installer.root + '/' + name), Buffer.from(bytes));
});

test('incorrect payload CRC still refuses completion when manifest SHA and length match', async () => {
  const c = await scenario('native-crc-corrupt');
  await mutate(c, (bytes, rows) => {
    const member = rows.find(row => row.name.endsWith('/bin.js'));
    const wrong = (bytes.readUInt32LE(member.localOffset + 14) ^ 1) >>> 0;
    bytes.writeUInt32LE(wrong, member.localOffset + 14);
    bytes.writeUInt32LE(wrong, member.centralOffset + 16);
  });
  await assert.rejects(install(c), {code: 'ohos_checksum_failed'});
  assert.equal(await c.installer.installed(), null);
  await fs.access(c.directory + '/runtime/installing.json');
});
