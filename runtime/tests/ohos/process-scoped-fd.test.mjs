import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Bash, InMemoryFs } from '../../ohos/process/build/just-bash/index.js';
import { createFilesystem } from '../../ohos/process/filesystem.mjs';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';
import { independentOpenCases, independentOpenFiles } from './process-scoped-fd-cases.mjs';

const mode = process.env.M4_DIAGNOSTICS_MODE;
assert(['jit', 'strict'].includes(mode));
if (mode === 'strict') {
  assert.equal(process.version, 'v24.22.1');
  assert(process.execArgv.includes('--jitless'));
  assert.equal(process.platform, 'openharmony');
  assert.equal(typeof WebAssembly, 'undefined');
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
}
const oracle = JSON.parse(await readFile(new URL('./process-scoped-fd-oracle.json', import.meta.url), 'utf8'));
assert.equal(oracle.caseSourceSha256, createHash('sha256').update(await readFile(new URL('./process-scoped-fd-cases.mjs', import.meta.url))).digest('hex'));
const raw = (result, stream) => Buffer.from(result[stream], result[stream + 'Kind'] === 'bytes'
  || stream === 'stdout' && result.stdoutEncoding === 'binary' ? 'latin1' : 'utf8');
const collect = async stream => { const chunks = []; for await (const chunk of stream) chunks.push(Buffer.from(chunk)); return Buffer.concat(chunks); };
async function fixture(t, name) {
  const root = await mkdtemp(join(tmpdir(), 'ohos-scoped-fd-'));
  const cwd = join(root, '中文-' + name), temporaryRoot = join(root, 'temporary');
  await mkdir(cwd); await mkdir(temporaryRoot);
  for (const [path, value] of Object.entries(independentOpenFiles)) await writeFile(join(cwd, path), value);
  t.after(() => rm(root, { recursive: true, force: true }));
  return { cwd, temporaryRoot };
}
async function direct(f, command, executionLimits) {
  const fs = createFilesystem([f.cwd]);
  const bash = new Bash({ fs: fs.fs, cwd: f.cwd, defenseInDepth: false,
    commands: ['bash', 'sh', 'printf', 'cat'], python: false, javascript: false, executionLimits });
  fs.seal();
  return bash.exec('bash', { args: ['-c', command], cwd: f.cwd, rawScript: true });
}
for (const spec of independentOpenCases) {
  test(`scoped descriptor ordering: ${spec.name}`, { timeout: 15000 }, async t => {
    const expected = oracle.rows.find(row => row.name === spec.name);
    assert.equal(expected.command, spec.command);
    for (const kind of ['direct', 'worker']) {
      const f = await fixture(t, kind); let actual;
      if (kind === 'direct') {
        const result = await direct(f, spec.command);
        actual = { exitCode: result.exitCode, stdoutHex: raw(result, 'stdout').toString('hex'), stderrHex: raw(result, 'stderr').toString('hex') };
      } else {
        const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [f.cwd], temporaryRoot: f.temporaryRoot });
        try {
          const argv = runtime.prepare(['bash', '-c', spec.command], { mode: 'workspace-write', workspaceRoot: f.cwd });
          const handle = runtime.spawn({ argv, cwd: f.cwd, graceMs: 200, stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
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
test('inherited file sinks retain the execution-wide output budget', async t => {
  const f = await fixture(t, 'budget');
  const result = await direct(f, '{ printf ABC; printf DEF; printf GHI; } > result.bin', { maxOutputSize: 6 });
  assert.equal(result.exitCode, 126);
  assert.equal(await readFile(join(f.cwd, 'result.bin'), 'utf8'), 'ABCDEF');
  assert.match(raw(result, 'stderr').toString('utf8'), /output size exceeded/);
});
test('exact budget does not charge inherited file output twice', async t => {
  const f = await fixture(t, 'exact-budget');
  const result = await direct(f, '{ printf ABC; printf DEF; } > result.bin', { maxOutputSize: 6 });
  assert.equal(result.exitCode, 0);
  assert.equal(await readFile(join(f.cwd, 'result.bin'), 'utf8'), 'ABCDEF');
  assert.equal(raw(result, 'stdout').length + raw(result, 'stderr').length, 0);
});
test('a dup file sink counts the actual two stream bytes once', async t => {
  const f = await fixture(t, 'dup-budget');
  const result = await direct(f, '{ printf ABC; printf DEF >&2; } > result.bin 2>&1', { maxOutputSize: 6 });
  assert.equal(result.exitCode, 0);
  assert.equal(await readFile(join(f.cwd, 'result.bin'), 'utf8'), 'ABCDEF');
});
test('in-memory output positions preserve holes after a real truncation', async () => {
  const fs = new InMemoryFs();
  const bash = new Bash({ fs, cwd: '/', defenseInDepth: false, commands: ['bash', 'printf'], python: false, javascript: false });
  const result = await bash.exec('bash', { args: ['-c', '{ printf ABC; : > /result; printf XY; } > /result'], cwd: '/', rawScript: true });
  assert.equal(result.exitCode, 0);
  assert.equal(Buffer.from(await fs.readFileBuffer('/result')).toString('hex'), '0000005859');
});
