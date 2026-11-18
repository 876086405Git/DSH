// UNCOMPILED_HMS. PDFKit signatures follow hms-contracts.md D; scaling still needs device evidence.
import type { pdfService } from '@kit.PDFKit';
import { PdfKit, loadPdfKit } from './HmsKits';
import image from '@ohos.multimedia.image';
import common from '@ohos.app.ability.common';
import { Any } from '@ohos/flutter_ohos';
import { PdfChannelError, PdfInput } from './PdfInput';

interface PageSize { width: number; height: number; }

export class HmsPdfPages {
  private static owner?: HmsPdfPages;
  private static physical?: HmsPdfPages;
  private static tail: Promise<void> = Promise.resolve();
  private static pending: number = 0;
  private context: common.Context;
  private openLocal: (path: string) => Promise<number>;
  private retired: boolean = false;
  private input?: PdfInput;
  private kit?: PdfKit;
  private document?: pdfService.PdfDocument;
  private original: string = '';
  private pageCount: number = 0;
  private needsClose: boolean = false;
  private page?: pdfService.PdfPage;
  private pixels?: image.PixelMap;
  private packer?: image.ImagePacker;
  private ownPending: number = 0;
  private submission: number = 0;
  private closeAt: number = -1;
  private closing?: Promise<void>;

  constructor(context: common.Context, openLocal: (path: string) => Promise<number>) {
    this.context = context; this.openLocal = openLocal;
    const old = HmsPdfPages.owner; HmsPdfPages.owner = this;
    if (old) old.retire().catch((): void => {});
  }

  private current(): void {
    if (this.retired || HmsPdfPages.owner !== this) throw new PdfChannelError('cancelled', 'PDF 窗口已关闭。');
  }

  private enqueue<T>(operation: () => Promise<T>, cleanup: boolean = false): Promise<T> {
    if (!cleanup && HmsPdfPages.pending >= 32) return Promise.reject(new PdfChannelError('busy', 'PDF 正在处理其他页面，请稍后重试。'));
    HmsPdfPages.pending++; this.ownPending++; this.submission++;
    const result = HmsPdfPages.tail.then(operation);
    HmsPdfPages.tail = result.then((): void => {}, (): void => {});
    return result.finally((): void => { HmsPdfPages.pending--; this.ownPending--; });
  }

  private validatePath(path: string): void {
    if (typeof path !== 'string' || path.length === 0 || path.length > 4096 || !path.startsWith('/') || /[\x00-\x1f\x7f]/.test(path)) {
      throw new PdfChannelError('invalid', 'PDF 必须先下载或复制到本机工作区或应用缓存。');
    }
  }

  private async releasePage(): Promise<void> {
    // Keep each handle until its release succeeds; a later close retries in this order.
    if (this.packer) { await this.packer.release(); this.packer = undefined; }
    if (this.pixels) { await this.pixels.release(); this.pixels = undefined; }
    if (this.page) { this.page.release(); this.page = undefined; }
  }

  private async closeDocument(): Promise<void> {
    this.needsClose = true;
    await this.releasePage();
    if (this.document) { this.document.releaseDocument(); this.document = undefined; }
    if (this.input) { await this.input.dispose(); this.input = undefined; }
    this.original = ''; this.pageCount = 0; this.needsClose = false;
    if (HmsPdfPages.physical === this) HmsPdfPages.physical = undefined;
  }

  private async open(path: string): Promise<pdfService.PdfDocument> {
    this.current(); this.validatePath(path);
    if (HmsPdfPages.physical && HmsPdfPages.physical !== this) await HmsPdfPages.physical.closeDocument();
    this.current(); await this.releasePage();
    if (this.document && !this.needsClose && this.original === path) return this.document;
    await this.closeDocument(); this.current(); HmsPdfPages.physical = this;
    this.input = new PdfInput();
    try {
      const kit = await loadPdfKit();
      this.current(); this.kit = kit;
      await this.input.copy(this.context.cacheDir, path, this.openLocal, (): void => this.current());
      this.current(); this.document = kit.createDocument();
      const result = this.document.loadDocument(this.input.snapshotPath);
      if (result !== kit.success) {
        throw new PdfChannelError(result === kit.password ? 'pdf_password' : 'pdf_unavailable',
          result === kit.password ? '此 PDF 需要密码，请用系统应用打开。' : '无法预览此 PDF，请用系统应用打开。');
      }
      const count = this.document.getPageCount();
      if (!Number.isSafeInteger(count) || count < 1 || count > 1000) throw new PdfChannelError('pdf_size', '内嵌预览支持 1 到 1000 页，请用系统应用打开此文件。');
      this.pageCount = count; this.original = path; return this.document;
    } catch (error) {
      try { await this.closeDocument(); } catch (_) { /* physical remains held until cleanup succeeds */ }
      this.current();
      if (error instanceof PdfChannelError) throw error as Error;
      throw new PdfChannelError('pdf_unavailable', '系统 PDF 预览服务暂时不可用，请用系统应用打开。');
    }
  }

