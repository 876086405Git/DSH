import { test } from 'node:test';
import assert from 'node:assert/strict';
import dns from 'node:dns';
import dgram from 'node:dgram';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { createLookup, readDnsConfig } from '../../direct/dns.mjs';

async function server(t, ipv6 = false, lastOctet = 7, beforeReply = () => {}) {
  const socket = dgram.createSocket(ipv6 ? 'udp6' : 'udp4');
  const queries = [];
  socket.on('message', async (packet, peer) => {
    let offset = 12;
    const parts = [];
    while (packet[offset]) {
      const length = packet[offset++]; parts.push(packet.subarray(offset, offset + length).toString()); offset += length;
    }
    offset++;
    const name = parts.join('.'); const type = packet.readUInt16BE(offset); offset += 4;
    queries.push({ name, type });
    const reply = await beforeReply(name, type);
    if (name.startsWith('timeout') || reply === 'timeout') return;
    const absent = name.startsWith('missing') || reply === 'missing';
    const refused = name.startsWith('refused') || reply === 'refused';
    const partial = name.startsWith('partial') && type === 28;
    const noData = (name.startsWith('v4only') && type === 28) || reply === 'nodata';
    const response = Buffer.from(packet.subarray(0, offset));
    response.writeUInt16BE(refused ? 0x8185 : absent ? 0x8183 : partial ? 0x8182 : 0x8180, 2);
    response.writeUInt16BE(absent || refused || partial || noData ? 0 : 1, 6);
    response.writeUInt16BE(0, 8); response.writeUInt16BE(0, 10);
    let answer = Buffer.alloc(0);
    if (!absent && !refused && !partial && !noData) {
      const data = type === 28 ? Buffer.from(`20010db80000000000000000000000${lastOctet.toString(16).padStart(2, '0')}`, 'hex') : Buffer.from([192, 0, 2, lastOctet]);
      answer = Buffer.alloc(12 + data.length);
      answer.writeUInt16BE(0xc00c, 0); answer.writeUInt16BE(type, 2); answer.writeUInt16BE(1, 4);
      answer.writeUInt32BE(60, 6); answer.writeUInt16BE(data.length, 10); data.copy(answer, 12);
    }
    socket.send(Buffer.concat([response, answer]), peer.port, peer.address);
  });
  await new Promise((resolve, reject) => { socket.once('error', reject); socket.bind(0, ipv6 ? '::1' : '127.0.0.1', resolve); });
  t.after(() => socket.close());
  return { endpoint: ipv6 ? `[::1]:${socket.address().port}` : `127.0.0.1:${socket.address().port}`, queries };
}

function fixture(t, endpoint, watch = false) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'direct-dns-'));
  const resolvConf = path.join(dir, 'resolv.conf'); const hostsFile = path.join(dir, 'hosts');
  const endpoints = Array.isArray(endpoint) ? endpoint : [endpoint];
  fs.writeFileSync(resolvConf, endpoints.map((value) => `nameserver ${value}\n`).join('') + 'options timeout:2 attempts:2\n');
  fs.writeFileSync(hostsFile, '127.0.0.1 localhost fixture.local\n::1 localhost fixture.local\n');
  const adapter = createLookup({ resolvConf, hostsFile, watch });
  t.after(() => { adapter.close(); fs.rmSync(dir, { recursive: true, force: true }); });
  return { ...adapter, resolvConf };
}

test('config keeps explicit servers, IPv6 and hosts aliases; empty config fails closed', () => {
  const config = readDnsConfig(' # comment\nnameserver 1.1.1.1\nnameserver 2001:db8::1 # x\nnameserver 1.1.1.1', '::1 LocalHost alias\n');
  assert.deepEqual(config.servers, ['1.1.1.1', '2001:db8::1']);
  assert.deepEqual(config.hosts.get('alias'), [{ address: '::1', family: 6 }]);
  assert.throws(() => readDnsConfig('search example.com'), /no nameserver/u);
});

test('a nonresponding configured server gives a bounded retryable failure without NSS fallback', async (t) => {
  const udp = await server(t); const adapter = fixture(t, udp.endpoint);
  const start = Date.now();
  await assert.rejects(adapter.promiseLookup('timeout.test', 4), { code: 'EAI_AGAIN' });
  assert(udp.queries.length >= 2, `c-ares retry count: ${udp.queries.length}`);
  assert(Date.now() - start < 15_000, 'resolver budget remains bounded');
});

