import common from '@ohos.app.ability.common';
import { NativeMediaKey, NativeVoiceIndicator } from './NativeMediaPolicy';
import { mountVoiceStop } from './VoiceStopOverlay';

class ShownStop {
  readonly key: NativeMediaKey;
  taken: boolean = false;
  unmount: () => void = (): void => {};
  constructor(key: NativeMediaKey) { this.key = key; }
}

// What a plugin needs before it may listen: a stop the person can see. One at a time,
// and a late hide for an older key leaves a newer control alone.
export class NativeVoiceStopControl implements NativeVoiceIndicator {
  private readonly context: common.UIAbilityContext;
  private shown: ShownStop | null = null;

  constructor(context: common.UIAbilityContext) { this.context = context; }

  async show(key: NativeMediaKey, stop: () => void): Promise<void> {
    if (this.shown !== null) this.take(this.shown);
    const entry = new ShownStop(key);
    entry.unmount = await mountVoiceStop(this.context, stop, (): void => { if (!entry.taken) stop(); });
    this.shown = entry;
  }

  async hide(key: NativeMediaKey): Promise<void> {
    const shown = this.shown;
    if (shown === null || shown.key.owner !== key.owner || shown.key.generation !== key.generation ||
      shown.key.lease !== key.lease) return;
    this.take(shown);
  }

  private take(entry: ShownStop): void {
    entry.taken = true;
    if (this.shown === entry) this.shown = null;
    entry.unmount();
  }
}
