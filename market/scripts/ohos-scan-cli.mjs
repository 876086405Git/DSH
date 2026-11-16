#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { lstat, mkdir, readFile, readdir, realpath, writeFile } from 'node:fs/promises';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';
import semver from 'semver';
import { MAX_BYTES, unpack, verifyIntegrity } from './core.mjs';
import { applyOhosData, scanOhos, withDependencyCoverage, OHOS_SCANNER } from './ohos-scan.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const json = async path => JSON.parse(await readFile(path, 'utf8'));
const save = (path, value) => writeFile(path, JSON.stringify(value, null, 2) + '\n', { flag: 'wx' });
const compare = (a, b) => a < b ? -1 : a > b ? 1 : 0;

export async function readPackage(directory) {
  const root = await realpath(directory);
  if (root !== resolve(directory) || !(await lstat(root)).isDirectory()) throw new Error('package-directory-link');
  const files = new Map();
  let total = 0;
  async function visit(path) {
    for (const entry of (await readdir(path, { withFileTypes: true })).sort((a, b) => compare(a.name, b.name))) {
      if (entry.name === 'node_modules' || entry.name === '.git') continue;
      const file = join(path, entry.name);
      const info = await lstat(file);
      if (info.isSymbolicLink()) throw new Error('package-file-link:' + relative(root, file));
      if (info.isDirectory()) { await visit(file); continue; }
      if (!info.isFile()) throw new Error('package-non-regular-file');
      total += info.size;
      if (total > MAX_BYTES || files.size >= 20000) throw new Error('package-too-large');
      const bytes = await readFile(file);
      if (bytes.length !== info.size) throw new Error('package-changed-during-scan');
      files.set(relative(root, file).split(sep).join('/'), bytes);
    }
  }
  await visit(root);
  const pkg = JSON.parse(files.get('package.json')?.toString() ?? 'null');
  if (!pkg || typeof pkg.name !== 'string' || typeof pkg.version !== 'string') throw new Error('package-identity-missing');
  return { root, files, pkg, report: scanOhos(files, pkg) };
}

