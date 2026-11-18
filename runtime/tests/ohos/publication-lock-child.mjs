import assert from 'node:assert/strict';
import fs from 'node:fs';
import { open } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { spawnSync } from 'node:child_process';

const [lockPath, strictFlag] = process.argv.slice(2);
const strict = strictFlag === '--strict';
if (strict) {
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
  assert.equal(typeof WebAssembly, 'undefined');
  assert.throws(() => spawnSync(process.execPath, ['--version']), { code: 'ERR_OHOS_SIM_SPAWN' });
  assert.throws(() => fs.linkSync('/dsh-no-source', '/dsh-no-target'), { code: 'EACCES' });
  assert.throws(() => process.dlopen({}, '/dsh-no-addon.node'), { code: 'ERR_OHOS_SIM_DLOPEN' });
}
const binding = process._linkedBinding('dsh_ohos_publication');
assert.equal(typeof binding.lockExclusive, 'function');
const send = value => console.log(JSON.stringify({ pid: process.pid, ...value }));
const lines = createInterface({ input: process.stdin });
let handle;
send({ event: 'ready', strictConstraintsVerified: strict, node: process.version, execArgv: process.execArgv });
try {
  for await (const line of lines) {
    if (line === 'go') {
      assert.equal(handle, undefined);
      handle = await open(lockPath, 'a+', 0o600);
      const stat = await handle.stat({ bigint: true });
      try {
        assert.equal(binding.lockExclusive(handle.fd), undefined);
        send({ event: 'attempt', acquired: true, identity: { dev: String(stat.dev), ino: String(stat.ino) } });
      } catch (error) {
        send({ event: 'attempt', acquired: false, error: { name: error.name, code: error.code, errno: error.errno, syscall: error.syscall } });
        await handle.close(); handle = undefined;
        break;
      }
    } else if (line === 'close') {
      assert.ok(handle);
      await handle.close(); handle = undefined;
      send({ event: 'closed' });
    } else if (line === 'exit') {
      break;
    } else {
      throw new Error('Unexpected coordinator command');
    }
  }
} finally {
  await handle?.close();
  lines.close();
  process.stdin.destroy();
}
