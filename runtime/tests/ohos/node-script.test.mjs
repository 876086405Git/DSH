import { symlinkFixture } from './host-link-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import * as promises from 'node:fs/promises';
import childProcess from 'node:child_process';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Worker } from 'node:worker_threads';
import { createNodeScriptWorker, nodeScriptAvailable } from '../../ohos/process/node-script.mjs';
import { assertNodeFsInventory, fsPathTable, promisesPathTable } from '../../ohos/process/node-path-table.mjs';

const nodeVersion = '24.22.1';
assert.equal(process.versions.node, nodeVersion);
const plainCwd = process.cwd, plainRead = fs.readFileSync, plainSpawn = childProcess.spawn;
const plainChildSpawn = childProcess.ChildProcess.prototype.spawn;

async function fixture(t) {
  const root = await promises.mkdtemp(join(tmpdir(), 'ohos-node-worker-'));
  const workspace = join(root, '工作区'), temporary = join(root, '临时区');
  await promises.mkdir(workspace); await promises.mkdir(temporary);
  const active = new Set(), parentFds = new Set();
  t.after(async () => {
    await Promise.all([...active].map(worker => worker.terminate()));
    for (const fd of parentFds) fs.closeSync(fd);
    await promises.rm(root, { recursive: true, force: true });
    assert.equal(process.cwd, plainCwd); assert.equal(fs.readFileSync, plainRead);
    assert.equal(childProcess.spawn, plainSpawn); assert.equal(childProcess.ChildProcess.prototype.spawn, plainChildSpawn);
  });
  let sequence = 0;
  const launch = async (source, options = {}) => {
    const entry = join(workspace, `script-${sequence++}.${options.extension ?? 'mjs'}`);
    await promises.writeFile(entry, source);
    const worker = createNodeScriptWorker({ args: [entry, ...(options.args ?? [])], cwd: options.cwd ?? workspace,
      roots: [workspace, temporary], workspaceRoots: [workspace], readOnly: options.readOnly,
      env: { CHECK_ENV: '隔离值', ...(options.env ?? {}) }, stdin: options.stdin ?? '' });
    active.add(worker);
    const stdout = [], stderr = [], errors = [], messages = [];
    let firstOutput, timedOut = false;
    worker.stdout.on('data', bytes => { firstOutput ??= performance.now(); stdout.push(bytes); });
    worker.stderr.on('data', bytes => stderr.push(bytes));
    worker.on('error', error => errors.push({ code: error.code, message: error.message, stack: error.stack }));
    worker.on('message', message => { messages.push(message); options.onMessage?.(message, worker); });
    const timeout = setTimeout(() => { timedOut = true; void worker.terminate(); }, 15000);
    const done = new Promise(resolve => worker.once('exit', exitCode => {
      clearTimeout(timeout); active.delete(worker);
      resolve({ exitCode, stdout: Buffer.concat(stdout).toString(), stderr: Buffer.concat(stderr).toString(), errors,
        messages, firstOutput, exitAt: performance.now(), timedOut });
    }));
    return { worker, done };
  };
  return { root, workspace, temporary, launch, parentFds };
}
function successful(result) {
  assert.equal(result.timedOut, false, JSON.stringify(result));
  assert.equal(result.exitCode, 0, JSON.stringify(result));
  assert.deepEqual(result.errors, [], JSON.stringify(result));
  return JSON.parse(result.stdout.trim());
}

test('fixed Node fs inventory fails closed for an added export or a missing classified path entry', () => {
  assert.equal(nodeScriptAvailable(), true);
  assertNodeFsInventory(fs, fs.promises);
  const changed = Object.create(null, Object.getOwnPropertyDescriptors(fs));
  changed.unclassifiedPathFunction = () => {};
  assert.throws(() => assertNodeFsInventory(changed, fs.promises), { code: 'ERR_OHOS_NODE_FS_SURFACE_CHANGED' });
  delete changed.unclassifiedPathFunction; delete changed.readFile;
  assert.throws(() => assertNodeFsInventory(changed, fs.promises), { code: 'ERR_OHOS_NODE_FS_SURFACE_CHANGED' });
});

