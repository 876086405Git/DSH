// Test assets only: the five real tools use the same deterministic local model.
import { writeFile, mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { startFakeModel } from './model.mjs';

export async function startScenarios(workspace) {
  await mkdir(join(workspace, 'git 项目'));
  await writeFile(join(workspace, 'git 项目/中文 文件.txt'), 'needle-中文\n');
  await writeFile(join(workspace, '相对依赖.mjs'), 'export default "relative-module-ok";\n');
  await writeFile(join(workspace, 'Worker 脚本.mjs'), `
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { isMainThread } from 'node:worker_threads';
import dependency from './相对依赖.mjs';
const mode = readFileSync('scenario-mode.txt', 'utf8');
assert.equal(isMainThread, false);
assert.equal(process.cwd(), ${JSON.stringify(workspace)});
assert.equal(import.meta.main, true);
assert.equal(process.platform, 'openharmony');
assert.equal(typeof WebAssembly, 'undefined');
assert(process.execArgv.includes('--jitless'));
assert.deepEqual(process.argv.slice(2), ['中文 参数']);
assert.equal(dependency, 'relative-module-ok');
assert.equal(readFileSync('中文 测试.txt', 'utf8'), '修改后内容\\n');
if (mode === 'normal') {
  const bytes = 2 * 1024 * 1024;
  process.stdout.write('x'.repeat(bytes));
  process.stdout.write('\\nlarge-output-tail-中文\\n');
  writeFileSync('worker-observation.json', JSON.stringify({ mode, bytes, isMainThread, platform: process.platform,
    wasm: typeof WebAssembly, jitless: process.execArgv.includes('--jitless'), cwd: process.cwd() }));
} else {
  assert(['cancel', 'stop'].includes(mode));
  writeFileSync('started-' + mode, 'worker-started');
  setInterval(() => appendFileSync('heartbeat-' + mode, 'x'), 20);
}
`);
  const command = "node 'Worker 脚本.mjs' '中文 参数' && git init 'git 项目' && " +
    "git -C 'git 项目' add '中文 文件.txt' && git -C 'git 项目' status --porcelain > 'git-status.txt' && " +
    "rg --fixed-strings 'needle-中文' 'git 项目/中文 文件.txt' > 'rg-result.txt' && printf 'shell-ok\\n'";
  return startFakeModel(workspace, { bashCommand: command });
}
