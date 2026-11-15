import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
const version = JSON.parse(readFileSync(new URL('../../ohos/node-version.json', import.meta.url), 'utf8'));
assert.equal(process.versions.node, version);
assert.equal(typeof WebAssembly, 'undefined');
assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], undefined);
assert.equal(globalThis[Symbol.for('dsh.go.ohos.net')], undefined);
assert.equal(globalThis[Symbol.for('dsh.go.ohos.publication')], undefined);
const keys = Object.keys(process._linkedBinding('dsh_ohos_publication')).sort();
assert.deepEqual(keys, ['getOwnershipMarker', 'getSystemBuildIdentity', 'lockExclusive', 'renameNoReplace', 'setOwnershipMarker']);
if (process.env.OHOS_HOST_MAIN_SENTINEL) writeFileSync(process.env.OHOS_HOST_MAIN_SENTINEL, 'main');
console.log(JSON.stringify({ linuxContractOnly: true, platform: process.platform,
  linked: keys, execArgv: process.execArgv, arguments: process.argv.slice(2) }));
