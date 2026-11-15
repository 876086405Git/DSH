// 非官方最小逻辑声明；不是 HMS SDK。来源见 picture-shortcut.md 的官方 API/API-diff。
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
declare namespace productViewManager {
  interface CheckShortcutResult { code: number; tid?: string; expired?: number; limit?: number; }
  interface PinShortcutInfo { shortcutId: string; icon?: string; iconId?: number; label?: string; labelId?: number; want?: Want; }
  function checkPinShortcutPermitted(context: common.UIAbilityContext, shortcutId: string,
    want: Want, label: string, foregroundIcon: string, backgroundIcon: string): Promise<CheckShortcutResult>;
  function requestNewPinShortcut(context: common.UIAbilityContext, tid: string): Promise<void>;
  function getPinShortcutInfos(): Promise<PinShortcutInfo[]>;
}
export default productViewManager;
