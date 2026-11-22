// dsh-app boot cache for `dsh web`, preloaded by the /usr/local/bin/dsh shim (`--import`).
//
// Under proot every path lookup traps into the tracer. While DSH boots, its plugin loader
// canonicalizes and probes the same read-only package tree thousands of times (realpath walks
// every component, `existsSync` probes each node_modules level, the same package.json is read
// again and again). Until the server prints its URL line, those calls for paths below ROOTS are
// answered from a per-component cache: one lstat per path component, misses remembered. Other
// paths, other call shapes, and everything after boot go straight to node:fs.
//
// ROOTS only holds trees nothing writes to while DSH runs (the runtime replaces them only while
// DSH is stopped; the app's own files under /opt/dsh-app are written before the launch, and are
// not cached anyway). Symbolic links are followed only into ROOTS; ambiguous path
// spellings and links outside those trees fall back to node:fs.
import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
import { resolve } from 'node:path';
import { isMainThread } from 'node:worker_threads';

export const ROOTS = ['/opt/dsh/', '/opt/node/', '/opt/dsh-go/'];

/** Answer for "not cacheable here": the caller uses node:fs. */
export const PASS = Symbol('pass');

/**
 * The cache itself, over an fs-like object (lstatSync, realpathSync and its native, readFileSync).
 * `real(p)` returns the canonical path, `{code, at}` when component `at` is missing, or PASS.
 */
export function createBootCache({ roots = ROOTS, fsImpl = fs } = {}) {
  const lstat = fsImpl.lstatSync.bind(fsImpl);
  const canonical = fsImpl.realpathSync.native.bind(fsImpl.realpathSync);
  const logical = fsImpl.realpathSync.bind(fsImpl);
  // "<canonical parent>/<name>" -> its canonical path (key itself unless a link) | {link} | {code, at}
  const components = new Map();
  const manifests = new Map(); // package.json path -> text
  const inRoots = (p) => roots.some((r) => (p + '/').startsWith(r));
  // Components inside ROOTS, and the directories above them (/opt).
  const cacheable = (p) => inRoots(p) || roots.some((r) => r.startsWith(p + '/'));
  const eligible = (p) => typeof p === 'string' && p.startsWith('/') && !p.endsWith('/') &&
    !/(?:^|\/)\.{1,2}(?:\/|$)/u.test(p) && inRoots(p);

  function real(p) {
    const cached = components.get(p);
    if (typeof cached === 'string') return cached;
    const parts = resolve(p).split('/');
    const last = parts.length - 1;
    let cur = '';
    for (let i = 1; i <= last; i++) {
      const key = cur + '/' + parts[i];
      let hit = components.get(key);
      if (hit === undefined) {
        let st;
        try {
          st = lstat(key);
        } catch (error) {
          if (error?.code !== 'ENOENT' && error?.code !== 'ENOTDIR') return PASS;
          hit = { code: error.code, at: key };
          if (cacheable(cur)) components.set(key, hit);
          return hit;
        }
        if (st.isSymbolicLink()) {
          let target;
          try {
            target = canonical(key);
            if (!inRoots(target) || logical(key) !== target) return PASS;
          } catch { return PASS; }
          hit = { link: target };
        } else {
          hit = key;
        }
        if (cacheable(key)) components.set(key, hit);
      }
      if (typeof hit === 'object') {
        if (hit.code !== undefined) return hit;
        cur = hit.link;
        continue;
      }
      cur = hit;
    }
    return cur || '/';
  }

  return {
    eligible,
    real(p) {
      return eligible(p) ? real(p) : PASS;
    },
    manifest(p, read) {
      if (!eligible(p) || !p.endsWith('/package.json')) return PASS;
      let text = manifests.get(p);
      if (text === undefined) {
        if (typeof real(p) !== 'string') return PASS;
        text = read();
        manifests.set(p, text);
      }
      return text;
    },
    clear() {
      components.clear();
      manifests.clear();
    },
  };
}

function missing(code, syscall, path) {
  const text = code === 'ENOTDIR' ? 'not a directory' : 'no such file or directory';
  return Object.assign(new Error(`${code}: ${text}, ${syscall} '${path}'`), {
    errno: code === 'ENOTDIR' ? -20 : -2,
    code,
    syscall,
    path,
  });
}

