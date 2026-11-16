import { symlinkFixture } from './host-link-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, readFile, rm, writeFile, link as nativeLink, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';
import { Bash, ReadWriteFs, MountableFs, InMemoryFs, defineCommand } from '../../ohos/process/build/just-bash/index.js';
import { createFilesystem } from '../../ohos/process/filesystem.mjs';
import { independentOpenCases, independentOpenFiles } from './process-independent-open-cases.mjs';

const mode = process.env.M4_DIAGNOSTICS_MODE;
assert(['jit', 'strict'].includes(mode));
if (mode === 'strict') {
  assert.equal(process.version, 'v24.22.1');
  assert(process.execArgv.includes('--jitless'));
  assert.equal(process.platform, 'openharmony');
  assert.equal(typeof WebAssembly, 'undefined');
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
}
const oracle = JSON.parse(await readFile(new URL('./process-independent-open-oracle.json', import.meta.url), 'utf8'));
assert.equal(oracle.caseSourceSha256, createHash('sha256').update(
  await readFile(new URL('./process-independent-open-cases.mjs', import.meta.url))).digest('hex'));
const collect = async stream => {
  const chunks = []; for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks);
};
const bytes = (value, name) => Buffer.from(value[name], value[name + 'Kind'] === 'bytes'
  || name === 'stdout' && value.stdoutEncoding === 'binary' ? 'latin1' : 'utf8');
const okay = { stdout: '', stderr: '', exitCode: 0 };
let linkRequest = 0;
async function link(source, destination) {
  if (mode !== 'strict') return nativeLink(source, destination);
  // Host fixture input, never a restored Node builtin. The Python test parent
  // checks that both paths belong to its fresh private workspace.
  const requests = process.env.OHOS_TEST_LINK_REQUESTS, responses = process.env.OHOS_TEST_LINK_RESPONSES;
  assert(requests && responses, 'strict hard-link inputs require process-link-fixture.py');
  const name = `${process.pid}-${++linkRequest}.json`, pending = name + '.pending';
  await writeFile(join(requests, pending), JSON.stringify({ source, destination }), { flag: 'wx' });
  const { rename } = await import('node:fs/promises');
  await rename(join(requests, pending), join(requests, name));
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    let answer;
    try { answer = JSON.parse(await readFile(join(responses, name), 'utf8')); }
    catch (error) {
      if (error.code !== 'ENOENT') throw error;
      await new Promise(resolve => setTimeout(resolve, 5));
      continue;
    }
    await rm(join(responses, name));
    if (!answer.ok) throw Object.assign(new Error(answer.message), { code: answer.code });
    return;
  }
  throw new Error('native fixture link handshake timed out');
}

async function fixture(t, spec = {}) {
  const root = await mkdtemp(join(process.env.OHOS_TEST_LINK_WORKSPACE ?? tmpdir(), 'ohos-independent-open-test-'));
  const cwd = join(root, '中文 工作区'), temporaryRoot = join(root, 'temporary');
  await mkdir(cwd); await mkdir(temporaryRoot);
  for (const [name, value] of Object.entries(independentOpenFiles)) await writeFile(join(cwd, name), value);
  if (spec.initial !== undefined) await writeFile(join(cwd, spec.output ?? 'result.bin'), spec.initial);
  if (spec.symlink) await symlinkFixture('result.bin', join(cwd, 'alias.bin'));
  t.after(() => rm(root, { recursive: true, force: true }));
  return { root, cwd, temporaryRoot };
}
function shell(fs, cwd, customCommands = []) {
  return new Bash({ fs, cwd, defenseInDepth: false,
    commands: ['bash', 'sh', 'printf', 'cat'], customCommands, python: false, javascript: false });
}
async function execute(bash, cwd, command) {
  return bash.exec('bash', { args: ['-c', command], cwd, rawScript: true });
}
async function assertDenied(operation, pattern) {
  let result;
  try { result = await operation(); }
  catch (error) { assert.match(String(error), pattern); return; }
  assert.notEqual(result.exitCode, 0);
  assert.match(bytes(result, 'stderr').toString('utf8'), pattern);
}

