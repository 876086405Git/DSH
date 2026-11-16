import { createHash } from 'node:crypto';
import { gunzipSync } from 'node:zlib';
import { readFile } from 'node:fs/promises';
import Ajv from 'ajv';
import Ajv2020 from 'ajv/dist/2020.js';
import semver from 'semver';
import parseSpdx from 'spdx-expression-parse';
import licenses from 'spdx-license-list';
import { Parser } from 'tar';
import { parseMarketIndex } from '@deepseek-ai/dsh-plugin-market-index';
import { scanOhos, ohosSummary } from './ohos-scan.mjs';

export const MAX_BYTES = 50 * 1024 * 1024;
export const REGISTRY = 'https://registry.npmjs.org/';
export const INDEX_URL = 'https://go.dshtui.com/market/index.json';
export const LEVELS = {
  'install-scripts': 'high',
  'native-code': 'high',
  shell: 'medium',
  network: 'low',
  filesystem: 'medium',
  obfuscated: 'medium',
  'not-adapted': 'low',
};
const json = async (url) => JSON.parse(await readFile(url, 'utf8'));
const schema = await json(new URL('../schema/plugin.schema.json', import.meta.url));
const validate = new Ajv({ allErrors: true }).compile(schema);
const nativeAjv = new Ajv2020({ strict: false, allErrors: true });
for (const name of ['manifest', 'invoke', 'view', 'stream', 'contributions'])
  nativeAjv.addSchema(await json(new URL(`../vendor/native-schema/${name}.schema.json`, import.meta.url)));
