// Executes the actual ETS after TypeScript erasure. Crypto and persistence are
// real Node HMAC/SHA256 and private Linux files; OS/Flutter remain test doubles.
import assert from 'node:assert/strict';
import { createHash, createHmac, randomBytes } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const prefix = process.env.OHOS_TYPESCRIPT_PREFIX;
assert(prefix, 'Set OHOS_TYPESCRIPT_PREFIX to the locked process npm-ci directory');
const ts = createRequire(resolve(prefix, 'package.json'))('typescript');
const source = process.env.OHOS_NOTIFY_SOURCE || new URL('../../../app/ohos/entry/src/main/ets/plugins/NotifyPlugin.ets', import.meta.url);
const compiled = ts.transpileModule(readFileSync(source, 'utf8'), { compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
} });
const plain = value => Object.prototype.toString.call(value) === '[object Map]' ? Object.fromEntries(value) : value;
const clone = value => JSON.parse(JSON.stringify(value));
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const post = { group: 'local:本机|会话一', key: 'turn', sessionId: '会话一', host: 'local:', kind: 'done',
  publicText: '一轮对话已结束', title: '私密标题', text: 'private-body-secret', fullText: 'private-full-secret' };

function fixture(t, { directory, hooks = {}, launchWant = {} } = {}) {
  const root = directory || mkdtempSync(join(tmpdir(), 'dsh-notify-'));
  if (!directory) t.after(() => rmSync(root, { recursive: true, force: true }));
  const storeFile = join(root, 'preferences.json');
  let cache = existsSync(storeFile) ? JSON.parse(readFileSync(storeFile, 'utf8')) : {};
  const channels = [], calls = [], agents = [], published = [], active = new Map(), listeners = new Set(), warnings = [];
  const state = { enabled: true, slot: { enabled: true, notificationLevel: 3 }, flushes: 0 };
  const store = {
    async get(key, fallback) { return cache[key] ?? fallback; },
    async put(key, value) { cache[key] = value; },
    async flush() {
      state.flushes++;
      await hooks.flush?.(state.flushes);
      writeFileSync(storeFile + '.tmp', JSON.stringify(cache), { mode: 0o600 });
      renameSync(storeFile + '.tmp', storeFile);
    },
  };
  class Channel {
    constructor(_messenger, name) { this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    setStreamHandler(handler) { assert.notEqual(handler, null); this.stream = handler; }
  }
  const notification = {
    SlotType: { SERVICE_INFORMATION: 2 }, SlotLevel: { LEVEL_NONE: 0 }, ContentType: { NOTIFICATION_CONTENT_BASIC_TEXT: 0 },
    async isNotificationEnabled() { calls.push('enabled'); await hooks.permission?.(); return state.enabled; },
    async getSlot(type) { assert.equal(type, 2); calls.push('getSlot'); await hooks.slot?.(); return state.slot; },
    async addSlot(type) { assert.equal(type, 2); calls.push('addSlot'); state.slot = { enabled: true, notificationLevel: 3 }; },
    async publish(request) {
      calls.push('publish:start'); await hooks.publish?.(request);
      published.push(request); active.set(request.id + ':' + request.label, request); calls.push('publish:done');
    },
    async cancel(id, label) { calls.push('cancel:' + label); active.delete(id + ':' + label); },
    async cancelGroup(group) { calls.push('cancelGroup:' + group); for (const [key, value] of active) if (value.groupName === group) active.delete(key); },
    async getActiveNotifications() { calls.push('getActive'); return [...active.values()]; },
    async openNotificationSettingsWithResult(context) { assert.equal(context, ability.context); calls.push('settings'); await hooks.settings?.(); return { vibrationEnabled: true, soundEnabled: true }; },
    async requestEnableNotification(context) { assert.equal(context, ability.context); calls.push('request'); await hooks.request?.(); },
  };
  const symKey = bytes => ({ bytes: Buffer.from(bytes), getEncoded: () => ({ data: new Uint8Array(bytes) }) });
  const crypto = {
    createMd(algorithm) {
      assert.equal(algorithm, 'SHA256'); const chunks = [];
      return { async update(blob) { chunks.push(Buffer.from(blob.data)); }, async digest() {
        const bytes = Buffer.concat(chunks); await hooks.digest?.(bytes.toString());
        return { data: new Uint8Array(createHash('sha256').update(bytes).digest()) };
      } };
    },
    createSymKeyGenerator(algorithm) {
      assert.equal(algorithm, 'HMAC|SHA256');
      return { async generateSymKey() { return symKey(randomBytes(32)); }, async convertKey(blob) { return symKey(blob.data); } };
    },
    createMac(algorithm) {
      assert.equal(algorithm, 'SHA256'); let key; const chunks = [];
      return { async init(value) { key = value.bytes; }, async update(blob) { chunks.push(Buffer.from(blob.data)); }, async doFinal() {
        const bytes = Buffer.concat(chunks); await hooks.mac?.(bytes.toString());
        return { data: new Uint8Array(createHmac('sha256', key).update(bytes).digest()) };
      } };
    },
  };
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, {
    module, exports: module.exports,
    require(name) {
      if (name === '@ohos.notificationManager') return { default: notification };
      if (name === '@ohos.app.ability.wantAgent') return { default: {
        OperationType: { START_ABILITY: 2 }, WantAgentFlags: { CONSTANT_FLAG: 3 },
        async getWantAgent(info) { calls.push('wantAgent'); agents.push(info); await hooks.agent?.(info); return { agentId: agents.length }; },
      } };
      if (name === '@ohos.data.preferences') return { default: { async getPreferences(context, options) {
        assert.equal(context, application); assert.equal(options.name, 'dsh-notify'); return store;
      } } };
      if (name === '@ohos.security.cryptoFramework') return { default: crypto };
      if (name === '@ohos.util') return { default: { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } } };
      if (name === '@ohos.hilog') return { default: { warn(...args) { warnings.push(args); } } };
      if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel, EventChannel: Channel };
      throw new Error('Unexpected runtime import ' + name);
    },
  });
  const application = { filesDir: root };
  const messenger = { removed: [], setMessageHandler(name, handler) { assert.equal(handler, null); this.removed.push(name); } };
  const engine = { getApplicationContext: () => application, getBinaryMessenger: () => messenger };
  const ability = { launchWant, context: { abilityInfo: { bundleName: 'io.github.ccch1mneyyy.dsh_app', name: 'EntryAbility' } } };
  const binding = { getAbility: () => ability, addOnNewWantListener: x => listeners.add(x), removeOnNewWantListener: x => listeners.delete(x) };
  const Plugin = module.exports.default;
  const make = () => { const value = new Plugin(); value.onAttachedToEngine(engine); return value; };
  const plugin = make();
  function channel(name = 'dsh/notify') { return channels.filter(x => x.name === name).at(-1); }
  function call(method, args = {}) {
    const handler = channel().handler; assert(handler, 'method channel attached');
    return new Promise(resolve => handler.onMethodCall({ method, argument: key => args[key] }, {
      success: value => resolve({ value: plain(value) }), error: (code, message) => resolve({ error: code, message }), notImplemented: () => resolve({ missing: true }),
    }));
  }
  function listen(name = 'dsh/notify/taps') {
    const result = { values: [], errors: [], ended: 0 };
    channel(name).stream.onListen(null, { success: x => result.values.push(plain(x)), error: (...x) => result.errors.push(x), endOfStream: () => result.ended++ });
    return result;
  }
  return { root, storeFile, state, hooks, channels, calls, agents, published, active, listeners, warnings, Plugin,
    plugin, make, engine, messenger, ability, binding, call, listen, channel,
    attach() { plugin.onAttachedToAbility(binding); },
    async drainTaps() { await Plugin.tapQueue; },
  };
}

