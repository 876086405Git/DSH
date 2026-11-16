import { createRequire } from 'node:module';
import { isIP } from 'node:net';

// Use the existing active-policy/parent-environment contract, not a second
// process-wide proxy owner. This policy belongs only to LinuxControl jobs.
const requireProcess = createRequire(new URL('../process/runtime.mjs', import.meta.url));
const { scrubbedParentEnv } = requireProcess('@deepseek-ai/dsh-subprocess');
const names = ['http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY',
  'all_proxy', 'ALL_PROXY', 'no_proxy', 'NO_PROXY', 'NODE_USE_ENV_PROXY'];
const bypass = ['localhost', '127.0.0.1', '::1', '[::1]',
  'gitee.com', '.gitee.com', 'huaweicloud.com', '.huaweicloud.com'];
const failure = code => Object.assign(new Error('Linux proxy configuration is invalid or unsupported'), { code, status: 400 });
const configError = () => failure('ERR_OHOS_LINUX_PROXY_CONFIG');
const nonempty = value => typeof value === 'string' && value.trim() !== '';
const bounded = (value, size) => typeof value === 'string' && Buffer.byteLength(value) <= size && !value.includes('\0');

function parentProxy() {
  const parent = scrubbedParentEnv();
  return Object.fromEntries(names.map(name => [name, parent[name]]));
}
function noProxy(...values) {
  const entries = values.flatMap(value => typeof value === 'string' ? value.split(/[,\s]+/) : [])
    .map(value => value.trim()).filter(Boolean);
  // Python's client, among others, treats the whole value '*' specially.
  if (entries.includes('*')) return '*';
  return [...new Set([...entries, ...bypass])].join(',');
}
function guestAddress(url) {
  const host = url.hostname.toLowerCase().replace(/\.$/, '');
  const ipv4Loopback = isIP(host) === 4 && host.startsWith('127.');
  const ipv6Loopback = host === '[::1]' || host === '::1';
  if (ipv6Loopback || (ipv4Loopback && host !== '127.0.0.1') ||
      ((host === 'localhost' || ipv4Loopback) && url.protocol === 'https:')) {
    throw failure('ERR_OHOS_LINUX_PROXY_ADDRESS');
  }
  // TinyEMU's actual IPv4 slirp host alias connects to host 127.0.0.1 with
  // the same port. It cannot preserve an arbitrary 127.x binding or TLS name.
  if (host === 'localhost' || host === '127.0.0.1') url.hostname = '10.0.2.2';
  return url.href;
}
function proxyUrl(value) {
  if (!bounded(value, 4096) || /[\u0000-\u0020\u007f]/.test(value)) throw failure('ERR_OHOS_LINUX_PROXY_URL');
  let url;
  try { url = new URL(value); } catch { throw failure('ERR_OHOS_LINUX_PROXY_URL'); }
  if (!['http:', 'https:'].includes(url.protocol) || !url.hostname ||
      url.pathname !== '/' || url.search || url.hash) throw failure('ERR_OHOS_LINUX_PROXY_URL');
  return guestAddress(url);
}
function inheritedAddress(value) {
  if (!nonempty(value)) return value;
  let url;
  try { url = new URL(value); } catch { return value; }
  // Existing inherited schemes/errors belong to their existing tool contract.
  // Only an HTTP(S) App endpoint has the explicit host-to-guest address rule.
  if (!['http:', 'https:'].includes(url.protocol)) return value;
  return guestAddress(url);
}
function normalize(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      !['inherit', 'direct', 'manual'].includes(value.mode) ||
      Object.keys(value).some(key => !['mode', 'httpProxy', 'httpsProxy', 'noProxy'].includes(key))) throw configError();
  if (value.mode !== 'manual') {
    if (Object.keys(value).some(key => key !== 'mode')) throw configError();
    return Object.freeze({ mode: value.mode });
  }
  for (const key of ['httpProxy', 'httpsProxy', 'noProxy']) {
    if (value[key] !== undefined && !bounded(value[key], 4096)) throw configError();
  }
  const httpProxy = nonempty(value.httpProxy) ? proxyUrl(value.httpProxy.trim()) : undefined;
  const httpsProxy = nonempty(value.httpsProxy) ? proxyUrl(value.httpsProxy.trim()) : httpProxy;
  if (!httpProxy && !httpsProxy) throw configError();
  return Object.freeze({ mode: 'manual', httpProxy, httpsProxy, noProxy: noProxy(value.noProxy) });
}

/** A routed command inherits the App's own proxy variables through its shell.
 * Those copies are not deliberate settings: drop them so this policy decides. */
export function withoutInheritedProxy(env) {
  const parent = scrubbedParentEnv();
  return Object.fromEntries(Object.entries(env).filter(([key, value]) => !names.includes(key) || value !== parent[key]));
}

/** In-memory configuration only. No persistence, dispatcher mutation or I/O. */
export class LinuxProxyPolicy {
  #configuration = Object.freeze({ mode: 'inherit' });
  #revision = 0;
  set(value) {
    const next = normalize(value);
    if (JSON.stringify(next) === JSON.stringify(this.#configuration)) return;
    if (this.#revision >= Number.MAX_SAFE_INTEGER) throw failure('ERR_OHOS_LINUX_PROXY_REVISION');
    this.#configuration = next; this.#revision++;
  }
  status() {
    const value = this.#configuration, inherited = value.mode === 'inherit' ? parentProxy() : undefined;
    return { source: value.mode, revision: this.#revision,
      httpConfigured: value.mode === 'manual' ? !!value.httpProxy :
        value.mode === 'inherit' && [inherited.http_proxy, inherited.HTTP_PROXY, inherited.all_proxy, inherited.ALL_PROXY].some(nonempty),
      httpsConfigured: value.mode === 'manual' ? !!value.httpsProxy :
        value.mode === 'inherit' && [inherited.https_proxy, inherited.HTTPS_PROXY, inherited.all_proxy, inherited.ALL_PROXY].some(nonempty) };
  }
  forRequest(explicit) {
    const value = this.#configuration;
    if (value.mode !== 'inherit' && names.some(key => Object.hasOwn(explicit, key))) {
      throw failure('ERR_OHOS_LINUX_PROXY_ENV_CONFLICT');
    }
    const environment = { ...explicit };
    // Publish all aliases, including undefined removals, so backend inheritance
    // cannot reintroduce an old fallback after this per-request snapshot.
    const proxy = Object.fromEntries(names.map(key => [key, undefined]));
    if (value.mode === 'manual') {
      proxy.http_proxy = proxy.HTTP_PROXY = value.httpProxy;
      proxy.https_proxy = proxy.HTTPS_PROXY = value.httpsProxy;
      proxy.no_proxy = proxy.NO_PROXY = value.noProxy;
      proxy.NODE_USE_ENV_PROXY = '1';
    } else if (value.mode === 'inherit') {
      const inherited = parentProxy(); Object.assign(proxy, inherited);
      for (const key of names.slice(0, 6)) {
        if (!Object.hasOwn(explicit, key)) proxy[key] = inheritedAddress(proxy[key]);
      }
      // Deliberate caller values retain their existing precedence and address
      // realm. They are not silently reinterpreted as an App loopback endpoint.
      for (const key of names) if (Object.hasOwn(explicit, key)) proxy[key] = explicit[key];
      proxy.no_proxy = proxy.NO_PROXY = noProxy(inherited.no_proxy, inherited.NO_PROXY, explicit.no_proxy, explicit.NO_PROXY);
    }
    Object.assign(environment, proxy);
    return { environment, revision: this.#revision };
  }
}
