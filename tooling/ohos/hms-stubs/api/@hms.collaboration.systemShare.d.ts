// 非官方，只为检查调用方逻辑。来源：用户 hms-contracts.md；最终以真实 HMS SDK 编译为准。
// 非官方；只为检查调用方逻辑。来源 hms-contracts.md，不证明 HMS SDK 类型兼容。
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
declare namespace systemShare {
  interface SharedRecord { utd: string; uri?: string; content?: string; title?: string; description?: string; }
  class SharedData {
    constructor(record: SharedRecord);
    addRecord(record: SharedRecord): void;
    getRecords(): SharedRecord[];
  }
  interface ShareOperationResult { targetAbilityInfo: { name: string }; }
  interface ShareControllerAnchor { windowOffset: { x: number; y: number }; size?: { width: number; height: number }; }
  enum SelectionMode { SINGLE = 0, BATCH = 1 }
  enum SharePreviewMode { DEFAULT = 0, DETAIL = 1 }
  interface ShareControllerOptions { selectionMode?: SelectionMode; previewMode?: SharePreviewMode; anchor?: ShareControllerAnchor | string; }
  class ShareController {
    constructor(data: SharedData);
    show(context: common.UIAbilityContext, options: ShareControllerOptions): Promise<void>;
    on(event: 'dismiss', callback: () => void): void;
    on(event: 'shareCompleted', callback: (result: ShareOperationResult) => void): void;
    off(event: 'dismiss', callback: () => void): void;
    off(event: 'shareCompleted', callback?: (result: ShareOperationResult) => void): void;
  }
  function getSharedData(want: Want): Promise<SharedData>;
}

export default systemShare;
