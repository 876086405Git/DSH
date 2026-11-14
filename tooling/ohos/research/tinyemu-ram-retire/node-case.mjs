import assert from 'node:assert/strict';
import { Socket } from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';

const [library, config, mode] = process.argv.slice(2);
const module = { exports: {} };
process.dlopen(module, library);
const native = module.exports;
const owner = native.create(config);
const socket = new Socket({ fd: owner.fd, readable: true, writable: true });
let output = '';
socket.on('data', bytes => { output += bytes.toString(); });
socket.on('error', () => {});
assert.throws(() => owner.join(), { code: 'ERR_OHOS_LINUX_STOP_REQUIRED' });
if (mode !== 'early-stop') {
  const deadline = Date.now() + 5000;
  while (['poweroff', 'fatal', 'missing'].includes(mode) ? !socket.destroyed : !output.includes('MEMORY-PROBE-READY\n')) {
    assert.ok(Date.now() < deadline, 'fixture startup deadline');
    await delay(2);
  }
}
owner.requestStop();
const promise = owner.join();
assert.equal(owner.join(), promise);
const result = await promise;
const measured = native.__retentionStats();
// Preserve the independent measurement even when the baseline fails below.
console.log(JSON.stringify({ phase: 'observed', mode, result, measured,
  touchSource: 'test-only host mallocz wrapper, not guest instructions', scope: 'actual Node async join and TinyEMU objects; no SDK/device/PSS claim' }));
socket.destroy();
assert.equal(result.ownerQuarantined, true);
assert.throws(() => native.create(config), { code: 'ERR_OHOS_LINUX_OWNER_QUARANTINED' });
if (mode === 'join-error' || mode === 'cancelled') {
  assert.equal(result.joined, false);
  assert.equal(result.apiResult, null);
  assert.equal(result.retirementError, null);
  assert.equal(result.ramRetirement, null);
  assert.equal(measured.adviceCalls, 0);
  assert.equal(measured.residentPages, null);
} else {
  assert.equal(result.joined, true);
  assert.equal(result.retirementError, mode === 'disk-error');
  assert.equal(result.apiResult, mode === 'fatal' ? -9 : mode === 'missing' ? -1 : mode === 'disk-error' ? -8 : mode === 'poweroff' ? -3 : -4);
  const retirement = result.ramRetirement;
  if (mode !== 'missing') {
    assert.equal(measured.mincoreBeforeResult, 0);
    assert.equal(measured.mincoreResult, 0);
    assert.equal(measured.residentBeforePages, measured.eligibleBytes / measured.pageBytes);
  }
  if (['fatal', 'missing', 'disk-error'].includes(mode)) {
    assert.equal(measured.adviceCalls, 0);
    assert.equal(retirement.eligible, false);
    assert.equal(retirement.attempted, false);
    assert.equal(retirement.advisedBytes, 0);
    if (mode !== 'missing') assert.equal(measured.residentPages, measured.eligibleBytes / measured.pageBytes);
  } else {
    // First red assertion is an observed missing system call, not a missing field.
    assert.equal(measured.adviceCalls, 1);
    assert.equal(retirement.eligible, true);
    assert.equal(retirement.attempted, true);
    assert.equal(retirement.trackedBytes, 16 * 1024 * 1024);
    assert.equal(retirement.eligibleBytes, measured.eligibleBytes);
    assert.equal(measured.mappingRetained, true);
    assert.equal(measured.boundaryBytesPreserved, true);
    if (mode === 'advice-error') {
      assert.equal(measured.residentPages, measured.eligibleBytes / measured.pageBytes);
      assert.equal(retirement.advisedBytes, 0);
      assert.equal(retirement.errorCode, 5);
    } else {
      assert.equal(measured.residentPages, 0);
      assert.equal(retirement.advisedBytes, measured.eligibleBytes);
      assert.equal(retirement.errorCode, 0);
    }
  }
}
assert.equal(owner.join(), promise);
assert.equal(native.__retentionStats().adviceCalls, measured.adviceCalls, 'repeated join must not advise again');
console.log(JSON.stringify({ phase: 'asserted', status: 'PASS', mode }));