test('every fixed path-table entry executes against real files at the private cwd, including nested entry points', async t => {
  const f = await fixture(t);
  const requests = [...Object.entries(fsPathTable).map(([name, value]) => ({ kind: 'fs', name, ...value })),
    ...Object.entries(promisesPathTable).map(([name, value]) => ({ kind: 'promises', name, ...value }))];
  for (const { kind, name, operation } of requests) if (operation === 'readlink') {
    const stem = `${kind}-${name}-中文`;
    await symlinkFixture(`${stem}.txt`, join(f.workspace, `${stem}-dest.txt`));
  }
  const source = await promises.readFile(new URL('./node-script-api-fixture.mjs', import.meta.url), 'utf8');
  const mode = process.execArgv.some(value => value.endsWith('/sim/preload.mjs')) ? 'strict' : 'native';
  const result = successful(await (await f.launch(source, { args: [JSON.stringify(requests), mode] })).done);
  assert.equal(result.status, 'PASS_SCOPED'); assert.equal(result.cwd, f.workspace);
  assert.deepEqual(result.observations.map(row => row.kind + '.' + row.name), requests.map(row => row.kind + '.' + row.name));
  assert.equal(result.nested.length, 3);
  t.diagnostic(JSON.stringify({ entries: requests.length, nativeUnavailable: result.observations.filter(row => row.nativeUnavailable),
    originalOhosDenial: result.observations.filter(row => row.originalOhosDenial) }));
});

test('private batch stdin is byte exact when read and cannot keep an ignoring script alive', async t => {
  const f = await fixture(t), input = Buffer.from([0, 255, 195, 169, 10]);
  for (const stdin of ['', input]) {
    const ignored = await (await f.launch("console.log(JSON.stringify({ignored:true}));", { stdin })).done;
    assert.equal(successful(ignored).ignored, true);
  }
  const consumed = await (await f.launch("const chunks=[];for await(const chunk of process.stdin)chunks.push(chunk);console.log(JSON.stringify({hex:Buffer.concat(chunks).toString('hex')}));", { stdin: input })).done;
  assert.equal(successful(consumed).hex, input.toString('hex'));
});

test('two cwd values, process.chdir, path.resolve and Chinese paths stay within their own Worker', async t => {
  const f = await fixture(t), a = join(f.workspace, '甲'), b = join(f.workspace, '乙');
  await promises.mkdir(a); await promises.mkdir(b);
  await promises.writeFile(join(a, '输入.txt'), 'A'); await promises.writeFile(join(b, '输入.txt'), 'B');
  const source = `import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';import {resolve} from 'node:path';
    const initial=process.cwd();const value=readFileSync('输入.txt','utf8');
    assert.equal(resolve('输入.txt'),initial+'/输入.txt');
    assert.throws(()=>process.chdir(${JSON.stringify(f.temporary)}),{code:'EACCES'});
    process.chdir('..');assert.equal(process.cwd(),${JSON.stringify(f.workspace)});
    console.log(JSON.stringify({initial,value,current:process.cwd(),environment:process.env.CHECK_ENV}));`;
  const aw = await f.launch(source, { cwd: a }), bw = await f.launch(source, { cwd: b });
  const [ar, br] = await Promise.all([aw.done, bw.done]);
  assert.deepEqual([successful(ar).value, successful(br).value], ['A', 'B']);
  assert.equal(successful(ar).environment, '隔离值');
  assert.equal(process.cwd, plainCwd);
  const control = new Worker("const fs=require('node:fs');require('node:worker_threads').parentPort.postMessage({cwd:process.cwd(),name:fs.readFileSync.name});", { eval: true });
  // Node may drain a queued message from its exit handler. Register both
  // promises before yielding; subscribing after message can miss actual exit.
  const exited = new Promise(resolve => control.once('exit', resolve));
  const data = await new Promise((resolve, reject) => { control.once('message', resolve); control.once('error', reject); });
  assert.equal(await exited, 0);
  assert.deepEqual(data, { cwd: process.cwd(), name: 'readFileSync' });
});

