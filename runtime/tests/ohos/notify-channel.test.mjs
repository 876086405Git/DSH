// Executes the actual ETS after TypeScript erasure. Crypto and persistence are
// real Node HMAC/SHA256 and private Linux files; OS/Flutter remain test doubles.
import assert from 'node:assert/strict';
import { createHash, createHmac, randomBytes, randomUUID } from 'node:crypto';
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
  const subscribers = [];
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
    SlotType: { SERVICE_INFORMATION: 2 }, SlotLevel: { LEVEL_NONE: 0 }, ContentType: { NOTIFICATION_CONTENT_BASIC_TEXT: 0, NOTIFICATION_CONTENT_LONG_TEXT: 1 },
    async isNotificationEnabled() { calls.push('enabled'); await hooks.permission?.(); return state.enabled; },
    async getSlot(type) { assert.equal(type, 2); calls.push('getSlot'); await hooks.slot?.(); return state.slot; },
    async addSlot(type) { assert.equal(type, 2); calls.push('addSlot'); state.slot = { enabled: true, notificationLevel: 3 }; },
    async publish(request) {
      calls.push('publish:start'); await hooks.publish?.(request);
      const snapshot = clone(request); published.push(snapshot); active.set(request.id + ':' + request.label, snapshot); calls.push('publish:done');
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
        OperationType: { START_ABILITY: 1, SEND_COMMON_EVENT: 4 }, WantAgentFlags: { CONSTANT_FLAG: 4 },
        async getWantAgent(info) { calls.push('wantAgent'); agents.push(info); await hooks.agent?.(info); return { agentId: agents.length }; },
      } };
      if (name === '@ohos.commonEventManager') return { default: {
        async createSubscriber(info) {
          calls.push('common:create'); await hooks.createSubscriber?.(info);
          const subscriber = { info, active: false, callback: null }; subscribers.push(subscriber); return subscriber;
        },
        async subscribeToEvent(subscriber, callback) {
          calls.push('common:subscribe'); await hooks.subscribe?.(subscriber);
          subscriber.active = true; subscriber.callback = callback;
        },
        unsubscribe(subscriber, callback) {
          calls.push('common:unsubscribe');
          Promise.resolve().then(() => hooks.unsubscribe?.(subscriber)).then(() => {
            subscriber.active = false; callback?.();
          }, error => callback?.(error));
        },
      } };
      if (name === '@ohos.data.preferences') return { default: { async getPreferences(context, options) {
        assert.equal(context, application); assert.equal(options.name, 'dsh-notify'); return store;
      } } };
      if (name === '@ohos.security.cryptoFramework') return { default: crypto };
      if (name === '@ohos.util') return { default: { generateRandomUUID: randomUUID, TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } } };
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
    plugin, make, engine, messenger, ability, binding, call, listen, channel, subscribers,
    async broadcast(data) {
      for (const subscriber of subscribers) if (subscriber.active) subscriber.callback(data);
      await Promise.resolve(); await Plugin.queue;
    },
    attach() { plugin.onAttachedToAbility(binding); },
    async drainTaps() { await Plugin.tapQueue; },
  };
}

