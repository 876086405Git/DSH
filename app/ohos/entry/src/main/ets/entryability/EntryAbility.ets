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
import NativeFilesPlugin from '../plugins/NativeFilesPlugin';
import NativeMediaPlugin from '../plugins/NativeMediaPlugin';
import PerformancePlugin from '../plugins/PerformancePlugin';
import DiagnosticsPlugin from '../plugins/DiagnosticsPlugin';
import { loadNativeHost } from '../runtime/NativeHost';
import WebFilesPlugin from '../plugins/WebFilesPlugin';
import HmsSharePlugin from '../plugins/HmsSharePlugin';
import { HmsShareInbox } from '../plugins/HmsShareInbox';
import ShortcutsPlugin from '../plugins/ShortcutsPlugin';
import LauncherIconPlugin from '../plugins/LauncherIconPlugin';
import LaunchPlugin from '../plugins/LaunchPlugin';
import VoicePlugin from '../plugins/VoicePlugin';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';

export default class EntryAbility extends FlutterAbility {
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

  onForeground(): void {
    RuntimeController.onForeground(this);
    VoicePlugin.onForeground(this);
    NativeFilesPlugin.onForeground(this);
    NativeMediaPlugin.onForeground(this);
    super.onForeground();
  }

  onBackground(): void {
    RuntimeController.onBackground(this);
    VoicePlugin.onBackground(this);
    NativeFilesPlugin.onBackground(this);
    NativeMediaPlugin.onBackground(this);
    super.onBackground();
  }

  onDestroy(): void {
    RuntimeController.onDestroy(this);
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
    flutterEngine.getPlugins()?.add(new NativeMediaPlugin(async (root: string, relative: string): Promise<number> => {
      const host = await loadNativeHost();
      return host.openUserFile(root, relative);
    }))
    flutterEngine.getPlugins()?.add(new PerformancePlugin())
    flutterEngine.getPlugins()?.add(new DiagnosticsPlugin())
    flutterEngine.getPlugins()?.add(new HmsSharePlugin())
    flutterEngine.getPlugins()?.add(new VoicePlugin())
    flutterEngine.getPlugins()?.add(new ShortcutsPlugin())
    flutterEngine.getPlugins()?.add(new LauncherIconPlugin())
    flutterEngine.getPlugins()?.add(new LaunchPlugin())
  }
}
