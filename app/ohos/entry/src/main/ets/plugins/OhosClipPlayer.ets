// Public AVPlayer only. The opener is injected and must use the lazy NativeHost facade.
// No native DSO is imported or loaded by capabilities/activation.
import media from '@ohos.multimedia.media';
import audio from '@ohos.multimedia.audio';
import fs from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';
import { NativeMediaError } from './NativeMediaPolicy';

export type NativeClipOpener = (root: string, relative: string) => Promise<number>;
let playbackLease: OhosClipPlayer | null = null;

export class OhosClipPlayer {
  private readonly opener: NativeClipOpener;
  private readonly current: () => boolean;
  private readonly terminal: (kind: string, reason: string) => void;
  private readonly closeFailure: () => void;
  private player: media.AVPlayer | null = null;
  private fd: number = -1;
  private live: boolean = false;
  private begun: boolean = false;
  private desiredPlaying: boolean = true;
  private opening: Promise<void> | null = null;
  private transition: Promise<void> | null = null;
  private operation: Promise<void> | null = null;
  private closing: Promise<void> | null = null;

  constructor(opener: NativeClipOpener, current: () => boolean,
    terminal: (kind: string, reason: string) => void, closeFailure: () => void) {
    this.opener = opener; this.current = current; this.terminal = terminal; this.closeFailure = closeFailure;
  }

  async start(root: string, relative: string): Promise<void> {
    if (this.begun) throw new NativeMediaError('busy', '此播放器已经启动过。');
    this.begun = true; this.live = true;
    // Store the in-flight work before invoking even a synchronous opener hook.
    this.opening = Promise.resolve().then((): Promise<void> => this.acquire(root, relative));
    try { await this.opening; }
    catch (error) {
      try { await this.stop(); }
      catch (_) { throw new NativeMediaError('close', '音频资源尚未确认关闭。'); }
      throw error as Error;
    }
  }

  private assertLive(): void {
    if (!this.live || !this.current()) throw new NativeMediaError('stale-owner', '媒体操作的所有者已失效。');
  }

  private async acquire(root: string, relative: string): Promise<void> {
    this.assertLive();
    const previous = playbackLease;
    if (previous !== null && !previous.live) {
      // A retired Flutter engine cannot retry disposal. Wait for its original
      // attempt to settle before retrying through the retained physical lease.
      if (previous.closing !== null) { try { await previous.closing; } catch (_) {} }
      this.assertLive();
      if (playbackLease === previous) {
        try { await previous.stop(); }
        catch (_) { throw new NativeMediaError('busy', '上一段音频的原生资源尚未释放。'); }
      }
      this.assertLive();
    }
    // Two replacements can both await the old close; only one may acquire.
    if (playbackLease !== null) throw new NativeMediaError('busy', '上一段音频的原生资源尚未释放。');
    playbackLease = this;
    await this.setup(root, relative);
  }

  private async setup(root: string, relative: string): Promise<void> {
    this.assertLive();
    this.fd = await this.opener(root, relative);
    this.assertLive();
    if (!Number.isSafeInteger(this.fd) || this.fd < 0) throw new NativeMediaError('media-invalid', '音频文件句柄无效。');
    const info = await fs.stat(this.fd);
    this.assertLive();
    if (!info.isFile() || !Number.isSafeInteger(info.size) || info.size < 1 || info.size > 16 * 1024 * 1024) {
      throw new NativeMediaError('media-invalid', '音频片段必须为 1 字节至 16 MiB 的普通文件。');
    }
    const player = await media.createAVPlayer();
    if (player === undefined) throw new NativeMediaError('unsupported', '此设备无法创建音频播放器。');
    this.player = player;
    this.assertLive();
    player.on('stateChange', (state: media.AVPlayerState): void => {
      if (!this.live) return;
      if (state === 'initialized' && this.transition === null) {
        this.transition = this.prepare(player);
        this.transition.catch((): void => this.finish('audio.error', 'player'));
      } else if (state === 'completed') this.finish('audio.ended', '');
      else if (state === 'error') this.finish('audio.error', 'player');
    });
    player.on('error', (_error: BusinessError): void => this.finish('audio.error', 'player'));
    player.on('audioInterrupt', (event: audio.InterruptEvent): void => {
      if ([audio.InterruptHint.INTERRUPT_HINT_PAUSE, audio.InterruptHint.INTERRUPT_HINT_STOP,
        audio.InterruptHint.INTERRUPT_HINT_MUTE].includes(event.hintType)) this.finish('audio.stopped', 'interrupted');
    });
    this.assertLive();
    // Bound playback to the checked FD range. Never hand a path/URL back to the player.
    player.fdSrc = { fd: this.fd, offset: 0, length: info.size };
  }

  private async prepare(player: media.AVPlayer): Promise<void> {
    this.assertLive();
    player.audioRendererInfo = { usage: audio.StreamUsage.STREAM_USAGE_VOICE_MESSAGE, rendererFlags: 0 };
    await player.prepare();
    this.assertLive();
    player.audioInterruptMode = audio.InterruptMode.INDEPENDENT_MODE;
    if (this.desiredPlaying) {
      await player.play();
      this.assertLive();
    }
  }

  async setPlaying(wanted: boolean): Promise<void> {
    this.assertLive(); this.desiredPlaying = wanted;
    if (this.operation !== null) throw new NativeMediaError('busy', '播放器操作尚未完成。');
    if (this.opening !== null) await this.opening;
    if (this.transition !== null) { try { await this.transition; } catch (_) { this.assertLive(); } }
    this.assertLive();
    const player = this.player;
    if (player === null) throw new NativeMediaError('audio', '没有当前音频片段。');
    let work: Promise<void> | null = null;
    if (!wanted && player.state === 'playing') work = player.pause();
    else if (wanted && ['prepared', 'paused'].includes(player.state)) work = player.play();
    else if (['idle', 'initialized', 'prepared', 'playing', 'paused'].includes(player.state)) return;
    else throw new NativeMediaError('audio', '播放器当前状态不能完成该操作。');
    this.operation = work;
    try { if (work !== null) await work; this.assertLive(); }
    catch (error) { this.finish('audio.error', 'player'); throw error as Error; }
    finally { this.operation = null; }
  }

  stop(): Promise<void> {
    // Invalidate every queued state transition before awaiting any allocation or API.
    this.live = false;
    if (this.closing !== null) return this.closing;
    const work = this.release();
    this.closing = work;
    work.then((): void => { if (this.closing === work) this.closing = null; },
      (): void => { if (this.closing === work) this.closing = null; });
    return work;
  }

  private async release(): Promise<void> {
    if (this.opening !== null) { try { await this.opening; } catch (_) {} }
    if (this.transition !== null) { try { await this.transition; } catch (_) {} }
    if (this.operation !== null) { try { await this.operation; } catch (_) {} }
    if (this.player !== null) {
      const player = this.player;
      await player.release();
      // Late callbacks remain harmless even if unsubscribe itself fails.
      try { player.off('stateChange'); } catch (_) {}
      try { player.off('error'); } catch (_) {}
      try { player.off('audioInterrupt'); } catch (_) {}
      this.player = null;
    }
    if (this.fd >= 0) { await fs.close(this.fd); this.fd = -1; }
    if (playbackLease === this) playbackLease = null;
  }

  private finish(kind: string, reason: string): void {
    if (!this.live) return;
    this.live = false;
    this.stop().then((): void => this.terminal(kind, reason), (): void => this.closeFailure());
  }
}
