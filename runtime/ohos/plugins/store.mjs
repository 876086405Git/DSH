import {
  closeSync, constants, existsSync, fsyncSync, lstatSync, mkdirSync,
  openSync, readFileSync, readdirSync, readlinkSync, realpathSync, renameSync, rmSync,
  unlinkSync, writeFileSync,
} from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { randomUUID } from 'node:crypto';

const active = new Map();
export const profileDirectories = new Set();
const files = ['package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'cordis.patch.yml', 'compatibility.json'];
const packageName = /^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/;
const generationName = /^generation-[A-Za-z0-9]+$/;
const rollbackId = /^[a-f0-9]{32}$/;
const failure = message => Object.assign(new Error(`[OHOS_PLUGIN_STORE] ${message}`), { code: 'ERR_OHOS_PLUGIN_STORE' });

function stat(path) {
  try { return lstatSync(path); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
}

function syncDirectory(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try { fsyncSync(fd); } finally { closeSync(fd); }
}

function directory(parent, name) {
  const path = join(parent, name);
  const info = stat(path);
  if (!info) { mkdirSync(path, { mode: 0o700 }); syncDirectory(parent); }
  else if (!info.isDirectory() || info.isSymbolicLink()) throw failure(`安装目录不是普通目录：${name}`);
  return path;
}

function storeRoot(dir, create = false) {
  const path = join(dir, '.plugin-manager', 'ohos');
  if (!create && !existsSync(path)) return;
  const manager = create ? directory(dir, '.plugin-manager') : join(dir, '.plugin-manager');
  for (const item of [manager, path]) {
    if (create && item === path) directory(manager, 'ohos');
    const info = stat(item);
    if (!info?.isDirectory() || info.isSymbolicLink()) throw failure('插件事务目录包含链接或非目录');
  }
  return path;
}

function regularBytes(path) {
  const info = stat(path);
  if (!info) return null;
  if (!info.isFile() || info.nlink !== 1) throw failure(`配置不是独占普通文件：${path}`);
  return readFileSync(path);
}

function writeAtomic(path, bytes) {
  const temporary = join(dirname(path), `.ohos-write-${randomUUID()}`);
  const fd = openSync(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try {
    writeFileSync(fd, bytes); fsyncSync(fd);
  } catch (error) {
    unlinkSync(temporary); throw error;
  } finally { closeSync(fd); }
  try { renameSync(temporary, path); syncDirectory(dirname(path)); }
  finally { if (stat(temporary)) unlinkSync(temporary); }
}

function removeFile(path) {
  if (!stat(path)) return;
  unlinkSync(path); syncDirectory(dirname(path));
}

function syncFile(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try { fsyncSync(fd); } finally { closeSync(fd); }
}

function rollbackFiles(record) {
  return [{ name: 'active.json', bytes: record.packages }, ...record.files];
}

function rollbackDirectory(root, record, create = false) {
  if (record.rollbackId === undefined) return;
  const name = `rollback-${record.rollbackId}`;
  if (!create && !stat(join(root, name))) return;
  return directory(root, name);
}

// The durable pending journal owns this directory before it is created. No
// installer operation may start until every ordinary beforeimage is synced.
function prepareRollback(root, record) {
  const backup = rollbackDirectory(root, record, true);
  for (const item of rollbackFiles(record)) {
    if (item.bytes === null) continue;
    const path = join(backup, item.name), expected = Buffer.from(item.bytes, 'base64');
    const current = regularBytes(path);
    if (current !== null) {
      if (!current.equals(expected)) throw failure('回滚副本字节不符，保留现场');
      syncFile(path);
      continue;
    }
    const fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try { writeFileSync(fd, expected); fsyncSync(fd); }
    finally { closeSync(fd); }
  }
  syncDirectory(backup);
}

function cleanupRollback(root, record) {
  const backup = rollbackDirectory(root, record);
  if (!backup) return;
  const owned = new Set(rollbackFiles(record).filter(item => item.bytes !== null).map(item => item.name));
  for (const name of readdirSync(backup)) {
    if (!owned.has(name)) throw failure('回滚目录含有非本事务文件，保留现场');
    regularBytes(join(backup, name));
  }
  rmSync(backup, { recursive: true, force: true });
  syncDirectory(root);
}

function restoreFile(path, bytes, root, record, name) {
  const before = bytes === null ? null : Buffer.from(bytes, 'base64');
  const current = regularBytes(path);
  if (current === null && before === null || current !== null && before !== null && current.equals(before)) {
    if (current !== null) syncFile(path);
    syncDirectory(dirname(path));
    return;
  }
  if (before === null) { removeFile(path); return; }
  if (record.rollbackId !== undefined) {
    const backup = rollbackDirectory(root, record);
    if (!backup) throw failure('回滚副本缺失，保留现场');
    const source = join(backup, name), saved = regularBytes(source);
    if (saved === null || !saved.equals(before)) throw failure('回滚副本缺失或字节不符，保留现场');
    renameSync(source, path);
    // The target must be durable before a newly unselected generation is freed.
    // A later retry compares target bytes first: the backup may be consumed.
    syncDirectory(dirname(path));
    syncDirectory(backup);
    return;
  }
  // Old schema2 journals have no ordinary beforeimages. Keep compatibility;
  // their recovery can still need free space for a replacement file.
  writeAtomic(path, before);
}

function linkPath(dir, name) {
  if (!packageName.test(name)) throw failure('插件包名无效');
  const parent = join(dir, 'node_modules');
  for (const path of [parent, ...(name.startsWith('@') ? [join(parent, name.split('/')[0])] : [])]) {
    const info = stat(path);
    if (info && (!info.isDirectory() || info.isSymbolicLink())) throw failure('插件父目录不是普通目录');
  }
  return join(parent, name);
}

function ownedTarget(dir, path, target) {
  const root = join(dir, '.plugin-manager', 'ohos', 'generations') + sep;
  const absolute = resolve(dirname(path), target);
  if (!absolute.startsWith(root) || !generationName.test(absolute.slice(root.length).split(sep)[0])) {
    throw failure('已有插件目录不属于鸿蒙安装器，不能覆盖或删除');
  }
  return absolute;
}

function currentLink(dir, path) {
  const info = stat(path);
  if (!info) return null;
  if (!info.isSymbolicLink()) throw failure('已有插件不是鸿蒙管理的版本链接，不能覆盖或删除');
  const target = readlinkSync(path);
  ownedTarget(dir, path, target);
  return target;
}

function packageTarget(dir, target) {
  if (typeof target !== 'string' || isAbsolute(target) || target.split('/').some(part => !part || part === '.' || part === '..')
    || !generationName.test(target.split('/')[0])) throw failure('插件版本路径无效');
  return join(dir, '.plugin-manager', 'ohos', 'generations', target);
}

function parsePackages(dir, bytes) {
  if (bytes === null) return Object.create(null);
  const value = JSON.parse(bytes);
  if (value?.schema !== 1 || !value.packages || typeof value.packages !== 'object' || Array.isArray(value.packages))
    throw failure('插件版本清单无效');
  for (const [name, target] of Object.entries(value.packages)) {
    if (!packageName.test(name)) throw failure('插件版本清单包名无效');
    packageTarget(dir, target);
  }
  return Object.assign(Object.create(null), value.packages);
}

function readPackages(dir, root) {
  return parsePackages(dir, regularBytes(join(root, 'active.json')));
}

function writePackages(root, packages) {
  writeAtomic(join(root, 'active.json'), `${JSON.stringify({ schema: 1, packages })}\n`);
}

export function profilePackageRoots(dir) {
  if (!existsSync(dir)) return [];
  dir = realpathSync(dir);
  profileDirectories.add(dir);
  const root = storeRoot(dir);
  if (!root) return [];
  return Object.entries(readPackages(dir, root)).map(([name, target]) => {
    const realPath = packageTarget(dir, target);
    if (!stat(realPath)?.isDirectory() || realpathSync(realPath) !== realPath)
      throw failure('发布目录不是已验证的真实版本目录');
    return { name, realPath };
  });
}

// Successful link layouts existed only off-device. Do not destroy one while
// pretending its old dependency graph can be loaded by the linkless resolver.
function refuseLegacyLinks(dir, root) {
  const modules = join(dir, 'node_modules');
  if (!stat(modules)) return;
  linkPath(dir, 'probe');
  const names = [];
  for (const entry of readdirSync(modules, { withFileTypes: true })) {
    if (entry.isSymbolicLink()) names.push(entry.name);
    else if (entry.isDirectory() && entry.name.startsWith('@'))
      for (const child of readdirSync(join(modules, entry.name), { withFileTypes: true }))
        if (child.isSymbolicLink()) names.push(`${entry.name}/${child.name}`);
  }
  for (const name of names) {
    const path = linkPath(dir, name), absolute = resolve(dirname(path), readlinkSync(path));
    if (absolute.startsWith(join(root, 'generations') + sep))
      throw failure('发现旧模拟器的链接布局；已保留现场，请重新安装该插件');
  }
}

function validateJournal(record) {
  if (![1, 2].includes(record.schema) || !['pending', 'committed'].includes(record.phase)
    || !Array.isArray(record.files) || !Array.isArray(record.links) || !Array.isArray(record.created)
    || record.files.length !== files.length || new Set(record.files.map(item => item.name)).size !== files.length
    || record.files.some(item => !files.includes(item.name) || item.bytes !== null && typeof item.bytes !== 'string')
    || record.links.some(item => !packageName.test(item.name) || ![item.before, item.after].every(value => value === null || typeof value === 'string'))
    || record.created.some(name => !generationName.test(name))
    || record.schema === 2 && record.packages !== null && typeof record.packages !== 'string'
    || record.rollbackId !== undefined && (record.schema !== 2 || typeof record.rollbackId !== 'string' || !rollbackId.test(record.rollbackId)))
    throw failure('插件事务记录无效，保留现场并停止加载');
}

function restore(dir, root, record) {
  if (record.schema === 1 && record.links.some(item => item.before !== null))
    throw failure('旧链接事务有已安装版本；已保留现场，请恢复旧环境后重新安装');
  if (record.links.length || record.created.length) directory(root, 'generations');
  if (record.schema === 1) {
    const packages = readPackages(dir, root), links = [];
    for (const item of record.links) {
      const path = linkPath(dir, item.name), current = currentLink(dir, path);
      if (current !== null && current !== item.before && current !== item.after) throw failure('插件链接已由其他操作改变，不能覆盖');
      delete packages[item.name];
      if (current !== null) links.push(path);
    }
    if (record.links.length) writePackages(root, packages);
    for (const path of links) removeFile(path);
  } else {
    const before = parsePackages(dir, record.packages === null ? null : Buffer.from(record.packages, 'base64'));
    const current = readPackages(dir, root);
    for (const name of new Set([...Object.keys(before), ...Object.keys(current), ...record.links.map(item => item.name)])) {
      const change = record.links.find(item => item.name === name);
      if ((current[name] ?? null) !== (before[name] ?? null) && (!change || (current[name] ?? null) !== change.after))
        throw failure('插件版本清单已由其他操作改变，不能覆盖');
    }
    restoreFile(join(root, 'active.json'), record.packages, root, record, 'active.json');
  }
  const selected = new Set(Object.values(readPackages(dir, root)).map(target => target.split('/')[0]));
  if (record.created.some(name => selected.has(name))) throw failure('本次版本仍被选择引用，保留现场');
  for (const name of record.created) {
    const path = join(root, 'generations', name);
    if (stat(path)?.isSymbolicLink()) throw failure('本次版本目录被链接替换，保留现场');
    rmSync(path, { recursive: true, force: true });
  }
  if (existsSync(join(root, 'generations'))) syncDirectory(join(root, 'generations'));
  for (const item of record.files) restoreFile(join(dir, item.name), item.bytes, root, record, item.name);
}

// Called before profile configuration is read. A live operation may itself cause
// resolution reads; those reads must not undo that operation's journal.
export function recoverProfile(dir) {
  if (!existsSync(dir)) return;
  dir = realpathSync(dir);
  profileDirectories.add(dir);
  if (active.has(dir)) return;
  const root = storeRoot(dir);
  if (!root) return;
  const path = join(root, 'transaction.json');
  const bytes = regularBytes(path);
  if (bytes !== null) {
    const record = JSON.parse(bytes);
    validateJournal(record);
    if (record.schema === 1 && record.phase === 'committed') refuseLegacyLinks(dir, root);
    if (record.phase === 'pending') restore(dir, root, record);
    cleanupRollback(root, record);
    removeFile(path);
  }
  refuseLegacyLinks(dir, root);
}

export function transactionFor(dir) {
  const transaction = active.get(realpathSync(dir));
  if (!transaction) throw failure('插件操作缺少 profile 写事务');
  return transaction;
}

// The manager holds its existing package.json write lock for this entire lifetime.
export function beginTransaction(dir) {
  if (!isAbsolute(dir)) throw failure('profile 路径必须为绝对路径');
  dir = realpathSync(dir);
  if (active.has(dir)) throw failure('profile 已有未结束的插件操作');
  recoverProfile(dir);
  const root = storeRoot(dir, true);
  const path = join(root, 'transaction.json');
  const record = {
    schema: 2, phase: 'pending',
    files: files.map(name => ({ name, bytes: regularBytes(join(dir, name))?.toString('base64') ?? null })),
    packages: regularBytes(join(root, 'active.json'))?.toString('base64') ?? null,
    links: [], created: [], rollbackId: randomUUID().replaceAll('-', ''),
  };
  const save = () => writeAtomic(path, `${JSON.stringify(record)}\n`);
  save();
  prepareRollback(root, record);
  const transaction = {
    newGeneration() {
      const parent = directory(root, 'generations');
      const name = `generation-${randomUUID().replaceAll('-', '')}`;
      const destination = join(parent, name);
      record.created.push(name); save();
      mkdirSync(destination, { mode: 0o700 }); syncDirectory(parent);
      return destination;
    },
    publish(name, destination) {
      if (record.links.some(item => item.name === name)) throw failure('同一次安装尝试不能重复发布同名插件');
      const targetPath = linkPath(dir, name);
      if (stat(targetPath)) throw failure('已有插件目录不属于鸿蒙安装器，不能覆盖或删除');
      const packages = readPackages(dir, root);
      const target = destination === null ? null : relative(join(root, 'generations'), destination);
      if (target !== null) {
        const absolute = packageTarget(dir, target);
        if (realpathSync(absolute) !== absolute || !stat(absolute)?.isDirectory()) throw failure('发布目录不是已验证的真实版本目录');
      }
      const item = { name, before: packages[name] ?? null, after: target };
      record.links.push(item);
      save();
      if (target === null) delete packages[name];
      else Object.defineProperty(packages, name, { value: target, enumerable: true, configurable: true });
      writePackages(root, packages);
    },
    writeManifest(manifest) { writeAtomic(join(dir, 'package.json'), `${JSON.stringify(manifest, null, 2)}\n`); },
    rollbackAttempt() {
      restore(dir, root, record);
      record.links = []; record.created = []; save();
      // A registry retry uses this same transaction; rename may have consumed
      // active/profile beforeimages during the previous failed attempt.
      prepareRollback(root, record);
    },
    finish(success) {
      try {
        if (success) {
          for (const name of files) {
            const file = join(dir, name);
            if (regularBytes(file) === null) continue;
            const fd = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW);
            try { fsyncSync(fd); } finally { closeSync(fd); }
          }
          syncDirectory(dir);
          record.phase = 'committed'; save();
          // The commit is durable. Cleanup failure must not make the manager
          // report a failed install and reconcile the previous live profile.
          try { cleanupRollback(root, record); removeFile(path); }
          catch { return { committed: true, cleanupPending: true }; }
          return { committed: true, cleanupPending: false };
        }
        restore(dir, root, record);
        cleanupRollback(root, record);
        removeFile(path);
        return { committed: false, cleanupPending: false };
      } finally {
        // A failed terminal write leaves the journal for the next owner to recover.
        active.delete(dir);
      }
    },
  };
  active.set(dir, transaction);
  return transaction;
}
