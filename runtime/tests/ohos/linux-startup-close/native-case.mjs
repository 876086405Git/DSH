import assert from 'node:assert/strict';
import { Socket } from 'node:net';
import { once } from 'node:events';
import { readdir, readlink } from 'node:fs/promises';

const [library, config, disk, fault, prior] = process.argv.slice(2);
const loaded = { exports: {} }; process.dlopen(loaded, library);
const owner = loaded.exports.create(config);
const socket = new Socket({ fd: owner.fd, readable: true, writable: true });
socket.on('error', () => {}); const end = once(socket, 'end'); socket.resume();
const guard = setTimeout(() => { throw new Error('startup close fixture watchdog'); }, 3000);
try {
  await end; owner.requestStop(); const joining = owner.join();
  assert.equal(joining, owner.join()); const native = await joining;
  const live = [], priorLive = [];
  for (const name of await readdir('/proc/self/fd')) {
    try {
      const path = await readlink('/proc/self/fd/' + name);
      if (path === disk) live.push(Number(name));
      if (path === prior) priorLive.push(Number(name));
    } catch {}
  }
  console.log('STARTUP_NATIVE ' + JSON.stringify({ native, live, priorLive, fault }));
  assert.equal(native.joined, true); assert.equal(native.joinAttempted, true);
  assert.equal(native.joinError, 0); assert.equal(native.fdRetirement.retired, true);
  assert.equal(native.ramRetirement.eligible, false); assert.equal(native.waitError, 0);
  assert.equal(live.length, fault === 'retain-eio' ? 1 : 0);
  assert.equal(priorLive.length, 0, 'rollback continues closing the other opened drive');
  assert.equal(native.retirementError, fault === 'retain-eio');
  assert.equal(native.apiResult, fault === 'retain-eio' ? -8 : -1);
} finally { clearTimeout(guard); socket.destroy(); }
