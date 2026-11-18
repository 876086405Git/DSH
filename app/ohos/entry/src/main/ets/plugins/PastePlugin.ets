import pasteboard from '@ohos.pasteboard';
import UIAbility from '@ohos.app.ability.UIAbility';
import {
  Any, AbilityAware, AbilityPluginBinding, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { PastePrompt } from './PastePrompt';

class PastePending {
  reading: boolean = false;
  settled: boolean = false;
  readonly id: string;
  readonly result: MethodResult;
  readonly prompt: PastePrompt;
  readonly ability: UIAbility;
  readonly cancel: () => void;
  constructor(id: string, result: MethodResult, ability: UIAbility, cancel: () => void) {
    this.id = id;
    this.result = result;
    this.ability = ability;
    this.cancel = cancel;
    this.prompt = new PastePrompt(cancel);
  }
}
let activePaste: PastePending | null = null;
const foregroundAbilities: WeakSet<UIAbility> = new WeakSet<UIAbility>();

export default class PastePlugin implements FlutterPlugin, AbilityAware {
  private engine: FlutterPluginBinding | null = null;
  private ability: AbilityPluginBinding | null = null;
  private channel: MethodChannel | null = null;
  private pending: PastePending | null = null;
  static onForeground(ability: UIAbility): void { foregroundAbilities.add(ability); }
  static onBackground(ability: UIAbility): void {
    foregroundAbilities.delete(ability);
    const pending = activePaste;
    if (pending !== null && pending.ability === ability) pending.cancel();
  }
  getUniqueClassName(): string { return 'DshPastePlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.retire(); this.channel?.setMethodCallHandler(null);
    this.engine = binding; this.ability = null;
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/paste');
    this.channel.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (this.engine !== binding) { this.reply(result, 'cancelled'); return; }
      const id: Any = call.argument('requestId');
      if (call.method === 'readText') {
        if (typeof id !== 'string' || id.length === 0 || id.length > 128) { this.reply(result, 'unavailable'); return; }
        this.request(id, result);
      } else if (call.method === 'cancel') {
        const pending = this.pending;
        const matched = pending !== null && pending.id === id;
        if (matched && pending !== null) {
          if (pending.settled) this.cleanup(pending);
          else this.finish(pending, 'cancelled');
        }
        result.success(matched);
      } else result.notImplemented();
    } });
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.engine !== binding) return;
    this.retire(); this.channel?.setMethodCallHandler(null);
    this.channel = null; this.engine = null; this.ability = null;
  }
  onAttachedToAbility(binding: AbilityPluginBinding): void {
    if (this.ability !== binding) this.retire();
    this.ability = binding;
  }
  onDetachedFromAbility(): void { this.retire(); this.ability = null; }
  private retire(): void {
    if (this.pending !== null) {
      if (this.pending.settled) this.cleanup(this.pending);
      else this.finish(this.pending, 'cancelled');
    }
  }
  private request(id: string, result: MethodResult): void {
    const ability = this.ability;
    if (ability === null || !foregroundAbilities.has(ability.getAbility())) { this.reply(result, 'unavailable'); return; }
    const active = activePaste;
    if (active !== null) {
      // A new user request may retry only the exact retired owner's cleanup.
      // This request remains busy: it never opens another UI or reads text.
      if (active.settled) this.cleanup(active);
      this.reply(result, 'busy'); return;
    }
    const pending = new PastePending(id, result, ability.getAbility(), (): void => {
      if (this.pending !== pending) return;
      if (pending.settled) this.cleanup(pending);
      else this.finish(pending, 'cancelled');
    });
    this.pending = pending; activePaste = pending;
    pending.prompt.open(ability.getAbility().context, (granted: boolean): void => {
      if (this.pending !== pending || pending.settled || pending.reading) return;
      if (!granted) { this.finish(pending, 'denied'); return; }
      pending.reading = true;
      // Only the real PasteButton SUCCESS callback reaches getData. Invoke
      // immediately; the MethodChannel request itself never reads the clipboard.
      this.read(pending);
    }).catch((): void => this.finish(pending, 'unavailable'));
  }
  private async read(pending: PastePending): Promise<void> {
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      if (pending.settled || this.pending !== pending) return;
      const text = data.getPrimaryText();
      this.finish(pending, text.length === 0 ? 'empty' : 'text', text);
    } catch (_) { this.finish(pending, 'readFailed'); }
  }
  private finish(pending: PastePending, status: string, text: string = ''): void {
    if (pending.settled) return;
    pending.settled = true;
    let shown: boolean = false;
    try {
      if (status === 'denied') shown = pending.prompt.feedback($r('app.string.dsh_paste_denied'));
      else if (status === 'empty') shown = pending.prompt.feedback($r('app.string.dsh_paste_empty'));
      else if (status === 'readFailed' || status === 'unavailable') shown = pending.prompt.feedback($r('app.string.dsh_paste_failed'));
    } catch (_) { /* The typed result still reports failure if the window is gone. */ }
    this.reply(pending.result, status, text, shown);
    this.cleanup(pending);
  }
  private cleanup(pending: PastePending): void {
    pending.prompt.close().then((): void => {
      if (this.pending === pending) this.pending = null;
      if (activePaste === pending) activePaste = null;
    }, (): void => {
      // Keep this exact owner until close succeeds; cancel/detach can retry.
      // In particular a failed close must not admit a second visible prompt.
    });
  }
  // shown: a toast already said what happened, so Dart must not say it again.
  private reply(result: MethodResult, status: string, text: string = '', shown: boolean = false): void {
    const value: Map<string, Any> = new Map<string, Any>([['status', status]]);
    if (status === 'text') value.set('text', text);
    if (shown) value.set('shown', true);
    try { result.success(value); } catch (_) { /* Retired messenger. */ }
  }
}
