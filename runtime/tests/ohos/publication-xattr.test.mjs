import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, open, rm, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';

assert.equal(process.version, 'v24.22.1');
const strict = process.env.DSH_TEST_XATTR_STRICT === '1';
if (strict) {
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
  assert.equal(typeof WebAssembly, 'undefined');
  assert.throws(() => spawnSync(process.execPath, ['--version']), { code: 'ERR_OHOS_SIM_SPAWN' });
  assert.throws(() => fs.linkSync('/dsh-no-source', '/dsh-no-target'), { code: 'EACCES' });
  assert.throws(() => process.dlopen({}, '/dsh-no-addon.node'), { code: 'ERR_OHOS_SIM_DLOPEN' });
}
const binding = process._linkedBinding('dsh_ohos_publication');
async function fixture(fn) {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-publication-xattr-'));
  try { await fn(join(directory, 'owned')); }
  finally { await rm(directory, { recursive: true, force: true }); }
}

test('real fd marker: missing, create, fsync, close/reopen; write-only file handle works', async () => {
  await fixture(async path => {
    const token = randomUUID(), handle = await open(path, 'wx', 0o600);
    try {
      assert.equal(binding.getOwnershipMarker(handle.fd), undefined);
      assert.equal(binding.setOwnershipMarker(handle.fd, token), undefined);
      await handle.sync();
      assert.equal(binding.getOwnershipMarker(handle.fd), token);
    } finally { await handle.close(); }
    const reopened = await open(path, 'r');
    try { assert.equal(binding.getOwnershipMarker(reopened.fd), token); }
    finally { await reopened.close(); }
  });
});

test('XATTR_CREATE never overwrites; exception carries errno/syscall and no marker/path/content', async () => {
  await fixture(async path => {
    const first = randomUUID(), second = randomUUID(), handle = await open(path, 'wx', 0o600);
    try {
      binding.setOwnershipMarker(handle.fd, first);
      assert.throws(() => binding.setOwnershipMarker(handle.fd, second), error => {
        assert.equal(error.code, 'EEXIST'); assert.equal(error.errno, -17); assert.equal(error.syscall, 'fsetxattr');
        assert.ok(!error.message.includes(first) && !error.message.includes(second) && !error.message.includes(path));
        return true;
      });
      assert.equal(binding.getOwnershipMarker(handle.fd), first);
    } finally { await handle.close(); }
  });
});

test('strict argument validation does not create a marker; invalid descriptors preserve EBADF', async () => {
  await fixture(async path => {
    const handle = await open(path, 'wx', 0o600);
    try {
      for (const value of [undefined, null, 1, {}, 1n]) {
        assert.throws(() => binding.setOwnershipMarker(handle.fd, value), { code: 'ERR_INVALID_ARG_TYPE' });
      }
      for (const value of ['', 'bad\0token', 'x'.repeat(65537)]) {
        assert.throws(() => binding.setOwnershipMarker(handle.fd, value), { code: 'ERR_INVALID_ARG_VALUE' });
      }
      assert.equal(binding.getOwnershipMarker(handle.fd), undefined);
      for (const value of [-1, NaN, Infinity, 1.5, 2 ** 32]) {
        assert.throws(() => binding.setOwnershipMarker(value, randomUUID()), { code: 'ERR_INVALID_ARG_VALUE' });
        assert.throws(() => binding.getOwnershipMarker(value), { code: 'ERR_INVALID_ARG_VALUE' });
      }
      for (const value of ['1', {}, 1n]) {
        assert.throws(() => binding.getOwnershipMarker(value), { code: 'ERR_INVALID_ARG_TYPE' });
      }
      assert.throws(() => binding.setOwnershipMarker(), { code: 'ERR_INVALID_ARG_TYPE' });
      assert.throws(() => binding.getOwnershipMarker(), { code: 'ERR_INVALID_ARG_TYPE' });
      assert.throws(() => binding.setOwnershipMarker(2 ** 31 - 1, randomUUID()), { code: 'EBADF', errno: -9, syscall: 'fsetxattr' });
      assert.throws(() => binding.getOwnershipMarker(2 ** 31 - 1), { code: 'EBADF', errno: -9, syscall: 'fgetxattr' });
    } finally { await handle.close(); }
  });
});

test('UTF-8 marker length is read without truncation', async () => {
  await fixture(async path => {
    const handle = await open(path, 'wx', 0o600), token = '归属-😀-' + 'x'.repeat(1024);
    try {
      binding.setOwnershipMarker(handle.fd, token);
      assert.equal(binding.getOwnershipMarker(handle.fd), token);
    } finally { await handle.close(); }
  });
});

test('held descriptor pins old inode and marker while replacement path has no ownership marker', async () => {
  await fixture(async path => {
    const handle = await open(path, 'wx', 0o600), token = randomUUID();
    let foreign;
    try {
      binding.setOwnershipMarker(handle.fd, token); await handle.sync();
      const original = await handle.stat({ bigint: true });
      await unlink(path); await writeFile(path, 'foreign file content', { flag: 'wx', mode: 0o600 });
      foreign = await open(path, 'r');
      const replacement = await foreign.stat({ bigint: true });
      assert.notEqual(replacement.ino, original.ino);
      assert.equal(binding.getOwnershipMarker(handle.fd), token);
      assert.equal(binding.getOwnershipMarker(foreign.fd), undefined);
      assert.equal(await foreign.readFile('utf8'), 'foreign file content');
    } finally { await foreign?.close(); await handle.close(); }
  });
});

test('real procfs unsupported xattr is ENOTSUP, not missing marker', async () => {
  const handle = await open('/proc/self/status', 'r');
  try {
    assert.throws(() => binding.getOwnershipMarker(handle.fd), { code: 'ENOTSUP', errno: -95, syscall: 'fgetxattr' });
  } finally { await handle.close(); }
});

test.after(() => console.log(JSON.stringify({ scope: 'Linux actual fd xattrs only', strictConstraintsVerified: strict, targetOhos: 'NOT_RUN' })));
