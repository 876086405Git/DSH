import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import * as fs from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';

const shadow = resolve(process.env.M4_LICENSE_SHADOW);
const require = createRequire(join(shadow, 'process/package.json'));
const report = { stage: process.env.M4_PRUNE_STAGE, wasmUnavailable: globalThis.WebAssembly === undefined, execArgv: process.execArgv, node: process.version, resolution: {}, checks: [] };
for (const name of ['just-bash', 'isomorphic-git', 'typescript', 'sql.js']) {
  try { report.resolution[name] = require.resolve(name); }
  catch (error) { report.resolution[name] = { code: error.code }; }
}
assert.ok(report.resolution['just-bash'].startsWith(shadow + '/node_modules/'));
assert.ok(report.resolution['isomorphic-git'].startsWith(shadow + '/node_modules/'));
const root = await mkdtemp(join(tmpdir(), 'ohos-license-prune-'));
const work = join(root, 'work'), temp = join(root, 'temp');
await mkdir(work); await mkdir(temp);
let runtime;
try {
  const { VirtualSubprocessRuntime } = await import(pathToFileURL(join(shadow, 'process/runtime.mjs')));
  runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot: temp });
  const run = async argv => {
    const handle = runtime.spawn({ argv, cwd: work, graceMs: 100, stdio: { stdin: 'ignore', stdout: { maxBytes: 1024 * 1024 }, stderr: { maxBytes: 1024 * 1024 } } });
    const timer = setTimeout(() => handle.terminate(), 15000);
    const done = await handle.done.finally(() => clearTimeout(timer));
    const result = { ...done, stdout: handle.collected.stdout.readFrom(0).text, stderr: handle.collected.stderr.readFrom(0).text };
    assert.equal(result.signal, null);
    return result;
  };
  const check = (name, result, expected) => {
    assert.equal(result.exitCode, expected.exitCode, result.stderr);
    if (expected.stdout !== undefined) assert.equal(result.stdout, expected.stdout);
    report.checks.push({ name, pass: true, exitCode: result.exitCode });
  };
  check('shell-pipeline', await run(['bash', '-c', "printf 'b\\na\\n' | sort | head -n 1"]), { exitCode: 0, stdout: 'a\n' });
  check('shell-files', await run(['bash', '-c', "printf 'hello\\n' > a.txt; cp a.txt b.txt; mv b.txt c.txt; cat c.txt; rm a.txt c.txt"]), { exitCode: 0, stdout: 'hello\n' });
  check('shell-loop', await run(['bash', '-c', 'for x in 1 2 3; do printf "$x"; done']), { exitCode: 0, stdout: '123' });
  await writeFile(join(work, '中文.txt'), '中文 foo\n');
  const grep = await run(['rg', '--json', '--regexp=\\b中文\\b', '--glob=*.txt']);
  check('unicode-json-rg', grep, { exitCode: 0 });
  assert.equal(JSON.parse(grep.stdout).data.submatches[0].match.text, '中文');
  for (const name of ['python3', 'sqlite3', 'node']) check(name + '-unavailable', await run([name, '--version']), { exitCode: 127 });
  const git = (await import(pathToFileURL(require.resolve('isomorphic-git')))).default;
  const repo = join(work, 'repo'); await mkdir(repo);
  await git.init({ fs, dir: repo, defaultBranch: 'main' });
  assert.equal(await git.currentBranch({ fs, dir: repo }), 'main');
  report.checks.push({ name: 'isomorphic-git-init', pass: true });
  report.pass = report.checks.length;
} catch (error) {
  report.failure = { name: error.name, code: error.code, message: error.message, stack: error.stack };
  process.exitCode = 1;
} finally {
  await runtime?.dispose();
  await rm(root, { recursive: true, force: true });
  console.log(JSON.stringify(report, null, 2));
}
