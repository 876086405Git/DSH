// Public OH facts and bounded persisted redacted logs. No host import or user-content scan.
import common from '@ohos.app.ability.common';
import bundleManager from '@ohos.bundle.bundleManager';
import display from '@ohos.display';
import statvfs from '@ohos.file.statvfs';
import {
  AbilityAware, AbilityPluginBinding, Any, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { ohosDeviceIdentity, systemMemoryBytes } from './OhosDeviceFacts';
import { PersistedRuntimeLog } from '../runtime/PersistedRuntimeLog';
import { RuntimeFile, RuntimeManifest } from '../runtime/RuntimeCore';
import { OhosRuntimeStorage } from '../runtime/OhosRuntimeStorage';
import { DiagnosticEvidenceError, EvidenceFields, OhosDiagnosticEvidence } from './OhosDiagnosticEvidence';
import { OhosFaultEvents } from './OhosFaultEvents';
import { OhosKeyboardLog } from './OhosKeyboardLog';

export default class DiagnosticsPlugin implements FlutterPlugin, AbilityAware {
  private binding: FlutterPluginBinding | null = null;
  private ability: AbilityPluginBinding | null = null;
  private methods: MethodChannel | null = null;
  private request: number = 0;
  private busy: boolean = false;
  private evidence: OhosDiagnosticEvidence | null = null;
  private faults: OhosFaultEvents | null = null;
  private keyboard: OhosKeyboardLog;

  constructor(keyboard: OhosKeyboardLog = new OhosKeyboardLog()) {
    this.keyboard = keyboard;
  }

  getUniqueClassName(): string { return 'DshDiagnosticsPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    if (this.binding !== null) this.onDetachedFromEngine(this.binding);
    this.binding = binding; this.ability = null;
    try {
      this.evidence = OhosDiagnosticEvidence.get(binding.getApplicationContext().filesDir);
      this.faults = new OhosFaultEvents(this.evidence); this.faults.start();
    } catch (_) { this.evidence = null; this.faults = null; }
    this.methods = new MethodChannel(binding.getBinaryMessenger(), 'dsh/diagnostics');
    this.methods.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (this.binding !== binding) { this.error(result, 'detached'); return; }
      if (call.method === 'recordAppError' || call.method === 'recordVoiceStage') {
        this.record(binding, call, result); return;
      }
      if (call.method === 'collectSystemIme') {
        try { result.success(this.keyboard.snapshot(this.ability !== null)); } catch (_) {}
        return;
      }
      if (call.method === 'cancelSystemIme') {
        try { result.success(null); } catch (_) {}
        return;
      }
      if (!['info', 'engineLog'].includes(call.method)) { try { result.notImplemented(); } catch (_) {} return; }
      if (this.busy) { this.error(result, 'busy'); return; }
      this.busy = true; const request = ++this.request;
      let work: Promise<Any>;
      try {
        const context = binding.getApplicationContext();
        const logs = PersistedRuntimeLog.get(context.filesDir);
        const max: Any = call.argument('maxBytes');
        const limit = typeof max === 'number' && Number.isFinite(max) ? max : 512 * 1024;
        work = call.method === 'info' ? this.info(context, logs) : logs.tail(limit);
      } catch (_) { this.busy = false; this.error(result, 'failed'); return; }
      work.then((value: Any): void => {
        if (this.binding !== binding || this.request !== request) { this.error(result, 'detached'); return; }
        this.busy = false;
        try { result.success(value); } catch (_) {}
      }, (): void => {
        const active = this.binding === binding && this.request === request;
        if (active) this.busy = false;
        this.error(result, active ? 'failed' : 'detached');
      });
    } });
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.binding !== binding) return;
    this.request++; this.busy = false; this.binding = null; this.ability = null;
    this.faults?.stop(); this.faults = null; this.evidence = null;
    this.methods?.setMethodCallHandler(null); this.methods = null;
  }
  onAttachedToAbility(binding: AbilityPluginBinding): void { this.ability = binding; }
  onDetachedFromAbility(): void { this.ability = null; }
  private error(result: MethodResult, code: string): void {
    try { result.error(code, code === 'busy' ? '诊断读取尚未完成。' : '无法完成设备诊断读取。', null); } catch (_) {}
  }

  private record(binding: FlutterPluginBinding, call: MethodCall, result: MethodResult): void {
    const evidence: OhosDiagnosticEvidence | null = this.evidence;
    if (evidence === null) { this.error(result, 'evidence_unavailable'); return; }
    const fields: EvidenceFields = call.method === 'recordAppError' ? {
      source: call.argument('source'), errorType: call.argument('errorType'), stack: call.argument('stack')
    } : { stage: call.argument('stage'), backend: call.argument('backend'), code: call.argument('code') };
    const kind: string = call.method === 'recordAppError' ? 'appErrors' : 'voiceStages';
    evidence.record(kind, fields).then((): void => {
      if (this.binding !== binding) { this.error(result, 'detached'); return; }
      try { result.success(null); } catch (_) {}
    }, (error: Error): void => {
      this.error(result, this.binding !== binding ? 'detached' :
        error instanceof DiagnosticEvidenceError ? error.code : 'evidence_unavailable');
    });
  }

  private async info(context: common.Context, logs: PersistedRuntimeLog): Promise<Map<string, Any>> {
    const evidence: OhosDiagnosticEvidence | null = this.evidence;
    const faults: OhosFaultEvents | null = this.faults;
    const device: Map<string, Any> = ohosDeviceIdentity();
    const memory = systemMemoryBytes(); if (memory !== null) device.set('memoryMb', memory / (1024 * 1024));
    try {
      const d = display.getDefaultDisplaySync();
      const screen: Map<string, Any> = new Map<string, Any>();
      screen.set('widthPx', d.width); screen.set('heightPx', d.height);
      screen.set('density', d.densityPixels); screen.set('densityDpi', d.densityDPI);
      const fontScale = this.ability?.getAbility().context.config.fontSizeScale;
      if (fontScale !== undefined) screen.set('fontScale', fontScale);
      device.set('display', screen);
    } catch (_) {}
    const app: Map<string, Any> = new Map<string, Any>();
    const manifest: Map<string, Any> = new Map<string, Any>();
    await Promise.all([
      bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).then((info: bundleManager.BundleInfo): void => {
        app.set('versionName', info.versionName); app.set('versionCode', info.versionCode);
      }).catch((): void => {}),
      statvfs.getFreeSize(context.filesDir).then((bytes: number): void => {
        if (Number.isSafeInteger(bytes) && bytes >= 0) device.set('freeStorageMb', bytes / (1024 * 1024));
      }).catch((): void => {}),
      this.manifest(context, manifest)
    ]);
    app.set('engineLog', logs.facts());
    const value: Map<string, Any> = new Map<string, Any>();
    value.set('app', app); value.set('device', device); value.set('manifest', manifest);
    value.set('voice', new Map<string, Any>());
    if (evidence !== null) {
      await faults?.drain();
      value.set('evidence', await evidence.snapshot(faults?.availability() ?? 'unavailable'));
    }
    return value;
  }
  private async manifest(context: common.Context, target: Map<string, Any>): Promise<void> {
    try {
      const storage = new OhosRuntimeStorage(context.resourceManager, context.filesDir);
      const value: RuntimeManifest = await storage.readBundledManifest();
      if ([value.runtimeVersion, value.dshVersion, value.nodeVersion].some((s: string): boolean => s.length > 128)) return;
      let size = 0; value.files.forEach((file: RuntimeFile): void => { size += file.size; });
      if (!Number.isSafeInteger(size)) return;
      target.set('runtimeVersion', value.runtimeVersion); target.set('dshVersion', value.dshVersion);
      target.set('nodeVersion', value.nodeVersion); target.set('files', value.files.length); target.set('uncompressedBytes', size);
    } catch (_) { /* Malformed/missing bundled facts do not abort a diagnostic export. */ }
  }
}
