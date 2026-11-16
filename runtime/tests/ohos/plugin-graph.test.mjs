import assert from 'node:assert/strict';
import { createServer, get } from 'node:http';
import { once } from 'node:events';
import { test } from 'node:test';
import { createRegistry } from '../../ohos/plugins/registry.mjs';
import { resolveGraph } from '../../ohos/plugins/graph.mjs';

const integrity = 'sha512-' + Buffer.alloc(64).toString('base64');
const pkg = (name, version, extra = {}) => ({ name, version, dist: {
  tarball: `https://packages.example/${name}/${version}.tgz`, integrity }, ...extra });
function fixture(records) {
  const requests = [];
  const client = createRegistry({ registry: 'https://registry.example', fetchImpl: async url => {
    const name = decodeURIComponent(new URL(url).pathname.slice(1));
    requests.push(name);
    const versions = records[name];
    return new Response(JSON.stringify(versions ? { name, versions,
      'dist-tags': { latest: Object.keys(versions).at(-1) }, time: {} } : {}), { status: versions ? 200 : 404 });
  }});
  return { client, requests };
}

test('locks transitive conflicting versions and cycles, caching each packument', async () => {
  const { client, requests } = fixture({
    root: { '1.0.0': pkg('root', '1.0.0', { dependencies: { a: '^1', b: '2' } }) },
    a: { '1.0.0': pkg('a', '1.0.0', { dependencies: { b: '1', root: '1' } }) },
    b: { '1.0.0': pkg('b', '1.0.0'), '2.0.0': pkg('b', '2.0.0') },
  });
  const graph = await resolveGraph({ spec: 'root', registryClient: client });
  assert.equal(graph.root, 'root@1.0.0');
  assert.equal(graph.nodes.length, 4);
  assert.equal(graph.nodes.find(n => n.name === 'a').dependencies.b.id, 'b@1.0.0');
  assert.equal(graph.nodes[0].dependencies.b.id, 'b@2.0.0');
  assert.equal(requests.filter(n => n === 'b').length, 1);
  assert.equal(JSON.stringify(graph).includes('^1'), true); // original manifest retained
  assert(graph.nodes.every(n => n.integrity === integrity));
});

test('scoped ranges, exact prereleases and listing preserve manager view contract', async () => {
  const { client } = fixture({ '@scope/pkg': {
    '1.0.0': pkg('@scope/pkg', '1.0.0'), '1.1.0': pkg('@scope/pkg', '1.1.0'),
    '2.0.0-rc.1': pkg('@scope/pkg', '2.0.0-rc.1'),
  }});
  assert.equal((await client.readManifest('@scope/pkg@^1')).version, '1.1.0');
  assert.equal((await client.readManifest('@scope/pkg@2.0.0-rc.1')).version, '2.0.0-rc.1');
  assert.deepEqual((await client.view('@scope/pkg', ['versions', 'time', 'dist-tags'])).versions,
    ['1.0.0', '1.1.0', '2.0.0-rc.1']);
  assert.deepEqual(await client.view('@scope/pkg@1.0.0', ['name', 'version']), { name: '@scope/pkg', version: '1.0.0' });
});

test('host peers and dependencies keep one host instance; missing and incompatible peers fail', async () => {
  const hostPackages = new Map([['core', { version: '1.2.0', packageDir: '/engine/core' }]]);
  const { client } = fixture({ root: { '1.0.0': pkg('root', '1.0.0', {
    dependencies: { core: '^1' }, peerDependencies: { core: '^1', absent: '*' },
    peerDependenciesMeta: { absent: { optional: true } },
  }) }});
  const graph = await resolveGraph({ spec: 'root', registryClient: client, hostPackages });
  assert.equal(graph.nodes.length, 1);
  assert.equal(graph.nodes[0].peers.core.packageDir, '/engine/core');
  assert.equal(graph.nodes[0].dependencies.core.type, 'host');
  assert.match(graph.nodes[0].omitted.absent, /optional peer/);
  await assert.rejects(resolveGraph({ spec: 'root', registryClient: client }), /peer.*core/);
  await assert.rejects(resolveGraph({ spec: 'root', registryClient: client,
    hostPackages: new Map([['core', { version: '2.0.0', packageDir: '/engine/core' }]]) }), /core.*incompatible/);
});

