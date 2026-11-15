// UNCOMPILED_HMS / 未在真机核实。EntryAbility 显式传递首次与后续 Want，普通启动不读取分享数据。
import type { systemShare } from '@kit.ShareKit';
import { ShareKit, loadShareKit } from './HmsKits';
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import fs from '@ohos.file.fs';
import { Any, FlutterPluginBinding, MethodChannel } from '@ohos/flutter_ohos';
import { HmsShareStorage, ShareBatch } from './HmsShareStorage';
import {
  ShareError, SHARE_MAX_ITEMS, SHARE_MAX_FILE, SHARE_MAX_TOTAL, SHARE_MAX_TEXT,
  SHARE_MAX_RECORDS, boundedShareText, externalShareUri, incomingShareName, incomingMime
} from './HmsSharePolicy';

class ShareArrival {
  event?: Map<string, Any>;
  batch?: ShareBatch;
  storage: HmsShareStorage;
  constructor(storage: HmsShareStorage) { this.storage = storage; }
}

class ShareInput {
  uri: string;
  name: string;
  mime: string | null;
  file?: fs.File;
  constructor(uri: string, name: string, mime: string | null) { this.uri = uri; this.name = name; this.mime = mime; }
}

function skipped(name: string | null, reason: string): Map<string, Any> {
  return new Map<string, Any>([['name', name], ['reason', reason]]);
}

function problem(reason: string): Map<string, Any> {
  return new Map<string, Any>([['text', null], ['subject', null], ['files', []], ['skipped', [skipped(null, reason)]]]);
}

export class HmsShareInbox {
  private static pending: ShareArrival[] = [];
  private static reading: number = 0;
  private static overflow: boolean = false;
  private static owner?: FlutterPluginBinding;
  private static channel?: MethodChannel;
  private static isReady: boolean = false;

  static attach(owner: FlutterPluginBinding, channel: MethodChannel): void {
    HmsShareInbox.owner = owner; HmsShareInbox.channel = channel; HmsShareInbox.isReady = false;
  }

  static detach(owner: FlutterPluginBinding): void {
    if (HmsShareInbox.owner !== owner) return;
    HmsShareInbox.owner = undefined; HmsShareInbox.channel = undefined; HmsShareInbox.isReady = false;
  }

  static ready(owner: FlutterPluginBinding, reply: (ready: boolean) => void): void {
    if (HmsShareInbox.owner !== owner) { reply(false); return; }
    HmsShareInbox.isReady = true; reply(true); HmsShareInbox.flush();
  }

  static receive(context: common.UIAbilityContext, want: Want, launch: AbilityConstant.LaunchParam): boolean {
    if (launch.launchReasonMessage !== 'ReasonMessage_SystemShare') return false;
    const storage = new HmsShareStorage(context);
    if (HmsShareInbox.pending.length >= 8) { HmsShareInbox.overflow = true; return true; }
    const arrival = new ShareArrival(storage);
    HmsShareInbox.pending.push(arrival);
    if (HmsShareInbox.reading >= 4) {
      arrival.event = problem('too_many'); HmsShareInbox.flush(); return true;
    }
    if (!canIUse('SystemCapability.Collaboration.SystemShare')) {
      arrival.event = problem('unreadable'); HmsShareInbox.flush(); return true;
    }
    HmsShareInbox.reading++;
    // 先保留到达顺序和在途额度；首次加载只影响真实分享，不等待 Dart ready。
    try {
      loadShareKit().then((kit: ShareKit): Promise<systemShare.SharedData> => kit.getSharedData(want)).then((data: systemShare.SharedData) => {
        return HmsShareInbox.read(arrival, data.getRecords(), context.abilityInfo.bundleName);
      }).catch(() => {
        arrival.event = problem('unreadable');
      }).finally(() => {
        HmsShareInbox.reading--; HmsShareInbox.flush();
      });
    } catch (_error) {
      HmsShareInbox.reading--; arrival.event = problem('unreadable'); HmsShareInbox.flush();
    }
    return true;
  }

