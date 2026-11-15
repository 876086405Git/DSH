import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { performance } from 'node:perf_hooks';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';
import { Bash } from '../../ohos/process/build/just-bash/index.js';

const collect = async stream => {
  const chunks = [];
  for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks);
};

async function fixture(t, ownTemporary = false) {
  const base = await mkdtemp(join(tmpdir(), 'ohos-streaming-'));
  const work = join(base, '工作区');
  const temporaryRoot = join(base, '临时');
  await Promise.all([mkdir(work), mkdir(temporaryRoot)]);
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], ...(ownTemporary ? {} : { temporaryRoot }) });
  t.after(async () => {
    await runtime.dispose();
    await rm(base, { recursive: true, force: true });
  });
  const spawn = (argv, extra = {}) => runtime.spawn({
    argv, cwd: work, graceMs: 200,
    stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' }, ...extra,
  });
  const run = async (script, extra) => {
    const handle = spawn(['bash', '-c', script], extra);
    const [outcome, stdout, stderr] = await Promise.all([handle.done, collect(handle.stdout), collect(handle.stderr)]);
    assert.equal(await handle.waitForExit(), true);
    return { ...outcome, stdout, stderr };
  };
  return { base, work, temporaryRoot, runtime, spawn, run };
}

test('完成的外层语句在后续 sleep 结束前交付，UTF-8 stdout/stderr 无重复', { timeout: 15000 }, async t => {
  const f = await fixture(t);
  const handle = f.spawn(['bash', '-c', 'printf "首块甲\\n"; printf "首错乙\\n" >&2; sleep 0.4; printf "尾块丙\\n"; printf "尾错丁\\n" >&2']);
  const start = performance.now(), observations = [];
  let settled = false;
  handle.done.then(() => { settled = true; });
  handle.stdout.on('data', data => observations.push({ at: performance.now() - start, settled, bytes: Buffer.from(data) }));
  const [outcome, stdout, stderr] = await Promise.all([handle.done, collect(handle.stdout), collect(handle.stderr)]);
  const end = performance.now() - start;
  assert.equal(outcome.exitCode, 0);
  assert.equal(stdout.toString(), '首块甲\n尾块丙\n');
  assert.equal(stderr.toString(), '首错乙\n尾错丁\n');
  assert(observations.length >= 2, 'baseline batch implementation returns one combined output chunk');
  assert.equal(observations[0].bytes.toString(), '首块甲\n');
  assert.equal(observations[0].settled, false);
  assert(end - observations[0].at >= 150, `first=${observations[0].at}, end=${end}`);
  t.diagnostic(JSON.stringify({ firstOutputMs: observations[0].at, completionMs: end, chunks: observations.length }));
});

test('sh 的原始 argv、cwd/env 与批量 stdin 保留，脚本文件同样分段', async t => {
  const f = await fixture(t);
  await writeFile(join(f.work, '脚本.sh'), 'printf "%s|%s|%s\\n" "$0" "$1" "$VALUE"; pwd; cat; sleep 0.02; printf done');
  const handle = f.spawn(['sh', '脚本.sh', '$(echo unsafe)'], {
    env: { VALUE: '环境甲' },
    stdio: { stdin: { data: '输入乙\n' }, stdout: 'pipe', stderr: 'pipe' },
  });
  const [outcome, stdout, stderr] = await Promise.all([handle.done, collect(handle.stdout), collect(handle.stderr)]);
  assert.equal(outcome.exitCode, 0);
  assert.equal(stdout.toString(), `脚本.sh|$(echo unsafe)|环境甲\n${f.work}\n输入乙\ndone`);
  assert.equal(stderr.length, 0);
});

test('捕获、管道、函数和重定向仍先完成输出路由，没有内部结果泄露', async t => {
  const f = await fixture(t);
  const result = await f.run('value=$(printf HIDDEN); printf "%s\\n" "$value" > captured; printf pipe-in | sed s/in/out/ > piped; f() { printf nested; }; f > nested; { printf group; printf err >&2; } > group 2>error; printf visible; cat captured piped nested group error');
  assert.equal(result.exitCode, 0);
  assert.equal(result.stdout.toString(), 'visibleHIDDEN\npipe-outnestedgrouperr');
  assert.equal(result.stderr.length, 0);
  assert.equal(await readFile(join(f.work, 'captured'), 'utf8'), 'HIDDEN\n');
});