test('only this Worker denies child_process, inherited descriptors and paths through an outside symlink', async t => {
  const f = await fixture(t);
  await promises.writeFile(join(f.temporary, 'outside.txt'), 'temporary is not a chdir workspace');
  await symlinkFixture(f.root, join(f.workspace, 'escape'));
  await promises.mkdir(join(f.root, 'outside/deep'), { recursive: true });
  await promises.writeFile(join(f.root, 'outside/secret'), 'OUTSIDE');
  await promises.mkdir(join(f.workspace, 'tricky'));
  await symlinkFixture(join(f.root, 'outside/deep'), join(f.workspace, 'tricky/link'));
  const source = `import assert from 'node:assert/strict';import fs from 'node:fs';import cp from 'node:child_process';
    for(const fd of [0,1,2])assert.throws(()=>fs.closeSync(fd),{code:'ERR_OHOS_NODE_FD_UNAVAILABLE'});
    assert.throws(()=>fs.readFileSync(0),{code:'ERR_OHOS_NODE_FD_UNAVAILABLE'});
    assert.throws(()=>fs.writeSync(1,'must not reach App stdout'),{code:'ERR_OHOS_NODE_FD_UNAVAILABLE'});
    assert.throws(()=>cp.spawn('must-not-execute'),{code:'ERR_OHOS_CHILD_PROCESS_UNAVAILABLE'});
    assert.throws(()=>new cp.ChildProcess().spawn({}),{code:'ERR_OHOS_CHILD_PROCESS_UNAVAILABLE'});
    assert.throws(()=>process.chdir('escape'),{code:'EACCES'});
    assert.throws(()=>fs.readFileSync('escape/outside/secret'),{code:'EACCES'});
    assert.throws(()=>fs.readFileSync('tricky/link/../secret'),{code:'EACCES'});
    assert(fs.lstatSync('escape').isSymbolicLink());
    console.log(JSON.stringify({denied:true}));`;
  assert.equal(successful(await (await f.launch(source)).done).denied, true);
});

for (const closeKind of ['sync', 'callback', 'stream', 'file-handle', 'file-handle-stream']) {
  test(`closed ${closeKind} fd is denied after the real parent reuses exactly the same numeric descriptor`, async t => {
    const f = await fixture(t), sentinel = join(f.root, 'parent-owned');
    await promises.writeFile(sentinel, 'PARENT_UNCHANGED');
    let reused, reusedFd;
    const source = `import assert from 'node:assert/strict';import fs from 'node:fs';import fsp from 'node:fs/promises';import {once} from 'node:events';import {parentPort} from 'node:worker_threads';
      fs.writeFileSync('own.txt','OWN');const kind=${JSON.stringify(closeKind)};let fd;
      if(kind==='file-handle'||kind==='file-handle-stream'){
        const handle=await fsp.open('own.txt','r');fd=handle.fd;
        if(kind==='file-handle'){await handle.close();}else{const stream=handle.createReadStream();for await(const chunk of stream){};assert.equal(handle.fd,-1);}
      }else{
        fd=fs.openSync('own.txt','r');
        if(kind==='sync')fs.closeSync(fd);
        else if(kind==='callback')await new Promise((resolve,reject)=>fs.close(fd,error=>error?reject(error):resolve()));
        else{const stream=fs.createReadStream(undefined,{fd,autoClose:true});for await(const chunk of stream){};}
      }
      const response=once(parentPort,'message');parentPort.postMessage({kind:'reuse',fd});const [message]=await response;assert.equal(message.fd,fd);
      assert.throws(()=>fs.readFileSync(fd),{code:'ERR_OHOS_NODE_FD_UNAVAILABLE'});
      assert.throws(()=>fs.writeSync(fd,'BAD'),{code:'ERR_OHOS_NODE_FD_UNAVAILABLE'});
      assert.throws(()=>fs.closeSync(fd),{code:'ERR_OHOS_NODE_FD_UNAVAILABLE'});
      console.log(JSON.stringify({closed:kind,fd,denied:true}));parentPort.close();`;
    const child = await f.launch(source, { onMessage(message, worker) {
      if (message.kind !== 'reuse') return;
      for (let count = 0; count < 256; count++) {
        const fd = fs.openSync(sentinel, 'r+'); f.parentFds.add(fd);
        if (fd === message.fd) { reused = true; reusedFd = fd; worker.postMessage({ fd }); return; }
      }
      worker.postMessage({ fd: -1 });
    } });
    const result = successful(await child.done); assert.equal(result.denied, true); assert.equal(reused, true);
    assert.equal(fs.readFileSync(reusedFd, 'utf8'), 'PARENT_UNCHANGED');
  });
}

