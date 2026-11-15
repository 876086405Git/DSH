import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setImmediate as immediate } from 'node:timers/promises';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';
import { createOwnedGitServer } from '../../ohos/process/owned-server.mjs';

async function fixture(t, observe = server => server) {
  const base = await mkdtemp('/tmp/ohos-combined-');
  const work = join(base, '工作区'), temporaryRoot = join(base, '临时');
  await Promise.all([mkdir(work), mkdir(temporaryRoot)]);
  let servers = 0;
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot }, {
    createOwnedGitServer(options) { return observe(createOwnedGitServer(options), ++servers); },
  });
  t.after(async () => { await runtime.dispose(); await rm(base, { recursive: true, force: true }); });
  const spawn = argv => runtime.spawn({ argv, cwd: work, graceMs: 200, env: {},
    stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
  const complete = async handle => {
    const collect = async stream => { const chunks = []; for await (const value of stream) chunks.push(value); return Buffer.concat(chunks); };
    const [outcome, stdout, stderr] = await Promise.all([handle.done, collect(handle.stdout), collect(handle.stderr)]);
    assert.equal(await handle.waitForExit(), true);
    return { ...outcome, stdout, stderr };
  };
  return { work, runtime, spawn, complete, servers: () => servers };
}

test('untrusted Node messages never reach the owned broker; following bash retains its real server', { timeout: 15000 }, async t => {
  const f = await fixture(t);
  await writeFile(join(f.work, 'entry.mjs'), `import {parentPort} from 'node:worker_threads';
parentPort.postMessage({type:'dsh-ohos-owned-git-request',protocolVersion:1,requestId:1,operation:'begin',payload:{}});
parentPort.postMessage({type:'dsh-ohos-owned-git-ack',protocolVersion:1,requestId:1});
parentPort.postMessage({exitCode:99});console.log('untrusted');process.exitCode=7;`);
  const result = await f.complete(f.spawn(['node', 'entry.mjs']));
  assert.equal(result.exitCode, 7); assert.equal(result.stdout.toString(), 'untrusted\n');
  assert.equal(result.stderr.length, 0); assert.equal(f.servers(), 0);
  const shell = await f.complete(f.spawn(['bash', '-c', 'printf shell-after-node']));
  assert.equal(shell.exitCode, 0); assert.equal(shell.stdout.toString(), 'shell-after-node');
  assert.equal(f.servers(), 1); assert.equal(f.runtime.live.size, 0);
});

test('stdout tail drains before real owner finish; pending finish keeps the next Node job queued', { timeout: 15000 }, async t => {
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  const f = await fixture(t, (server, number) => ({ handle: server.handle, stop: server.stop,
    async finish(options) {
      await server.finish(options);
      if (number === 1) { entered.resolve(); await release.promise; }
    },
  }));
  const bytes = 2 * 1024 * 1024;
  await writeFile(join(f.work, 'emit.mjs'), `process.stdout.write(Buffer.alloc(${bytes},81),()=>process.stdout.write('尾'));`);
  await writeFile(join(f.work, 'next.mjs'), "import {writeFileSync} from 'node:fs';writeFileSync('next-result','next');");
  const first = f.spawn(['bash', '-c', 'node emit.mjs']), observed = [];
  first.stdout.on('data', chunk => observed.push(Buffer.from(chunk)));
  first.stderr.resume();
  let settled = false; first.done.then(() => { settled = true; });
  const next = f.spawn(['node', 'next.mjs']); next.stdout.resume(); next.stderr.resume();
  try {
    await entered.promise; await immediate();
    assert.deepEqual(Buffer.concat(observed), Buffer.concat([Buffer.alloc(bytes,81), Buffer.from('尾')]));
    assert.equal(settled, false); assert.equal(f.runtime.live.size, 2);
    await assert.rejects(readFile(join(f.work, 'next-result')), { code: 'ENOENT' });
    release.resolve();
    assert.deepEqual(await first.done, { exitCode: 0, signal: null });
    assert.equal(await first.waitForExit(), true);
    assert.deepEqual(await next.done, { exitCode: 0, signal: null });
    assert.equal(await next.waitForExit(), true);
    assert.equal(await readFile(join(f.work, 'next-result'), 'utf8'), 'next');
    assert.equal(f.servers(), 1); assert.equal(f.runtime.live.size, 0);
  } finally { release.resolve(); }
});