test('持久描述符、source/eval 和嵌套 bash 的捕获不被外层 sink 越过', async t => {
  const f = await fixture(t);
  await writeFile(join(f.work, 'source.sh'), 'printf from-source; printf source-err >&2');
  const result = await f.run('exec 3>fd-file; printf first >&3; . ./source.sh >source-out 2>source-error; eval "printf eval-output" >eval-file; bash -c "printf nested" | sed s/nested/filtered/ >nested-file; value=$(bash -c "printf secret"); printf "%s" "$value" >capture; printf second >&3; exec 3>&-; cat fd-file source-out source-error eval-file nested-file capture');
  assert.equal(result.exitCode, 0);
  assert.equal(result.stdout.toString(), 'firstsecondfrom-sourcesource-erreval-outputfilteredsecret');
  assert.equal(result.stderr.length, 0);
  assert.equal(await readFile(join(f.work, 'fd-file'), 'utf8'), 'firstsecond');
});

test('交付后共享输出预算不刷新，也不因外层转发重复计费', async () => {
  for (const [budget, expectedCode, expectedOutput] of [[12, 126, '1234567890'], [20, 0, '1234567890abcdefghij']]) {
    const bash = new Bash({ defenseInDepth: false, executionLimits: { maxOutputSize: budget } });
    const chunks = [];
    const result = await bash.exec('bash', {
      args: ['-c', 'printf 12345; printf 67890; printf abcde; printf fghij'],
      ohosStatementOutput: async value => { chunks.push(value.stdout); },
    });
    assert.equal(result.exitCode, expectedCode);
    assert.equal(chunks.join('') + result.stdout, expectedOutput);
    if (expectedCode !== 0) assert.match(result.stderr, /total output size exceeded/);
    else assert.equal(result.stderr, '');
  }
});

test('私有 sink 限定固定 bash/sh 入口，拒绝绕过入口的输出重定向', async () => {
  const bash = new Bash({ defenseInDepth: false });
  let calls = 0;
  await assert.rejects(bash.exec('bash -c "printf secret" > captured', {
    ohosStatementOutput: async () => { calls++; },
  }), /literal bash\/sh entry/);
  assert.equal(calls, 0);
});

test('二进制字节和 UTF-8 分段后仍精确，2>&1 与单独 stderr 保持各自通道', async t => {
  const f = await fixture(t);
  await writeFile(join(f.work, 'bytes'), Buffer.from([0, 255, 195, 169, 0, 128]));
  const result = await f.run('cat bytes; printf "中文"; cat bytes 缺失文件 2>&1; printf "独立错\\n" >&2');
  assert.equal(result.exitCode, 0);
  assert.deepEqual(result.stdout, Buffer.concat([
    Buffer.from([0, 255, 195, 169, 0, 128]), Buffer.from('中文'),
    Buffer.from([0, 255, 195, 169, 0, 128]), Buffer.from('cat: 缺失文件: No such file or directory\n'),
  ]));
  assert.equal(result.stderr.toString(), '独立错\n');
});

test('跨语句拆开的 UTF-8 字节在原始管道和最终收集结果中保留', async t => {
  const f = await fixture(t);
  await writeFile(join(f.work, 'head'), Buffer.from([0xe4, 0xb8]));
  await writeFile(join(f.work, 'tail'), Buffer.from([0xad]));
  const raw = await f.run('cat head; sleep 0.01; cat tail');
  assert.equal(raw.exitCode, 0);
  assert.deepEqual(raw.stdout, Buffer.from('中'));
  const handle = f.spawn(['bash', '-c', 'cat head; sleep 0.01; cat tail'], {
    stdio: { stdin: 'ignore', stdout: { maxBytes: 100 }, stderr: { maxBytes: 100 } },
  });
  assert.equal((await handle.done).exitCode, 0);
  assert.deepEqual(handle.collected.stdout.readFrom(0), { text: '中', nextOffset: 3, lossy: false });
});

