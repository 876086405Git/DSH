// dsh/picture_shortcut: unchanged Android/Dart wire contract, AppGallery backend.
import {
  AbilityAware, AbilityPluginBinding, Any, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodCallHandler, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import UIAbility from '@ohos.app.ability.UIAbility';
import { PictureShortcutAttempt, PictureShortcutOutcome, pictureShortcutLabel,
  pictureShortcutSupported, pinPictureShortcut } from './OhosPictureShortcut';

const foreground: WeakSet<UIAbility> = new WeakSet<UIAbility>();
const plugins: Set<PictureShortcutPlugin> = new Set<PictureShortcutPlugin>();

function reply(supported: boolean, requested: boolean): Map<string, Any> {
  const value: Map<string, Any> = new Map<string, Any>();
  value.set('supported', supported); value.set('requested', requested); return value;
}

export default class PictureShortcutPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private engine: FlutterPluginBinding | null = null;
  private ability: AbilityPluginBinding | null = null;
  private channel: MethodChannel | null = null;
  private attempt: PictureShortcutAttempt | null = null;
  private result: MethodResult | null = null;

  getUniqueClassName(): string { return 'DshPictureShortcutPlugin'; }
  static onForeground(ability: UIAbility): void { foreground.add(ability); }
  static onBackground(ability: UIAbility): void {
    foreground.delete(ability);
    plugins.forEach((plugin: PictureShortcutPlugin): void => {
      // The system confirmation page may background the app after submission.
      if (plugin.ability?.getAbility() === ability && plugin.attempt?.submitted !== true) plugin.retire();
    });
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.retire(); this.channel?.setMethodCallHandler(null);
    this.engine = binding; this.ability = null;
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/picture_shortcut');
    this.channel.setMethodCallHandler(this); plugins.add(this);
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.engine !== binding) return;
    this.retire(); this.channel?.setMethodCallHandler(null);
    this.channel = null; this.engine = null; this.ability = null; plugins.delete(this);
  }
  onAttachedToAbility(binding: AbilityPluginBinding): void { this.retire(); this.ability = binding; }
  onDetachedFromAbility(): void { this.retire(); this.ability = null; }

  private retire(): void {
    if (this.attempt !== null) this.attempt.cancelled = true;
    this.attempt = null;
    const result: MethodResult | null = this.result; this.result = null;
    try { result?.success(reply(true, false)); } catch (_) {}
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'pin') { result.notImplemented(); return; }
    const png: Any = call.argument('png');
    if (!(png instanceof Uint8Array) || png.byteLength === 0 || png.byteLength > 2 * 1024 * 1024) {
      result.error('invalid', 'no picture', null); return;
    }
    if (!pictureShortcutSupported()) { result.success(reply(false, false)); return; }
    const ability: AbilityPluginBinding | null = this.ability;
    const channel: MethodChannel | null = this.channel;
    if (ability === null || channel === null || !foreground.has(ability.getAbility()) || this.attempt !== null) {
      result.success(reply(true, false)); return;
    }
    const rawLabel: Any = call.argument('label');
    const label: string = pictureShortcutLabel(typeof rawLabel === 'string' ? rawLabel : '');
    const attempt: PictureShortcutAttempt = new PictureShortcutAttempt(ability.getAbility().context, label, png,
      (): boolean => this.ability === ability && this.channel === channel && foreground.has(ability.getAbility()));
    this.attempt = attempt; this.result = result;
    pinPictureShortcut(attempt).then((outcome: PictureShortcutOutcome): void => {
      if (this.attempt !== attempt || this.channel !== channel) return;
      this.attempt = null; this.result = null;
      try { result.success(reply(outcome.supported, outcome.requested)); } catch (_) {}
      if (outcome.requested) { try { channel.invokeMethod('pinned', null); } catch (_) {} }
    }).catch((): void => { if (this.attempt === attempt) this.retire(); });
  }
}
