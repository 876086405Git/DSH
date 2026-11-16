import common from '@ohos.app.ability.common';
import cryptoFramework from '@ohos.security.cryptoFramework';
import util from '@ohos.util';
import type { HostPhoneKey } from 'libdsh_host.so';
import { NativeHostModule, loadNativeHost } from '../runtime/NativeHost';
import { RuntimeChannelError } from '../runtime/RuntimeCore';
import { PhoneEffects, PhoneEffectDenied, PhoneEffectResult } from './PhoneEffects';

interface PhonePendingData { pending: boolean; foreground: boolean; nowMs: number; deadlineMs: number; }
interface PhoneRequestData {
  engineId: string; bridgeGeneration: number; requestId: string; tool: string;
  args: Record<string, Object>;
}
function hex(bytes: Uint8Array): string {
  return Array.from(bytes).map((value: number): string => value.toString(16).padStart(2, '0')).join('');
}
function resultMap(result: PhoneEffectResult): Map<string, Object | null> {
  return new Map<string, Object | null>([['status', result.status], ['effect', result.effect],
    ['evidence', result.evidence], ['dispatched', result.dispatched], ['code', result.code], ['message', result.message]]);
}
function resultJson(result: PhoneEffectResult): string {
  // Shared native complete encoding; caller object insertion order is irrelevant.
  const ordered: PhoneEffectResult = { status: result.status, effect: result.effect, evidence: result.evidence,
    dispatched: result.dispatched, code: result.code, message: result.message };
  return JSON.stringify(ordered);
}
function failure(dispatched: boolean, code: string, message: string): PhoneEffectResult {
  return { status: dispatched ? 'unknown' : 'failed', effect: 'none', evidence: 'unknown', dispatched, code, message };
}

// One local Flutter owner. This class never emits the capability on status/log/event channels.
export class PhoneBridge {
  private readonly context: () => common.UIAbilityContext | null;
  private host: NativeHostModule | null = null;
  private owner: string = '';
  private engineId: string = '';
  private generation: number = 0;
  private abilityGeneration: number = 0;
  private sequence: number = 0;
  private pending: Promise<Map<string, Object | null>> | null = null;
  private active: string | null = null;

  constructor(context: () => common.UIAbilityContext | null) { this.context = context; }

  retire(): void {
    ++this.sequence; this.pending = null; this.owner = '';
    const generation = this.generation; this.generation = 0; this.engineId = ''; this.abilityGeneration = 0;
    if (generation > 0) this.host?.phoneRetire(generation);
    // Do not clear active: a consumed system Promise must finish before it frees its native slot.
  }

  retireScope(engineId: string, generation: number): void {
    if (engineId === this.engineId && generation === this.generation && generation > 0) this.retire();
  }

  attach(enabled: boolean): Promise<Map<string, Object | null>> {
    if (!enabled) {
      return Promise.reject(new RuntimeChannelError('ohos_phone_disabled', '手机工具尚未启用。'));
    }
    if (this.pending !== null) return this.pending;
    const sequence = this.sequence;
    const pending = this.bootstrap(sequence);
    this.pending = pending;
    pending.then((): void => { if (this.pending === pending) this.pending = null; },
      (): void => { if (this.pending === pending) this.pending = null; });
    return pending;
  }