test('read-only is enforced for path writes, fd writes and FileHandle mutation methods', async t => {
  const f = await fixture(t); await promises.writeFile(join(f.workspace, 'input'), 'UNCHANGED');
  const source = `import assert from 'node:assert/strict';import fs from 'node:fs';import fsp from 'node:fs/promises';
    assert.equal(fs.readFileSync('input','utf8'),'UNCHANGED');
    assert.throws(()=>fs.writeFileSync('input','BAD'),{code:'EACCES'});
    assert.throws(()=>fs.openSync('input','r+'),{code:'EACCES'});
    const fd=fs.openSync('input','r');assert.throws(()=>fs.fchmodSync(fd,0o777),{code:'EACCES'});fs.closeSync(fd);
    const handle=await fsp.open('input','r');await assert.rejects(handle.chmod(0o777),{code:'EACCES'});
    await assert.rejects(handle.writeFile('BAD'),{code:'EACCES'});await handle.close();
    console.log(JSON.stringify({readOnly:true}));`;
  assert.equal(successful(await (await f.launch(source, { readOnly: true })).done).readOnly, true);
  assert.equal(await promises.readFile(join(f.workspace, 'input'), 'utf8'), 'UNCHANGED');
});

test('UTF-8 Buffer and file URL paths, empty paths and ignored stream path preserve their stated boundaries', async t => {
  const f = await fixture(t);
  const source = `import assert from 'node:assert/strict';import fs from 'node:fs';import fsp from 'node:fs/promises';import {pathToFileURL} from 'node:url';import {promisify} from 'node:util';
    const name='输入 中文';fs.writeFileSync(Buffer.from(name),'payload');
    const url=pathToFileURL(process.cwd()+'/'+name);assert.equal(await fsp.readFile(url,'utf8'),'payload');
    assert.equal(await promisify(fs.readFile)(Buffer.from(name),'utf8'),'payload');
    const target=pathToFileURL(process.cwd()+'/目标 中文');fs.renameSync(Buffer.from(name),target);
    assert.equal(fs.readFileSync(target,'utf8'),'payload');
    assert.throws(()=>fs.readFileSync(Buffer.from([255])),{code:'ERR_OHOS_NODE_PATH_ENCODING'});
    assert.throws(()=>fs.readFileSync(''),{code:'ENOENT'});await assert.rejects(fsp.writeFile('','bad'),{code:'ENOENT'});
    const real=await promisify(fs.realpath)(Buffer.from('目标 中文'),{encoding:'buffer'});
    assert(Buffer.isBuffer(real));assert.equal(real.toString(),process.cwd()+'/目标 中文');
    const fd=fs.openSync(target,'r');const stream=fs.createReadStream('/outside/ignored-path',{fd,autoClose:true});
    const chunks=[];for await(const chunk of stream)chunks.push(chunk);assert.equal(Buffer.concat(chunks).toString(),'payload');
    assert.throws(()=>fs.closeSync(fd),{code:'ERR_OHOS_NODE_FD_UNAVAILABLE'});
    console.log(JSON.stringify({pathKinds:true}));`;
  assert.equal(successful(await (await f.launch(source)).done).pathKinds, true);
});

test('transferred FileHandle cannot authorize its old numeric descriptor after the real receiver closes and reuses it', async t => {
  const f = await fixture(t), sentinel = join(f.root, 'receiver-owned'); await promises.writeFile(sentinel, 'RECEIVER_UNCHANGED');
  let reusedFd;
  const source = `import assert from 'node:assert/strict';import fs from 'node:fs';import fsp from 'node:fs/promises';import {once} from 'node:events';import {parentPort} from 'node:worker_threads';
    fs.writeFileSync('transfer','OWN');const handle=await fsp.open('transfer','r');const fd=handle.fd;
    const response=once(parentPort,'message');parentPort.postMessage({kind:'transfer',handle,fd},[handle]);
    assert.equal(handle.fd,-1);const [message]=await response;assert.equal(message.fd,fd);
    assert.throws(()=>fs.readFileSync(fd),{code:'ERR_OHOS_NODE_FD_UNAVAILABLE'});
    assert.throws(()=>fs.writeSync(fd,'BAD'),{code:'ERR_OHOS_NODE_FD_UNAVAILABLE'});
    assert.throws(()=>fs.closeSync(fd),{code:'ERR_OHOS_NODE_FD_UNAVAILABLE'});
    console.log(JSON.stringify({transfer:true}));parentPort.close();`;
  const child = await f.launch(source, { async onMessage(message, worker) {
    if (message.kind !== 'transfer') return;
    try {
      await message.handle.close();
      for (let count = 0; count < 256; count++) {
        const fd = fs.openSync(sentinel, 'r+'); f.parentFds.add(fd);
        if (fd === message.fd) { reusedFd = fd; worker.postMessage({ fd }); return; }
      }
      worker.postMessage({ fd: -1 });
    } catch (error) { worker.postMessage({ error: error.message }); }
  } });
  assert.equal(successful(await child.done).transfer, true);
  assert.equal(fs.readFileSync(reusedFd, 'utf8'), 'RECEIVER_UNCHANGED');
});