test('real c-ares A/AAAA, all/order, IP literal, hosts and IDNA', async (t) => {
  const udp = await server(t); const adapter = fixture(t, udp.endpoint);
  assert.deepEqual(await adapter.promiseLookup('dual.test', { all: true, order: 'ipv6first' }), [
    { address: '2001:db8::7', family: 6 }, { address: '192.0.2.7', family: 4 },
  ]);
  assert.deepEqual(await adapter.promiseLookup('dual.test', { family: 4 }), { address: '192.0.2.7', family: 4 });
  assert.deepEqual(await adapter.promiseLookup('dual.test', { family: 6 }), { address: '2001:db8::7', family: 6 });
  assert.deepEqual(await adapter.promiseLookup('127.0.0.4', { family: 6 }), { address: '127.0.0.4', family: 4 });
  assert.deepEqual(await adapter.promiseLookup('fixture.local', { family: 6 }), { address: '::1', family: 6 });
  assert(!udp.queries.some((query) => query.name === 'fixture.local'));
  await adapter.promiseLookup('例子.test', { family: 4 });
  assert(udp.queries.some((query) => query.name === 'xn--fsqu00a.test'));
});

test('mutating a hosts result does not change later callback or Promise lookups', async (t) => {
  const udp = await server(t); const adapter = fixture(t, udp.endpoint);
  const callback = promisify(adapter.lookup);
  const options = { all: true, order: 'ipv4first' };
  const expected = [{ address: '127.0.0.1', family: 4 }, { address: '::1', family: 6 }];
  const first = await callback('fixture.local', options);
  first[0].address = '192.0.2.9';
  first[1].family = 4;
  const second = await adapter.promiseLookup('fixture.local', options);
  assert.deepEqual(second, expected);
  second[0].address = '192.0.2.10';
  assert.deepEqual(await callback('fixture.local', options), expected);
  assert.equal(udp.queries.length, 0);
});

test('IPv6 DNS transport uses the configured server', async (t) => {
  const udp = await server(t, true); const adapter = fixture(t, udp.endpoint);
  assert.equal((await adapter.promiseLookup('dual.test', 6)).address, '2001:db8::7');
  assert.equal(udp.queries.length, 1);
});

test('partial family success, V4MAPPED, ALL and empty answers retain lookup semantics', async (t) => {
  const udp = await server(t); const adapter = fixture(t, udp.endpoint);
  assert.equal((await adapter.promiseLookup('partial.test')).family, 4);
  assert.deepEqual(await adapter.promiseLookup('v4only.test', { family: 6, hints: dns.V4MAPPED }), { address: '::ffff:192.0.2.7', family: 6 });
  const all = await adapter.promiseLookup('dual.test', { family: 6, hints: dns.V4MAPPED | dns.ALL, all: true });
  assert.deepEqual(all.map((entry) => entry.address), ['2001:db8::7', '::ffff:192.0.2.7']);
  await assert.rejects(adapter.promiseLookup('missing.test'), { code: 'ENOTFOUND', syscall: 'getaddrinfo', hostname: 'missing.test' });
  await assert.rejects(adapter.promiseLookup('refused.test'), { code: 'EAI_AGAIN' });
});

test('REFUSED falls through to the next configured server for A and AAAA', async (t) => {
  const first = await server(t, false, 7, () => 'refused');
  const second = await server(t, false, 8);
  const adapter = fixture(t, [first.endpoint, second.endpoint]);
  assert.deepEqual(await adapter.promiseLookup('fallback.test', { all: true, order: 'ipv4first' }), [
    { address: '192.0.2.8', family: 4 }, { address: '2001:db8::8', family: 6 },
  ]);
  assert.deepEqual([...new Set(first.queries.map((query) => query.type))].sort(), [1, 28]);
  assert.deepEqual(second.queries.map((query) => query.type).sort(), [1, 28]);
});

test('REFUSED from every configured server remains EAI_AGAIN after trying both', async (t) => {
  const first = await server(t, false, 7, () => 'refused');
  const second = await server(t, false, 8, () => 'refused');
  const adapter = fixture(t, [first.endpoint, second.endpoint]);
  await assert.rejects(adapter.promiseLookup('fallback.test', { all: true }), { code: 'EAI_AGAIN' });
  for (const udp of [first, second]) {
    assert.deepEqual([...new Set(udp.queries.map((query) => query.type))].sort(), [1, 28]);
  }
});

