import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { secretsFixture, deferred } from './secrets-fixture.mjs';

test('first empty reads are empty without generating a key; four methods preserve Unicode namespaces', async t => {
  const f = await secretsFixture(t);
  assert.deepEqual(await f.request('read', { key: 'remote.未保存' }), { value: null });
  assert.deepEqual(await f.request('readAll'), { value: {} });
  assert.deepEqual(await f.request('delete', { key: 'absent' }), { value: null });
  assert.equal(f.events.filter(row => row.op === 'generate').length, 0);
  const value = '秘密材料—中文🔐\nsecond line';
  assert.deepEqual(await f.request('write', { key: 'remote.密码', value }), { value: null });
  assert.deepEqual(await f.request('write', { key: 'deepseek_api_key', value: '' }), { value: null });
  assert.deepEqual(await f.request('read', { key: 'remote.密码' }), { value });
  assert.deepEqual(await f.request('readAll'), { value: { 'remote.密码': value, deepseek_api_key: '' } });
  const bytes = await fs.readFile(f.vaultPath);
  assert.equal(bytes.includes(Buffer.from(value)), false);
  assert.equal(bytes.includes(Buffer.from('remote.密码')), false);
  assert.deepEqual(await f.request('delete', { key: 'remote.密码' }), { value: null });
  assert.deepEqual(await f.request('readAll'), { value: { deepseek_api_key: '' } });
});

test('large private-key/hosted-list text exceeds Asset size and HUKS chunk size; actual short file IO completes', async t => {
  const f = await secretsFixture(t, { maxRead: 8191, maxWrite: 4093 });
  const value = '-----BEGIN PRIVATE KEY-----\n' + '中文内容-and-key-data\n'.repeat(12000) + '-----END PRIVATE KEY-----';
  assert(Buffer.byteLength(value) > 100 * 1024);
  assert.deepEqual(await f.request('write', { key: 'remote.private-key', value }), { value: null });
  assert.deepEqual(await f.request('read', { key: 'remote.private-key' }), { value });
  assert(f.events.some(row => row.op === 'update' && row.bytes === 64 * 1024));
  assert(f.events.filter(row => row.op === 'update').every(row => row.bytes <= 64 * 1024));
  assert.equal(f.fds.size, 0);
});

test('same value gets a fresh nonce; a new engine instance reuses the original non-overwritten key', async t => {
  const f = await secretsFixture(t);
  const args = { key: 'forum.keypair', value: '{"private":"retained"}' };
  assert.deepEqual(await f.request('write', args), { value: null });
  const first = await fs.readFile(f.vaultPath);
  f.plugin.onDetachedFromEngine(f.engine);
  const next = f.attach();
  assert.deepEqual(await f.request('read', { key: args.key }, next.channel), { value: args.value });
  assert.deepEqual(await f.request('write', args, next.channel), { value: null });
  const second = await fs.readFile(f.vaultPath);
  assert.notDeepEqual(first.subarray(8, 20), second.subarray(8, 20));
  assert.notDeepEqual(first, second);
  assert.equal(f.events.filter(row => row.op === 'generate').length, 1);
  next.plugin.onDetachedFromEngine(next.engine);
});

test('two live instances serialize read-modify-write without dropping concurrent keys', async t => {
  const f = await secretsFixture(t), next = f.attach();
  const writes = Array.from({ length: 12 }, (_, i) => f.request('write', { key: 'provider_key_' + i, value: 'key-' + i }, i % 2 ? next.channel : f.channel));
  assert((await Promise.all(writes)).every(reply => reply.value === null && !reply.error));
  assert.deepEqual(await f.request('delete', { key: 'provider_key_3' }, next.channel), { value: null });
  assert.deepEqual(await f.request('readAll'), { value: Object.fromEntries(Array.from({ length: 12 }, (_, i) => i).filter(i => i !== 3).map(i => ['provider_key_' + i, 'key-' + i])) });
  assert.equal(f.events.filter(row => row.op === 'generate').length, 1);
  next.plugin.onDetachedFromEngine(next.engine);
});

