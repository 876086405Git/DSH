import { symlinkFixture } from './host-link-fixture.mjs';
import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';

let base, work, temp, outside, runtime;
before(async () => {
  base = await fs.mkdtemp(join(tmpdir(), 'ohos-process-test-'));
  [work, temp, outside] = ['工作区', '临时', '外部'].map(name => join(base, name));
  await Promise.all([work, temp, outside].map(path => fs.mkdir(path)));
  runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot: temp });
});
after(async () => {
  await runtime?.dispose();
  await fs.rm(base, { recursive: true, force: true });
});

function spawn(argv, extra = {}) {
  return runtime.spawn({ argv, cwd: work, stdio: { stdin: 'ignore', stdout: { maxBytes: 65536 }, stderr: { maxBytes: 65536 } }, graceMs: 200, ...extra });
}
async function run(argv, extra) {
  const handle = spawn(argv, extra);
  const outcome = await handle.done;
  return { ...outcome, stdout: handle.collected.stdout.readFrom(0).text, stderr: handle.collected.stderr.readFrom(0).text, handle };
}

test('原生全局构造器和子进程入口不由虚拟后端改写', async () => {
  const cp = await import('node:child_process');
  const original = cp.spawn;
  const constructors = [Request, Response, Headers, FormData];
  await run(['bash', '-c', 'true']);
  assert.equal(cp.spawn, original);
  assert.deepEqual([Request, Response, Headers, FormData], constructors);
});

test('真实中文文件、管道、重定向、变量和退出码', async () => {
  const result = await run(['bash', '-c', 'printf "甲\\n乙\\n" > "中文 文件.txt"; cat "中文 文件.txt" | grep 乙; echo err >&2; exit 7']);
  assert.equal(result.exitCode, 7);
  assert.equal(result.stdout, '乙\n');
  assert.equal(result.stderr, 'err\n');
  assert.equal(await fs.readFile(join(work, '中文 文件.txt'), 'utf8'), '甲\n乙\n');
});

test('sh -c 的 argv 不做第二次插值，stdin 是批量字节', async () => {
  const result = await run(['sh', '-c', 'printf "%s\\n" "$1"; cat', 'zero', '$(echo UNSAFE)'], {
    stdio: { stdin: { data: '输入中文\n' }, stdout: { maxBytes: 65536 }, stderr: { maxBytes: 65536 } },
  });
  assert.equal(result.exitCode, 0);
  assert.equal(result.stdout, '$(echo UNSAFE)\n输入中文\n');
});

test('环境复用原有 scrub 规则并保留显式值与删除标记', async () => {
  const names = ['OHOS_TEST_SECRET', 'DSH_TEST_ID', 'OHOS_TEST_NORMAL'];
  const prior = Object.fromEntries(names.map(name => [name, process.env[name]]));
  process.env.OHOS_TEST_SECRET = 'ambient-sensitive';
  process.env.DSH_TEST_ID = 'ambient-identity';
  process.env.OHOS_TEST_NORMAL = 'remove-me';
  try {
    const result = await run(['bash', '-c', 'printf "%s|%s|%s|%s" "$OHOS_TEST_SECRET" "$DSH_TEST_ID" "$OHOS_TEST_NORMAL" "$EXPLICIT_TOKEN"'], { env: { OHOS_TEST_NORMAL: undefined, EXPLICIT_TOKEN: 'explicit' } });
    assert.equal(result.stdout, '|||explicit');
  } finally {
    for (const name of names) if (prior[name] === undefined) delete process.env[name]; else process.env[name] = prior[name];
  }
});

test('直接和上级越界读写均拒绝；外部文件保持原内容', async () => {
  const secret = join(outside, 'secret');
  await fs.writeFile(secret, 'outside');
  for (const command of [`cat '${secret}'`, `printf changed > '${secret}'`, "printf changed > '../外部/secret'", 'printf fake > /not-mounted']) {
    const result = await run(['bash', '-c', command]);
    assert.notEqual(result.exitCode, 0, command);
    assert.match(result.stderr, /EACCES|denied|No such file/i);
  }
  assert.equal(await fs.readFile(secret, 'utf8'), 'outside');
});

