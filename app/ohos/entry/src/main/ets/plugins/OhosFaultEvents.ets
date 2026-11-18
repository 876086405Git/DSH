// Public HiAppEvent contract; SDK/HBN-AL00 behavior remains a device validation item.
import hiAppEvent from '@ohos.hiviewdfx.hiAppEvent';
import { Any } from '@ohos/flutter_ohos';
import { DiagnosticEvidenceError, DiagnosticEvidenceRow, diagnosticEvidenceRow, OhosDiagnosticEvidence } from './OhosDiagnosticEvidence';

interface FaultParameters { time?: Any; crash_type?: Any; external_log?: Any; }

export class OhosFaultEvents {
  private static owner: OhosFaultEvents | null = null;
  private static pending: DiagnosticEvidenceRow | null = null;
  private readonly evidence: OhosDiagnosticEvidence;
  private watcher: hiAppEvent.Watcher | null = null;
  private holder: hiAppEvent.AppEventPackageHolder | null = null;
  private work: Promise<void> | null = null;
  private state: string = 'unavailable';

  constructor(evidence: OhosDiagnosticEvidence) { this.evidence = evidence; }
  availability(): string { return this.state; }

  start(): void {
    if (OhosFaultEvents.owner !== null) OhosFaultEvents.owner.stop();
    OhosFaultEvents.owner = this;
    if (!canIUse('SystemCapability.HiviewDFX.HiAppEvent')) { this.state = 'unsupported'; return; }
    const watcher: hiAppEvent.Watcher = {
      name: 'dshDiagnosticFaults',
      appEventFilters: [{ domain: hiAppEvent.domain.OS, names: [hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_FREEZE] }],
      triggerCondition: { row: 1 },
      onTrigger: (_rows: number, _bytes: number, _holder: hiAppEvent.AppEventPackageHolder): void => {
        // Do not retain the OS package or its exception, hilog and thread bodies.
        if (OhosFaultEvents.owner === this) void this.drain();
      }
    };
    this.watcher = watcher;
    try {
      this.holder = hiAppEvent.addWatcher(watcher);
      if (this.holder === null) { this.state = 'unavailable'; return; }
      this.holder.setRow(1);
      // A former process's events are collected on the next engine attachment.
      void this.drain();
    } catch (_) {
      this.holder = null; this.state = 'unavailable';
      try { hiAppEvent.removeWatcher(watcher); } catch (_) {}
    }
  }
  stop(): void {
    if (OhosFaultEvents.owner !== this) return;
    OhosFaultEvents.owner = null; this.holder = null; this.state = 'unavailable';
    if (this.watcher !== null) { try { hiAppEvent.removeWatcher(this.watcher); } catch (_) {} }
    this.watcher = null;
  }

  drain(): Promise<void> {
    if (this.work !== null) return this.work;
    if (OhosFaultEvents.owner !== this || this.holder === null) return Promise.resolve();
    const work: Promise<void> = Promise.resolve().then((): Promise<void> => this.collect());
    // A subscription/storage failure is exposed in info.evidence.availability.
    this.work = work.then((): void => {}, (): void => { this.state = 'unavailable'; });
    const settled: Promise<void> = this.work;
    settled.then((): void => { if (this.work === settled) this.work = null; });
    return settled;
  }
  private async collect(): Promise<void> {
    const holder: hiAppEvent.AppEventPackageHolder | null = this.holder;
    if (holder === null || OhosFaultEvents.owner !== this) return;
    let corrupt: boolean = false;
    try { await this.evidence.clean(); }
    catch (error) {
      if (!(error instanceof DiagnosticEvidenceError) || error.code !== 'invalid_storage') throw error as Error;
      corrupt = true;
    }
    for (let count: number = 0; count < 32; count++) {
      if (OhosFaultEvents.owner !== this || this.holder !== holder) return;
      if (OhosFaultEvents.pending === null) {
        const pack: hiAppEvent.AppEventPackage | null = holder.takeNext();
        if (pack === null) { this.state = corrupt ? 'unavailable' : 'available'; return; }
        const info: hiAppEvent.AppEventInfo | undefined = pack.appEventInfos[0];
        if (info === undefined || info.domain !== hiAppEvent.domain.OS ||
          ![hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_FREEZE].includes(info.name)) continue;
        const params: FaultParameters = info.params as FaultParameters;
        if (typeof params.time !== 'number') continue;
        OhosFaultEvents.pending = diagnosticEvidenceRow('processExits', {
          source: 'hiAppEvent', event: info.name, crashType: params.crash_type, logs: params.external_log
        }, params.time);
        if (OhosFaultEvents.pending === null) continue;
      }
      // Keep one sanitized event on write failure; a later info retries it.
      // takeNext has no acknowledgement transaction with our private file.
      const pending: DiagnosticEvidenceRow = OhosFaultEvents.pending;
      await this.evidence.fault(pending);
      if (OhosFaultEvents.pending === pending) OhosFaultEvents.pending = null;
      corrupt = false;
    }
    // A bounded batch never claims to have drained an unknown older backlog.
    // The next info/onTrigger performs another batch, without a polling timer.
    this.state = 'unavailable';
  }
}