test('corrupt version or GCM tag makes all four operations fail without replacing existing ciphertext', async t => {
  const f = await secretsFixture(t);
  await f.request('write', { key: 'hosted_links', value: '[{"secret":"old-data"}]' });
  const original = await fs.readFile(f.vaultPath);
  for (const index of [4, original.length - 1]) {
    const corrupt = Buffer.from(original); corrupt[index] ^= 1; await fs.writeFile(f.vaultPath, corrupt);
    for (const [method, args] of [['read', { key: 'hosted_links' }], ['readAll', {}], ['write', { key: 'hosted_links', value: '[]' }], ['delete', { key: 'hosted_links' }]]) {
      const result = await f.request(method, args);
      assert.equal(result.error, 'secrets_unreadable');
      assert.deepEqual(await fs.readFile(f.vaultPath), corrupt);
    }
  }
  assert.equal(f.events.filter(row => row.op === 'generate').length, 1);
});

test('missing HUKS key with existing ciphertext is not first use, including subsequent UI-style empty save', async t => {
  const f = await secretsFixture(t);
  await f.request('write', { key: 'hosted_links', value: '[{"secret":"saved"}]' });
  const before = await fs.readFile(f.vaultPath); f.keys.clear();
  for (const [method, args] of [['read', { key: 'hosted_links' }], ['readAll', {}], ['write', { key: 'hosted_links', value: '[]' }], ['delete', { key: 'hosted_links' }]]) {
    assert.equal((await f.request(method, args)).error, 'secrets_key_missing');
    assert.deepEqual(await fs.readFile(f.vaultPath), before);
  }
  assert.equal(f.events.filter(row => row.op === 'generate').length, 1);
});

test('non-missing key-service errors do not trigger creation or an empty fallback', async t => {
  const f = await secretsFixture(t, { keyQueryError: 12000005 });
  assert.equal((await f.request('write', { key: 'deepseek_api_key', value: 'not-logged' })).error, 'secrets_unavailable');
  assert.equal(f.events.filter(row => row.op === 'generate').length, 0);
  await assert.rejects(fs.stat(f.vaultPath), { code: 'ENOENT' });
});

test('failed ciphertext write preserves the prior vault and does not poison later queued requests', async t => {
  const f = await secretsFixture(t);
  await f.request('write', { key: 'remote.password', value: 'prior' });
  const before = await fs.readFile(f.vaultPath);
  f.change({ beforeWrite: async () => { throw Error('controlled write failure'); } });
  assert.equal((await f.request('write', { key: 'remote.password', value: 'replacement' })).error, 'secrets_io');
  assert.deepEqual(await fs.readFile(f.vaultPath), before);
  assert.deepEqual(await fs.readdir(f.vaultPath.slice(0, f.vaultPath.lastIndexOf('/'))), ['vault-v1.bin']);
  f.change({ beforeWrite: null });
  assert.deepEqual(await f.request('read', { key: 'remote.password' }), { value: 'prior' });
  assert.deepEqual(await f.request('write', { key: 'remote.password', value: 'next' }), { value: null });
});

test('GCM finish failure after partial update never returns unauthenticated plaintext and aborts the session', async t => {
  const f = await secretsFixture(t);
  await f.request('write', { key: 'remote.private-key', value: '秘密'.repeat(50000) });
  const before = await fs.readFile(f.vaultPath);
  f.change({ finishFailure: true });
  const result = await f.request('readAll');
  assert.equal(result.error, 'secrets_unreadable'); assert.equal('value' in result, false);
  assert(f.events.some(row => row.op === 'abort')); assert.equal(f.sessions.size, 0);
  assert.deepEqual(await fs.readFile(f.vaultPath), before);
});

test('detach during encryption prevents publication and replies once; next instance can proceed', async t => {
  const entered = deferred(), release = deferred();
  const f = await secretsFixture(t, { beforeFinish: async ({ encrypt }) => { if (encrypt) { entered.resolve(); await release.promise; } } });
  const pending = f.call(f.channel, 'write', { key: 'retired', value: 'do-not-publish' });
  await entered.promise; f.plugin.onDetachedFromEngine(f.engine); const next = f.attach();
  release.resolve();
  assert.equal((await pending.done).error, 'cancelled'); assert.equal(pending.replies.length, 1);
  await assert.rejects(fs.stat(f.vaultPath), { code: 'ENOENT' });
  f.change({ beforeFinish: null });
  assert.deepEqual(await f.request('write', { key: 'current', value: 'saved' }, next.channel), { value: null });
  assert.deepEqual(await f.request('readAll', {}, next.channel), { value: { current: 'saved' } });
  next.plugin.onDetachedFromEngine(next.engine);
});