test('exact channels, unknown methods and explicit live/inline-action boundaries', async t => {
  const f = fixture(t);
  assert.deepEqual(f.channels.map(x => x.name), ['dsh/notify', 'dsh/notify/taps', 'dsh/notify/actions']);
  assert.deepEqual(await f.call('unknown'), { missing: true });
  assert.deepEqual((await f.call('liveStatus')).value, { supported: false, allowed: false, settings: true, xiaomiFocus: false });
  assert.equal((await f.call('live', { enabled: true, activity: {} })).error, 'ohos_unsupported');
  assert.deepEqual(await f.call('live', { enabled: false, activity: {} }), { value: null });
  assert.deepEqual(await f.call('live', { enabled: true }), { value: null });
  assert.equal((await f.call('actionResult')).error, 'ohos_unsupported');
  const actions = f.listen('dsh/notify/actions');
  assert.equal(actions.errors[0][0], 'ohos_unsupported'); assert.equal(actions.ended, 1); assert.deepEqual(actions.values, []);
});

test('app switch stays distinct from a disabled slot; unknown and failed queries are errors', async t => {
  const f = fixture(t); f.attach();
  assert.deepEqual((await f.call('status')).value, { enabled: true, done: true, attention: true });
  f.state.slot.enabled = false;
  assert.deepEqual((await f.call('status')).value, { enabled: true, done: false, attention: false });
  assert.equal((await f.call('show', post)).error, 'permission');
  f.state.slot = { enabled: true, notificationLevel: 0 };
  assert.equal((await f.call('status')).value.done, false);
  f.state.slot = {}; assert.equal((await f.call('status')).error, 'ohos_notify_failed');
  f.state.enabled = false;
  assert.deepEqual((await f.call('status')).value, { enabled: false, done: false, attention: false });
  assert.equal((await f.call('show', post)).error, 'permission');
  assert.equal(f.published.length, 0); assert(!f.calls.includes('settings'));
  f.state.enabled = true; f.state.slot = null;
  assert.deepEqual((await f.call('status')).value, { enabled: true, done: true, attention: true });
  assert.equal(f.calls.filter(x => x === 'addSlot').length, 1);
  f.hooks.permission = () => { throw new Error('service down'); };
  assert.equal((await f.call('status')).error, 'ohos_notify_failed');
});

