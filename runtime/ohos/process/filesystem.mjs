import { workerData } from 'node:worker_threads';
import { NativeGrantFs } from './files/grant-fs.mjs';
import { loadGrantBinding } from './files/authority.mjs';
import { dirname, resolve } from 'node:path';
import { isInside } from './paths.mjs';
export { isInside, distinctRoots } from './paths.mjs';
import { MountableFs, ReadWriteFs } from './build/just-bash/index.js';

export function createFilesystem(roots, policy, options = {}) {
  // Only the fixed internal shell Worker receives these single-use native tickets.
  // Strings naming grants cannot acquire anything in this consumer.
  const grants = options.grantMounts ?? workerData?.dshOhosWorkspaceGrants?.mounts ?? [];
  if (!Array.isArray(grants) || grants.length > 128) throw Object.assign(new Error('ERR_WORKSPACE_MOUNT'), { code: 'ERR_WORKSPACE_MOUNT' });
  const mounts = [], seen = new Set();
  let binding;
  try {
    if (grants.length) binding = options.binding ?? loadGrantBinding();
    for (const grant of grants) {
      if (!/^\/workspaces\/[0-9a-f-]{36}$/.test(grant.mountPoint) || seen.has(grant.mountPoint) ||
          !/^[0-9a-f]{64}$/.test(grant.ticket) || roots.some(root => isInside(root, grant.mountPoint) || isInside(grant.mountPoint, root))) {
        throw Object.assign(new Error('ERR_WORKSPACE_MOUNT'), { code: 'ERR_WORKSPACE_MOUNT' });
      }
      seen.add(grant.mountPoint);
      mounts.push({ mountPoint: grant.mountPoint, filesystem: new NativeGrantFs(binding, grant.ticket) });
    }
  } catch (error) { for (const mount of mounts) mount.filesystem.close(); throw error; }
  const permittedRoots = [...roots, ...seen];
  let ready = false;
  let filesystem;
  try { filesystem = new MountableFs({
    mounts: [...mounts, ...roots.map(root => ({
      mountPoint: root,
      filesystem: new ReadWriteFs({
        root,
        allowSymlinks: true,
        maxFileReadSize: 64 * 1024 * 1024,
        maxCopySize: 64 * 1024 * 1024,
      }),
    }))],
  }); } catch (error) { for (const mount of mounts) mount.filesystem.close(); throw error; }
  const permitted = path => permittedRoots.some(root => isInside(root, resolve(path)));
  const requirePath = path => {
    if (!permitted(path)) {
      throw Object.assign(new Error('EACCES: 路径不在工作区或本次运行的临时目录内'), { code: 'EACCES' });
    }
  };
  // 不把未挂载路径默默写进 MountableFs 的内存后端。
  const metadata = new Set(['stat', 'lstat', 'exists', 'readdir', 'readdirWithFileTypes', 'realpath']);
  const readOnly = new Set([...metadata, 'readFile', 'readFileBytes', 'readFileBuffer', 'readlink']);
  const virtualRoots = ['/bin', '/usr/bin', '/dev', '/proc'];
  const mutations = new Set(['writeFile', 'writeFileSync', 'appendFile', 'mkdir', 'mkdirSync', 'createExclusive', 'rm', 'cp', 'mv', 'chmod', 'symlink', 'link', 'utimes', 'writeFileLazy']);
  const fs = new Proxy(filesystem, {
    get(target, key) {
      const method = target[key];
      if (typeof method !== 'function') return method;
      if (key === 'resolvePath' || key === 'getAllPaths') return method.bind(target);
      return (...args) => {
        // Bash 构造器只在内存底层建立 /bin、/dev、/proc 的虚拟条目。
        if (!ready) return method.apply(target, args);
        if (policy?.mode === 'read-only' && mutations.has(key) && args[0] !== '/dev/null') {
          throw Object.assign(new Error('EACCES: OHOS_SANDBOX_DENIED: 当前调用是 read-only，不能修改文件'), { code: 'EACCES' });
        }
        if ((key === 'writeFile' || key === 'appendFile') && args[0] === '/dev/null') return Promise.resolve();
        if (key === 'symlink') {
          requirePath(args[1]);
          requirePath(resolve(dirname(args[1]), args[0]));
          return method.apply(target, args);
        }
        const path = resolve(args[0]);
        const ancestor = permittedRoots.some(root => isInside(path, root)) || path === '/';
        const virtual = readOnly.has(key) && virtualRoots.some(root => isInside(root, path));
        if (key === 'exists' && !permitted(path) && !ancestor && !virtual) return Promise.resolve(false);
        if (!(metadata.has(key) && ancestor) && !virtual) requirePath(path);
        if (key === 'cp' || key === 'mv' || key === 'link') {
          requirePath(args[1]);
          const sourceGrant = mounts.find(mount => isInside(mount.mountPoint, path));
          const targetGrant = mounts.find(mount => isInside(mount.mountPoint, resolve(args[1])));
          if (sourceGrant !== targetGrant && (sourceGrant || targetGrant)) throw Object.assign(new Error('EXDEV: workspace leases cannot be crossed'), { code: 'EXDEV' });
        }
        return method.apply(target, args);
      };
    },
  });
  return { fs, seal: () => { ready = true; }, close: () => { for (const mount of mounts) mount.filesystem.close(); } };
}
