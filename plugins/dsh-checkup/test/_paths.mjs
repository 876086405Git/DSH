// 可移植路径解析：测试里不再写死任何本机绝对路径。
// 全部从「当前文件位置 / 环境变量 / 平台默认位置」推导，换机器、换用户名都能跑。
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

// 包根目录（本文件在 test/ 下，上一级即包根）
export const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

// DSH 数据目录：优先 DSH_HOME，否则 ~/.dsh（与 lib/index.js 的 HOME 保持同一套规则）
export const DSH_HOME = process.env.DSH_HOME || join(homedir(), '.dsh');

// desktop profile 的落盘位置
export const DESKTOP_PROFILE_DIR = join(DSH_HOME, 'profiles', 'desktop');
export const DESKTOP_PROFILE_PATCH = join(DESKTOP_PROFILE_DIR, 'cordis.patch.yml');
export const DESKTOP_PROFILE_MODULES = join(DESKTOP_PROFILE_DIR, 'node_modules');

const require = createRequire(import.meta.url);

// 桌面端安装根（<AppRoot>/DeepSeek Harness/resources）
function resourcesDirs() {
  const dirs = [];
  const localAppData = process.env.LOCALAPPDATA;
  if (localAppData) dirs.push(join(localAppData, 'Programs', 'DeepSeek Harness', 'resources'));
  const programFiles = process.env.ProgramFiles;
  if (programFiles) dirs.push(join(programFiles, 'DeepSeek Harness', 'resources'));
  return dirs;
}

// yaml 依赖的候选目录（按可信度排序，第一个存在的胜出）
export function yamlCandidates() {
  const candidates = [];
  // 1) 本包自己装的依赖（npm/pnpm install 后的 node_modules/yaml）
  candidates.push(join(REPO_ROOT, 'node_modules', 'yaml'));
  // 2) 显式指定的宿主 app 目录
  if (process.env.DSH_APP_DIR) candidates.push(join(resolve(process.env.DSH_APP_DIR), 'node_modules', 'yaml'));
  // 3) 桌面端安装目录里的内置依赖
  for (const resources of resourcesDirs()) {
    candidates.push(join(resources, 'app', 'dsh', 'node_modules', 'yaml'));
    candidates.push(join(resources, 'app', 'node_modules', 'yaml'));
  }
  // 4) desktop profile 里已装的依赖（插件声明了 yaml，装进 profile 后必然有一份）
  candidates.push(join(DESKTOP_PROFILE_MODULES, 'yaml'));
  return candidates;
}

// 统一加载 yaml：本地依赖优先，找不到再逐个候选目录试
export function loadYaml() {
  try {
    return require('yaml');
  } catch {
    /* 本地没装依赖，继续找宿主侧的 */
  }
  for (const dir of yamlCandidates()) {
    if (!existsSync(join(dir, 'package.json'))) continue;
    return require(dir);
  }
  throw new Error(
    '找不到 yaml 依赖。先在本包目录执行 npm install，' +
      '或把环境变量 DSH_APP_DIR 指向桌面端 app/dsh 目录。已尝试：\n  ' +
      yamlCandidates().join('\n  '),
  );
}
