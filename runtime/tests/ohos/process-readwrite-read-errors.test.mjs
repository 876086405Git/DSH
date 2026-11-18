import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Bash } from '../../ohos/process/build/just-bash/index.js';
import { createFilesystem } from '../../ohos/process/filesystem.mjs';

const mode = process.env.M4_DIAGNOSTICS_MODE;
assert(['jit', 'strict'].includes(mode));
if (mode === 'strict') {
  assert.equal(process.version, 'v24.22.1');
  assert(process.execArgv.includes('--jitless'));
  assert.equal(process.platform, 'openharmony');
  assert.equal(typeof WebAssembly, 'undefined');
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
}
const initial = Buffer.from('ABCD\n');
const failureMessage = 'controlled-refresh-EIO';

async function fixture(t, failRead = 0) {
  const root = await mkdtemp(join(tmpdir(), 'ohos-readwrite-read-errors-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const cwd = join(root, 'work');
  await mkdir(cwd);
  const path = join(cwd, 'input.bin');
  await writeFile(path, initial);
  const reads = [], filesystem = createFilesystem([cwd], { mode: 'workspace-write' });
  assert.equal(typeof filesystem.fs.readFileBytes, 'function');
  // Only this instance's existing IFileSystem method is controlled. The first
  // <> read and every other filesystem operation still use the real backend.
  const counted = new Proxy(filesystem.fs, { get(target, key) {
    const value = target[key];
    if (key === 'readFileBytes') return async (...args) => {
      if (args[0] !== path) return value.apply(target, args);
      const row = { number: reads.length + 1, failed: false };
      reads.push(row);
      if (row.number === failRead) {
        row.failed = true;
        throw Object.assign(new Error(failureMessage), { code: 'EIO' });
      }
      const data = await value.apply(target, args);
      row.hex = Buffer.from(data, 'latin1').toString('hex');
      return data;
    };
    return typeof value === 'function' ? value.bind(target) : value;
  } });
  const bash = new Bash({ fs: counted, cwd, defenseInDepth: false,
    commands: ['bash', 'sh', 'printf'], python: false, javascript: false });
  filesystem.seal();
  return { cwd, path, reads, bash };
}

async function execute(t, f, script) {
  const result = await f.bash.exec('bash', { args: ['-c', script], cwd: f.cwd, rawScript: true });
  const file = await readFile(f.path);
  // Record actual results before any semantic assertion, including expected
  // command failure. These diagnostics also make the b566 comparison reviewable.
  t.diagnostic(JSON.stringify({ script, result: { exitCode: result.exitCode,
    stdout: result.stdout, stderr: result.stderr }, reads: f.reads,
    initialHex: initial.toString('hex'), finalHex: file.toString('hex') }));
  assert.deepEqual(file, initial);
  return result;
}

test('readwrite refresh failure reports read exit 1 and preserves the cached unread line', { timeout: 15000 }, async t => {
  const f = await fixture(t, 2);
  const result = await execute(t, f, `exec 3<> input.bin || exit $?
value=sentinel
read -r -u 3 value
read_rc=$?
printf 'read:%s:%s\n' "$read_rc" "$value"
cached=sentinel
read -r cached <&3
cached_rc=$?
printf 'cached:%s:%s\n' "$cached_rc" "$cached"
exit "$read_rc"`);
  assert.equal(result.exitCode, 1);
  assert.equal(result.stderr, `bash: read: 3: ${failureMessage}\n`);
  assert.equal(result.stdout, 'read:1:sentinel\ncached:0:ABCD\n');
  assert.deepEqual(f.reads, [
    { number: 1, failed: false, hex: initial.toString('hex') },
    { number: 2, failed: true },
  ]);
});

test('readwrite zero counts and zero -N precedence do not refresh or consume input', { timeout: 15000 }, async t => {
  const f = await fixture(t, 2);
  const result = await execute(t, f, `exec 3<> input.bin || exit $?
value=sentinel
read -n 0 -u 3 value
rc=$?
printf 'n0:%s:%s\n' "$rc" "$value"
if [ "$rc" != 0 ]; then exit "$rc"; fi
value=sentinel
read -N 0 -u 3 value
rc=$?
printf 'N0:%s:%s\n' "$rc" "$value"
if [ "$rc" != 0 ]; then exit "$rc"; fi
value=sentinel
read -N 0 -n 1 -u 3 value
rc=$?
printf 'N0-wins:%s:%s\n' "$rc" "$value"
if [ "$rc" != 0 ]; then exit "$rc"; fi
read -r cached <&3
rc=$?
printf 'cached:%s:%s\n' "$rc" "$cached"
exit "$rc"`);
  assert.equal(result.exitCode, 0);
  assert.equal(result.stderr, '');
  assert.equal(result.stdout, 'n0:0:\nN0:0:\nN0-wins:0:\ncached:0:ABCD\n');
  assert.deepEqual(f.reads, [{ number: 1, failed: false, hex: initial.toString('hex') }]);
});

test('readwrite nonzero -N takes precedence over -n0 and refreshes before consuming', { timeout: 15000 }, async t => {
  const f = await fixture(t);
  const result = await execute(t, f, `exec 3<> input.bin || exit $?
read -n 0 -N 1 -u 3 value
rc=$?
printf 'N1-wins:%s:%s\n' "$rc" "$value"
if [ "$rc" != 0 ]; then exit "$rc"; fi
read -r cached <&3
rc=$?
printf 'cached:%s:%s\n' "$rc" "$cached"
exit "$rc"`);
  assert.equal(result.exitCode, 0);
  assert.equal(result.stderr, '');
  assert.equal(result.stdout, 'N1-wins:0:A\ncached:0:BCD\n');
  assert.deepEqual(f.reads, [
    { number: 1, failed: false, hex: initial.toString('hex') },
    { number: 2, failed: false, hex: initial.toString('hex') },
  ]);
});
