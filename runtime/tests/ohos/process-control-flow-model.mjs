// Keep the real DSH five-tool/two-approval round. Only its deterministic model
// peer's bash command changes; actual interpreter, Worker and files do the work.
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { startFakeModel as standardModel } from '../../ohos/sim/fake-model.mjs';

export async function startFakeModel(workspace) {
  await writeFile(join(workspace, '控制流.bytes'), Buffer.from([0, 255, 195, 169, 128, 10]));
  await writeFile(join(workspace, '核对输出.cjs'), `
const assert = require('node:assert/strict');
const { readFileSync, writeFileSync } = require('node:fs');
assert.equal(process.cwd(), ${JSON.stringify(workspace)});
assert.equal(process.platform, 'openharmony');
assert.equal(typeof WebAssembly, 'undefined');
assert(process.execArgv.includes('--jitless'));
const observations = {};
for (const name of ['return.bin', 'exit.bin', 'pipe.bin', 'loop.bin']) {
  observations[name] = readFileSync(name).toString('hex');
  assert.equal(observations[name], '00ffc3a9800a');
}
assert.equal(readFileSync('中文 测试.txt', 'utf8'), '修改后内容\\n');
writeFileSync('control-flow-observation.json', JSON.stringify(observations) + '\\n');
process.stdout.write('shell-ok\\n');
`);
  const bashCommand = [
    'f(){ cat 控制流.bytes; return 7; }',
    'f > return.bin; code=$?; [ "$code" = 7 ] || exit 1',
    "bash -c '{ cat 控制流.bytes; exit 7; }' > exit.bin; code=$?; [ \"$code\" = 7 ] || exit 1",
    'f | cat > pipe.bin',
    'for x in 1 2; do cat 控制流.bytes; break; done > loop.bin',
    "node '核对输出.cjs'",
  ].join('; ');
  return standardModel(workspace, { bashCommand });
}
