import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import OhSubprocessRuntime from '../../ohos/process/index.mjs';

assert.ok(process.env.OHOS_TEST_PROCESS_PREFIX, '需指定单独打过 ohos-virtual-process.diff 的前缀');
const require = createRequire(join(resolve(process.env.OHOS_TEST_PROCESS_PREFIX), 'package.json'));
const load = name => import(pathToFileURL(require.resolve(name)));
const { Context } = await load('@deepseek-ai/cordis');
const { LocalBashExecutor } = await load('@deepseek-ai/dsh-bash-local');
const { Session } = await load('@deepseek-ai/dsh-session');
const search = await load('@deepseek-ai/dsh-tool-fs-search');
let root, work, temp, ctx;
let searchSequence = 0;
function searchAgent() {
  const id = `ohos-search-fixture-${++searchSequence}`;
  return { session: Session.create(id, undefined, { version: 4, id, createdAt: Date.now(), isSeeded: false, cwd: work }) };
}
before(async () => {
  root = await mkdtemp(join(tmpdir(), 'ohos-service-test-'));
  work = join(root, '工作区'); temp = join(root, 'temp');
  await Promise.all([mkdir(work), mkdir(temp)]);
  ctx = new Context();
  await ctx.plugin(OhSubprocessRuntime, { workspaceRoots: [work], temporaryRoot: temp });
  await ctx.plugin(LocalBashExecutor, { cwd: work, timeoutMs: 15000, maxTimeoutMs: 30000, maxOutputBytes: 65536, maxSpillBytes: 1048576, graceMs: 200 });
});
after(async () => {
  await ctx?.fiber.dispose();
  await rm(root, { recursive: true, force: true });
});

test('真实Cordis注册ctx.subprocess，原LocalBashExecutor执行并保留状态与输出', async () => {
  assert.equal(ctx.subprocess.capabilities.kind, 'virtual');
  const execution = await ctx.shell.execute(ctx.shell.resolve({ command: 'echo hello > 文件.txt; cat 文件.txt; exit 4' }));
  const result = await execution.result();
  assert.equal(result.exitCode, 4);
  assert.equal(result.stdout.text, 'hello\n');
  assert.equal(result.aborted, false);
  assert.equal(result.timedOut, false);
  assert.equal(execution.status, 'completed');
  assert.equal(await readFile(join(work, '文件.txt'), 'utf8'), 'hello\n');
});

test('原bash deadline负责超时分类，返回时worker已退出', async () => {
  const execution = await ctx.shell.execute(ctx.shell.resolve({ command: 'sleep 30; echo late > forbidden', timeoutMs: 120 }));
  const result = await execution.result();
  assert.equal(result.timedOut, true);
  assert.equal(result.aborted, false);
  assert.equal(result.exitCode, null);
  assert.equal(execution.status, 'killed');
  assert.equal(ctx.subprocess.backend.live.size, 0);
});

test('原bash caller取消与timeout分类不同', async () => {
  const controller = new AbortController();
  const execution = await ctx.shell.execute(ctx.shell.resolve({ command: 'sleep 30', signal: controller.signal }));
  controller.abort(new Error('cancel fixture'));
  const result = await execution.result();
  assert.equal(result.timedOut, false);
  assert.equal(result.aborted, true);
  assert.equal(result.exitCode, null);
});

test('锁定DSH真实buildGrepCommand/runRipgrep/parseGrepMatches通过虚拟rg', async () => {
  await writeFile(join(work, '搜索.txt'), 'ABC\nabc\n中文abc\n');
  const exec = { agent: searchAgent(), signal: new AbortController().signal };
  const context = { subprocess: ctx.subprocess, workingDirectory: { ensure: async () => work } };
  const result = await search.runRipgrep(context, exec, 'grep', search.buildGrepCommand({ pattern: 'abc', path: '搜索.txt' }), 10000, 200, 1000);
  assert.deepEqual(search.parseGrepMatches(result.stdout), [
    { path: '搜索.txt', lineNumber: 2, line: 'abc' },
    { path: '搜索.txt', lineNumber: 3, line: '中文abc' },
  ]);
  assert.equal(result.noMatches, false);
});

