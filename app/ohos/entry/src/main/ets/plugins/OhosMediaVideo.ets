// Public MediaKit, real FD ownership. SDK/codec/audio/texture output remain device checks.
import fs from '@ohos.file.fs';
import media from '@ohos.multimedia.media';
import audio from '@ohos.multimedia.audio';
import image from '@ohos.multimedia.image';
import { BusinessError } from '@ohos.base';
import { Any, SurfaceTextureEntry, TextureRegistry } from '@ohos/flutter_ohos';

export type MediaVideoOpener = (root: string, relative: string) => Promise<number>;

export class MediaVideoError extends Error {
  readonly code: string;
  constructor(code: string, message: string = 'video unavailable') { super(message); this.code = code; }
}

// This object stays reachable until all media owners, the FD and the surface
// retire successfully. A timeout answers the caller; it cannot release a live FD.
export class OhosMediaVideo {
  textureId: number = -1;
  prepared: boolean = false;
  active: boolean = true;
  workDone: boolean = false;
  private readonly opener: MediaVideoOpener;
  private readonly current: () => boolean;
  private readonly foreground: () => boolean;
  private readonly retired: () => void;
  private fd: number = -1;
  private player: media.AVPlayer | null = null;
  private extractor: media.AVMetadataExtractor | null = null;
  private generator: media.AVImageGenerator | null = null;
  private pixels: image.PixelMap | null = null;
  private packer: image.ImagePacker | null = null;
  private registry: TextureRegistry | null = null;
  private texture: SurfaceTextureEntry | null = null;
  private work: Promise<void> | null = null;
  private preparing: Promise<void> | null = null;
  private operations: Promise<void> = Promise.resolve();
  private closing: Promise<void> | null = null;
  private cancelPreparation: ((error: Error) => void) | null = null;
  private wanted: boolean = false;
  private playGeneration: number = 0;
  private failure: MediaVideoError | null = null;

  constructor(opener: MediaVideoOpener, current: () => boolean, foreground: () => boolean, retired: () => void) {
    this.opener = opener; this.current = current; this.foreground = foreground; this.retired = retired;
  }

  private check(): void {
    if (!this.active || !this.current()) throw this.failure ?? new MediaVideoError('closed');
  }

  private async input(root: string, relative: string): Promise<number> {
    this.check();
    try { this.fd = await this.opener(root, relative); }
    catch (_) { throw new MediaVideoError('invalid', 'a local video file is required'); }
    this.check();
    if (!Number.isSafeInteger(this.fd) || this.fd < 0) throw new MediaVideoError('invalid');
    const info: fs.Stat = await fs.stat(this.fd); this.check();
    if (!info.isFile()) throw new MediaVideoError('invalid', 'a local video file is required');
    if (!Number.isSafeInteger(info.size) || info.size <= 0) throw new MediaVideoError('unsupported');
    return info.size;
  }

  start(root: string, relative: string, registry: TextureRegistry, activate: () => Promise<void>): Promise<void> {
    const work: Promise<void> = Promise.resolve().then((): Promise<void> => this.prepare(root, relative, registry, activate));
    this.work = work;
    work.then((): void => { this.workDone = true; }, (): void => { this.workDone = true; });
    return work;
  }

