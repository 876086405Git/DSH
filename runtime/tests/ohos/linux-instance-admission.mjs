import assert from 'node:assert/strict';
import { open, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [mode, source, directory, result] = process.argv.slice(2);
if (mode === 'hold') {
  const file = await open(join(directory, '.lock'), 'a+', 0o600);
  process._linkedBinding('dsh_ohos_publication').lockExclusive(file.fd);
  const info = await file.stat();
  process.stdout.write(JSON.stringify({ locked: true, dev: info.dev, ino: info.ino }) + '\n');
  await new Promise(resolve => process.stdin.once('data', resolve));
  await file.close();
} else if (mode === 'discard') {
  // The production composition: owner.mjs takes the lock captured by the sole preload.
  const { discardLinuxInstallation } = await import(pathToFileURL(join(source, 'runtime/ohos/linux/owner.mjs')));
  let removed = null, errorCode = null;
  try { ({ removed } = await discardLinuxInstallation({ directory })); } catch (error) { errorCode = error.code ?? 'unknown'; }
  await writeFile(result, JSON.stringify({ removed, errorCode }, null, 2) + '\n', { flag: 'wx' });
} else {
  const { LinuxInstallationOwner } = await import(pathToFileURL(join(source, 'runtime/ohos/linux/owner.mjs')));
  const asset = { path: '/unused-test-boundary', bytes: 1, sha256: '1'.repeat(64), expandedBytes: 1024, expandedSha256: '2'.repeat(64) };
  let downloads = 0, created = 0, errorCode;
  const owner = new LinuxInstallationOwner({ directory, nativeLibraryDirectory: '/unused-native-boundary', manifest:
    { bios: asset, kernel: asset, tools: asset, bootstrap: asset, empty: asset, archive: { url: 'https://fixture.invalid/base', bytes: 1, sha256: '3'.repeat(64) } } }, {
    download: { fetch() { downloads++; throw Object.assign(new Error('stop at explicit download boundary'), { code: 'ERR_RESEARCH_DOWNLOAD' }); } },
    createSession() { created++; throw new Error('must not create a VM'); },
  });
  try { await owner.install(); } catch (error) { errorCode = error.code; }
  const retirement = await owner.dispose();
  const info = await stat(directory), lock = await stat(join(directory, '.lock'));
  const observed = { downloads, created, errorCode, rootMode: info.mode & 0o777, lockDev: lock.dev, lockIno: lock.ino, retirement };
  await writeFile(result, JSON.stringify(observed, null, 2) + '\n', { flag: 'wx' });
  assert.equal(downloads, mode === 'busy' ? 0 : 1, 'a different process holding the genuine flock must prevent downloading');
  assert.equal(created, 0);
  assert.equal(info.mode & 0o777, 0o700, 'only the actual dedicated root FD must be tightened');
  if (mode === 'busy') assert.equal(errorCode, 'ERR_OHOS_LINUX_BUSY');
}
