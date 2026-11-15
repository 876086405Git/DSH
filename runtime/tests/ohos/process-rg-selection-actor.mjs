import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const request = JSON.parse(await readFile(process.argv[2], 'utf8'));
assert.equal(process.versions.node, '24.22.1');
assert(['jit', 'strict'].includes(request.mode));
if (request.mode === 'strict') {
  assert(process.execArgv.includes('--jitless'));
  assert.equal(process.platform, 'openharmony');
  assert.equal(typeof WebAssembly, 'undefined');
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
}
const { executeRg } = await import(pathToFileURL(request.module));
const { createFilesystem } = await import(pathToFileURL(request.filesystem));
const { Bash, defineCommand } = await import(pathToFileURL(request.bashModule));
if (request.uid !== undefined) {
  process.setgroups([]);
  process.setgid(request.uid);
  process.setuid(request.uid);
}
const rows = [];
for (const test of request.cases) {
  const filesystem = createFilesystem([test.cwd], { mode: 'read-only' });
  const trace = [];
  let tracing = false;
  const observed = new Proxy(filesystem.fs, {
    get(target, key) {
      const method = target[key];
      if (typeof method !== 'function') return method;
      return (...args) => {
        if (tracing && key !== 'resolvePath' && key !== 'getAllPaths') {
          trace.push({ operation: String(key), path: args[0] });
        }
        return method(...args);
      };
    },
  });
  const limits = { maxGlobOperations: 1000000, maxArrayElements: 1000000,
    maxOutputSize: 64 * 1024 * 1024, ...test.limits };
  let result;
  if (test.entry === 'bash') {
    const bash = new Bash({ fs: observed, cwd: test.cwd, commands: ['rg'],
      customCommands: [defineCommand('rg', executeRg)],
      executionLimits: limits, python: false, javascript: false, defenseInDepth: false });
    filesystem.seal();
    tracing = true;
    result = await bash.exec('rg', { args: test.args, cwd: test.cwd, rawScript: true });
  } else {
    filesystem.seal();
    tracing = true;
    result = await executeRg(test.args, { cwd: test.cwd, fs: observed, limits,
      origCommand() { throw new Error('Unexpected non-JSON branch'); } });
  }
  const stdout = result.stdoutKind === 'bytes' || result.stdoutEncoding === 'binary'
    ? Buffer.from(result.stdout, 'latin1').toString('utf8') : result.stdout;
  const records = stdout.split('\n').filter(Boolean).map(line => JSON.parse(line));
  rows.push({ name: test.name, args: test.args, entry: test.entry ?? 'direct',
    limits, exitCode: result.exitCode, stdout, stderr: result.stderr, records, trace });
}
console.log(JSON.stringify({ node: process.versions.node, platform: process.platform,
  wasm: typeof WebAssembly, marker: globalThis[Symbol.for('dsh.go.ohos.sim')],
  uid: process.getuid(), rows }, null, 2));
