// Actual ETS backend/queue, explicit AudioRenderer and timer boundaries.
// No claim that this fixture plays sound, grants device focus, or compiles ArkTS.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

assert(process.env.OHOS_TYPESCRIPT_PREFIX, 'set OHOS_TYPESCRIPT_PREFIX to TypeScript 5.9.3');
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
assert.equal(ts.version, '5.9.3');
const repo = fileURLToPath(new URL('../../../', import.meta.url));
export const deferred = () => Promise.withResolvers();
export async function until(check, description = 'condition') {
  const deadline = Date.now() + 4000;
  while (!check()) {
    if (Date.now() >= deadline) throw new Error('Timed out: ' + description);
    await new Promise(resolve => setTimeout(resolve, 1));
  }
}

export function pcmFixture(options = {}) {
  let config = options, inWrite = false, current = true;
  const cache = new Map(), renderers = [], calls = [], events = [], timers = new Map();
  let nextTimer = 1;
  const state = { STATE_PREPARED: 1, STATE_RUNNING: 2, STATE_STOPPED: 3, STATE_RELEASED: 4, STATE_PAUSED: 5 };
  const format = { samplingRate: 24000, channels: 1, sampleFormat: 1, encodingType: 0 };
  const api = name => { assert(!inWrite, 'AudioRenderer API called in writeData: ' + name); calls.push(name); };
  class Renderer {
    constructor(settings) {
      this.settings = settings; this.listeners = new Map(); this.allListeners = new Map();
      this.state = state.STATE_PREPARED; this.starts = 0; this.stops = 0; this.releases = 0;
      this.drains = 0; this.pauses = 0; this.flushes = 0;
      this.volumes = []; this.uncommitted = []; this.committed = [];
      this.formatChecks = 0; this.released = false; renderers.push(this);
      this.framePos = 0; this.timestampReads = 0;
      this.outputDevices = [];
    }
    getStreamInfoSync() {
      api('format'); this.formatChecks++;
      if (config.formatThrow) throw Error('controlled format');
      if (config.formatHook) config.formatHook(this);
      return { ...format, ...config.format, ...(this.formatChecks > 1 ? config.afterFormat : {}) };
    }
    getBufferSizeSync() { api('buffer-size'); return config.bufferSize ?? 8; }
    getAudioTimestampInfoSync() {
      api('timestamp'); this.timestampReads++;
      if (config.timestampError) throw Error('controlled timestamp');
      return { framePos: this.framePos, timestamp: this.framePos * 1e9 / 24000 };
    }
    on(name, callback) {
      api('on:' + name); if (config.onFailure === name) throw Error('controlled on');
      this.listeners.set(name, callback); this.allListeners.set(name, callback);
    }
    off(name) {
      api('off:' + name); if (config.offFailure === name) throw Error('controlled off');
      this.listeners.delete(name);
    }
    async setInterruptMode(mode) { api('interrupt-mode'); this.mode = mode; if (config.mode) await config.mode(this); }
    async setDefaultOutputDevice(device) {
      api('output-device');
      if (config.outputDevice) await config.outputDevice(this, device);
      this.outputDevices.push(device);
    }
    async start() {
      api('start'); this.starts++; this.state = state.STATE_RUNNING;
      if (config.start) await config.start(this);
      if (config.startState !== undefined) this.state = config.startState;
    }
    async stop() {
      api('stop'); this.stops++; if (config.stop) await config.stop(this);
      this.state = state.STATE_STOPPED;
    }
    async pause() {
      api('pause'); this.pauses++; if (config.pause) await config.pause(this);
      this.state = state.STATE_PAUSED;
    }
    async flush() {
      api('flush'); this.flushes++; if (config.flush) await config.flush(this);
      this.uncommitted.length = 0; this.committed.length = 0;
    }
    async release() {
      api('release'); this.releases++; if (config.release) await config.release(this);
      assert(!this.released, 'successful native release called twice');
      this.state = state.STATE_RELEASED; this.released = true;
    }
    async drain() {
      api('drain'); this.drains++;
      assert.equal(this.uncommitted.length, 0, 'drain raced a VALID callback that has not been submitted');
      if (config.drain) await config.drain(this);
    }
    async setVolume(value) { api('volume'); this.volumes.push(value); if (config.volume) await config.volume(this, value); }
    pump(size = 8, { late = false } = {}) {
      // A subsequent native callback is reachable only after the previous buffer
      // has been submitted/processed. Hold it until that barrier deliberately.
      this.committed.push(...this.uncommitted.splice(0));
      const buffer = new ArrayBuffer(size); new Uint8Array(buffer).fill(0xa5);
      const callback = (late ? this.allListeners : this.listeners).get('writeData');
      assert(callback, 'write callback absent');
      let result;
      inWrite = true;
      try { result = callback(buffer); } finally { inWrite = false; }
      const bytes = new Uint8Array(buffer).slice();
      if (result === 0) this.uncommitted.push(bytes);
      return { result, bytes };
    }
    interrupt(hintType, forceType = 1, { late = false } = {}) {
      (late ? this.allListeners : this.listeners).get('audioInterrupt')?.({ hintType, forceType });
    }
    stateChange(value, { late = false } = {}) {
      this.state = value;
      (late ? this.allListeners : this.listeners).get('stateChange')?.(value);
    }
  }
  const audio = {
    AudioSamplingRate: { SAMPLE_RATE_24000: 24000 }, AudioChannel: { CHANNEL_1: 1 },
    AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 }, AudioEncodingType: { ENCODING_TYPE_RAW: 0 },
    StreamUsage: { STREAM_USAGE_AUDIOBOOK: 12, STREAM_USAGE_VOICE_COMMUNICATION: 2 }, InterruptMode: { INDEPENDENT_MODE: 1 },
    DeviceType: { EARPIECE: 1, SPEAKER: 2, DEFAULT: 1000 },
    InterruptForceType: { INTERRUPT_FORCE: 0, INTERRUPT_SHARE: 1 },
    InterruptHint: { INTERRUPT_HINT_PAUSE: 2, INTERRUPT_HINT_STOP: 3, INTERRUPT_HINT_DUCK: 4,
      INTERRUPT_HINT_UNDUCK: 5, INTERRUPT_HINT_MUTE: 6, INTERRUPT_HINT_RESUME: 1 },
    AudioState: state, AudioDataCallbackResult: { VALID: 0, INVALID: -1 },
    async createAudioRenderer(settings) {
      api('create'); if (config.create) await config.create(settings);
      return config.createNull ? null : new Renderer(settings);
    }
  };
  function load(relative, extraBoundaries = {}) {
    const path = relative.startsWith('/') ? relative : resolve(repo, relative);
    if (cache.has(path)) return cache.get(path).exports;
    const module = { exports: {} }; cache.set(path, module);
    const transformed = ts.transpileModule(fs.readFileSync(path, 'utf8'), {
      reportDiagnostics: true,
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }
    });
    assert.equal(transformed.diagnostics?.length ?? 0, 0, 'TypeScript transpile diagnostics');
    const boundaries = { '@ohos.multimedia.audio': { default: audio },
      '@ohos.systemDateTime': { default: {} }, '@ohos.window': { default: {} },
      '@ohos.abilityAccessCtrl': { default: {} }, ...extraBoundaries };
    try {
      vm.runInNewContext(transformed.outputText, {
        module, exports: module.exports, Map, Set, ArrayBuffer, Uint8Array, DataView, Promise, Error,
        canIUse(capability) {
          if (capability === 'SystemCapability.Multimedia.Audio.Capturer') return false;
          assert.equal(capability, 'SystemCapability.Multimedia.Audio.Renderer'); return config.supported !== false;
        },
        setTimeout(callback, delay) {
          const id = nextTimer++;
          timers.set(id, setTimeout(() => { timers.delete(id); callback(); }, delay));
          return id;
        },
        clearTimeout(id) { clearTimeout(timers.get(id)); timers.delete(id); },
        require(name) {
          if (name.startsWith('.')) return load(resolve(dirname(path), name + '.ets'), extraBoundaries);
          assert(name in boundaries, 'unadapted boundary ' + name); return boundaries[name];
        }
      }, { filename: path });
    } catch (error) { cache.delete(path); throw error; }
    return module.exports;
  }
  const Stream = load('app/ohos/entry/src/main/ets/plugins/OhosPcmStream.ets').OhosPcmStream;
  const Queue = load('app/ohos/entry/src/main/ets/plugins/PcmByteQueue.ets').PcmByteQueue;
  function make(settings = {}, isCurrent = () => current) {
    return new Stream({ rate: 24000, call: false, levels: false, ...settings }, isCurrent, {
      started() { assert(!inWrite); events.push({ kind: 'start' }); if (config.listenerThrows) throw Error('retired listener'); },
      level(value) { assert(!inWrite); events.push({ kind: 'level', value }); },
      terminal(kind, reason) { assert(!inWrite); events.push({ kind, reason }); if (config.listenerThrows) throw Error('retired listener'); }
    });
  }
  return { make, load, Stream, Queue, audio, renderers, calls, events, timers,
    change(next) { config = { ...config, ...next }; },
    setCurrent(value) { current = value; } };
}
