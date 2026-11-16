// 1317 research only: unchanged production ETS; explicit Flutter, SDK audio,
// permission, window and CoreSpeech boundaries. No acoustic/device claim.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = process.env.OHOS_ROUTE_SOURCE_ROOT ?? fileURLToPath(new URL('../../../', import.meta.url));
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
assert(ts.version.startsWith('5.9.'));
const hash = path => crypto.createHash('sha256').update(fs.readFileSync(path)).digest('hex');

export const deferred = () => Promise.withResolvers();
export const settle = () => new Promise(resolve => setImmediate(resolve));
export async function until(check) { for (let i = 0; i < 100; i++) { if (check()) return; await settle(); } assert(check(), 'condition not reached'); }
export function routeFixture(options = {}) {
  const cache = new Map(), inputs = new Map(), channels = [], trace = [], events = [];
  const renderers = [], capturers = [], engines = [];
  const session = {
    active: options.initialActive === true, device: options.initialDevice ?? 1000,
    callbacks: new Set(), history: [],
    isAudioSessionActivated() { return this.active; },
    getDefaultOutputDevice() { return this.device; },
    on(name, cb) { assert.equal(name, 'audioSessionDeactivated'); this.callbacks.add(cb); this.history.push(cb); },
    off(name, cb) { assert.equal(name, 'audioSessionDeactivated'); if (options.offError) throw Error('off'); this.callbacks.delete(cb); },
    async activateAudioSession(strategy) {
      trace.push({ method: 'session.activate', strategy }); await options.activate?.();
      this.active = !options.resolveInactive;
    },
    async deactivateAudioSession() {
      trace.push({ method: 'session.deactivate' }); await options.deactivate?.(); this.active = false;
    },
    async setDefaultOutputDevice(device) {
      trace.push({ method: 'session.setDefaultOutputDevice', device, phase: 'request' });
      await options.route?.(device); this.device = device;
      trace.push({ method: 'session.setDefaultOutputDevice', device, phase: 'accepted' });
    },
    lose() { this.active = false; for (const cb of this.callbacks) cb({ reason: 0 }); }
  };
  const state = { STATE_PREPARED: 1, STATE_RUNNING: 2, STATE_STOPPED: 3, STATE_RELEASED: 4, STATE_PAUSED: 5 };
  class Capturer {
    constructor(config) { this.config = config; this.listeners = new Map(); this.releases = 0; capturers.push(this); }
    getStreamInfoSync() { return { samplingRate: 16000, channels: 1, sampleFormat: 1, encodingType: 0 }; }
    getOverflowCountSync() { return 0; }
    on(name, callback) { this.listeners.set(name, callback); }
    off(name) { this.listeners.delete(name); }
    async start() { trace.push({ method: 'capturer.start' }); }
    async stop() { trace.push({ method: 'capturer.stop' }); }
    async release() { this.releases++; trace.push({ method: 'capturer.release' }); }
  }
  class Renderer {
    constructor(config) { this.config = config; this.state = 1; this.listeners = new Map(); this.devices = []; this.releases = 0; renderers.push(this); }
    getStreamInfoSync() { return { samplingRate: 24000, channels: 1, sampleFormat: 1, encodingType: 0 }; }
    getBufferSizeSync() { return 640; }
    on(name, callback) { this.listeners.set(name, callback); }
    off(name) { this.listeners.delete(name); }
    async setInterruptMode(mode) { trace.push({ method: 'renderer.setInterruptMode', mode }); }
    async setDefaultOutputDevice(device) { this.devices.push(device); trace.push({ method: 'renderer.setDefaultOutputDevice', device }); }
    async start() { this.state = 2; trace.push({ method: 'renderer.start' }); }
    async pause() { this.state = 5; trace.push({ method: 'renderer.pause' }); }
    async flush() { trace.push({ method: 'renderer.flush' }); }
    async stop() { this.state = 3; trace.push({ method: 'renderer.stop' }); }
    async release() { this.state = 4; this.releases++; trace.push({ method: 'renderer.release' }); }
    async setVolume(volume) { trace.push({ method: 'renderer.setVolume', volume }); }
  }
  class TtsEngine {
    constructor(config) { this.config = config; this.calls = []; this.closed = false; engines.push(this); }
    setListener(listener) { this.listener = listener; }
    speak(text, params) { this.calls.push({ text, params }); trace.push({ method: 'tts.speak', params }); }
    start() {
      const id = this.calls.at(-1).params.requestId;
      this.listener.onStart(id, { audioType: 'pcm', sampleRate: 16000, sampleBit: 16, audioChannel: 1, compressRate: 0 });
    }
    stop() { trace.push({ method: 'tts.stop' }); }
    shutdown() { this.closed = true; trace.push({ method: 'tts.shutdown' }); }
  }
  const audio = {
    getAudioManager() { return { getSessionManager() { return session; } }; },
    AudioConcurrencyMode: { CONCURRENCY_DEFAULT: 0 },
    AudioSamplingRate: { SAMPLE_RATE_16000: 16000, SAMPLE_RATE_24000: 24000 }, AudioChannel: { CHANNEL_1: 1 },
    AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 }, AudioEncodingType: { ENCODING_TYPE_RAW: 0 },
    SourceType: { SOURCE_TYPE_VOICE_COMMUNICATION: 7 },
    StreamUsage: { STREAM_USAGE_AUDIOBOOK: 12, STREAM_USAGE_VOICE_COMMUNICATION: 2 },
    InterruptMode: { INDEPENDENT_MODE: 1 }, DeviceType: { EARPIECE: 1, SPEAKER: 2, DEFAULT: 1000 },
    AudioState: state, AudioDataCallbackResult: { VALID: 0, INVALID: -1 },
    InterruptHint: { INTERRUPT_HINT_STOP: 3, INTERRUPT_HINT_PAUSE: 2, INTERRUPT_HINT_MUTE: 6 },
    async createAudioCapturer(config) { trace.push({ method: 'createAudioCapturer', config }); return new Capturer(config); },
    async createAudioRenderer(config) { trace.push({ method: 'createAudioRenderer', config }); return new Renderer(config); }
  };
  const screen = { keep: false, getWindowProperties() { return { isKeepScreenOn: this.keep }; },
    async setWindowKeepScreenOn(on) { this.keep = on; } };
  class MethodChannel {
    constructor(messenger, name) { this.messenger = messenger; this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod(method, args) { events.push({ channel: this.name, method, ...Object.fromEntries(args) }); }
  }
  const boundaries = {
    '@ohos/flutter_ohos': { MethodChannel },
    '@ohos.multimedia.audio': { default: audio },
    '@ohos.systemDateTime': { default: { TimeType: { STARTUP: 0 }, getUptime() { return 0; } } },
    '@ohos.window': { default: { async getLastWindow() { return screen; } } },
    '@ohos.abilityAccessCtrl': { default: { GrantStatus: { PERMISSION_GRANTED: 0 }, createAtManager: () => ({
      async checkAccessToken(token, permission) { assert.equal(token, 321); assert.equal(permission, 'ohos.permission.MICROPHONE'); return 0; }
    }) } },
    '@kit.CoreSpeechKit': { textToSpeech: { async createEngine(config) { trace.push({ method: 'tts.create', config }); return new TtsEngine(config); } } }
  };
  function load(path) {
    if (cache.has(path)) return cache.get(path).exports;
    inputs.set(path, hash(path));
    const module = { exports: {} }; cache.set(path, module);
    const result = ts.transpileModule(fs.readFileSync(path, 'utf8'), { fileName: path, reportDiagnostics: true,
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } });
    assert.equal(result.diagnostics?.length ?? 0, 0);
    vm.runInNewContext(result.outputText, {
      module, exports: module.exports, Map, Set, WeakSet, Promise, Error, ArrayBuffer, Uint8Array, DataView, setTimeout, clearTimeout,
      canIUse(cap) { assert(['SystemCapability.Multimedia.Audio.Capturer', 'SystemCapability.Multimedia.Audio.Renderer'].includes(cap)); return true; },
      require(name) {
        if (name.startsWith('.')) return load(resolve(dirname(path), name + '.ets'));
        assert(Object.hasOwn(boundaries, name), 'unadapted SDK boundary: ' + name);
        return boundaries[name];
      }
    }, { filename: path });
    return module.exports;
  }
  const context = { applicationInfo: { accessTokenId: 321 } }, ui = { context };
  const ability = { getAbility: () => ui }, engine = { getBinaryMessenger: () => ui };
  for (const name of ['SpeechPlugin', 'CompanionVoicePlugin']) {
    const Plugin = load(resolve(root, 'app/ohos/entry/src/main/ets/plugins', name + '.ets')).default;
    const plugin = new Plugin(); plugin.onAttachedToEngine(engine); plugin.onAttachedToAbility(ability); Plugin.onForeground(ui);
  }
  function request(channelName, method, args = {}) {
    const channel = channels.find(c => c.name === channelName);
    return new Promise(resolve => channel.handler.onMethodCall({ method, argument: key => args[key] }, {
      success: value => resolve({ value }), error: (error, message, details) => resolve({ error, message, details }),
      notImplemented: () => resolve({ missing: true })
    }));
  }
  return { trace, events, renderers, capturers, engines, screen, session,
    change(next) { Object.assign(options, next); },
    speech: (method, args) => request('dsh/speech', method, args), tts: (method, args) => request('dsh/companion_voice', method, args),
    identities() { return [...inputs].map(([path, sha256]) => ({ path, sha256, afterSha256: hash(path), unchanged: hash(path) === sha256 })); },
    async close() {
      await request('dsh/companion_voice', 'stop'); await request('dsh/speech', 'callStop'); await request('dsh/speech', 'stop');
      assert(capturers.every(c => c.releases === 1)); assert(renderers.every(r => r.releases === 1)); assert(engines.every(e => e.closed));
      assert.equal(screen.keep, false);
    }
  };
}
