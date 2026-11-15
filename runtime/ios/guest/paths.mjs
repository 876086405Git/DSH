import { lstatSync, realpathSync, statSync } from 'node:fs';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';

const denied = message => Object.assign(new Error(`EACCES: IOS_GUEST_PATH_DENIED: ${message}`), { code: 'EACCES' });
const inside = (root, path) => root === '/' ? isAbsolute(path) : path === root || path.startsWith(root + sep);

function directory(path) {
  if (typeof path !== 'string' || !isAbsolute(path) || path.includes('\0')) throw denied('Expected an absolute host directory');
  const canonical = realpathSync(path);
  if (canonical === '/' || !statSync(canonical).isDirectory()) throw denied('A filesystem root is not an authorized workspace');
  return canonical;
}

// Resolves the existing prefix for file-tool destinations that do not exist yet.
// Native execution still has to bind root FDs and enforce every operation; this
// trusted path conversion is not a substitute for that native boundary.
function canonicalDestination(path) {
  let current = path;
  const missing = [];
  for (;;) {
    try { return join(realpathSync(current), ...missing); }
    catch (error) {
      if (error.code !== 'ENOENT') throw error;
      try {
        if (lstatSync(current).isSymbolicLink()) throw denied('A dangling link is not a missing file destination');
      } catch (linkError) { if (linkError.code !== 'ENOENT') throw linkError; }
      const parent = dirname(current);
      if (parent === current) throw error;
      missing.unshift(current.slice(parent.length + (parent === '/' ? 0 : 1)));
      current = parent;
    }
  }
}

export class GuestPaths {
  constructor({ workspaceRoot, temporaryRoot, forbiddenRoots = [] }) {
    const workspace = directory(workspaceRoot), temporary = directory(temporaryRoot);
    if (inside(workspace, temporary) || inside(temporary, workspace)) throw denied('Workspace and private temporary roots must be disjoint');
    for (const path of forbiddenRoots) {
      const blocked = canonicalDestination(resolve(path));
      for (const root of [workspace, temporary]) {
        if (inside(root, blocked) || inside(blocked, root)) throw denied('App state overlaps an execution mount');
      }
    }
    this.mounts = Object.freeze([
      Object.freeze({ host: workspace, guest: '/workspace' }),
      Object.freeze({ host: temporary, guest: '/tmp' }),
    ]);
  }

  toGuest(path) {
    if (typeof path !== 'string' || !isAbsolute(path) || path.includes('\0')) throw denied('Expected an absolute host path');
    const canonical = canonicalDestination(path);
    const mount = this.mounts.find(row => inside(row.host, canonical));
    if (!mount) throw denied('Host path is outside this session');
    return join(mount.guest, relative(mount.host, canonical));
  }

  toHost(path, { followFinalLink = true } = {}) {
    if (typeof path !== 'string' || path.includes('\0')) throw denied('Invalid guest path');
    const mount = this.mounts.find(row => path === row.guest || path.startsWith(row.guest + '/'));
    if (!mount) return undefined; // Other local paths retain the existing provider.
    const suffix = path.slice(mount.guest.length);
    if (suffix.split('/').includes('..')) throw denied('Guest aliases do not accept parent traversal');
    const target = join(mount.host, suffix);
    // lstat must observe a leaf link, including a dangling one. Resolve its
    // parent for confinement without turning that link into a regular file.
    const canonical = !followFinalLink && target !== mount.host
      ? join(canonicalDestination(dirname(target)), basename(target))
      : canonicalDestination(target);
    if (!inside(mount.host, canonical)) throw denied('Guest alias resolves outside its authorized mount');
    return canonical;
  }
}

export function guestEnvironment(input = {}, cwd) {
  const env = { PATH: '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', HOME: '/tmp', TMPDIR: '/tmp', LANG: 'C.UTF-8', PWD: cwd };
  for (const name of ['LANG', 'LC_ALL', 'LC_CTYPE', 'TZ', 'TERM', 'COLORTERM', 'NO_COLOR', 'COLUMNS', 'LINES']) {
    if (typeof input[name] === 'string' && !input[name].includes('\0')) env[name] = input[name];
  }
  return Object.freeze(env);
}