test('锁定DSH真实glob模板保留以短横开头的字面路径', async () => {
  await mkdir(join(work, '-leading'));
  await writeFile(join(work, '-leading', 'a.txt'), 'text');
  const context = { subprocess: ctx.subprocess, workingDirectory: { ensure: async () => work } };
  const result = await search.runRipgrep(context, { agent: searchAgent(), signal: new AbortController().signal }, 'glob', search.buildGlobCommand({ pattern: '*.txt', path: '-leading' }), 10000, 200, 1000);
  assert.equal(result.noMatches, false);
  const paths = result.stdout.trim().split('\n').map(path => search.toWorkdirRelative(path, work));
  assert.deepEqual(paths, ['-leading/a.txt']);
});

test('无效regex经DSH原错误分类成为SEARCH_INVALID_PATTERN', async () => {
  const context = { subprocess: ctx.subprocess, workingDirectory: { ensure: async () => work } };
  await assert.rejects(search.runRipgrep(context, { agent: searchAgent(), signal: new AbortController().signal }, 'grep', search.buildGrepCommand({ pattern: '[' }), 10000, 200, 1000), { code: 'SEARCH_INVALID_PATTERN' });
});

test('真实DSH把缺失搜索路径作为SEARCH_FAILED，不能伪装noMatches', async () => {
  const context = { subprocess: ctx.subprocess, workingDirectory: { ensure: async () => work } };
  for (const path of ['missing.txt', 'missing/']) {
    await assert.rejects(search.runRipgrep(context, { agent: searchAgent(), signal: new AbortController().signal }, 'grep', search.buildGrepCommand({ pattern: 'abc', path }), 10000, 200, 1000), { code: 'SEARCH_FAILED' });
  }
});

test('真实DSH的合法零宽正则保留非空行与空行', async () => {
  await writeFile(join(work, 'zero-width.txt'), '😀中abc\n\nabc');
  const context = { subprocess: ctx.subprocess, workingDirectory: { ensure: async () => work } };
  for (const pattern of ['^', '$', '']) {
    const result = await search.runRipgrep(context, { agent: searchAgent(), signal: new AbortController().signal }, 'grep', search.buildGrepCommand({ pattern, path: 'zero-width.txt' }), 10000, 200, 1000);
    assert.equal(result.noMatches, false);
    assert.deepEqual(search.parseGrepMatches(result.stdout).map(match => [match.lineNumber, match.line]), [[1, '😀中abc'], [2, ''], [3, 'abc']]);
  }
});

test('真实DSH显式搜索文件不被gitignore、隐藏或负向glob伪装成零匹配', async () => {
  const directory = join(work, 'explicit-ignored');
  await mkdir(join(directory, '.git'), { recursive: true });
  await writeFile(join(directory, '.gitignore'), '*.txt\n');
  const context = { subprocess: ctx.subprocess, workingDirectory: { ensure: async () => directory } };
  for (const path of ['ignored.txt', '.hidden.txt']) {
    await writeFile(join(directory, path), 'abc\n');
    for (const include of [undefined, '!*.txt']) {
      const result = await search.runRipgrep(context, { agent: searchAgent(), signal: new AbortController().signal }, 'grep', search.buildGrepCommand({ pattern: 'abc', path, include }), 10000, 200, 1000);
      assert.equal(result.noMatches, false);
      assert.deepEqual(search.parseGrepMatches(result.stdout), [{ path, lineNumber: 1, line: 'abc' }]);
    }
  }
});

test('DSH原rawOutputMaxBytes上限不解析截断的半条JSON', async () => {
  const context = { subprocess: ctx.subprocess, workingDirectory: { ensure: async () => work } };
  await assert.rejects(search.runRipgrep(context, { agent: searchAgent(), signal: new AbortController().signal }, 'grep', search.buildGrepCommand({ pattern: 'abc' }), 32, 200, 1000), { code: 'SEARCH_RAW_OUTPUT_OVERFLOW' });
});

