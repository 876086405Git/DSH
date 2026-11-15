// Runs as the final --import before the *real locked* DSH bin. It intentionally
// exits before the DSH CLI main: this is provider/preload integration, not an
// authenticated complete-App round.
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { writeSync } from 'node:fs';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { readPublicationCapabilities } from '../../ohos/publication/capabilities.mjs';

const config = JSON.parse(await fs.readFile(process.env.M6_FUSE_TEST_CONFIG, 'utf8'));
const send = value => writeSync(1, JSON.stringify(value) + '\n');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const service = globalThis[Symbol.for('dsh.go.ohos.publication')];
const observed = globalThis[Symbol.for('dsh.go.ohos.fuse.test')];
assert.equal(process.versions.node, '24.22.1');
assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
assert.equal(process.platform, 'openharmony', 'real provider must select its OH publication branch in both modes');
assert.equal(service?.protocolVersion, 1);
assert(globalThis[Symbol.for('dsh.go.ohos.net')]?.globalDispatcherApi, 'the real product network bootstrap must finish first');
if (config.mode === 'strict') {
  assert(process.execArgv.includes('--jitless'));
  assert.equal(process.platform, 'openharmony');
  assert.equal(typeof WebAssembly, 'undefined');
  assert.throws(() => spawn(process.execPath, ['-e', '0']), { code: 'ERR_OHOS_NO_SPAWN' });
  assert.throws(() => process.dlopen({ exports: {} }, '/no-fuse-addon.node'), { code: 'ERR_OHOS_SIM_DLOPEN' });
  await assert.rejects(fs.link('/no-fuse-source', '/no-fuse-target'), { code: 'EACCES' });
}
function snapshot() {
  const before = observed.state(), calls = observed.wrapperCalls, realCalls = observed.realNativeCalls;
  const atomic = service.atomic, capability = readPublicationCapabilities();
  assert(Object.isFrozen(service), 'publication service must be read-only');
  for (let i = 0; i < 20; i++) {
    const again = readPublicationCapabilities();
    assert.deepEqual(again, capability);
    assert.notStrictEqual(again, capability);
    assert(Object.isFrozen(again)); assert(Object.isFrozen(again.publication));
  }
  assert.deepEqual(observed.state(), before, 'reading capabilities must not rewrite the persistent state');
  assert.equal(observed.wrapperCalls, calls, 'reading capabilities must not enter native rename');
  assert.equal(observed.realNativeCalls, realCalls);
  // The real production reader returns the structured O6 fragment. HTTP
  // authentication/serialization and Dart parsing remain separate gates.
  const publicationCapability = capability.publication;
  return { atomic: atomic ?? null, publicationCapability, ownerId: service.ownerId,
    systemVersion: service.systemVersion ?? null, recoverySummary: service.recoverySummary,
    state: before, wrapperCalls: calls, realNativeCalls: realCalls,
    capabilityReads: { count: 21, nativeCallsAdded: 0, persistentStateUnchanged: true } };
}
send({ type: 'startup', ...snapshot() });
const contexts = [];
try {
  if (config.operation === 'helper') {
    const provider = await import(pathToFileURL(config.moduleFile));
    for (const target of config.targets) {
      try {
        const result = await provider.publishOhosExclusive(config.source, target);
        send({ type: 'published', target, result, ...snapshot() });
      } catch (error) {
        send({ type: 'publication-error', target, name: error.name, code: error.code,
          message: error.message, ...snapshot() });
        if (!(config.allowedErrors ?? []).includes(error.code)) throw error;
      }
    }
  } else if (config.operation !== 'startup-only') {
    const require = createRequire(join(config.prefix, 'package.json'));
    const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
    const { Context } = await load('cordis');
    const ctx = new Context(); contexts.push(ctx);
    if (config.operation === 'attachment-public') {
      const { LocalAttachmentStore } = await load('dsh-attachment-local');
      await ctx.plugin(LocalAttachmentStore, { dshHome: config.data });
      const expected = await fs.readFile(config.source);
      const ref = await ctx.attachments.saveFile({ data: expected, name: '熔断重启.txt' });
      const chunks = []; for await (const chunk of ctx.attachments.readFileStream(ref)) chunks.push(chunk);
      const actual = Buffer.concat(chunks); assert.deepEqual(actual, expected);
      send({ type: 'public-consumer', operation: config.operation, ref, path: ctx.attachments.fileHostPath(ref),
        bytes: actual.length, sha256: hash(actual), ...snapshot() });
    } else if (config.operation === 'session-public') {
      const provider = await load('dsh-session-persistence-jsonl');
      await ctx.plugin(provider, { root: join(config.data, 'sessions'), compression: 'none' });
      const header = { id: 'fuse-restart-session', version: 4, createdAt: 1,
        isSeeded: false, delegationDepth: 0, cwd: config.data };
      const existing = await ctx.sessionPersistence.stat(header.id);
      if (!existing) {
        const created = await ctx.sessionPersistence.create(header); await created.flush(); await created.close();
      }
      const handle = await ctx.sessionPersistence.open(header.id, 'read');
      assert.deepEqual(handle.header, header); await handle.close();
      const listing = await ctx.sessionPersistence.list();
      assert.deepEqual(listing.map(row => row.header.id), [header.id]);
      const path = ctx.sessionPersistence.locate(header).path, bytes = await fs.readFile(path);
      send({ type: 'public-consumer', operation: config.operation, path, bytes: bytes.length,
        sha256: hash(bytes), header, existedAtStartup: !!existing, ...snapshot() });
    } else throw new Error(`unsupported test operation ${config.operation}`);
  }
  send({ type: 'done', ...snapshot() });
} catch (error) {
  send({ type: 'actor-error', name: error.name, code: error.code, message: error.message, stack: error.stack });
  process.exitCode = 1;
} finally {
  for (const ctx of contexts) await ctx.fiber.dispose();
}
process.exit(process.exitCode ?? 0);
