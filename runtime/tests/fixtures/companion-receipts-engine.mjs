// Owner-only integration fixture. Real boot, Factory, Session/JSONL, Domain,
// sandbox filesystem and Remote approval. The owner Peer and inputs are test data.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { cp, link, mkdir, readFile, realpath, stat, statfs, symlink, writeFile } from 'node:fs/promises';
import { isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

const runtime = fileURLToPath(new URL('../../', import.meta.url));
const bridgeSource = join(runtime, 'bridge/dsh-go-bridge');
const supported = new Set([0xef53n, 0x58465342n, 0x9123683en]);
const packages = ['dsh-app-boot', 'dsh-session', 'dsh-session-projection', 'dsh-agent',
  'dsh-system-prompt', 'dsh-llm', 'dsh-tools', 'dsh-tool-executor-native', 'dsh-agent-loop',
  'dsh-session-persistence-jsonl', 'dsh-session-persistence', 'dsh-session-format',
  'dsh-session-format-catalog', 'dsh-session-format-v3-to-v4', 'dsh-util-values', 'dsh-atomic-write', 'dsh-storage', 'dsh-storage-json', 'dsh-storage-domain',
  'dsh-sandbox-policy', 'dsh-sandbox', 'dsh-fs', 'dsh-fs-local', 'dsh-fs-sandbox', 'dsh-user-approval', 'dsh-typert-registry',
  'dsh-api-remote-access', 'dsh-api-gateway', 'dsh-api-remotes', 'dsh-client-connection'];
const raw = value => value?.[Symbol.for('cordis.original')] ?? value;
let environmentOwner;

export async function ownerPrerequisites() {
  if (process.platform !== 'linux') return { blocked: 'J requires its actual Linux anchored filesystem' };
  if (Number(process.versions.node.split('.')[0]) < 24) return { blocked: 'Use the repository Node 24 owner runtime' };
  const prefix = process.env.DSH_PREFIX, parent = process.env.COMPANION_J_OWNER_ROOT;
  if (!prefix || !parent || !isAbsolute(prefix) || !isAbsolute(parent))
    return { blocked: 'Set absolute DSH_PREFIX and COMPANION_J_OWNER_ROOT (an existing disposable-test parent)' };
  if (!(await stat(parent)).isDirectory()) return { blocked: 'COMPANION_J_OWNER_ROOT must be an existing directory' };
  const filesystem = await statfs(parent, { bigint: true });
  if (!supported.has(filesystem.type)) return { blocked: `Unsupported real filesystem 0x${filesystem.type.toString(16)}; no statfs override is permitted` };
  const target = process.env.COMPANION_TASK_TARGET ?? 'android';
  assert(['android', 'ohos'].includes(target), 'known prefix target');
  const pins = JSON.parse(await readFile(join(runtime, 'patches/pins.json'), 'utf8'));
  const lock = JSON.parse(await readFile(join(runtime, 'locks/dsh-0.2.2-rc.1/package-lock.json'), 'utf8'));
  const finals = new Map();
  for (const patch of pins.targetSets[target])
    for (const [path, value] of Object.entries(pins.patches[patch]['0.2.2-rc.1'] ?? {})) finals.set(path, value.after);
  const sources = [];
  for (const name of packages) {
    const relative = `node_modules/@deepseek-ai/${name}/lib/index.js`;
    const folder = join(prefix, 'node_modules/@deepseek-ai', name);
    let body, metadata;
    try {
      [body, metadata] = await Promise.all([readFile(join(prefix, relative)), readFile(join(folder, 'package.json'), 'utf8')]);
    } catch (error) {
      if (error.code === 'ENOENT') return { blocked: `Incomplete engine prefix: ${relative} or package.json is missing` };
      throw error;
    }
    assert.equal(JSON.parse(metadata).version, lock.packages[`node_modules/@deepseek-ai/${name}`].version, name);
    const sha256 = createHash('sha256').update(body).digest('hex');
    if (finals.has(relative)) assert.equal(sha256, finals.get(relative), `final ${target} patch identity: ${relative}`);
    sources.push({ path: relative, sha256, finalPatchChecked: finals.has(relative) });
  }
  return { prefix: resolve(prefix), parent: resolve(parent), target, filesystemType: filesystem.type.toString(16), sources };
}

export async function until(check, description, timeoutMs = 15000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    const value = await check();
    if (value) return value;
    await delay(5);
  }
  assert.fail(`Timed out: ${description}`);
}

