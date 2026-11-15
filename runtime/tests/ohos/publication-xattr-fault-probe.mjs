import assert from 'node:assert/strict';
import { mkdtemp, open, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const binding = process._linkedBinding('dsh_ohos_publication');
const directory = await mkdtemp(join(tmpdir(), 'dsh-xattr-fault-'));
const handle = await open(join(directory, 'owned'), 'wx', 0o600);
try {
  const mode = process.env.DSH_TEST_XATTR_GET_FAULT || process.env.DSH_TEST_XATTR_SET_FAULT;
  let outcome;
  if (process.env.DSH_TEST_XATTR_SET_FAULT) {
    const code = mode === 'io' ? 'EIO' : 'ENOTSUP';
    const errno = mode === 'io' ? -5 : -95;
    assert.throws(() => binding.setOwnershipMarker(handle.fd, 'public-test-token'), { code, errno, syscall: 'fsetxattr' });
    assert.equal(binding.getOwnershipMarker(handle.fd), undefined);
    outcome = code;
  } else if (mode === 'missing-after-size') {
    assert.equal(binding.getOwnershipMarker(handle.fd), undefined); outcome = 'undefined';
  } else if (mode === 'shrink-after-size' || mode === 'empty') {
    const value = mode === 'empty' ? '' : 'ok';
    assert.equal(binding.getOwnershipMarker(handle.fd), value); outcome = 'exact actual length';
  } else {
    const code = mode === 'unsupported' ? 'ENOTSUP' : 'ERANGE';
    const errno = mode === 'unsupported' ? -95 : -34;
    assert.throws(() => binding.getOwnershipMarker(handle.fd), { code, errno, syscall: 'fgetxattr' });
    outcome = code;
  }
  console.log(JSON.stringify({ mode, outcome, status: 'PASS', injectedSyscallOutcome: true, targetDeviceClaim: false }));
} finally { await handle.close(); await rm(directory, { recursive: true, force: true }); }
