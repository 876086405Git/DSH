// dsh/media_video: local materialized chat videos, unchanged Android/Dart wire.
import UIAbility from '@ohos.app.ability.UIAbility';
import common from '@ohos.app.ability.common';
import {
  AbilityAware, AbilityPluginBinding, Any, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodCallHandler, MethodChannel, MethodResult, TextureRegistry
} from '@ohos/flutter_ohos';
import { RuntimePaths } from '../runtime/RuntimePaths';
import { MediaVideoError, MediaVideoOpener, OhosMediaVideo } from './OhosMediaVideo';

class VideoReply {
  cancelled: boolean = false;
  onCancel: (() => void) | null = null;
  private readonly result: MethodResult;
  private answered: boolean = false;
  private timer: number = -1;
  constructor(result: MethodResult, timeout: number, timeoutMessage: string) {
    this.result = result;
    if (timeout > 0) this.timer = setTimeout((): void => this.cancel('timeout', timeoutMessage), timeout);
  }
  success(value: Any): void {
    if (this.answered) return;
    this.answered = true; clearTimeout(this.timer);
    try { this.result.success(value); } catch (_) {}
  }
  error(code: string, message: string = 'video unavailable'): void {
    if (this.answered) return;
    this.answered = true; clearTimeout(this.timer);
    try { this.result.error(code, message, null); } catch (_) {}
  }
  missing(): void {
    if (this.answered) return;
    this.answered = true; clearTimeout(this.timer);
    try { this.result.notImplemented(); } catch (_) {}
  }
  cancel(code: string, message: string = 'video unavailable'): void { this.cancelled = true; this.onCancel?.(); this.error(code, message); }
}

class VideoHandler implements MethodCallHandler {
  private readonly plugin: MediaVideoPlugin;
  private readonly binding: FlutterPluginBinding;
  constructor(plugin: MediaVideoPlugin, binding: FlutterPluginBinding) { this.plugin = plugin; this.binding = binding; }
  onMethodCall(call: MethodCall, result: MethodResult): void { this.plugin.callBound(call, result, this.binding); }
}

export default class MediaVideoPlugin implements FlutterPlugin, AbilityAware {
  private static current: MediaVideoPlugin | null = null;
  private static foreground: WeakSet<UIAbility> = new WeakSet<UIAbility>();
  private static playback: OhosMediaVideo | null = null;
  private static opening: OhosMediaVideo | null = null;
  private static poster: OhosMediaVideo | null = null;
  private readonly opener: MediaVideoOpener;
  private engine: FlutterPluginBinding | null = null;
  private ability: AbilityPluginBinding | null = null;
  private context: common.Context | null = null;
  private textures: TextureRegistry | null = null;
  private methods: MethodChannel | null = null;
  private generation: number = 0;
  private openGeneration: number = 0;
  private clip: OhosMediaVideo | null = null;
  private pendingOpen: VideoReply | null = null;
  private pendingPoster: VideoReply | null = null;
  constructor(opener: MediaVideoOpener) { this.opener = opener; }
  getUniqueClassName(): string { return 'DshMediaVideoPlugin'; }

