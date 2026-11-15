import { dirname, join, relative, resolve, sep } from 'node:path';

const inside = (root, path) => path === root || path.startsWith(root + sep);
const missing = error => error?.code === 'ENOENT' || error?.code === 'ENOTDIR';
const fault = (code, message) => Object.assign(new Error(message), { code });

// just-bash preserves POSIX codes in its sanitized message; isomorphic-git
// expects error.code. Normalize that representation without changing policy.
export function normalizeGitFilesystem(fs) {
  return new Proxy(fs, { get(target, key) {
    const value = target[key];
    if (typeof value !== 'function') return value;
    return async (...args) => {
      try { return await value.apply(target, args); }
      catch (error) {
        if (!error.code) {
          const code = /^(E[A-Z0-9]+):/.exec(error.message)?.[1];
          if (code) error.code = code;
        }
        throw error;
      }
    };
  } });
}

function nodeStat(value) {
  const type = value.isSymbolicLink ? 0o120000 : value.isDirectory ? 0o040000 : 0o100000;
  return {
    ...value,
    mode: (value.mode & 0o7777) | type,
    dev: Number(value.dev ?? 0), ino: Number(value.ino ?? 0), uid: 0, gid: 0,
    ctime: value.mtime, ctimeMs: value.mtime.getTime(), mtimeMs: value.mtime.getTime(),
    isFile: () => value.isFile, isDirectory: () => value.isDirectory,
    isSymbolicLink: () => value.isSymbolicLink,
  };
}

// Metadata writes are messages to the main-thread owner. Reads, work-tree
// writes, and explicit final-file deletion retain the restricted IFileSystem.
// This accessor is lazy: read-only Git commands do not require a ledger.
export function requireGitOwnership(ctx) {
  const owner = ctx.ownedGit;
  if (!owner || ['createIndex', 'writeIndex', 'writeMetadata', 'commitIndex', 'releaseIndex']
    .some(name => typeof owner[name] !== 'function')) {
    throw fault('ERR_OHOS_OWNERSHIP_UNAVAILABLE', 'Git metadata writes require the main-engine ownership service');
  }
  return owner;
}

export const isGitOwnershipError = error => typeof error?.code === 'string' && error.code.startsWith('ERR_OHOS_');

function metadataBytes(content, encoding) {
  if (typeof content === 'string') return Buffer.from(content, encoding ?? 'utf8');
  if (!(content instanceof Uint8Array) || content.buffer instanceof SharedArrayBuffer) {
    throw fault('ERR_OHOS_GIT_RESOURCE_CONTENT', 'Git metadata requires string or non-shared Uint8Array content');
  }
  return content;
}