test('退出与 errexit 在已交付前缀之后只交付未发尾部', async t => {
  const f = await fixture(t);
  for (const [script, code, stdout, stderr] of [
    ['printf prefix; printf err >&2; exit 7; printf forbidden', 7, 'prefix', 'err'],
    ['printf prefix; set -e; false; printf forbidden', 1, 'prefix', ''],
    ['printf prefix; eval "printf nested; exit 9"; printf forbidden', 9, 'prefixnested', ''],
  ]) {
    const result = await f.run(script);
    assert.equal(result.exitCode, code, script);
    assert.equal(result.stdout.toString(), stdout, script);
    assert.equal(result.stderr.toString(), stderr, script);
  }
});

test('外层复合语句内部继续缓冲，不把循环内部输出当作已交付', async t => {
  const f = await fixture(t);
  const handle = f.spawn(['bash', '-c', 'printf before; for x in 1 2; do printf "$x"; sleep 0.03; done; printf after']);
  const chunks = [];
  handle.stdout.on('data', data => chunks.push(Buffer.from(data).toString()));
  const [outcome, stdout, stderr] = await Promise.all([handle.done, collect(handle.stdout), collect(handle.stderr)]);
  assert.equal(outcome.exitCode, 0);
  assert.equal(stdout.toString(), 'before12after');
  assert.equal(stderr.length, 0);
  assert(chunks.includes('12'), JSON.stringify(chunks));
  assert(!chunks.includes('1') && !chunks.includes('2'), JSON.stringify(chunks));
});

test('已观察首块后硬取消同步循环，保留前缀并在实际退出之后放行队列', { timeout: 15000 }, async t => {
  const f = await fixture(t);
  const first = Promise.withResolvers();
  const handle = f.spawn(['bash', '-c', 'printf retained; while true; do :; done; printf forbidden > forbidden']);
  handle.stdout.once('data', data => first.resolve(Buffer.from(data)));
  const output = collect(handle.stdout), errors = collect(handle.stderr);
  const next = f.spawn(['bash', '-c', 'printf next > next; printf successor']);
  const nextOutput = collect(next.stdout), nextError = collect(next.stderr);
  assert.equal((await first.promise).toString(), 'retained');
  assert.equal(await readFile(join(f.work, 'next')).then(() => true, error => { assert.equal(error.code, 'ENOENT'); return false; }), false);
  handle.terminate();
  assert.equal(await handle.waitForExit(), true);
  assert.deepEqual(await handle.done, { exitCode: null, signal: 'SIGTERM' });
  assert.equal((await output).toString(), 'retained');
  assert.equal((await errors).length, 0);
  assert.equal((await next.done).exitCode, 0);
  assert.equal((await nextOutput).toString(), 'successor');
  assert.equal((await nextError).length, 0);
  assert.equal(await readFile(join(f.work, 'next'), 'utf8'), 'next');
  assert.equal(await readFile(join(f.work, 'forbidden')).then(() => true, error => { assert.equal(error.code, 'ENOENT'); return false; }), false);
});

test('dispose 在硬取消完成后精确删除自有临时根，已提交工作区文件保留', { timeout: 15000 }, async t => {
  const f = await fixture(t, true);
  const ownRoot = f.runtime.temporaryRoot;
  const first = Promise.withResolvers();
  const handle = f.spawn(['bash', '-c', 'printf committed > keep; printf scratch > "$TMPDIR/scratch"; printf ready; while true; do :; done']);
  handle.stdout.once('data', () => first.resolve());
  const output = collect(handle.stdout), errors = collect(handle.stderr);
  await first.promise;
  await f.runtime.dispose();
  assert.equal(await handle.waitForExit(), true);
  assert.equal((await handle.done).signal, 'SIGTERM');
  assert.equal((await output).toString(), 'ready');
  assert.equal((await errors).length, 0);
  assert.equal(await readFile(join(f.work, 'keep'), 'utf8'), 'committed');
  assert.equal(await readFile(join(ownRoot, 'scratch')).then(() => true, error => { assert.equal(error.code, 'ENOENT'); return false; }), false);
});