  private async bootstrap(sequence: number): Promise<Map<string, Object | null>> {
    const host = await loadNativeHost();
    this.host = host;
    const life = host.lifecycleSnapshot();
    if (sequence !== this.sequence || this.context() === null || life.available !== 1 || life.foreground !== 1) {
      throw new RuntimeChannelError('ohos_phone_foreground', '请回到 DSH 前台启用手机工具。');
    }
    const current = host.phoneSnapshot();
    if (this.owner !== '' && current.available && current.bridgeGeneration === this.generation &&
      life.ownerGeneration === this.abilityGeneration && current.engineId === this.engineId) return this.bootstrapMap();
    const owner = hex((await cryptoFramework.createRandom().generateRandom(32)).data);
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new util.TextEncoder().encodeInto(owner) });
    const hash = hex((await md.digest()).data);
    const latest = host.lifecycleSnapshot();
    if (sequence !== this.sequence || this.context() === null || latest.engineGeneration !== life.engineGeneration ||
      latest.ownerGeneration !== life.ownerGeneration || latest.available !== 1 || latest.foreground !== 1) {
      throw new RuntimeChannelError('ohos_phone_retired', '手机工具连接已变化，请重新启用。');
    }
    const generation = host.phoneAttach(hash, life.engineGeneration, life.ownerGeneration);
    if (generation <= 0) throw new RuntimeChannelError('ohos_phone_not_ready', '本机引擎尚未准备好手机工具连接。');
    this.owner = owner; this.generation = generation; this.abilityGeneration = life.ownerGeneration;
    this.engineId = host.phoneSnapshot().engineId;
    return this.bootstrapMap();
  }

  private bootstrapMap(): Map<string, Object | null> {
    const baseUrl = this.host?.getState().baseUrl;
    if (typeof baseUrl !== 'string' || !/^http:\/\/127\.0\.0\.1:[0-9]{1,5}$/.test(baseUrl)) {
      this.retire(); throw new RuntimeChannelError('ohos_phone_endpoint', '本机手机工具连接不可用。');
    }
    return new Map<string, Object | null>([['v', 1], ['engineId', this.engineId],
      ['bridgeGeneration', this.generation], ['baseUrl', baseUrl], ['owner', this.owner]]);
  }

  cancel(key: HostPhoneKey): Map<string, Object | null> {
    this.checkScope(key);
    const dispatched = this.host?.phoneOperation('revoke', key);
    return new Map<string, Object | null>([['dispatched', typeof dispatched === 'boolean' ? dispatched : null]]);
  }

  check(key: HostPhoneKey): Map<string, Object | null> {
    this.checkScope(key);
    const raw = this.host?.phoneOperation('check', key);
    if (typeof raw !== 'string') throw new RuntimeChannelError('ohos_phone_unknown', '手机等待状态不可用。');
    const value = JSON.parse(raw) as PhonePendingData;
    return new Map<string, Object | null>([['pending', value.pending], ['foreground', value.foreground],
      ['nowMs', value.nowMs], ['deadlineMs', value.deadlineMs]]);
  }

  private checkScope(key: HostPhoneKey): void {
    if (this.host === null || this.owner === '' || key.engineId !== this.engineId || key.bridgeGeneration !== this.generation) {
      throw new RuntimeChannelError('ohos_phone_retired', '手机操作已失效，请勿重试旧请求。');
    }
  }

  private inspect(key: HostPhoneKey): PhoneRequestData {
    if (this.host === null || this.owner === '' || this.context() === null ||
      key.engineId !== this.engineId || key.bridgeGeneration !== this.generation) {
      throw new RuntimeChannelError('ohos_phone_retired', '手机操作已失效，请勿重试旧请求。');
    }
    const raw = this.host.phoneOperation('inspect', key);
    if (typeof raw !== 'string') throw new RuntimeChannelError('ohos_phone_stale', '手机操作已取消、超时或派发。');
    const request = JSON.parse(raw) as PhoneRequestData;
    if (request.engineId !== key.engineId || request.bridgeGeneration !== key.bridgeGeneration ||
      request.requestId !== key.requestId || typeof request.tool !== 'string' ||
      typeof request.args !== 'object' || request.args === null || Array.isArray(request.args)) {
      throw new RuntimeChannelError('ohos_phone_request', '原生手机请求格式无效。');
    }
    return request;
  }

  async execute(key: HostPhoneKey): Promise<Map<string, Object | null>> {
    const request = this.inspect(key);
    if (request.tool === 'mcp__phone__handoff') {
      throw new RuntimeChannelError('ohos_phone_handoff', '交还操作需要当前窗口的用户继续确认。');
    }
    if (this.active !== null) throw new RuntimeChannelError('ohos_phone_busy', '上一次手机系统操作尚未退出。');
    const context = this.context();
    if (context === null) throw new RuntimeChannelError('ohos_phone_foreground', '请回到 DSH 前台。');
    const host = this.host as NativeHostModule;
    this.active = key.requestId;
    const sequence = this.sequence;
    let result: PhoneEffectResult;
    try {
      const args = new Map<string, Object>();
      for (const name of Object.keys(request.args)) args.set(name, request.args[name]);
      result = await new PhoneEffects(context).execute(request.tool, args, (): void => {
        if (sequence !== this.sequence || this.context() !== context || host.phoneOperation('consume', key) !== true) {
          throw new PhoneEffectDenied('cancelled_before_dispatch', '手机操作已取消、超时或不在前台，没有派发。');
        }
      });
    } catch (_) {
      const consumed = host.phoneOperation('consumed', key);
      result = failure(consumed !== false, 'native_effect_failed', '手机系统操作未返回可靠结果，不会自动重试。');
    } finally {
      // Native finish below, not this JS flag, releases the single effect slot.
      this.active = null;
    }
    return this.finish(host, key, result);
  }

  handoffContinue(key: HostPhoneKey): Map<string, Object | null> {
    const request = this.inspect(key);
    if (request.tool !== 'mcp__phone__handoff') throw new RuntimeChannelError('ohos_phone_request', '此请求不是交还操作。');
    const host = this.host as NativeHostModule;
    if (host.phoneOperation('consume', key) !== true) throw new RuntimeChannelError('ohos_phone_stale', '交还提示已失效。');
    return this.finish(host, key, { status: 'succeeded', effect: 'none', evidence: 'user_confirmed',
      dispatched: true, code: 'user_confirmed', message: '用户已回到 DSH 并确认继续。' });
  }

  private finish(host: NativeHostModule, key: HostPhoneKey, supplied: PhoneEffectResult): Map<string, Object | null> {
    const consumed = host.phoneOperation('consumed', key);
    let result = supplied;
    if (consumed === null) throw new RuntimeChannelError('ohos_phone_unknown', '手机动作状态未知，不会自动重试。');
    if (supplied.dispatched !== consumed) result = failure(consumed === true, 'native_evidence_mismatch', '手机动作结果与原生派发记录不一致。');
    if (host.phoneOperation('finish', key, resultJson(result)) !== true) {
      throw new RuntimeChannelError('ohos_phone_stale', '手机动作回执已失效，不会自动重试。');
    }
    return resultMap(result);
  }
}
