import PastePlugin from '../plugins/PastePlugin';
import AppLinksPlugin from '../plugins/AppLinksPlugin';
import SecretsPlugin from '../plugins/SecretsPlugin';
import AttachmentFilesPlugin from '../plugins/AttachmentFilesPlugin';
import IslandsPlugin from '../plugins/IslandsPlugin';
import NotifyPlugin from '../plugins/NotifyPlugin';
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import ConnectivityPlugin from '../plugins/ConnectivityPlugin';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { RuntimePlugin } from '../runtime/RuntimePlugin';
import { RuntimeController } from '../runtime/RuntimeController';
import FilesMediaPlugin from '../plugins/FilesMediaPlugin';
import AuthorizedWorkspacesPlugin from '../plugins/AuthorizedWorkspacesPlugin';
import NativeFilesPlugin from '../plugins/NativeFilesPlugin';
import NativeMediaPlugin from '../plugins/NativeMediaPlugin';
import { NativeVoiceStopControl } from '../plugins/NativeVoiceStopControl';
import PerformancePlugin from '../plugins/PerformancePlugin';
import { OhosKeyboardLog } from '../plugins/OhosKeyboardLog';
import DiagnosticsPlugin from '../plugins/DiagnosticsPlugin';
import UsagePlugin from '../plugins/UsagePlugin';
import { loadNativeHost } from '../runtime/NativeHost';
import WebFilesPlugin from '../plugins/WebFilesPlugin';
import HmsSharePlugin from '../plugins/HmsSharePlugin';
import { HmsShareInbox } from '../plugins/HmsShareInbox';
import ShortcutsPlugin from '../plugins/ShortcutsPlugin';
import LauncherIconPlugin from '../plugins/LauncherIconPlugin';
import PictureShortcutPlugin from '../plugins/PictureShortcutPlugin';
import LaunchPlugin from '../plugins/LaunchPlugin';
import LaunchClipPlugin from '../plugins/LaunchClipPlugin';
import MediaVideoPlugin from '../plugins/MediaVideoPlugin';
import VoicePlugin from '../plugins/VoicePlugin';
import SpeechPlugin from '../plugins/SpeechPlugin';
import CompanionVoicePlugin from '../plugins/CompanionVoicePlugin';
import StreamingAsrPlugin from '../plugins/StreamingAsrPlugin';
import CompanionWidgetPlugin from '../plugins/CompanionWidgetPlugin';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import window from '@ohos.window';

export default class EntryAbility extends FlutterAbility {
  private keyboardLog: OhosKeyboardLog = new OhosKeyboardLog();

  onCreate(want: Want, launch: AbilityConstant.LaunchParam): void {
    HmsShareInbox.receive(this.context, want, launch);
    ShortcutsPlugin.receive(want, launch);
    super.onCreate(want, launch);
  }

  onNewWant(want: Want, launch: AbilityConstant.LaunchParam): void {
    HmsShareInbox.receive(this.context, want, launch);
    ShortcutsPlugin.receive(want, launch);
    super.onNewWant(want, launch);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    super.onWindowStageCreate(windowStage);
    PerformancePlugin.applyFrameCache();
    this.keyboardLog.attach(windowStage);
  }

  onWindowStageDestroy(): void {
    this.keyboardLog.detach();
    super.onWindowStageDestroy();
  }

  onForeground(): void {
    this.keyboardLog.setForeground(true);
    PastePlugin.onForeground(this);
    AppLinksPlugin.onForeground(this);
    RuntimeController.onForeground(this);
    VoicePlugin.onForeground(this);
    SpeechPlugin.onForeground(this);
    CompanionVoicePlugin.onForeground(this);
    StreamingAsrPlugin.onForeground(this);
    NativeFilesPlugin.onForeground(this);
    AuthorizedWorkspacesPlugin.onForeground(this);
    NativeMediaPlugin.onForeground(this);
    MediaVideoPlugin.onForeground(this);
    PictureShortcutPlugin.onForeground(this);
    super.onForeground();
  }

