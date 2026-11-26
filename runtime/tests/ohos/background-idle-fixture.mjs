import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash, randomUUID } from 'node:crypto';

const require = createRequire(import.meta.url);
const buildRequire = createRequire(path.join(path.resolve(process.env.DSH_BACKGROUND_BUILD_TOOLS), 'package.json'));
const esbuild = buildRequire('esbuild');
if (esbuild.version !== '0.27.3') throw new Error('The locked esbuild 0.27.3 is required');
const source = path.resolve(process.env.DSH_BACKGROUND_SOURCE);
const nativeAddon = require(path.resolve(process.env.DSH_BACKGROUND_NATIVE));
const runtime = path.join(source, 'app/ohos/entry/src/main/ets/runtime');
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'ohos-background-idle-'));
export const trace = [];
export const flush = () => new Promise(setImmediate);
let now = 10000, nextTimer = 1;
export const localDate = { now: () => now };
export const linuxBoundary = { shutdown: null, calls: 0 };
export const timers = new Map();
const installTimer = (callback, delay, interval) => {
  if (!(Number.isFinite(delay) && delay >= 0)) throw new Error('invalid fixture timer delay');
  const id = nextTimer++; timers.set(id, { callback, delay, due: now + delay, interval }); return id;
};
export const localSetTimeout = (fn, delay) => installTimer(fn, delay, false);
export const localClearTimeout = id => timers.delete(id);
export const localSetInterval = (fn, delay) => installTimer(fn, delay, true);
export const localClearInterval = id => timers.delete(id);
export async function advance(delta) {
  const end = now + delta; let deliveries = 0;
  for (;;) {
    const candidate = [...timers.entries()].filter(([, timer]) => timer.due <= end).sort((a, b) => a[1].due - b[1].due || a[0] - b[0])[0];
    if (!candidate) break;
    if (++deliveries > 10000) throw new Error('fixture timer limit');
    const [id, timer] = candidate; now = timer.due; nativeAddon.setNow(now);
    if (timer.interval) timer.due += timer.delay; else timers.delete(id);
    trace.push({ kind: 'timer', id, now, interval: timer.interval, delay: timer.delay });
    timer.callback(); await flush();
  }
  now = end; nativeAddon.setNow(now); await flush(); return deliveries;
}

export const native = {
  state: {}, events: [], stops: 0,
  reset() {
    now = 10000; nextTimer = 1; timers.clear(); trace.length = 0; nativeAddon.reset(now);
    this.state = { phase: 'idle', consumed: false, baseUrl: null, token: null, exitCode: null, errorCode: null, errorMessage: null };
    this.events = []; this.stops = 0;
  },
  getState() { return { ...native.state }; },
  drainEvents() { return native.events.splice(0); },
  lifecycleSnapshot() { return nativeAddon.lifecycleSnapshot(); },
  lifecycleUpdate(operation, owner, grant, value) {
    const answer = nativeAddon.lifecycleUpdate(operation, owner, grant, value);
    trace.push({ kind: 'native-update', operation, owner, grant, value, answer, state: nativeAddon.lifecycleSnapshot() });
    return answer;
  },
  stop() { native.stops++; native.state.phase = 'stopping'; },
};
export const nativeHostState = () => native.getState();
export const peekNativeHost = () => native;
export const nativeHostTouched = () => true;
export const loadNativeHost = async () => native;
export const configureNativeRecovery = () => {};