async function stageBridge(fixtureHome, prefix) {
  const directory = join(fixtureHome, 'fixture-bridge');
  await mkdir(directory, { recursive: true });
  await cp(join(bridgeSource, 'lib'), join(directory, 'lib'), { recursive: true });
  await cp(join(bridgeSource, 'package.json'), join(directory, 'package.json'));
  const dependency = join(directory, 'node_modules');
  try { await symlink(join(prefix, 'node_modules'), dependency, 'dir'); }
  catch (error) {
    if (error.code !== 'EEXIST') throw error;
    assert.equal(await realpath(dependency), await realpath(join(prefix, 'node_modules')));
  }
  return directory;
}

export async function openReceiptHost({ prerequisite, fixtureHome, beforeTasks }) {
  assert.equal(environmentOwner, undefined, 'One temporary DSH_HOME owner per process');
  const token = {}; environmentOwner = token;
  const previousHome = process.env.DSH_HOME, previousFetch = globalThis.fetch;
  const counters = { modelCalls: [], networkCalls: [], creates: [], resumes: [], links: 0 };
  process.env.DSH_HOME = fixtureHome;
  globalThis.fetch = async (...args) => {
    counters.networkCalls.push(String(args[0]));
    throw new Error('No fetch is allowed in the model-free J engine fixture');
  };
  const restore = () => {
    globalThis.fetch = previousFetch;
    if (previousHome === undefined) delete process.env.DSH_HOME;
    else process.env.DSH_HOME = previousHome;
    if (environmentOwner === token) environmentOwner = undefined;
  };
  let ctx, store, peer, eventPump, closing;
  const eventLifetime = new AbortController(), frames = [];
  let eventFailure;
  const close = () => closing ??= (async () => {
    try { await store?.close(); }
    finally {
      eventLifetime.abort();
      try { await eventPump; await peer?.dispose(); }
      finally { try { await ctx?.fiber.dispose(); } finally { restore(); } }
    }
  })();
  try {
    await mkdir(join(fixtureHome, 'documents'), { recursive: true });
    const base = join(prerequisite.prefix, 'node_modules/@deepseek-ai');
    const load = name => import(pathToFileURL(join(base, name, 'lib/index.js')).href);
    const [{ boot }, agentModule, loopModule, sessionModule, approvalModule, gatewayModule, { Peer }] = await Promise.all([
      load('dsh-app-boot'), load('dsh-agent'), load('dsh-agent-loop'), load('dsh-session'),
      load('dsh-user-approval'), load('dsh-api-gateway'), load('dsh-client-connection')]);
    const staged = await stageBridge(fixtureHome, prerequisite.prefix);
    const loadBridge = name => import(pathToFileURL(join(staged, 'lib/companion', name)).href);
    const entry = (id, name, config = {}) => ({ id, name: pathToFileURL(join(base, name, 'lib/index.js')).href, config });
    const main = join(fixtureHome, 'owner-j-main.json');
    await writeFile(main, JSON.stringify([
      entry('sessions', 'dsh-session'), entry('projections', 'dsh-session-projection'),
      entry('agents', 'dsh-agent'), entry('prompt', 'dsh-system-prompt'), entry('llm', 'dsh-llm'),
      entry('tools', 'dsh-tools'), entry('native', 'dsh-tool-executor-native'), entry('loop', 'dsh-agent-loop', { agents: [] }),
      entry('jsonl', 'dsh-session-persistence-jsonl', { root: join(fixtureHome, 'jsonl'), compression: 'none', listConcurrency: 1 }),
      entry('storage', 'dsh-storage'), entry('storage-json', 'dsh-storage-json', { root: join(fixtureHome, 'storage') }),
      entry('domains', 'dsh-storage-domain', { backend: 'json' }),
      entry('policy', 'dsh-sandbox-policy', { mode: 'read-only', workspaceRoot: join(fixtureHome, 'documents') }),
      entry('fs', 'dsh-fs-sandbox', { cwd: fixtureHome }), entry('approval', 'dsh-user-approval', { policy: 'ask' }),
      entry('typert', 'dsh-typert-registry'), entry('access', 'dsh-api-remote-access'),
      entry('gateway', 'dsh-api-gateway'), entry('remotes', 'dsh-api-remotes'),
    ]));
    ctx = await boot('dsh', main, [], host => {
      host.provide('profileContext', { dir: fixtureHome, installAnchor: join(base, 'dsh-session/package.json') });
    });
    assert(raw(ctx.agents) instanceof agentModule.AgentRegistry);
    assert(raw(ctx.agentLoop) instanceof loopModule.AgentLoop);
    assert(raw(ctx.sessions) instanceof sessionModule.SessionStore);
    assert(raw(ctx.approval) instanceof approvalModule.ApprovalService);
    assert(raw(ctx.typertGateway) instanceof gatewayModule.TypertGatewayService);
    assert(ctx.get('sessionPersistence'), 'Real JSONL service mounted');
    assert.deepEqual(ctx.llm.listProviders(), [], 'No adapter is configured');
    assert.equal(ctx.get('agentDefaultModel'), undefined, 'No default model service is installed');
    for (const method of ['prepareCall', 'stream']) {
      const service = raw(ctx.llm), original = service[method];
      assert.equal(typeof original, 'function');
      service[method] = function (...args) {
        counters.modelCalls.push(method);
        return Reflect.apply(original, this, args);
      };
    }
    for (const method of ['create', 'resume']) {
      const service = raw(ctx.agents), original = service[method];
      service[method] = function (options) {
        counters[method === 'create' ? 'creates' : 'resumes'].push({ sessionId: options.sessionId,
          resumeSessionId: options.resumeSessionId, agentOptions: structuredClone(options.agentOptions) });
        return Reflect.apply(original, this, [options]);
      };
    }
    const filesystem = raw(ctx.fs);
    filesystem.internals.linkFile = async (...args) => { counters.links++; return link(...args); };
    await beforeTasks?.(filesystem);
    peer = new Peer(ctx, { principal: { kind: 'owner' }, interactions: 'answer' });
    const stream = await ctx.typertGateway.wireStream.open('$events', { args: {} }, undefined, peer, eventLifetime.signal);
    const iterator = stream[Symbol.asyncIterator]();
    const opening = await iterator.next();
    assert.equal(opening.done, false); assert.equal(opening.value.type, 'ready');
    const clientId = opening.value.clientId;
    eventPump = (async () => {
      for (;;) {
        const value = await iterator.next();
        if (value.done) return;
        frames.push(value.value);
      }
    })().catch(error => { if (!eventLifetime.signal.aborted) eventFailure = error; });
    const { mountCompanionTasks } = await loadBridge('task-service.js');
    mountCompanionTasks(ctx);
    store = await until(() => ctx.get('dshGoCompanionTasks'), 'production J task service mounted');
    assert(store.runner.kinds.includes('host.receipts_to_sheet'));
    return { ctx, store, frames, counters, fixtureHome, close, loadBridge,
      checkEvents() { if (eventFailure) throw eventFailure; },
      async answer(frame, value) {
        const result = await ctx.typertGateway.dispatchRpc('$events/result',
          { args: { clientId, eventId: frame.eventId, outcome: { kind: 'result', value } } }, eventLifetime.signal, peer);
        assert.equal(result.ok, true, JSON.stringify(result));
      },
      async persisted(agentId) {
        const reader = await ctx.sessionPersistence.open(agentId, 'read');
        try { return await reader.read(); } finally { await reader.close(); }
      },
    };
  } catch (error) {
    await close();
    throw error;
  }
}