const nativeValidate = nativeAjv.getSchema('https://go.dshtui.com/schema/plugin-kit/v1/manifest.schema.json');
export const digest = (value) => createHash('sha256').update(JSON.stringify(value)).digest('hex');
export const filename = (name) => name.replace('/', '__') + '.json';
export function validateEntry(entry) {
  const errors = [];
  if (Object.hasOwn(entry ?? {}, 'tier')) errors.push('tier-forbidden');
  if (!validate(entry)) errors.push(...validate.errors.map((e) => `schema:${e.instancePath}:${e.message}`));
  if (!semver.valid(entry?.version) || semver.valid(entry.version) !== entry.version) errors.push('version-not-exact');
  for (const raw of [entry?.homepage, ...(Array.isArray(entry?.screenshots) ? entry.screenshots : [])].filter(
    Boolean,
  )) {
    try {
      const u = new URL(raw);
      if (u.protocol !== 'https:' || u.username || u.password) errors.push('invalid-url');
    } catch {
      errors.push('invalid-url');
    }
  }
  return errors;
}
export function osiLicense(value) {
  try {
    const walk = (n) =>
      n.license
        ? !!licenses[n.license]?.osiApproved && !n.exception
        : n.conjunction === 'or'
          ? walk(n.left) || walk(n.right)
          : walk(n.left) && walk(n.right);
    return typeof value === 'string' && walk(parseSpdx(value));
  } catch {
    return false;
  }
}
export async function boundedBody(response, max = MAX_BYTES) {
  if (!response.ok) throw new Error(`http-${response.status}`);
  if (Number(response.headers.get('content-length')) > max) throw new Error('package-too-large');
  const chunks = [];
  let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length;
    if (size > max) throw new Error('package-too-large');
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks);
}
export async function request(url, options = {}) {
  return fetch(url, { signal: AbortSignal.timeout(30_000), ...options, redirect: 'error' });
}
export async function metadata(name, fetcher = request) {
  const response = await fetcher(REGISTRY + encodeURIComponent(name));
  if (response.status === 404) throw new Error('version-not-found');
  return JSON.parse((await boundedBody(response, 10 * 1024 * 1024)).toString());
}
export function verifyIntegrity(bytes, integrity) {
  if (typeof integrity !== 'string' || !/^sha512-[A-Za-z0-9+/]{86}==$/.test(integrity)) return false;
  return 'sha512-' + createHash('sha512').update(bytes).digest('base64') === integrity;
}
export function unpack(bytes) {
  return new Promise((resolve, reject) => {
    const files = new Map();
    const paths = new Set();
    let total = 0;
    let count = 0;
    let stopped = false;
    const fail = (e) => {
      if (!stopped) {
        stopped = true;
        reject(e);
        parser.abort(e);
      }
    };
    const parser = new Parser({
      strict: true,
      maxMetaEntrySize: 1024 * 1024,
      onReadEntry: (entry) => {
        const path = entry.path;
        // Match the eventual extraction target. Directory suffixes share an unsuffixed target;
        // Empty segments and Windows filename rules can alias another name after extraction.
        const target = entry.type === 'Directory' && path.endsWith('/') ? path.slice(0, -1) : path;
        const targetKey = target.toLowerCase();
        if (
          ++count > 20000 ||
          !(target.startsWith('package/') || (entry.type === 'Directory' && target === 'package')) ||
          path.includes('\\') ||
          target.split('/').some((s) => s === '' || s === '..' || s === '.' || /[. ]$/.test(s) || s.includes(':')) ||
          paths.has(targetKey)
        ) {
          entry.resume();
          return fail(new Error('unsafe-tarball'));
        }
        paths.add(targetKey);
        if (entry.type === 'Directory') {
          entry.resume();
          return;
        }
        if (entry.type !== 'File' && entry.type !== 'OldFile') {
          entry.resume();
          return fail(new Error('unsafe-tarball-link'));
        }
        total += entry.size;
        if (total > MAX_BYTES) {
          entry.resume();
          return fail(new Error('package-too-large'));
        }
        const chunks = [];
        let actual = 0;
        entry.on('data', (chunk) => {
          actual += chunk.length;
          if (actual > entry.size) return fail(new Error('unsafe-tarball'));
          chunks.push(chunk);
        });
        entry.on('end', () => files.set(path.slice(8), Buffer.concat(chunks)));
      },
    });
    parser.on('error', reject);
    parser.on('end', () => {
      if (!stopped) resolve({ files, size: total });
    });
    try {
      // Bound decompression before parsing; compressed bombs never expand without limit.
      const tar = gunzipSync(bytes, { maxOutputLength: MAX_BYTES + 16 * 1024 * 1024 });
      parser.end(tar);
    } catch (e) {
      fail(new Error(e.code === 'ERR_BUFFER_TOO_LARGE' ? 'package-too-large' : 'invalid-tarball'));
    }
  });
}
export function scan(files, pkg) {
  const evidence = {};
  const add = (flag, path) => {
    const hits = (evidence[flag] ??= []);
    if (hits.length < 12 && !hits.includes(path)) hits.push(path);
  };
  if (
    ['preinstall', 'install', 'postinstall'].some((k) => typeof pkg.scripts?.[k] === 'string' && pkg.scripts[k].trim())
  )
    add('install-scripts', 'package.json');
  let media = false,
    card = false,
    settings = false;
  for (const [path, bytes] of files) {
    if (
      /(?:\.node|\.exe|\.dll|\.so(?:\.\d+)*|\.dylib|\.wasm)$|(?:^|\/)binding\.gyp$/i.test(path) ||
      bytes.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70])) ||
      bytes.subarray(0, 2).toString() === 'MZ' ||
      ['feedface', 'feedfacf', 'cefaedfe', 'cffaedfe', 'cafebabe'].includes(bytes.subarray(0, 4).toString('hex'))
    )
      add('native-code', path);
    if (!/\.(?:[cm]?js|jsx|tsx?|sh|cjs)$/i.test(path)) continue;
    const source = bytes.toString('utf8');
    if (/\.sh$/i.test(path)) add('shell', path);
    if (/\b(?:child_process|execSync|execFile|spawnSync|spawn)\b|\b(?:exec|system)\s*\(/.test(source))
      add('shell', path);
    if (
      /\bfetch\s*\(|\b(?:https?|wss?):\/\/|(?:from\s*|require\s*\()\s*['"](?:node:)?(?:https?|http2|net|tls|ws)['"]|\bWebSocket\b/.test(
        source,
      )
    )
      add('network', path);
    // Dynamic destinations cannot be proven workspace-contained by text scanning.
    if (
      /\b(?:writeFile(?:Sync)?|appendFile(?:Sync)?|createWriteStream|mkdir(?:Sync)?|rm(?:Sync)?|unlink(?:Sync)?|rename(?:Sync)?|copyFile(?:Sync)?)\s*\(/.test(
        source,
      )
    )
      add('filesystem', path);
    if (
      bytes.length > 100 * 1024 &&
      (source.split('\n').some((line) => line.length > 2000) || /\b_0x[0-9a-f]+\b|eval\s*\(/i.test(source))
    )
      add('obfuscated', path);
    media ||= source.includes('dsh-go/media');
    card ||= source.includes('dsh-go/view');
    settings ||= /dsh-settings|settings\.register|settings\.define/.test(source);
  }
  const manifest = pkg.dshGo;
  let manifestOk = !!manifest && Buffer.byteLength(JSON.stringify(manifest)) <= 16384 && nativeValidate(manifest);
  const items = manifestOk
    ? ['composer.actions', 'message.actions', 'composer.strip', 'panels'].flatMap(
        (surface) => manifest.contributes[surface] ?? [],
      )
    : [];
  if (new Set(items.map((item) => item.id)).size !== items.length) manifestOk = false;
  const slots = manifestOk && items.length > 0;
  const adapted = !!manifestOk && !!(slots || media || card);
  const features = adapted
    ? [
        ...(slots ? ['native-slots'] : []),
        ...(card ? ['native-cards'] : []),
        ...(media ? ['media'] : []),
        ...(settings ? ['settings-page'] : []),
      ]
    : [];
  if (!adapted) add('not-adapted', 'package.json');
  const flags = Object.keys(LEVELS).filter((f) => evidence[f]);
  return {
    risk: {
      level: flags.some((f) => LEVELS[f] === 'high')
        ? 'high'
        : flags.some((f) => LEVELS[f] === 'medium')
          ? 'medium'
          : 'low',
      flags,
    },
    evidence,
    dshGo: { adapted, ...(manifestOk && manifest.minApp ? { minApp: manifest.minApp } : {}), features },
    platforms: { ohos: scanOhos(files, pkg) },
  };
}
export function makeIndex(rows) {
  const categories = {};
  for (const { entry } of rows) categories[entry.category] = { title: { en: entry.category } };
  const index = {
    format: 1,
    title: { zh: 'DSH Go 插件市场', en: 'DSH Go plugins' },
    metadata: { categories },
    plugins: rows.map(({ entry, report }) => ({
      name: entry.name,
      title: entry.title,
      description: entry.summary,
      ...(entry.homepage ? { homepage: entry.homepage } : {}),
      metadata: { category: entry.category, platforms: { ohos: ohosSummary(report.platforms.ohos) } },
      versions: [
        {
          version: entry.version,
          publishTimestamp: report.publishTimestamp,
          source: { type: 'npm', registry: REGISTRY },
          ...(report.engines?.dsh ? { engines: report.engines } : {}),
        },
      ],
    })),
  };
  parseMarketIndex(index, INDEX_URL);
  return index;
}
export async function inspect(
  entry,
  { fetcher = request, packument, tarball, advisories, now = new Date().toISOString() } = {},
) {
  const report = {
    schema: 1,
    name: entry?.name,
    version: entry?.version,
    entryHash: digest(entry),
    checkedAt: now,
    status: 'denied',
    denials: validateEntry(entry),
    warnings: [],
    scope: 'exact npm tarball; npm advisories for this package only, not resolved dependencies',
  };
  if (report.denials.length) return report;
  try {
    packument ??= await metadata(entry.name, fetcher);
    const version = packument.versions?.[entry.version];
    if (!version) throw new Error('version-not-found');
    report.publishTimestamp = Math.floor(Date.parse(packument.time?.[entry.version]) / 1000);
    if (!Number.isFinite(report.publishTimestamp)) throw new Error('invalid-publish-time');
    if (version.dist?.unpackedSize > MAX_BYTES) throw new Error('package-too-large');
    const tarUrl = new URL(version.dist?.tarball);
    if (tarUrl.origin !== new URL(REGISTRY).origin || tarUrl.username || tarUrl.password)
      throw new Error('untrusted-tarball-url');
    tarball ??= await boundedBody(await fetcher(tarUrl, { signal: AbortSignal.timeout(180_000) }));
    if (tarball.length > MAX_BYTES) throw new Error('package-too-large');
    if (!verifyIntegrity(tarball, version.dist?.integrity)) throw new Error('integrity-mismatch');
    report.integrity = version.dist.integrity;
    const { files, size } = await unpack(tarball);
    report.unpackedSize = size;
    const pkg = JSON.parse(files.get('package.json')?.toString() ?? 'null');
    if (pkg?.name !== entry.name || pkg?.version !== entry.version) throw new Error('manifest-identity-mismatch');
    if (!osiLicense(pkg.license)) report.denials.push('license-not-osi');
    if (typeof pkg.dsh?.bundle?.patch !== 'string' || !files.has(pkg.dsh.bundle.patch.replace(/^\.\//, '')))
      report.denials.push('not-dsh-bundle');
    report.engines = pkg.engines?.dsh ? { dsh: pkg.engines.dsh } : {};
    Object.assign(report, scan(files, pkg));
    report.warnings = report.risk.flags;
    if (advisories === undefined) {
      advisories = JSON.parse(
        (
          await boundedBody(
            await fetcher(REGISTRY + '-/npm/v1/security/advisories/bulk', {
              method: 'POST',
              headers: { 'content-type': 'application/json' },
              body: JSON.stringify({ [entry.name]: [entry.version] }),
            }),
            5 * 1024 * 1024,
          )
        ).toString(),
      );
    }
    if (
      !advisories ||
      typeof advisories !== 'object' ||
      Array.isArray(advisories) ||
      Object.values(advisories).some((v) => !Array.isArray(v))
    )
      throw new Error('advisory-unavailable');
    report.advisories = Object.values(advisories)
      .flat()
      .map((a) => ({ id: a.id, url: a.url, severity: a.severity, vulnerable_versions: a.vulnerable_versions }));
    if (
      report.advisories.some(
        (a) =>
          !semver.validRange(a.vulnerable_versions) || !['low', 'moderate', 'high', 'critical'].includes(a.severity),
      )
    )
      throw new Error('advisory-unavailable');
    if (
      report.advisories.some(
        (a) =>
          ['high', 'critical'].includes(a.severity) &&
          semver.satisfies(entry.version, a.vulnerable_versions, { includePrerelease: true }),
      )
    )
      report.denials.push('high-advisory');
    try {
      makeIndex([{ entry, report }]);
    } catch (e) {
      report.denials.push(`invalid-format-1:${e.message}`);
    }
  } catch (e) {
    report.denials.push(e.message);
  }
  report.status = report.denials.length ? 'denied' : 'passed';
  return report;
}