  private async prepare(root: string, relative: string, registry: TextureRegistry, activate: () => Promise<void>): Promise<void> {
    const length: number = await this.input(root, relative);
    await activate(); this.check();
    this.player = await media.createAVPlayer(); this.check();
    const player: media.AVPlayer = this.player;
    this.textureId = registry.getTextureId();
    if (!Number.isSafeInteger(this.textureId) || this.textureId < 0) throw new MediaVideoError('unsupported');
    this.registry = registry; this.texture = registry.registerTexture(this.textureId);
    const texture: SurfaceTextureEntry = this.texture;
    const surface: number = texture.getSurfaceId();
    if (texture.getTextureId() !== this.textureId || !Number.isSafeInteger(surface) || surface <= 0) {
      throw new MediaVideoError('unsupported');
    }
    await new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      let settled: boolean = false;
      const finish: (error: Error | null) => void = (error: Error | null): void => {
        if (settled) return;
        settled = true; this.cancelPreparation = null;
        if (error === null) resolve(); else reject(error);
      };
      this.cancelPreparation = (error: Error): void => finish(error);
      player.on('error', (_error: BusinessError): void => {
        finish(new MediaVideoError('playback') as Error); this.fault();
      });
      player.on('audioInterrupt', (event: audio.InterruptEvent): void => {
        if (!this.active || !this.current()) return;
        // Android pauses even for CAN_DUCK and never resumes on focus gain.
        if ([audio.InterruptHint.INTERRUPT_HINT_PAUSE, audio.InterruptHint.INTERRUPT_HINT_STOP,
          audio.InterruptHint.INTERRUPT_HINT_DUCK].includes(event.hintType)) {
          this.pause().catch((): void => this.fault());
        }
      });
      player.on('stateChange', (state: media.AVPlayerState): void => {
        if (!this.active || !this.current()) return;
        if (state === 'initialized' && this.preparing === null) {
          try {
            player.surfaceId = surface.toString();
            player.audioRendererInfo = { usage: audio.StreamUsage.STREAM_USAGE_MOVIE, rendererFlags: 0 };
            this.preparing = player.prepare();
            this.preparing.catch((error: Error): void => finish(error));
          } catch (error) { finish(error as Error); }
        } else if (state === 'prepared') {
          try {
            if (!Number.isSafeInteger(player.width) || player.width <= 0 || !Number.isSafeInteger(player.height) || player.height <= 0 ||
              !Number.isSafeInteger(player.duration) || player.duration < 0) throw new MediaVideoError('unsupported');
            registry.setTextureBufferSize(this.textureId, player.width, player.height);
            player.loop = false; player.audioInterruptMode = audio.InterruptMode.INDEPENDENT_MODE; player.setVolume(1);
            this.prepared = true; finish(null);
          } catch (error) { finish(error as Error); }
        } else if (state === 'error') { finish(new MediaVideoError('playback') as Error); this.fault(); }
      });
      player.fdSrc = { fd: this.fd, offset: 0, length: length };
    });
    if (this.preparing !== null) await this.preparing;
    this.check();
  }

  opened(): Map<string, Any> {
    this.check();
    const player: media.AVPlayer | null = this.player;
    if (player === null || !this.prepared) throw new MediaVideoError('closed');
    return new Map<string, Any>([['texture', this.textureId], ['width', player.width], ['height', player.height], ['durationMs', player.duration]]);
  }

  state(): Map<string, Any> {
    this.check();
    const player: media.AVPlayer | null = this.player;
    if (player === null || !this.prepared) throw new MediaVideoError('closed');
    if (!Number.isSafeInteger(player.currentTime) || player.currentTime < 0) throw new MediaVideoError('playback');
    return new Map<string, Any>([['positionMs', player.currentTime], ['durationMs', player.duration], ['playing', player.state === 'playing']]);
  }

  private enqueue(action: () => Promise<void>): Promise<void> {
    const next: Promise<void> = this.operations.then(action);
    this.operations = next.then((): void => {}, (): void => {});
    return next;
  }

  play(): Promise<void> {
    this.check(); this.wanted = true;
    const generation: number = ++this.playGeneration;
    return this.enqueue(async (): Promise<void> => {
      this.check();
      if (generation !== this.playGeneration || !this.wanted) return;
      if (!this.foreground()) throw new MediaVideoError('background', 'app is not in foreground');
      const player: media.AVPlayer | null = this.player;
      if (player === null || !this.prepared) throw new MediaVideoError('closed');
      if (['prepared', 'paused', 'completed'].includes(player.state)) await player.play();
      else if (player.state !== 'playing') throw new MediaVideoError('playback');
      // A delayed play completion must not outlive a pause/background/focus loss.
      if (!this.active || !this.current() || !this.wanted || !this.foreground()) {
        if (player.state === 'playing') await player.pause();
      }
      this.check();
    });
  }

  pause(): Promise<void> {
    if (!this.active) return Promise.resolve();
    this.wanted = false; this.playGeneration++;
    return this.enqueue(async (): Promise<void> => {
      const player: media.AVPlayer | null = this.player;
      if (player !== null && player.state === 'playing') await player.pause();
    });
  }

  seek(position: number): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      this.check();
      const player: media.AVPlayer | null = this.player;
      if (player === null || !this.prepared) throw new MediaVideoError('closed');
      // OH has no Android SEEK_CLOSEST_SYNC. API 12 SEEK_CLOSEST requests the
      // closest frame. This reply is submission, not proof of an exact position.
      player.seek(Math.max(0, Math.min(Math.trunc(position), player.duration)), media.SeekMode.SEEK_CLOSEST);
    });
  }

  poster(root: string, relative: string): Promise<Uint8Array | null> {
    let bytes: Uint8Array | null = null;
    const work: Promise<void> = Promise.resolve().then(async (): Promise<void> => {
      const length: number = await this.input(root, relative);
      this.extractor = await media.createAVMetadataExtractor(); this.check();
      this.extractor.fdSrc = { fd: this.fd, offset: 0, length: length };
      const metadata: media.AVMetadata = await this.extractor.fetchMetadata(); this.check();
      const width: number = Number(metadata.videoWidth), height: number = Number(metadata.videoHeight);
      if (!Number.isSafeInteger(width) || width <= 0 || !Number.isSafeInteger(height) || height <= 0) return;
      await this.extractor.release(); this.extractor = null; this.check();
      this.generator = await media.createAVImageGenerator(); this.check();
      this.generator.fdSrc = { fd: this.fd, offset: 0, length: length };
      const scale: number = Math.min(1, 512 / Math.max(width, height));
      this.pixels = await this.generator.fetchFrameByTime(0, media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC,
        { width: Math.max(1, Math.floor(width * scale)), height: Math.max(1, Math.floor(height * scale)) });
      this.check();
      const info: image.ImageInfo = await this.pixels.getImageInfo(); this.check();
      if (info.size.width <= 0 || info.size.height <= 0 || Math.max(info.size.width, info.size.height) > 512) return;
      this.packer = image.createImagePacker();
      const packed: ArrayBuffer = await this.packer.packToData(this.pixels, { format: 'image/jpeg', quality: 80 }); this.check();
      if (packed.byteLength > 0) bytes = new Uint8Array(packed);
    });
    this.work = work;
    work.then((): void => { this.workDone = true; }, (): void => { this.workDone = true; });
    return work.then((): Uint8Array | null => bytes);
  }

  private fault(): void {
    if (!this.active) return;
    this.failure = new MediaVideoError('playback');
    this.close().catch((): void => {});
  }

  close(): Promise<void> {
    this.active = false; this.wanted = false; this.playGeneration++;
    this.cancelPreparation?.((this.failure ?? new MediaVideoError('closed')) as Error);
    if (this.closing !== null) return this.closing;
    const work: Promise<void> = this.release(); this.closing = work;
    work.then((): void => { if (this.closing === work) this.closing = null; },
      (): void => { if (this.closing === work) this.closing = null; });
    return work;
  }

  private async release(): Promise<void> {
    if (this.work !== null) { try { await this.work; } catch (_) {} }
    if (this.preparing !== null) { try { await this.preparing; } catch (_) {} }
    await this.operations;
    if (this.player !== null) {
      await this.player.release();
      try { this.player.off('stateChange'); this.player.off('error'); this.player.off('audioInterrupt'); } catch (_) {}
      this.player = null;
    }
    if (this.extractor !== null) { await this.extractor.release(); this.extractor = null; }
    if (this.generator !== null) { await this.generator.release(); this.generator = null; }
    if (this.packer !== null) { await this.packer.release(); this.packer = null; }
    if (this.pixels !== null) { await this.pixels.release(); this.pixels = null; }
    if (this.fd >= 0) { await fs.close(this.fd); this.fd = -1; }
    if (this.registry !== null && this.textureId >= 0) {
      this.registry.unregisterTexture(this.textureId); this.registry = null; this.texture = null;
    }
    this.retired();
  }
}