test('public-only post, fixed own target, immutable Want and real persisted HMAC', async t => {
  const f = fixture(t); f.attach();
  assert.deepEqual(await f.call('show', { ...post, canApprove: true, bundleName: 'attacker', abilityName: 'attacker' }), { value: null });
  const request = f.published[0], info = clone(f.agents[0]), want = info.wants[0];
  assert.deepEqual(clone(request.content), { notificationContentType: 0, normal: { title: 'DSH Go', text: post.publicText } });
  assert.deepEqual(clone(request.actionButtons), [{ title: '打开应用处理', wantAgent: { agentId: 1 } }]);
  assert.equal(want.bundleName, 'io.github.ccch1mneyyy.dsh_app'); assert.equal(want.abilityName, 'EntryAbility');
  assert.deepEqual(info.actionFlags, [3]); assert.equal(info.actionType, 2);
  const key = JSON.parse(readFileSync(f.storeFile, 'utf8')).hmacKey;
  assert.match(key, /^[0-9a-f]{64}$/);
  const params = want.parameters;
  assert.equal(params.dshNotifyMac, createHmac('sha256', Buffer.from(key, 'hex')).update(params.dshNotifyPayload).digest('hex'));
  for (const secret of [post.title, post.text, post.fullText, key]) {
    assert(!JSON.stringify([request, info]).includes(secret));
  }
  assert(!Object.keys(request).some(x => ['distributedOption', 'notDistributed', 'lockscreenVisibility'].includes(x)));
});

test('stable identity, unambiguous label hashing, group cancel and scoped cancelAll', async t => {
  const f = fixture(t); f.attach();
  await f.call('show', post); const first = f.published[0].label;
  await f.call('show', { ...post, publicText: '更新' }); assert.equal(f.published[1].label, first); assert.equal(f.active.size, 1);
  await f.call('show', { ...post, group: 'a|b', key: 'c' });
  await f.call('show', { ...post, group: 'a', key: 'b|c' });
  assert.notEqual(f.published[2].label, f.published[3].label);
  await f.call('cancel', { group: 'a|b', key: 'c' }); assert.equal(f.active.size, 2);
  await f.call('cancelGroup', { group: post.group }); assert.equal(f.active.size, 1);
  f.active.set('other', { id: 4, label: 'other-feature' });
  f.active.set('lookalike', { id: 9, label: 'dsh-chat:other-feature' });
  await f.call('cancelAll'); assert.deepEqual([...f.active.keys()], ['other', 'lookalike']);
});

test('show and cancelAll serialize around actual pending publication; rejection releases queue', async t => {
  const entered = deferred(), release = deferred();
  const f = fixture(t, { hooks: { publish: () => { entered.resolve(); return release.promise; } } }); f.attach();
  const show = f.call('show', post); await entered.promise;
  const cancel = f.call('cancelAll'); assert(!f.calls.includes('getActive'));
  release.resolve(); assert.deepEqual(await show, { value: null }); assert.deepEqual(await cancel, { value: null });
  assert.equal(f.active.size, 0); assert(f.calls.indexOf('publish:done') < f.calls.indexOf('getActive'));
  f.hooks.publish = () => { throw new Error('frequency limit'); };
  assert.equal((await f.call('show', post)).error, 'ohos_notify_failed');
  f.hooks.publish = undefined;
  assert.deepEqual(await f.call('show', post), { value: null }); assert.equal(f.active.size, 1);
});

