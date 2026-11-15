// System selection only: no storage permission, persistent grant, or cache copy.
// Byte access begins in Dart's separate read call, never inside the PhotoPicker callback.
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import photoAccessHelper from '@ohos.file.photoAccessHelper';
import fileUri from '@ohos.file.fileuri';
import uniformTypeDescriptor from '@ohos.data.uniformTypeDescriptor';
import util from '@ohos.util';
import UIAbility from '@ohos.app.ability.UIAbility';
import hilog from '@ohos.hilog';
import {
  AbilityAware, AbilityPluginBinding, Any, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import {
  NativeFileError, NativeFileRequest, nativeFileMime, nativeFileName, nativeFileUris
} from './NativeFilePolicy';

class SelectedNativeFile {
  readonly handle: string;
  readonly uri: string;
  readonly name: string;
  readonly mediaType: string;
  file: fs.File | null = null;
  offset: number = 0;
  ended: boolean = false;
  constructor(value: string) {
    this.handle = util.generateRandomUUID(false); this.uri = value;
    this.name = nativeFileName(new fileUri.FileUri(value).name);
    let mime = 'application/octet-stream';
    const dot = this.name.lastIndexOf('.');
    if (dot > 0) {
      try {
        const type = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(this.name.substring(dot));
        mime = nativeFileMime(uniformTypeDescriptor.getTypeDescriptor(type)?.mimeTypes[0] ?? mime);
      } catch (_) { /* Unknown metadata remains application/octet-stream. */ }
    }
    this.mediaType = mime;
  }
  metadata(): Map<string, Any> {
    const out: Map<string, Any> = new Map<string, Any>();
    out.set('handle', this.handle); out.set('name', this.name);
    // The public PhotoPicker guide forbids opening its URI in the select callback.
    // Dart explicitly permits unknown lengths; first read checks fstat plus the actual byte stream.
    out.set('bytes', null); out.set('mediaType', this.mediaType); return out;
  }
}

class NativeSelection {
  readonly request: NativeFileRequest;
  readonly engine: FlutterPluginBinding;
  readonly ability: AbilityPluginBinding;
  pending: MethodResult | null;
  files: SelectedNativeFile[] = [];
  active: boolean = true;
  picking: boolean = true;
  ioBusy: boolean = false;
  closing: boolean = false;
  timer: number = -1;
  constructor(request: NativeFileRequest, engine: FlutterPluginBinding, ability: AbilityPluginBinding, result: MethodResult) {
    this.request = request; this.engine = engine; this.ability = ability; this.pending = result;
  }
}

// This lease represents actual platform work across engine/plugin replacements.
// Cancelling Flutter's result cannot dismiss a public OH picker or abort fs.read.
let fileLease: NativeSelection | null = null;
const foregroundAbilities: WeakSet<UIAbility> = new WeakSet();

export default class NativeFilesPlugin implements FlutterPlugin, AbilityAware {
  private engine: FlutterPluginBinding | null = null;
  private ability: AbilityPluginBinding | null = null;
  private channel: MethodChannel | null = null;
  private selection: NativeSelection | null = null;

  static onForeground(ability: UIAbility): void { foregroundAbilities.add(ability); }
  static onBackground(ability: UIAbility): void { foregroundAbilities.delete(ability); }
  getUniqueClassName(): string { return 'DshNativeFilesPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.cancel(); this.channel?.setMethodCallHandler(null);
    this.engine = binding; this.ability = null;
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/native-files');
    this.channel.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (this.engine !== binding) { this.error(result, new NativeFileError('cancelled', '文件通道已关闭。')); return; }
      if (call.method === 'capabilities') {
        const value: Map<string, Any> = new Map<string, Any>(); value.set('files', canIUse('SystemCapability.FileManagement.UserFileService'));
        this.success(result, value);
      } else if (call.method === 'pick') this.pick(call, result);
      else if (call.method === 'read') this.read(call, result);
      else if (call.method === 'cancel') {
        if (call.argument('owner') === this.selection?.request.owner) this.cancel();
        this.success(result, null);
      } else { try { result.notImplemented(); } catch (_) { /* The old messenger may be gone. */ } }
    } });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.engine !== binding) return;
    this.cancel(); this.channel?.setMethodCallHandler(null);
    this.channel = null; this.engine = null; this.ability = null;
  }
  onAttachedToAbility(binding: AbilityPluginBinding): void {
    if (this.ability !== binding) this.cancel(); this.ability = binding;
  }
  onDetachedFromAbility(): void { this.cancel(); this.ability = null; }

  private current(value: NativeSelection): boolean {
    return value.active && this.selection === value && this.engine === value.engine && this.ability === value.ability;
  }
  private assertCurrent(value: NativeSelection): void {
    if (!this.current(value)) throw new NativeFileError('cancelled', '文件选择已取消或过期。');
  }
  private error(result: MethodResult, error: Error | NativeFileError): void {
    try {
      if (error instanceof NativeFileError) result.error(error.code, error.message, null);
      else result.error('failed', '无法读取所选文件，请重试。', null);
    } catch (_) { /* Never turn a failed transport into a second method reply. */ }
  }
  private success(result: MethodResult, value: Any): void {
    try { result.success(value); } catch (_) { /* Resource retirement must continue after engine teardown. */ }
  }

  private pick(call: MethodCall, result: MethodResult): void {
    try {
      const request = NativeFileRequest.parse(call.args);
      const engine = this.engine; const ability = this.ability;
      if (engine === null || ability === null || !foregroundAbilities.has(ability.getAbility())) {
        throw new NativeFileError('unavailable', '请在应用前台点击选择文件。');
      }
      if (fileLease !== null) {
        // A detached plugin has no method handler left to retry a failed close.
        // Only retired, idle leases are retried; this request still reports busy
        // until physical closure finishes. No picker can appear after cancel.
        if (this.selection !== fileLease || fileLease.engine !== engine || fileLease.request.owner !== request.owner) {
          this.closeWhenIdle(fileLease);
        }
        throw new NativeFileError('busy', '上一项文件选择或读取尚未关闭，请稍后重试。');
      }
      const photos = request.images || request.visual;
      const syscap = photos ? 'SystemCapability.FileManagement.PhotoAccessHelper.Core' : 'SystemCapability.FileManagement.UserFileService';
      if (!canIUse(syscap)) throw new NativeFileError('unavailable', '当前设备没有所需的系统文件选择器。');
      const selected = new NativeSelection(request, engine, ability, result);
      fileLease = selected; this.selection = selected;
      selected.timer = setTimeout((): void => this.revoke(selected), 5 * 60 * 1000);
      let work: Promise<string[]>;
      try {
        if (photos) {
          const options = new photoAccessHelper.PhotoSelectOptions();
          options.maxSelectNumber = request.budget.maxFiles;
          options.MIMEType = request.visual ? photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE : photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
          work = new photoAccessHelper.PhotoViewPicker().select(options).then((value: photoAccessHelper.PhotoSelectResult): string[] => value.photoUris);
        } else {
          const options = new picker.DocumentSelectOptions();
          options.maxSelectNumber = request.budget.maxFiles; options.selectMode = picker.DocumentSelectMode.FILE;
          work = new picker.DocumentViewPicker(ability.getAbility().context).select(options);
        }
      } catch (error) {
        selected.picking = false;
        selected.pending = null; this.revoke(selected); throw error as Error;
      }
      work.then((values: string[]): void => {
        selected.picking = false;
        if (!this.current(selected)) { this.closeWhenIdle(selected); return; }
        const reply = selected.pending; selected.pending = null;
        if (reply === null) { this.revoke(selected); return; }
        try {
          const uris = nativeFileUris(values, request.budget.maxFiles);
          if (uris.length === 0) { this.revoke(selected); this.success(reply, null); return; }
          selected.files = uris.map((value: string): SelectedNativeFile => new SelectedNativeFile(value));
          this.success(reply, selected.files.map((value: SelectedNativeFile): Map<string, Any> => value.metadata()));
        } catch (error) { this.revoke(selected); this.error(reply, error as Error); }
      }, (error: Error): void => {
        selected.picking = false;
        const reply = selected.pending; selected.pending = null;
        this.revoke(selected);
        if (reply !== null) this.error(reply, new NativeFileError('unavailable', '系统文件选择未完成。'));
      });
    } catch (error) { this.error(result, error as Error); }
  }

  private read(call: MethodCall, result: MethodResult): void {
    const selected = this.selection;
    const handle: Any = call.argument('handle');
    const entry = selected?.files.find((value: SelectedNativeFile): boolean => value.handle === handle);
    if (selected === null || !this.current(selected) || selected.request.owner !== call.argument('owner') || entry === undefined) {
      this.error(result, new NativeFileError('cancelled', '文件选择已取消或过期。')); return;
    }
    if (selected.ioBusy || selected.closing || selected.picking) {
      this.error(result, new NativeFileError('busy', '文件读取尚未结束。')); return;
    }
    selected.ioBusy = true;
    this.readChunk(selected, entry).then((value: Uint8Array | null): void => {
      selected.ioBusy = false;
      if (this.current(selected)) this.success(result, value);
      else this.error(result, new NativeFileError('cancelled', '文件选择已取消或过期。'));
      this.closeWhenIdle(selected);
    }, (error: Error): void => {
      selected.ioBusy = false;
      const active = this.current(selected);
      this.revoke(selected);
      this.error(result, active ? error : new NativeFileError('cancelled', '文件选择已取消或过期。'));
    });
  }

  private async readChunk(selected: NativeSelection, entry: SelectedNativeFile): Promise<Uint8Array | null> {
    this.assertCurrent(selected);
    if (entry.ended) return null;
    if (entry.file === null) {
      // The URI comes only from this selection, never from a method-call path argument.
      entry.file = await fs.open(entry.uri, fs.OpenMode.READ_ONLY | fs.OpenMode.NONBLOCK);
      this.assertCurrent(selected);
      const stat = await fs.stat(entry.file.fd);
      this.assertCurrent(selected);
      if (!stat.isFile()) throw new NativeFileError('invalid', '所选资源不是普通文件。');
      selected.request.budget.known(entry.handle, stat.size);
    }
    const countLimit = selected.request.budget.chunkSize(entry.handle);
    const buffer = new ArrayBuffer(countLimit);
    const count = await fs.read(entry.file.fd, buffer, { offset: entry.offset, length: countLimit });
    this.assertCurrent(selected);
    if (!Number.isSafeInteger(count) || count < 0 || count > countLimit) throw new NativeFileError('failed', '文件读取返回了无效长度。');
    if (count === 0) {
      await fs.close(entry.file); entry.file = null; entry.ended = true;
      this.assertCurrent(selected); return null;
    }
    selected.request.budget.accept(entry.handle, count);
    entry.offset += count; return new Uint8Array(buffer.slice(0, count));
  }

  private cancel(): void { if (this.selection !== null) this.revoke(this.selection); }
  private revoke(selected: NativeSelection): void {
    selected.active = false;
    if (selected.timer >= 0) { clearTimeout(selected.timer); selected.timer = -1; }
    const result = selected.pending; selected.pending = null;
    if (result !== null) this.success(result, null);
    this.closeWhenIdle(selected);
  }
  private closeWhenIdle(selected: NativeSelection): void {
    if (selected.active || selected.picking || selected.ioBusy || selected.closing) return;
    selected.closing = true;
    this.closeFiles(selected).then((): void => {
      selected.closing = false;
      if (selected.files.some((value: SelectedNativeFile): boolean => value.file !== null)) return;
      if (fileLease === selected) fileLease = null;
      if (this.selection === selected) this.selection = null;
    });
  }
  private async closeFiles(selected: NativeSelection): Promise<void> {
    for (const entry of selected.files) {
      if (entry.file === null) continue;
      try { await fs.close(entry.file); entry.file = null; }
      catch (_) { hilog.warn(0xD003F00, 'DshNativeFiles', '所选文件句柄关闭失败，保留物理占用'); }
    }
  }
}
