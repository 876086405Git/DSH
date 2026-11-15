import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';
import { Bash, defineCommand } from '../../ohos/process/build/just-bash/index.js';
import { createFilesystem } from '../../ohos/process/filesystem.mjs';
import { nodeCommand } from '../../ohos/process/node-command.mjs';

const bytes = Buffer.from([0, 255, 0xc3, 0xa9, 10, 0x80, 0xe4, 0xb8, 0xad]);
const cases = [
  ['plain', 'node bytes.mjs', 'stderr'],
  ['redirect', 'node bytes.mjs 2> error.bin', 'file'],
  ['append', 'node bytes.mjs 2>> error.bin; node bytes.mjs 2>> error.bin', 'file', 2],
  ['merge', 'node bytes.mjs 2>&1', 'stdout'],
  ['merged pipe', 'node bytes.mjs 2>&1 | cat', 'stdout'],
  ['pipe stderr', 'node bytes.mjs |& cat', 'stdout'],
  ['pipeline stderr side', 'node bytes.mjs | cat', 'stderr'],
  ['shared file', 'node bytes.mjs &> error.bin', 'file'],
  ['descriptor', 'exec 3> error.bin; node bytes.mjs 2>&3; exec 3>&-', 'file'],
  ['group', '{ node bytes.mjs; }', 'stderr'],
  ['subshell', '(node bytes.mjs)', 'stderr'],
  ['function', 'f() { node bytes.mjs; }; f', 'stderr'],
  ['for loop', 'for value in first second; do node bytes.mjs; done', 'stderr', 2],
  ['if clause', 'if true; then node bytes.mjs; fi', 'stderr'],
  ['substitution stderr', 'value=$(node bytes.mjs); printf "%s" "$value"', 'stderr'],
  ['nested shell', "bash -c 'node bytes.mjs'", 'stderr'],
  ['eval', "eval 'node bytes.mjs'", 'stderr'],
  ['source', 'source sourced.sh', 'stderr'],
  ['errexit', 'set -e; node bytes.mjs failure; echo unreachable', 'stderr', 1, 9],
  ['return', 'f() { node bytes.mjs; return 4; }; f', 'stderr', 1, 4],
  ['break', 'for value in first second; do node bytes.mjs; break; done', 'stderr'],
  ['continue', 'for value in first second; do node bytes.mjs; continue; done', 'stderr', 2],
];

for (const [name, command, channel, count = 1, exitCode = 0] of cases) {
  test(`Node binary stderr remains exact through ${name}`, { timeout: 15000 }, async t => {
    const root = await mkdtemp('/tmp/ohos-node-stderr-');
    const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [root] });
    t.after(async () => { await runtime.dispose(); await rm(root, { recursive: true, force: true }); });
    await writeFile(join(root, 'bytes.mjs'), `process.stderr.write(Buffer.from(${JSON.stringify([...bytes])}));if(process.argv[2])process.exitCode=9;`);
    await writeFile(join(root, 'sourced.sh'), 'node bytes.mjs\n');
    const handle = runtime.spawn({ argv: ['bash', '-c', command], cwd: root, graceMs: 200,
      stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
    const collect = async stream => { const chunks = []; for await (const chunk of stream) chunks.push(chunk); return Buffer.concat(chunks); };
    const [result, stdout, stderr] = await Promise.all([handle.done, collect(handle.stdout), collect(handle.stderr)]);
    assert.equal(await handle.waitForExit(), true);
    assert.equal(result.exitCode, exitCode);
    const actual = channel === 'file' ? await readFile(join(root, 'error.bin')) : channel === 'stdout' ? stdout : stderr;
    assert.deepEqual(actual, Buffer.concat(Array(count).fill(bytes)), `${name}: ${actual.toString('hex')}`);
    if (channel !== 'stdout') assert.equal(stdout.length, 0);
    if (channel !== 'stderr') assert.equal(stderr.length, 0);
  });
}

