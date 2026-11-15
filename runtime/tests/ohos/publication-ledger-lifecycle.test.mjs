import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { createAtomicPublisher } from '../../ohos/publication/atomic.mjs';
import { openOwnershipLedger } from '../../ohos/publication/ledger.mjs';

const native = process._linkedBinding('dsh_ohos_publication');
const denyLink = async () => { throw Object.assign(new Error('link denied by fixture'), { code: 'EACCES' }); };
const io = { ...fs, link: denyLink };
const missing = path => assert.rejects(fs.lstat(path), { code: 'ENOENT' });
const records = f => fs.readFile(join(f.ledgerDirectory, 'ledger.json'), 'utf8').then(JSON.parse,
  error => { if (error.code === 'ENOENT') return { entries: [] }; throw error; });
async function fixture(t) {
  const directory = await fs.mkdtemp(join(tmpdir(), 'dsh-publication-lifecycle-'));
  const source = join(directory, 'source'), target = join(directory, 'final');
  const ledgerDirectory = join(directory, 'ownership');
  let ledger;
  t.after(async () => {
    try { await ledger?.close(); }
    finally { await fs.rm(directory, { recursive: true, force: true }); }
  });
  ledger = await openOwnershipLedger({ directory: ledgerDirectory, ownerId: randomUUID(),
    lockExclusive: native.lockExclusive, setOwnershipMarker: native.setOwnershipMarker, getOwnershipMarker: native.getOwnershipMarker });
  await fs.writeFile(source, Buffer.alloc(100003, 67));
  return { directory, source, target, ledgerDirectory, ledger };
}
const publisher = (f, options = {}) => createAtomicPublisher({ renameNoReplace: native.renameNoReplace,
  ledger: f.ledger, fs: io, ...options });

test('the core rejects a missing ledger before it can create any temporary', () => {
  assert.throws(() => createAtomicPublisher({ renameNoReplace: native.renameNoReplace }), /durable ownership ledger/);
});

test('real persisted reservation precedes wx and identified state precedes the first write', async t => {
  const f = await fixture(t), sequence = [];
  let temporary, output;
  const observed = { ...io, async open(path, ...args) {
    if (args[0] === 'wx') {
      temporary = path;
      const entry = (await records(f)).entries[0];
      assert.equal(entry.path, path); assert.equal(entry.finalPath, f.target);
      assert.equal(entry.ownerId, f.ledger.ownerId); assert.equal(entry.pid, process.pid);
      assert.equal(entry.state, 'reserved'); await missing(path); sequence.push('durable-reserve-before-wx');
    }
    const handle = await fs.open(path, ...args);
    if (args[0] !== 'wx') return handle;
    output = handle;
    const writeFile = handle.writeFile.bind(handle), close = handle.close.bind(handle);
    let writes = 0;
    handle.writeFile = async bytes => {
      if (writes++ === 0) {
        const entry = (await records(f)).entries[0], info = await handle.stat({ bigint: true });
        assert.equal(entry.state, 'identified'); assert.equal(entry.dev, String(info.dev)); assert.equal(entry.ino, String(info.ino));
        assert.equal(native.getOwnershipMarker(handle.fd), entry.token);
        sequence.push('durable-identify-before-write');
      }
      await writeFile(bytes);
    };
    handle.close = async () => {
      await missing(path); assert.notEqual(handle.fd, -1);
      assert.equal((await records(f)).entries.length, 1);
      sequence.push('cleared-before-close'); await close();
    };
    return handle;
  } };
  const ledger = { ...f.ledger, async release(token) {
    await missing(temporary); assert.equal(output.fd, -1); sequence.push('closed-before-release');
    return f.ledger.release(token);
  } };
  assert.deepEqual(await publisher(f, { fs: observed, ledger })(f.source, f.target), { method: 'rename-noreplace' });
  assert.deepEqual(sequence, ['durable-reserve-before-wx', 'durable-identify-before-write', 'cleared-before-close', 'closed-before-release']);
  assert.deepEqual((await records(f)).entries, []);
  assert.deepEqual(await fs.readFile(f.source), await fs.readFile(f.target));
});

test('reservation failure cannot reach exclusive file creation', async t => {
  const f = await fixture(t), failure = new Error('injected reserve failure'); let writes = 0;
  const observed = { ...io, async open(path, ...args) { if (args[0] === 'wx') writes++; return fs.open(path, ...args); } };
  await assert.rejects(publisher(f, { fs: observed, ledger: { ...f.ledger, reserve() { throw failure; } } })(f.source, f.target), error => error === failure);
  assert.equal(writes, 0); await missing(f.target); assert.deepEqual((await records(f)).entries, []);
});

test('identify rejection causes no copy and safely releases the owned reservation', async t => {
  const f = await fixture(t), failure = new Error('injected identify failure'); let copied = false, temporary;
  const observed = { ...io, async open(path, ...args) {
    const handle = await fs.open(path, ...args);
    if (args[0] === 'wx') { temporary = path; handle.writeFile = async () => { copied = true; }; }
    return handle;
  } };
  await assert.rejects(publisher(f, { fs: observed, ledger: { ...f.ledger, identify() { throw failure; } } })(f.source, f.target), error => error === failure);
  assert.equal(copied, false); await missing(temporary); await missing(f.target);
  assert.deepEqual((await records(f)).entries, []);
});

