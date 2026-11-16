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
  for (const args of [['-e'], ['-p'], ['--help'], ['--eval=42'], ['--inspect'], ['directory']]) {
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

// Worker exit events retain the integer supplied by the script. At the
// subprocess seam, Node is an external POSIX command with an 8-bit status.
for (const method of ['exit', 'exitCode']) for (const route of ['direct', 'nested']) {
  for (const [code, expected] of [[0, 0], [7, 7], [255, 255], [256, 0], [-1, 255]]) {
    test(`Node exit status ${method}/${route}/${code} matches an external command`, { timeout: 15000 }, async t => {
      const f = await fixture(t);
      const entry = await f.script(method === 'exit' ? `process.exit(${code});` : `process.exitCode=${code};`);
      const result = await f.run(route === 'direct' ? ['node', entry] : ['bash', '-c', `node '${entry}'`]);
      assert.deepEqual({ exitCode: result.exitCode, signal: result.signal }, { exitCode: expected, signal: null });
      assert.equal(result.stdout.length, 0); assert.equal(result.stderr.length, 0);
      assert.equal(f.runtime.live.size, 0);
    });
  }
}

for (const [code, expected] of [[0, 0], [7, 7], [255, 255], [256, 0], [-1, 255]]) {
  test(`Node exit status ${code} drives Bash status and conditional branches`, { timeout: 15000 }, async t => {
    const f = await fixture(t), entry = await f.script(`process.exit(${code});`);
    const invoke = `node '${entry}'`;
    const result = await f.run(['bash', '-c', `${invoke}; printf 'status=%s\n' "$?"; if ${invoke}; then printf 'if=yes\n'; else printf 'if=no\n'; fi; ${invoke} && printf 'and=yes\n'; printf 'after-and\n'; set -o pipefail; ${invoke} | cat; printf 'pipe=%s\n' "$?"`]);
    const branch = expected === 0 ? 'if=yes\nand=yes\n' : 'if=no\n';
    assert.equal(result.exitCode, 0); assert.equal(result.signal, null); assert.equal(result.stderr.length, 0);
    assert.equal(result.stdout.toString(), `status=${expected}\n${branch}after-and\npipe=${expected}\n`);
  });
}

for (const shell of [false, true]) test(`inline Node real ${shell ? 'bash' : 'direct'} path preserves output, status, stdin and guards`, { timeout: 20000 }, async t => {
  const f = await fixture(t);
  await writeFile(join(f.work, 'relative.cjs'), 'module.exports="相对依赖";');
  await writeFile(join(f.work, 'relative.mjs'), 'export default "ESM依赖";');
  const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  const args = values => shell ? ['bash', '-c', ['node', ...values].map(quote).join(' ')] : ['node', ...values];
  const run = (values, options) => f.run(args(values), options);
  const source = 'console.log(JSON.stringify({cwd:process.cwd(),env:process.env.EXPLICIT_VALUE,argv:process.argv.slice(1),value:require("./relative.cjs"),guard:globalThis[Symbol.for("dsh.go.ohos.nodeWorker.paths")],preload:globalThis[Symbol.for("dsh.go.ohos.nodeWorker.preload")]}));process.exitCode=7;';
  const result = await run(['-e', source, '--', '中文 参数'], { env: { EXPLICIT_VALUE: '环境值' } });
  assert.equal(result.exitCode, 7, result.stderr.toString());
  const value = JSON.parse(result.stdout); assert.equal(value.cwd, f.work); assert.equal(value.env, '环境值');
  assert.deepEqual(value.argv, ['中文 参数']); assert.equal(value.value, '相对依赖'); assert(value.guard); assert.equal(value.preload, 1);
  for (const [code, expected] of [['1+2','3\n'],['undefined','undefined\n'],['({x:"中文",n:2})',"{ x: '中文', n: 2 }\n"]]) {
    const printed = await run(['-p', code]); assert.equal(printed.exitCode, 0); assert.equal(printed.stdout.toString(), expected);
  }
  assert.equal((await run(['--version'])).stdout.toString(), process.version+'\n');
  const moduleResult = await run(['-e','import value from "./relative.mjs";console.log(await Promise.resolve(value));']);
  assert.equal(moduleResult.exitCode,0,moduleResult.stderr.toString());assert.equal(moduleResult.stdout.toString(),'ESM依赖\n');
  const dynamic = await run(['-e','import("./relative.mjs").then(m=>console.log(m.default));']);
  assert.equal(dynamic.exitCode,0,dynamic.stderr.toString());assert.equal(dynamic.stdout.toString(),'ESM依赖\n');
  const stdin = { stdio: { stdin: { data: 'console.log("stdin-code");(async()=>{for await(const b of process.stdin)console.log("unexpected",b)})();' }, stdout: 'pipe', stderr: 'pipe' } };
  assert.equal((await run([], stdin)).stdout.toString(), 'stdin-code\n');
  const data = await run(['-e', '(async()=>{for await(const b of process.stdin)process.stdout.write(b)})()'], { stdio: { stdin: {data: shell ? '输入中文' : Buffer.from([0,255,195,169])}, stdout:'pipe',stderr:'pipe' } });
  assert.deepEqual(data.stdout,shell ? Buffer.from('输入中文') : Buffer.from([0,255,195,169]));
  const denied = await run(['-e','require("node:fs").writeFileSync("../outside", "bad")']);
  assert.notEqual(denied.exitCode,0);assert.match(denied.stderr.toString(),/EACCES|OHOS_SANDBOX_DENIED/);
  const deniedModule=await run(['-e','import fs from "node:fs";fs.writeFileSync("../outside-module","bad")']);
  assert.notEqual(deniedModule.exitCode,0);assert.match(deniedModule.stderr.toString(),/EACCES|OHOS_SANDBOX_DENIED/);
  for(const n of [-1,256]) assert.equal((await run(['-e',`process.exit(${n})`])).exitCode,n&255);
  const bad = await run(['-e','throw new Error("inline failure")']);assert.equal(bad.exitCode,1);assert.match(bad.stderr.toString(),/inline failure/);
  const active = f.spawn(args(['-e','require("node:fs").writeFileSync("inline-started","ready");console.log("ready");while(true){}']));
  const started = new Promise(resolve=>active.stdout.once('data',resolve));
  // Bash buffers the statement: observe an actual workspace write before cancellation.
  if(shell) {
    const deadline=Date.now()+6000;
    while(await stat(join(f.work,'inline-started')).then(()=>false,()=>true)) {
      assert(Date.now()<deadline,'inline Node really started before cancellation');await delay(10);
    }
  } else await started;
  active.terminate();const stopped=await f.complete(active);assert.equal(stopped.signal,'SIGTERM');assert.equal(f.runtime.live.size,0);
});

test('a real shell pipeline feeds Node program source exactly once', async t => {
  const f = await fixture(t);
  const result = await f.run(['bash','-c',"printf 'console.log(6*7)' | node"]);
  assert.equal(result.exitCode,0,result.stderr.toString());assert.equal(result.stdout.toString(),'42\n');
});

// Real Worker errors must remain command outcomes, never owner-listener errors.
for (const route of ['direct', 'bash']) {
  test(`${route} Worker thrown values preserve diagnostics and release the queued lane`, { timeout: 15000 }, async t => {
    const f = await fixture(t);
    const values = [
      ['Object.assign(new Error("真实错误"), {stack:"Error: 真实错误\\n    at fixed-worker-frame"})', 'Error: 真实错误\n    at fixed-worker-frame\n'],
      ['"中文抛值"', '中文抛值\n'],
      ['null', 'null\n'],
      ['({toString:1,valueOf:2,detail:"中文对象"})', "{ toString: 1, valueOf: 2, detail: '中文对象' }\n"],
    ];
    const next = await f.script("process.stdout.write('queue-continues');");
    for (const [expression, expected] of values) {
      const entry = await f.script(`process.stdout.write('before-error\\n',()=>setImmediate(()=>{throw ${expression};}));`);
      const argv = route === 'direct' ? ['node', entry] : ['bash', '-c', `node '${entry}'`];
      const failed = f.spawn(argv);
      const queued = f.spawn(['node', next]);
      const [result, following] = await Promise.all([f.complete(failed), f.complete(queued)]);
      assert.equal(result.exitCode, 1);
      assert.equal(result.signal, null);
      assert.equal(result.stdout.toString(), 'before-error\n');
      assert.deepEqual(result.stderr, Buffer.from(expected));
      assert.equal(following.exitCode, 0);
      assert.equal(following.stderr.length, 0);
      assert.equal(following.stdout.toString(), 'queue-continues');
      assert.equal(f.runtime.live.size, 0);
    }
  });
}
