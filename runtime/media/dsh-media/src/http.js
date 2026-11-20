import { request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { lookup as dnsLookup } from 'node:dns/promises';
import { BlockList, isIP } from 'node:net';
import { MediaError, checkAbort, abortError, fail } from './errors.js';

// Deliberately conservative: production accepts HTTPS to public address ranges.
// A test-only transport instance may admit literal loopback HTTP mock servers.
const denied4 = new BlockList();
const denied6 = new BlockList();
for (const [address, prefix] of [
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10],
  ['127.0.0.0', 8], ['169.254.0.0', 16], ['172.16.0.0', 12],
  ['192.0.0.0', 24], ['192.0.2.0', 24], ['192.88.99.0', 24],
  ['192.168.0.0', 16], ['198.18.0.0', 15], ['198.51.100.0', 24],
  ['203.0.113.0', 24], ['224.0.0.0', 4], ['240.0.0.0', 4],
]) {
  denied4.addSubnet(address, prefix, 'ipv4');
  // RFC 6052: the well-known prefix retains its embedded IPv4 exclusions.
  denied6.addSubnet(`64:ff9b::${address}`, 96 + prefix, 'ipv6');
}
const global6 = new BlockList();
global6.addSubnet('2000::', 3, 'ipv6');
global6.addSubnet('64:ff9b::', 96, 'ipv6');
for (const [address, prefix] of [
  ['2001::', 23], ['2001:db8::', 32], ['2002::', 16], ['3fff::', 20],
]) denied6.addSubnet(address, prefix, 'ipv6');

export function isPublicAddress(address) {
  const family = isIP(address);
  if (family === 4) return !denied4.check(address, 'ipv4');
  // This also rejects mapped IPv4, link local, ULA, and unspecified addresses.
  return family === 6 && global6.check(address, 'ipv6')
    && !denied6.check(address, 'ipv6');
}

function hostname(url) {
  return url.hostname.replace(/^\[/, '').replace(/\]$/, '');
}

export function parseMediaUrl(value, { allowLoopback = false } = {}) {
  let url;
  try { url = new URL(value); } catch { fail('unsafe_url'); }
  if (url.username || url.password || url.hash || value.length > 8192) {
    fail('unsafe_url');
  }
  const host = hostname(url);
  const loopback = host === '127.0.0.1' || host === '::1';
  if (url.protocol !== 'https:' && !(allowLoopback && loopback && url.protocol === 'http:')) {
    fail('unsafe_url');
  }
  if (isIP(host) && !(allowLoopback && loopback) && !isPublicAddress(host)) {
    fail('unsafe_url');
  }
  return url;
}

async function withAbort(promise, signal) {
  checkAbort(signal);
  if (!signal) return promise;
  return new Promise((resolve, reject) => {
    const onAbort = () => reject(abortError(signal));
    signal.addEventListener('abort', onAbort, { once: true });
    // Attach both handlers even if abort wins, so later DNS rejection is consumed.
    promise.then(resolve, reject).finally(() => {
      signal.removeEventListener('abort', onAbort);
    }).catch(() => {});
    if (signal.aborted) onAbort();
  });
}

function createHttpPreparer({ allowLoopback = false, lookup = dnsLookup } = {}) {
  return async function prepareHttpRequest(value, {
    method = 'GET', headers = {}, body, signal, maxBytes,
  }) {
    checkAbort(signal);
    if (!Number.isSafeInteger(maxBytes) || maxBytes <= 0
      || !['GET', 'POST', 'DELETE'].includes(method)) fail('invalid_request');
    if (Object.keys(headers).some(name => [
      'host', 'connection', 'upgrade', 'proxy-authorization', 'proxy-connection',
      'transfer-encoding', 'te', 'trailer',
    ].includes(name.toLowerCase()))) fail('invalid_request');
    const url = parseMediaUrl(value, { allowLoopback });
    const host = hostname(url);
    const literal = isIP(host);
    let addresses;
    try {
      addresses = literal ? [{ address: host, family: literal }]
        : await withAbort(lookup(host, { all: true, verbatim: true }), signal);
    } catch (error) {
      if (error instanceof MediaError) throw error;
      fail('network');
    }
    checkAbort(signal);
    if (!Array.isArray(addresses) || addresses.length === 0
      || addresses.some(entry => {
        if (allowLoopback && (entry.address === '127.0.0.1' || entry.address === '::1')) {
          return !literal;
        }
        return !isPublicAddress(entry.address);
      })) fail('unsafe_url');
    const selected = addresses[0];
    const send = url.protocol === 'https:' ? httpsRequest : httpRequest;

    return () => new Promise((resolve, reject) => {
      checkAbort(signal);
      let settled = false;
      const finish = (error, result) => {
        if (settled) return;
        settled = true;
        if (error) reject(error); else resolve(result);
      };
      let req;
      try {
        req = send(url, {
          method,
          headers,
          agent: false,
          family: selected.family,
          servername: literal ? undefined : host,
          autoSelectFamily: false,
          maxHeaderSize: 16384,
          signal,
          // The TLS hostname remains the original host. DNS is not repeated.
          lookup: (_name, options, callback) => {
            if (typeof options === 'function') {
              callback = options;
              options = {};
            }
            if (options?.all) callback(null, [selected]);
            else callback(null, selected.address, selected.family);
          },
        }, res => {
          const chunks = [];
          let bytes = 0;
          const stop = code => {
            finish(new MediaError(code));
            res.destroy();
            req.destroy();
          };
          const encoding = res.headers['content-encoding'];
          if (encoding && encoding !== 'identity') {
            stop('response');
            return;
          }
          const declared = res.headers['content-length'];
          if (declared !== undefined
            && (!/^\d+$/.test(declared) || Number(declared) > maxBytes)) {
            stop('too_large');
            return;
          }
          res.on('data', chunk => {
            bytes += chunk.length;
            if (bytes > maxBytes) { stop('too_large'); return; }
            chunks.push(chunk);
          });
          res.on('end', () => {
            if (!res.complete) { finish(new MediaError('network')); return; }
            finish(null, {
              status: res.statusCode ?? 0,
              headers: res.headers,
              body: Buffer.concat(chunks, bytes),
            });
          });
          res.on('error', () => finish(signal?.aborted
            ? abortError(signal) : new MediaError('network')));
          res.on('aborted', () => finish(signal?.aborted
            ? abortError(signal) : new MediaError('network')));
          res.on('close', () => {
            if (!res.complete) finish(signal?.aborted
              ? abortError(signal) : new MediaError('network'));
          });
        });
        req.on('upgrade', (_res, socket) => {
          socket.destroy();
          finish(new MediaError('response'));
        });
        req.on('connect', (_res, socket) => {
          socket.destroy();
          finish(new MediaError('response'));
        });
        req.on('close', () => {
          if (!settled) finish(signal?.aborted
            ? abortError(signal) : new MediaError('network'));
        });
        req.on('error', () => finish(signal?.aborted
          ? abortError(signal) : new MediaError('network')));
        req.end(body);
      } catch {
        req?.destroy();
        finish(signal?.aborted ? abortError(signal) : new MediaError('network'));
      }
    });
  };
}

export function createHttpTransport(options) {
  const prepare = createHttpPreparer(options);
  return async function requestBytes(value, options) {
    return (await prepare(value, options))();
  };
}

export const prepareHttpRequest = createHttpPreparer();
export const requestBytes = createHttpTransport();
