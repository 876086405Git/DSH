// Actual EntryAbility, companion TTS plugin and playback lane; HMS/Flutter/audio are boundaries.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';

assert(process.env.OHOS_TYPESCRIPT_PREFIX, 'OHOS_TYPESCRIPT_PREFIX is required');
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
assert(ts.version.startsWith('5.9.'), 'TypeScript 5.9.x is required');
const root = process.env.OHOS_TTS_SOURCE_ROOT ?? fileURLToPath(new URL('../../../', import.meta.url));
const ets = resolve(root, 'app/ohos/entry/src/main/ets');
const { entryAbilityImports, assertEntryAbilityImports, createEntryAbilityImports } = await import(
  pathToFileURL(resolve(root, 'runtime/tests/ohos/entry-ability-fixture.mjs')).href);
export const deferred = () => Promise.withResolvers();
export const plain = x => x instanceof Map ? Object.fromEntries([...x].map(([k, v]) => [k, plain(v)])) : x;
export async function until(check) {
  const end = Date.now() + 5000;
  while (!check()) {
    assert(Date.now() < end, 'fixture event timed out');
    await new Promise(resolve => setImmediate(resolve));
  }
}

export function systemTtsFixture(options = {}) {
  let settings = options, serial = 0;
  const cache = new Map(), channels = [], engines = [], events = [], trace = [], streams = [];
  const PcmTerminalKind = { Done: 'done', Stopped: 'stopped', Error: 'error' };
  class Engine {
    constructor(params) { this.params = params; this.calls = []; this.stops = 0; this.shutdowns = 0; engines.push(this); }
    setListener(listener) { if (settings.listenerError) throw Error('fixture listener failed'); this.listener = listener; }
    speak(text, params) {
      if (settings.speakError) throw Error('fixture speak failed');
      this.calls.push({ text, params }); trace.push('tts.speak');
    }
    stop() { this.stops++; trace.push('tts.stop'); if (settings.stopError) throw Error('fixture stop failed'); }
    shutdown() { this.shutdowns++; trace.push('tts.shutdown'); if (settings.shutdownError) throw Error('fixture shutdown failed'); this.closed = true; }
    start(id) { this.listener.onStart(id, { audioType: 'pcm', sampleRate: 16000, sampleBit: 16, audioChannel: 1, compressRate: 0 }); }
    complete(id, type = 1) { this.listener.onComplete(id, { type, message: '' }); }
    stopped(id) { this.listener.onStop(id, { type: 0, message: '' }); }
    error(id) { this.listener.onError(id, 1002300005, 'fixture native failure'); }
  }
  const api = {
    async createEngine(params) {
      trace.push('tts.create');
      if (settings.create) await settings.create();
      if (settings.createError) throw Error('fixture create failed');
      return new Engine(params);
    },
  };
  class Backend {
    constructor(config, current, listener) { this.config = config; this.current = current; this.listener = listener; streams.push(this); }
    async open() { trace.push('pcm.open'); this.opened = true; return this.current(); }
    async stop() {
      trace.push('pcm.stop');
      if (settings.pcmStop) await settings.pcmStop();
      if (settings.pcmStopError) throw Error('fixture PCM release failed');
      this.closed = true; this.listener.terminal('stopped', '');
    }
    write(bytes) { return bytes.byteLength; }
    waiting() { return 0; }
    end() {}
    async duck() {}
  }
  class MethodChannel {
    constructor(messenger, name) { this.messenger = messenger; this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod(method, args) {
      events.push({ method, ...plain(args), channel: this.name, messenger: this.messenger });
      if (settings.eventError) throw Error('fixture retired event transport');
    }
  }
  class FlutterAbility {
    constructor() { this.context = { applicationInfo: { accessTokenId: 123 } }; }
    configureFlutterEngine() {}
    onForeground() {}
    onBackground() {}
    onDestroy() {}
  }
  const overrides = { '../runtime/NativeHost': () => ({ loadNativeHost() { throw Error('unrelated host'); } }) };
  for (const name of ['CompanionVoicePlugin', 'SpeechPlugin']) {
    const specifier = '../plugins/' + name;
    if (Object.hasOwn(entryAbilityImports, specifier)) overrides[specifier] = () => load(resolve(ets, 'plugins/' + name + '.ets'));
  }
  const entries = createEntryAbilityImports(overrides);
  function load(path) {
    if (cache.has(path)) return cache.get(path).exports;
    const module = { exports: {} }; cache.set(path, module);
    const source = fs.readFileSync(path, 'utf8');
    if (path.endsWith('/entryability/EntryAbility.ets')) assertEntryAbilityImports(source);
    const result = ts.transpileModule(source, { fileName: path, compilerOptions: {
      target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
    }, reportDiagnostics: true });
    assert(!result.diagnostics?.some(d => d.category === ts.DiagnosticCategory.Error), path);
    vm.runInNewContext(result.outputText, {
      module, exports: module.exports, Map, Set, WeakSet, Promise, Error, ArrayBuffer, Uint8Array, setTimeout, clearTimeout,
      require(name) {
        if (name === '@ohos/flutter_ohos') return { MethodChannel, FlutterAbility };
        // The call owner is real, but these TTS cases must never start capture.
        if (['@ohos.multimedia.audio', '@ohos.systemDateTime', '@ohos.window', '@ohos.abilityAccessCtrl'].includes(name)) {
          return { default: {} };
        }
        if (name === './OhosPcmStream') return { OhosPcmStream: Backend };
        if (name === './PcmStreamTypes') return { PcmTerminalKind };
        if (name === './HmsTextToSpeechKit') {
          trace.push('tts.load');
          if (settings.loadError) throw Error('fixture Kit unavailable');
          return { textToSpeech: api };
        }
        if (name.startsWith('.') && path.endsWith('/entryability/EntryAbility.ets')) return entries(name);
        if (name.startsWith('.')) return load(resolve(path, '..', name + '.ets'));
        throw Error('unadapted boundary ' + name);
      },
    }, { filename: path });
    return module.exports;
  }
  const EntryAbility = load(resolve(ets, 'entryability/EntryAbility.ets')).default;
  function attach(existing = null) {
    const ui = new EntryAbility(), messenger = { serial: ++serial };
    const engine = { getBinaryMessenger: () => messenger, getApplicationContext: () => ui.context };
    const ability = { getAbility: () => ui }, plugins = [];
    if (existing) {
      plugins.push(existing); existing.onAttachedToEngine(engine); existing.onAttachedToAbility(ability);
    } else ui.configureFlutterEngine({ getPlugins: () => ({ add(plugin) {
      plugins.push(plugin); plugin.onAttachedToEngine?.(engine); plugin.onAttachedToAbility?.(ability);
    } }) });
    ui.onForeground();
    return { ui, engine, ability, messenger, plugins,
      methods: channels.findLast(c => c.messenger === messenger && c.name === 'dsh/companion_voice'),
      pcm: channels.findLast(c => c.messenger === messenger && c.name === 'dsh/speech'),
      plugin: plugins.find(p => p.getUniqueClassName?.() === 'DshCompanionVoicePlugin'),
      background: () => ui.onBackground(), foreground: () => ui.onForeground(), destroy: () => ui.onDestroy() };
  }
  function call(channel, method, args = {}) {
    const reply = deferred(), replies = [];
    const respond = value => { replies.push(value); reply.resolve(value); if (settings.replyError) throw Error('fixture retired reply'); };
    if (!channel?.handler) respond({ missing: true });
    else channel.handler.onMethodCall({ method, argument: key => args[key] }, {
      success: value => respond({ value: plain(value) }),
      error: (error, message, details) => respond({ error, message, details: plain(details) }),
      notImplemented: () => respond({ missing: true }),
    });
    return { done: reply.promise, replies };
  }
  return { ...attach(), attach, call, channels, engines, streams, events, trace,
    change(next) { settings = { ...settings, ...next }; } };
}