test('binary stderr and Unicode diagnostics coexist without double encoding', { timeout: 15000 }, async t => {
  const root = await mkdtemp('/tmp/ohos-node-stderr-mixed-');
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [root] });
  t.after(async () => { await runtime.dispose(); await rm(root, { recursive: true, force: true }); });
  await writeFile(join(root, 'bytes.mjs'), `process.stderr.write(Buffer.from(${JSON.stringify([...bytes])}));`);
  const handle = runtime.spawn({ argv: ['bash', '-c', "printf '前中文' >&2; node bytes.mjs; printf '后中文' >&2"], cwd: root, graceMs: 200,
    stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
  const chunks = []; handle.stdout.resume(); handle.stderr.on('data', chunk => chunks.push(chunk));
  assert.equal((await handle.done).exitCode, 0); assert.equal(await handle.waitForExit(), true);
  assert.deepEqual(Buffer.concat(chunks), Buffer.concat([Buffer.from('前中文'), bytes, Buffer.from('后中文')]));
});

const stdoutBytes = Buffer.from([0x80, 0, 0xe4, 0xb8, 0xad, 0xff]);
for (const [name, suffix, out, err, files] of [
  ['independent', '', stdoutBytes, bytes, {}],
  ['stderr to stdout', '2>&1', Buffer.concat([stdoutBytes, bytes]), Buffer.alloc(0), {}],
  ['stdout to stderr', '1>&2', Buffer.alloc(0), Buffer.concat([stdoutBytes, bytes]), {}],
  ['separate files', '> output.bin 2> error.bin', Buffer.alloc(0), Buffer.alloc(0), { 'output.bin': stdoutBytes, 'error.bin': bytes }],
  ['shared file', '> both.bin 2>&1', Buffer.alloc(0), Buffer.alloc(0), { 'both.bin': Buffer.concat([stdoutBytes, bytes]) }],
  ['duplicate before redirect', '2>&1 > output.bin', bytes, Buffer.alloc(0), { 'output.bin': stdoutBytes }],
  ['stdout to error file', '2> both.bin 1>&2', Buffer.alloc(0), Buffer.alloc(0), { 'both.bin': Buffer.concat([stdoutBytes, bytes]) }],
  ['duplicate stderr before redirect', '1>&2 2> error.bin', Buffer.alloc(0), stdoutBytes, { 'error.bin': bytes }],
  ['stdout to stderr before pipe', '1>&2 | cat', Buffer.alloc(0), Buffer.concat([stdoutBytes, bytes]), {}],
  ['stdout to stderr then file and pipe', '1>&2 2> error.bin | cat', Buffer.alloc(0), stdoutBytes, { 'error.bin': bytes }],
  ['both to original stderr before pipe', '1>&2 2>&1 | cat', Buffer.alloc(0), Buffer.concat([stdoutBytes, bytes]), {}],
]) {
  test(`raw stdout and stderr preserve both encodings through ${name}`, { timeout: 15000 }, async t => {
    const root = await mkdtemp('/tmp/ohos-node-both-');
    const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [root] });
    t.after(async () => { await runtime.dispose(); await rm(root, { recursive: true, force: true }); });
    await writeFile(join(root, 'both.mjs'), `process.stdout.write(Buffer.from(${JSON.stringify([...stdoutBytes])}),()=>process.stderr.write(Buffer.from(${JSON.stringify([...bytes])})));`);
    const handle = runtime.spawn({ argv: ['bash', '-c', `node both.mjs ${suffix}`], cwd: root, graceMs: 200,
      stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
    const collect = async stream => { const chunks = []; for await (const chunk of stream) chunks.push(chunk); return Buffer.concat(chunks); };
    const [result, actualOut, actualErr] = await Promise.all([handle.done, collect(handle.stdout), collect(handle.stderr)]);
    assert.equal(result.exitCode, 0); assert.equal(await handle.waitForExit(), true);
    assert.deepEqual(actualOut, out); assert.deepEqual(actualErr, err);
    for (const [file, expected] of Object.entries(files)) assert.deepEqual(await readFile(join(root, file)), expected);
  });
}

