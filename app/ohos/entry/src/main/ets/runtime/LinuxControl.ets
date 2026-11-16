// SDK 26 HTTP calls follow the existing lifecycle transport. Device validation is pending.
import http from '@ohos.net.http';
import { RuntimeChannelError } from './RuntimeCore';

interface LinuxNativeRetirement { joined: boolean; retirementError: boolean | null; apiResult: number | null; }
interface LinuxGuestClose { epoch: string; rootfsSync: boolean; syncMethod: string; syncScope: string; }
export interface LinuxProxyConfiguration { mode: string; httpProxy?: string; httpsProxy?: string; noProxy?: string; }
export interface LinuxProxyStatus { source: string; revision: number; httpConfigured: boolean; httpsConfigured: boolean; }
interface LinuxJobProxyFact { proxyRevision?: number; }
interface LinuxRetirement {
  resourcesRetired: boolean; filesRemoved: boolean; dataRetained: boolean;
  ownerQuarantined: boolean; native: LinuxNativeRetirement | null; releaseErrorCode: string | null;
  guestClose?: LinuxGuestClose | null; cleanCheckpoint?: boolean;
}
export interface LinuxStatus {
  v: number; instanceId: string; attemptId: string | null; state: string;
  persistentInstanceId?: string | null; bootMode?: string | null;
  nativeMemoryRelease?: string | null;
  enabled: boolean; admission: boolean; guestOpened: boolean; ownerRetained: boolean;
  workspaceLease: boolean; restartRequired: boolean; shutdownComplete: boolean; nextRequestId: number;
  retirement: LinuxRetirement | null;
  proxy?: LinuxProxyStatus; job?: LinuxJobProxyFact | null;
}
export interface LinuxRunRequest {
  v: number; instanceId: string; attemptId: string; action: string; requestId: number;
  argv: string[]; cwd: string; env: Record<string, string>; stdin: string;
}
interface LinuxRequest {
  v: number; instanceId: string; attemptId: string | null; action: string; enabled?: boolean;
  proxy?: LinuxProxyConfiguration;
}
interface LinuxErrorDetail { code: string; }
interface LinuxErrorResponse { error: LinuxErrorDetail; }
interface LinuxSession {
  origin: string; token: string; cookie: string | null; login: Promise<string> | null;
}

class StopRedirect implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.REDIRECTION;
  async interceptorHandle(_request: http.HttpRequestContext, _response: http.HttpResponse): Promise<boolean> {
    return false;
  }
}

function failure(code: string): RuntimeChannelError {
  return new RuntimeChannelError(code, 'Linux 控制尚未确认完成；请检查状态，勿将网络中断当作任务或资源已结束。');
}

