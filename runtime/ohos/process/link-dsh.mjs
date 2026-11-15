import { lstat, readFile, realpath, symlink } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const prefix = process.argv[2];
if (!prefix) throw new Error('用法：node link-dsh.mjs <已安装且版本锁定的 DSH prefix>');
const source = await realpath(join(resolve(prefix), 'node_modules/@deepseek-ai'));
for (const name of ['dsh-subprocess', 'dsh-subprocess-local', 'dsh-sandbox']) {
  const pkg = JSON.parse(await readFile(join(source, name, 'package.json'), 'utf8'));
  if (pkg.version !== '0.2.2-rc.1') throw new Error(`${name} 版本不符：${pkg.version}`);
}
const target = join(dirname(fileURLToPath(import.meta.url)), 'node_modules/@deepseek-ai');
const existing = await lstat(target).catch(error => {
  if (error.code !== 'ENOENT') throw error;
});
if (existing) {
  if (!existing.isSymbolicLink() || await realpath(target) !== source) throw new Error('目标已有不同的 DSH 依赖；不覆盖，请使用独立安装目录');
} else await symlink(source, target, 'dir');
console.log('O4 DSH 依赖版本与解析路径已核对');
