import test from 'node:test';
import assert from 'node:assert/strict';
import https from 'node:https';
import { syncBuiltinESMExports } from 'node:module';
import { createHttpTransport, isPublicAddress, prepareHttpRequest } from '../src/http.js';

test('DNS64 well-known prefix accepts the public embedded IPv4 address', async () => {
  for (const address of [
    '64:ff9b::808:808', '64:ff9b::8.8.8.8',
    '0064:FF9B:0000:0000:0000:0000:0808:0808', '64:ff9b::1.1.1.1',
  ]) {
    assert.equal(isPublicAddress(address), true, address);
    assert.equal(typeof await prepareHttpRequest(`https://[${address}]/image`, { maxBytes: 100 }), 'function');
  }
});

test('DNS64 preserves IPv4 exclusions and adjacent prefix boundaries', () => {
  for (const address of [
    '0.0.0.1', '10.0.0.1', '100.64.0.1', '100.127.255.255', '127.0.0.1',
    '169.254.169.254', '172.16.0.1', '172.31.255.255', '192.0.0.1',
    '192.0.2.1', '192.88.99.1', '192.168.0.1', '198.18.0.1',
    '198.19.255.255', '198.51.100.1', '203.0.113.1', '224.0.0.1', '255.255.255.255',
  ]) assert.equal(isPublicAddress(`64:ff9b::${address}`), false, address);
  for (const address of ['100.63.255.255', '100.128.0.0', '172.15.255.255', '172.32.0.0', '198.20.0.0']) {
    assert.equal(isPublicAddress(`64:ff9b::${address}`), true, address);
  }
  for (const address of ['::ffff:8.8.8.8', '64:ff9b:1::808:808', '64:ff9b:0:0:0:1:808:808']) {
    assert.equal(isPublicAddress(address), false, address);
  }
});

test('public A plus DNS64 AAAA reaches the existing pinned HTTPS request', async t => {
  const addresses = [{ address: '8.8.8.8', family: 4 }, { address: '64:ff9b::808:808', family: 6 }];
  let lookups = 0;
  const transport = createHttpTransport({ lookup: async (host, options) => {
    assert.equal(host, 'media.test');
    assert.deepEqual(options, { all: true, verbatim: true });
    lookups += 1;
    return addresses;
  } });
  let sent;
  const mocked = t.mock.method(https, 'request', (url, options) => {
    sent = { url, options };
    throw new Error('test stops before opening a socket');
  });
  syncBuiltinESMExports();
  try {
    await assert.rejects(transport('https://media.test/image', { maxBytes: 100 }), { code: 'network' });
    assert.equal(lookups, 1);
    assert.equal(mocked.mock.callCount(), 1);
    assert.equal(sent.url.href, 'https://media.test/image');
    assert.equal(sent.options.servername, 'media.test');
    assert.equal(sent.options.family, 0);
    assert.equal(sent.options.autoSelectFamily, true);
    sent.options.lookup('media.test', { all: true }, (error, pinned) => {
      assert.equal(error, null);
      assert.deepEqual(pinned, addresses);
    });
    addresses.push({ address: '64:ff9b::169.254.169.254', family: 6 });
    await assert.rejects(transport('https://media.test/image', { maxBytes: 100 }), { code: 'unsafe_url' });
    assert.equal(mocked.mock.callCount(), 1);
  } finally {
    mocked.mock.restore();
    syncBuiltinESMExports();
  }
});