function decodeStatus(text: string): LinuxStatus {
  const value: LinuxStatus = JSON.parse(text) as LinuxStatus;
  if (value === null || value.v !== 1 || typeof value.instanceId !== 'string' || value.instanceId.length === 0 ||
      !(value.attemptId === null || typeof value.attemptId === 'string') ||
      !['disabled', 'installing', 'enabled', 'disabling', 'stopping', 'stopped', 'unavailable', 'failed', 'unknown'].includes(value.state) ||
      ![value.enabled, value.admission, value.guestOpened, value.ownerRetained, value.workspaceLease,
        value.restartRequired, value.shutdownComplete].every((item: boolean): boolean => typeof item === 'boolean') ||
      value.workspaceLease !== false || !Number.isSafeInteger(value.nextRequestId) || value.nextRequestId < 1) {
    throw failure('ohos_linux_protocol');
  }
  if (!(value.persistentInstanceId === undefined || value.persistentInstanceId === null ||
      typeof value.persistentInstanceId === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value.persistentInstanceId)) ||
      !(value.bootMode === undefined || value.bootMode === null || value.bootMode === 'install' || value.bootMode === 'resume') ||
      ((value.persistentInstanceId ?? null) === null) !== ((value.bootMode ?? null) === null)) {
    throw failure('ohos_linux_protocol');
  }
  if (value.nativeMemoryRelease !== undefined && value.nativeMemoryRelease !== null &&
      value.nativeMemoryRelease !== 'process-exit') throw failure('ohos_linux_protocol');
  const proxy = value.proxy;
  if (proxy !== undefined && (proxy === null ||
      Object.keys(proxy).some((key: string): boolean => !['source', 'revision', 'httpConfigured', 'httpsConfigured'].includes(key)) ||
      !['inherit', 'direct', 'manual'].includes(proxy.source) || !Number.isSafeInteger(proxy.revision) || proxy.revision < 0 ||
      typeof proxy.httpConfigured !== 'boolean' || typeof proxy.httpsConfigured !== 'boolean' ||
      (proxy.source === 'direct' && (proxy.httpConfigured || proxy.httpsConfigured)) ||
      (proxy.source === 'manual' && !proxy.httpConfigured && !proxy.httpsConfigured))) throw failure('ohos_linux_protocol');
  const proxyRevision = value.job?.proxyRevision;
  if (proxyRevision !== undefined && (!Number.isSafeInteger(proxyRevision) || proxyRevision < 0)) throw failure('ohos_linux_protocol');
  const retired = value.retirement;
  if (retired !== null) {
    if (retired === undefined || ![retired.resourcesRetired, retired.filesRemoved, retired.dataRetained, retired.ownerQuarantined]
      .every((item: boolean): boolean => typeof item === 'boolean')) throw failure('ohos_linux_protocol');
    const native = retired.native;
    if (native !== null && (native === undefined || typeof native.joined !== 'boolean' ||
      !(native.retirementError === null || typeof native.retirementError === 'boolean') ||
      !(native.apiResult === null || Number.isInteger(native.apiResult)))) throw failure('ohos_linux_protocol');
    const close = retired.guestClose;
    if (close !== undefined && close !== null && (typeof close.epoch !== 'string' ||
      !/^[a-f0-9]{64}$/.test(close.epoch) || close.rootfsSync !== true ||
      close.syncMethod !== 'syncfs' || close.syncScope !== 'rootfs')) throw failure('ohos_linux_protocol');
    if (retired.cleanCheckpoint !== undefined && typeof retired.cleanCheckpoint !== 'boolean') throw failure('ohos_linux_protocol');
    if (retired.cleanCheckpoint === true && (!value.persistentInstanceId || !retired.resourcesRetired || !retired.dataRetained || retired.filesRemoved ||
      close === undefined || close === null || native === null || !native.joined || native.retirementError !== false ||
      (native.apiResult !== -3 && native.apiResult !== -4))) throw failure('ohos_linux_protocol');
  }
  if (value.shutdownComplete && (retired === null || !retired.resourcesRetired ||
    (retired.native === null ? retired.ownerQuarantined : !retired.native.joined || retired.native.retirementError !== false))) {
    throw failure('ohos_linux_shutdown_unconfirmed');
  }
  return value;
}

export class LinuxControl {
  private session: LinuxSession | null = null;

  private host(baseUrl: string, token: string): LinuxSession {
    // Both values come from NativeHost, never from a MethodChannel argument.
    const match = /^http:\/\/127\.0\.0\.1:([0-9]{1,5})\/?$/.exec(baseUrl);
    if (match === null || Number(match[1]) < 1 || Number(match[1]) > 65535 || token.length === 0) {
      throw failure('ohos_linux_endpoint');
    }
    const origin = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    if (this.session === null || this.session.origin !== origin || this.session.token !== token) {
      this.session = { origin: origin, token: token, cookie: null, login: null };
    }
    return this.session;
  }

  private async request(url: string, options: http.HttpRequestOptions): Promise<http.HttpResponse> {
    const request = http.createHttp();
    try {
      const chain = new http.HttpInterceptorChain();
      if (!chain.addChain([new StopRedirect()]) || !chain.apply(request)) throw failure('ohos_linux_redirect_guard');
      return await request.request(url, options);
    } catch (error) {
      if (error instanceof RuntimeChannelError) throw error as Error;
      throw failure('ohos_linux_unavailable');
    } finally { request.destroy(); }
  }

  private async login(session: LinuxSession): Promise<string> {
    if (session.cookie !== null) return session.cookie;
    if (session.login !== null) return session.login;
    session.login = (async (): Promise<string> => {
      const response = await this.request(session.origin + '/?token=' + encodeURIComponent(session.token), {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING,
        usingCache: false, usingProxy: false, connectTimeout: 1000, readTimeout: 5000, maxLimit: 65536
      });
      const headers = response.header as Record<string, string | string[]>;
      let cookies: string[] = [];
      Object.keys(headers).forEach((key: string): void => {
        if (key.toLowerCase() !== 'set-cookie') return;
        const value = headers[key]; cookies = typeof value === 'string' ? [value] : value;
      });
      const matches = cookies.map((value: string): string => value.split(';')[0])
        .filter((value: string): boolean => /^dsh-auth-[A-Za-z0-9_-]+=[A-Za-z0-9_.-]+$/.test(value));
      if (response.responseCode !== 303 || matches.length !== 1) throw failure('ohos_linux_auth');
      session.cookie = matches[0]; return matches[0];
    })();
    try { return await session.login; } finally { session.login = null; }
  }

