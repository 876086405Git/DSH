import { createRequire } from 'node:module';
import { parseRegistrySpec, registryError, secureUrl } from './registry.mjs';

const semver = createRequire(new URL('../../../package.json', import.meta.url))('semver');
const maxNodes = 512;
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
function fields(manifest, name) {
  const value = manifest[name] ?? {};
  if (!object(value)) throw registryError(`${manifest.name}: invalid ${name}`);
  return value;
}
function compatiblePlatform(manifest) {
  for (const [field, current] of [['os', 'openharmony'], ['cpu', 'arm64']]) {
    if (manifest[field] === undefined) continue;
    const values = manifest[field];
    if (!Array.isArray(values) || values.some(v => typeof v !== 'string'))
      throw registryError(`${manifest.name}: invalid ${field}`);
    if (values.includes('!' + current)) return false;
    const positive = values.filter(v => !v.startsWith('!'));
    if (positive.length && !positive.includes(current) && !positive.includes('any')) return false;
  }
  return true;
}
function integrityOf(manifest) {
  const value = manifest.dist?.integrity;
  if (typeof value !== 'string' || !value.trim()) throw registryError(`${manifest.name}: missing integrity`);
  let supported = false;
  for (const token of value.trim().split(/\s+/)) {
    const match = /^(sha256|sha384|sha512)-([A-Za-z0-9+/]+={0,2})$/.exec(token);
    if (!match) throw registryError(`${manifest.name}: unsupported integrity`);
    const bytes = Buffer.from(match[2], 'base64');
    if (bytes.length !== Number(match[1].slice(3)) / 8 || bytes.toString('base64') !== match[2])
      throw registryError(`${manifest.name}: invalid integrity`);
    supported = true;
  }
  if (!supported) throw registryError(`${manifest.name}: unsupported integrity`);
  return value;
}
function hostEdge(name, range, hostPackages) {
  if (typeof range !== 'string' || !semver.validRange(range))
    throw registryError(`${name}: unsupported host dependency range`);
  const host = hostPackages.get(name);
  if (!host) return;
  if (!semver.satisfies(host.version, range, { includePrerelease: true }))
    throw registryError(`${name}: incompatible host version ${host.version}`);
  return { type: 'host', name, version: host.version, packageDir: host.packageDir,
    ...(host.declarer === undefined ? {} : { declarer: host.declarer }) };
}

/** Resolve a complete fixed graph without writing profile files or importing package code. */
export async function resolveGraph({ spec, registryClient, hostPackages = new Map(), signal }) {
  const nodes = new Map();
  async function visit(request, optional = false) {
    signal?.throwIfAborted();
    const manifest = await registryClient.readManifest(request);
    signal?.throwIfAborted();
    if (!compatiblePlatform(manifest)) {
      if (optional) return;
      throw registryError(`${manifest.name}: incompatible OHOS arm64 platform`);
    }
    const id = `${manifest.name}@${manifest.version}`;
    if (nodes.has(id)) return id;
    if (nodes.size >= maxNodes) throw registryError('Plugin graph exceeds 512 packages');
    const scripts = fields(manifest, 'scripts');
    if (['preinstall', 'install', 'postinstall'].some(name => Object.hasOwn(scripts, name)))
      throw registryError(`${manifest.name}: installation script is unsupported`);
    if (manifest.gypfile === true) throw registryError(`${manifest.name}: native build is unsupported`);
    const node = { id, name: manifest.name, version: manifest.version,
      resolved: secureUrl(manifest.dist?.tarball).href, integrity: integrityOf(manifest), manifest,
      dependencies: {}, peers: {}, omitted: {} };
    nodes.set(id, node);
    const peerMeta = fields(manifest, 'peerDependenciesMeta');
    for (const [name, range] of Object.entries(fields(manifest, 'peerDependencies'))) {
      parseRegistrySpec(`${name}@${range}`);
      const edge = hostEdge(name, range, hostPackages);
      if (edge) Object.defineProperty(node.peers, name, { value: edge, enumerable: true });
      else if (peerMeta[name]?.optional === true) Object.defineProperty(node.omitted, name, {
        value: 'missing optional peer', enumerable: true });
      else throw registryError(`${manifest.name}: unsupported non-host peer ${name}`);
    }
    const optionalDeps = fields(manifest, 'optionalDependencies');
    const dependencies = { ...fields(manifest, 'dependencies'), ...optionalDeps };
    for (const [name, range] of Object.entries(dependencies)) {
      if (typeof range !== 'string') throw registryError(`${manifest.name}: invalid dependency ${name}`);
      parseRegistrySpec(`${name}@${range}`);
      const host = Object.hasOwn(node.peers, name) ? hostEdge(name, range, hostPackages) : undefined;
      const target = host ? undefined : await visit(`${name}@${range}`, Object.hasOwn(optionalDeps, name));
      if (!host && target === undefined) Object.defineProperty(node.omitted, name, {
        value: 'optional dependency excluded by platform', enumerable: true });
      else Object.defineProperty(node.dependencies, name, { value: host ?? { type: 'package', id: target }, enumerable: true });
    }
    return id;
  }
  const root = await visit(spec);
  return { schema: 1, root, nodes: [...nodes.values()] };
}