for (const [label, reply] of [['NXDOMAIN', 'missing'], ['NODATA', 'nodata']]) {
  test(`REFUSED fallback stops at ${label} without querying a later positive server`, async (t) => {
    const first = await server(t, false, 7, () => 'refused');
    const second = await server(t, false, 8, () => reply);
    const third = await server(t, false, 9);
    const adapter = fixture(t, [first.endpoint, second.endpoint, third.endpoint]);
    await assert.rejects(adapter.promiseLookup('fallback.test', { all: true }), { code: 'ENOTFOUND' });
    assert.deepEqual(second.queries.map((query) => query.type).sort(), [1, 28]);
    assert.equal(third.queries.length, 0, 'a definitive negative answer is not bypassed');
  });
}

test('partial-family success does not query fallback DNS after REFUSED', async (t) => {
  const first = await server(t, false, 7, (_name, type) => type === 28 ? 'refused' : undefined);
  const second = await server(t, false, 8, () => 'timeout');
  const adapter = fixture(t, [first.endpoint, second.endpoint]);
  assert.deepEqual(await adapter.promiseLookup('fallback.test', { all: true, order: 'ipv4first' }), [
    { address: '192.0.2.7', family: 4 },
  ]);
  assert.deepEqual(first.queries.map((query) => query.type).sort(), [1, 28]);
  assert.equal(second.queries.length, 0, 'an existing answer must not start a new fallback');
});

test('callback is asynchronous, promisify shape, validation stays on the exact Node version', async (t) => {
  const udp = await server(t); const adapter = fixture(t, udp.endpoint);
  let synchronous = true;
  const callback = new Promise((resolve, reject) => adapter.lookup('dual.test', 4, (error, address, family) => {
    try { assert.equal(synchronous, false); assert.ifError(error); assert.equal(address, '192.0.2.7'); assert.equal(family, 4); resolve(); }
    catch (failure) { reject(failure); }
  }));
  synchronous = false; await callback;
  assert.deepEqual(await promisify(adapter.lookup)('dual.test', { family: 'IPv4' }), { address: '192.0.2.7', family: 4 });
  assert.throws(() => adapter.lookup('dual.test', { family: 9 }, () => {}), { code: 'ERR_INVALID_ARG_VALUE' });
  assert.throws(() => adapter.lookup('dual.test', { all: 1 }, () => {}), { code: 'ERR_INVALID_ARG_TYPE' });
  assert.throws(() => adapter.lookup('bad\0host', () => {}), { code: 'ERR_INVALID_ARG_VALUE' });
  await assert.rejects(adapter.promiseLookup('dual.test', { family: 'IPv4' }), { code: 'ERR_INVALID_ARG_VALUE' });
});

test('atomic resolv.conf refresh changes both families; invalid replacement fails without host fallback', async (t) => {
  const first = await server(t, false, 7); const second = await server(t, false, 8);
  const adapter = fixture(t, first.endpoint);
  assert.deepEqual((await adapter.promiseLookup('dual.test', { all: true })).map((entry) => entry.address), ['192.0.2.7', '2001:db8::7']);
  fs.writeFileSync(adapter.resolvConf + '.new', `nameserver ${second.endpoint}\n`);
  fs.renameSync(adapter.resolvConf + '.new', adapter.resolvConf); adapter.refresh();
  assert.deepEqual((await adapter.promiseLookup('dual.test', { all: true })).map((entry) => entry.address), ['192.0.2.8', '2001:db8::8']);
  fs.writeFileSync(adapter.resolvConf, 'nameserver invalid\n'); adapter.refresh();
  await assert.rejects(adapter.promiseLookup('dual.test', { all: true }), { code: 'EAI_AGAIN' });
  assert.deepEqual(first.queries.map((query) => query.type).sort(), [1, 28]);
  assert.deepEqual(second.queries.map((query) => query.type).sort(), [1, 28]);
});

test('in-flight families finish on their captured config across invalid and valid refreshes', { timeout: 15_000 }, async (t) => {
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  let arrived;
  const bothQueries = new Promise((resolve) => { arrived = resolve; });
  const types = new Set();
  const first = await server(t, false, 7, async (_name, type) => {
    types.add(type);
    if (types.size === 2) arrived();
    await held;
  });
  const second = await server(t, false, 8);
  const adapter = fixture(t, first.endpoint);
  const pending = adapter.promiseLookup('dual.test', { all: true });
  try {
    await bothQueries;
    fs.writeFileSync(adapter.resolvConf, 'nameserver invalid\n'); adapter.refresh();
    await assert.rejects(adapter.promiseLookup('dual.test', { all: true }), { code: 'EAI_AGAIN' });
    fs.writeFileSync(adapter.resolvConf + '.new', `nameserver ${second.endpoint}\n`);
    fs.renameSync(adapter.resolvConf + '.new', adapter.resolvConf); adapter.refresh();
    assert.deepEqual((await adapter.promiseLookup('dual.test', { all: true })).map((entry) => entry.address), ['192.0.2.8', '2001:db8::8']);
  } finally {
    release();
  }
  assert.deepEqual((await pending).map((entry) => entry.address), ['192.0.2.7', '2001:db8::7']);
  assert.deepEqual([...types].sort(), [1, 28]);
});

