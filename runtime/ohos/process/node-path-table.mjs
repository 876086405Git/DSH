// Fixed public Node 24.22.1 surface. Never infer path arguments from names at
// runtime: an added/removed export requires an explicit compatibility review.
export const pathOperations = Object.freeze({
  access: { paths: [0] }, appendFile: { paths: [0], fd: true, write: true },
  chmod: { paths: [0], write: true }, chown: { paths: [0], write: true },
  copyFile: { paths: [0, 1], write: true }, cp: { paths: [0, 1], write: true },
  exists: { paths: [0] }, lchmod: { paths: [0], write: true, noFollow: true },
  lchown: { paths: [0], write: true, noFollow: true }, link: { paths: [0, 1], write: true },
  lstat: { paths: [0], noFollow: true, ancestor: true }, lutimes: { paths: [0], write: true, noFollow: true },
  mkdir: { paths: [0], write: true }, mkdtemp: { paths: [0], write: true, prefix: true },
  mkdtempDisposable: { paths: [0], write: true, prefix: true },
  open: { paths: [0], open: true }, openAsBlob: { paths: [0] }, opendir: { paths: [0] },
  readdir: { paths: [0] }, readFile: { paths: [0], fd: true },
  readlink: { paths: [0], noFollow: true }, realpath: { paths: [0] },
  rename: { paths: [0, 1], write: true, noFollow: true },
  rm: { paths: [0], write: true, noFollow: true }, rmdir: { paths: [0], write: true, noFollow: true },
  stat: { paths: [0], ancestor: true }, statfs: { paths: [0] },
  symlink: { paths: [1], write: true, noFollow: true, symlink: true },
  truncate: { paths: [0], fd: true, write: true }, unlink: { paths: [0], write: true, noFollow: true },
  unwatchFile: { paths: [0] }, utimes: { paths: [0], write: true },
  watch: { paths: [0] }, watchFile: { paths: [0] }, writeFile: { paths: [0], fd: true, write: true },
  glob: { glob: true },
  createReadStream: { paths: [0], stream: true },
  createWriteStream: { paths: [0], stream: true, write: true },
  ReadStream: { paths: [0], stream: true }, FileReadStream: { paths: [0], stream: true },
  WriteStream: { paths: [0], stream: true, write: true },
  FileWriteStream: { paths: [0], stream: true, write: true },
  Utf8Stream: { utf8Stream: true, write: true },
});

const callback = ['access', 'appendFile', 'chmod', 'chown', 'copyFile', 'cp', 'exists',
  'glob', 'lchmod', 'lchown', 'link', 'lstat', 'lutimes', 'mkdir', 'mkdtemp', 'open',
  'opendir', 'readdir', 'readFile', 'readlink', 'realpath', 'rename', 'rm', 'rmdir',
  'stat', 'statfs', 'symlink', 'truncate', 'unlink', 'utimes', 'writeFile'];
const synchronous = ['access', 'appendFile', 'chmod', 'chown', 'copyFile', 'cp', 'exists',
  'glob', 'lchmod', 'lchown', 'link', 'lstat', 'lutimes', 'mkdir', 'mkdtemp', 'mkdtempDisposable',
  'open', 'opendir', 'readdir', 'readFile', 'readlink', 'realpath', 'rename', 'rm', 'rmdir',
  'stat', 'statfs', 'symlink', 'truncate', 'unlink', 'utimes', 'writeFile'];
const immediate = ['createReadStream', 'createWriteStream', 'ReadStream', 'WriteStream',
  'FileReadStream', 'FileWriteStream', 'Utf8Stream', 'unwatchFile', 'watch', 'watchFile'];
export const fsPathTable = Object.freeze(Object.fromEntries([
  ...callback.map(name => [name, { operation: name, completion: 'callback' }]),
  ...synchronous.map(name => [name + 'Sync', { operation: name, completion: 'sync' }]),
  ...immediate.map(name => [name, { operation: name, completion: 'sync' }]),
  ['openAsBlob', { operation: 'openAsBlob', completion: 'promise' }],
]));
export const promisesPathTable = Object.freeze(Object.fromEntries([
  'access', 'appendFile', 'chmod', 'chown', 'copyFile', 'cp', 'glob', 'lchmod', 'lchown',
  'link', 'lstat', 'lutimes', 'mkdir', 'mkdtemp', 'mkdtempDisposable', 'open', 'opendir',
  'readFile', 'readdir', 'readlink', 'realpath', 'rename', 'rm', 'rmdir', 'stat', 'statfs',
  'symlink', 'truncate', 'unlink', 'utimes', 'watch', 'writeFile',
].map(name => [name, { operation: name, completion: ['glob', 'watch'].includes(name) ? 'iterator' : 'promise' }])));
export const fdOperations = Object.freeze({
  close: false, closeSync: false, fchmod: true, fchmodSync: true,
  fchown: true, fchownSync: true, fdatasync: true, fdatasyncSync: true,
  fstat: false, fstatSync: false, fsync: true, fsyncSync: true,
  ftruncate: true, ftruncateSync: true, futimes: true, futimesSync: true,
  read: false, readSync: false, readv: false, readvSync: false,
  write: true, writeSync: true, writev: true, writevSync: true,
});
const fsValues = ['Dir', 'Dirent', 'Stats', '_toUnixTimestamp', 'F_OK', 'R_OK', 'W_OK', 'X_OK', 'constants', 'promises'];
export const nestedPathTable = Object.freeze(['realpath.native', 'realpathSync.native', 'Utf8Stream.prototype.reopen']);

export function assertNodeFsInventory(fs, promises) {
  const check = (actual, expected, label) => {
    const added = actual.filter(name => !expected.includes(name));
    const missing = expected.filter(name => !actual.includes(name));
    if (added.length || missing.length) throw Object.assign(new Error(
      `${label} exports changed; review the fixed Node path table (added=${added.join(',')}; missing=${missing.join(',')})`),
      { code: 'ERR_OHOS_NODE_FS_SURFACE_CHANGED' });
  };
  check(Object.getOwnPropertyNames(fs), [...Object.keys(fsPathTable), ...Object.keys(fdOperations), ...fsValues], 'fs');
  check(Object.getOwnPropertyNames(promises), [...Object.keys(promisesPathTable), 'constants'], 'fs/promises');
  if (typeof fs.realpath.native !== 'function' || typeof fs.realpathSync.native !== 'function'
      || typeof fs.Utf8Stream.prototype.reopen !== 'function') {
    throw Object.assign(new Error('Nested Node path entry changed'), { code: 'ERR_OHOS_NODE_FS_SURFACE_CHANGED' });
  }
}
