import type { HostLifecycleSnapshot } from 'libdsh_host.so';
// UI observations do not prove that the OS has frozen or granted CPU time.
export interface HostLifecycleObservation {
  revision: number;
  foreground: boolean;
  computePermission: string;
}

export interface HostLifecycleAck {
  nativeHost: HostLifecycleSnapshot | null;
  busy: boolean;
  manualPaused: boolean;
  confirmedPause: boolean;
}

export interface LifecycleTransport {
  send(baseUrl: string, token: string, observation: HostLifecycleObservation): Promise<HostLifecycleAck>;
  cancel(): void;
}

export class LifecycleFailure extends Error {
  readonly code: string;
  constructor(code: string) { super('本机引擎生命周期同步未完成。'); this.code = code; }
}

export class RuntimeLifecycle {
  private readonly transport: LifecycleTransport;
  private readonly permission: () => string;
  private readonly changed: () => void;
  private readonly received: (ack: HostLifecycleAck) => void;
  private foreground: boolean = false;
  private revision: number = 1;
  private generation: number = 0;
  private baseUrl: string | null = null;
  private token: string | null = null;
  private requested: number = -1;
  private acknowledged: number = -1;
  private failure: string | null = null;
  private observation: HostLifecycleObservation | null = null;
  private retry: number | null = null;
  private retryDelay: number = 1000;

  constructor(transport: LifecycleTransport, permission: () => string, changed: () => void = (): void => {},
    received: (ack: HostLifecycleAck) => void = (_ack: HostLifecycleAck): void => {}) {
    this.transport = transport; this.permission = permission; this.changed = changed; this.received = received;
  }

  observe(foreground: boolean): void {
    this.resetRetry();
    this.foreground = foreground; this.revision++;
    this.push();
  }

  runtime(baseUrl: string | null, token: string | null): void {
    if (this.baseUrl === baseUrl && this.token === token) return;
    this.resetRetry();
    this.generation++; this.transport.cancel();
    this.baseUrl = baseUrl; this.token = token; this.requested = -1; this.acknowledged = -1;
    this.failure = null; this.push();
    if (baseUrl === null) this.changed();
  }

  refresh(): void {
    if (this.requested === this.acknowledged && this.failure === null) this.observe(this.foreground);
  }

  status(): Map<string, Object | null> {
    return new Map<string, Object | null>([
      ['foreground', this.foreground], ['revision', this.revision],
      ['acknowledgedRevision', this.acknowledged < 0 ? null : this.acknowledged],
      ['error', this.failure]
    ]);
  }

  failureCode(): string | null { return this.failure; }

  synchronized(): boolean {
    return this.baseUrl !== null && this.token !== null && this.requested === this.revision &&
      this.acknowledged === this.revision && this.failure === null;
  }

  private resetRetry(): void {
    if (this.retry !== null) clearTimeout(this.retry);
    this.retry = null; this.retryDelay = 1000; this.observation = null;
  }

  private push(): void {
    if (this.baseUrl === null || this.token === null || this.requested === this.revision) return;
    const revision = this.revision, generation = this.generation;
    if (this.observation === null) this.observation = {
      revision: revision, foreground: this.foreground, computePermission: this.permission()
    };
    this.requested = revision; this.transport.cancel();
    this.transport.send(this.baseUrl, this.token, this.observation).then((ack: HostLifecycleAck): void => {
      if (this.generation === generation && this.revision === revision) {
        this.acknowledged = revision; this.failure = null;
        try { this.received(ack); }
        catch (_) { this.failure = 'ohos_lifecycle_native'; }
        this.changed();
      }
    }, (error: Error): void => {
      if (this.generation === generation && this.revision === revision) {
        this.failure = error instanceof LifecycleFailure ? error.code : 'ohos_lifecycle_unavailable';
        // Retry only this idempotent host observation, never a tool or prompt.
        this.retry = setTimeout((): void => {
          this.retry = null; this.requested = -1; this.push();
        }, this.retryDelay);
        this.retryDelay = Math.min(this.retryDelay * 2, 30000);
        this.changed();
      }
    });
  }
}
