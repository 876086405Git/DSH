import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { basename, dirname, join, resolve } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { createInterface } from 'node:readline';
import { spawn } from 'node:child_process';

const scenario = process.argv[2];
assert(['session-none', 'session-zstd', 'attachment-files'].includes(scenario));
const strict = process.env.DSH_SCANNER_STRICT === '1';
assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
assert.equal(globalThis[Symbol.for('dsh.go.ohos.publication')]?.protocolVersion, 1);
if (strict) {
  assert.equal(process.platform, 'openharmony');
  assert.equal(typeof WebAssembly, 'undefined');
  assert.throws(() => spawn(process.execPath, ['-e', '0']), { code: 'ERR_OHOS_SIM_SPAWN' });
  assert.throws(() => process.dlopen({ exports: {} }, '/no-scanner-addon.node'), { code: 'ERR_OHOS_SIM_DLOPEN' });
  await assert.rejects(fs.link('/no-scanner-source', '/no-scanner-target'), { code: 'EACCES' });
}
const require = createRequire(join(resolve(process.env.DSH_TEST_PREFIX), 'package.json'));
const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
const { Context } = await load('cordis');
const sessions = await load('dsh-session-persistence-jsonl');
const { LocalAttachmentStore } = await load('dsh-attachment-local');
const root = await fs.mkdtemp(join(process.env.DSH_HOME, 'scanner-fixture-'));
const contexts = [], watched = [], originalOrphanHashes = new Map();
const lineReader = createInterface({ input: process.stdin, crlfDelay: Infinity });
const commands = lineReader[Symbol.asyncIterator]();
const send = message => process.stdout.write(JSON.stringify(message) + '\n');
const command = async expected => {
  const item = await commands.next(); assert.equal(item.done, false); assert.equal(item.value, expected);
};
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const tempName = () => `.dsh-ohos-publish-${randomUUID()}.tmp`;
async function orphan(parent, bytes, label) {
  await fs.mkdir(parent, { recursive: true });
  const path = join(parent, tempName()); await fs.writeFile(path, bytes, { flag: 'wx' });
  watched.push({ path, kind: 'orphan', label, bytes: bytes.length }); originalOrphanHashes.set(path, hash(bytes)); return path;
}
async function sessionContext(compression) {
  const ctx = new Context(); contexts.push(ctx);
  await ctx.plugin(sessions, { root: join(root, 'sessions'), compression }); return ctx;
}
async function attachmentContext() {
  const ctx = new Context(); contexts.push(ctx);
  await ctx.plugin(LocalAttachmentStore, { dshHome: root }); return ctx;
}
async function readAttachment(store, ref) {
  const chunks = []; for await (const chunk of store.readFileStream(ref)) chunks.push(chunk); return Buffer.concat(chunks);
}

