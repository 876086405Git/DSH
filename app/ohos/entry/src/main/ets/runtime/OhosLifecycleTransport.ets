// Public SDK 26 APIs; actual redirect/cookie/cancellation behavior awaits a device.
import http from '@ohos.net.http';
import { LifecycleTransport, HostLifecycleObservation, LifecycleFailure } from './RuntimeLifecycle';

class StopRedirect implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.REDIRECTION;
  async interceptorHandle(_request: http.HttpRequestContext, _response: http.HttpResponse): Promise<boolean> {
    return false;
  }
}

interface LifecycleAck {
  v: number;
  host: HostLifecycleObservation;
  closed: boolean;
  blocked: boolean;
}

export class OhosLifecycleTransport implements LifecycleTransport {
  private generation: number = 0;
  private cancelRequest: (() => void) | null = null;
  private origin: string | null = null;
  private launchToken: string | null = null;
  private cookie: string | null = null;

  cancel(): void { this.generation++; this.cancelRequest?.(); }

  private async request(url: string, options: http.HttpRequestOptions): Promise<http.HttpResponse> {
    const request = http.createHttp();
    return new Promise<http.HttpResponse>((resolve, reject) => {
      let settled = false;
      const finish = (response: http.HttpResponse | null, code: string | null): void => {
        if (settled) return;
        settled = true; this.cancelRequest = null; request.destroy();
        if (response !== null) resolve(response);
        else reject(new LifecycleFailure(code ?? 'ohos_lifecycle_unavailable'));
      };
      this.cancelRequest = (): void => finish(null, 'ohos_lifecycle_cancelled');
      try {
        const chain = new http.HttpInterceptorChain();
        if (!chain.addChain([new StopRedirect()]) || !chain.apply(request)) {
          finish(null, 'ohos_lifecycle_redirect_guard'); return;
        }
        request.request(url, options).then((response: http.HttpResponse): void => finish(response, null),
          (): void => finish(null, 'ohos_lifecycle_unavailable'));
      } catch (_) { finish(null, 'ohos_lifecycle_unavailable'); }
    });
  }

  private current(generation: number): void {
    if (generation !== this.generation) throw new LifecycleFailure('ohos_lifecycle_cancelled');
  }

  async send(baseUrl: string, token: string, observation: HostLifecycleObservation): Promise<void> {
    // HostCore starts a fixed IPv4 loopback listener. Never accept a Dart URL.
    const match = /^http:\/\/127\.0\.0\.1:([0-9]{1,5})\/?$/.exec(baseUrl);
    if (match === null || Number(match[1]) < 1 || Number(match[1]) > 65535 || token.length === 0) {
      throw new LifecycleFailure('ohos_lifecycle_endpoint');
    }
    const origin = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    const generation = this.generation;
    if (this.origin !== origin || this.launchToken !== token) {
      this.origin = origin; this.launchToken = token; this.cookie = null;
    }
    if (this.cookie === null) {
      const login = await this.request(origin + '/?token=' + encodeURIComponent(token), {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING,
        usingCache: false, usingProxy: false, connectTimeout: 1000, readTimeout: 3000, maxLimit: 65536
      });
      this.current(generation);
      const headers = login.header as Record<string, string | string[]>;
      let cookies: string[] = [];
      Object.keys(headers).forEach((key: string): void => {
        if (key.toLowerCase() !== 'set-cookie') return;
        const value = headers[key];
        cookies = typeof value === 'string' ? [value] : value;
      });
      const matches = cookies.map((value: string): string => value.split(';')[0])
        .filter((value: string): boolean => /^dsh-auth-[A-Za-z0-9_-]+=[A-Za-z0-9_.-]+$/.test(value));
      if (login.responseCode !== 303 || matches.length !== 1) throw new LifecycleFailure('ohos_lifecycle_auth');
      this.cookie = matches[0];
    }
    this.current(generation);
    const response = await this.request(origin + '/dsh-go/v1/lifecycle', {
      method: http.RequestMethod.POST, expectDataType: http.HttpDataType.STRING,
      header: { 'cookie': this.cookie, 'content-type': 'application/json' },
      extraData: JSON.stringify({ operation: 'host', revision: observation.revision,
        foreground: observation.foreground, computePermission: observation.computePermission }),
      usingCache: false, usingProxy: false, connectTimeout: 1000, readTimeout: 3000, maxLimit: 65536
    });
    this.current(generation);
    if (response.responseCode === 401) this.cookie = null;
    if (response.responseCode !== 200 || typeof response.result !== 'string') throw new LifecycleFailure('ohos_lifecycle_control');
    const ack: LifecycleAck = JSON.parse(response.result) as LifecycleAck;
    if (ack.v !== 1 || ack.host?.revision !== observation.revision ||
        ack.host.foreground !== observation.foreground || ack.host.computePermission !== observation.computePermission ||
        ack.closed !== false || ack.blocked !== false) throw new LifecycleFailure('ohos_lifecycle_ack');
  }
}