  private static async read(arrival: ShareArrival, records: systemShare.SharedRecord[], own: string): Promise<void> {
    if (!Array.isArray(records) || records.length > SHARE_MAX_RECORDS) {
      arrival.event = problem('too_many'); return;
    }
    let text = ''; let subject: string | null = null;
    const inputs: ShareInput[] = [];
    const failures: Map<string, Any>[] = [];
    for (const record of records) {
      if (!record) { failures.push(skipped(null, 'unreadable')); continue; }
      if (!subject && typeof record.title === 'string') subject = boundedShareText(record.title, 4096).trim() || null;
      if (typeof record.content === 'string' && text.length < SHARE_MAX_TEXT) {
        const part = boundedShareText(record.content, SHARE_MAX_TEXT - text.length - (text ? 2 : 0)).trim();
        if (part) text += (text ? '\n\n' : '') + part;
      }
      if (typeof record.uri !== 'string' || !record.uri) continue;
      const name = incomingShareName(record.uri, typeof record.title === 'string' ? record.title : undefined);
      if (inputs.length >= SHARE_MAX_ITEMS) { failures.push(skipped(name, 'too_many')); continue; }
      const input = new ShareInput(record.uri, name, typeof record.utd === 'string' ? incomingMime(record.utd) : null);
      inputs.push(input);
    }
    // 同一批的全部合格 URI 先请求 FD；不让后面的临时授权等到前一个文件复制结束。
    await Promise.all(inputs.map(async (input: ShareInput): Promise<void> => {
      if (!externalShareUri(input.uri, own)) return;
      try { input.file = await fs.open(input.uri, fs.OpenMode.READ_ONLY | fs.OpenMode.NONBLOCK); }
      catch (_error) { /* 每个项目单独报告 unreadable。 */ }
    }));
    const files: Map<string, Any>[] = [];
    let batch: ShareBatch | undefined;
    try {
      if (inputs.some((input: ShareInput) => input.file !== undefined)) batch = await arrival.storage.create(false);
      let total = 0;
      for (const input of inputs) {
        if (!input.file || !batch) { failures.push(skipped(input.name, 'unreadable')); continue; }
        try {
          const size = await arrival.storage.copy(input.file.fd, batch, input.name,
            Math.min(SHARE_MAX_FILE, SHARE_MAX_TOTAL - total), (): void => {});
          total += size;
          files.push(new Map<string, Any>([['path', batch.paths[batch.paths.length - 1]], ['name', input.name],
            ['mime', input.mime], ['size', size]]));
        } catch (error) {
          failures.push(skipped(input.name, error instanceof ShareError && error.code === 'too_large' ? 'too_large' : 'unreadable'));
        }
      }
      if (batch && files.length === 0) { await arrival.storage.discard(batch); batch = undefined; }
      arrival.batch = batch;
      arrival.event = new Map<string, Any>([['text', text || null], ['subject', subject], ['files', files], ['skipped', failures]]);
    } catch (error) {
      if (batch) await arrival.storage.discard(batch);
      throw error as Error;
    } finally {
      for (const input of inputs) {
        if (input.file) { try { await fs.close(input.file); } catch (_error) { /* OS teardown may close it. */ } }
      }
    }
  }

  private static flush(): void {
    if (!HmsShareInbox.isReady || !HmsShareInbox.channel) return;
    while (HmsShareInbox.pending.length > 0 && HmsShareInbox.pending[0].event) {
      const arrival = HmsShareInbox.pending[0];
      try { HmsShareInbox.channel.invokeMethod('share', arrival.event!); }
      catch (_error) { HmsShareInbox.isReady = false; return; }
      HmsShareInbox.pending.shift();
      if (arrival.batch) arrival.storage.release(arrival.batch);
    }
    if (HmsShareInbox.overflow && HmsShareInbox.pending.length === 0) {
      try { HmsShareInbox.channel.invokeMethod('share', problem('too_many')); HmsShareInbox.overflow = false; }
      catch (_error) { HmsShareInbox.isReady = false; }
    }
  }
}
