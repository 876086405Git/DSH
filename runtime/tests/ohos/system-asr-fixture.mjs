// Real ETS service bodies with explicit Core Speech and timer boundaries.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createEntryAbilityImports, assertEntryAbilityImports } from './entry-ability-fixture.mjs';
const repo = process.env.OHOS_ASR_SOURCE_ROOT ?? fileURLToPath(new URL('../../../', import.meta.url));
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
assert.match(ts.version, /^5\.9\./);
export const deferred = () => Promise.withResolvers();
export async function settle() { for (let n = 0; n < 12; n++) await Promise.resolve(); }
export function asrFixture(options = {}) {
  let config = options, now = 0, serial = 0, current = true;
  const cache = new Map(), timers = new Map(), engines = [], events = [], calls = [], channels = [], channelEvents = [];
  class MethodChannel {
    constructor(messenger, name) { this.messenger = messenger; this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod(method, args) { channelEvents.push({ method, ...Object.fromEntries(args), messenger: this.messenger }); }
  }
  class FlutterAbility {
    constructor() { this.context = {}; }
    configureFlutterEngine() {}
    onForeground() {}
    onBackground() {}
    onDestroy() {}
  }
  const entryImports = createEntryAbilityImports({
    '../runtime/NativeHost': () => ({ loadNativeHost: async () => { throw new Error('unrelated NativeHost must not run'); } }),
    '../plugins/StreamingAsrPlugin': () => load('StreamingAsrPlugin'),
  });
  class Engine {
    constructor(params) { this.params = params; this.listener = null; this.starts = []; this.audio = []; this.finishes = []; this.cancels = []; this.shutdowns = 0; engines.push(this); }
    setListener(listener) { this.listener = listener; calls.push('setListener'); if (config.listenerFailure) throw Error('listener refused'); }
    startListening(params) {
      assert(this.listener); this.starts.push(params); calls.push('start');
      if (config.startFailure) throw Error('start refused');
      if (config.autoStart !== false) this.listener.onStart(params.sessionId, '');
    }
    writeAudio(id, bytes) {
      assert(this.listener); assert.equal(bytes.length, 640);
      this.audio.push({ id, bytes: bytes.slice(), time: now });
      if (config.writeFailure) throw Error('write refused');
    }
    isBusy() { return false; }
    finish(id) { this.finishes.push(id); if (config.autoComplete !== false) this.listener.onComplete(id, ''); }
    cancel(id) { this.cancels.push(id); }
    shutdown() { this.shutdowns++; if (config.shutdownFailure) throw Error('shutdown refused'); }
    result(text, final = false, last = false, id = this.starts.at(-1).sessionId) { this.listener.onResult(id, { result: text, isFinal: final, isLast: last }); }
    complete(id = this.starts.at(-1).sessionId) { this.listener.onComplete(id, ''); }
    error(code, id = this.starts.at(-1).sessionId) { this.listener.onError(id, code, 'private SDK text is not forwarded'); }
  }
  const kit = { async createEngine(params) { calls.push('create'); if (config.create) await config.create(); return new Engine(params); } };
  function load(file) {
    const path = file.startsWith('/') ? file : resolve(repo, 'app/ohos/entry/src/main/ets/plugins', file + '.ets');
    if (cache.has(path)) return cache.get(path).exports;
    const module = { exports: {} }; cache.set(path, module);
    const source = fs.readFileSync(path, 'utf8');
    if (path.endsWith('/entryability/EntryAbility.ets')) assertEntryAbilityImports(source);
    const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }).outputText;
    vm.runInNewContext(js, { module, exports: module.exports, Map, Set, ArrayBuffer, Uint8Array, Promise, Error,
      canIUse: cap => { assert.equal(cap, 'SystemCapability.AI.SpeechRecognizer'); return config.supported !== false; },
      setTimeout: (callback, ms) => { const id = ++serial; timers.set(id, { at: now + ms, callback }); return id; },
      clearTimeout: id => timers.delete(id),
      require(name) {
        if (name === '@ohos/flutter_ohos') return { MethodChannel, FlutterAbility };
        if (name.startsWith('.') && path.endsWith('/entryability/EntryAbility.ets')) return entryImports(name);
        if (name === '@kit.CoreSpeechKit') return { speechRecognizer: kit };
        if (name.startsWith('.')) return load(resolve(dirname(path), name + '.ets'));
        throw Error('unadapted boundary: ' + name);
      }
    }, { filename: path });
    return module.exports;
  }
  async function advance(ms) {
    const end = now + ms;
    for (;;) {
      const next = [...timers.entries()].filter(([, timer]) => timer.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!next) break;
      now = next[1].at; timers.delete(next[0]); next[1].callback(); await settle();
    }
    now = end; await settle();
  }
  function make() {
    const Resource = load('HmsStreamingAsr').HmsStreamingAsr;
    return new Resource(notice => events.push({ ...notice }), () => current);
  }
  function attach(ui = null, foreground = true) {
    const Entry = load(resolve(repo, 'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets')).default;
    ui ??= new Entry();
    const messenger = {};
    const binding = { getBinaryMessenger: () => messenger };
    const ability = { getAbility: () => ui };
    const added = [];
    ui.configureFlutterEngine({ getPlugins: () => ({ add(plugin) {
      added.push(plugin); plugin.onAttachedToEngine?.(binding); plugin.onAttachedToAbility?.(ability);
    } }) });
    if (foreground) ui.onForeground();
    const plugin = added.find(p => p.getUniqueClassName?.() === 'DshStreamingAsrPlugin');
    assert(plugin, 'real EntryAbility registers StreamingAsrPlugin');
    const channel = channels.findLast(c => c.name === 'dsh/streaming_asr' && c.messenger === messenger);
    function invoke(method, args) {
      return new Promise((resolve, reject) => channel.handler.onMethodCall({ method, argument: key => args[key] }, {
        success: resolve,
        error: (code, message) => reject(Object.assign(new Error(message), { code })),
        notImplemented: () => reject(new Error('notImplemented')),
      }));
    }
    return { ui, binding, ability, plugin, channel, invoke };
  }
  return { make, load, attach, engines, events, channelEvents, calls, timers, advance, now: () => now,
    change: next => { config = { ...config, ...next }; }, retire: () => { current = false; } };
}
