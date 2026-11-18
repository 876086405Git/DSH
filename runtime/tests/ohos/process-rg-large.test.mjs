import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
const processRoot = process.env.M4_PROCESS_ROOT
  ? pathToFileURL(resolve(process.env.M4_PROCESS_ROOT) + '/')
  : new URL('../../ohos/process/', import.meta.url);
const { executeRg } = await import(new URL('rg.mjs', processRoot));
const { createFilesystem } = await import(new URL('filesystem.mjs', processRoot));
const { VirtualSubprocessRuntime } = await import(new URL('runtime.mjs', processRoot));
assert.ok(process.env.OHOS_TEST_PROCESS_PREFIX, '需要固定的 OHOS DSH prefix');
const require = createRequire(join(resolve(process.env.OHOS_TEST_PROCESS_PREFIX), 'package.json'));
const search = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-tool-fs-search')));
const { Session } = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-session')));
const limit = 4 * 1024 * 1024, outputLimit = 64 * 1024 * 1024;
let root, work, temp, runtime, filesystem;
before(async () => {
  root = await mkdtemp(join(tmpdir(), 'ohos-rg-large-test-'));
  work = join(root, 'work'); temp = join(root, 'temp');
  await mkdir(work); await mkdir(temp);
  runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot: temp });
  filesystem = createFilesystem([work, temp]); filesystem.seal();
});
after(async () => { await runtime?.dispose(); await rm(root, { recursive: true, force: true }); });
const matches = text => text.trim().split('\n').filter(Boolean).map(JSON.parse).map(record => record.data);
async function direct(args, { paddedView = false } = {}) {
  const reads = [];
  const fs = new Proxy(filesystem.fs, { get(target, key) {
    const value = target[key];
    if (typeof value !== 'function') return value;
    return async (...args) => {
      if (key === 'readFileBuffer') {
        reads.push(args[0]);
        const bytes = await value.apply(target, args);
        if (!paddedView) return bytes;
        const padded = new Uint8Array(bytes.length + 11).fill(0xff);
        padded.set(bytes, 5);
        return padded.subarray(5, 5 + bytes.length);
      }
      return value.apply(target, args);
    };
  } });
  // resolvePath is synchronous in IFileSystem; preserve that public contract.
  const counted = new Proxy(fs, { get(target, key) { return key === 'resolvePath' ? filesystem.fs.resolvePath : target[key]; } });
  const result = await executeRg(args, { fs: counted, cwd: work, limits: { maxArrayElements: 1000000, maxOutputSize: outputLimit, maxGlobOperations: 1000000 }, origCommand: () => { throw new Error('unexpected origCommand'); } });
  return { ...result, reads: reads.map(path => path.slice(work.length + 1)) };
}
async function worker(args) {
  const handle = runtime.spawn({ argv: ['rg', ...args], cwd: work, graceMs: 100, stdio: { stdin: 'ignore', stdout: { maxBytes: outputLimit }, stderr: { maxBytes: 1024 * 1024 } } });
  const timer = setTimeout(() => handle.terminate(), 30000);
  const done = await handle.done.finally(() => clearTimeout(timer));
  assert.equal(done.signal, null, '必须由 rg 正常结束，不能把超时/worker 崩溃当作 exit 2');
  assert.equal(runtime.live.size, 0);
  return { ...done, stdout: handle.collected.stdout.readFrom(0).text, stderr: handle.collected.stderr.readFrom(0).text };
}

test('每个显式 JSON 文本文件只从真实受限 FS 读取一次', async () => {
  await writeFile(join(work, 'one.txt'), 'abc\n'); await writeFile(join(work, 'two.txt'), 'abc\n');
  const result = await direct(['--json', '--regexp=abc', '--', 'one.txt', 'two.txt']);
  assert.equal(result.exitCode, 0, result.stderr);
  assert.deepEqual(result.reads, ['one.txt', 'two.txt']);
  assert.equal(matches(result.stdout).length, 2);
});

