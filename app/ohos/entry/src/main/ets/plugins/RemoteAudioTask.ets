import common from '@ohos.app.ability.common';
import wantAgent, { WantAgent } from '@ohos.app.ability.wantAgent';
import audio from '@ohos.multimedia.audio';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';

const TAG = 'DshRemoteBackground';

export async function prepareRemoteAudioAgent(context: common.UIAbilityContext): Promise<WantAgent | undefined> {
  try {
    return await wantAgent.getWantAgent({ wants: [{
      bundleName: context.applicationInfo.name, abilityName: context.abilityInfo.name
    }], requestCode: 0, actionType: wantAgent.OperationType.START_ABILITY,
    actionFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG] });
  } catch (error) {
    hilog.warn(0x3F00, TAG, 'Audio WantAgent failed: %{public}d', (error as BusinessError).code);
    return undefined;
  }
}

// One attempt per background transition. Late results still belong to this attempt.
export class RemoteAudioTask {
  private readonly context: common.UIAbilityContext;
  private live: boolean = true;
  private listening: boolean = false;
  private taskId?: number;
  private renderer?: audio.AudioRenderer;
  private readonly earlyStops: Map<number, boolean> = new Map<number, boolean>();
  private readonly onCancel = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => this.unavailable(info.id, true);
  private readonly onSuspend = (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => this.unavailable(info.continuousTaskId, false);

  constructor(context: common.UIAbilityContext) { this.context = context; }

  async start(agent: Promise<WantAgent | undefined>): Promise<void> {
    try {
      const notificationTarget = await agent;
      if (!this.live || notificationTarget === undefined) return;
      backgroundTaskManager.on('continuousTaskCancel', this.onCancel);
      this.listening = true;
      backgroundTaskManager.on('continuousTaskSuspend', this.onSuspend);
      const request = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_AUDIO_PLAYBACK];
      request.wantAgent = notificationTarget;
      const result = await backgroundTaskManager.startBackgroundRunning(this.context, request);
      const id = result.continuousTaskId;
      if (id === undefined || id < 0) {
        // Never stop all tasks in the ability; the local engine may own one.
        hilog.warn(0x3F00, TAG, 'Continuous audio task returned no ownership ID');
        this.stop();
        return;
      }
      if (!this.live) { this.stopTask(id); return; }
      this.taskId = id;
      const earlyStop = this.earlyStops.get(id);
      this.earlyStops.clear();
      if (earlyStop !== undefined) { this.stop(earlyStop); return; }
      await this.startRenderer();
    } catch (error) {
      if (this.live) hilog.warn(0x3F00, TAG, 'Continuous audio task failed: %{public}d', (error as BusinessError).code);
      this.stop();
    }
  }

  private unavailable(id: number, cancelled: boolean): void {
    if (!this.live) return;
    if (this.taskId === id) this.stop(cancelled);
    else if (this.taskId === undefined) this.earlyStops.set(id, cancelled);
  }

  private async startRenderer(): Promise<void> {
    const options: audio.AudioRendererOptions = {
      streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_24000,
        channels: audio.AudioChannel.CHANNEL_1, sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
      rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_UNKNOWN, rendererFlags: 0 }
    };
    const renderer = await audio.createAudioRenderer(options);
    if (!renderer) {
      hilog.warn(0x3F00, TAG, 'Audio renderer unavailable');
      this.stop();
      return;
    }
    try {
      if (!this.live) return;
      // Don't take audio focus from real playback. Every submitted PCM sample is still zero.
      renderer.setSilentModeAndMixWithOthers(true);
      renderer.on('stateChange', (state: audio.AudioState): void => {
        if (state === audio.AudioState.STATE_STOPPED || state === audio.AudioState.STATE_PAUSED ||
          state === audio.AudioState.STATE_RELEASED) this.stop();
      });
      renderer.on('writeData', (buffer: ArrayBuffer): audio.AudioDataCallbackResult => {
        if (!this.live) return audio.AudioDataCallbackResult.INVALID;
        new Uint8Array(buffer).fill(0);
        return audio.AudioDataCallbackResult.VALID;
      });
      await renderer.start();
      if (!this.live) return;
      if (renderer.state === audio.AudioState.STATE_RUNNING) this.renderer = renderer;
      else {
        hilog.warn(0x3F00, TAG, 'Audio renderer did not enter running state');
        this.stop();
      }
    } finally {
      // Release here if foreground/disconnect/cancel beat createAudioRenderer or start.
      if (this.renderer !== renderer) await this.releaseRenderer(renderer);
    }
  }

  stop(cancelled: boolean = false): void {
    if (!this.live) return;
    this.live = false;
    const renderer = this.renderer;
    this.renderer = undefined;
    if (renderer !== undefined) this.releaseRenderer(renderer);
    const id = this.taskId;
    this.taskId = undefined;
    if (id !== undefined && !cancelled) this.stopTask(id);
    this.earlyStops.clear();
    if (this.listening) {
      this.listening = false;
      try { backgroundTaskManager.off('continuousTaskCancel', this.onCancel); } catch (error) {
        hilog.warn(0x3F00, TAG, 'Cancel listener cleanup failed: %{public}d', (error as BusinessError).code);
      }
      try { backgroundTaskManager.off('continuousTaskSuspend', this.onSuspend); } catch (error) {
        hilog.warn(0x3F00, TAG, 'Suspend listener cleanup failed: %{public}d', (error as BusinessError).code);
      }
    }
  }

  private async stopTask(id: number): Promise<void> {
    try { await backgroundTaskManager.stopBackgroundRunning(this.context, id); } catch (error) {
      hilog.warn(0x3F00, TAG, 'Continuous audio task stop failed: %{public}d', (error as BusinessError).code);
    }
  }

  private async releaseRenderer(renderer: audio.AudioRenderer): Promise<void> {
    try {
      if (renderer.state === audio.AudioState.STATE_RUNNING || renderer.state === audio.AudioState.STATE_PAUSED) {
        await renderer.stop();
      }
    } catch (error) {
      hilog.warn(0x3F00, TAG, 'Audio renderer stop failed: %{public}d', (error as BusinessError).code);
    }
    try {
      if (renderer.state !== audio.AudioState.STATE_RELEASED) await renderer.release();
    } catch (error) {
      hilog.warn(0x3F00, TAG, 'Audio renderer release failed: %{public}d', (error as BusinessError).code);
    }
  }
}
