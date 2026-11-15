// 未编译、未在真机核实。Only the system picker supplies result URIs.
// Dart owns page/navigation validity; this layer cannot prove WebView visibility.
import picker from '@ohos.file.picker';
import uniformTypeDescriptor from '@ohos.data.uniformTypeDescriptor';
import {
  AbilityAware, AbilityPluginBinding, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { WebPickRequest, webFileSelection, webFileSuffixFilters } from './WebFilePolicy';

class WebPickPending {
  readonly owner: string;
  readonly result: MethodResult;
  constructor(owner: string, result: MethodResult) { this.owner = owner; this.result = result; }
}

// Shared by plugin instances in this Ark module. Cancelling a callback does not
// dismiss DocumentViewPicker, which has no public cancellation API.
let activePicker: WebPickPending | null = null;

export default class WebFilesPlugin implements FlutterPlugin, AbilityAware {
  private engine: FlutterPluginBinding | null = null;
  private ability: AbilityPluginBinding | null = null;
  private channel: MethodChannel | null = null;
  private pending: WebPickPending | null = null;

  getUniqueClassName(): string { return 'DshWebFilesPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.cancel(); this.channel?.setMethodCallHandler(null);
    this.engine = binding; this.ability = null;
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/web-files');
    this.channel.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (call.method === 'pick') {
        if (this.engine !== binding) result.success([]);
        else this.pick(call, result);
      } else if (call.method === 'cancel') {
        if (this.engine === binding && call.args instanceof Map &&
            call.args.get('owner') === this.pending?.owner) this.cancel();
        result.success(null);
      } else result.notImplemented();
    } });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.engine !== binding) return;
    this.cancel(); this.channel?.setMethodCallHandler(null);
    this.channel = null; this.engine = null; this.ability = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    if (this.ability !== binding) this.cancel();
    this.ability = binding;
  }

  onDetachedFromAbility(): void { this.cancel(); this.ability = null; }

  private cancel(): void {
    const request = this.pending;
    this.pending = null;
    request?.result.success([]);
  }

  private finish(request: WebPickPending, values: string[]): void {
    if (activePicker === request) activePicker = null;
    if (this.pending !== request) return;
    this.pending = null;
    request.result.success(values);
  }

  private pick(call: MethodCall, result: MethodResult): void {
    const request = WebPickRequest.parse(call.args as Map<string, Object | null> | null);
    const ability = this.ability;
    if (request === null || ability === null || activePicker !== null) { result.success([]); return; }
    const pending = new WebPickPending(request.owner, result);
    this.pending = pending; activePicker = pending;
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = request.multiple ? 500 : 1;
      options.selectMode = picker.DocumentSelectMode.FILE;
      const filters = webFileSuffixFilters(request.acceptTypes, (mime: string): string[] => {
        const type = uniformTypeDescriptor.getUniformDataTypeByMIMEType(mime);
        return uniformTypeDescriptor.getTypeDescriptor(type)?.filenameExtensions ?? [];
      });
      if (filters.length !== 0) options.fileSuffixFilters = filters;
      new picker.DocumentViewPicker(ability.getAbility().context).select(options).then(
        (uris: string[]): void => this.finish(pending, webFileSelection(uris, request.multiple)),
        (): void => this.finish(pending, [])
      );
    } catch (_) { this.finish(pending, []); }
  }
}
