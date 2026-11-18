import assert from 'node:assert/strict';
import { readFile, readdir, stat } from 'node:fs/promises';
import { linkSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { ownerFixture, until } from './linux-control-fixture.mjs';

const [mode, directory] = process.argv.slice(2), cleanups = [];
assert.equal(typeof WebAssembly, 'undefined');
assert.throws(() => spawnSync(process.execPath, ['--version']), { code: 'ERR_OHOS_SIM_SPAWN' });
assert.throws(() => linkSync('/no-source', '/no-target'), { code: 'EACCES' });
assert.throws(() => process.dlopen({}, '/no-addon'), { code: 'ERR_OHOS_SIM_DLOPEN' });
const send = value => process.stdout.write(JSON.stringify({ pid: process.pid, ...value }) + '\n');
const f = await ownerFixture({ after(fn) { cleanups.push(fn); } }, mode === 'crash'
  ? { open: false } : mode === 'debt' ? { nativeResult: { joined: false, retirementError: null, apiResult: null } } : {});
let downloads = 0;
const fetch = f.internals.download.fetch;
f.internals.download.fetch = (...args) => { downloads++; if (mode === 'reject') throw new Error('rejected retained owner cannot download'); return fetch(...args); };
const owner = f.createOwner({ directory }), installing = owner.install();
async function disk() {
  const attempt = (await readdir(directory)).find(name => name.startsWith('.installation-'));
  const record = JSON.parse(await readFile(join(directory, attempt, 'instance.json'), 'utf8'));
  const path = join(directory, attempt, 'target.ext4'), info = await stat(path), bytes = await readFile(path);
  return { path, dev: info.dev, ino: info.ino, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex'), record };
}
try {
  if (mode === 'reject') {
    let errorCode; try { await installing; } catch (error) { errorCode = error.code; }
    const retirement = await owner.dispose();
    send({ event: 'rejected', errorCode, downloads, created: f.counts().created, retirement });
  } else if (mode === 'crash') {
    await until(() => f.counts().created === 1);
    send({ event: 'booting', disk: await disk(), fixtureRoot: f.directory });
    await new Promise(resolve => process.stdin.once('data', resolve));
    throw new Error('crash actor must be killed by its coordinator');
  } else {
    const { active } = await installing, retirement = await owner.dispose();
    send({ event: mode === 'debt' ? 'debt' : 'clean', disk: await disk(), retirement, active, fixtureRoot: f.directory });
    if (mode === 'debt') await new Promise(resolve => process.stdin.once('data', resolve));
  }
} finally { for (const cleanup of cleanups) await cleanup(); }