test('默认显式二进制仍明确 exit 2，--text 单次读取并保留 NUL', async () => {
  await writeFile(join(work, 'binary.txt'), 'abc\0tail\n');
  const args = ['--json', '--regexp=abc', '--', 'binary.txt'];
  const binary = await direct(args);
  assert.equal(binary.exitCode, 2); assert.match(binary.stderr, /默认二进制/); assert.equal(binary.stdout, '');
  assert.deepEqual(binary.reads, ['binary.txt']);
  const text = await direct(['--text', ...args]);
  assert.equal(text.exitCode, 0, text.stderr); assert.deepEqual(text.reads, ['binary.txt']);
  assert.equal(matches(text.stdout)[0].lines.text, 'abc\0tail\n');
});

test('目录选择的二进制仍跳过，普通文件各读取一次', async () => {
  await mkdir(join(work, 'directory'));
  await writeFile(join(work, 'directory/a.txt'), 'abc\n'); await writeFile(join(work, 'directory/b.txt'), 'abc\0\n');
  const result = await direct(['--json', '--regexp=abc', '--', 'directory']);
  assert.equal(result.exitCode, 0, result.stderr);
  assert.deepEqual(result.reads.sort(), ['directory/a.txt', 'directory/b.txt']);
  assert.deepEqual(matches(result.stdout).map(item => item.path.text), ['directory/a.txt']);
});

test('非零 byteOffset 的 Uint8Array 保留 UTF-8、BOM、CRLF 与字节坐标', async () => {
  await writeFile(join(work, 'view.txt'), '\uFEFF中\uFEFFé\r\n😀\uFEFFé');
  const result = await direct(['--json', '--regexp=\uFEFFé', '--', 'view.txt'], { paddedView: true });
  assert.equal(result.exitCode, 0, result.stderr); assert.deepEqual(result.reads, ['view.txt']);
  assert.deepEqual(matches(result.stdout), [
    { path: { text: 'view.txt' }, lines: { text: '中\uFEFFé\r\n' }, line_number: 1, absolute_offset: 0, submatches: [{ match: { text: '\uFEFFé' }, start: 3, end: 8 }] },
    { path: { text: 'view.txt' }, lines: { text: '😀\uFEFFé' }, line_number: 2, absolute_offset: 10, submatches: [{ match: { text: '\uFEFFé' }, start: 4, end: 9 }] },
  ]);
});

test('非法 UTF-8 保持 exit 2，不能被替换字符静默搜索', async () => {
  for (const [index, bytes] of [[0x80], [0xc0, 0xaf], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80]].entries()) {
    const path = `invalid-${index}.txt`; await writeFile(join(work, path), Buffer.from(bytes));
    const result = await direct(['--json', '--regexp=.', '--', path]);
    assert.equal(result.exitCode, 2); assert.match(result.stderr, /非 UTF-8/); assert.equal(result.stdout, '');
    assert.deepEqual(result.reads, [path]);
  }
});

test('48 MiB 单行同一反例返回 exit 2，随后 worker 任务仍可正常运行', async () => {
  const path = join(work, 'huge.txt');
  const input = Buffer.alloc(48 * 1024 * 1024, 0x61);
  assert.equal(createHash('sha256').update(input).digest('hex'), 'fcaf3b489c7a30d4914c93ef4cb4cb7e5e59acd52a68285effc8ab9f1d793d92');
  await writeFile(path, input);
  try {
    const result = await worker(['--json', '--regexp=z', '--', 'huge.txt']);
    assert.equal(result.exitCode, 2); assert.equal(result.stdout, '');
    assert.match(result.stderr, /4194304.*50331648/);
    const next = await worker(['--json', '--regexp=abc', '--', 'one.txt']);
    assert.equal(next.exitCode, 0, next.stderr);
  } finally { await rm(path, { force: true }); }
});