try {
  let scan, controls;
  if (scenario.startsWith('session-')) {
    const compression = scenario.slice('session-'.length);
    const ctx = await sessionContext(compression);
    const header = id => ({ id, version: 4, createdAt: Date.now(), isSeeded: false, delegationDepth: 0, cwd: root });
    const realHeader = header('real-session'), hiddenHeader = header('hidden-session');
    for (const value of [realHeader, hiddenHeader]) {
      const handle = await ctx.sessionPersistence.create(value); await handle.flush(); await handle.close();
    }
    const realPath = ctx.sessionPersistence.locate(realHeader).path;
    const hiddenPath = ctx.sessionPersistence.locate(hiddenHeader).path;
    await ctx.fiber.dispose();
    const hiddenBytes = await fs.readFile(hiddenPath), movedPath = join(dirname(hiddenPath), tempName());
    await fs.rename(hiddenPath, movedPath);
    watched.push({ path: movedPath, kind: 'orphan', label: 'valid-generation-under-temporary-name', bytes: hiddenBytes.length });
    originalOrphanHashes.set(movedPath, hash(hiddenBytes));
    await orphan(dirname(realPath), Buffer.alloc(0), 'zero-byte-in-real-session');
    await orphan(dirname(realPath), Buffer.from('{"type":"header",'), 'partial-json-in-real-session');
    await orphan(dirname(dirname(realPath)), Buffer.from('not a session\n'), 'project-level-file');
    await orphan(join(root, 'sessions'), Buffer.from([0x28, 0xb5, 0x2f, 0xfd, 0xff]), 'root-level-file');
    watched.push({ path: realPath, kind: 'canonical', label: 'real-generation', bytes: (await fs.stat(realPath)).size });
    let cold;
    scan = async () => {
      cold = await sessionContext(compression); const store = cold.sessionPersistence, selected = [];
      const original = store.readGenerationHeader.bind(store);
      store.readGenerationHeader = (...args) => { selected.push(args[0].sourcePath); return original(...args); };
      const listing = await store.list(); assert.deepEqual(listing.map(x => x.header.id).sort(), ['real-session']);
      assert.equal((await store.stat('real-session')).header.id, 'real-session');
      assert.equal(await store.stat('hidden-session'), undefined);
      const handle = await store.open('real-session', 'read'); assert.equal(handle.header.id, 'real-session'); await handle.close();
      await assert.rejects(store.open('hidden-session', 'read'), { name: 'SessionPersistenceNotFoundError' });
      assert(selected.length > 0); assert(selected.every(path => path === realPath));
      return { compression, listedIds: listing.map(x => x.header.id), selectedHeaderPaths: selected,
        hiddenGenerationAbsent: true, actualPublicOpenSucceeded: true };
    };
    controls = async () => {
      await fs.rename(movedPath, hiddenPath);
      const listing = await cold.sessionPersistence.list();
      assert.deepEqual(listing.map(x => x.header.id).sort(), ['hidden-session', 'real-session']);
      return { restoredCanonicalGenerationIsListed: true, listedIds: listing.map(x => x.header.id) };
    };
  } else {
    const ctx = await attachmentContext();
    const realBytes = Buffer.alloc(131081, 65), hiddenBytes = Buffer.from('valid hidden attachment'), namedBytes = Buffer.from('legitimate user name');
    const realRef = await ctx.attachments.saveFile({ data: realBytes, name: 'real.txt' });
    const hiddenRef = await ctx.attachments.saveFile({ data: hiddenBytes, name: 'hidden.txt' });
    const namedRef = await ctx.attachments.saveFile({ data: namedBytes, name: tempName() });
    const realPath = ctx.attachments.fileHostPath(realRef), hiddenPath = ctx.attachments.fileHostPath(hiddenRef), namedPath = ctx.attachments.fileHostPath(namedRef);
    assert(basename(namedPath).startsWith('.dsh-ohos-publish-'));
    await ctx.fiber.dispose();
    const movedPath = join(dirname(hiddenPath), tempName()); await fs.rename(hiddenPath, movedPath);
    watched.push({ path: movedPath, kind: 'orphan', label: 'valid-file-alias-under-temporary-name', bytes: hiddenBytes.length });
    originalOrphanHashes.set(movedPath, hash(hiddenBytes));
    await orphan(dirname(realPath), Buffer.alloc(0), 'zero-byte-alongside-valid-alias');
    await orphan(join(root, 'attachments/v1/file-objects/ff'), Buffer.from('partial canonical object'), 'file-object-shard');
    await orphan(join(root, 'attachments/v1/objects/ee'), Buffer.from('not an image'), 'image-object-shard');
    await orphan(join(root, 'attachments/v1'), Buffer.from('unregistered root orphan'), 'attachment-root');
    watched.push({ path: realPath, kind: 'canonical', label: 'referenced-file-alias', bytes: realBytes.length });
    watched.push({ path: namedPath, kind: 'canonical', label: 'legitimate-temporary-shaped-user-filename', bytes: namedBytes.length });
    let cold;
    scan = async () => {
      cold = await attachmentContext(); const store = cold.attachments;
      assert.deepEqual(await readAttachment(store, realRef), realBytes);
      assert.deepEqual(await readAttachment(store, namedRef), namedBytes);
      await assert.rejects(readAttachment(store, hiddenRef), { code: 'ATTACHMENT_NOT_FOUND' });
      assert.equal(store.fileHostPath(hiddenRef), hiddenPath);
      return { referencedFileRead: true, legitimateTemporaryShapedNameRead: true,
        missingReferencedAliasDoesNotSearchTemporaryFiles: true,
        scope: 'real public file-attachment service; no invented directory scanner or image decoder claim' };
    };
    controls = async () => {
      await fs.rename(movedPath, hiddenPath);
      assert.deepEqual(await readAttachment(cold.attachments, hiddenRef), hiddenBytes);
      return { restoredReferencedAliasIsReadable: true };
    };
  }
  send({ stage: 'ready', scenario, strict, node: process.version, platform: process.platform, watched });
  await command('scan');
  const result = await scan();
  send({ stage: 'scanned', result });
  await command('positive');
  for (const entry of watched.filter(x => x.kind === 'orphan')) {
    assert.equal(hash(await fs.readFile(entry.path)), originalOrphanHashes.get(entry.path));
  }
  send({ stage: 'positive', allOrphansUnchangedAndExplicitlyRead: true });
  await command('controls');
  send({ stage: 'done', controls: await controls() });
} finally {
  lineReader.close(); process.stdin.destroy();
  for (const ctx of contexts) await ctx.fiber.dispose();
  await fs.rm(root, { recursive: true, force: true });
}
