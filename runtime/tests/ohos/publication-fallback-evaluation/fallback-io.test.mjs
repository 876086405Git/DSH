import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import syncFs from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';

assert.equal(process.version, 'v24.22.1');
const strict = process.env.DSH_TEST_M3C_STRICT === '1';
if (strict) {
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
  assert.equal(typeof WebAssembly, 'undefined');
  assert.throws(() => spawnSync(process.execPath, ['--version']), { code: 'ERR_OHOS_SIM_SPAWN' });
  assert.throws(() => syncFs.linkSync('/not-a-source', '/not-a-target'), { code: 'EACCES' });
  assert.throws(() => process.dlopen({}, '/not-an-addon.node'), { code: 'ERR_OHOS_SIM_DLOPEN' });
}
const directory = resolve(process.env.DSH_TEST_M3C_VARIANTS);
const modes = ['baseline', 'naive', 'guarded'];
const factories = Object.fromEntries(await Promise.all(modes.map(async name =>
  [name, (await import(pathToFileURL(join(directory, `${name}.mjs`)))).createAtomicPublisher])));
const results = [];
const digest = data => createHash('sha256').update(data).digest('hex');
const contents = (size, offset = 0) => Buffer.from(Array.from({ length: size }, (_, i) => (i * 17 + offset) % 251));
const codeList = error => !error ? [] : [error.code ?? error.name, ...(error.errors ?? []).flatMap(codeList)];
const exists = async path => fs.stat(path).then(() => true, error => {
  if (error.code === 'ENOENT') return false;
  throw error;
});

async function run(mode, name, { size = 131139, fallbackHook, afterFinalWrite,
  nativeError = { code: 'EINVAL', errno: -22, syscall: 'renameat2' }, existingFinal } = {}) {
  const root = await fs.mkdtemp(join(tmpdir(), 'dsh-m3c-io-'));
  const source = join(root, 'source'), target = join(root, 'final');
  const original = contents(size);
  const counters = Object.fromEntries(['source', 'temporary', 'final'].map(role =>
    [role, { opens: 0, readCalls: 0, readBytes: 0, writeCalls: 0, writeBytes: 0, syncCalls: 0, closes: 0 }]));
  const controller = new AbortController();
  let receipt, fallbackCalls = 0, commitCalls = 0, result, error;
  const state = { root, source, target, original, controller };
  const handles = new Set();
  await fs.writeFile(source, original);
  if (existingFinal) await fs.writeFile(target, existingFinal);
  const activeFs = {
    ...fs,
    link: async () => { throw Object.assign(new Error('explicit test gate: link unavailable'), { code: 'EACCES' }); },
    open: async (path, flags, permissions) => {
      const handle = await fs.open(path, flags, permissions);
      handles.add(handle);
      const role = path === source ? 'source' : path === target ? 'final' : 'temporary';
      const count = counters[role]; count.opens++;
      return new Proxy(handle, { get(object, key) {
        if (key === 'read') return async (...args) => {
          const answer = await object.read(...args); count.readCalls++; count.readBytes += answer.bytesRead; return answer;
        };
        if (key === 'writeFile') return async data => {
          await object.writeFile(data); count.writeCalls++; count.writeBytes += data.byteLength;
          if (role === 'final') await afterFinalWrite?.({ ...state, receipt, count });
        };
        if (key === 'sync') return async () => { await object.sync(); count.syncCalls++; };
        if (key === 'close') return async () => {
          await object.close(); handles.delete(object); count.closes++;
        };
        const value = Reflect.get(object, key, object);
        return typeof value === 'function' ? value.bind(object) : value;
      } });
    },
  };
  try {
    const publish = factories[mode]({ fs: activeFs,
      renameNoReplace() { commitCalls++; throw Object.assign(new Error('explicit test native outcome'), nativeError); },
      registerTemporary(value) { receipt = value; },
      async onFallback() { fallbackCalls++; await fallbackHook?.({ ...state, receipt }); },
    });
    try { result = await publish(source, target, { signal: controller.signal }); }
    catch (caught) { error = caught; }
    const final = await exists(target) ? await fs.readFile(target) : undefined;
    const temporary = receipt && await exists(receipt.path) ? await fs.readFile(receipt.path) : undefined;
    const observation = { name, mode, strictConstraintsVerified: strict, injectedLinkError: 'EACCES',
      injectedNativeOutcome: nativeError, sourceBytes: original.length, sourceSHA256: digest(original),
      result, errors: codeList(error), fallbackCalls, commitCalls,
      counters, totalReadBytes: Object.values(counters).reduce((n, c) => n + c.readBytes, 0),
      totalWriteBytes: Object.values(counters).reduce((n, c) => n + c.writeBytes, 0),
      finalExists: final !== undefined, finalBytes: final?.length, finalSHA256: final && digest(final),
      temporaryExists: temporary !== undefined, temporaryBytes: temporary?.length,
      temporarySHA256: temporary && digest(temporary), openHandlesAfterPublish: handles.size,
      pendingAfterPublish: publish.pendingCount };
    results.push(observation);
    assert.equal(handles.size, 0, 'each actual opened handle must close');
    assert.equal(publish.pendingCount, 0);
    return { observation, original, final, temporary, result, error };
  } finally {
    for (const handle of handles) await handle.close().catch(() => {});
    await fs.rm(root, { recursive: true, force: true });
  }
}