export async function scanInstalled(prefix) {
  const root = await realpath(prefix);
  if (root !== resolve(prefix)) throw new Error('prefix-link');
  const packages = new Map();
  async function add(path) {
    if (packages.has(path)) return;
    const item = await readPackage(path);
    packages.set(path, item);
    await discover(join(path, 'node_modules'));
  }
  async function discover(path) {
    let entries;
    try { entries = await readdir(path, { withFileTypes: true }); } catch (error) { if (error.code === 'ENOENT') return; throw error; }
    for (const entry of entries.sort((a, b) => compare(a.name, b.name))) {
      if (entry.name.startsWith('.')) continue;
      const next = join(path, entry.name);
      if (!entry.isDirectory() || entry.isSymbolicLink()) throw new Error('installed-package-not-directory:' + next);
      if (entry.name.startsWith('@')) {
        for (const child of (await readdir(next)).sort()) await add(join(next, child));
      } else await add(next);
    }
  }
  await discover(join(root, 'node_modules'));
  for (const path of ['runtime/ohos/process', 'runtime/bridge/dsh-go-bridge']) {
    try { await lstat(join(root, path, 'package.json')); } catch (error) { if (error.code === 'ENOENT') continue; throw error; }
    await add(join(root, path));
  }
  const resolveDependency = (owner, name) => {
    if (!/^(?:@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9][a-z0-9._~-]*$/i.test(name)) return undefined;
    let directory = owner;
    while (directory === root || directory.startsWith(root + sep)) {
      const item = packages.get(join(directory, 'node_modules', name));
      if (item) return item;
      if (directory === root) break;
      directory = dirname(directory);
    }
  };
  let lockSha256;
  try { lockSha256 = hash(await readFile(join(root, 'package-lock.json'))); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const rows = [];
  for (const item of packages.values()) {
    const seen = new Set([item.root]), queue = [item], missing = [], findings = [];
    for (let i = 0; i < queue.length; i++) {
      const parent = queue[i];
      for (const dep of parent.report.dependencies.required) {
        const found = resolveDependency(parent.root, dep.name);
        if (!found || !semver.validRange(dep.range) || !semver.satisfies(found.pkg.version, dep.range)) {
          missing.push({ owner: parent.pkg.name, name: dep.name, range: dep.range, reason: found ? 'version-range-not-verified' : 'not-present' });
          continue;
        }
        if (seen.has(found.root)) continue;
        seen.add(found.root); queue.push(found);
        if (found.report.ownStatus !== 'usable') findings.push({ name: found.pkg.name, version: found.pkg.version,
          sourceSha256: found.report.source.sha256, ownStatus: found.report.ownStatus,
          reasons: found.report.reasons.filter(row => row.code !== 'unresolved-dependencies').map(row => row.code) });
      }
    }
    const report = withDependencyCoverage(item.report, { missing: missing.slice(0, 12), findings: findings.slice(0, 12), packages: seen.size - 1, lockSha256 });
    report.dependencies.missingCount = missing.length;
    report.dependencies.findingsCount = findings.length;
    rows.push({ path: relative(root, item.root).split(sep).join('/'), name: item.pkg.name, version: item.pkg.version, report });
  }
  rows.sort((a, b) => compare(a.path, b.path));
  return { schema: 1, scanner: OHOS_SCANNER, prefix: root, scope: 'actual installed bytes; no execution; optional dependencies are reported but not traversed',
    lockSha256: lockSha256 ?? null, rows };
}

function table(rows) {
  const text = ['| 包 | 版本 | 静态判断 | 主要证据 | 依赖覆盖 |', '| --- | --- | --- | --- | --- |'];
  for (const row of rows) {
    const report = row.report ?? row.platforms?.ohos;
    text.push(`| ${row.name} | ${row.version} | ${report?.label ?? '部分可用（未完成扫描）'} | ${(report?.reasons?.map(item => item.code) ?? [row.error]).join('、')} | ${report?.dependencies?.coverage ?? 'not-scanned'} |`);
  }
  return text.join('\n') + '\n';
}

export async function scanSnapshot(path) {
  const input = await json(join(path, 'manifest.json'));
  const packages = [], blocked = [];
  for (const row of input.rows) {
    if (!/^[a-z0-9@._-]+$/i.test(row.id)) throw new Error('snapshot-id');
    const bytes = await readFile(join(path, row.id + '.tgz'));
    if (bytes.length > MAX_BYTES || hash(bytes) !== row.sha256 || !verifyIntegrity(bytes, row.integrity)) throw new Error('snapshot-integrity:' + row.name);
    try {
      const { files } = await unpack(bytes);
      const pkg = JSON.parse(files.get('package.json')?.toString() ?? 'null');
      if (pkg?.name !== row.name || pkg?.version !== row.version) throw new Error('manifest-identity-mismatch');
      packages.push({ name: row.name, version: row.version, category: row.category, integrity: row.integrity,
        tarballSha256: row.sha256, source: row.source, platforms: { ohos: scanOhos(files, pkg) } });
    } catch (error) {
      if (row.category !== 'candidates') throw error;
      blocked.push({ name: row.name, version: row.version, category: row.category, error: error.message,
        status: 'partial', label: '部分可用（证据不足）', runtimeVerdict: 'unknown', scanCompleted: false,
        source: row.source, integrity: row.integrity, tarballSha256: row.sha256,
        note: '候选包触发既有归档检查上限或身份校验；没有降低上限，也没有推断代码可运行。' });
    }
  }
  return { schema: 1, scanner: OHOS_SCANNER, inputManifestSha256: hash(await readFile(join(path, 'manifest.json'))), packages, blocked };
}

async function main() {
  const { values } = parseArgs({ options: {
    package: { type: 'string' }, tarball: { type: 'string' }, integrity: { type: 'string' }, installed: { type: 'string' },
    snapshot: { type: 'string' }, 'apply-sidecar': { type: 'string' }, data: { type: 'string' }, out: { type: 'string' },
  } });
  if (!values.out || ['package', 'tarball', 'installed', 'snapshot', 'apply-sidecar'].filter(key => values[key]).length !== 1) {
    throw new Error('usage: node ohos-scan-cli.mjs --package DIR | --tarball TGZ --integrity SRI | --installed PREFIX | --snapshot DIR | --apply-sidecar JSON --data JSON --out NEW_PATH');
  }
  if (values.package) return save(values.out, (await readPackage(resolve(values.package))).report);
  if (values.tarball) {
    const bytes = await readFile(values.tarball);
    if (bytes.length > MAX_BYTES || !verifyIntegrity(bytes, values.integrity)) throw new Error('tarball-integrity');
    const { files } = await unpack(bytes);
    return save(values.out, scanOhos(files, JSON.parse(files.get('package.json')?.toString() ?? 'null')));
  }
  if (values['apply-sidecar']) return save(values.out, applyOhosData(await json(values['apply-sidecar']), await json(values.data)));
  await mkdir(values.out, { recursive: false });
  if (values.installed) {
    const result = await scanInstalled(resolve(values.installed));
    await save(join(values.out, 'all-packages.json'), result);
    const bundled = result.rows.filter(row => row.name.startsWith('@deepseek-ai/dsh-') || row.path.startsWith('runtime/'));
    await save(join(values.out, 'bundled.json'), { ...result, rows: bundled });
    await writeFile(join(values.out, 'bundled.md'), table(bundled), { flag: 'wx' });
    console.log(JSON.stringify({ packages: result.rows.length, bundled: bundled.length }));
  } else {
    const result = await scanSnapshot(resolve(values.snapshot));
    await save(join(values.out, 'scan.json'), result);
    await save(join(values.out, 'ohos-data.json'), { ...result, packages: result.packages.filter(row => row.category === 'plugins') });
    await writeFile(join(values.out, 'market.md'), table([...result.packages, ...result.blocked]), { flag: 'wx' });
    console.log(JSON.stringify({ scanned: result.packages.length, blocked: result.blocked.length }));
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(error => { console.error(error.stack); process.exitCode = 1; });
}
