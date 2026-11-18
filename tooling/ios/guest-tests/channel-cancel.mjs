import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';
const base = dirname(fileURLToPath(import.meta.url));
const [mode = 'fulfilled'] = process.argv.slice(2);
const input = {};
for (const name of ['ADDON', 'ROOT', 'WORKSPACE', 'TEMP', 'PROTECTED']) {
  input[name] = process.env['DSH_GUEST_TEST_' + name];
  assert(input[name] && input[name].startsWith('/'), 'absolute test path required: ' + name);
}
const { createNativeGuestChannel } = await import('../../../runtime/ios/guest/native-channel.mjs');
const { SerialGuestChannel } = await import('../../../runtime/ios/guest/channel.mjs');
const native = createRequire(import.meta.url)(input.ADDON);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const requests = command => ({ mounts: [{ host: input.WORKSPACE, guest: '/workspace' },
  { host: input.TEMP, guest: '/tmp' }], mode: 'workspace-write', cwd: '/workspace',
  argv: ['/bin/sh', '-c', command], env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin' }, stdin: '' });
const channel = new SerialGuestChannel(createNativeGuestChannel(native,
  { root: input.ROOT, protectedPaths: [input.PROTECTED] }));
const abort = new AbortController();
const began = performance.now();
let consumerEnded, consumerEntered = false, expectedError;
try {
  await channel.execute(requests("trap '' TERM; printf HELD; while :; do :; done"), {
    signal: abort.signal, graceMs: 200,
    output: async (stream, bytes) => {
      assert.equal(stream, 'stdout'); assert.equal(bytes.toString(), 'HELD');
      assert.equal(consumerEntered, false); consumerEntered = true;
      setTimeout(() => abort.abort(), 50);
      if (mode === 'pending') return new Promise(() => {});
      await sleep(500);
      consumerEnded = performance.now();
      if (mode === 'rejected') throw new Error('test consumer rejected');
    },
  });
  assert.fail('cancelled operation unexpectedly resolved');
} catch (error) { expectedError = error; }
const settledAt = performance.now();
assert(consumerEntered);
if (mode === 'pending') {
  assert.equal(consumerEnded, undefined);
  assert.equal(channel.state, 'faulted');
  assert.equal(expectedError.code, 'ERR_IOS_GUEST_FAULTED');
} else {
  assert(consumerEnded !== undefined && settledAt >= consumerEnded);
  if (mode === 'rejected') {
    assert.equal(channel.state, 'faulted');
    assert.equal(expectedError.code, 'ERR_IOS_GUEST_FAULTED');
  } else {
    assert.equal(expectedError.code, 'ABORT_ERR'); assert.equal(channel.state, 'idle');
    let nextOutput = '';
    const next = await channel.execute(requests('printf next-real-guest'), {
      graceMs: 200, output: async (_, bytes) => { nextOutput += bytes; },
    });
    assert.equal(next.exitCode, 0); assert.equal(next.resourcesSettled, true);
    assert.equal(nextOutput, 'next-real-guest'); assert.equal(channel.state, 'idle');
  }
}
for (let i = 0; i < 200 && native.status().state === 'running'; i++) await sleep(10);
assert.equal(native.status().state, 'ready');
console.log(JSON.stringify({ mode, version: process.version, arch: process.arch,
  errorCode: expectedError.code, channel: channel.state, native: native.status(),
  elapsedMs: settledAt - began, consumerMs: consumerEnded === undefined ? null : consumerEnded - began,
  realConsumerFinishedBeforeSettlement: consumerEnded === undefined ? null : settledAt >= consumerEnded }));