test('exact channels, unknown methods and truthful ordinary live capability', async t => {
  const f = fixture(t);
  assert.deepEqual(f.channels.map(x => x.name), ['dsh/notify', 'dsh/notify/taps', 'dsh/notify/actions']);
  assert.deepEqual(await f.call('unknown'), { missing: true });
  assert.deepEqual((await f.call('liveStatus')).value, { supported: false, allowed: false, settings: true, xiaomiFocus: false,
    ordinaryFallback: true, ordinaryAllowed: true, backend: 'ordinary' });
  assert.equal((await f.call('live', { enabled: true, activity: {} })).error, 'bad_args');
  assert.deepEqual(await f.call('live', { enabled: false, activity: {} }), { value: null });
  assert.deepEqual(await f.call('live', { enabled: true }), { value: null });
  assert.deepEqual(await f.call('actionResult'), { value: null });
  const actions = f.listen('dsh/notify/actions');
  assert.deepEqual(actions.errors, []); assert.equal(actions.ended, 0); assert.deepEqual(actions.values, []);
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

test('real notification content, fixed own target, immutable Want and real persisted HMAC', async t => {
  const f = fixture(t); f.attach();
  assert.deepEqual(await f.call('show', { ...post, canApprove: true, bundleName: 'attacker', abilityName: 'attacker' }), { value: null });
  const request = f.published[0], info = clone(f.agents[0]), want = info.wants[0];
  assert.deepEqual(clone(request.content), { notificationContentType: 1, longText: { title: post.title, text: post.text, longText: post.fullText, briefText: post.text, expandedTitle: post.title } });
  assert.deepEqual(clone(request.actionButtons), [{ title: '打开应用处理', wantAgent: { agentId: 1 } }]);
  assert.equal(want.bundleName, 'io.github.ccch1mneyyy.dsh_app'); assert.equal(want.abilityName, 'EntryAbility');
  assert.deepEqual(info.actionFlags, [4]); assert.equal(info.actionType, 1);
  const key = JSON.parse(readFileSync(f.storeFile, 'utf8')).hmacKey;
  assert.match(key, /^[0-9a-f]{64}$/);
  const params = want.parameters;
  assert.equal(params.dshNotifyMac, createHmac('sha256', Buffer.from(key, 'hex')).update(params.dshNotifyPayload).digest('hex'));
  for (const secret of [post.title, post.text, post.fullText, key]) {
    assert(!JSON.stringify(info).includes(secret), 'tap routing must never contain notification content or its signing key');
  }
  assert(!JSON.stringify(request).includes(key));
  assert(!JSON.stringify(f.warnings).includes(post.text));
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


test('same Dart title/text keys reach basic notifications unchanged, including Unicode and newlines', async t => {
  const f = fixture(t); f.attach();
  const title = '真实会话 👩🏽‍💻', text = '第一行\n第二行：等待你确认';
  assert.deepEqual(await f.call('show', { ...post, title, text, fullText: undefined, body: 'not-a-protocol-key' }), { value: null });
  assert.deepEqual(clone(f.published[0].content), { notificationContentType: 0, normal: { title, text } });
  assert(!JSON.stringify(f.published[0].content).includes(post.publicText));
});

test('missing or empty text uses public fallback only to meet the SDK nonempty content contract', async t => {
  const f = fixture(t); f.attach();
  for (const empty of [undefined, null, '']) {
    assert.deepEqual(await f.call('show', { ...post, title: empty, text: empty, fullText: empty }), { value: null });
    assert.deepEqual(clone(f.published.at(-1).content), { notificationContentType: 0, normal: { title: 'DSH Go', text: post.publicText } });
  }
  assert.deepEqual(await f.call('show', { ...post, title: '', text: '', fullText: '', publicText: '' }), { value: null });
  assert.equal(f.published.at(-1).content.normal.text, '有新的会话提醒');
});

test('non-string content fails before signing or publishing without exposing its value', async t => {
  const f = fixture(t); f.attach();
  for (const name of ['title', 'text', 'fullText', 'publicText']) {
    for (const value of [3, false, { secret: 'not-content' }]) {
      const result = await f.call('show', { ...post, [name]: value });
      assert.equal(result.error, 'bad_args');
      assert(!JSON.stringify(result).includes('not-content'));
    }
  }
  assert.equal(f.published.length, 0); assert.equal(f.agents.length, 0); assert.equal(f.state.flushes, 0);
});


test('438 an alive signed approval notification replies without starting an ability', async t => {
  const f = fixture(t); f.attach();
  t.after(() => f.plugin.onDetachedFromEngine(f.engine));
  const actions = f.listen('dsh/notify/actions');
  const approval = { ...post, key: 'approval-1', kind: 'approval', eventId: 'approval-1',
    canApprove: true, requestToken: 17 };
  assert.deepEqual(await f.call('show', approval), { value: null });
  const request = f.published[0];
  assert.deepEqual(Array.from(request.actionButtons, button => button.title), ['拒绝', '允许本次', '打开应用处理']);
  assert.deepEqual(actions.errors, []); assert.equal(actions.ended, 0);
  assert.equal(f.subscribers.length, 1);
  assert.deepEqual(clone(f.subscribers[0].info), {
    events: ['io.github.ccch1mneyyy.dsh_app.NOTIFICATION_APPROVAL'],
    publisherBundleName: 'io.github.ccch1mneyyy.dsh_app',
  });
  const button = request.actionButtons.find(button => button.title === '允许本次');
  const info = f.agents[button.wantAgent.agentId - 1], want = info.wants[0];
  assert.equal(info.actionType, 4, 'SEND_COMMON_EVENT cannot start a UI ability');
  assert.deepEqual(Array.from(info.actionFlags), [4], 'the button Want is immutable');
  await f.broadcast({ event: want.action, bundleName: 'io.github.ccch1mneyyy.dsh_app', parameters: want.parameters });
  assert.equal(actions.values.length, 1);
  const action = actions.values[0];
  assert.deepEqual({ ...action, actionId: 'INSTANCE' }, {
    group: approval.group, key: approval.key, eventId: approval.eventId,
    host: approval.host, sessionId: approval.sessionId, decision: 'allowed-once',
    requestToken: 17, actionId: 'INSTANCE',
  });
  assert.match(action.actionId, /^[0-9a-f-]{36}$/i);
  assert.equal(f.active.size, 1, 'submission alone is not a successful approval');
});


const approvalPost = { ...post, key: 'approval-1', kind: 'approval', eventId: 'approval-1', canApprove: true, requestToken: 17 };
const ownBundle = 'io.github.ccch1mneyyy.dsh_app';
function actionData(f, request, title = '允许本次') {
  const button = request.actionButtons.find(button => button.title === title);
  assert(button, title);
  const info = f.agents[button.wantAgent.agentId - 1];
  assert.equal(info.actionType, 4);
  const want = info.wants[0];
  return { event: want.action, bundleName: ownBundle, parameters: clone(want.parameters) };
}
function actionFixture(t, options) {
  const f = fixture(t, options); f.attach();
  const actions = f.listen('dsh/notify/actions');
  t.after(async () => {
    f.hooks.unsubscribe = undefined;
    f.plugin.onDetachedFromEngine(f.engine);
    await f.plugin.actionTask;
    assert(f.subscribers.every(subscriber => !subscriber.active), 'no live dynamic subscriber after normal detach');
  });
  return { ...f, actions };
}

test('approval actions use a real persisted HMAC and reject publisher, decision and token tampering', async t => {
  const f = actionFixture(t);
  await f.call('show', approvalPost);
  const data = actionData(f, f.published[0]);
  const { dshNotifyActionPayload: payload, dshNotifyActionMac: mac } = data.parameters;
  const signingKey = JSON.parse(readFileSync(f.storeFile, 'utf8')).hmacKey;
  assert.equal(mac, createHmac('sha256', Buffer.from(signingKey, 'hex')).update(payload).digest('hex'));
  const signed = JSON.parse(payload);
  assert.equal(signed.requestToken, 17); assert.equal(signed.eventId, approvalPost.eventId);
  assert.equal(signed.decision, 'allowed-once'); assert.equal(signed.sessionId, approvalPost.sessionId);
  for (const secret of [post.title, post.text, post.fullText, signingKey]) assert(!payload.includes(secret));
  await f.broadcast({ ...data, bundleName: 'untrusted.publisher' });
  await f.broadcast({ ...data, event: data.event + '.wrong' });
  await f.broadcast({ ...data, parameters: { ...data.parameters, dshNotifyActionMac: '0'.repeat(64) } });
  for (const change of [{ decision: 'rejected' }, { requestToken: 18 }, { eventId: 'other' }, { actionId: randomUUID() }]) {
    await f.broadcast({ ...data, parameters: { ...data.parameters,
      dshNotifyActionPayload: JSON.stringify({ ...signed, ...change }) } });
  }
  assert.equal(f.actions.values.length, 0);
  await f.broadcast(data);
  await f.broadcast(data);
  await f.broadcast(actionData(f, f.published[0], '拒绝'));
  assert.equal(f.actions.values.length, 1, 'both buttons share one in-flight decision');
  assert.equal(f.actions.values[0].decision, 'allowed-once');
  assert(!JSON.stringify(f.warnings).includes(signingKey));
});

test('replacement invalidates the old action and its late acknowledgement cannot cancel the new notification', async t => {
  const f = actionFixture(t);
  await f.call('show', approvalPost);
  const first = actionData(f, f.published[0]);
  await f.broadcast(first);
  const old = f.actions.values[0];
  await f.call('show', { ...approvalPost, requestToken: 18 });
  const replacement = f.published[1], next = actionData(f, replacement);
  assert.equal(f.active.size, 1);
  assert.notEqual(JSON.parse(next.parameters.dshNotifyActionPayload).actionId, old.actionId);
  await f.call('actionResult', { group: old.group, key: old.key, actionId: old.actionId, result: 'handled' });
  assert.equal(f.active.size, 1); assert.equal(f.published.length, 2);
  await f.broadcast(first); assert.equal(f.actions.values.length, 1);
  await f.broadcast(next); assert.equal(f.actions.values.length, 2);
  const current = f.actions.values[1];
  await f.call('actionResult', { group: current.group, key: current.key, actionId: current.actionId, result: 'handled' });
  assert.equal(f.active.size, 0);
});

test('cancel, cancelGroup and cancelAll invalidate the signed buttons they remove', async t => {
  for (const method of ['cancel', 'cancelGroup', 'cancelAll']) {
    const f = actionFixture(t);
    await f.call('show', approvalPost);
    const data = actionData(f, f.published[0]);
    assert.deepEqual(await f.call(method, { group: approvalPost.group, key: approvalPost.key }), { value: null });
    assert.equal(f.active.size, 0);
    await f.broadcast(data); assert.equal(f.actions.values.length, 0, method);
  }
});

test('a failed Dart reply leaves a truthful open-only notification and never acknowledges success', async t => {
  const f = actionFixture(t);
  await f.call('show', approvalPost);
  const data = actionData(f, f.published[0]);
  await f.broadcast(data);
  const action = f.actions.values[0];
  await f.call('actionResult', { group: action.group, key: action.key, actionId: action.actionId, result: 'failed' });
  assert.equal(f.active.size, 1); assert.equal(f.published.length, 2);
  assert.deepEqual(f.published[1].actionButtons.map(button => button.title), ['打开应用处理']);
  assert.deepEqual(f.published[1].content.normal, { title: 'DSH Go', text: '未能完成审批，请打开应用处理。' });
  await f.broadcast(data); assert.equal(f.actions.values.length, 1);
  await f.call('actionResult', { group: action.group, key: action.key, actionId: action.actionId, result: 'handled' });
  assert.equal(f.active.size, 1, 'a late duplicate ACK cannot clear the fallback entry');
});

test('missing listener or request token keeps the original open-only action', async t => {
  const f = fixture(t); f.attach();
  await f.call('show', approvalPost);
  assert.deepEqual(f.published[0].actionButtons.map(button => button.title), ['打开应用处理']);
  assert.equal(f.subscribers.length, 0);
  const g = actionFixture(t);
  await g.call('show', { ...approvalPost, requestToken: undefined });
  assert.deepEqual(g.published[0].actionButtons.map(button => button.title), ['打开应用处理']);
  assert.equal(g.subscribers.length, 0);
});

test('subscriber creation, subscription and common-event WantAgent failures still publish the open path', async t => {
  for (const point of ['createSubscriber', 'subscribe', 'agent']) {
    const hooks = {};
    hooks[point] = value => {
      if (point !== 'agent' || value.actionType === 4) throw new Error('explicit OS boundary rejection');
    };
    const f = actionFixture(t, { hooks });
    assert.deepEqual(await f.call('show', approvalPost), { value: null }, point);
    assert.deepEqual(f.published[0].actionButtons.map(button => button.title), ['打开应用处理']);
    assert.equal(f.active.size, 1); assert.deepEqual(f.actions.errors, []);
    hooks[point] = undefined;
    assert.deepEqual(await f.call('show', approvalPost), { value: null });
    assert.equal(f.published[1].actionButtons.length, 3);
    assert.equal(f.subscribers.filter(subscriber => subscriber.active).length, 1);
  }
});

test('failed unsubscription retains one owned subscriber and cannot deliver through a replaced Dart listener', async t => {
  const f = actionFixture(t);
  await f.call('show', approvalPost);
  const old = actionData(f, f.published[0]);
  f.hooks.unsubscribe = () => { throw new Error('OS unsubscribe rejected'); };
  f.channel('dsh/notify/actions').stream.onCancel(null);
  await f.plugin.actionTask;
  const next = f.listen('dsh/notify/actions');
  await f.call('show', approvalPost);
  assert.equal(f.subscribers.length, 1, 'must not create more subscribers while the old one is still owned');
  assert.deepEqual(f.published.at(-1).actionButtons.map(button => button.title), ['打开应用处理']);
  await f.broadcast(old); assert.equal(next.values.length, 0);
  f.hooks.unsubscribe = undefined;
  await f.call('show', { ...approvalPost, requestToken: 18 });
  assert.equal(f.subscribers.filter(subscriber => subscriber.active).length, 1);
  assert.equal(f.subscribers[0].active, false);
  await f.broadcast(actionData(f, f.published.at(-1)));
  assert.equal(next.values.length, 1);
});

test('late subscriber creation after engine detach is released and cannot publish or deliver', async t => {
  const entered = deferred(), release = deferred();
  const f = actionFixture(t, { hooks: { createSubscriber: () => { entered.resolve(); return release.promise; } } });
  const shown = f.call('show', approvalPost);
  await entered.promise;
  f.plugin.onDetachedFromEngine(f.engine);
  release.resolve();
  assert.equal((await shown).error, 'ohos_detached');
  await f.plugin.actionTask;
  assert.equal(f.published.length, 0); assert.equal(f.subscribers.length, 1);
  assert.equal(f.subscribers[0].active, false); assert.equal(f.actions.values.length, 0);
});

test('late subscription after Dart cancellation is released and the pending post falls back to open-only', async t => {
  const entered = deferred(), release = deferred();
  const f = actionFixture(t, { hooks: { subscribe: () => { entered.resolve(); return release.promise; } } });
  const shown = f.call('show', approvalPost);
  await entered.promise;
  f.channel('dsh/notify/actions').stream.onCancel(null);
  release.resolve();
  assert.deepEqual(await shown, { value: null });
  await f.plugin.actionTask;
  assert.deepEqual(f.published[0].actionButtons.map(button => button.title), ['打开应用处理']);
  assert.equal(f.subscribers[0].active, false); assert.equal(f.actions.values.length, 0);
});
