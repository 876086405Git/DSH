import common from '@ohos.app.ability.common';
import { WantAgent } from '@ohos.app.ability.wantAgent';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import {
  FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { prepareRemoteAudioAgent, RemoteAudioTask } from './RemoteAudioTask';

export default class RemoteBackgroundPlugin implements FlutterPlugin, MethodCallHandler {
  private readonly context: common.UIAbilityContext;
  private channel?: MethodChannel;
  private active: boolean = false;
  private background: boolean = false;
  private requestId: number = -1;
  private audioEnabled: boolean = false;
  private audioAgent?: Promise<WantAgent | undefined>;
  private audioTask?: RemoteAudioTask;

  constructor(context: common.UIAbilityContext) { this.context = context; }

  getUniqueClassName(): string { return 'DshRemoteBackgroundPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'io.github.ccch1mneyyy.dsh_app/remote_background');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.stop();
    this.channel?.setMethodCallHandler(null);
    this.channel = undefined;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'setRemoteActive' && call.method !== 'setRemoteAudio') { result.notImplemented(); return; }
    if (typeof call.args !== 'boolean') { result.error('bad_args', 'Expected a boolean.', null); return; }
    const enabled = call.args === true;
    if (call.method === 'setRemoteActive') this.active = enabled;
    else this.audioEnabled = enabled;
    if (this.active && this.audioEnabled) this.prepareAudio();
    else {
      this.stopAudio();
      this.release();
    }
    result.success(null);
  }

  onBackground(): void {
    if (this.background) return;
    this.background = true;
    if (!this.active || !this.audioEnabled) return;
    // Keep the app scheduled while the audio task is being granted.
    this.requestDelay();
    const agent = this.audioAgent ?? prepareRemoteAudioAgent(this.context);
    this.audioAgent = undefined;
    const task = new RemoteAudioTask(this.context);
    this.audioTask = task;
    task.start(agent).then((): void => {
      if (this.audioTask === task) this.release();
    });
  }

  // The OS only accepts a transient task from the foreground or onBackground.
  private requestDelay(): void {
    if (this.requestId !== -1) return;
    try {
      const info: backgroundTaskManager.DelaySuspendInfo = backgroundTaskManager.requestSuspendDelay('Start remote audio protection', (): void => {
        if (this.requestId === info.requestId) this.release();
      });
      this.requestId = info.requestId;
    } catch (error) {
      hilog.warn(0x3F00, 'DshRemoteBackground', 'Transient task denied: %{public}d', (error as BusinessError).code);
    }
  }

  onForeground(): void {
    this.background = false;
    this.stopAudio();
    this.release();
    this.prepareAudio();
  }

  stop(): void {
    this.active = false;
    this.audioEnabled = false;
    this.stopAudio();
    this.release();
  }

  private prepareAudio(): void {
    if (!this.background && this.active && this.audioEnabled && this.audioAgent === undefined) {
      this.audioAgent = prepareRemoteAudioAgent(this.context);
    }
  }

  private stopAudio(): void {
    this.audioAgent = undefined;
    this.audioTask?.stop();
    this.audioTask = undefined;
  }

  private release(): void {
    const id = this.requestId;
    if (id === -1) return;
    this.requestId = -1;
    try {
      backgroundTaskManager.cancelSuspendDelay(id);
    } catch (error) {
      hilog.warn(0x3F00, 'DshRemoteBackground', 'Transient task cancellation failed: %{public}d', (error as BusinessError).code);
    }
  }
}
