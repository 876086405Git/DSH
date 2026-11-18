import assert from 'node:assert/strict';
import { test } from 'node:test';
import { once } from 'node:events';
import { createPythonBackend } from '../../ohos/process/python-backend.mjs';

test('missing host refuses honestly; no accidental OS Python fallback', () => {
  const backend = createPythonBackend();
  assert.equal(backend.supports('python3'), true);
  assert.throws(() => backend.spawn('python3', ['-c', 'print(1)']), { code: 'ERR_OHOS_PYTHON_UNAVAILABLE' });
});
test('pip aliases, streams and structured cwd/env are forwarded independently', async () => {
  let spec, settle;
  const completion = new Promise(resolve => { settle = resolve; });
  const native = { contract: 'dsh-python-1', start(value) { spec = value; return { completion, cancel() {} }; } };
  const child = createPythonBackend({ native }).spawn('pip', ['--version'], { cwd: '/work', env: { LANG: 'C.UTF-8' } });
  const out = [], err = []; child.stdout.on('data', b => out.push(b)); child.stderr.on('data', b => err.push(b));
  const closed = once(child, 'close');
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(spec.argv, ['-m', 'pip', '--version']); assert.equal(spec.cwd, '/work'); assert.deepEqual(spec.env, { LANG: 'C.UTF-8' });
  spec.stdout(Buffer.from('one\0')); spec.stderr(Buffer.from('two'));
  settle({ exitCode: 7 }); assert.deepEqual(await closed, [7, null]);
  assert.equal(Buffer.concat(out).toString(), 'one\0'); assert.equal(Buffer.concat(err).toString(), 'two');
});
test('timeout requests cancellation but close waits for native drain/completion', async () => {
  let settle, cancelled = false;
  const completion = new Promise(resolve => { settle = resolve; });
  const native = { contract: 'dsh-python-1', start() { return { completion, cancel() { cancelled = true; } }; } };
  const child = createPythonBackend({ native }).spawn('python', [], { timeoutMs: 5 });
  const closed = once(child, 'close');
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(cancelled, true); assert.equal(child.exitCode, null);
  assert.throws(() => child.kill('SIGKILL'), { code: 'ERR_OHOS_PYTHON_SIGNAL' });
  settle({ exitCode: null, signal: 'SIGTERM' }); assert.deepEqual(await closed, [null, 'SIGTERM']);
});
test('bad timeout rejects before any host execution', () => {
  const native = { contract: 'dsh-python-1', start() { assert.fail('must not start'); } };
  assert.throws(() => createPythonBackend({ native }).spawn('python3', [], { timeoutMs: NaN }), RangeError);
});

test('abort before host start is retained and forwarded', async () => {
  let cancelled = 0, settle;
  const completion = new Promise(resolve => { settle = resolve; });
  const native = { contract: 'dsh-python-1', start() { return { completion, cancel() { cancelled++; } }; } };
  const child = createPythonBackend({ native }).spawn('python3', ['-c', 'pass']);
  const closed = once(child, 'close'); child.kill();
  await new Promise(resolve => setImmediate(resolve)); assert.equal(cancelled, 0);
  settle({ exitCode: 130 }); await closed;
});
test('existing runtime facade collects, seals and waits for actual completion', async () => {
  const { createPythonRuntimeBackend } = await import('../../ohos/process/python-backend.mjs');
  let spec, settle;
  const completion = new Promise(resolve => { settle = resolve; });
  const native = { contract: 'dsh-python-1', start(value) { spec = value; return { completion, cancel() {} }; } };
  const backend = createPythonRuntimeBackend({ native, createCollector() { return { chunks: [], push(b) { this.chunks.push(b); }, seal() { this.sealed = true; } }; } });
  const handle = backend.spawn({ argv: ['python3', '-c', 'print(1)'], graceMs: 1000, stdio: { stdin: 'ignore', stdout: { maxBytes: 10 }, stderr: 'pipe' } });
  await new Promise(resolve => setImmediate(resolve)); spec.stdout(Buffer.from('1\n')); settle({ exitCode: 0, signal: null });
  assert.deepEqual(await handle.done, { exitCode: 0, signal: null });
  assert.equal(handle.collected.stdout.sealed, true); assert.equal(await handle.waitForExit(), true);
});
test('abort after spawn but before deferred entry does not start native work', async () => {
  let starts = 0;
  const native = { contract: 'dsh-python-1', start() { starts++; return { completion: Promise.resolve({ exitCode: 0 }), cancel() {} }; } };
  const controller = new AbortController();
  const child = createPythonBackend({ native }).spawn('python3', [], { signal: controller.signal });
  const closed = once(child, 'close'); controller.abort(); await closed; assert.equal(starts, 0);
});
test('repeated termination forwards exactly one native cancellation', async () => {
  let settle, cancels = 0;
  const completion = new Promise(resolve => { settle = resolve; });
  const native = { contract: 'dsh-python-1', start() { return { completion, cancel() { cancels++; } }; } };
  const child = createPythonBackend({ native }).spawn('python3', []);
  const closed = once(child, 'close'); await new Promise(resolve => setImmediate(resolve));
  child.kill(); child.kill(); settle({ exitCode: 130 }); await closed; assert.equal(cancels, 1);
});
