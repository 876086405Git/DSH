import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';
import { Bash } from '../../ohos/process/build/just-bash/index.js';
import { createFilesystem } from '../../ohos/process/filesystem.mjs';
import { controlFlowCases, controlFlowFiles } from './process-control-flow-cases.mjs';

const mode = process.env.M4_DIAGNOSTICS_MODE;
assert(['jit', 'strict'].includes(mode), 'set M4_DIAGNOSTICS_MODE=jit or strict');
if (mode === 'strict') {
  assert.equal(process.version, 'v24.22.1');
  assert(process.execArgv.includes('--jitless'));
  assert.equal(process.platform, 'openharmony');
  assert.equal(typeof WebAssembly, 'undefined');
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
}
const collect = async stream => {
  const chunks = []; for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks);
};
const raw = (result, stream) => Buffer.from(result[stream], result[stream + 'Kind'] === 'bytes'
  || stream === 'stdout' && result.stdoutEncoding === 'binary' ? 'latin1' : 'utf8');
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'ohos-control-flow-'));
  const cwd = join(root, '中文 工作区'), temporaryRoot = join(root, 'temporary');
  await mkdir(cwd); await mkdir(temporaryRoot);
  for (const [name, bytes] of Object.entries(controlFlowFiles)) await writeFile(join(cwd, name), bytes);
  t.after(() => rm(root, { recursive: true, force: true }));
  return { cwd, temporaryRoot };
}
for (const expected of controlFlowCases) {
  test(`raw stdout through ${expected.name}`, { timeout: 15000 }, async t => {
    let runtime;
    t.after(() => runtime?.dispose());
    const f = await fixture(t);
    runtime = new VirtualSubprocessRuntime({ workspaceRoots: [f.cwd], temporaryRoot: f.temporaryRoot });
    try {
      const argv = runtime.prepare(['bash', '-c', expected.command], { mode: 'workspace-write', workspaceRoot: f.cwd }, t.signal);
      const handle = runtime.spawn({ argv, cwd: f.cwd, graceMs: 200, signal: t.signal,
        stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
      const [outcome, stdout, stderr] = await Promise.all([handle.done, collect(handle.stdout), collect(handle.stderr)]);
      assert.equal(await handle.waitForExit(), true);
      assert.equal(outcome.exitCode, expected.exitCode);
      assert.equal(stdout.toString('hex'), expected.stdoutHex);
      assert.equal(stderr.toString('hex'), expected.stderrHex);
      if (expected.fileHex === null) await assert.rejects(readFile(join(f.cwd, 'result.bin')), { code: 'ENOENT' });
      else assert.equal((await readFile(join(f.cwd, 'result.bin'))).toString('hex'), expected.fileHex);
    } finally { await runtime.dispose(); }
  });
}
async function limited(t, command, limits) {
  const f = await fixture(t), fs = createFilesystem([f.cwd]);
  const bash = new Bash({ fs: fs.fs, cwd: f.cwd, defenseInDepth: false,
    commands: ['bash', 'sh', 'cat', 'printf'], python: false, javascript: false, executionLimits: limits });
  fs.seal();
  return bash.exec('bash', { args: ['-c', command], cwd: f.cwd, rawScript: true });
}
test('a return carries exactly the original accounted bytes at the output limit', async t => {
  const result = await limited(t, 'f(){ cat binary; return 7; }; f', { maxOutputSize: controlFlowFiles.binary.length });
  assert.equal(result.exitCode, 7); assert.deepEqual(raw(result, 'stdout'), controlFlowFiles.binary);
  assert.equal(raw(result, 'stderr').length, 0);
});
test('output limit failure preserves the earlier accepted binary prefix once', async t => {
  const result = await limited(t, 'f(){ cat binary; cat binary; return 7; }; f', { maxOutputSize: controlFlowFiles.binary.length });
  assert.equal(result.exitCode, 126); assert.deepEqual(raw(result, 'stdout'), controlFlowFiles.binary);
  assert.match(raw(result, 'stderr').toString('utf8'), /output size exceeded/);
});
test('iteration limit failure preserves the prior binary output and exit code', async t => {
  const result = await limited(t, 'for x in 1 2 3; do cat binary; done', { maxLoopIterations: 2 });
  assert.equal(result.exitCode, 126);
  assert.deepEqual(raw(result, 'stdout'), Buffer.concat([controlFlowFiles.binary, controlFlowFiles.binary]));
  assert.match(raw(result, 'stderr').toString('utf8'), /too many iterations/);
});