test('settings needs a live ability, answers when its panel closes and blocks no other call', async t => {
  const entered = deferred(), release = deferred();
  const f = fixture(t, { hooks: { settings: () => { entered.resolve(); return release.promise; } } });
  assert.equal((await f.call('openSettings')).error, 'no_ability'); f.attach();
  let closed = false;
  const settings = f.call('openLiveSettings').then(reply => { closed = true; return reply; });
  await Promise.race([entered.promise, settings]);
  assert.equal((await f.call('status')).value.enabled, true);
  assert.equal(closed, false);
  release.resolve(); assert.deepEqual(await settings, { value: true });
  f.hooks.settings = undefined;
  assert.deepEqual(await f.call('openSettings'), { value: true });
  f.hooks.settings = () => { throw new Error('window gone'); };
  assert.equal((await f.call('openSettings')).error, 'ohos_notify_failed');
});

test('the permission dialog needs a live ability, answers from the system and blocks no other call', async t => {
  const entered = deferred(), release = deferred();
  const f = fixture(t, { hooks: { request: () => { entered.resolve(); return release.promise; } } });
  f.state.enabled = false;
  assert.equal((await f.call('requestPermission')).error, 'no_ability');
  assert.deepEqual(f.calls, [], 'no dialog without a window');
  f.attach();
  const asked = f.call('requestPermission'); await entered.promise;
  assert.equal((await f.call('status')).value.enabled, false);
  f.state.enabled = true; release.resolve();
  assert.deepEqual(await asked, { value: true });
  // Dismissed without an answer: the call resolved, the switch is still off.
  f.hooks.request = undefined; f.state.enabled = false;
  assert.deepEqual(await f.call('requestPermission'), { value: false });
});

test('a refusal is an answer, not a failure; anything else takes the error path', async t => {
  const f = fixture(t); f.state.enabled = false; f.attach();
  const code = value => Object.assign(new Error('rejected'), { code: value });
  f.hooks.request = () => { throw code(1600004); };
  assert.deepEqual(await f.call('requestPermission'), { value: false });
  f.hooks.request = () => { throw code(1600013); };
  assert.equal((await f.call('requestPermission')).error, 'ohos_notify_failed');
  f.hooks.request = () => { throw new Error('window gone'); };
  assert.equal((await f.call('requestPermission')).error, 'ohos_notify_failed');
});

test('cold restart verifies persisted key, delivers one pending tap and does not replay launch on reattach', async t => {
  const first = fixture(t); first.attach(); await first.call('show', { ...post, eventId: 'ev-1' });
  const want = clone(first.agents[0].wants[0]);
  const second = fixture(t, { directory: first.root, launchWant: want }); second.attach(); await second.drainTaps();
  const taps = second.listen();
  assert.deepEqual(taps.values, [{ host: post.host, sessionId: post.sessionId, kind: post.kind, eventId: 'ev-1' }]);
  second.plugin.onDetachedFromAbility(); second.plugin.onAttachedToAbility(second.binding); await second.drainTaps();
  assert.equal(taps.values.length, 1); assert.equal(second.listeners.size, 1);
  second.plugin.onNewWant(want, {}); await second.drainTaps(); assert.equal(taps.values.length, 2);
});

test('untrusted, tampered and oversize Wants never enter the tap stream', async t => {
  const f = fixture(t); f.attach(); await f.call('show', post); const taps = f.listen();
  const want = clone(f.agents[0].wants[0]);
  const tampered = clone(want); tampered.parameters.dshNotifyPayload = tampered.parameters.dshNotifyPayload.replace('会话一', '别的会话');
  const wrongMac = clone(want); wrongMac.parameters.dshNotifyMac = '0'.repeat(64);
  const huge = clone(want); huge.parameters.dshNotifyPayload = 'x'.repeat(8193);
  for (const item of [{ ...want, action: 'other' }, { action: want.action }, tampered, wrongMac, huge]) f.plugin.onNewWant(item, {});
  await f.drainTaps(); assert.deepEqual(taps.values, []);
  // A malformed signed route is rejected too: the persisted key is test-only.
  const key = Buffer.from(JSON.parse(readFileSync(f.storeFile)).hmacKey, 'hex');
  for (const route of [{ ...post, sessionId: '' }, { ...post, host: 1 }, null]) {
    const payload = JSON.stringify(route), invalid = clone(want);
    invalid.parameters.dshNotifyPayload = payload;
    invalid.parameters.dshNotifyMac = createHmac('sha256', key).update(payload).digest('hex');
    f.plugin.onNewWant(invalid, {});
  }
  await f.drainTaps(); assert.deepEqual(taps.values, []);
});

