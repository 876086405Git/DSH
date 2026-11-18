// dsh/launch_clip: private launch files, public MediaKit, and Flutter textures.
// No NativeHost/engine dependency; Android and the default dsh/launch channel are unchanged.
import fs from '@ohos.file.fs';
import media from '@ohos.multimedia.media';
import image from '@ohos.multimedia.image';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import {
  AbilityAware, AbilityPluginBinding, Any, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodCallHandler, MethodChannel, MethodResult, SurfaceTextureEntry, TextureRegistry
} from '@ohos/flutter_ohos';

class ClipError extends Error {
  readonly code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

// One operation owns its descriptors until every media service using them has released.
// A failed release leaves this object in the plugin's bounded set, for an explicit close
// or a later operation to retry; it must not free a surface still owned by AVPlayer.
class ClipResources {
  active: boolean = true;
  work: Promise<void> | null = null;
  closing: Promise<void> | null = null;
  cancel: (() => void) | null = null;
  fd: number = -1;
  output: number = -1;
  extractor: media.AVMetadataExtractor | null = null;
  generator: media.AVImageGenerator | null = null;
  player: media.AVPlayer | null = null;
  pixels: image.PixelMap | null = null;
  packer: image.ImagePacker | null = null;
  texture: SurfaceTextureEntry | null = null;
  registry: TextureRegistry | null = null;
  textureId: number = -1;
  notify: ((method: string) => void) | null = null;
  temporary: string = '';
  directory: string = '';
  wanted: boolean = false;
  ended: boolean = false;

  check(): void { if (!this.active) throw new ClipError('cancelled', 'Launch clip closed.'); }
  close(): Promise<void> {
    this.active = false;
    this.cancel?.();
    if (this.closing !== null) return this.closing;
    const closing = this.releaseAfterWork();
    this.closing = closing;
    closing.then((): void => { this.closing = null; }, (): void => { this.closing = null; });
    return closing;
  }
  private async releaseAfterWork(): Promise<void> {
    if (this.work !== null) { try { await this.work; } catch (_) {} }
    // Do not put descriptor/surface release in a finally: media release can fail.
    if (this.player !== null) { await this.player.release(); this.player = null; }
    if (this.extractor !== null) { await this.extractor.release(); this.extractor = null; }
    if (this.generator !== null) { await this.generator.release(); this.generator = null; }
    if (this.pixels !== null) { await this.pixels.release(); this.pixels = null; }
    if (this.packer !== null) { await this.packer.release(); this.packer = null; }
    if (this.fd >= 0) { await fs.close(this.fd); this.fd = -1; }
    if (this.output >= 0) { await fs.close(this.output); this.output = -1; }
    if (this.registry !== null && this.textureId >= 0) {
      this.registry.unregisterTexture(this.textureId); this.textureId = -1; this.texture = null; this.registry = null;
    }
    if (this.temporary !== '') {
      try { await fs.unlink(this.temporary); }
      catch (error) { if ((error as BusinessError).code !== 13900002) throw error as Error; }
      this.temporary = '';
    }
    if (this.directory !== '') {
      // rmdir is recursive on OH: only remove this owned, empty temporary directory.
      const stat = await fs.lstat(this.directory);
      if (!stat.isDirectory() || stat.isSymbolicLink() || (await fs.listFile(this.directory)).length !== 0) {
        throw new ClipError('close', 'Launch poster temporary directory changed.');
      }
      await fs.rmdir(this.directory); this.directory = '';
    }
  }
}

export default class LaunchClipPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private channel: MethodChannel | null = null;
  private context: common.Context | null = null;
  private textures: TextureRegistry | null = null;
  private readonly resources: Set<ClipResources> = new Set<ClipResources>();