for (const mode of modes) {
  test(`${mode}: actual stable-file read/write counters`, async () => {
    const { observation: o, original, final, error } = await run(mode, 'stable', { size: 262267 });
    assert.equal(error, undefined); assert.deepEqual(final, original);
    assert.equal(o.result.method, 'exclusive-copy-fallback'); assert.equal(o.fallbackCalls, 1);
    assert.equal(o.counters.source.readBytes, original.length * (mode === 'baseline' ? 2 : 1));
    assert.equal(o.counters.temporary.readBytes, mode === 'baseline' ? 0 : original.length);
    assert.equal(o.counters.source.opens, mode === 'baseline' ? 2 : 1);
    assert.equal(o.counters.temporary.writeBytes, original.length);
    assert.equal(o.counters.final.writeBytes, original.length);
    assert.equal(o.totalReadBytes, 2 * original.length); assert.equal(o.totalWriteBytes, 2 * original.length);
    assert.equal(o.temporaryExists, false);
  });
  test(`${mode}: source changes after completed staging`, async () => {
    const changed = contents(65731, 91);
    const { original, final, error } = await run(mode, 'source-changed', {
      fallbackHook: ({ source }) => fs.writeFile(source, changed),
    });
    assert.equal(error, undefined); assert.deepEqual(final, mode === 'baseline' ? changed : original);
  });
  test(`${mode}: source removed after completed staging`, async () => {
    const { observation: o, original, final, error } = await run(mode, 'source-removed', {
      fallbackHook: ({ source }) => fs.unlink(source),
    });
    if (mode === 'baseline') { assert.equal(error?.code, 'ENOENT'); assert.equal(o.finalExists, false); }
    else { assert.equal(error, undefined); assert.deepEqual(final, original); }
  });
  test(`${mode}: path replacement is diagnosed before final creation only by the guarded variant`, async () => {
    const foreign = Buffer.from('FOREIGN file at the completed temporary path');
    const { observation: o, original, final, temporary } = await run(mode, 'temporary-replaced', {
      fallbackHook: async ({ receipt }) => {
        await fs.rename(receipt.path, `${receipt.path}.saved`);
        await fs.writeFile(receipt.path, foreign);
      },
    });
    assert.ok(o.errors.includes('ERR_OHOS_PUBLICATION_TEMP_REPLACED'));
    assert.deepEqual(temporary, foreign, 'cleanup must preserve the replacement');
    if (mode === 'guarded') { assert.equal(o.finalExists, false); assert.equal(o.counters.final.opens, 0); }
    else assert.deepEqual(final, mode === 'baseline' ? original : foreign);
  });
  test(`${mode}: symlink replacement is not followed by the guarded reopen`, async () => {
    const foreign = Buffer.from('FOREIGN symlink target');
    const { observation: o, original, final, temporary } = await run(mode, 'temporary-symlink', {
      fallbackHook: async ({ root, receipt }) => {
        const foreignPath = join(root, 'foreign'); await fs.writeFile(foreignPath, foreign);
        await fs.rename(receipt.path, `${receipt.path}.saved`);
        await fs.symlink(foreignPath, receipt.path);
      },
    });
    assert.ok(o.errors.includes('ERR_OHOS_PUBLICATION_TEMP_REPLACED'));
    assert.deepEqual(temporary, foreign);
    if (mode === 'guarded') { assert.ok(o.errors.includes('ELOOP')); assert.equal(o.finalExists, false); }
    else assert.deepEqual(final, mode === 'baseline' ? original : foreign);
  });
  test(`${mode}: same-inode mutation is an explicit residual limit`, async () => {
    const changed = Buffer.from('same-inode write after sync; identity is not content immutability');
    const { final, original, error } = await run(mode, 'same-inode-mutation', {
      fallbackHook: async ({ receipt }) => {
        await fs.writeFile(receipt.path, changed);
        const current = await fs.stat(receipt.path, { bigint: true });
        assert.equal(String(current.dev), receipt.dev); assert.equal(String(current.ino), receipt.ino);
      },
    });
    assert.equal(error, undefined); assert.deepEqual(final, mode === 'baseline' ? original : changed);
  });
  test(`${mode}: fallback cancellation still leaves a partial final`, async () => {
    const reason = Object.assign(new Error('test abort after a confirmed real final write'), { code: 'TEST_ABORT' });
    const { observation: o, final, original, error } = await run(mode, 'partial-final-on-cancel', {
      afterFinalWrite: ({ count, controller }) => { if (count.writeCalls === 1) controller.abort(reason); },
    });
    assert.equal(error, reason); assert.equal(o.finalBytes, 65536); assert.ok(o.finalBytes < original.length);
    assert.deepEqual(final, original.subarray(0, 65536)); assert.equal(o.temporaryExists, false);
  });
  test(`${mode}: existing final remains byte identical`, async () => {
    const existing = Buffer.from('existing final bytes');
    const { final, error, observation: o } = await run(mode, 'existing-final', { existingFinal: existing });
    assert.equal(error?.code, 'EEXIST'); assert.deepEqual(final, existing);
    assert.equal(o.counters.final.opens, 0); assert.equal(o.counters.final.writeBytes, 0);
  });
}
for (const mode of ['baseline', 'guarded']) {
  for (const [code, syscall] of [['EACCES', 'renameat2'], ['EXDEV', 'renameat2'],
    ['ENOSYS', 'renameat2'], ['EIO', 'renameat2'], ['EINVAL', 'open']]) {
    test(`${mode}: ${code}/${syscall} never enters the EINVAL renameat2 fallback`, async () => {
      const { observation: o, error } = await run(mode, `gate-${code}-${syscall}`, { nativeError: { code, syscall } });
      assert.equal(error?.code, code); assert.equal(o.fallbackCalls, 0);
      assert.equal(o.finalExists, false); assert.equal(o.temporaryExists, false);
    });
  }
}
test.after(async () => {
  await fs.writeFile(process.env.DSH_TEST_M3C_RESULTS, JSON.stringify({
    node: process.version, argv: process.execArgv, strictConstraintsVerified: strict,
    scope: 'Real FileHandle I/O; explicit injected link/native gate. Application byte counts are not physical device reads, cache misses, or a performance benchmark.',
    productionModified: false, results,
  }, null, 2) + '\n');
});
