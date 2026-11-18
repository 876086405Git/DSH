import { symlinkFixture } from './host-link-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const mode = process.env.M4_DIAGNOSTICS_MODE;
assert(['jit', 'strict'].includes(mode), 'set M4_DIAGNOSTICS_MODE=jit or strict explicitly');
if (mode === 'strict') {
  assert.equal(process.versions.node, '24.22.1');
  assert(process.execArgv.includes('--jitless'));
  assert.equal(process.platform, 'openharmony');
  assert.equal(typeof WebAssembly, 'undefined');
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
}
const runtimeURL = process.env.M4_PROCESS_RUNTIME
  ? pathToFileURL(process.env.M4_PROCESS_RUNTIME)
  : new URL('../../ohos/process/runtime.mjs', import.meta.url);
const { VirtualSubprocessRuntime } = await import(runtimeURL);
const collect = async stream => {
  const chunks = [];
  for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks);
};

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'ohos-diagnostic-worker-'));
  const [work, outside, temporaryRoot] = ['work', 'outside', 'temporary'].map(name => join(root, name));
  await Promise.all([work, outside, temporaryRoot].map(path => mkdir(path)));
  await writeFile(join(outside, 'secret'), 'OUTSIDE_SECRET');
  await writeFile(join(outside, '中文'), 'OUTSIDE_UNICODE_SECRET');
  await writeFile(join(work, 'own'), 'inside');
  await writeFile(join(work, 'binary'), Buffer.from([0, 255, 195, 169]));
  await writeFile(join(work, 'unicode'), '你好');
  await symlinkFixture(outside, join(work, 'escape'));
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot });
  t.after(async () => { await runtime.dispose(); await rm(root, { recursive: true, force: true }); });
  const run = async (command, policy = 'workspace-write') => {
    const argv = runtime.prepare(['bash', '-c', command], { mode: policy, workspaceRoot: work });
    const handle = runtime.spawn({ argv, cwd: work, graceMs: 200,
      stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
    const [outcome, stdoutBytes, stderrBytes] = await Promise.all([
      handle.done, collect(handle.stdout), collect(handle.stderr),
    ]);
    assert.equal(await handle.waitForExit(), true);
    return { ...outcome, stdoutBytes, stderrBytes, stdout: stdoutBytes.toString('utf8'), stderr: stderrBytes.toString('utf8') };
  };
  return { root, work, outside, runtime, run };
}

for (const [name, command, merged = false] of [
  ['cat escape', 'cat escape/secret || printf recovered'],
  ['Unicode cat merged', 'cat escape/中文 2>&1 || printf recovered', true],
  ['input redirection', 'cat < escape/secret || printf recovered'],
  ['Unicode input redirection merged', 'cat 2>&1 < escape/中文 || printf recovered', true],
  ['cd escape', 'cd escape || printf recovered'],
  ['cd merged', 'cd escape 2>&1 || printf recovered', true],
  ['numeric input descriptor', 'cat 3<escape/secret <&3 || printf recovered'],
  ['readwrite descriptor', 'cat <>escape/secret || printf recovered'],
]) test(`${name}: actual worker reports EACCES and retains shell recovery`, async t => {
  const f = await fixture(t), result = await f.run(command);
  assert.equal(result.exitCode, 0);
  assert(result.stdout.endsWith('recovered'));
  assert.match(result.stdout + result.stderr, /EACCES/);
  assert.doesNotMatch(result.stdout + result.stderr, /OUTSIDE_|No such file|\uFFFD/);
  if (merged) assert.equal(result.stderr, '');
  else assert.equal(result.stdout, 'recovered');
  if (command.includes('中文')) assert.match(result.stdout + result.stderr, /中文/);
  assert.equal(await readFile(join(f.outside, 'secret'), 'utf8'), 'OUTSIDE_SECRET');
});

for (const command of [
  'cat escape/secret 2>/dev/null || printf recovered',
  'cat 2>/dev/null < escape/secret || printf recovered',
  'cd escape 2>/dev/null || printf recovered',
]) test(`suppressed diagnostics stay suppressed: ${command}`, async t => {
  const f = await fixture(t), result = await f.run(command, 'read-only');
  assert.equal(result.exitCode, 0);
  assert.equal(result.stdout, 'recovered');
  assert.equal(result.stderr, '');
});

test('an earlier stderr file redirection receives a later input-denial error', async t => {
  const f = await fixture(t);
  const result = await f.run('cat 2>diagnostic.txt < escape/中文 || printf recovered');
  assert.equal(result.exitCode, 0);
  assert.equal(result.stdout, 'recovered');
  assert.equal(result.stderr, '');
  const diagnostic = await readFile(join(f.work, 'diagnostic.txt'), 'utf8');
  assert.match(diagnostic, /EACCES/);
  assert.match(diagnostic, /中文/);
  assert.doesNotMatch(diagnostic, /No such file|OUTSIDE_|\uFFFD/);
});

for (const command of ['cat missing', 'cat < missing', 'cd missing']) {
  test(`real missing paths retain ENOENT semantics: ${command}`, async t => {
    const f = await fixture(t), result = await f.run(command + ' || printf recovered');
    assert.equal(result.exitCode, 0);
    assert.equal(result.stdout, 'recovered');
    assert.match(result.stderr, /No such file or directory/);
    assert.doesNotMatch(result.stderr, /EACCES/);
  });
}

test('raw stdout retains 0xff and UTF-8 stderr exactly once after 2>&1', async t => {
  const f = await fixture(t), result = await f.run('cat binary 缺失文件 2>&1');
  assert.equal(result.exitCode, 1);
  assert.equal(result.stderrBytes.length, 0);
  assert.deepEqual(result.stdoutBytes, Buffer.concat([
    Buffer.from([0, 255, 195, 169]), Buffer.from('cat: 缺失文件: No such file or directory\n'),
  ]));
});

test('a shared file sink receives binary stdout and UTF-8 stderr unchanged', async t => {
  const f = await fixture(t), result = await f.run('cat binary 缺失文件 >all 2>&1');
  assert.equal(result.exitCode, 1);
  assert.equal(result.stdoutBytes.length, 0);
  assert.equal(result.stderrBytes.length, 0);
  assert.deepEqual(await readFile(join(f.work, 'all')), Buffer.concat([
    Buffer.from([0, 255, 195, 169]), Buffer.from('cat: 缺失文件: No such file or directory\n'),
  ]));
});

test('2>&1 followed by >file keeps the original two sink identities', async t => {
  const f = await fixture(t), result = await f.run('cat unicode 缺失文件 2>&1 >out');
  assert.equal(result.exitCode, 1);
  assert.equal(result.stdout, 'cat: 缺失文件: No such file or directory\n');
  assert.equal(result.stderr, '');
  assert.equal(await readFile(join(f.work, 'out'), 'utf8'), '你好');
});

for (const [command, expected, exitCode = 0] of [
  ["for x in 1 2; do printf '你好'; done", '你好你好'],
  ["if true; then printf '你好'; fi", '你好'],
  ["printf '你好'; exit 7", '你好', 7],
  ["f(){ printf '你好'; return 7; }; f", '你好', 7],
  ["{ printf '你好'; } | cat", '你好'],
]) test(`existing Unicode compound output remains exact: ${command}`, async t => {
  const f = await fixture(t), result = await f.run(command);
  assert.equal(result.exitCode, exitCode);
  assert.deepEqual(result.stdoutBytes, Buffer.from(expected));
  assert.equal(result.stderr, '');
});

test('read-only policy still denies a redirection write without creating the target', async t => {
  const f = await fixture(t), result = await f.run('printf forbidden > newfile || printf recovered', 'read-only');
  // This write-policy error already exits the whole command in 3.6.0.
  // Preserve that existing behavior; read-denial recovery is tested above.
  assert.equal(result.exitCode, 1);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /EACCES: OHOS_SANDBOX_DENIED/);
  await assert.rejects(readFile(join(f.work, 'newfile')), { code: 'ENOENT' });
});
