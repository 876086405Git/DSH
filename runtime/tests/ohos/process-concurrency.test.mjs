import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';

async function fixture(t) {
  const base = await fs.mkdtemp(join(tmpdir(), 'ohos-queues-'));
  const work = join(base, '工作区'), temporaryRoot = join(base, '临时');
  await Promise.all([fs.mkdir(work), fs.mkdir(temporaryRoot)]);
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot });
  t.after(async () => { await runtime.dispose(); await fs.rm(base, { recursive: true, force: true }); });
  const spawn = (argv, extra = {}) => runtime.spawn({
    argv, cwd: work, graceMs: 200,
    stdio: { stdin: 'ignore', stdout: { maxBytes: 65536 }, stderr: { maxBytes: 65536 } },
    ...extra,
  });
  await fs.writeFile(join(work, '中文.txt'), 'needle中文\n');
  return { base, work, runtime, spawn };
}

async function ready(path) {
  const end = Date.now() + 10000;
  while (!await fs.stat(path).then(() => true, () => false)) {
    assert.ok(Date.now() < end, '真实 worker 未到达 ready 文件');
    await delay(20);
  }
}

async function within(promise, milliseconds) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('直接搜索仍在等待长 shell')), milliseconds);
    })]);
  } finally { clearTimeout(timer); }
}

const grep = (name = 'rg') => [name, '--json', '--regexp=needle', '--', '中文.txt'];
const text = handle => handle.collected.stdout.readFrom(0).text;

test('长 bash 不阻塞直接 rg，另外两个写任务保持 FIFO', { timeout: 20000 }, async t => {
  const { work, spawn } = await fixture(t);
  const shell = spawn(['bash', '-c', 'echo ready > ready; sleep 30; echo late > late']);
  await ready(join(work, 'ready'));
  const first = spawn(['bash', '-c', 'echo first >> order']);
  const second = spawn(['sh', '-c', 'echo second >> order']);
  const start = performance.now();
  const search = spawn(grep());
  assert.equal((await within(search.done, 8000)).exitCode, 0);
  assert.match(text(search), /needle中文/);
  assert.equal(await fs.stat(join(work, 'order')).then(() => true, () => false), false);
  assert.equal(await shell.waitForExit(AbortSignal.abort()), false);
  t.diagnostic(JSON.stringify({ searchMs: performance.now() - start, shellStillRunning: true, rssBytes: process.memoryUsage().rss }));
  shell.terminate();
  assert.equal((await shell.done).signal, 'SIGTERM');
  assert.equal((await first.done).exitCode, 0);
  assert.equal((await second.done).exitCode, 0);
  assert.equal(await fs.readFile(join(work, 'order'), 'utf8'), 'first\nsecond\n');
  assert.equal(await fs.stat(join(work, 'late')).then(() => true, () => false), false);
});

test('只读 prepare 和允许的 rg 绝对路径仍走搜索队列，bash 内的 rg 留在执行队列', { timeout: 20000 }, async t => {
  const { work, runtime, spawn } = await fixture(t);
  const shell = spawn(['bash', '-c', 'echo ready > ready; sleep 30']);
  await ready(join(work, 'ready'));
  const mixed = spawn(['bash', '-c', 'rg --json --regexp=needle -- 中文.txt; echo wrote > mixed']);
  for (const name of ['/dsh-go/ohos/bin/rg', '/bin/rg', '/usr/bin/rg']) {
    const argv = runtime.prepare(grep(name), { mode: 'read-only', workspaceRoot: work });
    const search = spawn(argv);
    assert.equal((await within(search.done, 8000)).exitCode, 0);
    assert.match(text(search), /needle中文/);
    assert.equal(await fs.stat(join(work, 'mixed')).then(() => true, () => false), false);
  }
  shell.terminate();
  await shell.done;
  assert.equal((await mixed.done).exitCode, 0);
  assert.equal(await fs.readFile(join(work, 'mixed'), 'utf8'), 'wrote\n');
});

test('搜索按提交顺序完成，排队取消不运行并且不阻塞后一搜索', async t => {
  const { spawn } = await fixture(t);
  const order = [];
  const first = spawn(grep());
  first.done.then(() => order.push('first'));
  const controller = new AbortController();
  const cancelled = spawn(grep(), { signal: controller.signal });
  const last = spawn(grep());
  last.done.then(() => order.push('last'));
  controller.abort();
  assert.equal((await cancelled.done).signal, 'SIGTERM');
  assert.equal(text(cancelled), '');
  assert.equal((await first.done).exitCode, 0);
  assert.equal((await last.done).exitCode, 0);
  assert.deepEqual(order, ['first', 'last']);
});

test('执行和搜索失败各自释放队列，之后仍可运行', async t => {
  const { spawn } = await fixture(t);
  const unavailable = spawn(['not-an-ohos-command']);
  const badSearch = spawn(['rg', '--json', '--regexp=[', '--', '中文.txt']);
  const shell = spawn(['bash', '-c', 'printf recovered']);
  const search = spawn(grep());
  assert.equal((await unavailable.done).exitCode, 127);
  assert.equal((await badSearch.done).exitCode, 2);
  assert.equal((await shell.done).exitCode, 0);
  assert.equal((await search.done).exitCode, 0);
  assert.equal(text(shell), 'recovered');
});

test('dispose 等待两类已启动任务退出，并取消两类队列中尚未启动的任务', async t => {
  const { runtime, spawn } = await fixture(t);
  const handles = [spawn(['bash', '-c', 'sleep 30']), spawn(grep())];
  const queued = [spawn(['bash', '-c', 'echo must-not-run']), spawn(grep())];
  // startNext 的 microtask 已创建实际 Worker；其模块初始化尚未完成。
  await Promise.resolve();
  await runtime.dispose();
  for (const handle of [...handles, ...queued]) {
    assert.equal(await handle.waitForExit(), true);
    assert.equal((await handle.done).signal, 'SIGTERM');
  }
  for (const handle of queued) assert.equal(text(handle), '');
  assert.throws(() => spawn(grep()), /服务已关闭/);
});
