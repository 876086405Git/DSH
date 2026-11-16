// dsh/companion_voice matches Android's system voice channel. 未在真机核实。
// Core Speech Kit API 11+, offline zh-CN; no microphone or background permission.
import UIAbility from '@ohos.app.ability.UIAbility';
import type { textToSpeech } from '@kit.CoreSpeechKit';
import {
  AbilityAware, AbilityPluginBinding, Any, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodCallHandler, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { OhosSpeechPlayback, SpeechPlaybackOwner } from './OhosSpeechPlayback';

class TtsRequest {
  id: string;
  methods: MethodChannel;
  started: boolean = false;
  constructor(id: string, methods: MethodChannel) { this.id = id; this.methods = methods; }
}

class TtsListener implements textToSpeech.SpeakListener {
  private plugin: CompanionVoicePlugin;
  constructor(plugin: CompanionVoicePlugin) { this.plugin = plugin; }
  onStart(id: string, _response: textToSpeech.StartResponse): void { this.plugin.started(id); }
  onComplete(id: string, response: textToSpeech.CompleteResponse): void {
    if (response.type === 1) this.plugin.terminal(id, 'done');
  }
  onStop(id: string, _response: textToSpeech.StopResponse): void { this.plugin.terminal(id, 'stopped'); }
  onError(id: string, _code: number, _message: string): void { this.plugin.terminal(id, 'error'); }
}

class TtsChannelHandler implements MethodCallHandler {
  private plugin: CompanionVoicePlugin;
  private binding: FlutterPluginBinding;
  constructor(plugin: CompanionVoicePlugin, binding: FlutterPluginBinding) {
    this.plugin = plugin; this.binding = binding;
  }
  onMethodCall(call: MethodCall, result: MethodResult): void { this.plugin.callBound(call, result, this.binding); }
}

export default class CompanionVoicePlugin implements FlutterPlugin, AbilityAware, SpeechPlaybackOwner {
  private static current: CompanionVoicePlugin | null = null;
  private static physical: CompanionVoicePlugin | null = null;
  private static foreground: WeakSet<UIAbility> = new WeakSet<UIAbility>();
  private static serial: number = 0;
  private engine: FlutterPluginBinding | null = null;
  private ability: AbilityPluginBinding | null = null;
  private methods: MethodChannel | null = null;
  private tts: textToSpeech.TextToSpeechEngine | null = null;
  private opening: Promise<boolean> | null = null;
  private closing: Promise<void> | null = null;
  private generation: number = 0;
  private speechGeneration: number = 0;
  private initialized: boolean = false;
  private prepared: boolean = false;
  private requests: Map<string, TtsRequest> = new Map<string, TtsRequest>();

  getUniqueClassName(): string { return 'DshCompanionVoicePlugin'; }

  static onForeground(ability: UIAbility): void { CompanionVoicePlugin.foreground.add(ability); }
  static onBackground(ability: UIAbility): void {
    CompanionVoicePlugin.foreground.delete(ability);
    const plugin: CompanionVoicePlugin | null = CompanionVoicePlugin.current;
    if (plugin?.ability?.getAbility() === ability) plugin.retire();
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    CompanionVoicePlugin.current?.retire();
    this.methods?.setMethodCallHandler(null);
    CompanionVoicePlugin.current = this;
    this.engine = binding;
    this.ability = null; this.prepared = false;
    this.methods = new MethodChannel(binding.getBinaryMessenger(), 'dsh/companion_voice');
    this.methods.setMethodCallHandler(new TtsChannelHandler(this, binding));
  }

  callBound(call: MethodCall, result: MethodResult, binding: FlutterPluginBinding): void {
    if (!['ready', 'speak', 'play', 'stop'].includes(call.method)) {
      try { result.notImplemented(); } catch (_) {} return;
    }
    this.handle(call, binding).then((value: Any): void => {
      try { result.success(value); } catch (_) {}
    }, (_error: Error): void => {
      try { result.error('speech-output', '系统朗读尚未停止，请重试或重新打开应用。', null); } catch (_) {}
    });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.engine !== binding) return;
    this.retire(); this.methods?.setMethodCallHandler(null);
    this.engine = null; this.ability = null; this.methods = null;
    if (CompanionVoicePlugin.current === this) CompanionVoicePlugin.current = null;
  }
  onAttachedToAbility(binding: AbilityPluginBinding): void {
    if (this.ability !== null && this.ability !== binding) this.retire();
    this.ability = binding;
  }
  onDetachedFromAbility(): void { this.retire(); this.ability = null; }

  private onScreen(): boolean {
    return CompanionVoicePlugin.current === this && this.ability !== null &&
      CompanionVoicePlugin.foreground.has(this.ability.getAbility());
  }
  private emit(type: string, request: TtsRequest): void {
    const methods: MethodChannel = request.methods;
    const event: Map<string, Any> = new Map<string, Any>([
      ['type', type], ['id', request.id], ['start', null], ['end', null]
    ]);
    try { methods.invokeMethod('event', event); } catch (_) {}
  }
  started(id: string): void {
    const request: TtsRequest | undefined = this.requests.get(id);
    if (request === undefined || request.started || !this.onScreen() || !OhosSpeechPlayback.isCurrent(this)) return;
    request.started = true; this.emit('start', request);
  }
  terminal(id: string, type: string): void {
    const request: TtsRequest | undefined = this.requests.get(id);
    if (request === undefined) return;
    this.requests.delete(id); this.emit(type, request);
  }
  private finishRequests(type: string): void {
    this.requests.forEach((request: TtsRequest): void => this.emit(type, request));
    this.requests.clear();
  }

  private async ready(): Promise<boolean> {
    if (!this.onScreen()) return false;
    const generation: number = this.generation;
    try {
      if (this.closing !== null) await this.closing;
      const previous: CompanionVoicePlugin | null = CompanionVoicePlugin.physical;
      if (previous !== null && previous !== this) await previous.stopPlayback();
      if (!this.onScreen() || this.generation !== generation) return false;
      if (this.tts !== null) return this.initialized;
      if (this.opening === null) {
        CompanionVoicePlugin.physical = this;
        this.opening = this.create(generation);
      }
      const work: Promise<boolean> = this.opening;
      try { return await work && this.onScreen() && generation === this.generation; }
      finally { if (this.opening === work) this.opening = null; }
    } catch (_) { return false; }
  }

  private async create(generation: number): Promise<boolean> {
    try {
      const module: ESObject = await import('./HmsTextToSpeechKit');
      const params: textToSpeech.CreateEngineParams = {
        language: 'zh-CN', person: 0, online: 1,
        extraParams: { name: 'dshGoSystemVoice', isBackStage: false }
      };
      const tts: textToSpeech.TextToSpeechEngine = await module.textToSpeech.createEngine(params);
      this.tts = tts; this.initialized = false;
      tts.setListener(new TtsListener(this));
      this.initialized = true;
      if (generation !== this.generation || !this.onScreen()) return false;
      this.prepared = true;
      return true;
    } catch (_) {
      // Preserve a failed-to-release engine; the next explicit stop retries it.
      if (this.tts !== null) {
        try { this.tts.shutdown(); this.tts = null; } catch (_) {}
      }
      return false;
    }
  }

  private async speak(call: MethodCall): Promise<boolean> {
    const id: Any = call.argument('id');
    const text: Any = call.argument('text');
    const rateValue: Any = call.argument('rate');
    const pitchValue: Any = call.argument('pitch');
    const forCall: Any = call.argument('call');
    const rate: Any = rateValue === null || rateValue === undefined ? 1 : rateValue;
    const pitch: Any = pitchValue === null || pitchValue === undefined ? 1 : pitchValue;
    if (typeof id !== 'string' || id.length === 0 || typeof text !== 'string' || text.length === 0 || text.length > 10000 ||
      typeof rate !== 'number' || !Number.isFinite(rate) || rate < 0.5 || rate > 2 ||
      typeof pitch !== 'number' || !Number.isFinite(pitch) || pitch < 0.5 || pitch > 2 || !this.onScreen() || !this.prepared || this.methods === null) return false;
    if (forCall !== null && forCall !== undefined && typeof forCall !== 'boolean') return false;
    const flush: boolean = call.argument('flush') === true;
    // Replace every earlier speak before yielding, including requests still
    // waiting for an engine or the PCM owner. Later queue entries share this
    // speech generation; the engine's creation generation remains unchanged.
    if (flush) this.speechGeneration++;
    const speechGeneration: number = this.speechGeneration;
    const generation: number = this.generation;
    if (flush && this.tts !== null) {
      try { this.tts.stop(); this.finishRequests('stopped'); } catch (_) { return false; }
    }
    if (!await this.ready() || generation !== this.generation || speechGeneration !== this.speechGeneration || this.tts === null) return false;
    const tts: textToSpeech.TextToSpeechEngine = this.tts;
    try {
      if (!await OhosSpeechPlayback.claim(this) || generation !== this.generation || speechGeneration !== this.speechGeneration ||
        !this.onScreen() || this.tts !== tts) return false;
    } catch (_) { return false; }
    const nativeId: string = 'dsh' + (++CompanionVoicePlugin.serial).toString(36);
    const params: textToSpeech.SpeakParams = {
      requestId: nativeId,
      // StreamUsage 2 is VOICE_COMMUNICATION; ordinary system voice is 3.
      // This selects the documented call route, not a device AEC guarantee.
      extraParams: { queueMode: 0, playType: 1, speed: rate, pitch: pitch, volume: 1, soundChannel: forCall === true ? 2 : 3 }
    };
    this.requests.set(nativeId, new TtsRequest(id, this.methods));
    try { tts.speak(text, params); return true; }
    catch (_) { this.requests.delete(nativeId); return false; }
  }

  stopPlayback: () => Promise<void> = (): Promise<void> => {
    this.generation++;
    if (this.closing !== null) return this.closing;
    const work: Promise<void> = this.close();
    this.closing = work;
    work.then((): void => { if (this.closing === work) this.closing = null; },
      (): void => { if (this.closing === work) this.closing = null; });
    return work;
  };

  private async close(): Promise<void> {
    try { await this.opening; } catch (_) {}
    this.initialized = false;
    const tts: textToSpeech.TextToSpeechEngine | null = this.tts;
    if (tts !== null) {
      try { tts.stop(); } catch (_) { /* shutdown is the resource-retirement operation */ }
      try { tts.shutdown(); }
      catch (_) { this.finishRequests('error'); throw new Error('TTS shutdown failed'); }
      this.tts = null; this.initialized = false;
    }
    this.finishRequests('stopped');
    if (CompanionVoicePlugin.physical === this) CompanionVoicePlugin.physical = null;
  }

  private retire(): void { OhosSpeechPlayback.release(this).catch((): void => {}); }

  private async handle(call: MethodCall, binding: FlutterPluginBinding): Promise<Any> {
    if (this.engine !== binding || CompanionVoicePlugin.current !== this) return call.method === 'stop' ? null : false;
    if (call.method === 'stop') { await OhosSpeechPlayback.release(this); return null; }
    if (call.method === 'ready') {
      const language: Any = call.argument('language');
      if (language !== null && language !== undefined && language !== 'zh-CN') return false;
      return this.ready();
    }
    if (call.method === 'speak') return this.speak(call);
    return false; // Encoded external-voice files do not have a matching player in this path.
  }
}