  private dimensions(page: pdfService.PdfPage): PageSize {
    const width = page.getWidth(); const height = page.getHeight();
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0 || width > 1000000 || height > 1000000) {
      throw new PdfChannelError('pdf_dimensions', 'PDF 页面尺寸无效。');
    }
    return { width, height };
  }

  info(path: string): Promise<Map<string, Any>[]> {
    return this.enqueue(async (): Promise<Map<string, Any>[]> => {
      const doc = await this.open(path); const result: Map<string, Any>[] = [];
      const count = this.pageCount;
      for (let i = 0; i < count; i++) {
        this.current(); this.page = doc.getPage(i);
        try {
          const size = this.dimensions(this.page);
          result.push(new Map<string, Any>([['width', Math.max(1, Math.round(size.width))], ['height', Math.max(1, Math.round(size.height))]]));
        } finally { await this.releasePage(); }
        // Yield the JS event loop between batches. Native synchronous work is still not preemptible.
        if ((i + 1) % 8 === 0) await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); });
      }
      this.current(); return result;
    });
  }

  render(path: string, index: number, requestedWidth: number): Promise<Uint8Array> {
    return this.enqueue(async (): Promise<Uint8Array> => {
      if (!Number.isSafeInteger(index) || index < 0 || !Number.isSafeInteger(requestedWidth)) throw new PdfChannelError('invalid', 'PDF 页码或渲染宽度无效。');
      const doc = await this.open(path); this.current();
      if (index >= this.pageCount) throw new PdfChannelError('invalid', 'PDF 页码超出范围。');
      this.page = doc.getPage(index);
      try {
        const size = this.dimensions(this.page);
        const width = Math.max(64, Math.min(2400, requestedWidth));
        const height = Math.max(1, Math.min(4800, Math.floor(width * size.height / size.width)));
        const matrix = this.kit!.createMatrix();
        matrix.x = 0; matrix.y = 0; matrix.width = width; matrix.height = height; matrix.rotate = 0;
        const options = this.kit!.createPixelOptions();
        options.isGray = false; options.drawAnnotations = true; options.isTransparent = false;
        this.pixels = this.page.getAreaPixelMapWithOptions(matrix, width, height, options);
        const actual = await this.pixels.getImageInfo(); this.current();
        if (actual.size.width !== width || actual.size.height !== height) throw new PdfChannelError('pdf_dimensions', '系统返回的 PDF 位图尺寸不符，请用系统应用打开。');
        this.packer = image.createImagePacker();
        const png = await this.packer.packToData(this.pixels, { format: 'image/png', quality: 100 }); this.current();
        if (png.byteLength < 24 || png.byteLength > 48 * 1024 * 1024) throw new PdfChannelError('pdf_size', 'PDF 页面图像大小超出内嵌预览范围。');
        const bytes = new Uint8Array(png); const view = new DataView(png);
        const signature = [137, 80, 78, 71, 13, 10, 26, 10];
        for (let i = 0; i < signature.length; i++) if (bytes[i] !== signature[i]) throw new PdfChannelError('pdf_format', '系统未返回 PNG 页面图像。');
        if (bytes[12] !== 73 || bytes[13] !== 72 || bytes[14] !== 68 || bytes[15] !== 82 ||
          view.getUint32(16, false) !== width || view.getUint32(20, false) !== height) throw new PdfChannelError('pdf_dimensions', 'PDF 页面编码尺寸不符。');
        return bytes;
      } finally { await this.releasePage(); }
    });
  }

  close(): Promise<void> {
    if (this.ownPending === 0 && !this.input && !this.document && !this.page && !this.pixels && !this.packer) return Promise.resolve();
    // Coalesce repeated closes only if no new page/info operation was submitted between them.
    if (this.closing && this.closeAt === this.submission) return this.closing;
    const work: Promise<void> = this.enqueue(async (): Promise<void> => { await this.closeDocument(); }, true).catch((error: Error): void => {
      if (this.closing === work) this.closing = undefined;
      throw error as Error;
    });
    this.closeAt = this.submission; this.closing = work; return work;
  }

  retire(): Promise<void> {
    this.retired = true;
    if (HmsPdfPages.owner === this) HmsPdfPages.owner = undefined;
    if (this.ownPending === 0 && !this.input && !this.document && !this.page && !this.pixels && !this.packer) return Promise.resolve();
    return this.close();
  }
}