test('late verification goes to the replacement engine; old listener and handlers retire', async t => {
  const entered = deferred(), release = deferred();
  const f = fixture(t); f.attach(); await f.call('show', post); const old = f.listen();
  f.hooks.mac = () => { entered.resolve(); return release.promise; };
  f.plugin.onNewWant(clone(f.agents[0].wants[0]), {}); await entered.promise;
  f.plugin.onDetachedFromEngine(f.engine);
  const next = f.make(); next.onAttachedToAbility(f.binding); const current = f.listen();
  release.resolve(); await f.drainTaps();
  assert.equal(old.values.length, 0); assert.equal(current.values.length, 1);
  assert.deepEqual(f.messenger.removed, ['dsh/notify/taps', 'dsh/notify/actions']);
  assert.equal(f.channels[0].handler, null); assert.equal(f.listeners.size, 1);
  f.plugin.onNewWant(clone(f.agents[0].wants[0]), {}); await f.drainTaps(); assert.equal(current.values.length, 1);
});

test('tap arrival order survives asynchronous verification; latest pending tap matches Android contract', async t => {
  const f = fixture(t); f.attach(); await f.call('show', post); await f.call('show', { ...post, sessionId: 'two', key: 'second' });
  const entered = deferred(), release = deferred(); let calls = 0;
  f.hooks.mac = () => { if (++calls === 1) { entered.resolve(); return release.promise; } };
  const taps = f.listen();
  f.plugin.onNewWant(clone(f.agents[0].wants[0]), {}); await entered.promise;
  f.plugin.onNewWant(clone(f.agents[1].wants[0]), {}); release.resolve(); await f.drainTaps();
  assert.deepEqual(taps.values.map(x => x.sessionId), [post.sessionId, 'two']);
  f.channel('dsh/notify/taps').stream.onCancel(null);
  f.plugin.onNewWant(clone(f.agents[0].wants[0]), {}); f.plugin.onNewWant(clone(f.agents[1].wants[0]), {}); await f.drainTaps();
  assert.deepEqual(f.listen().values.map(x => x.sessionId), ['two']);
});

test('engine generation rejects a late post after same-object reattach, while ability detach permits background posting', async t => {
  const entered = deferred(), release = deferred();
  const f = fixture(t, { hooks: { digest: text => { if (text.startsWith('[')) { entered.resolve(); return release.promise; } } } }); f.attach();
  const pending = f.call('show', post); await entered.promise;
  f.plugin.onDetachedFromEngine(f.engine); f.plugin.onAttachedToEngine(f.engine); f.plugin.onAttachedToAbility(f.binding);
  release.resolve(); assert.equal((await pending).error, 'ohos_detached'); assert.equal(f.published.length, 0);
  f.hooks.digest = undefined; f.plugin.onDetachedFromAbility();
  assert.deepEqual(await f.call('show', post), { value: null }); assert.equal(f.published.length, 1);
});

test('queued mutation from a retired engine cannot revive after reattach', async t => {
  const entered = deferred(), release = deferred();
  const f = fixture(t, { hooks: { publish: () => { entered.resolve(); return release.promise; } } }); f.attach();
  const first = f.call('show', post); await entered.promise;
  const queued = f.call('show', { ...post, key: 'queued' });
  f.plugin.onDetachedFromEngine(f.engine); f.plugin.onAttachedToEngine(f.engine); f.plugin.onAttachedToAbility(f.binding);
  release.resolve(); await first;
  assert.equal((await queued).error, 'ohos_detached'); assert.equal(f.published.length, 1);
});

test('persistent key flush failure cannot be bypassed through a cached Preferences value', async t => {
  const f = fixture(t, { hooks: { flush: () => { throw new Error('disk failure'); } } }); f.attach();
  assert.equal((await f.call('show', post)).error, 'ohos_notify_failed'); assert.equal(f.published.length, 0);
  assert(!existsSync(f.storeFile));
  assert.equal((await f.call('show', post)).error, 'ohos_notify_failed'); assert.equal(f.published.length, 0);
  assert.equal(f.state.flushes, 2);
  f.hooks.flush = undefined;
  assert.deepEqual(await f.call('show', post), { value: null }); assert(existsSync(f.storeFile));
});

test('corrupt saved key fails closed and never publishes or logs route content', async t => {
  const first = fixture(t); writeFileSync(first.storeFile, JSON.stringify({ hmacKey: 'bad' }));
  const f = fixture(t, { directory: first.root }); f.attach();
  assert.equal((await f.call('show', post)).error, 'ohos_notify_storage'); assert.equal(f.published.length, 0);
  assert(!JSON.stringify(f.warnings).includes(post.sessionId));
});