test('channel rejects malformed arguments without echoing secrets and keeps retired transport to one reply', async t => {
  const f = await secretsFixture(t);
  assert.deepEqual(await f.request('containsKey', { key: 'unused' }), { missing: true });
  const bad = await f.request('write', { key: 'secret-key', value: { secret: 'secret-value' } });
  assert.equal(bad.error, 'secrets_invalid'); assert(!bad.message.includes('secret-key')); assert(!bad.message.includes('secret-value'));
  f.change({ replyFailure: true });
  const read = f.call(f.channel, 'read', { key: 'absent' });
  assert.deepEqual(await read.done, { value: null }); await new Promise(resolve => setImmediate(resolve));
  assert.equal(read.replies.length, 1);
});


test('recovery requires literal confirmation, clears only credentials and works without decrypting a corrupt vault', async t => {
  const f = await secretsFixture(t);
  const config = f.app.filesDir + '/hosts.json';
  await fs.writeFile(config, '{"host":"keep-me"}');
  await f.request('write', { key: 'remote.password', value: 'old' });
  const corrupt = Buffer.from('broken encrypted vault');
  await fs.writeFile(f.vaultPath, corrupt);
  for (const args of [{}, { confirmed: false }, { confirmed: 'true' }, { confirmed: 1 }]) {
    assert.equal((await f.request('recover', args)).error, 'secrets_invalid');
    assert.deepEqual(await fs.readFile(f.vaultPath), corrupt);
  }
  assert.deepEqual(await f.request('recover', { confirmed: true }), { value: null });
  assert.equal(await fs.readFile(config, 'utf8'), '{"host":"keep-me"}');
  assert.deepEqual(await f.request('readAll'), { value: {} });
  assert.deepEqual(await f.request('recover', { confirmed: true }), { value: null });
  assert.deepEqual(await f.request('write', { key: 'replacement', value: 'new' }), { value: null });
  assert.equal(f.events.filter(row => row.op === 'generate').length, 2);
});

test('missing-key recovery deletes only ciphertext and permits new key creation on the next write', async t => {
  const f = await secretsFixture(t);
  await f.request('write', { key: 'lost', value: 'old' });
  f.keys.clear();
  assert.equal((await f.request('readAll')).error, 'secrets_key_missing');
  assert.deepEqual(await f.request('recover', { confirmed: true }), { value: null });
  assert.equal(f.events.filter(row => row.op === 'generate').length, 1);
  assert.deepEqual(await f.request('write', { key: 'replacement', value: 'new' }), { value: null });
  assert.deepEqual(await f.request('readAll'), { value: { replacement: 'new' } });
  assert.equal(f.events.filter(row => row.op === 'generate').length, 2);
});

test('recovery serializes behind the entire old read-modify-write and before the next write across engines', async t => {
  const f = await secretsFixture(t), next = f.attach();
  await f.request('write', { key: 'old', value: 'must disappear' });
  const entered = deferred(), release = deferred();
  f.change({ beforeFinish: async ({ encrypt }) => { if (encrypt) { entered.resolve(); await release.promise; } } });
  const oldWrite = f.request('write', { key: 'before', value: 'also disappear' });
  await entered.promise;
  const recovery = f.request('recover', { confirmed: true }, next.channel);
  const freshWrite = f.request('write', { key: 'after', value: 'retained' }, next.channel);
  release.resolve();
  assert.deepEqual(await oldWrite, { value: null });
  assert.deepEqual(await recovery, { value: null });
  assert.deepEqual(await freshWrite, { value: null });
  assert.deepEqual(await f.request('readAll'), { value: { after: 'retained' } });
  next.plugin.onDetachedFromEngine(next.engine);
});

test('failed or retired recovery preserves the vault and later requests still work', async t => {
  const f = await secretsFixture(t);
  await f.request('write', { key: 'old', value: 'retained' });
  const before = await fs.readFile(f.vaultPath);
  f.change({ beforeUnlink: async () => { throw Error('controlled unlink failure'); } });
  assert.equal((await f.request('recover', { confirmed: true })).error, 'secrets_io');
  assert.deepEqual(await fs.readFile(f.vaultPath), before);
  f.change({ beforeUnlink: null });
  const entered = deferred(), release = deferred();
  f.change({ beforeFinish: async ({ encrypt }) => { if (!encrypt) { entered.resolve(); await release.promise; } } });
  const reading = f.request('readAll');
  await entered.promise;
  const recovery = f.request('recover', { confirmed: true });
  f.plugin.onDetachedFromEngine(f.engine);
  const next = f.attach();
  release.resolve();
  assert.equal((await reading).error, 'cancelled');
  assert.equal((await recovery).error, 'cancelled');
  assert.deepEqual(await fs.readFile(f.vaultPath), before);
  f.change({ beforeFinish: null });
  assert.deepEqual(await f.request('readAll', {}, next.channel), { value: { old: 'retained' } });
  next.plugin.onDetachedFromEngine(next.engine);
});

