// Test-only handshake: after the real ReadWriteFs FileHandle.readFile returns,
// hold the search Worker before it can report a result. No product hook exists.
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { isMainThread } from 'node:worker_threads';
import { syncBuiltinESMExports } from 'node:module';

globalThis[Symbol.for('dsh.go.test.m4-4-io-gate')] = true;

if (!isMainThread && process.env.M4_4_SEARCH_FILE && process.env.M4_4_SEARCH_READY) {
  const open = fsp.open;
  fsp.open = async (path, ...args) => {
    const handle = await open(path, ...args);
    if (path === process.env.M4_4_SEARCH_FILE) {
      const readFile = handle.readFile.bind(handle);
      handle.readFile = async (...readArgs) => {
        await readFile(...readArgs);
        fs.writeFileSync(process.env.M4_4_SEARCH_READY, 'actual file read completed');
        setInterval(() => {}, 1000);
        await new Promise(() => {});
      };
    }
    return handle;
  };
  syncBuiltinESMExports();
}