test('fd wrappers preserve native customPromisifyArgs results and buffer identities', async t => {
  const f = await fixture(t);
  const source = `import assert from 'node:assert/strict';import fs from 'node:fs';import {promisify} from 'node:util';
    fs.writeFileSync('data','abcdef');const fd=fs.openSync('data','r+');
    const buffer=Buffer.alloc(2);const read=await promisify(fs.read)(fd,buffer,0,2,0);
    assert.deepEqual(Object.keys(read),['bytesRead','buffer']);assert.equal(read.bytesRead,2);assert.equal(read.buffer,buffer);assert.equal(buffer.toString(),'ab');
    const input=Buffer.from('xy');const write=await promisify(fs.write)(fd,input,0,2,0);
    assert.deepEqual(Object.keys(write),['bytesWritten','buffer']);assert.equal(write.bytesWritten,2);assert.equal(write.buffer,input);
    const buffers=[Buffer.alloc(1),Buffer.alloc(1)];const readv=await promisify(fs.readv)(fd,buffers,0);
    assert.deepEqual(Object.keys(readv),['bytesRead','buffers']);assert.equal(readv.bytesRead,2);assert.equal(readv.buffers,buffers);
    const inputs=[Buffer.from('1'),Buffer.from('2')];const writev=await promisify(fs.writev)(fd,inputs,0);
    assert.deepEqual(Object.keys(writev),['bytesWritten','buffer']);assert.equal(writev.bytesWritten,2);assert.equal(writev.buffer,inputs);
    fs.closeSync(fd);console.log(JSON.stringify({promisify:true}));`;
  assert.equal(successful(await (await f.launch(source)).done).promisify, true);
});

test('inline Node expressions, print, version and stdin use the inherited guarded Worker', async t => {
  const f = await fixture(t);
  const run = async (args, stdin = '') => {
    const worker = createNodeScriptWorker({args,cwd:f.workspace,roots:[f.workspace,f.temporary],workspaceRoots:[f.workspace],env:{CHECK_ENV:'环境值'},stdin});
    const stdout=[],stderr=[],errors=[];
    worker.stdout.on('data',b=>stdout.push(b));worker.stderr.on('data',b=>stderr.push(b));worker.on('error',e=>errors.push(e));
    const exitCode=await new Promise(resolve=>worker.once('exit',resolve));
    return {exitCode,stdout:Buffer.concat(stdout).toString(),stderr:Buffer.concat(stderr).toString(),errors};
  };
  await promises.writeFile(join(f.workspace,'relative.cjs'),'module.exports="相对模块";');
  const inline=await run(['-e', 'console.log(JSON.stringify({cwd:process.cwd(),env:process.env.CHECK_ENV,arg:process.argv[1],value:require("./relative.cjs")}));process.exitCode=7;', '--', '参数']);
  assert.equal(inline.exitCode,7,JSON.stringify({stderr:inline.stderr,errors:inline.errors.map(e=>({message:e.message,stack:e.stack,code:e.code}))}));assert.deepEqual(inline.errors,[]);
  assert.deepEqual(JSON.parse(inline.stdout),{cwd:f.workspace,env:'环境值',arg:'参数',value:'相对模块'});
  for(const [expression,expected] of [['1+2','3\n'],['undefined','undefined\n'],['({x:"中文",n:2})',"{ x: '中文', n: 2 }\n"]]){
    const result=await run(['-p',expression]);assert.equal(result.exitCode,0);assert.equal(result.stdout,expected);
  }
  assert.equal((await run(['--version'])).stdout,process.version+'\n');
  assert.equal((await run(['-p','(setTimeout(()=>console.log("later"),0),42)'])).stdout,'later\n42\n');
  for(const code of ['const console=null;42','(setTimeout(()=>{console.log=()=>{}},0),42)']) assert.equal((await run(['-p',code])).stdout,'42\n');
  assert.equal((await run(['-e','console.log(import.meta.main)'])).stdout,'false\n');
  for(const args of [[],['-']]) assert.equal((await run(args,'console.log("管道中文")')).stdout,'管道中文\n');
  assert.equal((await run(['-e','"use strict";console.log((function(){return this})()===undefined)'])).stdout,'true\n');
  assert.equal((await run(['-e','import path from "node:path";console.log(await Promise.resolve(path.basename(process.cwd())))'])).stdout,'工作区\n');
});