test('post-commit directory sync failure succeeds with one safe diagnostic across writes and recovery', async t => {
  const f = await secretsFixture(t, { beforeSync: async path => {
    if (path.endsWith('/dsh-secrets')) throw Error('do not log path or secret');
  } });
  for (const value of ['first', 'replacement']) {
    assert.deepEqual(await f.request('write', { key: 'remote.password', value }), { value: null });
    assert.deepEqual(await f.request('read', { key: 'remote.password' }), { value });
  }
  const next = f.attach();
  assert.deepEqual(await f.request('recover', { confirmed: true }, next.channel), { value: null });
  assert.deepEqual(await f.request('readAll'), { value: {} });
  const warnings = f.events.filter(row => row.op === 'warning');
  assert.equal(warnings.length, 1);
  assert.equal(warnings[0].message, 'Credential change committed; directory durability unavailable');
  assert.equal(f.fds.size, 0);
  next.plugin.onDetachedFromEngine(next.engine);
});

test('directory open or close failures after rename are diagnosed without rejecting a committed write', async t => {
  for (const operation of ['beforeOpen', 'afterClose']) {
    await t.test(operation, async t => {
      const f = await secretsFixture(t, { [operation]: async path => {
        if (path.endsWith('/dsh-secrets')) throw Error('controlled directory failure');
      } });
      assert.deepEqual(await f.request('write', { key: 'key', value: 'saved' }), { value: null });
      assert.deepEqual(await f.request('read', { key: 'key' }), { value: 'saved' });
      assert.equal(f.events.filter(row => row.op === 'warning').length, 1);
      assert.equal(f.fds.size, 0);
    });
  }
});

test('ordinary file sync, close and rename failures remain errors and retain the original vault', async t => {
  for (const operation of ['beforeSync', 'afterClose', 'beforeRename']) {
    await t.test(operation, async t => {
      const f = await secretsFixture(t);
      await f.request('write', { key: 'old', value: 'retained' });
      const before = await fs.readFile(f.vaultPath);
      f.change({ [operation]: async path => { if (path.endsWith('/ciphertext')) throw Error('controlled precommit failure'); } });
      assert.equal((await f.request('write', { key: 'new', value: 'not committed' })).error, 'secrets_io');
      assert.deepEqual(await fs.readFile(f.vaultPath), before);
      assert.equal(f.events.filter(row => row.op === 'warning').length, 0);
      assert.equal(f.fds.size, 0);
    });
  }
});


const ownAlias = 'DSH.Go.Secrets.AES256.GCM.v1';
test('explicit recovery replaces an existing unusable key and touches only its fixed alias', async t => {
  const f = await secretsFixture(t);
  await f.request('write', { key: 'old', value: 'old-secret' });
  const oldKey = Buffer.from(f.keys.get(ownAlias));
  const otherAlias = 'another-service-key', otherKey = Buffer.alloc(32, 8);
  f.keys.set(otherAlias, otherKey); f.unusableKeys.add(ownAlias);
  const config = f.app.filesDir + '/hosts.json'; await fs.writeFile(config, 'keep host configuration');
  assert.equal((await f.request('write', { key: 'new', value: 'before-recovery' })).error, 'secrets_unreadable');
  assert.deepEqual(await f.request('recover', { confirmed: true }), { value: null });
  assert.equal(f.keys.has(ownAlias), false); assert.deepEqual(f.keys.get(otherAlias), otherKey);
  assert.deepEqual(await f.request('write', { key: 'new', value: 'after-recovery' }), { value: null });
  assert.notDeepEqual(f.keys.get(ownAlias), oldKey);
  assert.deepEqual(await f.request('readAll'), { value: { new: 'after-recovery' } });
  assert.equal(await fs.readFile(config, 'utf8'), 'keep host configuration');
  assert.deepEqual(f.events.filter(e => e.op === 'deleteKey').map(e => e.alias), [ownAlias]);
});

