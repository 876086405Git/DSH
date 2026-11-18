// 未经 HarmonyOS SDK 编译、未在真机核实；通道签名已核固定 oh-flutter e5f752d。
import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import MethodChannel, { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import EventChannel, { StreamHandler, EventSink } from '@ohos/flutter_ohos/src/main/ets/plugin/common/EventChannel';
import Any from '@ohos/flutter_ohos/src/main/ets/plugin/common/Any';
import { AbilityAware, AbilityPluginBinding } from '@ohos/flutter_ohos';
import { BusinessError } from '@ohos.base';
import hilog from '@ohos.hilog';
import { RuntimeChannelError } from './RuntimeCore';
import { RuntimeController } from './RuntimeController';
import { LinuxRunRequest } from './LinuxControl';
import type { LinuxProxyConfiguration } from './LinuxControl';
import { ManagedSkillOwner } from './ManagedSkillService';
import { PhoneBridge } from '../phone/PhoneBridge';
import type { HostPhoneKey } from 'libdsh_host.so';


const POLLED: string[] = ['getStatus', 'getLogs', 'getLogSnapshot', 'failureLog', 'guestRoot', 'getLinuxStatus', 'getIdleDiagnostics'];
export class RuntimePlugin implements FlutterPlugin, MethodCallHandler, StreamHandler, AbilityAware {
  private methods: MethodChannel | null = null;
  private events: EventChannel | null = null;
  private controller: RuntimeController | null = null;
  private sink: ((event: Map<string, Object | null>) => void) | null = null;
  private engineBinding: FlutterPluginBinding | null = null;
  private ability: AbilityPluginBinding | null = null;
  private owner: ManagedSkillOwner | null = null;
  private phone: PhoneBridge | null = null;

  getUniqueClassName(): string { return 'DshRuntimePlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    if (this.engineBinding !== null) this.onDetachedFromEngine(this.engineBinding);
    this.engineBinding = binding;
    this.controller = RuntimeController.get(binding.getApplicationContext());
    this.owner = this.controller.managedSkills.attachOwner();
    this.phone = new PhoneBridge(() => this.controller?.phoneContext(this.ability?.getAbility()) ?? null);
    this.methods = new MethodChannel(binding.getBinaryMessenger(), 'dsh/runtime');
    this.events = new EventChannel(binding.getBinaryMessenger(), 'dsh/runtime/events');
    this.methods.setMethodCallHandler(this);
    this.events.setStreamHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.engineBinding !== binding) return;
    this.onCancel(null);
    try { this.phone?.retire(); } catch (_) {
      // Detach must still remove the only local consume/finish channel. No raw
      // owner is retained locally and the native record remains fail-closed at
      // lifecycle retirement/deadline; do not report OS cancellation success.
    }
    this.phone = null;
    if (this.owner !== null) this.controller?.managedSkills.detachOwner(this.owner);
    this.methods?.setMethodCallHandler(null);
    binding.getBinaryMessenger().setMessageHandler('dsh/runtime/events', null);
    this.methods = null; this.events = null; this.controller = null;
    this.engineBinding = null; this.owner = null; this.ability = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    if (this.ability !== null && this.ability !== binding) this.onDetachedFromAbility();
    this.ability = binding;
  }
  onDetachedFromAbility(): void {
    try { this.phone?.retire(); }
    catch (_) { console.error('[dsh/runtime] Phone owner retirement failed; local Ability detached.'); }
    finally { this.ability = null; }
  }

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
    // Method names and error codes only: arguments can carry keys and paths.
    const traced = !POLLED.includes(call.method);
    const began = Date.now();
    if (traced) hilog.info(0x3F00, 'DshRuntime', '%{public}s begin', call.method);
    this.handle(call, result).then((): void => {
      if (traced) hilog.info(0x3F00, 'DshRuntime', '%{public}s done in %{public}d ms', call.method, Date.now() - began);
    }).catch((error: Error) => {
      hilog.warn(0x3F00, 'DshRuntime', '%{public}s failed with %{public}s after %{public}d ms', call.method,
        error instanceof RuntimeChannelError ? error.code : 'ohos_runtime_error', Date.now() - began);
      if (error instanceof RuntimeChannelError) result.error(error.code, error.message, null);
      else result.error('ohos_runtime_error', '鸿蒙本机运行时操作失败，请查看状态或重新打开 App。', null);
    });
  }

  private async handle(call: MethodCall, result: MethodResult): Promise<void> {
    if (this.controller === null) throw new RuntimeChannelError('ohos_detached', '运行时通道已解除连接。');
    const controller = this.controller;
    if (call.method === 'getIdleDiagnostics') { result.success(controller.getIdleDiagnostics()); return; }
    if (call.method === 'setIdleDiagnosticsEnabled') {
      const enabled: Any = call.argument('enabled');
      if (typeof enabled !== 'boolean') throw new RuntimeChannelError('ohos_idle_diagnostics_arguments', '空闲诊断开关必须是布尔值。');
      result.success(controller.setIdleDiagnosticsEnabled(enabled)); return;
    }
    if (call.method === 'guestRoot') { result.success(controller.paths.guestRoot); return; }
    if (call.method === 'reopenApp') {
      const ability = this.ability?.getAbility();
      if (ability === undefined) throw new RuntimeChannelError('ohos_no_ability', '请先回到应用窗口再重新打开 App。');
      try { this.phone?.retire(); } finally { await controller.stop(); }
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
    if (call.method === 'phoneAttach') {
      if (this.phone === null) throw new RuntimeChannelError('ohos_detached', '手机工具通道已解除连接。');
      result.success(await this.phone.attach(call.argument('enabled') === true)); return;
    }
    if (call.method === 'phoneRetire') {
      const engine: Any = call.argument('engineId'); const generation: Any = call.argument('bridgeGeneration');
      if (typeof engine === 'string' && typeof generation === 'number' && Number.isSafeInteger(generation)) {
        this.phone?.retireScope(engine, generation);
      }
      result.success(null); return;
    }
    if (call.method === 'phoneExecute' || call.method === 'phoneHandoffContinue' || call.method === 'phoneCancel' || call.method === 'phoneCheck') {
      if (this.phone === null) throw new RuntimeChannelError('ohos_detached', '手机工具通道已解除连接。');
      const engine: Any = call.argument('engineId'); const generation: Any = call.argument('bridgeGeneration');
      const id: Any = call.argument('requestId'); const nonce: Any = call.argument('executionNonce');
      if (typeof engine !== 'string' || typeof generation !== 'number' || !Number.isSafeInteger(generation) ||
        generation <= 0 || engine.length === 0 || engine.length > 128 || typeof id !== 'string' || typeof nonce !== 'string' ||
        id.length === 0 || id.length > 64 || nonce.length === 0 || nonce.length > 64) {
        throw new RuntimeChannelError('ohos_phone_request', '手机操作身份格式无效。');
      }
      const key: HostPhoneKey = { engineId: engine, bridgeGeneration: generation, requestId: id, executionNonce: nonce };
      if (call.method === 'phoneExecute') result.success(await this.phone.execute(key));
      else if (call.method === 'phoneCancel') result.success(this.phone.cancel(key));
      else if (call.method === 'phoneCheck') result.success(this.phone.check(key));
      else result.success(this.phone.handoffContinue(key));
      return;
    }
    if (call.method === 'reset') {
      const keep: Any = call.argument('keep') ?? [];
      const reinstall: Any = call.argument('reinstall') ?? false;
      if (!Array.isArray(keep) || typeof reinstall !== 'boolean') throw new RuntimeChannelError('ohos_reset_arguments', '重置参数无效。');
      try { this.phone?.retire(); } finally { await controller.reset(keep as string[], reinstall); }
      return;
    }
    // Preview must not trigger pending recovery writes through initialization.
    if (call.method === 'lastKnownGood') { result.success(await controller.lastKnownGood()); return; }
    if (call.method === 'reminderAccess') { result.success(controller.reminderAccess()); return; }
    // Linux status is read-only and never enters installer/recovery initialization.
    if (call.method === 'getLinuxStatus') { result.success(await controller.getLinuxStatus()); return; }
    if (call.method === 'setLinuxEnabled') {
      const enabled: Any = call.argument('enabled');
      if (typeof enabled !== 'boolean') throw new RuntimeChannelError('ohos_linux_arguments', 'Linux 开关必须是布尔值。');
      result.success(await controller.setLinuxEnabled(enabled)); return;
    }
    if (call.method === 'setLinuxProxy') {
      const raw: Any = call.argument('proxy');
      if (!(raw instanceof Map)) throw new RuntimeChannelError('ohos_linux_arguments', 'Linux 代理参数无效。');
      const values = raw as Map<string, Object>;
      values.forEach((value: Object, key: string): void => {
        if (!['mode', 'httpProxy', 'httpsProxy', 'noProxy'].includes(key) || typeof value !== 'string') {
          throw new RuntimeChannelError('ohos_linux_arguments', 'Linux 代理参数无效。');
        }
      });
      const mode = values.get('mode');
      if (typeof mode !== 'string' || !['inherit', 'direct', 'manual'].includes(mode)) {
        throw new RuntimeChannelError('ohos_linux_arguments', 'Linux 代理模式无效。');
      }
      const proxy: LinuxProxyConfiguration = { mode: mode };
      if (values.has('httpProxy')) proxy.httpProxy = values.get('httpProxy') as string;
      if (values.has('httpsProxy')) proxy.httpsProxy = values.get('httpsProxy') as string;
      if (values.has('noProxy')) proxy.noProxy = values.get('noProxy') as string;
      result.success(await controller.setLinuxProxy(proxy)); return;
    }
    // User-confirmed in the app; deletes only the retained Linux instance.
    if (call.method === 'discardLinuxRetained') { result.success(await controller.discardLinuxRetained()); return; }
    if (call.method === 'runLinuxPrivateGuest') {
      const instance: Any = call.argument('instanceId'); const attempt: Any = call.argument('attemptId');
      const id: Any = call.argument('requestId'); const argv: Any = call.argument('argv');
      const cwd: Any = call.argument('cwd'); const input: Any = call.argument('stdin') ?? '';
      const env: Any = call.argument('env') ?? new Map<string, Object>();
      if (typeof instance !== 'string' || typeof attempt !== 'string' || typeof id !== 'number' ||
          !Number.isSafeInteger(id) || id < 1 || !Array.isArray(argv) || typeof cwd !== 'string' ||
          typeof input !== 'string' || !(env instanceof Map)) {
        throw new RuntimeChannelError('ohos_linux_arguments', 'Linux 作业参数或请求身份无效。');
      }
      const environmentFields: string[] = [];
      (env as Map<string, Object>).forEach((value: Object, key: string): void => {
        if (typeof key !== 'string' || typeof value !== 'string') throw new RuntimeChannelError('ohos_linux_arguments', 'Linux 环境值必须是字符串。');
        environmentFields.push(JSON.stringify(key) + ':' + JSON.stringify(value));
      });
      // JSON parsing creates own data properties, including a legal __proto__
      // environment name; assigning that name to {} would silently discard it.
      const environment = JSON.parse('{' + environmentFields.join(',') + '}') as Record<string, string>;
      const request: LinuxRunRequest = { v: 1, instanceId: instance, attemptId: attempt,
        action: 'runPrivateGuest', requestId: id, argv: argv as string[], cwd: cwd, env: environment, stdin: input };
      result.success(await controller.runLinuxPrivateGuest(request)); return;
    }
    await controller.initialize().catch((error: Error): void => {
      // Recovery failures must remain inspectable while mutating calls stay closed.
      if (!['getStatus', 'getLogs', 'getLogSnapshot', 'failureLog'].includes(call.method)) throw error;
    });
    switch (call.method) {
      case 'getStatus': controller.collect(); result.success(controller.snapshot()); return;
      case 'install': await controller.install(call.argument('dropKept') === true); result.success(null); return;
      case 'start':
        await controller.start((call.argument('env') ?? null) as Map<string, Object> | null,
          call.argument('phoneStorage') === true, (call.argument('mode') ?? null) as string | null,
          call.argument('visualReplies') !== false);
        result.success(null); return;
      case 'stop':
        try { this.phone?.retire(); } finally { await controller.stop(); }
        result.success(null); return;
      case 'getLogs': result.success(controller.recentLogs((call.argument('lines') ?? 500) as number)); return;
      case 'getLogSnapshot': result.success(controller.logSnapshot((call.argument('lines') ?? 300) as number)); return;
      case 'clearFailure': await controller.clearFailure(); result.success(null); return;
      case 'setWorkspaceRecovery':
        await controller.setWorkspaceRecovery(call.argument('enabled') === true); result.success(null); return;
      case 'failureLog': result.success(controller.failureLog()); return;

      case 'restoreLastKnownGood': result.success(await controller.restoreLastKnownGood()); return;
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
      case 'safePreflight': case 'moveAside': case 'setAutoSafe':
      case 'setDirectEngine': case 'requestStorage':
      case 'openAllFilesAccess': case 'batteryExempt': case 'requestBatteryExempt': case 'backgroundSettings':
      case 'openBackgroundSettings': case 'openVendorSettings': case 'voiceModelLine':
        throw new RuntimeChannelError('ohos_unsupported', `鸿蒙本机尚不支持 ${call.method}；文件请用系统选择器，其他任务可交给已连接的电脑。`);
      default: result.notImplemented();
    }
  }
}