  private async exchange(baseUrl: string, token: string, body: string | null, readTimeout: number = 5000): Promise<string> {
    const session = this.host(baseUrl, token);
    const cookie = await this.login(session);
    const options: http.HttpRequestOptions = {
      method: body === null ? http.RequestMethod.GET : http.RequestMethod.POST,
      expectDataType: http.HttpDataType.STRING, header: { 'cookie': cookie, 'content-type': 'application/json' },
      usingCache: false, usingProxy: false, connectTimeout: 1000, readTimeout: readTimeout, maxLimit: 65536
    };
    if (body !== null) options.extraData = body;
    const response = await this.request(session.origin + '/dsh-go/v1/linux', options);
    if (session !== this.session) throw failure('ohos_linux_stale');
    if (response.responseCode === 401) session.cookie = null;
    if (typeof response.result !== 'string') throw failure('ohos_linux_protocol');
    if (response.responseCode !== 200 && response.responseCode !== 202) {
      let code = 'ohos_linux_control';
      try {
        const value: LinuxErrorResponse = JSON.parse(response.result) as LinuxErrorResponse;
        if (typeof value.error?.code === 'string' && /^ERR_OHOS_[A-Z0-9_]+$/.test(value.error.code)) code = value.error.code;
      } catch (_) { /* Keep the local code; do not surface arbitrary server text. */ }
      throw failure(code);
    }
    decodeStatus(response.result);
    return response.result;
  }

  getStatus(baseUrl: string, token: string): Promise<string> { return this.exchange(baseUrl, token, null); }

  async setEnabled(baseUrl: string, token: string, enabled: boolean): Promise<string> {
    const current = decodeStatus(await this.getStatus(baseUrl, token));
    const request: LinuxRequest = { v: 1, instanceId: current.instanceId, attemptId: current.attemptId,
      action: 'setEnabled', enabled: enabled };
    return this.exchange(baseUrl, token, JSON.stringify(request));
  }

  async setProxy(baseUrl: string, token: string, proxy: LinuxProxyConfiguration): Promise<string> {
    const current = decodeStatus(await this.getStatus(baseUrl, token));
    const request: LinuxRequest = { v: 1, instanceId: current.instanceId, attemptId: current.attemptId,
      action: 'setProxy', proxy: proxy };
    // Session-only settings are sent directly to the trusted Node endpoint.
    // They are never persisted or included in status/error messages.
    return this.exchange(baseUrl, token, JSON.stringify(request));
  }

  // 重新安装 Linux: Node deletes the retained instance before it replies, so
  // this one waits longer than the 202 calls. A timeout is not a failure of
  // the deletion; the caller reads the status again.
  async discardRetained(baseUrl: string, token: string): Promise<string> {
    const current = decodeStatus(await this.getStatus(baseUrl, token));
    const request: LinuxRequest = { v: 1, instanceId: current.instanceId, attemptId: current.attemptId,
      action: 'discardRetained' };
    return this.exchange(baseUrl, token, JSON.stringify(request), 60000);
  }

  runPrivateGuest(baseUrl: string, token: string, request: LinuxRunRequest): Promise<string> {
    // Preserve the caller's request identity. A transport retry must not allocate a new job.
    return this.exchange(baseUrl, token, JSON.stringify(request));
  }

  async shutdown(baseUrl: string, token: string): Promise<void> {
    let current = decodeStatus(await this.getStatus(baseUrl, token));
    const instance = current.instanceId;
    if (!current.shutdownComplete) {
      const request: LinuxRequest = { v: 1, instanceId: instance, attemptId: current.attemptId, action: 'shutdown' };
      current = decodeStatus(await this.exchange(baseUrl, token, JSON.stringify(request)));
    }
    // This is a bounded observation window, never a synthetic completion ACK.
    const deadline = Date.now() + 180000;
    while (!current.shutdownComplete) {
      // Earlier installation cleanup is not the final shutdown acknowledgement.
      if (current.instanceId !== instance ||
          (current.retirement !== null && !current.retirement.resourcesRetired) || Date.now() >= deadline) {
        throw failure('ohos_linux_shutdown_unconfirmed');
      }
      await new Promise<void>((resolve): void => { setTimeout(resolve, 250); });
      current = decodeStatus(await this.getStatus(baseUrl, token));
    }
    if (current.instanceId !== instance) throw failure('ohos_linux_stale');
  }
}
