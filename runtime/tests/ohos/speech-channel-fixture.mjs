// Actual EntryAbility/SpeechPlugin ETS; Flutter and the PCM backend are explicit
// boundaries. This is neither a Dart run nor an AudioRenderer/device claim.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { resolve, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';

assert(process.env.OHOS_TYPESCRIPT_PREFIX, 'OHOS_TYPESCRIPT_PREFIX is required');
const requireTs = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'));
const ts = requireTs('typescript');
assert.equal(ts.version, '5.9.3', 'use the repository pinned compiler');
const productRoot = process.env.OHOS_SPEECH_SOURCE_ROOT ?? fileURLToPath(new URL('../../../', import.meta.url));
const etsRoot = resolve(productRoot, 'app/ohos/entry/src/main/ets');
const { entryAbilityImports, assertEntryAbilityImports, createEntryAbilityImports } = await import(
  pathToFileURL(resolve(productRoot, 'runtime/tests/ohos/entry-ability-fixture.mjs')).href);

export const deferred = () => Promise.withResolvers();
export function plain(value) {
  if (value instanceof Map) return Object.fromEntries([...value].map(([key, entry]) => [key, plain(entry)]));
  return value;
}
export async function until(check, label = 'condition') {
  const deadline = Date.now() + 5000;
  while (!check()) {
    if (Date.now() > deadline) throw new Error('Timed out: ' + label);
    await new Promise(resolve => setImmediate(resolve));
  }
}

