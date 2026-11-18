import common from '@ohos.app.ability.common';
import window from '@ohos.window';
import { ComponentContent } from '@ohos.arkui.node';

class VoiceStopParams {
  readonly stop: () => void;
  readonly lost: () => void;
  constructor(stop: () => void, lost: () => void) {
    this.stop = stop;
    this.lost = lost;
  }
}

@Builder
function voiceStopBuilder(params: VoiceStopParams) {
  Row() {
    Button($r('app.string.dsh_voice_stop')).onClick((): void => params.stop())
  }
  .width('100%')
  .justifyContent(FlexAlign.Center)
  .margin({ top: 96 })
  .hitTestBehavior(HitTestMode.Transparent)
  .onDetach((): void => params.lost())
}

// The only UI boundary of the plugin's stop control, which Linux tests replace: they
// can't show that a device drew it. Resolves with how to take it down again.
export async function mountVoiceStop(context: common.UIAbilityContext, stop: () => void,
  lost: () => void): Promise<() => void> {
  const ui = (await window.getLastWindow(context)).getUIContext();
  const overlay = ui.getOverlayManager();
  const content = new ComponentContent<VoiceStopParams>(ui, wrapBuilder(voiceStopBuilder), new VoiceStopParams(stop, lost));
  overlay.addComponentContent(content);
  return (): void => {
    overlay.removeComponentContent(content);
    content.dispose();
  };
}
