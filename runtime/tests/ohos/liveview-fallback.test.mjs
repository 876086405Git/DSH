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
const source = process.env.OHOS_NOTIFY_SOURCE || new URL(
  '../../../app/ohos/entry/src/main/ets/plugins/NotifyPlugin.ets', import.meta.url);
const compiled = ts.transpileModule(readFileSync(source, 'utf8'), { compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
} });
const plain = value => Object.prototype.toString.call(value) === '[object Map]' ? Object.fromEntries(value) : value;
const clone = value => JSON.parse(JSON.stringify(value));
// StandardMessageCodec MAP decodes every nested Dart map as an ETS Map.
const codecValue = value => Array.isArray(value) ? value.map(codecValue) :
  value !== null && typeof value === 'object' ? new Map(Object.entries(value).map(([k, v]) => [k, codecValue(v)])) : value;
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const host = JSON.stringify({ kind: 'local', id: 'local' });
const post = { group: 'local:本机|会话一', key: 'turn', sessionId: '会话一', host, kind: 'done',
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
      const snapshot = clone(request);
      calls.push('publish:start'); await hooks.publish?.(clone(snapshot));
      published.push(snapshot); active.set(snapshot.id + ':' + snapshot.label, clone(snapshot)); calls.push('publish:done');
    },
    async cancel(id, label) { calls.push('cancel:' + label); await hooks.cancel?.(id, label); active.delete(id + ':' + label); },
    async cancelGroup(group) { calls.push('cancelGroup:' + group); for (const [key, value] of active) if (value.groupName === group) active.delete(key); },
    async getActiveNotifications() { calls.push('getActive'); await hooks.active?.(); return [...active.values()].map(clone); },
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
    module, exports: module.exports, Map,
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
    return new Promise(resolve => handler.onMethodCall({ method, argument: key => codecValue(args[key]) }, {
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

test('441 running then waiting uses ordinary progress and done only retires live', async t => {
  const f = fixture(t); f.attach();
  const group = 'local:|session-441';
  const running = {
    kind: 'running', title: 'private-session-title-441', text: '正在思考', chip: '思考中',
    publicText: 'DSH 正在干活', mood: 'thinking', sinceMs: 1793854800000,
    host, sessionId: 'session-441',
  };
  const started = await f.call('live', { enabled: true, activity: running });
  // The baseline returns ohos_unsupported and publishes nothing. A completed
  // turn is not injected until after both real progress-state assertions.
  assert.equal(f.published.length, 1,
    `running must publish ordinary progress, not a completed-turn substitute: ${JSON.stringify(started)}`);
  assert.equal(started.error, undefined);
  assert.equal(f.active.size, 1);
  const first = f.published[0];
  assert.equal(first.id, 0);
  assert.equal(first.label, 'dsh-chat:live');
  assert.deepEqual(clone(first.content), {
    notificationContentType: 0, normal: { title: 'DSH Go', text: running.publicText },
  });
  const tap = clone(f.agents[0]);
  assert.equal(tap.actionType, 1, 'SDK START_ABILITY');
  assert.equal(tap.wants[0].bundleName, f.ability.context.abilityInfo.bundleName);
  assert.equal(tap.wants[0].abilityName, 'EntryAbility');
  assert.deepEqual(tap.actionFlags, [4], 'SDK CONSTANT_FLAG');
  const params = tap.wants[0].parameters;
  const route = JSON.parse(params.dshNotifyPayload);
  assert.equal(route.host, running.host);
  assert.equal(route.sessionId, running.sessionId);
  const key = JSON.parse(readFileSync(f.storeFile, 'utf8')).hmacKey;
  assert.equal(params.dshNotifyMac, createHmac('sha256', Buffer.from(key, 'hex')).update(params.dshNotifyPayload).digest('hex'));
  assert(!JSON.stringify(first).includes(running.title));
  assert(!JSON.stringify(tap).includes(running.title));
  assert(!JSON.stringify(tap).includes(running.publicText));

  const waiting = { ...running, kind: 'waiting', mood: 'notification',
    text: '待确认', chip: '待确认', publicText: 'DSH 正在等你确认', eventId: 'approval-441' };
  const waited = await f.call('live', { enabled: true, activity: waiting });
  assert.equal(waited.error, undefined);
  assert.equal(f.published.length, 2);
  assert.equal(f.active.size, 1, 'waiting replaces progress rather than adding another live item');
  assert.equal(f.published[1].id, first.id);
  assert.equal(f.published[1].label, first.label);
  assert.deepEqual(clone(f.published[1].content), {
    notificationContentType: 0, normal: { title: 'DSH Go', text: waiting.publicText },
  });
  assert.equal(f.published[1].actionButtons, undefined, 'a live summary never approves a request');

  // Original ChatAlerts owns this separate ordinary completed-turn post.
  const completion = { ...post, group, host: running.host, sessionId: running.sessionId };
  assert.equal((await f.call('show', completion)).error, undefined);
  const turn = f.published.at(-1);
  assert.notEqual(turn.label, first.label, 'live must not overwrite the original turn notification');
  const countBeforeDone = f.published.length;
  const ended = await f.call('live', { enabled: true, activity: {
    ...running, kind: 'done', mood: 'attention', text: '完成', chip: '完成', publicText: 'DSH 已完成',
  } });
  assert.equal(ended.error, undefined);
  assert.equal(f.published.length, countBeforeDone, 'done must not publish a second completion');
  assert.equal(f.active.has(first.id + ':' + first.label), false, 'live item retired');
  assert.equal(f.active.has(turn.id + ':' + turn.label), true, 'original completion survives');
  assert.equal(f.active.size, 1);
});

const running = (extra = {}) => ({
  kind: 'running', title: 'PRIVATE_SESSION_TITLE', text: 'PRIVATE_MODEL_TEXT', chip: 'PRIVATE_CHIP',
  publicText: 'DSH 正在干活', mood: 'thinking', sinceMs: 1793854800000,
  host, sessionId: 'session-441', ...extra,
});
const live = (f, activity = running()) => f.call('live', { enabled: true, activity });
const hasLive = f => f.active.has('0:dsh-chat:live');
const ok = result => assert.equal(result.error, undefined, JSON.stringify(result));

// Status describes OS permission and the selected backend, not an active card.
test('441 liveStatus reports ordinary capability without claiming Kit or display', async t => {
  const f = fixture(t); f.attach();
  for (const [enabled, slotEnabled, level, allowed] of [
    [true, true, 3, true], [false, true, 3, false], [true, false, 3, false], [true, true, 0, false],
  ]) {
    f.state.enabled = enabled; f.state.slot = { enabled: slotEnabled, notificationLevel: level };
    const result = await f.call('liveStatus'); ok(result);
    assert.equal(result.value.supported, false);
    assert.equal(result.value.allowed, false);
    assert.equal(result.value.ordinaryFallback, true);
    assert.equal(result.value.ordinaryAllowed, allowed);
    assert.equal(result.value.backend, 'ordinary');
  }
  assert.equal(f.published.length, 0);
  assert.equal(f.agents.length, 0);
});

for (const terminal of ['done', 'failed', 'disabled', 'null']) {
  test(`441 ${terminal} retires only live and does not publish a second turn`, async t => {
    const f = fixture(t); f.attach(); ok(await live(f)); ok(await f.call('show', post));
    const turn = f.published.at(-1); const count = f.published.length;
    const args = terminal === 'disabled' ? { enabled: false, activity: running() } :
      { enabled: true, activity: terminal === 'null' ? null : running({ kind: terminal }) };
    ok(await f.call('live', args));
    assert.equal(f.published.length, count);
    assert.equal(hasLive(f), false);
    assert.equal(f.active.has(turn.id + ':' + turn.label), true);
    assert.deepEqual(f.calls.filter(x => x.startsWith('cancel:')), ['cancel:dsh-chat:live']);
  });
}

test('441 app or slot denial blocks actual progress while permission error is returned', async t => {
  const f = fixture(t); f.attach();
  for (const [enabled, slotEnabled, level] of [[false, true, 3], [true, false, 3], [true, true, 0]]) {
    f.state.enabled = enabled; f.state.slot = { enabled: slotEnabled, notificationLevel: level };
    assert.equal((await live(f)).error, 'permission');
  }
  assert.equal(f.published.length, 0); assert.equal(f.agents.length, 0);
  f.hooks.permission = () => { throw new Error('OS permission failure'); };
  assert.equal((await f.call('liveStatus')).error, 'ohos_notify_failed');
  assert.equal((await live(f)).error, 'ohos_notify_failed');
});

test('441 failed publish is a real error and a later ordinary publish can recover', async t => {
  const f = fixture(t, { hooks: { publish() { throw new Error('publish rejected'); } } }); f.attach();
  assert.equal((await live(f)).error, 'ohos_notify_failed');
  assert.equal(hasLive(f), false); assert.equal(f.published.length, 0);
  f.hooks.publish = undefined; ok(await live(f)); assert.equal(hasLive(f), true);
});

test('441 failed signing cannot publish unsigned progress or expose private text', async t => {
  const f = fixture(t, { hooks: { mac() { throw new Error('MAC rejected'); } } }); f.attach();
  const result = await live(f); assert.equal(result.error, 'ohos_notify_failed');
  assert.equal(f.published.length, 0); assert.equal(f.agents.length, 0);
  assert(!JSON.stringify(result).includes('PRIVATE_'));
});

test('441 host/session change replaces the sole live identity with a freshly signed route', async t => {
  const f = fixture(t); f.attach(); ok(await live(f));
  const next = running({ host: JSON.stringify({ kind: 'ssh', id: 'host-441' }), sessionId: '另一个会话', publicText: 'DSH 正在等你确认', kind: 'waiting', eventId: 'pending-kind-not-an-approval-token' });
  ok(await live(f, next));
  assert.equal(f.active.size, 1);
  assert.deepEqual(f.published.map(x => [x.id, x.label]), [[0, 'dsh-chat:live'], [0, 'dsh-chat:live']]);
  assert.equal(f.published[0].content.normal.text, 'DSH 正在干活', 'captured OS requests remain snapshots');
  assert.equal(f.published[1].actionButtons, undefined);
  const agent = clone(f.agents.at(-1)); const route = JSON.parse(agent.wants[0].parameters.dshNotifyPayload);
  assert.equal(route.host, next.host); assert.equal(route.sessionId, next.sessionId);
  assert.equal(route.kind, 'live'); assert.equal(route.eventId, next.eventId);
  assert(!JSON.stringify([f.published, f.agents]).includes('PRIVATE_'));
  const taps = f.listen(); const actions = f.listen('dsh/notify/actions');
  f.plugin.onNewWant(agent.wants[0], {}); await f.drainTaps();
  assert.equal(taps.values.length, 1); assert.equal(taps.values[0].host, next.host);
  assert.equal(taps.values[0].sessionId, next.sessionId); assert.equal(actions.values.length, 0);
  const forged = clone(agent.wants[0]);
  forged.parameters.dshNotifyPayload = JSON.stringify({ ...route, sessionId: 'attacker' });
  f.plugin.onNewWant(forged, {}); await f.drainTaps();
  assert.equal(taps.values.length, 1, 'altered route cannot pass the original HMAC');
});

test('441 pending publish and disabled are serialized so no late card survives', async t => {
  const entered = deferred(), release = deferred();
  const f = fixture(t, { hooks: { async publish() { entered.resolve(); await release.promise; } } }); f.attach();
  const started = live(f); await entered.promise;
  const stopped = f.call('live', { enabled: false });
  assert.equal(f.calls.some(x => x.startsWith('cancel:')), false);
  release.resolve(); ok(await started); ok(await stopped);
  assert.equal(hasLive(f), false);
  assert(f.calls.indexOf('publish:done') < f.calls.indexOf('cancel:dsh-chat:live'));
});

test('441 engine detach after publish starts records and retires the successful late publication', async t => {
  const entered = deferred(), release = deferred();
  const f = fixture(t, { hooks: { async publish() { entered.resolve(); await release.promise; } } }); f.attach();
  const started = live(f); await entered.promise;
  f.plugin.onDetachedFromEngine(f.engine); release.resolve();
  assert.equal((await started).error, 'ohos_detached'); await f.Plugin.queue;
  assert.equal(f.published.length, 1); assert.equal(hasLive(f), false);
  assert(f.calls.indexOf('publish:done') < f.calls.indexOf('cancel:dsh-chat:live'));
});

test('441 same instance reattach retains its new publication after queued old cleanup', async t => {
  const entered = deferred(), release = deferred(); let first = true;
  const f = fixture(t, { hooks: { async publish() { if (first) { first = false; entered.resolve(); await release.promise; } } } }); f.attach();
  const old = live(f); await entered.promise;
  f.plugin.onDetachedFromEngine(f.engine);
  f.plugin.onAttachedToEngine(f.engine); f.plugin.onAttachedToAbility(f.binding);
  const fresh = live(f, running({ sessionId: 'reattached' })); release.resolve();
  assert.equal((await old).error, 'ohos_detached'); ok(await fresh); await f.Plugin.queue;
  assert.equal(hasLive(f), true); assert.equal(f.published.length, 2);
  assert.equal(JSON.parse(f.agents.at(-1).wants[0].parameters.dshNotifyPayload).sessionId, 'reattached');
  assert(f.calls.lastIndexOf('cancel:dsh-chat:live') < f.calls.lastIndexOf('publish:done'));
});

test('441 old engine detach cannot retire the different instance new owner', async t => {
  const f = fixture(t); f.attach(); ok(await live(f));
  const next = f.make(); next.onAttachedToAbility(f.binding);
  ok(await live(f, running({ sessionId: 'replacement-engine' })));
  const before = f.calls.filter(x => x.startsWith('cancel:')).length;
  f.plugin.onDetachedFromEngine(f.engine); await f.Plugin.queue;
  assert.equal(hasLive(f), true);
  assert.equal(f.calls.filter(x => x.startsWith('cancel:')).length, before);
});

test('441 cancellation rejection preserves active ownership and disabled retries', async t => {
  const f = fixture(t); f.attach(); ok(await live(f));
  f.hooks.cancel = () => { throw new Error('cancel rejected'); };
  assert.equal((await f.call('live', { enabled: false })).error, 'ohos_notify_failed');
  assert.equal(hasLive(f), true);
  f.hooks.cancel = undefined; ok(await f.call('live', { enabled: false }));
  assert.equal(hasLive(f), false);
  assert.equal(f.calls.filter(x => x === 'cancel:dsh-chat:live').length, 2);
});

test('441 cold no-owner cleanup queries actual active cards and never cancels an absent id', async t => {
  const f = fixture(t); f.attach();
  f.hooks.cancel = (id, label) => assert(f.active.has(id + ':' + label), 'SDK cancel absent id is not assumed safe');
  ok(await f.call('live', { enabled: false }));
  assert(f.calls.includes('getActive')); assert(!f.calls.some(x => x.startsWith('cancel:')));
  f.active.set('0:dsh-chat:live', { id: 0, label: 'dsh-chat:live' });
  f.active.set('0:other-feature', { id: 0, label: 'other-feature' });
  ok(await f.call('live', { enabled: false }));
  assert.equal(hasLive(f), false); assert.equal(f.active.has('0:other-feature'), true);
  assert.deepEqual(f.calls.filter(x => x.startsWith('cancel:')), ['cancel:dsh-chat:live']);
});

test('441 Ability detach leaves engine-owned live usable until actual engine detach', async t => {
  const f = fixture(t); f.attach(); ok(await live(f));
  f.plugin.onDetachedFromAbility(); await f.Plugin.queue;
  assert.equal(hasLive(f), true); assert(!f.calls.some(x => x.startsWith('cancel:')));
  ok(await live(f, running({ kind: 'waiting', publicText: 'DSH 正在等你确认' })));
  assert.equal(f.published.length, 2);
  f.plugin.onDetachedFromEngine(f.engine); await f.Plugin.queue;
  assert.equal(hasLive(f), false);
});

test('441 detach during permission await prevents a later publish', async t => {
  const entered = deferred(), release = deferred();
  const f = fixture(t, { hooks: { async permission() { entered.resolve(); await release.promise; } } }); f.attach();
  const started = live(f); await entered.promise;
  f.plugin.onDetachedFromEngine(f.engine); release.resolve();
  assert.equal((await started).error, 'ohos_detached'); await f.Plugin.queue;
  assert.equal(f.published.length, 0); assert.equal(hasLive(f), false);
});
