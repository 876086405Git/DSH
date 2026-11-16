// 非官方，只为检查调用方逻辑。来源：华为开发者文档 scanBarcode（默认界面扫码）；最终以真实 HMS SDK 编译为准。
// NONOFFICIAL stub: only startScanForResult (Promise form) and the fields the caller uses.
import common from '@ohos.app.ability.common';
import scanCore from './@hms.core.scan.scanCore';
declare namespace scanBarcode {
  interface ScanOptions { scanTypes?: Array<scanCore.ScanType>; enableMultiMode?: boolean; enableAlbum?: boolean; }
  interface ScanResult { scanType: scanCore.ScanType; originalValue: string; }
  function startScanForResult(context: common.Context, options?: ScanOptions): Promise<ScanResult>;
}

export default scanBarcode;
