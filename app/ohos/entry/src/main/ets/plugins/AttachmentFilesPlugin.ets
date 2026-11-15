import picker from '@ohos.file.picker';
import hilog from '@ohos.hilog';
import {
  AbilityAware, AbilityPluginBinding, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { AttachmentFileBatch, AttachmentFileRequest, AttachmentFileRetired } from './AttachmentFileStore';

class AttachmentPickPending {
  readonly request: AttachmentFileRequest;
  readonly result: MethodResult;
  readonly batch: AttachmentFileBatch;
  cancelled: boolean = false;
  responded: boolean = false;
  delivered: boolean = false;
  workDone: boolean = false;
  cleanup: Promise<void> | null = null;
  constructor(request: AttachmentFileRequest, result: MethodResult, cacheDir: string) {
    this.request = request; this.result = result; this.batch = new AttachmentFileBatch(cacheDir);
  }
}

// Logical cancel keeps the slot while its Ability is live. Retirement frees
// admission without claiming that DocumentViewPicker or in-flight I/O stopped.
let activePick: AttachmentPickPending | null = null;

// Keep only batches, not old Dart results or Ability bindings. A retry takes
// one snapshot and runs serially; repeated picks neither await it nor fan out I/O.
const deferredCleanup: Set<AttachmentFileBatch> = new Set<AttachmentFileBatch>();
let cleanupRetry: Promise<void> | null = null;

function cleanupWarning(): void {
  // No URI, filename, file contents or private key is logged.
  hilog.warn(0, 'DshAttachmentFiles', 'Attachment cache cleanup failed');
}

async function retryCleanup(batches: AttachmentFileBatch[]): Promise<void> {
  for (const batch of batches) {
    deferredCleanup.delete(batch);
    try { await batch.release(); }
    catch (_) { deferredCleanup.add(batch); cleanupWarning(); }
  }
}

export default class AttachmentFilesPlugin implements FlutterPlugin, AbilityAware {
  private engine: FlutterPluginBinding | null = null;
  private ability: AbilityPluginBinding | null = null;
  private channel: MethodChannel | null = null;
  private pending: AttachmentPickPending | null = null;
  private ready: Promise<void> = Promise.resolve();

  getUniqueClassName(): string { return 'DshAttachmentFilesPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.retire(); this.channel?.setMethodCallHandler(null);
    this.engine = binding; this.ability = null;
    this.ready = AttachmentFileBatch.initialize(binding.getApplicationContext().cacheDir)
      .catch((): void => cleanupWarning());
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/attachment-files');
    this.channel.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (this.engine !== binding) { result.error('ohos_attachment_detached', 'Attachment picker detached', null); return; }
      if (call.method === 'pick') this.pick(call, result);
      else if (call.method === 'release' || call.method === 'cancel') {
        const request = this.pending;
        if (request === null || !(call.args instanceof Map) || call.args.get('owner') !== request.request.owner) {
          result.success(null); return;
        }
        this.cancel(request);
        if (!request.workDone) { result.success(null); return; }
        this.cleanup(request).then((): void => result.success(null), (): void => {
          cleanupWarning();
          result.error('ohos_attachment_cleanup', 'Unable to release attachment cache', null);
        });
      } else result.notImplemented();
    } });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.engine !== binding) return;
    this.retire(); this.channel?.setMethodCallHandler(null);
    this.engine = null; this.ability = null; this.channel = null;
  }
  onAttachedToAbility(binding: AbilityPluginBinding): void {
    if (this.ability !== binding) this.retire();
    this.ability = binding;
  }
  onDetachedFromAbility(): void { this.retire(); this.ability = null; }

  private cancel(request: AttachmentPickPending): void {
    request.cancelled = true;
    if (!request.responded) { request.responded = true; request.result.success([]); }
  }

  private retire(): void {
    const request = this.pending;
    if (request === null) return;
    this.cancel(request);
    this.pending = null;
    if (activePick === request) activePick = null;
    if (request.workDone) this.cleanup(request).catch((): void => cleanupWarning());
  }

  private cleanup(request: AttachmentPickPending): Promise<void> {
    if (request.cleanup !== null) return request.cleanup;
    request.cleanup = request.batch.release().then((): void => {
      if (this.pending === request) this.pending = null;
      if (activePick === request) activePick = null;
    }, (error: Error): void => {
      // Dart has already released ownership and may never return this owner.
      // Retain only the unfinished batch; cleanup failure cannot strand admission.
      deferredCleanup.add(request.batch);
      if (this.pending === request) this.pending = null;
      if (activePick === request) activePick = null;
      request.cleanup = null;
      throw error;
    });
    return request.cleanup;
  }

  private pick(call: MethodCall, result: MethodResult): void {
    const options = AttachmentFileRequest.parse(call.args as Map<string, Object | null> | null);
    const ability = this.ability;
    const engine = this.engine;
    if (options === null) { result.error('ohos_attachment_arguments', 'Invalid attachment selection', null); return; }
    if (ability === null || engine === null) { result.error('ohos_attachment_detached', 'Attachment picker unavailable', null); return; }
    if (activePick !== null) { result.error('ohos_attachment_busy', 'Another attachment selection is still active', null); return; }
    if (cleanupRetry === null && deferredCleanup.size !== 0) {
      cleanupRetry = retryCleanup(Array.from(deferredCleanup)).finally((): void => { cleanupRetry = null; });
    }
    const pending = new AttachmentPickPending(options, result, engine.getApplicationContext().cacheDir);
    activePick = pending; this.pending = pending;
    this.run(pending, ability).catch((): void => cleanupWarning());
  }

  private async run(pending: AttachmentPickPending, ability: AbilityPluginBinding): Promise<void> {
    const current = (): boolean => this.pending === pending && !pending.cancelled && this.ability === ability;
    try {
      await this.ready;
      if (!current()) throw new AttachmentFileRetired();
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = pending.request.limit;
      options.selectMode = picker.DocumentSelectMode.FILE;
      const uris = await new picker.DocumentViewPicker(ability.getAbility().context).select(options);
      if (!current()) throw new AttachmentFileRetired();
      const entries = uris.length === 0 ? [] : await pending.batch.copy(uris, pending.request, current);
      if (!current()) throw new AttachmentFileRetired();
      pending.workDone = true;
      pending.responded = true;
      pending.result.success(entries.map(entry => entry.toMap()));
      pending.delivered = entries.length !== 0;
    } catch (error) {
      if (!pending.responded) {
        pending.responded = true;
        if (error instanceof AttachmentFileRetired) pending.result.success([]);
        else pending.result.error('ohos_attachment_io', 'Unable to read the selected attachment', null);
      }
    } finally {
      pending.workDone = true;
      if (!pending.delivered || pending.cancelled) await this.cleanup(pending);
    }
  }
}
