import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, symlink, rm, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { scanOhos, applyOhosData, ohosSummary } from '../scripts/ohos-scan.mjs';
import { scanInstalled, readPackage } from '../scripts/ohos-scan-cli.mjs';
import { inspect, unpack, validateEntry, verifyIntegrity, INDEX_URL } from '../scripts/core.mjs';
import { build } from '../scripts/build.mjs';
import { parseMarketIndex } from '@deepseek-ai/dsh-plugin-market-index';

function input(extra = {}, contents = {}) {
  const pkg = { name: 'test-package', version: '1.0.0', main: 'index.js', ...extra };
  const files = new Map(Object.entries({ 'package.json': JSON.stringify(pkg), 'index.js': 'export const value = 1;', ...contents }).map(([path, text]) => [path, Buffer.isBuffer(text) ? text : Buffer.from(text)]));
  return { pkg, files, report: scanOhos(files, pkg) };
}
test('pure JS screening is explicitly static and preserves a reproducible source fingerprint', () => {
  const { report, pkg, files } = input();
  assert.equal(report.status, 'usable'); assert.equal(report.label, '可用');
  assert.equal(report.deviceValidated, false); assert.match(report.meaning, /不是运行证明/);
  assert.equal(report.source.sha256, scanOhos(new Map([...files].reverse()), pkg).source.sha256);
  files.set('index.js', Buffer.from('export const value = 2;'));
  assert.notEqual(report.source.sha256, scanOhos(files, pkg).source.sha256);
});
test('five requested feature classes keep exact file evidence without executing scripts', async () => {
  const root = await mkdtemp(join(tmpdir(), 'ohos-scan-noexec-'));
  try {
    const marker = join(root, 'should-not-exist');
    const { report } = input({ bin: { tool: 'cli.js' }, scripts: { install: 'touch ' + marker } }, {
      'native.data': Buffer.from([127, 69, 76, 70, 0]),
      'wasm.data': Buffer.from([0, 97, 115, 109, 1]),
      'index.js': "import { exec } from 'node:child_process';\nexec('touch " + marker + "');\n",
      'cli.js': 'process.exit(123);',
    });
    assert.equal(report.status, 'partial');
    for (const code of ['native-code', 'wasm', 'child-process', 'bin', 'install-script']) {
      const reason = report.reasons.find(row => row.code === code); assert(reason, code);
      assert(reason.evidence.every(row => /^[0-9a-f]{64}$/.test(row.sha256)));
    }
    assert.equal(report.reasons.find(row => row.code === 'child-process').evidence[0].line, 1);
    await assert.rejects(access(marker), { code: 'ENOENT' });
  } finally { await rm(root, { recursive: true, force: true }); }
});
test('native suffix is terminal, implicit gyp and wasm references are recorded', () => {
  assert.equal(input({}, { 'client.node.js': 'export const x = 1;' }).report.status, 'usable');
  const { report } = input({}, { 'binding.gyp': '{}', 'other.js': 'WebAssembly.compile(bytes);' });
  assert(report.reasons.some(row => row.code === 'install-script'));
  assert(report.reasons.some(row => row.code === 'wasm'));
  assert(!input({ gypfile: false }, { 'binding.gyp': '{}' }).report.reasons.some(row => row.code === 'install-script'));
  assert.equal(input({}, { 'types.d.ts': "import type {} from 'child_process';" }).report.status, 'usable');
});
test('manifest platform exclusion and native-only main are explicit unavailable cases', () => {
  for (const extra of [{ os: ['linux', 'darwin'] }, { os: ['!openharmony'] }, { os: 'linux' }, { os: ['any', 'linux'] }, { cpu: ['x64'] }, { main: 'addon.node' }]) {
    assert.equal(input(extra).report.status, 'unavailable');
  }
  assert.equal(input({ os: ['openharmony'], cpu: ['arm64'] }).report.status, 'usable');
  assert.equal(input({ os: 'any', cpu: ['!x64'] }).report.status, 'usable');
  assert.equal(input({ os: ['!any'], cpu: 'arm64' }).report.status, 'usable');
  assert.equal(input({ os: [3] }).report.status, 'partial');
  assert.equal(input({ main: 'addon.node', exports: './index.js' }).report.status, 'usable');
});
test('unknown required and optional dependencies prevent a clean single-package verdict', () => {
  const required = input({ dependencies: { other: '^1.0.0' } }).report;
  assert.equal(required.status, 'partial'); assert(required.reasons.some(row => row.code === 'unresolved-dependencies'));
  const optional = input({ optionalDependencies: { other: '^1.0.0' } }).report;
  assert.equal(optional.status, 'partial'); assert(optional.reasons.some(row => row.code === 'optional-dependencies'));
  const peer = input({ optionalDependencies: { other: '^1' }, peerDependencies: { other: '^1' } }).report;
  assert.equal(peer.dependencies.required[0].kind, 'peer');
});
test('installed closure terminates cycles, checks dependency versions and propagates evidence', async () => {
  const root = await mkdtemp(join(tmpdir(), 'ohos-scan-graph-'));
  async function pkg(name, extra) {
    const path = join(root, 'node_modules', name); await mkdir(path, { recursive: true });
    await writeFile(join(path, 'package.json'), JSON.stringify({ name, version: '1.0.0', ...extra }));
    await writeFile(join(path, 'index.js'), 'export const value = 1;');
  }
  try {
    await pkg('a', { dependencies: { b: '^1' } }); await pkg('b', { dependencies: { a: '^1' } });
    let result = await scanInstalled(root);
    assert(result.rows.every(row => row.report.status === 'usable' && row.report.dependencies.coverage === 'complete'));
    await pkg('b', { os: ['linux'], dependencies: { missing: '^1' } });
    result = await scanInstalled(root);
    const a = result.rows.find(row => row.name === 'a').report;
    assert.equal(a.status, 'partial'); assert.equal(a.dependencies.missingCount, 1);
    assert(a.reasons.some(row => row.code === 'dependency-findings'));
    assert.equal(result.rows.find(row => row.name === 'b').report.status, 'unavailable');
    await pkg('a', { dependencies: { b: '^2' } });
    result = await scanInstalled(root);
    assert.equal(result.rows.find(row => row.name === 'a').report.reasons.at(-1).evidence[0].reason, 'version-range-not-verified');
    await pkg('a', { dependencies: { b: '^1' } }); await pkg('b', { version: '1.1.0-beta.1' });
    result = await scanInstalled(root);
    assert.equal(result.rows.find(row => row.name === 'a').report.dependencies.coverage, 'incomplete');
  } finally { await rm(root, { recursive: true, force: true }); }
});
test('directory input rejects file symlinks and never follows them', async () => {
  const root = await mkdtemp(join(tmpdir(), 'ohos-scan-link-'));
  try {
    await writeFile(join(root, 'package.json'), JSON.stringify({ name: 'local', version: '1.0.0' }));
    await symlink('/etc/passwd', join(root, 'leak.js'));
    await assert.rejects(readPackage(root), /package-file-link/);
  } finally { await rm(root, { recursive: true, force: true }); }
});
test('trusted data patch binds name/version/integrity and preserves other platform metadata', () => {
  const { report } = input();
  const sidecar = { schema: 1, plugins: { 'test-package': { version: '1.0.0', integrity: 'fixture-sri', risk: { level: 'low' }, platforms: { android: { status: 'unchanged' } } } } };
  const data = { schema: 1, packages: [{ name: 'test-package', version: '1.0.0', integrity: 'fixture-sri', platforms: { ohos: report } }] };
  const out = applyOhosData(sidecar, data);
  assert.deepEqual(out.plugins['test-package'].platforms.android, { status: 'unchanged' });
  assert.deepEqual(out.plugins['test-package'].risk, sidecar.plugins['test-package'].risk);
  assert.equal(sidecar.plugins['test-package'].platforms.ohos, undefined);
  assert.deepEqual(out.plugins['test-package'].platforms.ohos, ohosSummary(report));
  for (const field of ['version', 'integrity']) {
    const bad = structuredClone(data); bad.packages[0][field] = 'wrong';
    assert.throws(() => applyOhosData(sidecar, bad), /identity-mismatch/);
  }
  assert.throws(() => applyOhosData(sidecar, { ...data, packages: [...data.packages, ...data.packages] }), /identity-mismatch/);
  const inherited = structuredClone(data); inherited.packages[0].name = '__proto__';
  assert.throws(() => applyOhosData(sidecar, inherited), /identity-mismatch/);
  assert.equal(Object.prototype.platforms, undefined);
});
test('real fixed npm archives flow through scan, sidecar and official format-1 parser', async () => {
  for (const id of ['liustack-modlens', 'liustack-modsearch']) {
    const bytes = await readFile(new URL(`fixtures/${id}.tgz`, import.meta.url));
    const metadata = JSON.parse(await readFile(new URL(`fixtures/${id}.json`, import.meta.url)));
    assert(verifyIntegrity(bytes, metadata.integrity));
    const { files } = await unpack(bytes), pkg = JSON.parse(files.get('package.json'));
    const entry = { name: pkg.name, version: pkg.version, title: { en: pkg.name }, summary: { en: 'Fixture' }, category: 'tools' };
    const report = await inspect(entry, { packument: metadata.packument, tarball: bytes, advisories: metadata.advisories });
    assert.equal(report.status, 'passed');
    const out = build([{ entry, report }], { officialPackages: [], blockedVersions: {} });
    assert.deepEqual(out.sidecar.plugins[pkg.name].platforms.ohos, out.index.plugins[0].metadata.platforms.ohos);
    assert.equal(parseMarketIndex(out.index, INDEX_URL).plugins.length, 1);
    assert.equal(out.sidecar.plugins[pkg.name].platforms.ohos.status, 'partial');
    assert(validateEntry({ ...entry, platforms: { ohos: { status: 'usable' } } }).length > 0);
  }
});