const utf8 = (o) =>
  o === 'utf8' || o === 'utf-8' || (o !== null && typeof o === 'object' && /^utf-?8$/i.test(o.encoding ?? '') && o.flag === undefined);
const stringResult = (o) => o === undefined || o === 'utf8' || o === 'utf-8' || (o !== null && typeof o === 'object' && (o.encoding === undefined || /^utf-?8$/i.test(o.encoding)));

/**
 * Patches fsImpl's realpathSync (and .native), existsSync and readFileSync until the URL line
 * reaches `stdout` (or `maxMs` passes), then puts the originals back. Returns `uninstall`.
 */
export function install({ roots = ROOTS, fsImpl = fs, stdout = process.stdout, maxMs = 120_000 } = {}) {
  const cache = createBootCache({ roots, fsImpl });
  const original = {
    realpathSync: fsImpl.realpathSync,
    native: fsImpl.realpathSync.native,
    existsSync: fsImpl.existsSync,
    readFileSync: fsImpl.readFileSync,
    write: stdout.write,
  };
  let active = true;

  function realpathSync(p, options) {
    if (active && stringResult(options)) {
      const hit = cache.real(p);
      if (typeof hit === 'string') return hit;
      // node:fs's JS realpath reports the first missing component, from lstat.
      if (hit !== PASS) throw missing(hit.code, 'lstat', hit.at);
    }
    return Reflect.apply(original.realpathSync, this, arguments);
  }
  realpathSync.native = function native(p, options) {
    if (active && stringResult(options)) {
      const hit = cache.real(p);
      if (typeof hit === 'string') return hit;
      if (hit !== PASS) throw missing(hit.code, 'realpath', p);
    }
    return Reflect.apply(original.native, this, arguments);
  };
  function existsSync(p) {
    if (active) {
      const hit = cache.real(p);
      if (hit !== PASS) return typeof hit === 'string';
    }
    return Reflect.apply(original.existsSync, this, arguments);
  }
  function readFileSync(p, options) {
    if (active && utf8(options)) {
      const args = arguments;
      const text = cache.manifest(p, () => Reflect.apply(original.readFileSync, this, args));
      if (text !== PASS) return text;
    }
    return Reflect.apply(original.readFileSync, this, arguments);
  }

  let timer;
  function uninstall() {
    if (!active) return;
    active = false;
    cache.clear();
    clearTimeout(timer);
    if (fsImpl.realpathSync === realpathSync) fsImpl.realpathSync = original.realpathSync;
    if (fsImpl.existsSync === existsSync) fsImpl.existsSync = original.existsSync;
    if (fsImpl.readFileSync === readFileSync) fsImpl.readFileSync = original.readFileSync;
    if (stdout.write === watch) stdout.write = original.write;
    // ESM named imports taken during boot keep the wrappers, which now pass straight through;
    // not re-syncing leaves whatever else patched node builtins meanwhile as it was.
  }
  function watch(chunk, ...rest) {
    const result = Reflect.apply(original.write, this, [chunk, ...rest]);
    const text = typeof chunk === 'string' ? chunk : ArrayBuffer.isView(chunk) ? Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength).toString() : String(chunk);
    if (text.includes('?token=')) uninstall();
    return result;
  }

  fsImpl.realpathSync = realpathSync;
  fsImpl.existsSync = existsSync;
  fsImpl.readFileSync = readFileSync;
  stdout.write = watch;
  if (fsImpl === fs) syncBuiltinESMExports();
  timer = setTimeout(uninstall, maxMs);
  timer.unref?.();
  return uninstall;
}

// Preloaded by the shim for `dsh web` only; inert anywhere else (workers, other commands).
if (isMainThread && process.argv[2] === 'web' && process.env.DSH_GO_BOOT_CACHE !== '0') {
  try {
    const root = globalThis[Symbol.for('dsh.go.direct')]?.root;
    install({ roots: root ? ROOTS.map((path) => root + path) : ROOTS });
  } catch {
    // Never in the way of the launch: without the cache DSH just boots slower.
  }
}
