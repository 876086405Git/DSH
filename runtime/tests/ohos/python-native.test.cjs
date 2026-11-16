const assert = require('node:assert/strict');
const { test } = require('node:test');
const path = require('node:path');
const binding = require(path.resolve(process.env.OHOS_PYTHON_PROBE));
test('real host libpython executes, separates output and preserves exit codes', () => {
  const run = source => JSON.parse(binding.run(source, 1000));
  assert.deepEqual(run("import sys; print('真实Python'); print('err', file=sys.stderr); sys.exit(7)"),
    { stdout: '真实Python\n', stderr: 'err\n', exitCode: 7 });
  assert.deepEqual(run('print(1+2)'), { stdout: '3\n', stderr: '', exitCode: 0 });
  const error = run("raise ValueError('distinct')"); assert.equal(error.exitCode, 1); assert.match(error.stderr, /ValueError: distinct/);
});
test('cooperative Python bytecode timeout does not exit the Node process', () => {
  const result = JSON.parse(binding.run('while True: pass', 20));
  assert.equal(result.exitCode, 130);
  assert.equal(JSON.parse(binding.run('print(4)', 1000)).stdout, '4\n');
});
