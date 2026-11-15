import assert from 'node:assert/strict';
import { Socket } from 'node:net';
import { once } from 'node:events';
import { readdir, readlink } from 'node:fs/promises';
const [library, config, disk] = process.argv.slice(2);
const module = { exports: {} }; process.dlopen(module, library);
const owner = module.exports.create(config);
const socket = new Socket({ fd: owner.fd, readable: true, writable: true });
socket.on('error', () => {}); socket.resume();
const ended = once(socket, 'end');
const timer = setTimeout(() => { throw new Error('partial-start fixture watchdog'); }, 3000);
await ended; owner.requestStop(); const result = await owner.join(); clearTimeout(timer); socket.destroy();
assert.equal(result.joined, true); assert.equal(result.apiResult, -2); assert.equal(result.joinError, 0);
const openDrives = [];
for (const fd of await readdir('/proc/self/fd')) {
  try { if (await readlink('/proc/self/fd/' + fd) === disk) openDrives.push(Number(fd)); } catch {}
}
assert.equal(openDrives.length, 1, 'actual pre-opened drive still has a live fd after partial setup failure and join');
console.log(JSON.stringify({ scope: 'Actual missing fs export after actual drive open; no syscall fault injection', result, openDrives, expectedDriveRetirement: 'unknown' }));
assert.equal(result.retirementError, null, 'joined thread is not evidence that partial-start drives retired');
