import { existsSync, lstatSync, readFileSync, realpathSync } from 'node:fs';
import { basename, dirname, isAbsolute, join, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import Module, { createRequire, isBuiltin, registerHooks } from 'node:module';
import { profileDirectories, profilePackageRoots } from './store.mjs';

const marker = `${sep}.plugin-manager${sep}ohos${sep}generations${sep}`;
const graphs = new Map();
const failure = message => Object.assign(new Error(`[OHOS_PLUGIN_RESOLUTION] ${message}`),
  { code: 'ERR_OHOS_PLUGIN_RESOLUTION' });
let installed, esmResolver;
const require = createRequire(new URL('../../../package.json', import.meta.url));

function nativeResolver() {
  return esmResolver ??= require('node-addon-require-builtin').requireBuiltin('internal/modules/esm/resolve');
}

function nativeEsm(specifier, context) { return nativeResolver().defaultResolve(specifier, context); }

function packageName(request) {
  if (typeof request !== 'string' || isBuiltin(request) || /^[.#/]|^[A-Za-z][A-Za-z+.-]*:/.test(request)) return;
  const name = request.startsWith('@') ? request.split('/').slice(0, 2).join('/') : request.split('/')[0];
  if (/^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(name)) return name;
}

function filename(anchor) {
  if (typeof anchor !== 'string') return;
  if (anchor.startsWith('file:')) return fileURLToPath(anchor);
  if (isAbsolute(anchor)) return anchor;
}

function profileOf(path) {
  const offset = path.indexOf(marker);
  if (offset !== -1) return path.slice(0, offset);
  let known;
  for (const dir of profileDirectories)
    if ((path === dir || path.startsWith(dir + sep)) && (known === undefined || dir.length > known.length)) known = dir;
  // A Worker may first encounter an already-installed profile without the
  // main thread's management backend. Ordinary installation modules are not scanned.
  if (known === undefined && path.includes(`${sep}node_modules${sep}`)) return;
  for (let dir = path.endsWith(sep) ? path.slice(0, -1) : dirname(path); dirname(dir) !== dir; dir = dirname(dir)) {
    if (dir === known) return known;
    if (existsSync(join(dir, '.plugin-manager', 'ohos', 'active.json'))) {
      profileDirectories.add(dir);
      return dir;
    }
  }
  return known;
}

function generationOwner(path, dir) {
  const prefix = dir + marker;
  if (!path.startsWith(prefix)) return;
  const name = path.slice(prefix.length).split(sep)[0];
  if (!/^generation-[A-Za-z0-9]+$/.test(name)) throw failure('版本目录名称无效');
  const root = join(prefix, name);
  let graph = graphs.get(root);
  if (!graph) {
    const lock = join(root, 'lock.json');
    const info = lstatSync(lock);
    if (!info.isFile() || info.nlink !== 1 || realpathSync(root) !== root) throw failure('依赖锁不是独占普通文件');
    graph = JSON.parse(readFileSync(lock, 'utf8'));
    if (graph.schema !== 1 || !Array.isArray(graph.nodes) || !graph.nodes.some(node => node.id === graph.root))
      throw failure('依赖锁无效');
    for (const node of graph.nodes) {
      const target = resolve(root, node.directory ?? '');
      if (typeof node.directory !== 'string' || !target.startsWith(root + sep)
        || !target.endsWith(`${sep}node_modules${sep}${node.name}`) || realpathSync(target) !== target)
        throw failure('锁定包不属于真实版本目录');
      node.packageDir = target;
    }
    graphs.set(root, graph);
  }
  return { graph, node: graph.nodes.find(node => path.startsWith(node.packageDir + sep)) };
}

function packageAnchor(name, target, declarer) {
  if (declarer) return declarer;
  const suffix = `${sep}node_modules${sep}${name}`;
  if (!target.endsWith(suffix)) throw failure('锁定包缺少原生解析锚点');
  return join(target.slice(0, -suffix.length), '.ohos-resolve.cjs');
}

function lookup(path, request) {
  const name = packageName(request);
  if (!name) return;
  const dir = profileOf(path);
  if (!dir) return;
  const owner = generationOwner(path, dir);
  const self = importsScope(path);
  if (self?.value?.name === name && self.value.exports != null)
    return { packageDir: dirname(self.manifest), anchor: path };
  if (owner) {
    // The synthetic anchor is outside every package. Let Node perform its own
    // package lookup there without routing back through the active profile.
    if (!owner.node) return;
    const node = owner.node;
    const edge = Object.hasOwn(node.peers, name) ? node.peers[name] :
      Object.hasOwn(node.dependencies, name) ? node.dependencies[name] : undefined;
    if (!edge) return;
    const target = edge.type === 'host' ? edge : owner.graph.nodes.find(item => item.id === edge.id);
    if (!target) throw failure('依赖锁引用了缺失的包');
    return { packageDir: target.packageDir, anchor: packageAnchor(name, target.packageDir, target.declarer) };
  }
  // Keep native private dependencies of unmanaged packages inside a profile.
  for (const search of Module._nodeModulePaths(dirname(path))) {
    if (!search.startsWith(dir + sep)) break;
    if (existsSync(join(search, name, 'package.json'))) return;
  }
  const root = profilePackageRoots(dir).find(item => item.name === name);
  if (root) return { packageDir: root.realPath, anchor: packageAnchor(name, root.realPath) };
}

export function managedPackageDirectory(anchor, name) {
  const path = filename(anchor);
  return path ? lookup(path, name)?.packageDir : undefined;
}

export function managedRequest(request, anchor) {
  const path = filename(anchor);
  if (!path) return;
  if (filename(request)?.includes(marker))
    return { specifier: request, parentURL: pathToFileURL(path).href };
  // Generation-relative resources and native synthetic anchors must also bypass
  // DSH's current-profile relocation; their physical identity is immutable.
  if (path.includes(marker)) {
    const dir = profileOf(path);
    const owner = generationOwner(path, dir);
    if (!owner.node || !packageName(request) && !request.startsWith('#'))
      return { specifier: request, parentURL: pathToFileURL(path).href };
  }
  if (request.startsWith('#')) {
    if (importsScope(path)) return { specifier: request, parentURL: pathToFileURL(path).href };
    return;
  }
  const target = lookup(path, request);
  if (target) return { specifier: request, parentURL: pathToFileURL(target.anchor).href };
}

function importsScope(path) {
  const dir = profileOf(path);
  if (!dir) return;
  const owner = generationOwner(path, dir);
  if (owner && !owner.node) return;
  for (let parent = dirname(path); parent.startsWith(dir); parent = dirname(parent)) {
    const manifest = join(parent, 'package.json');
    if (existsSync(manifest)) return { manifest, value: JSON.parse(readFileSync(manifest, 'utf8').replace(/^\uFEFF/, '')) };
    if (parent === dir || basename(parent) === 'node_modules') break;
  }
}

function invalidTarget() {
  return Object.assign(new Error('Invalid package imports target'), { code: 'ERR_INVALID_PACKAGE_TARGET' });
}

function invalidSegments(value) {
  return value.split(/[\\/]/).some(part => {
    const decoded = part.replace(/%([a-f0-9]{2})/gi, (_, hex) => String.fromCharCode(parseInt(hex, 16))).toLowerCase();
    return decoded === '.' || decoded === '..' || decoded === 'node_modules';
  });
}

// Node still resolves every selected package, exports condition and filename.
// Selection must keep its continuation: an imports array retries an invalid
// target (including invalid dependency exports), but never a missing module.
function resolveImports(request, context, scope) {
  const nextResolve = nativeEsm;
  const map = scope.value.imports;
  if (request === '#' || request.endsWith('/') || !map || typeof map !== 'object')
    return nextResolve(request, context);
  let target, subpath = '', pattern = false;
  if (Object.hasOwn(map, request) && !request.includes('*')) target = map[request];
  else {
    const matches = Object.keys(map).filter(key => {
      const star = key.indexOf('*');
      return star !== -1 && star === key.lastIndexOf('*') && request.length >= key.length
        && request.startsWith(key.slice(0, star)) && request.endsWith(key.slice(star + 1));
    }).sort((a, b) => b.indexOf('*') - a.indexOf('*') || b.length - a.length);
    if (!matches.length) return nextResolve(request, context);
    const key = matches[0], star = key.indexOf('*');
    target = map[key]; subpath = request.slice(star, request.length - (key.length - star - 1)); pattern = true;
  }
  const conditions = new Set(context.conditions);
  const choose = value => {
    if (typeof value === 'string') {
      if (!value.startsWith('./')) {
        if (value.startsWith('/') || value.startsWith('../') || URL.canParse(value)) throw invalidTarget();
        const specifier = pattern ? value.replaceAll('*', () => subpath) : value;
        const routed = managedRequest(specifier, scope.manifest);
        const target = nativeResolver().packageResolve(specifier, new URL(routed?.parentURL ?? pathToFileURL(scope.manifest).href), conditions);
        return nextResolve(target.href, context);
      }
      if (invalidSegments(value.slice(2))) throw invalidTarget();
      if (pattern && invalidSegments(subpath))
        throw Object.assign(new Error('Invalid package imports subpath'), { code: 'ERR_INVALID_MODULE_SPECIFIER' });
      const url = new URL(value, pathToFileURL(scope.manifest));
      if (!url.pathname.startsWith(new URL('.', pathToFileURL(scope.manifest)).pathname)) throw invalidTarget();
      const specifier = pattern ? url.href.replaceAll('*', () => subpath) : url.href;
      return nextResolve(specifier, context);
    }
    if (Array.isArray(value)) {
      let last = value.length ? undefined : null;
      for (const item of value) {
        try {
          const result = choose(item);
          if (result === undefined) continue;
          if (result === null) { last = null; continue; }
          return result;
        } catch (error) {
          if (error.code !== 'ERR_INVALID_PACKAGE_TARGET') throw error;
          last = error;
        }
      }
      if (last instanceof Error) throw last;
      return last;
    }
    if (value === null) return null;
    if (typeof value === 'object') {
      const keys = Object.keys(value);
      if (keys.some(key => String(+key) === key && +key >= 0 && +key < 0xffffffff))
        throw Object.assign(new Error('Package imports conditions cannot have numeric keys'), { code: 'ERR_INVALID_PACKAGE_CONFIG' });
      for (const key of keys) if (key === 'default' || conditions.has(key)) {
        const result = choose(value[key]);
        if (result !== undefined) return result;
      }
      return;
    }
    throw invalidTarget();
  };
  return choose(target) ?? nextResolve(request, context);
}

// DSH's existing CJS seam receives the real options.paths; public module hooks
// do not. Keep validation and explicit search paths in Node's native resolver.
function resolveManagedCjs(request, parent, main, options, conditions, original) {
  const path = parent?.filename;
  if (!path || !profileOf(path)) return;
  if (request.startsWith('#')) {
    const scope = importsScope(path);
    if (!scope) return;
    // Both #imports and this absolute file take Node's nonrelative paths
    // validation. The manifest is not a candidate for a dependency lookup.
    original.call(Module, scope.manifest, parent, main, options);
    try {
      const result = resolveImports(request, { parentURL: pathToFileURL(path).href,
        conditions: [...(options?.conditions ?? conditions)] }, scope);
      return fileURLToPath(result.url);
    } catch (error) {
      if (['ERR_MODULE_NOT_FOUND', 'ERR_UNSUPPORTED_DIR_IMPORT'].includes(error.code)) error.code = 'MODULE_NOT_FOUND';
      throw error;
    }
  }
  if (options?.paths !== undefined) return original.call(Module, request, parent, main, options);
  const target = managedRequest(request, path);
  if (!target) return;
  const anchor = fileURLToPath(target.parentURL);
  if (anchor === path) return original.call(Module, request, parent, main, options);
  const synthetic = new Module(anchor);
  synthetic.parent = parent;
  synthetic.filename = anchor;
  synthetic.paths = Module._nodeModulePaths(dirname(anchor));
  return original.call(Module, request, synthetic, main, options);
}

export function installPluginResolution() {
  if (installed) return;
  globalThis[Symbol.for('dsh.go.ohos.plugin-resolution')] = {
    packageDirectory: managedPackageDirectory,
    roots: profilePackageRoots,
    request: managedRequest,
    resolveCjs: resolveManagedCjs,
  };
  installed = registerHooks({
    resolve(specifier, context, nextResolve) {
      if (['child_process', 'node:child_process'].includes(specifier)
          && context.parentURL?.startsWith('file:') && profileOf(fileURLToPath(context.parentURL))) {
        return { url: new URL('../process/plugin-process.mjs', import.meta.url).href, shortCircuit: true };
      }
      // Node 24 CJS has no import attributes. ESM may also use a custom
      // condition named "require", while still supplying an attributes object.
      if (context.importAttributes === undefined && context.conditions.includes('require')) return nextResolve(specifier, context);
      if (specifier.startsWith('#') && context.parentURL?.startsWith('file:')) {
        const scope = importsScope(fileURLToPath(context.parentURL));
        if (scope) {
          return { ...resolveImports(specifier, context, scope), shortCircuit: true };
        }
      }
      const target = managedRequest(specifier, context.parentURL);
      if (!target) return nextResolve(specifier, context);
      return nextResolve(specifier, { ...context, parentURL: target.parentURL });
    },
  });
}
