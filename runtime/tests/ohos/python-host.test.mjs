import assert from 'node:assert/strict';
import { test } from 'node:test';
import { once } from 'node:events';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createPythonBackend } from '../../ohos/process/python-backend.mjs';
import { createPythonProbeHost } from '../../ohos/python/probe-host.mjs';
const native = createPythonProbeHost(resolve(process.env.OHOS_PYTHON_PROBE));
const backend = createPythonBackend({ native });
async function run(args, options = {}) {
  const child = backend.spawn('python3', args, options), stdout = [], stderr = [];
  child.stdout.on('data', b => stdout.push(b)); child.stderr.on('data', b => stderr.push(b));
  const [exitCode] = await once(child, 'close');
  return { exitCode, stdout: Buffer.concat(stdout).toString(), stderr: Buffer.concat(stderr).toString() };
}
test('Node adapter executes shared-library Python repeatedly with absolute file IO and argv', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'python-native-'));
  try {
    const file = join(dir, 'value.txt');
    const result = await run(['-c', `import sys\nopen(sys.argv[1], 'w').write('saved')\nprint(sys.argv[2])\nprint('err',file=sys.stderr)`, file, '参数']);
    assert.deepEqual(result, { exitCode: 0, stdout: '参数\n', stderr: 'err\n' });
    assert.equal(readFileSync(file, 'utf8'), 'saved');
    assert.equal((await run(['-c', 'print(2)'])).stdout, '2\n');
  } finally { rmSync(dir, { recursive: true }); }
});
test('main Node loop stays responsive and cooperative cancel completes real Python', async () => {
  const child = backend.spawn('python3', ['-c', 'while True: pass']);
  const closed = once(child, 'close');
  setTimeout(() => child.kill(), 30);
  assert.equal((await closed)[0], 130);
});
test('unsupported cwd fails explicitly instead of mutating Node cwd', async () => {
  const before = process.cwd();
  await assert.rejects(run(['-c', 'pass'], { cwd: '/different' }), { code: 'ERR_OHOS_PYTHON_CWD' });
  assert.equal(process.cwd(), before);
});
test('real Python emits before its long computation exits', async () => {
  const child = backend.spawn('python3', ['-c', "import time\nprint('early', flush=True)\nend=time.monotonic()+0.15\nwhile time.monotonic()<end: pass\nprint('late')"]);
  const closed = once(child, 'close');
  const [chunk] = await once(child.stdout, 'data');
  assert.match(chunk.toString(), /early/); assert.equal(child.exitCode, null);
  await closed;
});
test('cancel immediately after spawn skips native execution', async () => {
  const child = backend.spawn('python3', ['-c', 'while True: pass']);
  const closed = once(child, 'close'); child.kill();
  assert.deepEqual(await closed, [null, 'SIGTERM']);
});
test('unsupported stdin bytes fail before execution and native reads report explicit error', async () => {
  const child = backend.spawn('python3', ['-c', "print('must-not-run')"]);
  const closed = once(child, 'close'), chunks = [];
  child.stdout.on('data', bytes => chunks.push(bytes)); child.stderr.resume(); child.stdin.end('requested input');
  assert.equal((await closed)[0], 1); assert.equal(Buffer.concat(chunks).length, 0);
  const result = await run(['-c', 'input()']); assert.equal(result.exitCode, 1); assert.match(result.stderr, /ERR_OHOS_PYTHON_STDIN/);
});