export const osBoundary = { allowed: true, requested: [], stopped: [], listeners: new Map(), startDeferred: null, stopError: false, nextId: 73 };
export const backgroundTaskManager = {
  BackgroundTaskMode: { MODE_TASK_KEEPING: 9 }, ContinuousTaskRequest: class {},
  on(type, callback) { let list = osBoundary.listeners.get(type); if (!list) osBoundary.listeners.set(type, list = new Set()); list.add(callback); },
  off(type, callback) { osBoundary.listeners.get(type)?.delete(callback); },
  async startBackgroundRunning(context, request) {
    const id = osBoundary.nextId++; osBoundary.requested.push({ id, context, modes: request.backgroundTaskModes });
    trace.push({ kind: 'os-start', id });
    return osBoundary.startDeferred ? await osBoundary.startDeferred.promise : { continuousTaskId: id, notificationId: id + 100 };
  },
  async stopBackgroundRunning(context, id) {
    osBoundary.stopped.push({ id, context }); trace.push({ kind: 'os-stop', id, native: native.lifecycleSnapshot() });
    if (osBoundary.stopError) throw new Error('injected OS stop failure');
    trace.push({ kind: 'os-stop-complete', id });
  },
  requestSuspendDelay() { throw new Error('short grant is outside these continuous-owner cases'); },
  cancelSuspendDelay(id) { trace.push({ kind: 'os-short-cancel', id }); },
};
export const wantAgent = { OperationType: { START_ABILITY: 0 }, WantAgentFlags: { CONSTANT_FLAG: 0 }, async getWantAgent(value) { return value; } };
export const backgroundComputePermission = () => osBoundary.allowed ? 'granted' : 'denied';
export const agentReminderAccess = () => 'denied';
export const wire = { busy: false, manualPaused: false, sends: [], cancels: 0, failure: null, alterAck: null };
export class OhosLifecycleTransport {
  async send(baseUrl, token, observation) {
    const row = { baseUrl, token, observation: { ...observation }, at: now };
    wire.sends.push(row); trace.push({ kind: 'transport-send', ...row });
    if (wire.failure) throw wire.failure;
    const ack = { nativeHost: native.lifecycleSnapshot(), busy: wire.busy, manualPaused: wire.manualPaused, confirmedPause: native.lifecycleSnapshot().foreground === 0 };
    wire.alterAck?.(ack); row.ack = structuredClone(ack); return ack;
  }
  cancel() { wire.cancels++; }
}

// These constructors isolate unrelated installation/storage/managed-skill work.
// Their methods fail if a test accidentally enters that work; no installation is claimed.
export class OhosRuntimeStorage { constructor() {} }
export class OhosRecoveryStorage { constructor() {} }
export class OhosLastKnownGoodStorage { constructor() {} }
export class ManagedSkillService { ready() {} stop() {} retire() {} generationFor() { return null; } }
export class LinuxControl { shutdown(...args) { linuxBoundary.calls++; if (!linuxBoundary.shutdown) throw new Error('Linux shutdown not exercised by this fixture'); return linuxBoundary.shutdown(...args); } }
export class PersistedRuntimeLog {
  static get() { return new PersistedRuntimeLog(); }
  append(rows) { trace.push({ kind: 'persist-log', count: rows.length }); }
  async flush() {}
}
export const util = { generateRandomUUID: randomUUID };
export const connection = {};
export const hilog = { info() {}, warn() {} };

const imported = [];
const removeImports = text => {
  const removed = [];
  const body = text.replace(/^import\b[\s\S]*?;\r?\n/gm, value => { removed.push(value); return ''; });
  return { removed, body };
};
const writeModule = async (name, imports) => {
  const original = await fs.readFile(path.join(runtime, name + '.ets'), 'utf8');
  const { removed, body } = removeImports(original);
  const generated = imports.replaceAll('.mts', '.mjs') + '\n' + body;
  const transformed = await esbuild.transform(generated, { loader: 'ts', format: 'esm', target: 'es2022',
    tsconfigRaw: { compilerOptions: { useDefineForClassFields: true } }, sourcefile: name + '.ets' });
  const out = path.join(root, name + '.mjs'); await fs.writeFile(out, transformed.code);
  imported.push({ name, source: path.join(runtime, name + '.ets'), sourceSha256: hash(original), bodySha256: hash(body), removedImports: removed,
    generatedTypedSha256: hash(generated), generatedJsSha256: hash(transformed.code), esbuildVersion: esbuild.version,
    adaptation: 'leading imports only before locked TypeScript erasure; unchanged original product method bodies are separately hashed' });
  return pathToFileURL(out).href;
};
const hash = value => createHash('sha256').update(value).digest('hex');
const fixture = import.meta.url;
export let RuntimeController, TransientTaskOwner, RuntimeLifecycle;
export async function loadModules() {
await writeModule('RuntimeCore', '');
await writeModule('RuntimePaths', '');
await writeModule('RuntimeRecovery', "import { RuntimeChannelError } from './RuntimeCore.mts';");
await writeModule('RuntimeLastKnownGood', "import { RuntimeChannelError } from './RuntimeCore.mts';");
await writeModule('RuntimeLifecycle', `import { localSetTimeout as setTimeout, localClearTimeout as clearTimeout } from '${fixture}';`);
await writeModule('ContinuousTaskOwner', `import { backgroundTaskManager, wantAgent, backgroundComputePermission, localSetTimeout as setTimeout } from '${fixture}';`);
await writeModule('TransientTaskOwner', `import { ContinuousTaskOwner } from './ContinuousTaskOwner.mts';\nimport { backgroundTaskManager, localSetTimeout as setTimeout, localClearTimeout as clearTimeout } from '${fixture}';`);
const controllerUrl = await writeModule('RuntimeController', `
import { RuntimeChannelError, RuntimeInstaller, RuntimeLogs, validateEnvironment, validateStartOptions, resolveNativeLibraryDir } from './RuntimeCore.mts';
import { RuntimePaths } from './RuntimePaths.mts';
import { RuntimeRecovery } from './RuntimeRecovery.mts';
import { RuntimeLastKnownGood } from './RuntimeLastKnownGood.mts';
import { RuntimeLifecycle } from './RuntimeLifecycle.mts';
import { TransientTaskOwner } from './TransientTaskOwner.mts';
import { nativeHostState, peekNativeHost, nativeHostTouched, loadNativeHost, configureNativeRecovery,
  OhosRuntimeStorage, OhosRecoveryStorage, OhosLastKnownGoodStorage, ManagedSkillService, LinuxControl, PersistedRuntimeLog,
  OhosLifecycleTransport, backgroundComputePermission, agentReminderAccess, util, connection, hilog,
  localSetInterval as setInterval, localClearInterval as clearInterval,
  localSetTimeout as setTimeout, localClearTimeout as clearTimeout, localDate as Date } from '${fixture}';
`);
({ RuntimeController } = await import(controllerUrl));
({ TransientTaskOwner } = await import(pathToFileURL(path.join(root, 'TransientTaskOwner.mjs'))));
({ RuntimeLifecycle } = await import(pathToFileURL(path.join(root, 'RuntimeLifecycle.mjs'))));
}
export const moduleIdentity = imported;
export const plain = value => value instanceof Map ? Object.fromEntries([...value].map(([key, item]) => [key, plain(item)]))
  : Array.isArray(value) ? value.map(plain) : value && typeof value === 'object' ? Object.fromEntries(Object.entries(value).map(([key, item]) => [key, plain(item)])) : value;