  onBackground(): void {
    this.keyboardLog.setForeground(false);
    PastePlugin.onBackground(this);
    AppLinksPlugin.onBackground(this);
    RuntimeController.onBackground(this);
    VoicePlugin.onBackground(this);
    SpeechPlugin.onBackground(this);
    CompanionVoicePlugin.onBackground(this);
    StreamingAsrPlugin.onBackground(this);
    NativeFilesPlugin.onBackground(this);
    AuthorizedWorkspacesPlugin.onBackground(this);
    NativeMediaPlugin.onBackground(this);
    MediaVideoPlugin.onBackground(this);
    PictureShortcutPlugin.onBackground(this);
    super.onBackground();
  }

  onDestroy(): void {
    MediaVideoPlugin.onDestroy(this);
    PictureShortcutPlugin.onBackground(this);
    this.keyboardLog.setForeground(false);
    this.keyboardLog.detach();
    SpeechPlugin.onBackground(this);
    CompanionVoicePlugin.onBackground(this);
    StreamingAsrPlugin.onBackground(this);
    PastePlugin.onBackground(this);
    RuntimeController.onDestroy(this);
    AuthorizedWorkspacesPlugin.onBackground(this);
    super.onDestroy();
  }

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    flutterEngine.getPlugins()?.add(new AppLinksPlugin())
    super.configureFlutterEngine(flutterEngine)
    flutterEngine.getPlugins()?.add(new ConnectivityPlugin())
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(new SecretsPlugin())
    flutterEngine.getPlugins()?.add(new AttachmentFilesPlugin())
    flutterEngine.getPlugins()?.add(new RuntimePlugin())
    flutterEngine.getPlugins()?.add(new FilesMediaPlugin())
    flutterEngine.getPlugins()?.add(new WebFilesPlugin())
    flutterEngine.getPlugins()?.add(new IslandsPlugin())
    flutterEngine.getPlugins()?.add(new NotifyPlugin())
    flutterEngine.getPlugins()?.add(new NativeFilesPlugin())
    flutterEngine.getPlugins()?.add(new AuthorizedWorkspacesPlugin())
    flutterEngine.getPlugins()?.add(new NativeMediaPlugin(async (root: string, relative: string): Promise<number> => {
      const host = await loadNativeHost();
      return host.openUserFile(root, relative);
    }, new NativeVoiceStopControl(this.context)))
    flutterEngine.getPlugins()?.add(new PerformancePlugin())
    flutterEngine.getPlugins()?.add(new DiagnosticsPlugin(this.keyboardLog))
    flutterEngine.getPlugins()?.add(new UsagePlugin())
    flutterEngine.getPlugins()?.add(new PastePlugin())
    flutterEngine.getPlugins()?.add(new HmsSharePlugin())
    flutterEngine.getPlugins()?.add(new VoicePlugin())
    flutterEngine.getPlugins()?.add(new SpeechPlugin())
    flutterEngine.getPlugins()?.add(new CompanionVoicePlugin())
    flutterEngine.getPlugins()?.add(new StreamingAsrPlugin())
    flutterEngine.getPlugins()?.add(new CompanionWidgetPlugin())
    flutterEngine.getPlugins()?.add(new ShortcutsPlugin())
    flutterEngine.getPlugins()?.add(new LauncherIconPlugin())
    flutterEngine.getPlugins()?.add(new PictureShortcutPlugin())
    flutterEngine.getPlugins()?.add(new LaunchPlugin())
    flutterEngine.getPlugins()?.add(new LaunchClipPlugin())
    flutterEngine.getPlugins()?.add(new MediaVideoPlugin(async (root: string, relative: string): Promise<number> => {
      return (await loadNativeHost()).openUserFile(root, relative);
    }))
  }
}