  getUniqueClassName(): string { return 'DshLaunchClipPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    this.textures = binding.getTextureRegistry();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/launch_clip');
    this.channel.setMethodCallHandler(this);
  }
  onAttachedToAbility(binding: AbilityPluginBinding): void {
    // Match the shipped path_provider getApplicationSupportDirectory exactly.
    this.context = binding.getAbility().context;
  }
  onDetachedFromAbility(): void { if (this.channel === null) this.context = null; }
  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null); this.channel = null;
    this.context = null; this.textures = null;
    this.resources.forEach((resource: ClipResources): void => {
      this.dispose(resource).catch((): void => {
        // Ownership remains retained; never close a descriptor/surface behind MediaKit.
        console.error('Launch clip media release failed during engine detach.');
      });
    });
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (!['probe', 'open', 'play', 'close'].includes(call.method)) { result.notImplemented(); return; }
    this.handle(call).then((value: Any): void => result.success(value), (error: Error): void => {
      const failure = error instanceof ClipError ? error : new ClipError('media', 'Launch clip operation failed.');
      result.error(failure.code, failure.message, null);
    });
  }
  private async handle(call: MethodCall): Promise<Any> {
    if (call.method === 'probe' || call.method === 'open') {
      const path: Any = call.argument('path');
      if (typeof path !== 'string') throw new ClipError('invalid', 'A launch file is required.');
      if (call.method === 'open') return this.open(path);
      const poster: Any = call.argument('poster');
      if (typeof poster !== 'string') throw new ClipError('invalid', 'A launch poster is required.');
      return this.probe(path, poster);
    }
    if (call.method === 'play' || call.method === 'close') {
      const id: Any = call.argument('texture');
      if (typeof id !== 'number' || !Number.isSafeInteger(id)) throw new ClipError('invalid', 'Invalid texture.');
      let found: ClipResources | null = null;
      this.resources.forEach((resource: ClipResources): void => {
        if (resource.texture?.getTextureId() === id) found = resource;
      });
      const resource = found as ClipResources | null;
      if (call.method === 'close') { if (resource !== null) await this.dispose(resource); return null; }
      if (resource === null || !resource.active || resource.player === null || resource.ended) return false;
      if (!resource.wanted) {
        resource.wanted = true;
        try { await resource.player.play(); }
        catch (_) { resource.notify?.('done'); return false; }
      }
      return true;
    }
    throw new ClipError('unsupported', 'Unknown launch clip method.');
  }
  private async dispose(resource: ClipResources): Promise<void> {
    try { await resource.close(); }
    catch (_) { throw new ClipError('close', 'Launch clip resources remain owned by MediaKit.'); }
    this.resources.delete(resource);
  }
  private async allocate(): Promise<ClipResources> {
    for (const old of this.resources) { if (!old.active) await this.dispose(old); }
    if (this.channel === null || this.context === null || this.resources.size >= 4) {
      throw new ClipError('busy', 'Launch clip resources unavailable.');
    }
    const resource = new ClipResources(); this.resources.add(resource); return resource;
  }
  private async validate(path: string, root: string): Promise<void> {
    const prefix = root + '/launch/';
    if (!path.startsWith(prefix)) throw new ClipError('invalid', 'Not a private launch file.');
    const leaf = path.substring(prefix.length);
    if (leaf === '' || leaf === '.' || leaf === '..' || leaf.includes('/') || leaf.includes('\\') || leaf.includes('\0')) {
      throw new ClipError('invalid', 'Not a private launch file.');
    }
    const directory = await fs.lstat(root + '/launch');
    if (!directory.isDirectory() || directory.isSymbolicLink()) throw new ClipError('invalid', 'Launch directory changed.');
  }
  private async input(resource: ClipResources, path: string, root: string): Promise<number> {
    await this.validate(path, root); resource.check();
    resource.fd = (await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW | fs.OpenMode.NONBLOCK)).fd;
    resource.check();
    const stat = await fs.stat(resource.fd); resource.check();
    if (!stat.isFile() || !Number.isSafeInteger(stat.size) || stat.size <= 0 || stat.size > 30 * 1024 * 1024) {
      throw new ClipError('invalid', 'Launch video must be a regular file of at most 30 MiB.');
    }
    return stat.size;
  }
  private async absent(path: string): Promise<void> {
    try { await fs.lstat(path); }
    catch (error) { if ((error as BusinessError).code === 13900002) return; throw error as Error; }
    throw new ClipError('invalid', 'Launch poster already exists.');
  }
  private async probe(path: string, poster: string): Promise<Any> {
    const resource = await this.allocate();
    const root = this.context!.filesDir;
    let answer: Map<string, Any> | null = null;
    resource.work = (async (): Promise<void> => {
      const size = await this.input(resource, path, root);
      await this.validate(poster, root); resource.check(); await this.absent(poster); resource.check();
      resource.extractor = await media.createAVMetadataExtractor(); resource.check();
      resource.extractor.fdSrc = { fd: resource.fd, offset: 0, length: size };
      const metadata = await resource.extractor.fetchMetadata(); resource.check();
      const duration = Number(metadata.duration), width = Number(metadata.videoWidth), height = Number(metadata.videoHeight);
      const orientation = Number(metadata.videoOrientation ?? '0');
      // Positive video dimensions plus a successfully decoded frame establish a video.
      // hasVideo's string values are not specified by the public SDK; do not assume Android's 'yes'.
      if (!Number.isSafeInteger(duration) || duration <= 0 ||
        !Number.isSafeInteger(width) || width <= 0 || !Number.isSafeInteger(height) || height <= 0 ||
        ![0, 90, 180, 270].includes(orientation)) throw new ClipError('media', 'Unreadable launch video.');
      // The descriptor is reused only after the first media owner has released it.
      await resource.extractor.release(); resource.extractor = null; resource.check();
      resource.generator = await media.createAVImageGenerator(); resource.check();
      resource.generator.fdSrc = { fd: resource.fd, offset: 0, length: size };
      const scale = Math.min(1, 1440 / Math.max(width, height));
      resource.pixels = await resource.generator.fetchFrameByTime(0, media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC,
        { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) });
      resource.check();
      // Preserve the public generator's pixels; never guess rotation from dimensions
      // (square/180-degree clips make that ambiguous). Device orientation remains a device check.
      const frame = (await resource.pixels.getImageInfo()).size; resource.check();
      if (frame.width <= 0 || frame.height <= 0 || Math.max(frame.width, frame.height) > 1440) {
        throw new ClipError('media', 'Launch poster exceeds the bounded frame size.');
      }
      resource.packer = image.createImagePacker();
      const png = await resource.packer.packToData(resource.pixels, { format: 'image/png', quality: 100 }); resource.check();
      if (png.byteLength === 0 || png.byteLength > 8 * 1024 * 1024) throw new ClipError('media', 'Launch poster is too large.');
      // Write inside an exclusively created private directory, then publish by rename.
      // Never open the caller's destination for writing (including a symlink destination).
      resource.directory = await fs.mkdtemp(root + '/launch/poster-XXXXXX'); resource.check();
      resource.temporary = resource.directory + '/frame.png';
      resource.output = (await fs.open(resource.temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW)).fd;
      resource.check();
      let offset = 0;
      while (offset < png.byteLength) {
        const written = await fs.write(resource.output, png.slice(offset), { offset }); resource.check();
        if (!Number.isSafeInteger(written) || written <= 0 || written > png.byteLength - offset) throw new ClipError('media', 'Incomplete poster.');
        offset += written;
      }
      await fs.fsync(resource.output); await fs.close(resource.output); resource.output = -1; resource.check();
      await this.validate(poster, root); await this.absent(poster); resource.check();
      // Both paths are app-owned. A raced destination is replaced, never followed.
      await fs.rename(resource.temporary, poster); resource.temporary = ''; resource.check();
      const rotated = orientation === 90 || orientation === 270;
      answer = new Map<string, Any>();
      answer.set('durationMs', duration); answer.set('width', rotated ? height : width); answer.set('height', rotated ? width : height);
    })();
    try { await resource.work; }
    catch (_) { await this.dispose(resource); return null; }
    await this.dispose(resource); return answer;
  }
  private async open(path: string): Promise<Any> {
    const resource = await this.allocate();
    const root = this.context!.filesDir, textures = this.textures!;
    const channel = this.channel!;
    resource.work = (async (): Promise<void> => {
      const size = await this.input(resource, path, root);
      resource.player = await media.createAVPlayer(); resource.check();
      const player = resource.player;
      resource.textureId = textures.getTextureId();
      if (!Number.isSafeInteger(resource.textureId) || resource.textureId < 0) throw new ClipError('media', 'Invalid texture identifier.');
      resource.registry = textures;
      resource.texture = textures.registerTexture(resource.textureId); resource.check();
      const texture = resource.texture, id = texture.getTextureId(), surface = texture.getSurfaceId();
      if (!Number.isSafeInteger(id) || id < 0 || !Number.isSafeInteger(surface) || surface <= 0) {
        throw new ClipError('media', 'Surface identifier cannot be represented exactly.');
      }
      const notify = (method: string): void => {
        if (!resource.active || this.channel !== channel) return;
        if (method === 'done') { if (resource.ended) return; resource.ended = true; }
        const event: Map<string, Any> = new Map<string, Any>(); event.set('texture', id);
        channel.invokeMethod(method, event);
      };
      resource.notify = notify;
      await new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
        let settled = false, preparing = false;
        const timer = setTimeout((): void => finish(new ClipError('media', 'Launch preparation timed out.') as Error), 10000);
        const finish = (error: Error | null): void => {
          if (settled) return; settled = true; clearTimeout(timer); resource.cancel = null;
          if (error === null) resolve(); else reject(error);
        };
        resource.cancel = (): void => finish(new ClipError('cancelled', 'Launch clip closed.') as Error);
        player.on('error', (_error: BusinessError): void => { finish(new ClipError('media', 'Launch player failed.') as Error); notify('done'); });
        player.on('startRenderFrame', (): void => {
          // MediaKit has handed the frame to the display module, not proof of presentation.
          notify('showing');
        });
        player.on('stateChange', (state: media.AVPlayerState): void => {
          if (!resource.active) return;
          if (state === 'initialized' && !preparing) {
            preparing = true;
            try {
              player.surfaceId = surface.toString();
              player.prepare().catch((error: Error): void => finish(error));
            } catch (error) { finish(error as Error); }
          } else if (state === 'prepared') {
            try {
              if (player.width > 0 && player.height > 0) textures.setTextureBufferSize(id, player.width, player.height);
              player.loop = false; player.setVolume(0); finish(null);
            }
            catch (error) { finish(error as Error); }
          } else if (state === 'completed') notify('done');
          else if (state === 'error') { finish(new ClipError('media', 'Launch player failed.') as Error); notify('done'); }
        });
        player.fdSrc = { fd: resource.fd, offset: 0, length: size };
      });
      resource.check();
    })();
    try { await resource.work; resource.check(); }
    catch (_) { await this.dispose(resource); return null; }
    const answer: Map<string, Any> = new Map<string, Any>(); answer.set('texture', resource.texture!.getTextureId()); return answer;
  }
}
