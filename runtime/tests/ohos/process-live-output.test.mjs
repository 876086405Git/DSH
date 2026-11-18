import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Bash, InMemoryFs } from '../../ohos/process/build/just-bash/index.js';
import { createFilesystem } from '../../ohos/process/filesystem.mjs';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';
import { independentOpenCases, independentOpenFiles } from './process-live-output-cases.mjs';

const mode = process.env.M4_DIAGNOSTICS_MODE;
assert(['jit', 'strict'].includes(mode));
if (mode === 'strict') {
  assert.equal(process.version, 'v24.22.1');
  assert(process.execArgv.includes('--jitless'));
  assert.equal(process.platform, 'openharmony');
  assert.equal(typeof WebAssembly, 'undefined');
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
}
const oracle = JSON.parse(await readFile(new URL('./process-live-output-oracle.json', import.meta.url), 'utf8'));
assert.equal(oracle.caseSourceSha256, createHash('sha256').update(await readFile(new URL('./process-live-output-cases.mjs', import.meta.url))).digest('hex'));
const raw = (result, stream) => Buffer.from(result[stream], result[stream + 'Kind'] === 'bytes'
  || stream === 'stdout' && result.stdoutEncoding === 'binary' ? 'latin1' : 'utf8');
const collect = async stream => { const chunks = []; for await (const chunk of stream) chunks.push(Buffer.from(chunk)); return Buffer.concat(chunks); };