for (const spec of independentOpenCases) {
  test(`independent file open: ${spec.name}`, { timeout: 15000 }, async t => {
    const f = await fixture(t, spec), runtime = new VirtualSubprocessRuntime({ workspaceRoots: [f.cwd], temporaryRoot: f.temporaryRoot });
    const expected = oracle.rows.find(row => row.name === spec.name);
    assert.equal(expected.command, spec.command);
    try {
      const argv = runtime.prepare(['bash', '-c', spec.command], { mode: 'workspace-write', workspaceRoot: f.cwd });
      const handle = runtime.spawn({ argv, cwd: f.cwd, graceMs: 200,
        stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
      const [result, stdout, stderr] = await Promise.all([handle.done, collect(handle.stdout), collect(handle.stderr)]);
      assert.equal(await handle.waitForExit(), true);
      assert.deepEqual({ exitCode: result.exitCode, stdoutHex: stdout.toString('hex'), stderrHex: stderr.toString('hex'),
        fileHex: (await readFile(join(f.cwd, spec.output ?? 'result.bin'))).toString('hex') }, expected.result);
    } finally { await runtime.dispose(); }
  });
}

test('scoped overwrite keeps the read-only policy denial', async t => {
  const f = await fixture(t, { initial: 'unchanged' }), filesystem = createFilesystem([f.cwd], { mode: 'read-only' });
  const bash = shell(filesystem.fs, f.cwd); filesystem.seal();
  await assertDenied(() => execute(bash, f.cwd, '{ printf ABCDEFGHI; printf 123 >&2; } > result.bin 2> result.bin'), /EACCES|read-only/);
  assert.equal(await readFile(join(f.cwd, 'result.bin'), 'utf8'), 'unchanged');
});

test('scoped overwrite cannot follow an escaping symlink', async t => {
  const f = await fixture(t), outside = join(f.root, 'outside.bin'); await writeFile(outside, 'outside-unchanged');
  await symlinkFixture(outside, join(f.cwd, 'result.bin'));
  const filesystem = createFilesystem([f.cwd]), bash = shell(filesystem.fs, f.cwd); filesystem.seal();
  await assertDenied(() => execute(bash, f.cwd, '{ printf ABCDEFGHI; printf 123 >&2; } > result.bin 2> result.bin'), /EACCES|cannot open redirect target/);
  assert.equal(await readFile(outside, 'utf8'), 'outside-unchanged');
});

test('independent opens keep existing hard-link copy-on-write isolation', async t => {
  const f = await fixture(t), outside = join(f.root, 'outside.bin'); await writeFile(outside, 'outside-unchanged');
  if (mode === 'strict') await assert.rejects(nativeLink(outside, join(f.cwd, 'forbidden-direct-link')), { code: 'EACCES' });
  await link(outside, join(f.cwd, 'result.bin'));
  const filesystem = createFilesystem([f.cwd]), bash = shell(filesystem.fs, f.cwd); filesystem.seal();
  const result = await execute(bash, f.cwd, '{ printf ABCDEFGHI; printf 123 >&2; } > result.bin 2> result.bin');
  assert.equal(result.exitCode, 0);
  assert.equal(await readFile(join(f.cwd, 'result.bin'), 'utf8'), '123DEFGHI');
  assert.equal(await readFile(outside, 'utf8'), 'outside-unchanged');
  assert.notEqual((await stat(outside)).ino, (await stat(join(f.cwd, 'result.bin'))).ino);
});

test('a hard link planted by a real body action is isolated before tail preservation', async t => {
  const f = await fixture(t), outside = join(f.root, 'outside.bin'), original = 'outside-tail-unchanged';
  await writeFile(outside, original);
  const filesystem = createFilesystem([f.cwd]);
  const bash = shell(filesystem.fs, f.cwd, [defineCommand('plant', async () => {
    await rm(join(f.cwd, 'result.bin')); await link(outside, join(f.cwd, 'result.bin')); return okay;
  })]); filesystem.seal();
  const result = await execute(bash, f.cwd, '{ plant; printf ABCDEFGHI; printf 123 >&2; } > result.bin 2> result.bin');
  assert.equal(result.exitCode, 0);
  assert.equal(await readFile(join(f.cwd, 'result.bin'), 'utf8'), '123DEFGHI' + original.slice(9));
  assert.equal(await readFile(outside, 'utf8'), original);
});

test('the fixed in-memory backend preserves raw tails too', async () => {
  const fs = new InMemoryFs({ '/work/stdout.bin': independentOpenFiles['stdout.bin'], '/work/stderr.bin': independentOpenFiles['stderr.bin'] });
  const bash = shell(fs, '/work');
  const result = await execute(bash, '/work', '{ cat stdout.bin; cat stderr.bin >&2; } > result.bin 2> result.bin');
  assert.equal(result.exitCode, 0);
  assert.equal(Buffer.from(await fs.readFileBuffer('/work/result.bin')).toString('hex'), '31ff32c3a980434445');
});

test('a single-link output preserves its tail without reading through the file-read cap', async t => {
  const f = await fixture(t), backend = new ReadWriteFs({ root: f.cwd, maxFileReadSize: 1 });
  const fs = new MountableFs({ mounts: [{ mountPoint: f.cwd, filesystem: backend }] });
  const bash = shell(fs, f.cwd, [defineCommand('fill', async () => {
    await writeFile(join(f.cwd, 'result.bin'), Buffer.alloc(4096, 0x7a)); return okay;
  })]);
  const result = await execute(bash, f.cwd, '{ fill; printf ABC; } > result.bin');
  assert.equal(result.exitCode, 0);
  const written = await readFile(join(f.cwd, 'result.bin'));
  assert.equal(written.length, 4096); assert.equal(written.subarray(0, 3).toString(), 'ABC');
  assert(written.subarray(3).every(value => value === 0x7a));
});

test('a hard link appearing after actual isolation causes a refusal before overwrite', async t => {
  const f = await fixture(t), backend = new ReadWriteFs({ root: f.cwd }), target = join(f.cwd, 'result.bin'), outside = join(f.root, 'linked-outside.bin');
  await writeFile(target, 'must-remain');
  const realAppend = backend.appendFileUnlocked.bind(backend);
  let linked = false;
  backend.appendFileUnlocked = async (...args) => {
    await realAppend(...args);
    if (!linked && args[2]?.ohosOverwriteAtStart === true) {
      linked = true; await link(target, outside);
    }
  };
  await assert.rejects(backend.writeFile('/result.bin', 'ABC', { encoding: 'utf8', ohosOverwriteAtStart: true }), /EACCES.*multiply-linked/);
  assert(linked); assert.equal(await readFile(outside, 'utf8'), 'must-remain');
  assert.equal(await readFile(target, 'utf8'), 'must-remain');
});

test('tail preservation retains the existing hard-link copy size limit', async t => {
  const f = await fixture(t), outside = join(f.root, 'outside.bin'); await writeFile(outside, '0123456789');
  const backend = new ReadWriteFs({ root: f.cwd, maxCopyOnWriteSize: 8 });
  const fs = new MountableFs({ mounts: [{ mountPoint: f.cwd, filesystem: backend }] });
  const bash = shell(fs, f.cwd, [defineCommand('plant', async () => {
    await rm(join(f.cwd, 'result.bin')); await link(outside, join(f.cwd, 'result.bin')); return okay;
  })]);
  await assertDenied(() => execute(bash, f.cwd, '{ plant; printf ABC; } > result.bin'), /EFBIG.*copy-on-write/);
  assert.equal(await readFile(outside, 'utf8'), '0123456789');
  assert.equal(await readFile(join(f.cwd, 'result.bin'), 'utf8'), '0123456789');
});

test('position writes retain the hard-link race refusal', async t => {
  const f = await fixture(t), backend = new ReadWriteFs({ root: f.cwd });
  const target = join(f.cwd, 'result.bin'), outside = join(f.root, 'linked-outside.bin');
  await writeFile(target, 'must-remain');
  const realAppend = backend.appendFileUnlocked.bind(backend);
  let linked = false;
  backend.appendFileUnlocked = async (...args) => {
    await realAppend(...args);
    if (!linked && args[2]?.ohosWritePosition === 3) { linked = true; await link(target, outside); }
  };
  await assert.rejects(backend.writeFile('/result.bin', 'ABC', { encoding: 'utf8', ohosWritePosition: 3 }), /EACCES.*multiply-linked/);
  assert(linked);
  assert.equal(await readFile(outside, 'utf8'), 'must-remain');
  assert.equal(await readFile(target, 'utf8'), 'must-remain');
});

test('invalid position writes reject without changing existing bytes', async t => {
  const f = await fixture(t), backend = new ReadWriteFs({ root: f.cwd });
  const target = join(f.cwd, 'result.bin'); await writeFile(target, 'must-remain');
  for (const position of [-1, 0.5, NaN, Infinity, '3', Number.MAX_SAFE_INTEGER]) {
    await assert.rejects(backend.writeFile('/result.bin', 'ABC', { encoding: 'utf8', ohosWritePosition: position }), /position/i);
    assert.equal(await readFile(target, 'utf8'), 'must-remain');
  }
});