/** Paths never grant authority; the main owner independently checks job roots. */
export function createGitFs(ctx, { gitdir, indexFile, objectDirectory, alternates = [], ownedIndex } = {}) {
  const raw = normalizeGitFilesystem(ctx.fs);
  const abort = () => ctx.signal?.throwIfAborted();
  const absolute = path => resolve(ctx.cwd, path);
  gitdir = gitdir && absolute(gitdir);
  indexFile = indexFile && absolute(indexFile);
  const originalObjects = gitdir && join(gitdir, 'objects');
  const index = gitdir && join(gitdir, 'index');
  const mapped = path => {
    path = absolute(path);
    if (indexFile && (path === index || path === index + '.lock')) return indexFile + path.slice(index.length);
    if (objectDirectory && inside(originalObjects, path)) return join(objectDirectory, relative(originalObjects, path));
    return path;
  };
  if (ownedIndex && (typeof ownedIndex.id !== 'string' || !ownedIndex.id || ownedIndex.path !== indexFile)) {
    throw fault('ERR_OHOS_GIT_RESOURCE_ID', 'Owned index must name exactly its returned resource path');
  }
  const requireContext = () => {
    if (!gitdir) throw fault('ERR_OHOS_GIT_METADATA_CONTEXT', 'Git mutations require an explicit repository metadata directory');
  };
  const checkMutation = target => {
    requireContext();
    // The pinned isomorphic-git 1.44.9 never creates index.lock. It is not an
    // alias for the owned index: native Git lock/rename semantics are absent.
    if (target === mapped(index + '.lock')) {
      throw fault('ENOTSUP', 'isomorphic-git 1.44.9 index.lock mutations are not supported');
    }
  };
  const candidates = path => {
    path = absolute(path);
    const primary = mapped(path);
    return originalObjects && inside(originalObjects, path)
      ? [...new Set([primary, ...alternates.map(root => join(root, relative(originalObjects, path)))])]
      : [primary];
  };
  async function read(method, path, ...args) {
    abort(); let last;
    for (const target of candidates(path)) {
      try { return await raw[method](target, ...args); }
      catch (error) { if (!missing(error)) throw error; last = error; }
    }
    throw last ?? fault('ENOENT', 'Missing git path');
  }
  async function mutate(method, path, ...args) {
    abort();
    const target = mapped(path);
    checkMutation(target);
    if (ownedIndex && target === indexFile) {
      throw fault('ENOTSUP', 'Owned index mutations must use the parent writeIndex/commitIndex lifecycle');
    }
    return raw[method](target, ...args);
  }
  async function writeFile(path, content, options = {}) {
    abort();
    const target = mapped(path);
    const settings = typeof options === 'string' ? { encoding: options } : options;
    checkMutation(target);
    if (ownedIndex && target === indexFile) {
      if (settings.mode !== undefined && settings.mode !== 0o600) {
        throw fault('ENOTSUP', 'Owned Git index mode is fixed at creation');
      }
      return requireGitOwnership(ctx).writeIndex(ownedIndex.id, metadataBytes(content, settings.encoding));
    }
    // Each ordinary metadata file is committed by its parent-owned resource.
    // No worker-created temporary, mv, or pathname-prefix cleanup remains here.
    if (inside(gitdir, absolute(path)) || (indexFile && target === indexFile)) {
      return requireGitOwnership(ctx).writeMetadata({ target,
        content: metadataBytes(content, settings.encoding), mode: settings.mode ?? 0o600 });
    }
    await raw.writeFile(target, content, settings.encoding);
    if (settings.mode !== undefined) await raw.chmod(target, settings.mode);
  }
  const promises = {
    readFile: async (path, options = {}) => {
      const data = Buffer.from(await read('readFileBuffer', path));
      const encoding = typeof options === 'string' ? options : options.encoding;
      return encoding ? data.toString(encoding) : data;
    },
    writeFile,
    stat: async path => nodeStat(await read('stat', path)),
    lstat: async path => nodeStat(await read('lstat', path)),
    readlink: async path => read('readlink', path),
    readdir: async path => {
      abort(); const entries = new Set(); let found = false, last;
      for (const target of candidates(path)) {
        try { for (const entry of await raw.readdir(target)) entries.add(entry); found = true; }
        catch (error) { if (!missing(error)) throw error; last = error; }
      }
      if (!found) throw last ?? fault('ENOENT', 'Missing git directory');
      return [...entries].sort();
    },
    mkdir: (path, options) => mutate('mkdir', path, typeof options === 'object' ? options : undefined),
    rmdir: path => mutate('rm', path),
    rm: (path, options) => mutate('rm', path, options),
    unlink: path => mutate('rm', path),
    chmod: (path, mode) => mutate('chmod', path, mode),
    symlink: async (target, path) => {
      abort(); const destination = mapped(path); checkMutation(destination);
      if (ownedIndex && destination === indexFile) throw fault('ENOTSUP', 'An owned Git index cannot be replaced by a symlink');
      return raw.symlink(target, destination);
    },
  };
  return { promises };
}

export async function repository(ctx) {
  let dir = resolve(ctx.cwd);
  for (;;) {
    const dotgit = join(dir, '.git');
    try {
      const stat = await ctx.fs.stat(dotgit);
      if (stat.isDirectory) return { dir, gitdir: await ctx.fs.realpath(dotgit) };
      if (stat.isFile) {
        const text = await ctx.fs.readFile(dotgit);
        if (!/^gitdir: .+\n?$/.test(text)) throw fault('EINVAL', 'Invalid .git indirection file');
        const gitdir = resolve(dir, text.slice(8).trim());
        if (!(await ctx.fs.stat(gitdir)).isDirectory) throw fault('ENOTDIR', 'Git directory is not a directory');
        return { dir, gitdir: await ctx.fs.realpath(gitdir) };
      }
    } catch (error) {
      if (!missing(error) && error?.code !== 'EACCES') throw error;
    }
    const parent = dirname(dir);
    if (parent === dir) throw fault('NOT_REPOSITORY', 'not a git repository (or any parent directory)');
    dir = parent;
  }
}

export function gitStorage(ctx, repo) {
  const env = ctx.env instanceof Map ? Object.fromEntries(ctx.env) : (ctx.env ?? {});
  for (const key of ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_GLOBAL'])
    if (env[key]) throw fault('ENOTSUP', `Unsupported Git environment variable: ${key}`);
  if (env.GIT_CONFIG_COUNT && env.GIT_CONFIG_COUNT !== '0') throw fault('ENOTSUP', 'Git config injection is not supported');
  const path = value => {
    if (!value || value.includes('\0')) throw fault('EINVAL', 'Invalid Git storage path');
    return resolve(ctx.cwd, value);
  };
  const settings = { ...repo,
    indexFile: env.GIT_INDEX_FILE === undefined ? undefined : path(env.GIT_INDEX_FILE),
    objectDirectory: env.GIT_OBJECT_DIRECTORY === undefined ? undefined : path(env.GIT_OBJECT_DIRECTORY),
    alternates: env.GIT_ALTERNATE_OBJECT_DIRECTORIES ? env.GIT_ALTERNATE_OBJECT_DIRECTORIES.split(':').map(path) : [],
  };
  // These paths do not become roots. Every access still goes through ctx.fs.
  return { ...settings, fs: createGitFs(ctx, settings), cache: {} };
}
