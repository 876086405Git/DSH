// The normal real DSH five-tool/two-approval round, with its bash step executing
// the actual Node backend. The model peer remains deterministic test input.
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { startFakeModel as standardModel } from '../../ohos/sim/fake-model.mjs';

export async function startFakeModel(workspace) {
  await writeFile(join(workspace, '相对依赖.mjs'), 'export default "relative-module-ok";');
  await writeFile(join(workspace, 'Worker 脚本.mjs'), `
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import value from './相对依赖.mjs';
assert.equal(process.cwd(), ${JSON.stringify(workspace)});
assert.equal(import.meta.main, true);
assert.equal(value, 'relative-module-ok');
assert.equal(readFileSync('中文 测试.txt', 'utf8'), '修改后内容\\n');
assert.deepEqual(process.argv.slice(2), ['中文 参数']);
assert.equal(process.env.NODE_ROUND_VALUE, '环境值');
assert.equal(typeof WebAssembly, 'undefined');
assert(process.execArgv.includes('--jitless'));
assert.throws(() => spawn('must-not-execute'), { code: 'ERR_OHOS_CHILD_PROCESS_UNAVAILABLE' });
writeFileSync('node-observation.json', JSON.stringify({ cwd: process.cwd(), argv: process.argv.slice(2),
  value, main: import.meta.main, jitless: process.execArgv.includes('--jitless'), wasm: typeof WebAssembly,
  nodeVersion: process.versions.node, platform: process.platform, environment: process.env.NODE_ROUND_VALUE }) + '\\n');
process.stdout.write('shell-ok\\n');
`);
  return standardModel(workspace, { bashCommand: "NODE_ROUND_VALUE='环境值' node 'Worker 脚本.mjs' '中文 参数'" });
}
