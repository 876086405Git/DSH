import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { createServer } from 'node:https';
import { once } from 'node:events';
import { mkdtempSync, readFileSync, rmSync, writeFileSync, symlinkSync, existsSync, lstatSync, mkdirSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createPythonRuntimeBackend } from '../../ohos/process/python-backend.mjs';
import { createPythonHost } from '../../ohos/python/host.mjs';
import { beforeJobExit } from './python-test-observation.mjs';
const root = mkdtempSync(join(tmpdir(), 'python-production-'));
const config = JSON.parse(process.env.OHOS_PYTHON_HOST_CONFIG);
const native = createPythonHost({ ...config, roots: [root] });
const backend = createPythonRuntimeBackend({ native });
after(async () => {
  try { await backend.dispose(); } finally { rmSync(root, { recursive: true, force: true }); }
}, { timeout: 15000 });
async function run(code, env = {}) {
  const handle = backend.spawn({ argv: ['python3', '-c', code], cwd: root, env, graceMs: 1000,
    stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
  const stdout = [], stderr = [];
  handle.stdout.on('data', b => stdout.push(b)); handle.stderr.on('data', b => stderr.push(b));
  const result = await handle.done;
  return { ...result, stdout: Buffer.concat(stdout).toString(), stderr: Buffer.concat(stderr).toString() };
}
test('production host isolates cwd/env, supports relative IO and repeated clean modules', async () => {
  const before = process.cwd(), original = process.env.TEST_ONLY;
  const first = await run("import os,sys\nprint(os.getcwd())\nprint(os.environ['TEST_ONLY'])\nopen('relative.txt','w').write('saved')\nos.environ['TEST_ONLY']='mutated'\nimport json\njson._dsh_marker=1", { TEST_ONLY: 'isolated' });
  assert.equal(first.exitCode, 0, first.stderr); assert.equal(first.stdout, root + '\nisolated\n');
  assert.equal(readFileSync(join(root, 'relative.txt'), 'utf8'), 'saved');
  assert.equal(process.cwd(), before); assert.equal(process.env.TEST_ONLY, original);
  const second = await run("import json,os\nprint(hasattr(json,'_dsh_marker'))\nprint(os.environ.get('TEST_ONLY'))");
  assert.equal(second.stdout, 'False\nNone\n', second.stderr);
});
test('binary streams and explicit unsupported stdin', async () => {
  const binary = await run("import sys\nsys.stdout.buffer.write(b'abc\\x00')");
  assert.equal(binary.stdout, 'abc\0', binary.stderr);
  const input = await run('input()'); assert.equal(input.exitCode, 1); assert.match(input.stderr, /ERR_OHOS_PYTHON_STDIN/);
});
test('SQLite relative path and SSL import execute inside new subinterpreter', async () => {
  const result = await run("import sqlite3,ssl\nc=sqlite3.connect('data.db')\nc.execute('create table sample(a)')\nc.close()\nprint(ssl.OPENSSL_VERSION.startswith('OpenSSL'))");
  assert.equal(result.exitCode, 0, result.stderr); assert.equal(result.stdout, 'True\n');
});
test('relative paths outside roots and unapproved dlopen are explicit failures', async () => {
  assert.match((await run("open('../outside','w')")).stderr, /ERR_OHOS_PYTHON_PATH/);
  assert.match((await run("import ctypes\nctypes.CDLL('/not-approved.so')")).stderr, /ERR_OHOS_PYTHON_DLOPEN/);
});
test('Python text reaches Node before completion and cancellation preserves App', { timeout: 15000 }, async t => {
  const handle = backend.spawn({ argv: ['python3', '-c', "print('ready',flush=True)\nwhile True: pass"], cwd: root, env: {}, graceMs: 1000,
    stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
  let errors = ''; handle.stderr.on('data', bytes => { errors += bytes; });
  t.after(async () => { handle.terminate(); await handle.done.catch(() => {}); });
  const [chunk] = await beforeJobExit(handle, signal => once(handle.stdout, 'data', { signal }),
    { label: 'early stdout', stderr: () => errors, signal: t.signal });
  assert.match(chunk.toString(), /ready/); handle.terminate();
  assert.equal((await handle.done).exitCode, 130);
});
test('an actual Python failure ends an absent-output observation promptly', { timeout: 5000 }, async t => {
  const handle = backend.spawn({ argv: ['python3', '-c', "raise RuntimeError('expected-output-observation-failure')"],
    cwd: root, env: {}, graceMs: 1000, stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
  let errors = ''; handle.stderr.on('data', bytes => { errors += bytes; });
  await assert.rejects(beforeJobExit(handle, signal => once(handle.stdout, 'data', { signal }),
    { label: 'absent stdout', stderr: () => errors, signal: t.signal }), error =>
      error.code === 'ERR_OHOS_TEST_JOB_ENDED_EARLY' && error.outcome.exitCode === 1 &&
      error.message.includes('expected-output-observation-failure'));
});
test('ctypes structures remain available while unapproved native loads are refused', async () => {
  const result = await run("import ctypes\nprint(ctypes.sizeof(ctypes.c_int))");
  assert.equal(result.exitCode, 0, result.stderr); assert.equal(result.stdout, '4\n');
});
test('script relative to cwd executes argv and pathlib with local chdir', async () => {
  writeFileSync(join(root, 'job.py'), "import os,pathlib,sys\nos.mkdir('sub')\nos.chdir('sub')\npathlib.Path('path.txt').write_text(sys.argv[1])\nprint(os.getcwd())");
  const handle = backend.spawn({ argv: ['python3', 'job.py', 'script-arg'], cwd: root, env: {}, graceMs: 1000,
    stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
  let errors = ''; handle.stdout.resume(); handle.stderr.on('data', bytes => { errors += bytes; });
  assert.equal((await handle.done).exitCode, 0, errors);
  assert.equal(readFileSync(join(root, 'sub/path.txt'), 'utf8'), 'script-arg');
});

test('urllib HTTPS verifies the packaged CA and rejects an untrusted context', async () => {
  const server = createServer({ key: readFileSync(process.env.OHOS_PYTHON_TLS_KEY), cert: readFileSync(process.env.OHOS_PYTHON_TLS_CERT) }, (_req, res) => res.end('verified'));
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  try {
    const url = `https://127.0.0.1:${server.address().port}/`;
    const result = await run(`import urllib.request\nprint(urllib.request.urlopen(${JSON.stringify(url)}, timeout=3).read().decode())`);
    assert.equal(result.exitCode, 0, result.stderr); assert.equal(result.stdout, 'verified\n');
    const refused = await run(`import urllib.request,ssl\nctx=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)\nurllib.request.urlopen(${JSON.stringify(url)},context=ctx,timeout=3)`);
    assert.equal(refused.exitCode, 1); assert.match(refused.stderr, /CERTIFICATE_VERIFY_FAILED/);
  } finally { await new Promise(resolve => server.close(resolve)); }
});
test('bounded output failure is explicit and a subsequent job still runs', async () => {
  await assert.rejects(run("print('x'*(17*1024*1024))"), { code: 'ERR_OHOS_PYTHON_OUTPUT_LIMIT' });
  assert.equal((await run('print(123)')).stdout, '123\n');
});

test('initialization installs the system CA directory for OpenSSL C lookups', async () => {
  const server = createServer({ key: readFileSync(process.env.OHOS_PYTHON_SYSTEM_TLS_KEY), cert: readFileSync(process.env.OHOS_PYTHON_SYSTEM_TLS_CERT) }, (_req, res) => res.end('system-store'));
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  try {
    const url = `https://127.0.0.1:${server.address().port}/`;
    const result = await run(`import ssl,urllib.request\nctx=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)\nctx.load_default_certs()\nprint(urllib.request.urlopen(${JSON.stringify(url)},context=ctx,timeout=3).read().decode())`);
    assert.equal(result.exitCode, 0, result.stderr); assert.equal(result.stdout, 'system-store\n');
    const automatic = await run(`import urllib.request\nprint(urllib.request.urlopen(${JSON.stringify(url)},timeout=3).read().decode())`);
    assert.equal(automatic.exitCode, 0, automatic.stderr); assert.equal(automatic.stdout, 'system-store\n');
    const explicit = await run(`import ssl,urllib.request\nctx=ssl.create_default_context(cafile=${JSON.stringify(process.env.OHOS_PYTHON_TLS_CERT)})\nurllib.request.urlopen(${JSON.stringify(url)},context=ctx,timeout=3)`);
    assert.equal(explicit.exitCode, 1); assert.match(explicit.stderr, /CERTIFICATE_VERIFY_FAILED/);
  } finally { await new Promise(resolve => server.close(resolve)); }
});

test('future imports compile at the start of user code and script imports its sibling', async () => {
  const command = await run('from __future__ import annotations\nprint("future")');
  assert.equal(command.exitCode, 0, command.stderr); assert.equal(command.stdout, 'future\n');
  mkdirSync(join(root, 'future-pkg'));
  writeFileSync(join(root, 'future-pkg/helper.py'), 'VALUE=42\n');
  writeFileSync(join(root, 'future-pkg/main.py'), 'from __future__ import annotations\nimport helper\nprint(helper.VALUE)\n');
  const handle = backend.spawn({ argv: ['python3', 'future-pkg/main.py'], cwd: root, env: {}, graceMs: 1000,
    stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
  let output = '', errors = ''; handle.stdout.on('data', b => { output += b; }); handle.stderr.on('data', b => { errors += b; });
  assert.equal((await handle.done).exitCode, 0, errors); assert.equal(output, '42\n');
});
test('unlink, lstat, readlink, rename and exclusive open preserve the final symlink', async () => {
  const target = join(root, 'precious'); writeFileSync(target, 'keep');
  symlinkSync(target, join(root, 'leaf'));
  const result = await run("import os,stat\nprint(stat.S_ISLNK(os.lstat('leaf').st_mode))\nprint(os.readlink('leaf'))\nos.rename('leaf','moved')\nos.unlink('moved')");
  assert.equal(result.exitCode, 0, result.stderr); assert.equal(result.stdout, 'True\n' + target + '\n');
  assert.equal(readFileSync(target, 'utf8'), 'keep'); assert.equal(existsSync(join(root, 'moved')), false);
  symlinkSync(join(root, 'absent-target'), join(root, 'exclusive'));
  const exclusive = await run("open('exclusive','x')"); assert.equal(exclusive.exitCode, 1); assert.match(exclusive.stderr, /FileExistsError/);
  assert.equal(lstatSync(join(root, 'exclusive')).isSymbolicLink(), true); assert.equal(existsSync(join(root, 'absent-target')), false);
  writeFileSync(join(root, 'replacement'), 'new'); symlinkSync(target, join(root, 'replace-leaf'));
  const replaced = await run("import os\nos.replace('replacement','replace-leaf')"); assert.equal(replaced.exitCode, 0, replaced.stderr);
  assert.equal(readFileSync(target, 'utf8'), 'keep'); assert.equal(readFileSync(join(root, 'replace-leaf'), 'utf8'), 'new');
});

test('trailing slash with nofollow never mutates an out-of-root directory', async () => {
  const outside = mkdtempSync(join(tmpdir(), 'python-outside-'));
  symlinkSync(outside, join(root, 'outside-dir-link'));
  const before = statSync(outside).mtimeMs;
  try {
    const result = await run("import os\nos.utime('outside-dir-link/',ns=(1000000000,1000000000),follow_symlinks=False)");
    assert.equal(statSync(outside).mtimeMs, before);
    assert.equal(result.exitCode, 1); assert.match(result.stderr, /ERR_OHOS_PYTHON_PATH/);
  } finally { rmSync(outside, { recursive: true }); }
});
test('backend advertises no confinement and refuses a provided policy', () => {
  assert.deepEqual(backend.capabilities, { confinement: 'none', trustedOnly: true });
  assert.throws(() => backend.spawn({ policy: { mode: 'read-only' } }), { code: 'ERR_OHOS_PYTHON_CONFINEMENT' });
});
