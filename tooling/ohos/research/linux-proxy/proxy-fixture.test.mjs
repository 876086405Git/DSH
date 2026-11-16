import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import { join } from 'node:path';
import http from 'node:http';
import tls from 'node:tls';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createProxyFixtures, NONCE } from './proxy-fixture.mjs';

test('loopback fixture validates Basic auth and records only a closed safe schema', async () => {
  const root = await mkdtemp(join(os.tmpdir(), 'dsh-proxy-fixture-'));
  const fixture = await createProxyFixtures({ directory: join(root, 'private') });
  const settings = fixture.settings;
  const request = authorized => new Promise((resolve, reject) => {
    const req = http.get({ host: '127.0.0.1', port: settings.httpProxyPort,
      path: `http://proxy-target.invalid:${settings.httpOriginPort}/nonce`, headers: authorized ? {
        'proxy-authorization': 'Basic ' + Buffer.from(settings.username + ':' + settings.password).toString('base64'),
      } : {} }, res => { const chunks = []; res.on('data', bytes => chunks.push(bytes)); res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString() })); });
    req.on('error', reject);
  });
  try {
    assert.equal((await request(false)).status, 407);
    const accepted = await request(true); assert.equal(accepted.status, 200); assert.equal(accepted.body, NONCE);
    const safe = JSON.stringify(fixture.events());
    assert.ok(!safe.includes(settings.password) && !safe.includes(settings.username));
    assert.ok(!safe.includes('http://') && !safe.includes('proxy-authorization') && !safe.includes('Basic '));
    assert.deepEqual(fixture.events().map(event => event.boundary), ['proxy', 'proxy', 'origin']);
    // Verify the certificate really has an accepted name and CA. This test is
    // only TLS to the fixture; the guest Git/gh CONNECT chain is a later test.
    const socket = tls.connect({ host: '127.0.0.1', port: settings.httpsProxyPort,
      servername: 'proxy-target.invalid', ca: settings.caPem, rejectUnauthorized: true });
    await once(socket, 'secureConnect'); assert.equal(socket.authorized, true); socket.destroy();
  } finally { await fixture.close(); await rm(root, { recursive: true, force: true }); }
});

test('actual host Git accepts the empty repository over verified HTTP and HTTPS proxy CONNECT', async () => {
  const root = await mkdtemp(join(os.tmpdir(), 'dsh-proxy-git-fixture-'));
  const fixture = await createProxyFixtures({ directory: join(root, 'private') });
  const settings = fixture.settings;
  try {
    for (const secure of [false, true]) {
      // This host-only fixture certificate includes the loopback IP. The real
      // guest uses its own 10.0.2.2 SAN; neither path disables verification.
      const endpoint = secure ? `https://127.0.0.1:${settings.httpsProxyPort}` : `http://127.0.0.1:${settings.httpProxyPort}`;
      const url = new URL(endpoint); url.username = settings.username; url.password = settings.password;
      const argv = ['-c', 'http.sslCAInfo=' + join(root, 'private/ca.crt'), '-c', 'http.proxySSLCAInfo=' + join(root, 'private/ca.crt'),
        'ls-remote', 'https://proxy-target.invalid/repo'];
      let accepted = false;
      try {
        const result = await promisify(execFile)('/usr/bin/git', argv, { env: { PATH: '/usr/bin:/bin', HOME: root, TMPDIR: root,
          LANG: 'C.UTF-8', https_proxy: url.href, SSL_CERT_FILE: join(root, 'private/ca.crt') }, timeout: 10000 });
        accepted = result.stdout === '';
      } catch { /* Never expose argv, stderr or credential-bearing child env. */ }
      assert.equal(accepted, true, secure ? 'host Git verified TLS to proxy and origin' : 'host Git verified HTTP CONNECT and origin TLS');
    }
    assert.ok(fixture.events().some(event => event.transport === 'https' && event.boundary === 'proxy' && event.authorized));
  } finally { await fixture.close(); await rm(root, { recursive: true, force: true }); }
});