test('PTY明确不可用，git解析到受限Worker而非系统可执行文件', async () => {
  await assert.rejects(ctx.subprocess.spawnTerminal({}), { code: 'ERR_OHOS_PTY_UNAVAILABLE' });
  assert.equal(await ctx.subprocess.resolveExecutable('git'), '/dsh-go/ohos/bin/git');
  assert.equal(await ctx.subprocess.resolveExecutable('bash'), '/dsh-go/ohos/bin/bash');
  assert.equal(ctx.subprocess.temporaryRoot, temp);
  assert.throws(() => { ctx.subprocess.temporaryRoot = '/tmp'; }, TypeError);
});

test('M4-1真实DSH include覆盖忽略文件和隐藏文件，保留被剪枝目录', async () => {
  const directory = join(work, 'm4-include');
  await mkdir(join(directory, '.git'), { recursive: true });
  await mkdir(join(directory, 'sub')); await mkdir(join(directory, 'ignored'));
  await writeFile(join(directory, '.gitignore'), '*.txt\nignored/\n');
  for (const path of ['a.txt', '.hidden.txt', 'sub/b.txt', 'ignored/c.txt', 'other.js']) await writeFile(join(directory, path), '中文 foo\n');
  const context = { subprocess: ctx.subprocess, workingDirectory: { ensure: async () => directory } };
  const result = await search.runRipgrep(context, { agent: searchAgent(), signal: new AbortController().signal }, 'grep', search.buildGrepCommand({ pattern: '\\b(?:中文|foo)\\b', include: '**/*.txt' }), 10000, 200, 1000);
  assert.equal(result.noMatches, false);
  assert.deepEqual(search.parseGrepMatches(result.stdout).map(match => match.path).sort(), ['.hidden.txt', 'a.txt', 'sub/b.txt']);
});

test('M4-1真实DSH显式文件优先于include，过滤后无文件不能伪装零匹配', async () => {
  const directory = join(work, 'm4-explicit'); await mkdir(directory);
  await writeFile(join(directory, 'a.txt'), '中文 ١٢\n');
  const context = { subprocess: ctx.subprocess, workingDirectory: { ensure: async () => directory } };
  const exec = { agent: searchAgent(), signal: new AbortController().signal };
  const result = await search.runRipgrep(context, exec, 'grep', search.buildGrepCommand({ pattern: '\\w+\\s\\d+', path: 'a.txt', include: '*.js' }), 10000, 200, 1000);
  assert.deepEqual(search.parseGrepMatches(result.stdout), [{ path: 'a.txt', lineNumber: 1, line: '中文 ١٢' }]);
  await assert.rejects(search.runRipgrep(context, exec, 'grep', search.buildGrepCommand({ pattern: 'x', include: '*.absent' }), 10000, 200, 1000), { code: 'SEARCH_FAILED' });
});

for (const [index, include, expected] of [
  [0, 'dir/?.txt', ['dir/a.txt', 'dir/z.txt']],
  [1, 'dir/???.txt', ['dir/abc.txt', 'dir/中.txt']],
  [2, 'dir/????.txt', ['dir/abcd.txt', 'dir/😀.txt']],
  [3, 'dir/[!a].txt', ['dir/z.txt']],
]) test(`M4-1真实DSH include按UTF-8字节匹配 ${include}`, async () => {
  const directory = join(work, 'm4-byte-' + index); await mkdir(join(directory, 'dir'), { recursive: true });
  for (const name of ['a', 'z', 'abc', 'abcd', '中', '😀']) await writeFile(join(directory, 'dir', name + '.txt'), 'needle\n');
  const context = { subprocess: ctx.subprocess, workingDirectory: { ensure: async () => directory } };
  const args = search.parseGrepArgs({ pattern: 'needle', include });
  const result = await search.runRipgrep(context, { agent: searchAgent(), signal: new AbortController().signal }, 'grep', search.buildGrepCommand(args), 65536, 100, 10000);
  assert.equal(result.noMatches, false);
  assert.deepEqual(search.parseGrepMatches(result.stdout).map(match => match.path).sort(), expected);
});