test('inline ESM resource URLs preserve special cwd, real same-name modules and path guards', { timeout: 30000 }, async t => {
  const f = await fixture(t), cwd = join(f.workspace, '目录 #%');
  await promises.mkdir(cwd);
  await promises.writeFile(join(cwd, '资料 #%.txt'), '资源355');
  await promises.writeFile(join(cwd, '[eval].mjs'), 'export default "real-eval";');
  await promises.writeFile(join(cwd, '[stdin].mjs'), 'export default "real-stdin";');
  await promises.writeFile(join(f.root, 'outside.txt'), 'outside');
  for (const mode of ['eval', 'stdin']) for (const readOnly of [false, true]) {
    const source = `#!/usr/bin/env node
import assert from 'node:assert/strict';import fs from 'node:fs';import {pathToFileURL} from 'node:url';
import a from './[eval].mjs';import b from './[stdin].mjs';
const resource=new URL('./资料%20%23%25.txt',import.meta.url);
assert.equal(fs.readFileSync(resource,'utf8'),'资源355');assert.equal(a,'real-eval');assert.equal(b,'real-stdin');
assert.equal(import.meta.main,false);assert.equal(import.meta.dirname,${JSON.stringify(cwd)});
assert.equal(Object.getPrototypeOf(import.meta),null);assert.equal(Object.getOwnPropertyDescriptor(import.meta,'url').writable,true);
assert.equal(fs.readFileSync(new URL(import.meta.url),'utf8'),${JSON.stringify(`export default "real-${mode}";`)});
assert.throws(()=>fs.readFileSync(${JSON.stringify(join(f.root, 'outside.txt'))},'utf8'),{code:'EACCES'});
assert.throws(()=>fs.readFileSync(new URL('./missing355',import.meta.url),'utf8'),{code:'ENOENT'});
const output=new URL('./output%20%23%25.txt',import.meta.url);
${readOnly ? "assert.throws(()=>fs.writeFileSync(output,'x'),{code:'EACCES'});" : "fs.writeFileSync(output,'ok');assert.equal(fs.readFileSync(output,'utf8'),'ok');"}
const resolved=import.meta.resolve('./资料%20%23%25.txt');import.meta.url='file:///changed/no.mjs';
assert.equal(import.meta.resolve('./资料%20%23%25.txt'),resolved);
console.log(JSON.stringify({mode:${JSON.stringify(mode)},readOnly:${readOnly},value:fs.readFileSync(resource,'utf8'),sameName:[a,b]}));`;
    const worker = createNodeScriptWorker({ args: mode === 'eval' ? ['-e', source] : ['-'],
      cwd, roots: [f.workspace, f.temporary], workspaceRoots: [f.workspace], readOnly, env: {}, stdin: mode === 'stdin' ? source : '' });
    const output = [], errors = [];
    worker.stdout.on('data', bytes => output.push(bytes));worker.on('error', error => errors.push({code:error.code,message:error.message}));
    worker.stderr.resume();const timer=setTimeout(()=>worker.terminate(),10000);
    const exit = await new Promise(resolve => worker.once('exit', resolve));clearTimeout(timer);
    assert.equal(exit,0,JSON.stringify(errors));assert.deepEqual(errors,[]);
    assert.deepEqual(JSON.parse(Buffer.concat(output).toString()),{mode,readOnly,value:'资源355',sameName:['real-eval','real-stdin']});
  }
});
