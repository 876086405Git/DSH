import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { Worker } from 'node:worker_threads';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { fixture, name, selectedPackage } from './plugin-package-harness.mjs';
import { tarFile, toolSource } from './plugin-package-fixture.mjs';

test('real inherited DSH Worker resolver preserves old private imports and selects new active files', { timeout: 30000 }, async t => {
  const dependency = 'ohos-worker-private', versions = {}, archives = {};
  for (const version of ['1.0.0', '2.0.0']) {
    const manifest = { name: dependency, version,
      exports: { import: './i.mjs', require: './c.cjs' } };
    const bytes = gzipSync(Buffer.concat([tarFile('package.json', JSON.stringify(manifest)),
      tarFile('i.mjs', `export default { version: '${version}', kind: 'import' };`),
      tarFile('c.cjs', `module.exports = { version: '${version}', kind: 'require' };`), Buffer.alloc(1024)]));
    archives[version] = bytes;
    versions[version] = { ...manifest, dist: { integrity: 'sha512-' + createHash('sha512').update(bytes).digest('base64'),
      tarball: `https://registry.ohos-fixture.test/worker-tar/${version}` } };
  }
  const source = `
    import assert from 'node:assert/strict';
    import { parentPort, workerData, getEnvironmentData } from 'node:worker_threads';
    import { createRequire } from 'node:module';
    const require = createRequire(import.meta.url);
    const esm = await import('#value'), cjs = require('#value');
    assert.throws(() => require.resolve('${dependency}', { paths: [] }), { code: 'MODULE_NOT_FOUND' });
    assert.throws(() => require.resolve('${dependency}', { paths: null }), { code: 'ERR_INVALID_ARG_VALUE' });
    assert.throws(() => require.resolve('#value', { paths: null }), { code: 'ERR_INVALID_ARG_VALUE' });
    assert.deepEqual(require(require.resolve('#value', { paths: [] })), cjs);
    assert.equal(require(require.resolve('${dependency}', { paths: [workerData.external] })).version, 'external');
    const peer = await import('@deepseek-ai/cordis'), direct = await import(workerData.hostCordis);
    parentPort.postMessage({ esm: esm.default, cjs, samePeer: peer.Context === direct.Context,
      inherited: getEnvironmentData('@deepseek-ai/dsh-app-boot/profile-resolution') !== undefined,
      hasWriter: !!globalThis[Symbol.for('dsh.go.ohos.plugins')] });
  `;
  const definitions = Object.fromEntries(['1.0.0', '2.0.0'].map(version => [version, {
    yaml: JSON.stringify([{ insert: [{ id: 'owned-tool', name }] }]), source: toolSource(version),
    manifest: { dependencies: { [dependency]: version }, imports: { '#value': dependency },
      peerDependencies: { '@deepseek-ai/dsh-app-boot': '^0.2.2-rc.1', '@deepseek-ai/cordis': '^4.1.0' } },
    files: { 'worker.mjs': source },
  }]));
  const f = await fixture(t, definitions, { hmr: true, network: {
    onRequest(req, res) {
      if (req.url === '/' + dependency) res.end(JSON.stringify({ name: dependency, versions }));
      else if (req.url.startsWith('/worker-tar/')) res.end(archives[req.url.slice('/worker-tar/'.length)]);
      else return false;
      return true;
    },
  } });
  const external = join(f.root, 'external');
  await mkdir(join(external, 'node_modules', dependency), { recursive: true });
  await writeFile(join(external, 'node_modules', dependency, 'package.json'), JSON.stringify({ name: dependency, main: 'index.cjs' }));
  await writeFile(join(external, 'node_modules', dependency, 'index.cjs'), "module.exports = { version: 'external' };\n");
  async function run(root, version) {
    const worker = new Worker(pathToFileURL(join(root, 'worker.mjs')), {
      workerData: { external, hostCordis: pathToFileURL(join(process.env.DSH_PREFIX, 'node_modules/@deepseek-ai/cordis/lib/index.js')).href },
    });
    try {
      const value = await new Promise((resolve, reject) => {
        worker.once('message', resolve); worker.once('error', reject);
        worker.once('exit', code => { if (code !== 0) reject(new Error(`Worker exit ${code}`)); });
      });
      assert.deepEqual(value, { esm: { version, kind: 'import' }, cjs: { version, kind: 'require' },
        samePeer: true, inherited: true, hasWriter: false });
    } finally { await worker.terminate(); }
  }
  assert.equal((await f.invoke('installBundle', name + '@1.0.0', { registry: f.registry, enabled: true })).application, 'applied');
  const old = selectedPackage(f.dir);
  await run(old, '1.0.0');
  const updated = await f.invoke('updateBundle', name, '2.0.0', { registry: f.registry });
  assert.equal(updated.result.application, 'restart-required', JSON.stringify(updated));
  await run(old, '1.0.0');
  await run(selectedPackage(f.dir), '2.0.0');
});