test('a wx collision unregisters only its reservation and preserves the existing entry', async t => {
  const f = await fixture(t), collision = join(f.directory, 'existing-file'), own = join(f.directory, 'own-temp');
  await fs.writeFile(collision, 'unrelated');
  let selections = 0;
  await publisher(f, { selectTemporaryPath() { return selections++ === 0 ? collision : own; } })(f.source, f.target);
  assert.equal(selections, 2); assert.equal(await fs.readFile(collision, 'utf8'), 'unrelated'); await missing(own);
  assert.deepEqual((await records(f)).entries, []);
});

test('invalid temporary paths are rejected before any durable reservation or wx', async t => {
  const f = await fixture(t); let reservations = 0;
  const ledger = { ...f.ledger, reserve() { reservations++; throw new Error('must not be called'); } };
  for (const path of [f.source, f.target, join(f.directory, 'ownership/escape')]) {
    await assert.rejects(publisher(f, { ledger, selectTemporaryPath: () => path })(f.source, f.target), /distinct entry/);
  }
  assert.equal(reservations, 0); await missing(f.target);
});

test('fstat failure preserves the unknown created entry and its reserved record', async t => {
  const f = await fixture(t), failure = new Error('injected fstat failure'); let temporary;
  const observed = { ...io, async open(path, ...args) {
    const handle = await fs.open(path, ...args);
    if (args[0] === 'wx') { temporary = path; handle.stat = async () => { throw failure; }; }
    return handle;
  } };
  await assert.rejects(publisher(f, { fs: observed })(f.source, f.target), error => {
    assert(error instanceof AggregateError); assert.equal(error.cause, failure);
    assert(error.errors.some(item => item.code === 'ERR_OHOS_PUBLICATION_TEMP_UNIDENTIFIED')); return true;
  });
  assert.equal((await fs.stat(temporary)).size, 0);
  const entries = (await records(f)).entries;
  assert.equal(entries.length, 1); assert.equal(entries[0].path, temporary); assert.equal(entries[0].state, 'reserved');
  await missing(f.target);
});

test('copy failure unlinks while its inode is still held, then closes and releases', async t => {
  const f = await fixture(t), failure = new Error('injected write failure'); let temporary, closed = false;
  const observed = { ...io, async open(path, ...args) {
    const handle = await fs.open(path, ...args);
    if (args[0] === 'wx') {
      temporary = path;
      handle.writeFile = async () => { await handle.write('partial'); throw failure; };
      const close = handle.close.bind(handle);
      handle.close = async () => {
        await missing(path); assert.equal((await handle.stat()).nlink, 0); await close(); closed = true;
      };
    }
    return handle;
  } };
  await assert.rejects(publisher(f, { fs: observed })(f.source, f.target), error => error === failure);
  assert.equal(closed, true); await missing(temporary); await missing(f.target); assert.deepEqual((await records(f)).entries, []);
});

test('release failure after a complete commit is an error and leaves a recoverable record', async t => {
  const f = await fixture(t), failure = new Error('injected release failure');
  await assert.rejects(publisher(f, { ledger: { ...f.ledger, release() { throw failure; } } })(f.source, f.target), error => error === failure);
  assert.deepEqual(await fs.readFile(f.source), await fs.readFile(f.target));
  const entries = (await records(f)).entries; assert.equal(entries.length, 1); assert.equal(entries[0].state, 'identified');
  await missing(entries[0].path);
  await f.ledger.close();
  const next = await openOwnershipLedger({ directory: f.ledgerDirectory, ownerId: randomUUID(),
    lockExclusive: native.lockExclusive, setOwnershipMarker: native.setOwnershipMarker, getOwnershipMarker: native.getOwnershipMarker });
  try {
    const summary = await next.recover(); assert.equal(summary.missing.length, 1);
    assert.equal(summary.removed.length, 0); assert.equal(summary.unresolved.length, 0);
    assert.deepEqual((await records(f)).entries, []);
  } finally { await next.close(); }
});

test('same-target queue does not pass a job whose durable release is still pending', async t => {
  const f = await fixture(t), entered = Promise.withResolvers(), finish = Promise.withResolvers();
  let links = 0, releases = 0;
  const ledger = { ...f.ledger, async release(token) {
    if (releases++ === 0) { entered.resolve(); await finish.promise; }
    return f.ledger.release(token);
  } };
  const publish = publisher(f, { ledger, fs: { ...io, async link() { links++; return denyLink(); } } });
  const first = publish(f.source, f.target);
  await entered.promise;
  const second = publish(f.source, f.target);
  await new Promise(resolve => setImmediate(resolve)); assert.equal(links, 1);
  finish.resolve(); await first; await assert.rejects(second, { code: 'EEXIST' });
  assert.equal(links, 2); assert.equal(publish.pendingCount, 0); assert.deepEqual((await records(f)).entries, []);
});