export async function createReceiptTask(host, taskId) {
  const directory = join(host.fixtureHome, 'documents');
  const folder = await host.store.bindFolder({ v: 1, hostStoreId: host.store.hostStoreId, path: directory });
  const inputs = [];
  for (let i = 0; i < 4; i++) {
    const name = `receipt-${i + 1}.txt`;
    await writeFile(join(directory, name), `Date: 2026-11-${20 + i}\nItem: Travel ${i + 1}\nAmount: CNY ${80 + i}.00\n`);
    inputs.push(await host.store.bindInput({ v: 1, hostStoreId: host.store.hostStoreId,
      kind: 'host.receipts_to_sheet', folderRef: folder.folderRef, name }));
  }
  const body = { v: 1, hostStoreId: host.store.hostStoreId, taskId, taskRev: 1, kind: 'host.receipts_to_sheet',
    origin: { sourceSessionId: 'light:owner-j-engine', messageId: `command-${taskId}`, itemNo: 0 }, hostSessionId: null,
    args: { inputs: inputs.map(({ sourceRef, version }) => ({ sourceRef, version })), outputDirRef: folder.folderRef,
      outputName: `${taskId}.xlsx`, writeMode: 'createNew' }, deadlineAtMs: null, afterExit: 'continue', allowQueue: true };
  const result = await host.store.create(body); assert.equal(result.created, true);
  return body;
}
