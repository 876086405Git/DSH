// 非官方，只为检查调用方逻辑。来源：用户 hms-contracts.md D；真实HMS SDK仍未编译。
// NONOFFICIAL: only user hms-contracts.md D. Not an HMS SDK declaration.
import image from '@ohos.multimedia.image';
declare namespace pdfService {
  enum ParseResult { PARSE_SUCCESS=0, PARSE_ERROR_FILE=1, PARSE_ERROR_FORMAT=2, PARSE_ERROR_PASSWORD=3, PARSE_ERROR_HANDLER=4, PARSE_ERROR_CERT=5 }
  class PdfMatrix { x: number; y: number; width: number; height: number; rotate: number; }
  class PixelOptions { isGray: boolean; drawAnnotations: boolean; isTransparent: boolean; }
  interface PdfPage {
    getWidth(): number; getHeight(): number;
    getAreaPixelMapWithOptions(matrix: PdfMatrix, width: number, height: number, options?: PixelOptions): image.PixelMap;
    release(): void;
  }
  class PdfDocument {
    loadDocument(path: string, password?: string, onProgress?: (progress: number)=>number): ParseResult;
    getPageCount(): number; getPage(index: number): PdfPage; releaseDocument(): void;
  }
}

export default pdfService;