async function fixture(t, name) {
  const root = await mkdtemp(join(tmpdir(), 'ohos-live-output-'));
  const cwd = join(root, '中文-' + name), temporaryRoot = join(root, 'temporary');
  await mkdir(cwd); await mkdir(temporaryRoot);
  for (const [path, value] of Object.entries(independentOpenFiles)) await writeFile(join(cwd, path), value);
  const runtimes = [];
  t.after(async () => {
    for (const runtime of runtimes) await runtime.dispose();
    await rm(root, { recursive: true, force: true });
  });
  return { cwd, temporaryRoot, runtimes };
}
async function direct(f, command, executionLimits) {
  const fs = createFilesystem([f.cwd]);
  const bash = new Bash({ fs: fs.fs, cwd: f.cwd, defenseInDepth: false,
    commands: ['bash', 'sh', 'printf', 'cat'], python: false, javascript: false, executionLimits });
  fs.seal();
  return bash.exec('bash', { args: ['-c', command], cwd: f.cwd, rawScript: true });
}
for (const spec of independentOpenCases) {
  test(`live output destination: ${spec.name}`, { timeout: 15000 }, async t => {
    const expected = oracle.rows.find(row => row.name === spec.name);
    assert.equal(expected.command, spec.command);
    for (const kind of ['direct', 'worker']) {
      const f = await fixture(t, kind); let actual;
      if (kind === 'direct') {
        const result = await direct(f, spec.command);
        actual = { exitCode: result.exitCode, stdoutHex: raw(result, 'stdout').toString('hex'), stderrHex: raw(result, 'stderr').toString('hex') };
      } else {
        const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [f.cwd], temporaryRoot: f.temporaryRoot });
        f.runtimes.push(runtime);
        try {
          const argv = runtime.prepare(['bash', '-c', spec.command], { mode: 'workspace-write', workspaceRoot: f.cwd }, t.signal);
          const handle = runtime.spawn({ argv, cwd: f.cwd, graceMs: 200, signal: t.signal,
            stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
          const [result, stdout, stderr] = await Promise.all([handle.done, collect(handle.stdout), collect(handle.stderr)]);
          assert.equal(await handle.waitForExit(), true);
          actual = { exitCode: result.exitCode, stdoutHex: stdout.toString('hex'), stderrHex: stderr.toString('hex') };
        } finally { await runtime.dispose(); }
      }
      actual.fileHex = (await readFile(join(f.cwd, 'result.bin'))).toString('hex');
      assert.deepEqual(actual, expected.result, kind);
    }
  });
}
test('live alias and file output share one exact byte budget', async t => {
  const f = await fixture(t, 'budget');
  const result = await direct(f, '{ printf C; printf E >&2; } 2>&1 > result.bin', { maxOutputSize: 2 });
  assert.equal(result.exitCode, 0);
  assert.equal(raw(result, 'stdout').toString('hex'), '45');
  assert.equal(raw(result, 'stderr').length, 0);
  assert.equal(await readFile(join(f.cwd, 'result.bin'), 'utf8'), 'C');
});
test('top-level public Bash.exec drains stable live output without a nested shell', async () => {
  const bash = new Bash({ fs: new InMemoryFs(), cwd: '/', defenseInDepth: false,
    commands: ['printf'], python: false, javascript: false });
  const result = await bash.exec('printf 中文; printf 错误 >&2');
  assert.equal(result.exitCode, 0);
  assert.equal(result.stdoutKind, 'text');
  assert.equal(result.stderrKind, 'text');
  assert.equal(result.stdout, '中文');
  assert.equal(result.stderr, '错误');
});
test('normal text output is never processed by the diagnostic path sanitizer', async () => {
  const bash = new Bash({ fs: new InMemoryFs(), cwd: '/', defenseInDepth: false,
    commands: ['printf'], python: false, javascript: false });
  const expected = '/tmp/public-example\n    at ordinary-output';
  const result = await bash.exec('printf "/tmp/public-example\\n    at ordinary-output"');
  assert.equal(result.exitCode, 0);
  assert.equal(result.stdoutKind, 'text');
  assert.equal(result.stdout, expected);
  assert.equal(result.stderr, '');
});
test('new redirection diagnostics are charged before entering a live or discarded sink', async t => {
  for (const command of ['printf X 1>&-', 'printf X 1>&- 2>/dev/null']) {
    const f = await fixture(t, 'diagnostic-budget');
    const limited = await direct(f, command, { maxOutputSize: 1 });
    assert.equal(limited.exitCode, 126, command);
    assert.match(raw(limited, 'stderr').toString('utf8'), /total output size exceeded/);
    const ample = await direct(f, command, { maxOutputSize: 4096 });
    assert.equal(ample.exitCode, 1, command);
    if (command.endsWith('/dev/null')) assert.equal(raw(ample, 'stderr').length, 0);
    else assert.match(raw(ample, 'stderr').toString('utf8'), /Bad file descriptor/);
  }
});
test('new routing diagnostic bytes are charged exactly once', async t => {
  const f = await fixture(t, 'diagnostic-exact');
  const diagnostic = 'bash: printf: write error: Bad file descriptor\n';
  const exact = 1 + Buffer.byteLength(diagnostic);
  const result = await direct(f, 'printf X 1>&-', { maxOutputSize: exact });
  assert.equal(result.exitCode, 1);
  assert.equal(raw(result, 'stdout').length, 0);
  assert.equal(raw(result, 'stderr').toString('utf8'), diagnostic);
  const tooSmall = await direct(f, 'printf X 1>&-', { maxOutputSize: exact - 1 });
  assert.equal(tooSmall.exitCode, 126);
});

// Same four inputs and byte predicates as the independent public-API probe.
// The Latin-pair stderr cases regress in v3; their stdout counterparts predate it.
for (const input of ['Ã©', 'Â¢', '中文', 'é']) {
  for (const target of ['stdout', 'stderr']) {
    test(`explicit text output survives the public result boundary: ${JSON.stringify(input)} ${target}`, async () => {
      const fs = new InMemoryFs();
      await fs.writeFile('/b', input);
      const bash = new Bash({ fs, cwd: '/', defenseInDepth: false,
        commands: ['cat', 'printf', 'bash'], python: false, javascript: false });
      const result = await bash.exec(target === 'stdout' ? 'cat /b' : 'cat /b >&2');
      assert.deepEqual(raw(result, target), Buffer.from(input, 'utf8'));
    });
  }
}