test('恰好 4 MiB 的命中行完整返回，输出预算仍为 64 MiB', async () => {
  const text = 'a'.repeat(limit); await writeFile(join(work, 'at-limit.txt'), text);
  const result = await worker(['--json', '--regexp=^a', '--', 'at-limit.txt']);
  assert.equal(result.exitCode, 0, result.stderr);
  const [item] = matches(result.stdout);
  assert.equal(item.lines.text, text); assert.equal(item.absolute_offset, 0);
  assert.deepEqual(item.submatches, [{ match: { text: 'a' }, start: 0, end: 1 }]);
});

test('超过预算一字节的未命中行也是 exit 2，不能伪装 noMatches', async () => {
  await writeFile(join(work, 'over-limit.txt'), 'a'.repeat(limit + 1));
  const result = await worker(['--json', '--regexp=z', '--', 'over-limit.txt']);
  assert.equal(result.exitCode, 2); assert.equal(result.stdout, ''); assert.match(result.stderr, /4194305/);
});

test('行预算排除 LF 与文件首 BOM，包含 CR；后续超长行不输出半份结果', async () => {
  await writeFile(join(work, 'crlf.txt'), '\uFEFF' + 'a'.repeat(limit - 1) + '\r\n');
  const accepted = await worker(['--json', '--regexp=^a', '--', 'crlf.txt']);
  assert.equal(accepted.exitCode, 0, accepted.stderr);
  assert.equal(Buffer.byteLength(matches(accepted.stdout)[0].lines.text), limit + 1);
  await writeFile(join(work, 'crlf.txt'), '\uFEFFabc\n' + 'a'.repeat(limit) + '\r\n');
  const rejected = await worker(['--json', '--regexp=a', '--', 'crlf.txt']);
  assert.equal(rejected.exitCode, 2); assert.equal(rejected.stdout, '');
  assert.match(rejected.stderr, /第 2 行为 4194305 字节/);
});

test('字节预算不按 Unicode 字符数计量', async () => {
  const text = '中'.repeat(Math.floor(limit / 3)) + 'a';
  assert.equal(Buffer.byteLength(text), limit);
  await writeFile(join(work, 'unicode-limit.txt'), text);
  const result = await worker(['--json', '--regexp=^中', '--', 'unicode-limit.txt']);
  assert.equal(result.exitCode, 0, result.stderr);
  const [item] = matches(result.stdout); assert.equal(item.lines.text, text);
  assert.deepEqual(item.submatches, [{ match: { text: '中' }, start: 0, end: 3 }]);
});

test('超过 4 MiB 的整个文件仍可搜索，只限制单行而非文件或输出', async () => {
  const line = 'a'.repeat(2 * 1024 * 1024) + '\n';
  await writeFile(join(work, 'many-lines.txt'), line.repeat(3));
  const result = await worker(['--json', '--regexp=^a', '--', 'many-lines.txt']);
  assert.equal(result.exitCode, 0, result.stderr);
  assert.ok(Buffer.byteLength(result.stdout) > limit);
  const records = matches(result.stdout); assert.equal(records.length, 3);
  assert.deepEqual(records.map(item => item.absolute_offset), [0, line.length, line.length * 2]);
  assert.ok(records.every(item => item.lines.text === line));
});

test('真实 DSH 把超行预算传播为 SEARCH_FAILED', async () => {
  const context = { subprocess: runtime, workingDirectory: { ensure: async () => work } };
  const id = 'm4-4a-large-file-session';
  const session = Session.create(id, undefined, { version: 4, id, createdAt: Date.now(), isSeeded: false, cwd: work });
  await assert.rejects(search.runRipgrep(context, { agent: { session }, signal: new AbortController().signal }, 'grep', search.buildGrepCommand({ pattern: 'z', path: 'over-limit.txt' }), outputLimit, 200, 10000), error => {
    assert.equal(error.code, 'SEARCH_FAILED');
    assert.match(error.message, /4194304/);
    return true;
  });
});
