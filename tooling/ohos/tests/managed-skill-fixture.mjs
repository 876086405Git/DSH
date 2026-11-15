// Actual Linux filesystem implementation of the public OH calls used by the
// production skill adapter. Explicit hooks inject cancellation and IO failures.
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { promisify } from 'node:util';
export { util } from './runtime-storage-fixture.mjs';

export const managedSkillIo = {
  calls: [], opened: new Map(), before: null, after: null, maxRead: Infinity, maxWrite: Infinity,
  reset() {
    if (this.opened.size !== 0) throw new Error('Previous managed skill probe leaked a descriptor');
    this.calls.length = 0; this.before = null; this.after = null; this.maxRead = Infinity; this.maxWrite = Infinity;
  },
};
async function call(operation, args, action) {
  const item = { operation, ...args };
  managedSkillIo.calls.push(item);
  if (managedSkillIo.before) await managedSkillIo.before(item);
  try {
    const result = await action();
    if (managedSkillIo.after) await managedSkillIo.after(item);
    return result;
  } catch (error) {
    const codes = { ENOENT:13900002, ENOTDIR:13900018, EEXIST:13900015, ELOOP:13900033 };
    if (Object.hasOwn(codes, error.code)) error.code = codes[error.code];
    throw error;
  }
}
const fd = file => typeof file === 'number' ? file : file.fd;
export const fileIo = {
  OpenMode: {
    CREATE:fs.constants.O_CREAT, READ_WRITE:fs.constants.O_RDWR, READ_ONLY:fs.constants.O_RDONLY,
    TRUNC:fs.constants.O_TRUNC, NOFOLLOW:fs.constants.O_NOFOLLOW,
    NONBLOCK:fs.constants.O_NONBLOCK, DIR:fs.constants.O_DIRECTORY,
  },
  lstat(path) { return call('lstat', { path }, () => fsp.lstat(path)); },
  stat(file) { return call('stat', { fd:typeof file === 'number' ? file : undefined }, () =>
    typeof file === 'number' ? promisify(fs.fstat)(file) : fsp.stat(file)); },
  mkdir(path) { return call('mkdir', { path }, () => fsp.mkdir(path)); },
  rename(from, to) { return call('rename', { from, to }, () => fsp.rename(from, to)); },
  unlink(path) { return call('unlink', { path }, () => fsp.unlink(path)); },
  async open(path, flags) {
    return call('open', { path, flags }, async () => {
      const handle = await fsp.open(path, flags, 0o600);
      managedSkillIo.opened.set(handle.fd, path);
      return { fd:handle.fd, handle, get path() { return fs.realpathSync(path); } };
    });
  },
  close(file) { return call('close', { fd:fd(file) }, async () => {
    if (typeof file === 'number') await promisify(fs.close)(file); else await file.handle.close();
    managedSkillIo.opened.delete(fd(file));
  }); },
  fsync(descriptor) { return call('fsync', { fd:descriptor, path:managedSkillIo.opened.get(descriptor) }, () => promisify(fs.fsync)(descriptor)); },
  read(descriptor, buffer, options) { return call('read', { fd:descriptor, length:options.length, offset:options.offset }, async () =>
    (await promisify(fs.read)(descriptor, Buffer.from(buffer), 0, Math.min(options.length, managedSkillIo.maxRead), options.offset)).bytesRead); },
  write(descriptor, buffer, options) { return call('write', { fd:descriptor, length:buffer.byteLength, offset:options.offset }, async () =>
    (await promisify(fs.write)(descriptor, Buffer.from(buffer), 0, Math.min(buffer.byteLength, managedSkillIo.maxWrite), options.offset)).bytesWritten); },
};
