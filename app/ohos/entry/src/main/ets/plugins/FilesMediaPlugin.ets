// UNCOMPILED_HMS、未在真机核实。PDFKit 独立于公开文件/选择器/媒体接口；使用安全 openUserFile。
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import fileUri from '@ohos.file.fileuri';
import photoAccessHelper from '@ohos.file.photoAccessHelper';
import common from '@ohos.app.ability.common';
import wantConstant from '@ohos.app.ability.wantConstant';
import cryptoFramework from '@ohos.security.cryptoFramework';
import util from '@ohos.util';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import { loadNativeHost } from '../runtime/NativeHost';
import { RuntimeController } from '../runtime/RuntimeController';
import { RuntimePaths } from '../runtime/RuntimePaths';
import { HmsPdfPages } from './HmsPdfPages';
import { PdfChannelError } from './PdfInput';
import {
  AbilityAware, AbilityPluginBinding, Any, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';

class FileChannelError extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

export default class FilesMediaPlugin implements FlutterPlugin, AbilityAware {
  private engineBinding?: FlutterPluginBinding;
  private context?: common.Context;
  private paths?: RuntimePaths;
  private ability?: AbilityPluginBinding;
  private files?: MethodChannel;
  private media?: MethodChannel;
  private generation: number = 0;
  private picking: boolean = false;
  private pdf?: HmsPdfPages;

  getUniqueClassName(): string { return 'DshFilesMediaPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    if (this.engineBinding) this.onDetachedFromEngine(this.engineBinding);
    this.engineBinding = binding;
    this.context = binding.getApplicationContext();
    this.paths = RuntimeController.get(this.context).paths;
    this.files = new MethodChannel(binding.getBinaryMessenger(), 'dsh/files');
    this.media = new MethodChannel(binding.getBinaryMessenger(), 'dsh/media');
    this.files.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (this.engineBinding !== binding) { result.error('cancelled', '窗口已关闭，操作已取消。', null); return; }
      if (!['resolveGuest', 'listOutputs', 'open', 'saveToDownloads', 'pdfInfo', 'pdfPage', 'pdfClose'].includes(call.method)) {
        result.notImplemented(); return;
      }
      this.reply(this.fileCall(call), result);
    } });
    this.media.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (this.engineBinding !== binding) { result.error('cancelled', '窗口已关闭，操作已取消。', null); return; }
      if (!['saveImage', 'openSettings'].includes(call.method)) { result.notImplemented(); return; }
      this.reply(this.mediaCall(call), result);
    } });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.engineBinding !== binding) return;
    this.onDetachedFromAbility();
    this.files?.setMethodCallHandler(null);
    this.media?.setMethodCallHandler(null);
    this.files = undefined; this.media = undefined; this.context = undefined; this.paths = undefined; this.engineBinding = undefined;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    if (this.ability && this.ability !== binding) this.onDetachedFromAbility();
    this.ability = binding;
  }
  onDetachedFromAbility(): void {
    this.generation++; this.ability = undefined;
    const pdf = this.pdf; this.pdf = undefined;
    if (pdf) pdf.retire().catch((): void => { hilog.warn(0xD003F00, 'DshFiles', 'PDF资源清理尚未完成'); });
  }

  private reply(work: Promise<Any>, result: MethodResult): void {
    work.then((value: Any) => result.success(value)).catch((error: Error) => {
      if (error instanceof FileChannelError || error instanceof PdfChannelError) result.error(error.code, error.message, null);
      else result.error('failed', '文件操作未完成，请重试或使用已连接的电脑。', null);
    });
  }

  private active(generation: number): void {
    if (generation !== this.generation || !this.context) throw new FileChannelError('cancelled', '窗口已关闭，操作已取消。');
  }

  private ui(): common.UIAbilityContext {
    if (!this.ability) throw new FileChannelError('no_ability', '请先回到应用窗口再操作。');
    return this.ability.getAbility().context;
  }

  private async openLocal(path: string, generation: number): Promise<number> {
    const context = this.context!;
    const roots = [this.paths!.workspace, context.cacheDir, context.tempDir];
    if (this.ability) {
      const uiContext = this.ability.getAbility().context;
      roots.push(uiContext.cacheDir, uiContext.tempDir);
    }
    for (const root of roots) {
      if (path.startsWith(root + '/')) {
        const host = await loadNativeHost();
        this.active(generation);
        return host.openUserFile(root, path.substring(root.length + 1));
      }
    }
    throw new FileChannelError('outside_workspace', '请将文件放入本机工作区，或从已连接的电脑下载后再操作。');
  }

  private safeName(input: string): string {
    const parts = input.split(/[\\/]/);
    const cleaned = (parts[parts.length - 1] || 'file').replace(/[\x00-\x1f\x7f\\/:*?"'`<>|{}\[\]]/g, '_').trim();
    const encoder = new util.TextEncoder();
    let name = '';
    for (const character of cleaned) {
      if (encoder.encodeInto(name + character).byteLength > 240) break;
      name += character;
    }
    return name === '' || name === '.' || name === '..' ? 'file' : name;
  }

  private async directory(path: string): Promise<void> {
    try { await fs.mkdir(path); }
    catch (error) { if ((error as BusinessError).code !== 13900015) throw error as Error; }
    const stat = await fs.lstat(path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new FileChannelError('invalid', '文件缓存目录不可用。');
  }

  private async slot(key: string): Promise<string> {
    const root = this.context!.cacheDir + '/dsh-exports';
    await this.directory(root);
    const directory = root + '/' + key;
    await this.directory(directory);
    return directory;
  }

  private async temporary(): Promise<string> {
    const root = this.context!.cacheDir + '/dsh-exports';
    await this.directory(root);
    return fs.mkdtemp(root + '/.part-XXXXXX');
  }

  private async removeTemporary(directory: string, path?: string): Promise<void> {
    if (path) {
      try { await fs.unlink(path); }
      catch (_error) { hilog.warn(0xD003F00, 'DshFiles', '临时文件清理失败'); }
    }
    try {
      const stat = await fs.lstat(directory);
      // OH rmdir 会递归删除；只清理仍为空的自有暂存目录。
      if (stat.isDirectory() && !stat.isSymbolicLink() && (await fs.listFile(directory)).length === 0) {
        await fs.rmdir(directory);
      }
    } catch (_error) { hilog.warn(0xD003F00, 'DshFiles', '临时目录清理失败'); }
  }

  private async copy(input: number, output: number, generation: number): Promise<void> {
    const buffer = new ArrayBuffer(256 * 1024);
    const size = (await fs.stat(input)).size;
    let offset = 0;
    while (offset < size) {
      this.active(generation);
      const count = await fs.read(input, buffer, { offset: offset, length: Math.min(buffer.byteLength, size - offset) });
      if (count === 0) throw new FileChannelError('failed', '源文件在复制时缩短，请重试。');
      let written = 0;
      while (written < count) {
        this.active(generation);
        const n = await fs.write(output, buffer.slice(written, count), { offset: offset + written });
        if (n === 0) throw new FileChannelError('failed', '文件写入未完成，请检查可用空间。');
        written += n;
      }
      offset += count;
    }
    this.active(generation);
    await fs.fsync(output);
  }

  private async snapshot(path: string, name: string, generation: number): Promise<string> {
    const input = await this.openLocal(path, generation);
    let staging: string | undefined;
    let temporary: string | undefined;
    try {
      const hash = cryptoFramework.createMd('SHA256');
      await hash.update({ data: new util.TextEncoder().encodeInto(path) });
      const key = Array.from((await hash.digest()).data).map((value: number) => value.toString(16).padStart(2, '0')).join('');
      const directory = await this.slot(key);
      const target = directory + '/' + this.safeName(name);
      staging = await this.temporary();
      temporary = staging + '/payload.tmp';
      const output = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.NOFOLLOW);
      try { await this.copy(input, output.fd, generation); }
      finally { await fs.close(output); }
      this.active(generation);
      await fs.rename(temporary, target);
      temporary = undefined;
      return target;
    } finally {
      try { await fs.close(input); }
      finally { if (staging) await this.removeTemporary(staging, temporary); }
    }
  }

  private pdfFor(generation: number): HmsPdfPages {
    const context = this.ui();
    this.active(generation);
    if (!this.pdf) this.pdf = new HmsPdfPages(context, (path: string): Promise<number> => this.openLocal(path, generation));
    return this.pdf;
  }

  private async fileCall(call: MethodCall): Promise<Any> {
    const generation = this.generation;
    const path = (call.argument('path') ?? '') as string;
    const name = this.safeName((call.argument('name') ?? path.substring(path.lastIndexOf('/') + 1)) as string);
    switch (call.method) {
      case 'resolveGuest':
        try { return await this.snapshot(path, name, generation); }
        catch (error) {
          if (error instanceof FileChannelError && error.code === 'cancelled') throw error;
          return null;
        }
      case 'listOutputs': return await this.outputs((call.argument('depth') ?? 3) as number, generation);
      case 'pdfClose': {
        const pdf = this.pdf;
        if (pdf) await pdf.close();
        this.active(generation);
        return null;
      }
      case 'pdfInfo': {
        const pages: Map<string, Any>[] = await this.pdfFor(generation).info(path);
        this.active(generation);
        return pages;
      }
      case 'pdfPage': {
        const bytes = await this.pdfFor(generation).render(path, (call.argument('page') ?? 0) as number,
          (call.argument('width') ?? 1080) as number);
        this.active(generation);
        return bytes;
      }
      case 'open': {
        // No public way to force a chooser: viewData shows the system's when several apps match.
        const context = this.ui();
        const copy = await this.snapshot(path, name, generation);
        this.active(generation);
        await context.startAbility({ action: 'ohos.want.action.viewData', uri: fileUri.getUriFromPath(copy),
          type: (call.argument('mime') ?? 'application/octet-stream') as string,
          flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION });
        return null;
      }
      case 'saveToDownloads': {
        const context = this.ui();
        if (this.picking) throw new FileChannelError('busy', '已有文件选择窗口，请先完成或取消。');
        this.picking = true;
        try {
          const check = await this.openLocal(path, generation); await fs.close(check);
          this.active(generation);
          const selected = await new picker.DocumentViewPicker(context).save({ newFileNames: [name] });
          this.active(generation);
          if (selected.length !== 1) throw new FileChannelError('cancelled', '保存已取消。');
          const input = await this.openLocal(path, generation);
          try {
            const output = await fs.open(selected[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
            try { await this.copy(input, output.fd, generation); }
            finally { await fs.close(output); }
          } finally { await fs.close(input); }
          return selected[0];
        } finally { this.picking = false; }
      }
      default: return null;
    }
  }

  private async outputs(depth: number, generation: number): Promise<Map<string, Any>[]> {
    const root = this.paths!.outputs;
    const result: Map<string, Any>[] = [];
    if (!await fs.access(root)) return result;
    const rootStat = await fs.lstat(root);
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) {
      throw new FileChannelError('outside_workspace', '输出目录必须是本机工作区内的普通目录。');
    }
    const walk = async (directory: string, level: number): Promise<void> => {
      this.active(generation);
      const names = (await fs.listFile(directory, { recursion: false })).sort();
      for (const name of names) {
        if (result.length >= 500) return;
        if (name.startsWith('.')) continue;
        const path = directory + '/' + name;
        const stat = await fs.lstat(path);
        if (stat.isSymbolicLink()) continue;
        if (stat.isDirectory()) {
          if (level < depth) await walk(path, level + 1);
        } else if (stat.isFile()) {
          const input = await this.openLocal(path, generation);
          try {
            const actual = await fs.stat(input);
            result.push(new Map<string, Any>([['path', path], ['bytes', actual.size], ['modified', actual.mtime * 1000]]));
          } finally { await fs.close(input); }
        }
      }
    };
    await walk(root, 1);
    return result;
  }

  private async mediaCall(call: MethodCall): Promise<Any> {
    if (call.method === 'openSettings') return false; // 每次保存走确认对话框，不申请广泛媒体权限。
    const context = this.ui();
    const generation = this.generation;
    const bytes = call.argument('bytes') as Uint8Array;
    const mime = call.argument('mime') as string;
    let extension: string;
    switch (mime) {
      case 'image/png': extension = 'png'; break;
      case 'image/jpeg': extension = 'jpg'; break;
      case 'image/gif': extension = 'gif'; break;
      case 'image/webp': extension = 'webp'; break;
      default: throw new FileChannelError('invalid', '此图片格式不能保存到相册。');
    }
    if (bytes.byteLength === 0) throw new FileChannelError('invalid', '图片为空。');
    if (this.picking) throw new FileChannelError('busy', '已有文件选择窗口，请先完成或取消。');
    this.picking = true;
    const name = this.safeName(call.argument('name') as string);
    const dot = name.lastIndexOf('.');
    const title = dot > 0 ? name.substring(0, dot) : name;
    let directory: string | undefined;
    let path: string | undefined;
    let helper: photoAccessHelper.PhotoAccessHelper | undefined;
    try {
      directory = await this.temporary();
      path = directory + '/' + title + '.' + extension;
      const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.NOFOLLOW);
      try {
        let offset = 0;
        while (offset < bytes.byteLength) {
          this.active(generation);
          const chunk = bytes.slice(offset, Math.min(offset + 256 * 1024, bytes.byteLength));
          const written = await fs.write(file.fd, chunk.buffer, { offset: offset });
          if (written === 0) throw new FileChannelError('failed', '图片写入未完成。');
          offset += written;
        }
        await fs.fsync(file.fd);
      } finally { await fs.close(file); }
      this.active(generation);
      helper = photoAccessHelper.getPhotoAccessHelper(context);
      const uris = await helper.showAssetsCreationDialog([fileUri.getUriFromPath(path)],
        [{ title: title, fileNameExtension: extension, photoType: photoAccessHelper.PhotoType.IMAGE }]);
      this.active(generation);
      if (uris.length !== 1) throw new FileChannelError('cancelled', '保存图片已取消。');
      const input = await this.openLocal(path, generation);
      try {
        const output = await fs.open(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        try { await this.copy(input, output.fd, generation); }
        finally { await fs.close(output); }
      } finally { await fs.close(input); }
      return uris[0];
    } finally {
      this.picking = false;
      if (helper) {
        try { await helper.release(); } catch (_error) { hilog.warn(0xD003F00, 'DshFiles', '相册句柄释放失败'); }
      }
      if (directory) await this.removeTemporary(directory, path);
    }
  }
}
