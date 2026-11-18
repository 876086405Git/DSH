// Test-only crash window: the real guard has durably recorded trying before
// this synchronous commit callback blocks. The parent sends actual SIGKILL.
import { randomUUID } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const tree = resolve(process.argv[2]), home = resolve(process.argv[3]), barrier = resolve(process.argv[4]);
const { openOwnershipLedger } = await import(pathToFileURL(join(tree, 'runtime/ohos/publication/ledger.mjs')));
const { openAtomicFuse, readSystemBuildIdentity } = await import(pathToFileURL(join(tree, 'runtime/ohos/publication/atomic-fuse.mjs')));
const binding = process._linkedBinding('dsh_ohos_publication');
const build = readSystemBuildIdentity(binding.getSystemBuildIdentity);
const ledger = await openOwnershipLedger({ directory: join(home, 'ohos-ownership'), ownerId: randomUUID(),
  lockExclusive: binding.lockExclusive, setOwnershipMarker: binding.setOwnershipMarker,
  getOwnershipMarker: binding.getOwnershipMarker });
const fuse = await openAtomicFuse({ storage: ledger.publicationAtomicState,
  ownerId: ledger.ownerId, systemVersion: build.systemVersion });
await fuse.run(() => {
  writeFileSync(barrier, JSON.stringify({ phase: 'durable-trying-before-native',
    systemVersion: build.systemVersion, identity: build.identity, ownerId: ledger.ownerId }) + '\n');
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
});
