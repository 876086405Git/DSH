// Deterministic input peer only. The DSH engine, interpreter, Node Worker,
// native fixtures and filesystem operations remain the real implementations.
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { startFakeModel as standardModel } from '../../ohos/sim/fake-model.mjs';

export async function startFakeModel(workspace) {
  // Create raw inputs during the bash tool, after the earlier text-grep tool.
  // A non-UTF-8 file without NUL is outside the OH JSON-text search contract;
  // the output test must not change or bypass that existing refusal.
  await writeFile(join(workspace, 'init.cjs'), `
const { writeFileSync } = require('node:fs');
writeFileSync('stdout.bytes', Buffer.from([0x41, 0x42, 0, 0xc3, 0xa9, 0x80, 0x43, 0x44, 0x45]));
writeFileSync('stderr.bytes', Buffer.from([0x31, 0xff, 0x32]));
`);
  await writeFile(join(workspace, 'emit.cjs'), `
const { readFileSync } = require('node:fs');
process.stdout.write(readFileSync('stdout.bytes'));
process.stderr.write(readFileSync('stderr.bytes'));
`);
  await writeFile(join(workspace, '核对独立打开.cjs'), `
const assert = require('node:assert/strict');
const { readFileSync, writeFileSync } = require('node:fs');
assert.equal(process.cwd(), ${JSON.stringify(workspace)});
assert.equal(process.platform, 'openharmony');
assert.equal(typeof WebAssembly, 'undefined');
assert(process.execArgv.includes('--jitless'));
const actual = {};
for (const name of ['scoped.bin', 'append.bin', 'return.bin', 'node.bin']) {
  actual[name] = readFileSync(name).toString('hex');
  assert.equal(actual[name], '31ff32c3a980434445');
}
actual['dup.bin'] = readFileSync('dup.bin').toString('hex');
assert.equal(actual['dup.bin'], '414200c3a98043444531ff32');
for (const [name, expected] of Object.entries({
  'body-truncate.bin': '31ff32',
  'body-cursor.bin': '00000000000000000031ff32',
  'capture.bin': '3c6361756768743e',
  'input-capture.bin': '3c41423e',
})) {
  actual[name] = readFileSync(name).toString('hex');
  assert.equal(actual[name], expected, name);
}
assert.equal(readFileSync('中文 测试.txt', 'utf8'), '修改后内容\\n');
writeFileSync('independent-open-observation.json', JSON.stringify(actual) + '\\n');
process.stdout.write('shell-ok\\n');
`);
  const emit = 'cat stdout.bytes; cat stderr.bytes >&2';
  const bashCommand = [
    'node init.cjs',
    `{ ${emit}; } > scoped.bin 2> scoped.bin`,
    'printf old-prefix > append.bin',
    `{ ${emit}; } >> append.bin 2> append.bin`,
    `f(){ ${emit}; return 7; }`,
    'f > return.bin 2> return.bin; code=$?; [ "$code" = 7 ] || exit 1',
    'node emit.cjs > node.bin 2> node.bin',
    `{ ${emit}; } 2> dup.bin 1>&2`,
    '{ cat stdout.bytes; : > body-truncate.bin; cat stderr.bytes >&2; } > body-truncate.bin 2> body-truncate.bin',
    '{ cat stdout.bytes; : > body-cursor.bin; cat stderr.bytes; } > body-cursor.bin',
    '{ value=$(printf caught); printf "<%s>" "$value"; } > capture.bin',
    '{ read -r value < <(printf "AB\\n"); printf "<%s>" "$value"; } > input-capture.bin',
    "node '核对独立打开.cjs'",
  ].join('; ');
  return standardModel(workspace, { bashCommand });
}
