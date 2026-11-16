import assert from 'node:assert/strict';
import { LinuxInstallationOwner } from '../../ohos/linux/owner.mjs';
import { linuxHostPaths, linuxHostLock } from '../../ohos/linux/host-paths.mjs';

// owner imported the same capture module used by the sole production preload.
// Mutate both late environment and the linked-binding lookup after that point.
const original = linuxHostPaths(), lock = linuxHostLock();
assert.equal(original.directory, process.argv[2]); assert.equal(typeof lock, 'function');
let replacements = 0, downloads = 0;
process.env.DSH_GO_OHOS_LINUX_DIRECTORY = '/late-plugin-directory';
process.env.DSH_GO_OHOS_NATIVE_LIBRARY_DIR = '/late-plugin-native';
process._linkedBinding = () => { replacements++; return { lockExclusive() { replacements++; } }; };
assert.equal(linuxHostPaths(), original); assert.equal(linuxHostLock(), lock);
const asset = { path: '/unused-boundary', bytes: 1, sha256: '1'.repeat(64), expandedBytes: 1024, expandedSha256: '2'.repeat(64) };
const owner = new LinuxInstallationOwner({ ...original, manifest: { bios: asset, kernel: asset, tools: asset, bootstrap: asset, empty: asset,
  archive: { url: 'https://fixture.invalid/base', bytes: 1, sha256: '3'.repeat(64) } } }, { download: { fetch() { downloads++; throw new Error('must stay behind real lock'); } } });
await assert.rejects(owner.install(), { code: 'ERR_OHOS_LINUX_BUSY' });
await owner.dispose(); assert.equal(replacements, 0); assert.equal(downloads, 0);
console.log(JSON.stringify({ captured: true, replacements, downloads }));
