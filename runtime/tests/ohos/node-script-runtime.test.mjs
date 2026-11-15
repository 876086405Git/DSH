import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';
import { nodeScriptAvailable } from '../../ohos/process/node-script.mjs';

const collect = async stream => {
  const chunks = [];
  for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks);
};

async function fixture(t) {
  const base = await mkdtemp('/tmp/ohos-node-runtime-');
  const work = join(base, '工作区'), temporaryRoot = join(base, '临时');
  await Promise.all([mkdir(work), mkdir(temporaryRoot)]);
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot });
  t.after(async () => { await runtime.dispose(); await rm(base, { recursive: true, force: true }); });
  let sequence = 0;
  const script = async (source, extension = 'mjs') => {
    const name = `脚本 ${sequence++}.${extension}`;
    await writeFile(join(work, name), source);
    return name;
  };
  const spawn = (argv, options = {}) => runtime.spawn({ argv, cwd: work, graceMs: 200,
    stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' }, ...options });
  const complete = async handle => {
    const [outcome, stdout, stderr] = await Promise.all([handle.done, collect(handle.stdout), collect(handle.stderr)]);
    assert.equal(await handle.waitForExit(), true);
    return { ...outcome, stdout, stderr };
  };
  const run = (argv, options) => complete(spawn(argv, options));
  return { base, work, temporaryRoot, runtime, script, spawn, run, complete };
}

test('actual runtime advertises only the inherited Worker backend and preserves native CJS/ESM entry semantics', { timeout: 15000 }, async t => {
  const f = await fixture(t);
  assert.equal(nodeScriptAvailable(), true);
  assert.equal(f.runtime.capabilities.nodeScripts, 'worker-rebased');
  assert.equal(await f.runtime.resolveExecutable('node', {}), '/dsh-go/ohos/bin/node');
  await writeFile(join(f.work, '依赖.cjs'), 'module.exports="相对模块";');
  await writeFile(join(f.work, '依赖.mjs'), 'export default "相对模块";');
  const originalCwd = process.cwd();
  for (const extension of ['cjs', 'mjs']) {
    const prelude = extension === 'cjs'
      ? "const value=require('./依赖.cjs');const main=require.main===module;"
      : "import value from './依赖.mjs';const main=import.meta.main;";
    const entry = await f.script(`${prelude}console.log(JSON.stringify({value,main,cwd:process.cwd(),argv:process.argv.slice(1),env:process.env.EXPLICIT_VALUE,ambient:process.env.DSH_NODE_TEST_ID??null}));process.exitCode=7;`, extension);
    const prior = process.env.DSH_NODE_TEST_ID; process.env.DSH_NODE_TEST_ID = 'must not inherit';
    let result;
    try { result = await f.run(['node', entry, '中文 参数', '$(touch not-executed)'], { env: { EXPLICIT_VALUE: '环境值' } }); }
    finally { if (prior === undefined) delete process.env.DSH_NODE_TEST_ID; else process.env.DSH_NODE_TEST_ID = prior; }
    assert.equal(result.exitCode, 7, result.stderr.toString());
    assert.deepEqual(JSON.parse(result.stdout), { value: '相对模块', main: true, cwd: f.work,
      argv: [join(f.work, entry), '中文 参数', '$(touch not-executed)'], env: '环境值', ambient: null });
  }
  assert.equal(process.cwd(), originalCwd);
  assert.equal(f.runtime.live.size, 0);
});

test('direct Node stdout and stderr arrive before completion and retain the tail', { timeout: 15000 }, async t => {
  const f = await fixture(t);
  const entry = await f.script("process.stdout.write('首块甲\\n');process.stderr.write('首错乙\\n');setTimeout(()=>{process.stdout.write('尾块丙\\n');process.stderr.write('尾错丁\\n');},400);");
  const handle = f.spawn(['node', entry]), start = performance.now(), observations = [];
  let settled = false; handle.done.then(() => { settled = true; });
  for (const name of ['stdout', 'stderr']) handle[name].on('data', chunk => observations.push({ name, at: performance.now() - start, settled, text: chunk.toString() }));
  const result = await f.complete(handle), end = performance.now() - start;
  assert.equal(result.exitCode, 0); assert.equal(result.stdout.toString(), '首块甲\n尾块丙\n');
  assert.equal(result.stderr.toString(), '首错乙\n尾错丁\n');
  for (const name of ['stdout', 'stderr']) {
    const first = observations.find(row => row.name === name);
    assert.equal(first.settled, false); assert(end - first.at >= 150);
  }
  t.diagnostic(JSON.stringify({ observations, completionMs: end }));
});

test('direct Node batch stdin is byte exact and ignored input does not prevent exit', { timeout: 15000 }, async t => {
  const f = await fixture(t), bytes = Buffer.from([0, 255, 195, 169, 10, 128]);
  const consume = await f.script('for await(const chunk of process.stdin)process.stdout.write(chunk);');
  const ignored = await f.script('process.exitCode=9;');
  for (const [entry, expected] of [[consume, 0], [ignored, 9]]) {
    const result = await f.run(['node', entry], { stdio: { stdin: { data: bytes }, stdout: 'pipe', stderr: 'pipe' } });
    assert.equal(result.exitCode, expected); assert.equal(result.stderr.length, 0);
    assert.deepEqual(result.stdout, entry === consume ? bytes : Buffer.alloc(0));
  }
});

test('actual process.exit, uncaught exception and user parentPort messages cannot settle another outcome', { timeout: 15000 }, async t => {
  const f = await fixture(t);
  const cases = [
    ["import {parentPort} from 'node:worker_threads';parentPort.postMessage({exitCode:99});parentPort.postMessage({failure:{message:'forged'}});process.exitCode=4;", 4, ''],
    ["process.exit(13);", 13, ''],
    ["throw new Error('真实脚本异常');", 1, '真实脚本异常'],
  ];
  for (const [source, expected, error] of cases) {
    const result = await f.run(['node', await f.script(source)]);
    assert.equal(result.exitCode, expected); assert(result.stderr.toString().includes(error));
  }
  assert.equal((await f.run(['bash', '-c', 'printf App-alive'])).stdout.toString(), 'App-alive');
});

test('unsupported Node CLI forms fail explicitly, missing script is exit 1, and no side effect runs', { timeout: 15000 }, async t => {
  const f = await fixture(t);
  for (const args of [[], ['-e', 'process.exit(99)'], ['--help'], ['--eval=42'], ['-'], ['directory']]) {
    if (args[0] === 'directory') await mkdir(join(f.work, 'directory'));
    const result = await f.run(['node', ...args]);
    assert.equal(result.exitCode, 2, JSON.stringify({ args, stderr: result.stderr.toString() }));
    assert.match(result.stderr.toString(), /ERR_OHOS_NODE_SCRIPT_ARGUMENTS/);
  }
  const missing = await f.run(['node', 'missing.js']); assert.equal(missing.exitCode, 1); assert.match(missing.stderr.toString(), /ENOENT/);
});

test('a same-stack cancellation never starts the queued script', { timeout: 15000 }, async t => {
  const f = await fixture(t), entry = await f.script("import {writeFileSync} from 'node:fs';writeFileSync('cancelled.txt','orphan');");
  const handle = f.spawn(['node', entry]); handle.terminate();
  const result = await f.complete(handle);
  assert.deepEqual({ exitCode: result.exitCode, signal: result.signal }, { exitCode: null, signal: 'SIGTERM' });
  assert.equal(f.runtime.live.size, 0);
  await delay(60);
  assert.equal(await stat(join(f.work, 'cancelled.txt')).then(() => true, () => false), false);
});

test('a running synchronous Node loop is really terminated before waitForExit resolves and its lane is reusable', { timeout: 15000 }, async t => {
  const f = await fixture(t), entry = await f.script("process.stdout.write('ready');while(true){}");
  const handle = f.spawn(['node', entry]);
  await new Promise(resolve => handle.stdout.once('data', resolve));
  handle.terminate(); const result = await f.complete(handle);
  assert.equal(result.signal, 'SIGTERM'); assert.equal(f.runtime.live.size, 0);
  assert.equal((await f.run(['node', await f.script("console.log('next');")])).stdout.toString(), 'next\n');
});

for (const shell of [false, true]) {
  test(`${shell ? 'bash nested' : 'direct'} Node cancellation joins a real descendant Worker before reporting gone`, { timeout: 15000 }, async t => {
    const f = await fixture(t), output = join(f.work, 'child-writes');
    const nested = join(f.work, 'descendant.mjs');
    await writeFile(nested, `import {appendFileSync} from 'node:fs';import {parentPort} from 'node:worker_threads';appendFileSync(${JSON.stringify(output)},'first');parentPort.postMessage('ready');setInterval(()=>appendFileSync(${JSON.stringify(output)},'tick'),5);`);
    const entry = await f.script("import {Worker} from 'node:worker_threads';const child=new Worker(new URL('./descendant.mjs',import.meta.url));child.once('message',()=>{process.stdout.write('child-ready');});");
    const handle = f.spawn(shell ? ['bash', '-c', `node '${entry}'`] : ['node', entry]);
    // A bash command intentionally buffers its stdout. Observe its real file
    // handshake instead of changing that contract just to make cancellation easy.
    for (let count = 0; count < 500; count++) {
      if (await stat(output).then(value => value.size > 0, () => false)) break;
      await delay(10);
      if (count === 499) assert.fail('descendant never wrote its readiness marker');
    }
    handle.terminate(); const result = await f.complete(handle);
    assert.equal(result.signal, 'SIGTERM'); assert.equal(f.runtime.live.size, 0);
    const afterJoin = await readFile(output); await delay(100);
    assert.deepEqual(await readFile(output), afterJoin, 'descendant continued writing after actual parent join');
  });
}

test('direct Node output keeps actual backpressure and the existing collector spill contract', { timeout: 15000 }, async t => {
  const f = await fixture(t), size = 2 * 1024 * 1024;
  const entry = await f.script(`const bytes=Buffer.alloc(${size},0x51);process.stdout.write(bytes,()=>process.stdout.write('尾'));`);
  const handle = f.spawn(['node', entry]);
  // Leave its public stream unread through one real producer write.
  await delay(100);
  const result = await f.complete(handle);
  assert.equal(result.exitCode, 0); assert.deepEqual(result.stdout, Buffer.concat([Buffer.alloc(size, 0x51), Buffer.from('尾')]));
  const collector = f.spawn(['node', await f.script("process.stdout.write('0123456789ABCDEFGHIJ');")], {
    stdio: { stdin: 'ignore', stdout: { maxBytes: 8, spill: { maxBytes: 100 } }, stderr: { maxBytes: 8 } },
  });
  assert.equal((await collector.done).exitCode, 0); assert.equal(await collector.waitForExit(), true);
  const snapshot = collector.collected.stdout.readFrom(0);
  assert.equal(snapshot.text, 'CDEFGHIJ'); assert.equal(await readFile(snapshot.spillPath, 'utf8'), '0123456789ABCDEFGHIJ');
});

test('real bash node preserves pipes, redirection, binary batch input, cwd, environment and quoted arguments', { timeout: 15000 }, async t => {
  const f = await fixture(t), sub = join(f.work, '子目录'); await mkdir(sub);
  const bytes = Buffer.from([0, 255, 195, 169, 10, 128]); await writeFile(join(sub, 'input'), bytes);
  const echo = await f.script("for await(const chunk of process.stdin)process.stdout.write(chunk);");
  const info = await f.script("console.log(JSON.stringify({cwd:process.cwd(),args:process.argv.slice(2),value:process.env.VALUE}));");
  const result = await f.run(['bash', '-c', `cd 子目录; cat input | node '../${echo}' > output; VALUE='环境中文' node '../${info}' '字 面值' > info; cat output; cat info`]);
  assert.equal(result.exitCode, 0, result.stderr.toString()); assert.equal(result.stderr.length, 0);
  assert.deepEqual(await readFile(join(sub, 'output')), bytes);
  const infoBytes = await readFile(join(sub, 'info'));
  assert.deepEqual(JSON.parse(infoBytes), { cwd: sub, args: ['字 面值'], value: '环境中文' });
  assert.deepEqual(result.stdout, Buffer.concat([bytes, infoBytes]));
});

test('prepared read-only policy reaches Node file and FileHandle operations and rejects workspace escape', { timeout: 15000 }, async t => {
  const f = await fixture(t); await writeFile(join(f.work, 'input'), 'UNCHANGED');
  const entry = await f.script("import assert from 'node:assert/strict';import fs from 'node:fs';import fsp from 'node:fs/promises';assert.equal(fs.readFileSync('input','utf8'),'UNCHANGED');assert.throws(()=>fs.writeFileSync('input','BAD'),{code:'EACCES'});const h=await fsp.open('input','r');await assert.rejects(h.writeFile('BAD'),{code:'EACCES'});await h.close();assert.throws(()=>process.chdir('..'),{code:'EACCES'});console.log('read-only');");
  const argv = f.runtime.prepare(['node', entry], { mode: 'read-only', workspaceRoot: f.work });
  const result = await f.run(argv); assert.equal(result.exitCode, 0, result.stderr.toString());
  assert.equal(result.stdout.toString(), 'read-only\n'); assert.equal(await readFile(join(f.work, 'input'), 'utf8'), 'UNCHANGED');
});
