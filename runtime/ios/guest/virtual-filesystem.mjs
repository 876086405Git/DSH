import { dirname, resolve, sep } from 'node:path';
import { MountableFs, ReadWriteFs } from '../../ohos/process/build/just-bash/index.js';

export const isInside = (root, path) => path === root || path.startsWith(root + sep);
export const distinctRoots = roots => [...new Set(roots)].filter(root => !roots.some(other => other !== root && isInside(other, root)));

export function createFilesystem(roots, policy, aliases = []) {
  let ready = false;
  const filesystem = new MountableFs({
    mounts: [...roots.map(root => ({ mountPoint: root, root })), ...aliases].map(({ mountPoint, root }) => ({
      mountPoint,
      filesystem: new ReadWriteFs({
        root,
        allowSymlinks: true,
        maxFileReadSize: 64 * 1024 * 1024,
        maxCopySize: 64 * 1024 * 1024,
      }),
    })),
  });
  const permittedRoots = aliases.length ? [...roots, ...aliases.map(row => row.mountPoint)] : roots;
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
        const ancestor = roots.some(root => isInside(path, root)) || path === '/';
        const virtual = readOnly.has(key) && virtualRoots.some(root => isInside(root, path));
        if (key === 'exists' && !permitted(path) && !ancestor && !virtual) return Promise.resolve(false);
        if (!(metadata.has(key) && ancestor) && !virtual) requirePath(path);
        if (key === 'cp' || key === 'mv' || key === 'link') requirePath(args[1]);
        return method.apply(target, args);
      };
    },
  });
  return { fs, seal: () => { ready = true; } };
}