test('nested Node keeps a large binary stderr block and a later valid UTF-8 tail', { timeout: 15000 }, async t => {
  const root = await mkdtemp('/tmp/ohos-node-stderr-large-');
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [root] });
  t.after(async () => { await runtime.dispose(); await rm(root, { recursive: true, force: true }); });
  await writeFile(join(root, 'large.mjs'), "process.stderr.write(Buffer.alloc(2*1024*1024,255),()=>process.stderr.write('尾中文')); ");
  const handle = runtime.spawn({ argv: ['bash', '-c', 'node large.mjs'], cwd: root, graceMs: 200,
    stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
  const chunks = []; handle.stdout.resume(); handle.stderr.on('data', chunk => chunks.push(chunk));
  assert.equal((await handle.done).exitCode, 0); assert.equal(await handle.waitForExit(), true);
  assert.deepEqual(Buffer.concat(chunks), Buffer.concat([Buffer.alloc(2*1024*1024,255), Buffer.from('尾中文')]));
});

test('typed stderr output budgets count original bytes once across delivery, merge and file routing', { timeout: 20000 }, async t => {
  const root = await mkdtemp('/tmp/ohos-node-stderr-budget-');
  t.after(() => rm(root, { recursive: true, force: true }));
  await writeFile(join(root, 'bytes.mjs'), `process.stderr.write(Buffer.from(${JSON.stringify([...bytes])}));`);
  for (const suffix of ['', '2>&1', '2> error.bin']) for (const budget of [bytes.length * 2, bytes.length * 2 - 1]) {
    const filesystem = createFilesystem([root]);
    const bash = new Bash({ fs: filesystem.fs, cwd: root, defenseInDepth: false,
      commands: ['bash', 'sh', 'node'], python: false, javascript: false,
      customCommands: [defineCommand('node', nodeCommand({ roots: [root], workspaceRoots: [root] }))],
      executionLimits: { maxOutputSize: budget } });
    filesystem.seal();
    const result = await bash.exec('bash', { args: ['-c', `node bytes.mjs ${suffix}; node bytes.mjs ${suffix}`],
      ohosStatementOutput: async () => {} });
    assert.equal(result.exitCode, budget === bytes.length * 2 ? 0 : 126, JSON.stringify({ suffix, budget, result }));
    if (result.exitCode) assert.match(result.stderr, /output size exceeded/);
  }
});

const splitWrites = [[255], [228], [184, 173, 128], [195], [169, 0], [240], [159, 152], [128, 254]];
for (const [suffix, channel] of [['', 'stderr'], ['2>&1 | cat', 'stdout'], ['2> split.bin', 'file']]) {
  test(`separate writes preserve UTF-8 split next to invalid bytes through ${channel}`, { timeout: 15000 }, async t => {
    const root = await mkdtemp('/tmp/ohos-node-stderr-split-');
    const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [root] });
    t.after(async () => { await runtime.dispose(); await rm(root, { recursive: true, force: true }); });
    await writeFile(join(root, 'split.mjs'), `for(const chunk of ${JSON.stringify(splitWrites)}){await new Promise(resolve=>process.stderr.write(Buffer.from(chunk),resolve));await new Promise(resolve=>setTimeout(resolve,15));}`);
    const handle = runtime.spawn({ argv: ['bash', '-c', `node split.mjs ${suffix}`], cwd: root, graceMs: 200,
      stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
    const collect = async stream => { const chunks = []; for await (const chunk of stream) chunks.push(chunk); return Buffer.concat(chunks); };
    const [result, stdout, stderr] = await Promise.all([handle.done, collect(handle.stdout), collect(handle.stderr)]);
    assert.equal(result.exitCode, 0); assert.equal(await handle.waitForExit(), true);
    const actual = channel === 'file' ? await readFile(join(root, 'split.bin')) : channel === 'stdout' ? stdout : stderr;
    assert.deepEqual(actual, Buffer.from(splitWrites.flat()));
    if (channel !== 'stdout') assert.equal(stdout.length, 0);
    if (channel !== 'stderr') assert.equal(stderr.length, 0);
  });
}
