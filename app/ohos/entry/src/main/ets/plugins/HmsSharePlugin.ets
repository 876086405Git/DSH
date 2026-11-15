// UNCOMPILED_HMS / 未编译、未在真机核实。HMS 签名依据共享 hms-contracts.md，非 SDK 编译结果。
import type { systemShare } from '@kit.ShareKit';
import { ShareKit, loadShareKit } from './HmsKits';
import fileUri from '@ohos.file.fileuri';
import display from '@ohos.display';
import {
  AbilityAware, AbilityPluginBinding, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { HmsShareInbox } from './HmsShareInbox';
import { HmsShareStorage, ShareBatch } from './HmsShareStorage';
import {
  ShareError, ShareRequest, SHARE_UNAVAILABLE, SHARE_METADATA_BUDGET,
  parseShareRequest, outgoingUtd, safeShareName, utf8Size
} from './HmsSharePolicy';

class ShareLease {
  plugin: HmsSharePlugin;
  engine: FlutterPluginBinding;
  ability: AbilityPluginBinding;
  result: MethodResult;
  storage: HmsShareStorage;
  batch?: ShareBatch;
  controller?: systemShare.ShareController;
  dismiss?: () => void;
  completed?: (result: systemShare.ShareOperationResult) => void;
  valid: boolean = true;
  replied: boolean = false;
  showing: boolean = false;
  closed: boolean = false;
  constructor(plugin: HmsSharePlugin, engine: FlutterPluginBinding, ability: AbilityPluginBinding,
    result: MethodResult, storage: HmsShareStorage) {
    this.plugin = plugin; this.engine = engine; this.ability = ability; this.result = result; this.storage = storage;
  }

  reply(value: string): void {
    if (this.replied) return;
    this.replied = true;
    try { this.result.success(this.valid ? value : SHARE_UNAVAILABLE); }
    catch (_error) { /* Flutter transport 已退休；仍必须完成物理 lease 收束。 */ }
  }

  error(error: Error): void {
    if (this.replied) return;
    this.replied = true;
    try {
      if (!this.valid) this.result.success(SHARE_UNAVAILABLE);
      else if (error instanceof ShareError) this.result.error(error.code, error.message, null);
      else this.result.error('share_failed', '系统分享未完成，请重试。', null);
    } catch (_error) { /* 不重投递已尝试过的旧 transport。 */ }
  }
}

// 同一 Ark 模块内跨插件实例保留物理面板 lease，不把逻辑取消当成面板关闭。
let activeShare: ShareLease | undefined;

export default class HmsSharePlugin implements FlutterPlugin, AbilityAware {
  private engine?: FlutterPluginBinding;
  private ability?: AbilityPluginBinding;
  private outgoing?: MethodChannel;
  private incoming?: MethodChannel;

  getUniqueClassName(): string { return 'DshHmsSharePlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    if (this.engine) this.onDetachedFromEngine(this.engine);
    if (activeShare && (activeShare.plugin !== this || activeShare.engine !== binding)) {
      activeShare.valid = false; activeShare.reply(SHARE_UNAVAILABLE);
    }
    this.engine = binding; this.ability = undefined;
    this.outgoing = new MethodChannel(binding.getBinaryMessenger(), 'dev.fluttercommunity.plus/share');
    this.incoming = new MethodChannel(binding.getBinaryMessenger(), 'dsh/share');
    HmsShareInbox.attach(binding, this.incoming);
    this.outgoing.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (this.engine !== binding) { result.success(SHARE_UNAVAILABLE); return; }
      if (call.method !== 'share') { result.notImplemented(); return; }
      this.share(call, result);
    } });
    this.incoming.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (call.method !== 'ready') { result.notImplemented(); return; }
      if (this.engine !== binding) { result.success(false); return; }
      HmsShareInbox.ready(binding, (ready: boolean): void => result.success(ready));
    } });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.engine !== binding) return;
    this.onDetachedFromAbility();
    HmsShareInbox.detach(binding);
    this.outgoing?.setMethodCallHandler(null); this.incoming?.setMethodCallHandler(null);
    this.outgoing = undefined; this.incoming = undefined; this.engine = undefined;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    if (this.ability !== binding) this.onDetachedFromAbility();
    this.ability = binding;
  }

  onDetachedFromAbility(): void {
    this.ability = undefined;
    const lease = activeShare;
    if (lease?.plugin === this) {
      lease.valid = false; lease.reply(SHARE_UNAVAILABLE);
      // preparing 在实际 IO 收束后释放；showing 必须等 dismiss 或 show 的明确失败。
    }
  }

  private share(call: MethodCall, result: MethodResult): void {
    try {
      const request = parseShareRequest(call.args);
      if (!canIUse('SystemCapability.Collaboration.SystemShare')) throw new ShareError('unsupported', '系统分享在这台设备上不可用。');
      if (!this.engine || !this.ability) throw new ShareError('no_ability', '请回到应用窗口后再分享。');
      if (activeShare) throw new ShareError('busy', '已有分享操作，请先关闭系统分享窗口。');
      const lease = new ShareLease(this, this.engine, this.ability, result, new HmsShareStorage(this.engine.getApplicationContext()));
      activeShare = lease;
      this.prepare(lease, request).catch(async (error: Error): Promise<void> => {
        lease.error(error);
        if (lease.batch && !lease.showing) await lease.storage.discard(lease.batch);
        this.close(lease);
      });
    } catch (error) {
      if (error instanceof ShareError) result.error(error.code, error.message, null);
      else result.error('share_failed', '系统分享未完成，请重试。', null);
    }
  }

  private check(lease: ShareLease): void {
    if (!lease.valid || lease.closed || activeShare !== lease || this.engine !== lease.engine || this.ability !== lease.ability) {
      throw new ShareError('cancelled', '分享窗口已失效。');
    }
  }

  private async prepare(lease: ShareLease, request: ShareRequest): Promise<void> {
    let kit: ShareKit;
    try { kit = await loadShareKit(); }
    catch (_) { throw new ShareError('unsupported', '系统分享在这台设备上不可用。'); }
    this.check(lease);
    lease.batch = await lease.storage.outgoing(request, lease.ability.getAbility().context, (): void => this.check(lease));
    this.check(lease);
    const records: systemShare.SharedRecord[] = [];
    if (lease.batch) {
      for (let i = 0; i < lease.batch.paths.length; i++) {
        const record: systemShare.SharedRecord = {
          utd: outgoingUtd(request.paths[i], request.mimes[i]),
          uri: fileUri.getUriFromPath(lease.batch.paths[i]),
          title: i === 0 && (request.title || request.subject) ? request.title || request.subject : safeShareName(request.paths[i])
        };
        // HMS 的文本+文件混合支持未定；不把纯文本放进 BATCH。目标是否呈现 description 待真机核实。
        if (i === 0 && request.text) record.description = request.text;
        records.push(record);
      }
    } else {
      records.push({ utd: request.link ? 'general.hyperlink' : 'general.plain-text', content: request.text,
        title: request.title || request.subject || undefined });
    }
    // 本地预算留出 Want 开销；平台 200KB 的最终判定仍由 show 的错误返回处理。
    if (utf8Size(JSON.stringify(records)) > SHARE_METADATA_BUDGET) throw new ShareError('too_large', '分享描述过长，请减少项目或文字。');
    const data = kit.createData(records[0]);
    for (let i = 1; i < records.length; i++) data.addRecord(records[i]);
    const controller = kit.createController(data);
    lease.controller = controller;
    lease.dismiss = (): void => {
      if (lease.closed) return;
      // 文档没有保证 completed/dismiss 顺序；没有已见成功证据时只报 unavailable。
      lease.reply(SHARE_UNAVAILABLE); this.close(lease);
    };
    lease.completed = (value: systemShare.ShareOperationResult): void => {
      if (lease.closed) return;
      const name = value?.targetAbilityInfo?.name;
      lease.reply(typeof name === 'string' && name.length > 0 && name.length <= 1024 ? name : SHARE_UNAVAILABLE);
      // 成功事件只结算 Dart 回包；仍保留 dismiss 监听和物理面板 lease。
    };
    controller.on('dismiss', lease.dismiss);
    controller.on('shareCompleted', lease.completed);
    const options: systemShare.ShareControllerOptions = {
      selectionMode: records.length > 1 ? kit.batch : kit.single,
      previewMode: kit.preview
    };
    if (request.origin) {
      const density = display.getDefaultDisplaySync().densityPixels;
      if (!(density > 0) || !Number.isFinite(density)) throw new ShareError('share_failed', '无法读取分享窗口的显示比例。');
      options.anchor = { windowOffset: { x: request.origin[0] * density, y: request.origin[1] * density },
        size: { width: request.origin[2] * density, height: request.origin[3] * density } };
    }
    this.check(lease);
    lease.showing = true;
    // show resolve 没有用户结果，也不证明面板关闭；只处理明确 reject。
    await controller.show(lease.ability.getAbility().context, options);
  }

  private close(lease: ShareLease): void {
    if (lease.closed) return;
    lease.closed = true;
    if (lease.dismiss) { try { lease.controller?.off('dismiss', lease.dismiss); } catch (_error) { /* SDK teardown. */ } }
    if (lease.completed) { try { lease.controller?.off('shareCompleted', lease.completed); } catch (_error) { /* SDK teardown. */ } }
    if (lease.batch) lease.storage.release(lease.batch);
    if (activeShare === lease) activeShare = undefined;
  }
}
