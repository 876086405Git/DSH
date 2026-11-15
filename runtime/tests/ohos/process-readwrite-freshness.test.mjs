import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, chmod, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Bash } from '../../ohos/process/build/just-bash/index.js';
import { createFilesystem } from '../../ohos/process/filesystem.mjs';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';

const mode = process.env.M4_DIAGNOSTICS_MODE;
assert(['jit', 'strict'].includes(mode));
if (mode === 'strict') {
  assert.equal(process.version, 'v24.22.1');
  assert(process.execArgv.includes('--jitless'));
  assert.equal(process.platform, 'openharmony');
  assert.equal(typeof WebAssembly, 'undefined');
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
}
const cases = JSON.parse(await readFile(new URL('./process-readwrite-freshness-cases.json', import.meta.url), 'utf8'));
assert.equal(cases.length, 3);
const raw = (result, stream) => Buffer.from(result[stream], result[stream + 'Kind'] === 'bytes'
  || stream === 'stdout' && result.stdoutEncoding === 'binary' ? 'latin1' : 'utf8');
const collect = async stream => {
  const chunks = [];
  for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks);
};
async function fixture(t, kind, spec) {
  const root = await mkdtemp(join(tmpdir(), 'ohos-readwrite-freshness-'));
  const cwd = join(root, 'work-' + kind), temporaryRoot = join(root, 'temporary');
  const runtimes = [], pending = [], disposals = new Map();
  const dispose = runtime => {
    if (!disposals.has(runtime)) disposals.set(runtime, runtime.dispose());
    return disposals.get(runtime);
  };
  t.after(async () => {
    for (const runtime of runtimes) await dispose(runtime);
    await Promise.allSettled(pending);
    await rm(root, { recursive: true, force: true });
  });
  await mkdir(cwd); await mkdir(temporaryRoot);
  const files = spec.files ?? [{ path: 'sample.bin', initialHex: spec.initialHex, fileHex: spec.fileHex }];
  for (const file of files) {
    await writeFile(join(cwd, file.path), Buffer.from(file.initialHex, 'hex'));
    await chmod(join(cwd, file.path), 0o644);
  }
  return { cwd, temporaryRoot, files, runtimes, pending, dispose };
}
async function direct(f, command, signal) {
  const fs = createFilesystem([f.cwd]);
  const bash = new Bash({ fs: fs.fs, cwd: f.cwd, defenseInDepth: false,
    commands: ['bash', 'sh', 'printf', 'cat', 'test'], python: false, javascript: false });
  fs.seal();
  const running = bash.exec('bash', { args: ['-c', command], cwd: f.cwd, rawScript: true, signal });
  f.pending.push(running);
  const result = await running;
  return { exitCode: result.exitCode, stdout: raw(result, 'stdout'), stderr: raw(result, 'stderr') };
}
async function worker(f, command, signal) {
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [f.cwd], temporaryRoot: f.temporaryRoot });
  f.runtimes.push(runtime);
  try {
    const argv = runtime.prepare(['bash', '-c', command], { mode: 'workspace-write', workspaceRoot: f.cwd }, signal);
    const handle = runtime.spawn({ argv, cwd: f.cwd, graceMs: 200, signal,
      stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
    const running = Promise.all([handle.done, collect(handle.stdout), collect(handle.stderr)]);
    f.pending.push(running);
    const [result, stdout, stderr] = await running;
    assert.equal(await handle.waitForExit(), true);
    assert.equal(result.signal, null);
    return { exitCode: result.exitCode, stdout, stderr };
  } finally {
    await f.dispose(runtime);
    assert.equal(runtime.live.size, 0);
  }
}
for (const spec of cases) {
  for (const kind of ['direct', 'worker']) {
    test(spec.name + ' (' + kind + ')', { timeout: 15000 }, async t => {
      const f = await fixture(t, kind, spec);
      const result = await (kind === 'direct' ? direct : worker)(f, spec.command, t.signal);
      assert.equal(result.exitCode, 0, kind + ': recorded shell phases including the expected EOF must agree');
      assert.deepEqual(result.stdout, Buffer.from(spec.stdout, 'utf8'), kind + ': exact phase and value report');
      assert.deepEqual(result.stderr, Buffer.from(spec.stderr ?? '', 'utf8'), kind + ': exact stderr');
      for (const file of f.files) {
        assert.deepEqual(await readFile(join(f.cwd, file.path)), Buffer.from(file.fileHex, 'hex'),
          kind + ': actual file bytes for ' + file.path);
      }
    });
  }
}