test('预植符号链接越界不能读写，内部符号链接正常', async () => {
  await symlinkFixture(outside, join(work, 'escape'));
  await fs.writeFile(join(work, 'inside'), 'inside');
  await symlinkFixture('inside', join(work, 'safe-link'));
  const internal = await run(['bash', '-c', 'cat safe-link']);
  assert.equal(internal.stdout, 'inside');
  for (const command of ['cat escape/secret', 'echo changed > escape/secret', 'mkdir escape/new-dir']) {
    const result = await run(['bash', '-c', command]);
    assert.notEqual(result.exitCode, 0, command);
  }
  assert.equal(await fs.readFile(join(outside, 'secret'), 'utf8'), 'outside');
  assert.equal(await fs.stat(join(outside, 'new-dir')).then(() => true, () => false), false);
});

test('合法临时目录可写，未挂载的 /tmp 路径拒绝', async () => {
  const result = await run(['bash', '-c', 'echo temp > "$TMPDIR/file"; cat "$TMPDIR/file"']);
  assert.equal(result.stdout, 'temp\n');
  assert.equal(await fs.readFile(join(temp, 'file'), 'utf8'), 'temp\n');
  const denied = await run(['bash', '-c', 'echo bad > /tmp/unscoped-ohos-file']);
  assert.notEqual(denied.exitCode, 0);
});

test('已abort不运行，取消等待与等待退出分开', async () => {
  const signal = AbortSignal.abort();
  assert.throws(() => spawn(['bash', '-c', 'echo late > forbidden'], { signal }), /aborted before spawn/);
  for (const graceMs of [0, -1, Infinity, 2147483648]) assert.throws(() => spawn(['bash', '-c', 'true'], { graceMs }), /subprocess graceMs/);
  assert.equal(await fs.stat(join(work, 'forbidden')).then(() => true, () => false), false);
  const handle = spawn(['bash', '-c', 'sleep 30; echo late > forbidden']);
  assert.equal(await handle.waitForExit(AbortSignal.abort()), false);
  handle.terminate();
  assert.equal(await handle.waitForExit(), true);
  assert.equal((await handle.done).signal, 'SIGTERM');
});