test('optional overrides ordinary dependency; explicit platform exclusion recorded', async () => {
  const { client } = fixture({ root: { '1.0.0': pkg('root', '1.0.0', {
    dependencies: { dep: '1' }, optionalDependencies: { dep: '2', linux: '1' },
  }) }, dep: { '2.0.0': pkg('dep', '2.0.0') },
  linux: { '1.0.0': pkg('linux', '1.0.0', { os: ['linux'], scripts: { install: 'native' } }) } });
  const graph = await resolveGraph({ spec: 'root', registryClient: client });
  assert.equal(graph.nodes[0].dependencies.dep.id, 'dep@2.0.0');
  assert.match(graph.nodes[0].omitted.linux, /platform/);
  assert.equal(graph.nodes.length, 2);
});

test('applicable optional native and lifecycle packages fail rather than disappear', async () => {
  for (const extra of [{ scripts: { install: 'node build.js' } }, { gypfile: true }]) {
    const { client } = fixture({ root: { '1.0.0': pkg('root', '1.0.0', { optionalDependencies: { dep: '1' } }) },
      dep: { '1.0.0': pkg('dep', '1.0.0', extra) } });
    await assert.rejects(resolveGraph({ spec: 'root', registryClient: client }), /dep.*(script|native)/);
  }
});

test('rejects unsupported specs, absent SRI and unsafe URLs without leaking credentials', async () => {
  const { client } = fixture({ root: { '1.0.0': pkg('root', '1.0.0', { dist: { tarball: 'https://packages.example/a' } }) } });
  for (const spec of ['file:/tmp/a', 'git:repo', 'root@npm:other@1', '../a', 'root@'])
    await assert.rejects(client.readManifest(spec), /spec/);
  await assert.rejects(resolveGraph({ spec: 'root', registryClient: client }), /integrity/);
  for (const registry of ['http://localhost:1234', 'https://user:SECRET@registry.example', 'https://registry.example/#SECRET']) {
    assert.throws(() => createRegistry({ registry }), e => /URL/.test(e.message) && !e.message.includes('SECRET'));
  }
});

test('registry uses real HTTP response bytes through injected HTTPS transport, rejects redirects and aborts', async t => {
  const server = createServer((req, res) => { res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ name: 'root', versions: { '1.0.0': pkg('root', '1.0.0') }, 'dist-tags': { latest: '1.0.0' } })); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => server.close());
  const registry = createRegistry({ registry: 'https://registry.example', fetchImpl: (url, opts) =>
    new Promise((resolve, reject) => {
      get(`http://127.0.0.1:${server.address().port}${new URL(url).pathname}`, { signal: opts.signal }, response => {
        const chunks = [];
        response.on('data', chunk => chunks.push(chunk));
        response.on('error', reject);
        response.on('end', () => resolve(new Response(Buffer.concat(chunks), { status: response.statusCode })));
      }).on('error', reject);
    }) });
  assert.equal((await registry.readManifest('root')).version, '1.0.0');
  const redirect = createRegistry({ registry: 'https://registry.example', fetchImpl: async () => new Response('', { status: 302 }) });
  await assert.rejects(redirect.readManifest('root'), /redirect/);
  const abort = new AbortController(); abort.abort();
  await assert.rejects(resolveGraph({ spec: 'root', registryClient: registry, signal: abort.signal }), { name: 'AbortError' });
});

test('registry timeout cancels transport and metadata size is bounded', async () => {
  let closed = false;
  const client = createRegistry({ registry: 'https://registry.example', timeoutMs: 10,
    fetchImpl: (_url, options) => new Promise((_resolve, reject) => {
      assert.equal(options.redirect, 'manual');
      options.signal.addEventListener('abort', () => { closed = true; reject(options.signal.reason); }, { once: true });
    }) });
  // AbortSignal.timeout uses an unref timer; this fixture represents an active socket.
  const alive = setInterval(() => {}, 1000);
  try { await assert.rejects(client.readManifest('root'), { name: 'TimeoutError' }); }
  finally { clearInterval(alive); }
  assert.equal(closed, true);
  const oversized = createRegistry({ registry: 'https://registry.example',
    fetchImpl: async () => new Response(' '.repeat(16 * 1024 * 1024 + 1)) });
  await assert.rejects(oversized.readManifest('root'), /exceeds/);
});