test('a failed watched config read recovers on lookup without another file change', { timeout: 5000 }, async (t) => {
  const first = await server(t, false, 7); const second = await server(t, false, 8);
  const adapter = fixture(t, first.endpoint, true);
  assert.equal((await adapter.promiseLookup('dual.test', 4)).address, '192.0.2.7');
  const read = fs.readFileSync;
  let observed;
  const failedRead = new Promise(resolve => { observed = resolve; });
  const injected = t.mock.method(fs, 'readFileSync', (file, ...args) => {
    if (file === adapter.resolvConf) {
      observed();
      throw Object.assign(new Error('isolated config read failure'), { code: 'EMFILE', syscall: 'open' });
    }
    return read(file, ...args);
  });
  fs.writeFileSync(adapter.resolvConf + '.new', `nameserver ${second.endpoint}\n`);
  fs.renameSync(adapter.resolvConf + '.new', adapter.resolvConf);
  await failedRead;
  await assert.rejects(adapter.promiseLookup('dual.test', 4), { code: 'EAI_AGAIN' });
  const before = fs.statSync(adapter.resolvConf, { bigint: true });
  injected.mock.restore();
  assert.equal((await adapter.promiseLookup('dual.test', 4)).address, '192.0.2.8');
  assert.equal((await promisify(adapter.lookup)('dual.test', 4)).address, '192.0.2.8');
  const after = fs.statSync(adapter.resolvConf, { bigint: true });
  assert.deepEqual([after.ino, after.size, after.mtimeNs], [before.ino, before.size, before.mtimeNs]);
  assert.equal(first.queries.length, 1, 'the stale resolver is not used after its config read failed');
  assert.equal(second.queries.length, 2);
});

test('a failed watcher stays failed even when the config remains readable', async (t) => {
  const udp = await server(t);
  const watch = fs.watch;
  let watcher;
  const capture = t.mock.method(fs, 'watch', (...args) => (watcher = watch(...args)));
  const adapter = fixture(t, udp.endpoint, true);
  capture.mock.restore();
  // Node closes the native watcher before emitting its syscall="watch" error.
  watcher.close();
  watcher.emit('error', Object.assign(new Error('isolated watcher failure'), { code: 'ENOSPC', syscall: 'watch' }));
  await assert.rejects(adapter.promiseLookup('dual.test', 4), { code: 'EAI_AGAIN' });
  assert.equal(udp.queries.length, 0);
});

test('the live directory watcher observes atomic replacement and recovers after invalid DNS config', async (t) => {
  const first = await server(t, false, 7); const second = await server(t, false, 8);
  const adapter = fixture(t, first.endpoint, true);
  assert.equal((await adapter.promiseLookup('dual.test', 4)).address, '192.0.2.7');
  async function eventually(check) {
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline) {
      try { if (await check()) return; } catch { /* wait for the filesystem event */ }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.fail('live DNS watcher did not observe the replacement');
  }
  fs.writeFileSync(adapter.resolvConf + '.new', `nameserver ${second.endpoint}\n`);
  fs.renameSync(adapter.resolvConf + '.new', adapter.resolvConf);
  await eventually(async () => (await adapter.promiseLookup('dual.test', 4)).address === '192.0.2.8');
  fs.writeFileSync(adapter.resolvConf, 'nameserver invalid\n');
  await eventually(async () => {
    try { await adapter.promiseLookup('dual.test', 4); return false; }
    catch (error) { return error.code === 'EAI_AGAIN'; }
  });
  fs.writeFileSync(adapter.resolvConf + '.new', `nameserver ${first.endpoint}\n`);
  fs.renameSync(adapter.resolvConf + '.new', adapter.resolvConf);
  await eventually(async () => (await adapter.promiseLookup('dual.test', 4)).address === '192.0.2.7');
});

test('the PRoot DNS import never stops Node, whether or not its resolver starts', () => {
  const glue = fileURLToPath(new URL('../../direct/proot-dns.mjs', import.meta.url));
  const result = spawnSync(process.execPath, ['--import', glue, '-e', 'console.log("main")'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'main\n');
});
