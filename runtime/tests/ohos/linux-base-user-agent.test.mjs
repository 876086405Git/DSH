import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:https';
import { readFile, mkdtemp, rm, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { createFetch } from '../../ohos/net/fetch.mjs';
import { createHttpDispatcher } from '../../ohos/net/dispatcher.mjs';
import { downloadLinuxBase } from '../../ohos/linux/base-download.mjs';

const userAgent = 'dsh-go-ohos-linux/1';
const body = Buffer.from('pinned Linux base over verified local TLS\0\xff');
const sha256 = createHash('sha256').update(body).digest('hex');

async function fixture(t) {
  assert.notEqual(process.env.NODE_TLS_REJECT_UNAUTHORIZED, '0');
  assert.ok(process.env.OHOS_LINUX_UA_TLS_CERT && process.env.OHOS_LINUX_UA_TLS_KEY,
    'run tooling/ohos/tests/linux-download-ua.py to prepare local TLS fixtures');
  const ca = await readFile(process.env.OHOS_LINUX_UA_TLS_CERT);
  const key = await readFile(process.env.OHOS_LINUX_UA_TLS_KEY);
  const requests = [];
  const server = createServer({ cert: ca, key }, (request, response) => {
    requests.push({ method: request.method, path: request.url, userAgent: request.headers['user-agent'] });
    const allowed = request.headers['user-agent'] === userAgent;
    response.writeHead(allowed ? 200 : 403); response.end(allowed ? body : 'fixture rejects the default UA');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const directory = await mkdtemp(join(tmpdir(), 'dsh-linux-ua-'));
  t.after(async () => {
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  });
  return { ca, requests, directory, artifact: {
    url: `https://127.0.0.1:${server.address().port}/base.bin`, bytes: body.length, sha256,
  } };
}

test('image downloader preserves TLS validation before any HTTP request', async t => {
  const { directory, artifact, requests } = await fixture(t);
  await assert.rejects(downloadLinuxBase({ directory, artifact }), TypeError);
  assert.deepEqual(requests, []);
  assert.deepEqual(await readdir(directory), []);
});

test('image downloader sends the fixed product UA through the production HTTPS dispatcher', async t => {
  const { directory, artifact, requests, ca } = await fixture(t);
  const dispatcher = createHttpDispatcher({ ca });
  t.after(() => dispatcher.close());
  try {
    const result = await downloadLinuxBase({ directory, artifact }, { fetch: createFetch(dispatcher) });
    assert.deepEqual(await readFile(result.path), body);
    assert.equal(result.state, 'verified-base');
    assert.deepEqual(requests, [{ method: 'GET', path: '/base.bin', userAgent }]);
  } finally {
    t.diagnostic(JSON.stringify({ requests, tlsVerification: 'enabled; explicit local test CA', fixturePolicy: '403 unless fixed product UA' }));
  }
});