test('invalid registry identities and malformed manifests fail before a lock is returned', async () => {
  for (const extra of [
    { name: 'other' }, { version: '2.0.0' }, { dependencies: [] },
    { dependencies: { dep: 'file:/private' } }, { peerDependencies: { core: 42 } },
    { dist: { tarball: 'https://user:SECRET@packages.example/a', integrity } },
    { dist: { tarball: 'https://packages.example/a', integrity: 'sha512-AA==' } },
  ]) {
    const { client } = fixture({ root: { '1.0.0': pkg('root', '1.0.0', extra) } });
    await assert.rejects(resolveGraph({ spec: 'root', registryClient: client }), error => !error.message.includes('SECRET'));
  }
});

test('network errors redact underlying URLs and optional network failure remains failure', async () => {
  const client = createRegistry({ registry: 'https://registry.example', fetchImpl: async () => {
    throw new Error('Failed URL https://user:SECRET@other.example/path');
  }});
  await assert.rejects(client.readManifest('root'), error => error.code === 'ERR_PNPM_META_FETCH_FAIL' && !error.message.includes('SECRET'));
  const { client: optional } = fixture({ root: { '1.0.0': pkg('root', '1.0.0', { optionalDependencies: { missing: '1' } }) } });
  await assert.rejects(resolveGraph({ spec: 'root', registryClient: optional }), { code: 'ERR_PNPM_FETCH_404' });
});


test('ordinary dependency may privately differ from a same-name host dependency', async () => {
  const { client } = fixture({ root: { '1.0.0': pkg('root', '1.0.0', { dependencies: { semver: '^6' } }) },
    semver: { '6.3.1': pkg('semver', '6.3.1') } });
  const graph = await resolveGraph({ spec: 'root', registryClient: client,
    hostPackages: new Map([['semver', { version: '7.8.6', packageDir: '/engine/semver' }]]) });
  assert.equal(graph.nodes.length, 2);
  assert.deepEqual(graph.nodes[0].dependencies.semver, { type: 'package', id: 'semver@6.3.1' });
});

for (const scenario of ['disconnect', 'body-timeout', 'caller-abort', 'total-timeout', 'invalid-json']) {
  test(`real HTTP registry body ${scenario} preserves retry or cancellation classification`, async t => {
    const { createHttpDispatcher } = await import('../../ohos/net/dispatcher.mjs');
    const controller = new AbortController();
    const timers = [];
    const server = createServer((_req, res) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      if (scenario === 'invalid-json') { res.end('{ invalid JSON }'); return; }
      res.write('{"versions":');
      if (scenario === 'disconnect') timers.push(setTimeout(() => res.destroy(), 20));
      if (scenario === 'caller-abort') timers.push(setTimeout(() => controller.abort(), 20));
    });
    server.listen(0, '127.0.0.1'); await once(server, 'listening');
    const dispatcher = createHttpDispatcher({ proxyEnv: {}, headersTimeout: 1000,
      bodyTimeout: scenario === 'body-timeout' ? 80 : 2000 });
    t.after(async () => {
      timers.forEach(clearTimeout); await dispatcher.destroy();
      server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    });
    const client = createRegistry({ registry: 'https://registry.example', signal: controller.signal,
      timeoutMs: scenario === 'total-timeout' ? 80 : 3000,
      fetchImpl: (_url, options) => fetch(`http://127.0.0.1:${server.address().port}/root`, { ...options, dispatcher }),
    });
    const expected = scenario === 'caller-abort' ? { name: 'AbortError' }
      : scenario === 'total-timeout' ? { name: 'TimeoutError' }
      : scenario === 'invalid-json' ? { code: 'ERR_OHOS_PLUGIN_PACKAGE' }
      : { code: 'ERR_PNPM_META_FETCH_FAIL' };
    await assert.rejects(client.readManifest('root'), expected);
  });
}
