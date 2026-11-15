// 未经 HarmonyOS SDK 编译、未在真机核实；通道签名已核固定 oh-flutter e5f752d。
import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import MethodChannel, { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import EventChannel, { StreamHandler, EventSink } from '@ohos/flutter_ohos/src/main/ets/plugin/common/EventChannel';
import Any from '@ohos/flutter_ohos/src/main/ets/plugin/common/Any';
import { AbilityAware, AbilityPluginBinding } from '@ohos/flutter_ohos';
import { BusinessError } from '@ohos.base';
import { RuntimeChannelError } from './RuntimeCore';
import { RuntimeController } from './RuntimeController';
import { ManagedSkillOwner } from './ManagedSkillService';

export class RuntimePlugin implements FlutterPlugin, MethodCallHandler, StreamHandler, AbilityAware {
  private methods: MethodChannel | null = null;
  private events: EventChannel | null = null;
  private controller: RuntimeController | null = null;
  private sink: ((event: Map<string, Object | null>) => void) | null = null;
  private engineBinding: FlutterPluginBinding | null = null;
  private ability: AbilityPluginBinding | null = null;
  private owner: ManagedSkillOwner | null = null;

  getUniqueClassName(): string { return 'DshRuntimePlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    if (this.engineBinding !== null) this.onDetachedFromEngine(this.engineBinding);
    this.engineBinding = binding;
    this.controller = RuntimeController.get(binding.getApplicationContext());
    this.owner = this.controller.managedSkills.attachOwner();
    this.methods = new MethodChannel(binding.getBinaryMessenger(), 'dsh/runtime');
    this.events = new EventChannel(binding.getBinaryMessenger(), 'dsh/runtime/events');
    this.methods.setMethodCallHandler(this);
    this.events.setStreamHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.engineBinding !== binding) return;
    this.onCancel(null);
    if (this.owner !== null) this.controller?.managedSkills.detachOwner(this.owner);
    this.methods?.setMethodCallHandler(null);
    binding.getBinaryMessenger().setMessageHandler('dsh/runtime/events', null);
    this.methods = null; this.events = null; this.controller = null;
    this.engineBinding = null; this.owner = null; this.ability = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void { this.ability = binding; }
  onDetachedFromAbility(): void { this.ability = null; }

  onListen(_args: Any, events: EventSink): void {
    this.onCancel(null);
    this.sink = (event: Map<string, Object | null>) => events.success(event);
    this.controller?.subscribe(this.sink);
  }

  onCancel(_args: Any): void {
    if (this.sink !== null) this.controller?.unsubscribe(this.sink);
    this.sink = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.handle(call, result).catch((error: Error) => {
      if (error instanceof RuntimeChannelError) result.error(error.code, error.message, null);
      else result.error('ohos_runtime_error', '鸿蒙本机运行时操作失败，请查看状态或重新打开 App。', null);
    });
  }

  private async handle(call: MethodCall, result: MethodResult): Promise<void> {
    if (this.controller === null) throw new RuntimeChannelError('ohos_detached', '运行时通道已解除连接。');
    const controller = this.controller;
    if (call.method === 'guestRoot') { result.success(controller.paths.guestRoot); return; }
    if (call.method === 'reopenApp') {
      const ability = this.ability?.getAbility();
      if (ability === undefined) throw new RuntimeChannelError('ohos_no_ability', '请先回到应用窗口再重新打开 App。');
      controller.stop();
      const info = ability.context.abilityInfo;
      try {
        await ability.context.restartApp({ bundleName: info.bundleName, moduleName: info.moduleName, abilityName: info.name });
      } catch (error) {
        const business = error as BusinessError;
        throw new RuntimeChannelError(String(business.code ?? 'ohos_restart_failed'), business.message);
      }
      result.success(null); return;
    }
    if (call.method === 'installManagedSkill') {
      if (this.owner === null) throw new RuntimeChannelError('ohos_detached', '运行时通道已解除连接。');
      const args = new Map<string, Object | null>();
      for (const key of ['requestId', 'expectedRoot', 'expectedToken', 'expectedGeneration', 'name', 'files']) {
        args.set(key, (call.argument(key) ?? null) as Object | null);
      }
      controller.managedSkills.install(this.owner, args, (reply: Map<string, Object | null>) => result.success(reply));
      return;
    }
    if (call.method === 'cancelManagedSkill') {
      const id: Any = call.argument('requestId');
      if (this.owner !== null && typeof id === 'string' && id.length > 0 && id.length <= 200) {
        controller.managedSkills.cancel(this.owner, id);
      }
      result.success(null); return;
    }
    await controller.initialize();
    switch (call.method) {
      case 'getStatus': controller.collect(); result.success(controller.snapshot()); return;
      case 'install': await controller.install(call.argument('dropKept') === true); result.success(null); return;
      case 'start':
        await controller.start((call.argument('env') ?? null) as Map<string, Object> | null,
          call.argument('phoneStorage') === true, (call.argument('mode') ?? null) as string | null,
          call.argument('visualReplies') !== false);
        result.success(null); return;
      case 'stop': controller.stop(); result.success(null); return;
      case 'getLogs': result.success(controller.recentLogs((call.argument('lines') ?? 500) as number)); return;
      case 'getLogSnapshot': result.success(controller.logSnapshot((call.argument('lines') ?? 300) as number)); return;
      case 'clearFailure': controller.clearFailure(); result.success(null); return;
      case 'failureLog': result.success(controller.failureLog()); return;
      case 'lastKnownGood':
        result.success(new Map<string, Object | null>([['available', false], ['at', null], ['disable', []], ['enable', []],
          ['changed', []], ['patchChanged', false], ['empty', true]])); return;
      case 'storageStatus':
        result.success(new Map<string, Object | null>([['granted', false], ['permission', false], ['legacy', false], ['guestPath', '']])); return;
      case 'networkMetered': result.success(await controller.networkMetered()); return;
      case 'publishDiagnostics':
        const markdown: Any = call.argument('markdown');
        if (typeof markdown !== 'string') result.success(null);
        else {
          try { result.success(await controller.publishDiagnostics(markdown)); }
          catch (_) { result.success(null); }
        }
        return;
      case 'reset': case 'restoreLastKnownGood': case 'safePreflight': case 'moveAside': case 'setAutoSafe':
      case 'setDirectEngine': case 'requestStorage':
      case 'openAllFilesAccess': case 'batteryExempt': case 'requestBatteryExempt': case 'backgroundSettings':
      case 'openBackgroundSettings': case 'openVendorSettings': case 'voiceModelLine':
        throw new RuntimeChannelError('ohos_unsupported', `鸿蒙本机尚不支持 ${call.method}；文件请用系统选择器，其他任务可交给已连接的电脑。`);
      default: result.notImplemented();
    }
  }
}
