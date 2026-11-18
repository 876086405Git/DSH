import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Bash } from '../../ohos/process/build/just-bash/index.js';
import { createFilesystem } from '../../ohos/process/filesystem.mjs';
import { stderrLimitCases, stderrLimitFiles } from './process-stderr-limit-cases.mjs';

const mode = process.env.M4_DIAGNOSTICS_MODE;
assert(['jit', 'strict'].includes(mode), 'set M4_DIAGNOSTICS_MODE=jit or strict');
if (mode === 'strict') {
  assert.equal(process.version, 'v24.22.1');
  assert(process.execArgv.includes('--jitless'));
  assert.equal(process.platform, 'openharmony');
  assert.equal(typeof WebAssembly, 'undefined');
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
}
const bytes = (result, stream) => Buffer.from(result[stream], result[stream + 'Kind'] === 'bytes'
  || stream === 'stdout' && result.stdoutEncoding === 'binary' ? 'latin1' : 'utf8');
async function execute(t, expected, entry, budget, extraLimits = {}) {
  const cwd = await mkdtemp(join(tmpdir(), 'ohos-stderr-limit-'));
  t.after(() => rm(cwd, { recursive: true, force: true }));
  for (const [name, data] of Object.entries(stderrLimitFiles)) await writeFile(join(cwd, name), data);
  const fs = createFilesystem([cwd]);
  const bash = new Bash({ fs: fs.fs, cwd, defenseInDepth: false,
    commands: ['bash', 'sh', 'printf', 'cat'], python: false, javascript: false,
    executionLimits: { maxOutputSize: budget, ...extraLimits } });
  fs.seal();
  const delivered = [];
  const options = { cwd, rawScript: true, signal: t.signal };
  if (entry !== 'direct') options.args = ['-c', expected.command];
  if (entry === 'statement sink') options.ohosStatementOutput = result => { delivered.push(result); };
  const result = await bash.exec(entry === 'direct' ? expected.command : 'bash', options);
  const results = [...delivered, result];
  return { exitCode: result.exitCode,
    nonemptyDeliveries: delivered.filter(r => bytes(r, 'stdout').length || bytes(r, 'stderr').length).length,
    stdout: Buffer.concat(results.map(r => bytes(r, 'stdout'))),
    stderr: Buffer.concat(results.map(r => bytes(r, 'stderr'))) };
}
for (const expected of stderrLimitCases) for (const entry of ['direct', 'bash entry', 'statement sink']) {
  test(`${expected.name}: ${entry} preserves the accepted error prefix`, { timeout: 15000 }, async t => {
    const result = await execute(t, expected, entry, expected.budget);
    if (expected.requireEarlyDelivery && entry === 'statement sink') assert(result.nonemptyDeliveries > 0);
    assert.equal(result.exitCode, 126);
    assert.deepEqual(result.stdout, expected.stdout);
    assert.deepEqual(result.stderr.subarray(0, expected.prefix.length), expected.prefix);
    const diagnostic = result.stderr.subarray(expected.prefix.length);
    assert.deepEqual(diagnostic, Buffer.from(diagnostic.toString('ascii'), 'ascii'));
    if (entry === 'direct' && expected.directDiagnostic) assert.deepEqual(diagnostic, Buffer.from(expected.directDiagnostic));
    else assert.match(diagnostic.toString('ascii'), new RegExp(`^bash: [^\\n]*total output size exceeded \\(>${expected.budget} bytes\\), increase executionLimits\\.maxOutputSize\\n$`));
  });
  test(`${expected.name}: ${entry} accepts the exact complete budget`, { timeout: 15000 }, async t => {
    const result = await execute(t, expected, entry, expected.exactBudget);
    if (expected.requireEarlyDelivery && entry === 'statement sink') assert(result.nonemptyDeliveries > 0);
    assert.equal(result.exitCode, 0);
    assert.deepEqual(result.stdout, expected.stdout);
    assert.deepEqual(result.stderr, expected.completeStderr);
  });
}

for (const entry of ['direct', 'bash entry', 'statement sink']) {
  test(`iteration limit keeps the binary error prefix: ${entry}`, { timeout: 15000 }, async t => {
    const expected = { command: 'for x in 1 2; do cat e >&2; done' };
    const result = await execute(t, expected, entry, 1000, { maxLoopIterations: 1 });
    assert.equal(result.exitCode, 126);
    assert.equal(result.stdout.length, 0);
    const prefix = stderrLimitFiles.e;
    assert.deepEqual(result.stderr.subarray(0, prefix.length), prefix);
    const diagnostic = result.stderr.subarray(prefix.length);
    assert.deepEqual(diagnostic, Buffer.from(diagnostic.toString('ascii'), 'ascii'));
    // The pinned constructor uses the supplied stderr instead of a diagnostic.
    // Preserve that existing behavior while checking its exact accepted bytes.
    assert.equal(diagnostic.length, 0);
  });
}

for (const entry of ['direct', 'bash entry', 'statement sink']) {
  test(`outer source-size limit keeps its original text diagnostic: ${entry}`, { timeout: 15000 }, async t => {
    const result = await execute(t, { command: 'printf "你好"' }, entry, 1000, { maxSourceBytes: 1 });
    assert.equal(result.exitCode, 126);
    assert.equal(result.stdout.length, 0);
    assert.equal(result.nonemptyDeliveries, 0);
    assert.deepEqual(result.stderr, Buffer.from('bash: script input size limit exceeded (1 bytes)\n'));
  });
}