test('运行中的worker在取消后退出，之后无排队写入', async () => {
  const controller = new AbortController();
  const handle = spawn(['bash', '-c', 'echo ready > ready; sleep 30; echo late > late'], { signal: controller.signal });
  const deadline = Date.now() + 5000;
  while (!await fs.stat(join(work, 'ready')).then(() => true, () => false)) {
    assert.ok(Date.now() < deadline, 'worker did not reach ready point');
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  controller.abort();
  assert.equal((await handle.done).signal, 'SIGTERM');
  assert.equal(await handle.waitForExit(), true);
  await new Promise(resolve => setTimeout(resolve, 80));
  assert.equal(await fs.stat(join(work, 'late')).then(() => true, () => false), false);
});

test('原 OutputCollector 保留尾部、完整spill及独立偏移读取', async () => {
  const handle = spawn(['bash', '-c', 'printf 0123456789ABCDEFGHIJ'], {
    stdio: { stdin: 'ignore', stdout: { maxBytes: 8, spill: { maxBytes: 100 } }, stderr: { maxBytes: 8 } },
  });
  await handle.done;
  const first = handle.collected.stdout.readFrom(0);
  assert.equal(first.text, 'CDEFGHIJ');
  assert.equal(first.lossy, true);
  assert.equal(first.nextOffset, 20);
  assert.equal(await fs.readFile(first.spillPath, 'utf8'), '0123456789ABCDEFGHIJ');
  assert.deepEqual(handle.collected.stdout.readFrom(0), first);
  assert.equal(handle.collected.stdout.readFrom(17).text, 'HIJ');
});

test('超过spill cap不宣传不完整文件', async () => {
  const result = await run(['bash', '-c', 'printf 01234567890123456789'], {
    stdio: { stdin: 'ignore', stdout: { maxBytes: 4, spill: { maxBytes: 10 } }, stderr: { maxBytes: 8 } },
  });
  const read = result.handle.collected.stdout.readFrom(0);
  assert.equal(read.text, '6789');
  assert.equal(read.lossy, true);
  assert.equal(read.spillPath, undefined);
});

test('原始输出pipe延后消费时仍完整交付大于高水位的stdout与stderr', async () => {
  const out = '中'.repeat(200000), err = 'e'.repeat(200000);
  await fs.writeFile(join(work, 'large-out'), out);
  await fs.writeFile(join(work, 'large-err'), err);
  const handle = spawn(['bash', '-c', 'cat large-out; cat large-err >&2'], {
    stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' },
  });
  await new Promise(resolve => setTimeout(resolve, 300));
  const consume = async stream => {
    const chunks = [];
    for await (const chunk of stream) chunks.push(chunk);
    return Buffer.concat(chunks).toString('utf8');
  };
  const [stdout, stderr, outcome] = await Promise.all([consume(handle.stdout), consume(handle.stderr), handle.done]);
  assert.equal(outcome.exitCode, 0);
  assert.equal(stdout, out);
  assert.equal(stderr, err);
});

test('伪造绝对可执行文件路径不会按basename执行', async () => {
  for (const command of ['/unapproved/bash', './rg']) {
    const result = await run([command, '-c', 'echo wrong > alias-bypass']);
    assert.equal(result.exitCode, 127);
  }
  assert.equal(await fs.stat(join(work, 'alias-bypass')).then(() => true, () => false), false);
});

test('未知命令返回127与中文替代路径；不加载Python/SQLite/WASM', async () => {
  for (const command of ['apt-get', 'python', 'sqlite3']) {
    const direct = await run([command, '--help']);
    assert.equal(direct.exitCode, 127);
    assert.match(direct.stderr, /这个命令在鸿蒙本机不可用，可以连接电脑执行/);
    const shell = await run(['bash', '-c', `${command} --help`]);
    assert.equal(shell.exitCode, 127);
  }
  assert.ok(!runtime.capabilities.commands.includes('sqlite3'));
});

test('交互stdin/control显式拒绝，不假装是可用协议通道', async () => {
  for (const changes of [{ stdin: 'pipe' }, { control: 'pipe' }]) {
    const handle = spawn(['bash', '-c', 'cat'], { stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe', ...changes } });
    await assert.rejects(handle.done, { code: 'ERR_OHOS_STREAM_UNAVAILABLE' });
    assert.equal(await handle.waitForExit(), true);
  }
});

test('DSH grep固定argv得到大小写敏感的NDJSON', async () => {
  await fs.writeFile(join(work, 'case.txt'), 'ABC\nabc\n中文abc\n');
  const result = await run(['rg', '--no-config', '--json', '--regexp=abc', '--', 'case.txt']);
  assert.equal(result.exitCode, 0, result.stderr);
  const matches = result.stdout.trim().split('\n').map(JSON.parse).filter(record => record.type === 'match');
  assert.deepEqual(matches.map(record => [record.data.path.text, record.data.line_number, record.data.lines.text]), [
    ['case.txt', 2, 'abc\n'], ['case.txt', 3, '中文abc\n'],
  ]);
  assert.equal((await run(['rg', '--no-config', '--json', '--regexp=not-found'])).exitCode, 1);
  const invalid = await run(['rg', '--no-config', '--json', '--regexp=[']);
  assert.equal(invalid.exitCode, 2);
  assert.match(invalid.stderr, /regex parse error/);
});

test('rg的中文JSON使用UTF-8字节偏移并保留末行无LF', async () => {
  await fs.writeFile(join(work, 'json-offset.txt'), '第一行\n中文abc\r\n中文abc');
  const result = await run(['rg', '--no-config', '--json', '--regexp=abc', '--', 'json-offset.txt']);
  assert.equal(result.exitCode, 0, result.stderr);
  const records = result.stdout.trim().split('\n').map(JSON.parse);
  assert.deepEqual(records.map(({ data }) => [data.line_number, data.absolute_offset, data.lines.text, data.submatches[0].start, data.submatches[0].end]), [
    [2, 10, '中文abc\r\n', 6, 9], [3, 21, '中文abc', 6, 9],
  ]);
});

test('rg开头单一内联大小写标志不被默认case-sensitive吞掉', async () => {
  await fs.writeFile(join(work, 'inline-case.txt'), 'ABC\nabc\n');
  const result = await run(['rg', '--json', '--regexp=(?i)abc', '--', 'inline-case.txt']);
  assert.equal(result.exitCode, 0, result.stderr);
  assert.deepEqual(result.stdout.trim().split('\n').map(JSON.parse).map(record => record.data.line_number), [1, 2]);
});

test('rg零宽UTF-8匹配覆盖每个字节坐标、CRLF及无LF末行', async () => {
  const lines = ['😀中abc\r\n', '\n', '中abc'];
  await fs.writeFile(join(work, 'zero-byte.txt'), lines.join(''));
  for (const pattern of ['^', '$', '']) {
    const result = await run(['rg', '--json', `--regexp=${pattern}`, '--', 'zero-byte.txt']);
    assert.equal(result.exitCode, 0, result.stderr);
    const records = result.stdout.trim().split('\n').map(JSON.parse);
    assert.deepEqual(records.map(record => record.data.lines.text), lines);
    for (let index = 0; index < lines.length; index++) {
      const bytes = Buffer.byteLength(lines[index].replace(/\n$/, ''));
      const expected = pattern === '^' ? [0] : pattern === '$' ? (index === 2 ? [] : [bytes]) : Array.from({ length: bytes + (index === 2 ? 0 : 1) }, (_, index) => index);
      assert.deepEqual(records[index].data.submatches.map(match => match.start), expected);
      assert.ok(records[index].data.submatches.every(match => match.start === match.end && match.match.text === ''));
    }
  }
});

test('rg非JSON新语义和未实现的files复杂glob仍明确拒绝', async () => {
  for (const args of [
    ['--regexp=abc', '--glob=*.txt'],
    ['--regexp=\\w+', '--', 'case.txt'],
    ['--files', '--glob=**/*.txt', '--no-ignore', '--hidden'],
    ['--json', '--regexp=(?i:abc)', '--', 'case.txt'],
  ]) {
    const result = await run(['rg', ...args]);
    assert.equal(result.exitCode, 2);
    assert.match(result.stderr, /鸿蒙本机尚不支持.*可以连接电脑执行/);
    assert.equal(result.stdout, '');
  }
});

test('rg默认二进制搜索明确拒绝，显式--text仍可读NUL正文', async () => {
  await fs.writeFile(join(work, 'nul.txt'), 'abc\0tail\n');
  const args = ['--json', '--regexp=abc', '--', 'nul.txt'];
  assert.equal((await run(['rg', ...args])).exitCode, 2);
  const result = await run(['rg', '--text', ...args]);
  assert.equal(result.exitCode, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).data.lines.text, 'abc\0tail\n');
});

test('rg的--之后与选项同名的路径不改变解析模式', async () => {
  for (const path of ['--files', '-F']) {
    await fs.writeFile(join(work, path), 'abc\n');
    const result = await run(['rg', '--json', '--regexp=abc', '--', path]);
    assert.equal(result.exitCode, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout).type, 'match');
    assert.equal(JSON.parse(result.stdout).data.lines.text, 'abc\n');
  }
});

test('DSH glob固定argv覆盖隐藏和忽略文件，按mtime排序，排除VCS', async () => {
  const dir = join(work, 'glob-fixture');
  await fs.mkdir(join(dir, '.git'), { recursive: true });
  await fs.writeFile(join(dir, '.git', 'secret.txt'), 'x');
  await fs.writeFile(join(dir, 'old.txt'), 'x');
  await fs.writeFile(join(dir, '.new.txt'), 'x');
  await fs.writeFile(join(dir, '.gitignore'), '*.txt\n');
  await fs.utimes(join(dir, 'old.txt'), 100, 100);
  await fs.utimes(join(dir, '.new.txt'), 200, 200);
  const result = await run(['rg', '--no-config', '--files', '--glob=*.txt', '--sort=modified', '--no-ignore', '--hidden', '--glob=!**/.git', '--glob=!**/.git/**', '--', 'glob-fixture']);
  assert.equal(result.exitCode, 0, result.stderr);
  assert.deepEqual(result.stdout.trim().split('\n'), ['glob-fixture/old.txt', 'glob-fixture/.new.txt']);
});

test('dispose取消运行与排队任务并等待全部线程退出', async () => {
  const separate = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot: temp });
  const spec = { argv: ['bash', '-c', 'sleep 30'], cwd: work, stdio: { stdin: 'ignore', stdout: { maxBytes: 8 }, stderr: { maxBytes: 8 } }, graceMs: 50 };
  const handles = [separate.spawn(spec), separate.spawn(spec)];
  await new Promise(resolve => setTimeout(resolve, 40));
  await separate.dispose();
  for (const handle of handles) {
    assert.equal(await handle.waitForExit(), true);
    assert.equal((await handle.done).signal, 'SIGTERM');
  }
  assert.equal(separate.live.size, 0);
});