export async function setup({ taskEnabled = false } = {}) {
  native.reset(); linuxBoundary.shutdown = null; linuxBoundary.calls = 0;
  Object.assign(osBoundary, { allowed: true, requested: [], stopped: [], listeners: new Map(), startDeferred: null, stopError: false, nextId: 73 });
  Object.assign(wire, { busy: false, manualPaused: false, sends: [], cancels: 0, failure: null, alterAck: null });
  RuntimeController.shared = null; RuntimeController.foreground = true;
  const context = { filesDir: '/test-only/background-idle', cacheDir: '/test-only/background-idle-cache',
    applicationInfo: { accessTokenId: 1, name: 'fixture.dsh' }, abilityInfo: { name: 'EntryAbility' } };
  const ability = { context }; RuntimeController.ability = ability;
  const controller = new RuntimeController(context); RuntimeController.shared = controller;
  // Ready is a platform boundary input. No install/start/guest is exercised.
  controller.initialized = Promise.resolve();
  Object.assign(native.state, { phase: 'running', consumed: true, baseUrl: 'http://127.0.0.1:3080', token: 'private-fixture-token' });
  controller.runtimeGeneration = 1; controller.bindOwner();
  // Model the persisted user opt-in without opening the preferences service.
  controller.applyTaskEnabled(taskEnabled);
  controller.collect(); await flush();
  const events = []; controller.sinks.push(event => { const record = plain(event); events.push(record); trace.push({ kind: 'controller-event', event: record }); });
  return { controller, ability, events, async background() { RuntimeController.onBackground(ability); await flush(); },
    async observe() { controller.lifecycle.observe(RuntimeController.foreground); await flush(); },
    async close() { controller.retireOwner(); native.state.phase = 'idle'; controller.collect(); await flush(); timers.clear(); RuntimeController.shared = null; RuntimeController.ability = null; } };
}
export async function saveCase(name, value) {
  const output = path.resolve(process.env.DSH_BACKGROUND_RECORDS); await fs.mkdir(output, { recursive: true });
  await fs.writeFile(path.join(output, name + '.json'), JSON.stringify({
    scope: 'unchanged ETS logic + actual product LifecycleState; deterministic clock/timer, OS/transport and ready boundaries; no installation, OH SDK or real network claim',
    name, value, native: native.lifecycleSnapshot(), trace: structuredClone(trace), modules: moduleIdentity,
  }, null, 2) + '\n');
}
export async function closeModules() { await fs.rm(root, { recursive: true, force: true }); }
