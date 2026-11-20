import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import https from 'node:https';
import { once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHttpTransport } from '../src/http.js';
import { createStreamStager } from '../src/stream-staging.js';

async function fixture(t) {
  const addresses = [
    { address: '2606:4700:4700::1111', family: 6 },
    { address: '1.1.1.1', family: 4 },
  ];
  const counts = { dns: 0, requests: 0 };
  const received = [];
  const sockets = new Set();
  const body = Buffer.from('synthetic-media-bytes');
  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    received.push({ method: req.method, body: Buffer.concat(chunks).toString() });
    res.end(body);
  });
  server.on('connection', socket => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const directory = await mkdtemp(join(tmpdir(), 'media-family-'));
  const lookup = async () => { counts.dns++; return addresses; };
  // Exercise the real transport functions and Node TCP selection. Only replace
  // the HTTPS boundary with local HTTP: public addresses keep their family and
  // order, mapped to ::1 / 127.0.0.1. The server accepts IPv4 only. This is not a
  // TLS or device test, and production's public-address checks still execute.
  const local = entry => ({ address: entry.family === 6 ? '::1' : '127.0.0.1', family: entry.family });
  const mocked = t.mock.method(https, 'request', (url, options, listener) => {
    counts.requests++;
    return http.request({ ...options, hostname: url.hostname, port: server.address().port, path: url.pathname,
      lookup(name, selectedOptions, callback) {
        options.lookup(name, selectedOptions, (error, value, family) => {
          if (error) return callback(error);
          if (selectedOptions.all) callback(null, value.map(local));
          else callback(null, local({ address: value, family }).address, family);
        });
      },
    }, listener);
  });
  syncBuiltinESMExports();
  t.after(async () => {
    mocked.mock.restore();
    syncBuiltinESMExports();
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  });
  return { lookup, counts, received, directory, body, url: 'https://media.test/result' };
}

test('media POST uses reachable IPv4 after refused IPv6 without replaying the request', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  const response = await createHttpTransport({ lookup: f.lookup })(f.url, {
    method: 'POST', body: Buffer.from('one-generation'), maxBytes: 1024,
    signal: AbortSignal.timeout(4000),
  });
  assert.deepEqual(response.body, f.body);
  assert.deepEqual(f.counts, { dns: 1, requests: 1 });
  assert.deepEqual(f.received, [{ method: 'POST', body: 'one-generation' }]);
});

test('video staging uses reachable IPv4 after refused IPv6 with one GET', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  const receipt = await createStreamStager({ lookup: f.lookup })(f.url, {
    directory: f.directory, maxBytes: 1024, timeoutMs: 4000,
  });
  assert.deepEqual(await readFile(receipt.path), f.body);
  assert.deepEqual(f.counts, { dns: 1, requests: 1 });
  assert.deepEqual(f.received, [{ method: 'GET', body: '' }]);
});