  static onForeground(ability: UIAbility): void { MediaVideoPlugin.foreground.add(ability); }
  static onBackground(ability: UIAbility): void {
    MediaVideoPlugin.foreground.delete(ability);
    const plugin: MediaVideoPlugin | null = MediaVideoPlugin.current;
    const clip: OhosMediaVideo | null = plugin?.ability?.getAbility() === ability ? plugin.clip : null;
    clip?.pause().catch((): void => { clip.close().catch((): void => {}); });
  }
  static onDestroy(ability: UIAbility): void {
    MediaVideoPlugin.foreground.delete(ability);
    const plugin: MediaVideoPlugin | null = MediaVideoPlugin.current;
    if (plugin?.ability?.getAbility() === ability) plugin.retire();
  }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    MediaVideoPlugin.current?.retire(); this.methods?.setMethodCallHandler(null);
    MediaVideoPlugin.current = this; this.engine = binding; this.context = binding.getApplicationContext();
    this.textures = binding.getTextureRegistry(); this.ability = null;
    this.methods = new MethodChannel(binding.getBinaryMessenger(), 'dsh/media_video');
    this.methods.setMethodCallHandler(new VideoHandler(this, binding));
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.engine !== binding) return;
    this.retire(); this.methods?.setMethodCallHandler(null);
    this.methods = null; this.engine = null; this.ability = null; this.context = null; this.textures = null;
    if (MediaVideoPlugin.current === this) MediaVideoPlugin.current = null;
  }
  onAttachedToAbility(binding: AbilityPluginBinding): void {
    if (this.ability !== null && this.ability !== binding) this.retire();
    this.ability = binding;
  }
  onDetachedFromAbility(): void { this.retire(); this.ability = null; }
  private retire(): void {
    this.generation++; this.openGeneration++;
    this.pendingOpen?.cancel('closed'); this.pendingPoster?.cancel('closed');
    this.clip?.close().catch((): void => {});
  }
  private onScreen(): boolean {
    return MediaVideoPlugin.current === this && this.ability !== null && MediaVideoPlugin.foreground.has(this.ability.getAbility());
  }

  callBound(call: MethodCall, result: MethodResult, binding: FlutterPluginBinding): void {
    const reply: VideoReply = new VideoReply(result, call.method === 'open' ? 20000 : call.method === 'poster' ? 10000 : 0,
      call.method === 'poster' ? 'poster extraction timed out' : 'video unavailable');
    if (this.engine !== binding || MediaVideoPlugin.current !== this) { reply.error('closed'); return; }
    const id: Any = call.argument('texture');
    const clip: OhosMediaVideo | null = typeof id === 'number' && Number.isSafeInteger(id) && this.clip?.textureId === id ? this.clip : null;
    if (!['open', 'poster', 'close', 'play', 'pause', 'seek', 'state'].includes(call.method)) {
      if (clip === null || !clip.active || !clip.prepared) reply.error('closed'); else reply.missing();
      return;
    }
    this.handle(call, reply, clip).then((value: Any): void => reply.success(value), (error: Error): void => {
      if (error instanceof MediaVideoError) reply.error(error.code, error.message);
      else reply.error(call.method === 'open' ? 'unsupported' : 'playback', 'video playback failed');
    });
  }

  private local(path: Any): string[] {
    const context: common.Context | null = this.context;
    if (context === null || typeof path !== 'string' || !path.startsWith('/') || /[\x00-\x1f\x7f\\]/.test(path)) {
      throw new MediaVideoError('invalid', 'a local video file is required');
    }
    const parts: string[] = path.split('/');
    for (let i: number = 1; i < parts.length; i++) {
      if (parts[i] === '' || parts[i] === '.' || parts[i] === '..') throw new MediaVideoError('invalid');
    }
    // Match FilesMediaPlugin's existing materialized-file roots. Whole filesDir
    // and LaunchClip's private launch directory are not added to this authority.
    const roots: string[] = [new RuntimePaths(context.filesDir).workspace, context.cacheDir, context.tempDir];
    const ui: common.UIAbilityContext | undefined = this.ability?.getAbility().context;
    if (ui !== undefined) { roots.push(ui.cacheDir, ui.tempDir); }
    for (let i: number = 0; i < roots.length; i++) {
      if (path.startsWith(roots[i] + '/')) return [roots[i], path.substring(roots[i].length + 1)];
    }
    throw new MediaVideoError('invalid', 'a local materialized video file is required');
  }

  private async open(path: Any, reply: VideoReply): Promise<Any> {
    const local: string[] = this.local(path);
    const generation: number = this.generation, request: number = ++this.openGeneration;
    this.pendingOpen?.cancel('closed'); this.pendingOpen = reply;
    let resource: OhosMediaVideo | null = null;
    try {
      const opening: OhosMediaVideo | null = MediaVideoPlugin.opening;
      if (opening !== null) await opening.close();
      if (reply.cancelled || generation !== this.generation || request !== this.openGeneration || this.textures === null) {
        throw new MediaVideoError('closed');
      }
      let activated: boolean = false;
      const owned: OhosMediaVideo = new OhosMediaVideo(this.opener,
        (): boolean => generation === this.generation && MediaVideoPlugin.current === this &&
          (activated ? this.clip === owned : request === this.openGeneration),
        (): boolean => this.onScreen(), (): void => {
          if (MediaVideoPlugin.opening === owned) MediaVideoPlugin.opening = null;
          if (MediaVideoPlugin.playback === owned) MediaVideoPlugin.playback = null;
          if (this.clip === owned) this.clip = null;
        });
      resource = owned; MediaVideoPlugin.opening = owned;
      reply.onCancel = (): void => { owned.close().catch((): void => {}); };
      await owned.start(local[0], local[1], this.textures, async (): Promise<void> => {
        // Native FD validation has completed. Invalid input must leave the
        // current clip playing, as Android checks localFile before closeAll.
        const previous: OhosMediaVideo | null = MediaVideoPlugin.playback;
        if (previous !== null) await previous.close();
        if (reply.cancelled || generation !== this.generation || request !== this.openGeneration) throw new MediaVideoError('closed');
        activated = true; MediaVideoPlugin.opening = null;
        MediaVideoPlugin.playback = owned; this.clip = owned;
      });
      return owned.opened();
    }
    catch (error) { resource?.close().catch((): void => {}); throw error as Error; }
    finally { if (this.pendingOpen === reply) this.pendingOpen = null; }
  }

  private async poster(path: Any, reply: VideoReply): Promise<Any> {
    const local: string[] = this.local(path);
    const generation: number = this.generation;
    const previous: OhosMediaVideo | null = MediaVideoPlugin.poster;
    if (previous !== null) {
      if (!previous.workDone) return null;
      try { await previous.close(); } catch (_) { return null; }
    }
    if (reply.cancelled || generation !== this.generation || MediaVideoPlugin.current !== this || MediaVideoPlugin.poster !== null) return null;
    const resource: OhosMediaVideo = new OhosMediaVideo(this.opener,
      (): boolean => generation === this.generation && MediaVideoPlugin.current === this,
      (): boolean => this.onScreen(), (): void => { if (MediaVideoPlugin.poster === resource) MediaVideoPlugin.poster = null; });
    MediaVideoPlugin.poster = resource; this.pendingPoster = reply;
    reply.onCancel = (): void => { resource.close().catch((): void => {}); };
    let bytes: Uint8Array | null = null;
    let invalid: boolean = false;
    try { bytes = await resource.poster(local[0], local[1]); }
    catch (error) { invalid = error instanceof MediaVideoError && error.code === 'invalid'; }
    try { await resource.close(); } catch (_) { bytes = null; }
    if (this.pendingPoster === reply) this.pendingPoster = null;
    if (invalid) throw new MediaVideoError('invalid', 'a local video file is required');
    return bytes;
  }

  private async handle(call: MethodCall, reply: VideoReply, clip: OhosMediaVideo | null): Promise<Any> {
    if (call.method === 'open') return this.open(call.argument('path'), reply);
    if (call.method === 'poster') return this.poster(call.argument('path'), reply);
    if (call.method === 'close') { if (clip !== null) await clip.close(); return null; }
    if (clip === null || !clip.active || !clip.prepared) throw new MediaVideoError('closed', 'video is closed');
    if (call.method === 'play' && !this.onScreen()) throw new MediaVideoError('background', 'app is not in foreground');
    try {
      if (call.method === 'state') return clip.state();
      if (call.method === 'play') await clip.play();
      else if (call.method === 'pause') await clip.pause();
      else {
        const position: Any = call.argument('positionMs');
        await clip.seek(typeof position === 'number' && Number.isFinite(position) ? position : 0);
      }
      return null;
    } catch (error) {
      clip.close().catch((): void => {});
      if (error instanceof MediaVideoError) throw error as Error;
      throw new MediaVideoError('playback', 'video playback failed');
    }
  }
}