export function speechChannelFixture(options = {}) {
  let settings = options;
  const channels = [], streams = [], trace = [], events = [], cache = new Map();
  const PcmTerminalKind = { Done: 'done', Stopped: 'stopped', Error: 'error' };

  class Backend {
    constructor(configuration, current, listener) {
      this.configuration = { ...configuration }; this.current = current; this.listener = listener;
      this.accepting = false; this.finished = false; this.bytes = 0; this.chunks = [];
      this.opening = null; this.closing = null; this.closed = false; this.terminal = false;
      this.opens = 0; this.stops = 0; this.ducks = [];
      streams.push(this);
    }
    open() {
      this.opens++; trace.push('backend.open');
      this.opening = (async () => {
        if (settings.open) await settings.open(this);
        if (!this.current() || settings.openFalse || this.configuration.rate !== 24000 ||
            this.configuration.call || this.configuration.levels) return false;
        this.accepting = true; return true;
      })();
      return this.opening;
    }
    write(bytes) {
      trace.push('backend.write');
      if (!this.accepting || !this.current() || this.finished || this.closed) return -1;
      const copy = Uint8Array.from(bytes); this.chunks.push(copy); this.bytes += copy.byteLength;
      return this.bytes;
    }
    waiting() { return this.current() && this.accepting && !this.closed ? this.bytes : -1; }
    end() { this.finished = true; trace.push('backend.end'); }
    stop() {
      this.accepting = false;
      if (this.closed) return Promise.resolve();
      if (this.closing) return this.closing;
      this.stops++; trace.push('backend.stop');
      const pending = (async () => {
        try { await this.opening; } catch {}
        if (settings.stop) await settings.stop(this);
        this.closed = true; this.bytes = 0; this.chunks = [];
        this.notice('stopped');
      })();
      this.closing = pending;
      pending.then(() => { this.closing = null; }, () => { this.closing = null; });
      return pending;
    }
    async duck(on) { if (settings.duck) await settings.duck(this, on); this.ducks.push(on); }
    startEvent() { this.listener.started(); }
    notice(kind, reason = '') {
      if (this.terminal) return;
      this.terminal = true; this.listener.terminal(kind, reason);
    }
    late(kind = 'done') { this.listener.terminal(kind, 'late fixture delivery'); }
  }

  class MethodChannel {
    constructor(messenger, name) { this.messenger = messenger; this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod(method, args) {
      const event = { method, ...plain(args), messenger: this.messenger };
      events.push(event); trace.push('event:' + event.type + ':' + event.what);
      if (settings.eventFailure) throw new Error('explicit retired Flutter transport');
    }
  }
  class FlutterAbility {
    constructor() { this.context = { applicationInfo: { accessTokenId: 123 } }; }
    configureFlutterEngine() {}
    onForeground() {}
    onBackground() {}
    onDestroy() {}
  }
  const flutter = { MethodChannel, FlutterAbility };
  const entryOverrides = { '../runtime/NativeHost': () => ({ loadNativeHost: async () => {
    throw new Error('unrelated native host must not run');
  } }) };
  if (Object.hasOwn(entryAbilityImports, '../plugins/SpeechPlugin')) {
    entryOverrides['../plugins/SpeechPlugin'] = () => load(resolve(etsRoot, 'plugins/SpeechPlugin.ets'));
  }
  const entryImports = createEntryAbilityImports(entryOverrides);

  function load(path) {
    if (cache.has(path)) return cache.get(path).exports;
    const module = { exports: {} }; cache.set(path, module);
    const text = fs.readFileSync(path, 'utf8');
    if (path.endsWith('/entryability/EntryAbility.ets')) assertEntryAbilityImports(text);
    const result = ts.transpileModule(text, { fileName: path, compilerOptions: {
      target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
    }, reportDiagnostics: true });
    assert(!result.diagnostics?.some(entry => entry.category === ts.DiagnosticCategory.Error), path);
    vm.runInNewContext(result.outputText, {
      module, exports: module.exports, Map, Set, WeakSet, Promise, Error, ArrayBuffer, Uint8Array,
      setTimeout, clearTimeout,
      // This legacy playback fixture explicitly has no capturer capability.
      // call-capture-fixture executes the same controller with the capture SDK boundary.
      canIUse(capability) { assert.equal(capability, 'SystemCapability.Multimedia.Audio.Capturer'); return false; },
      require(name) {
        if (name === '@ohos/flutter_ohos') return flutter;
        if (name === './OhosPcmStream') return { OhosPcmStream: Backend };
        if (name === './PcmStreamTypes') return { PcmTerminalKind };
        if (name === './OhosSpeechPlayback') return load(resolve(etsRoot, 'plugins/OhosSpeechPlayback.ets'));
        if (name.startsWith('.') && path.endsWith('/entryability/EntryAbility.ets')) return entryImports(name);
        if (name.startsWith('.')) return load(resolve(dirname(path), name + '.ets'));
        if (['@ohos.multimedia.audio', '@ohos.systemDateTime', '@ohos.window', '@ohos.abilityAccessCtrl'].includes(name)) {
          return { default: {} };
        }
        throw new Error('unadapted boundary ' + name + ' from ' + path);
      },
    }, { filename: path });
    return module.exports;
  }
  const EntryAbility = load(resolve(etsRoot, 'entryability/EntryAbility.ets')).default;
  let sequence = 0;
  function attach(existingPlugin = null, ui = new EntryAbility()) {
    const messenger = { sequence: ++sequence, setMessageHandler() {} };
    const engine = { getApplicationContext: () => ui.context, getBinaryMessenger: () => messenger };
    const ability = { getAbility: () => ui };
    const added = [];
    const embedder = { getPlugins: () => ({ add(plugin) {
      added.push(plugin);
      plugin.onAttachedToEngine?.(engine);
      plugin.onAttachedToAbility?.(ability);
    } }) };
    if (existingPlugin) {
      added.push(existingPlugin); existingPlugin.onAttachedToEngine(engine); existingPlugin.onAttachedToAbility(ability);
    } else {
      ui.configureFlutterEngine(embedder);
    }
    ui.onForeground();
    const methods = channels.findLast(channel => channel.messenger === messenger && channel.name === 'dsh/speech');
    const plugin = added.find(entry => entry.getUniqueClassName?.() === 'DshSpeechPlugin');
    return { ui, engine, ability, plugin, methods, messenger,
      foreground: () => ui.onForeground(), background: () => ui.onBackground(), destroy: () => ui.onDestroy() };
  }
  function call(methods, method, args = {}) {
    const done = deferred(), replies = [];
    const respond = reply => {
      replies.push(reply); done.resolve(reply);
      if (settings.replyFailure) throw new Error('explicit retired method reply');
    };
    if (!methods?.handler) {
      respond({ missing: true });
    } else {
      methods.handler.onMethodCall({ method, argument: key => args[key] }, {
        success: value => respond({ value: plain(value) }),
        error: (error, message, details) => respond({ error, message, details: plain(details) }),
        notImplemented: () => respond({ missing: true }),
      });
    }
    return { done: done.promise, replies };
  }
  return { ...attach(), attach, call, channels, streams, trace, events, PcmTerminalKind,
    change(next) { settings = { ...settings, ...next }; } };
}