for (const missing of ['directory', 'vault']) test(`recovery deletes the stale fixed alias even with missing ${missing}`, async t => {
  const f = await secretsFixture(t);
  await f.request('write', { key: 'old', value: 'old' }); f.unusableKeys.add(ownAlias);
  if (missing === 'directory') await fs.rm(f.app.filesDir + '/dsh-secrets', { recursive: true });
  else await fs.unlink(f.vaultPath);
  f.change({ keyQueryError: 12000005 });
  assert.deepEqual(await f.request('recover', { confirmed: true }), { value: null });
  assert.equal(f.keys.has(ownAlias), false, 'recovery must not use the possibly broken existence query');
  f.change({ keyQueryError: undefined });
  assert.deepEqual(await f.request('write', { key: 'new', value: 'new' }), { value: null });
});

for (const code of [201, 12000004, 12000005, 12000012]) test(`key deletion error ${code} is explicit and retryable after ciphertext removal`, async t => {
  const f = await secretsFixture(t);
  await f.request('write', { key: 'old', value: 'old' });
  f.change({ deleteKeyError: code });
  const failed = await f.request('recover', { confirmed: true });
  assert.equal(failed.error, 'secrets_recovery_failed');
  assert(!failed.message.includes('已保留'));
  await assert.rejects(fs.access(f.vaultPath), { code: 'ENOENT' });
  assert.equal(f.keys.has(ownAlias), true);
  f.change({ deleteKeyError: undefined });
  assert.deepEqual(await f.request('recover', { confirmed: true }), { value: null });
  assert.equal(f.keys.has(ownAlias), false);
  assert.deepEqual(await f.request('write', { key: 'fresh', value: 'new' }), { value: null });
});

test('key deletion remains within the cross-engine vault queue before the next write', async t => {
  const f = await secretsFixture(t), entered = deferred(), release = deferred();
  await f.request('write', { key: 'old', value: 'old' });
  f.change({ beforeDeleteKey: async () => { entered.resolve(); await release.promise; } });
  const recovering = f.request('recover', { confirmed: true }); await entered.promise;
  const next = f.attach(); let written = false;
  const writing = f.request('write', { key: 'new', value: 'new' }, next.channel).then(value => { written = true; return value; });
  await Promise.resolve(); assert.equal(written, false);
  release.resolve(); assert.deepEqual(await recovering, { value: null });
  assert.deepEqual(await writing, { value: null });
  assert.deepEqual(await f.request('readAll', {}, next.channel), { value: { new: 'new' } });
  assert.equal(f.events.filter(e => e.op === 'generate').length, 2);
});

test('retirement after unlink stops undispatched key deletion and a new engine can finish recovery', async t => {
  const f = await secretsFixture(t), entered = deferred(), release = deferred();
  await f.request('write', { key: 'old', value: 'old' });
  f.change({ beforeUnlink: async () => { entered.resolve(); await release.promise; } });
  const recovering = f.request('recover', { confirmed: true }); await entered.promise;
  f.plugin.onDetachedFromEngine(f.engine); const next = f.attach();
  release.resolve(); assert.equal((await recovering).error, 'cancelled');
  assert.equal(f.events.filter(e => e.op === 'deleteKey').length, 0);
  assert.equal(f.keys.has(ownAlias), true);
  await assert.rejects(fs.access(f.vaultPath), { code: 'ENOENT' });
  f.change({ beforeUnlink: undefined });
  assert.deepEqual(await f.request('recover', { confirmed: true }, next.channel), { value: null });
  assert.equal(f.keys.has(ownAlias), false);
  next.plugin.onDetachedFromEngine(next.engine);
});

test('retirement during dispatched HUKS deletion cannot delete a new engine key after its queued write', async t => {
  const f = await secretsFixture(t), entered = deferred(), release = deferred();
  await f.request('write', { key: 'old', value: 'old' });
  f.change({ beforeDeleteKey: async () => { entered.resolve(); await release.promise; } });
  const recovering = f.request('recover', { confirmed: true }); await entered.promise;
  f.plugin.onDetachedFromEngine(f.engine); const next = f.attach();
  const writing = f.request('write', { key: 'new', value: 'retained' }, next.channel);
  release.resolve(); assert.equal((await recovering).error, 'cancelled');
  assert.deepEqual(await writing, { value: null });
  assert.deepEqual(await f.request('readAll', {}, next.channel), { value: { new: 'retained' } });
  assert.equal(f.events.filter(e => e.op === 'generate').length, 2);
  next.plugin.onDetachedFromEngine(next.engine);
});
