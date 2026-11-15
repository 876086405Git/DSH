// Real NativeHost ETS body after TS erasure. Only the unavailable native module
// boundary is supplied by this fixture; check-arkts separately validates ArkTS.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import vm from 'node:vm';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const source = path.join(root, 'app/ohos/entry/src/main/ets');
assert(process.env.OHOS_TYPESCRIPT_PREFIX, 'Set OHOS_TYPESCRIPT_PREFIX to the locked TypeScript prefix');
const ts = createRequire(path.resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
const compile = text => ts.transpileModule(text, { compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
} }).outputText;
const text = fs.readFileSync(path.join(source, 'runtime/NativeHost.ets'), 'utf8');
const core = { exports: {} };
vm.runInNewContext(compile(fs.readFileSync(path.join(source, 'runtime/RuntimeCore.ets'), 'utf8')),
  { exports: core.exports, module: core });
const idle = { phase: 'idle', consumed: false, baseUrl: null, token: null,
  exitCode: null, errorCode: null, errorMessage: null };
const plain = value => JSON.parse(JSON.stringify(value));
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};

function fixture(boundary) {
  let loads = 0;
  const module = { exports: {} };
  vm.runInNewContext(compile(text), {
    exports: module.exports, module,
    require(name) {
      if (name === './RuntimeCore') return core.exports;
      assert.equal(name, 'libdsh_host.so');
      loads++;
      return boundary();
    },
  });
  return { api: module.exports, get loads() { return loads; } };
}

test('entry-reachable sources contain no static native value import', () => {
  const violations = [];
  const before = process.env.OHOS_NATIVE_LAZY_BEFORE_DIR;
  const visit = directory => {
    for (const item of fs.readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, item.name);
      if (item.isDirectory()) { visit(file); continue; }
      if (!item.name.endsWith('.ets')) continue;
      const relative = path.relative(source, file);
      const old = before && path.join(before, relative);
      const input = old && fs.existsSync(old) ? old : file;
      const ast = ts.createSourceFile(input, fs.readFileSync(input, 'utf8'), ts.ScriptTarget.Latest, true);
      for (const node of ast.statements) {
        if (ts.isImportDeclaration(node) && node.moduleSpecifier.text === 'libdsh_host.so' &&
            !node.importClause?.isTypeOnly) violations.push(relative);
      }
    }
  };
  visit(source);
  assert.deepEqual(violations, [], 'a static import still maps the native host before demand');
});

test('loading the helper and reading state does not touch the native boundary', () => {
  const f = fixture(() => { throw new Error('must stay unloaded'); });
  assert.equal(f.api.peekNativeHost(), null);
  for (let i = 0; i < 20; i++) assert.deepEqual(plain(f.api.nativeHostState()), idle);
  assert.equal(f.loads, 0);
});

test('concurrent demand shares one load and preserves live native state', async () => {
  const pending = deferred();
  const current = { ...idle };
  const host = { getState: () => ({ ...current }) };
  const f = fixture(() => pending.promise);
  const first = f.api.loadNativeHost(), second = f.api.loadNativeHost();
  assert.equal(first, second);
  await Promise.resolve();
  assert.equal(f.loads, 1);
  assert.equal(f.api.peekNativeHost(), null);
  assert.deepEqual(plain(f.api.nativeHostState()), idle);
  pending.resolve({ default: host });
  assert.equal(await first, host);
  assert.equal(await second, host);
  assert.equal(f.api.peekNativeHost(), host);
  current.phase = 'running'; current.consumed = true;
  assert.deepEqual(plain(f.api.nativeHostState()), current);
  assert.equal(await f.api.loadNativeHost(), host);
  assert.equal(f.loads, 1);
});

test('a rejected load stays unloaded and can be retried without consuming Node', async () => {
  const failure = new Error('fixture dlopen failure');
  const host = { getState: () => ({ ...idle }) };
  let fail = true;
  const f = fixture(() => { if (fail) throw failure; return { default: host }; });
  await assert.rejects(f.api.loadNativeHost(), error => error === failure);
  assert.equal(f.api.peekNativeHost(), null);
  assert.deepEqual(plain(f.api.nativeHostState()), idle);
  fail = false;
  assert.equal(await f.api.loadNativeHost(), host);
  assert.equal(f.loads, 2);
});

test('resolved missing default is an explicit error and never a successful native load', async () => {
  const f = fixture(() => ({ default: undefined }));
  await assert.rejects(f.api.loadNativeHost(), { code: 'ohos_native_unavailable' });
  assert.equal(f.api.peekNativeHost(), null);
  assert.deepEqual(plain(f.api.nativeHostState()), idle);
  await assert.rejects(f.api.loadNativeHost(), { code: 'ohos_native_unavailable' });
  assert.equal(f.loads, 2);
});
