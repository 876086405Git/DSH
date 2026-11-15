// Node 24.22.1 / Undici 7.30.1 and 8.11.2 transport. Fetch owns the web semantics;
// node:http(s) owns the parser, so this path never instantiates llhttp's WASM.
import http from 'node:http';
import https from 'node:https';
import { BlockList, isIP } from 'node:net';
import { Readable, Transform, pipeline } from 'node:stream';

const transportError = (code, message) => Object.assign(new Error(message), { code });
const loopback = new BlockList();
loopback.addSubnet('127.0.0.0', 8, 'ipv4');
loopback.addAddress('::1', 'ipv6');

function isLoopbackHost(hostname) {
  const host = hostname.replace(/^\[|\]$/g, '').replace(/\.$/, '').toLowerCase();
  if (host === 'localhost' || host.endsWith('.localhost') || host === '0.0.0.0' || host === '::') return true;
  const family = isIP(host);
  return family !== 0 && loopback.check(host, family === 4 ? 'ipv4' : 'ipv6');
}

function requestHeaders(input = []) {
  const headers = Object.create(null);
  const append = (name, value) => {
    if (value === undefined) return;
    const key = String(name).toLowerCase();
    const copy = Array.isArray(value) ? value.slice() : value;
    headers[key] = Object.hasOwn(headers, key) ? [].concat(headers[key], copy) : copy;
  };
  if (input == null) return headers;
  if (Array.isArray(input)) {
    if (input.length % 2 !== 0) throw new TypeError('Headers array must contain name/value pairs');
    for (let i = 0; i < input.length; i += 2) append(input[i], input[i + 1]);
  } else if (typeof input === 'object') {
    const prototype = Object.getPrototypeOf(input);
    const iterator = Object.hasOwn(input, Symbol.iterator) || (prototype !== null && prototype !== Object.prototype)
      ? input[Symbol.iterator] : undefined;
    if (iterator !== undefined) {
      if (typeof iterator !== 'function') throw new TypeError('Headers iterator must be callable');
      for (const pair of { [Symbol.iterator]: () => iterator.call(input) }) {
        if (!Array.isArray(pair) || pair.length !== 2) throw new TypeError('Headers iterator must yield name/value pairs');
        append(pair[0], pair[1]);
      }
    } else {
      for (const key of Object.keys(input)) append(key, input[key]);
    }
  } else {
    throw new TypeError('Headers must be an object or array');
  }
  return headers;
}

function requestContentLength(headers) {
  const value = headers['content-length'];
  if (value === undefined) return null;
  if (!['string', 'number', 'bigint'].includes(typeof value) || !/^[0-9]+$/.test(String(value))) {
    throw Object.assign(new TypeError('Invalid request Content-Length'), { code: 'UND_ERR_INVALID_ARG' });
  }
  const length = Number(value);
  if (!Number.isSafeInteger(length)) throw Object.assign(new TypeError('Invalid request Content-Length'), { code: 'UND_ERR_INVALID_ARG' });
  return length;
}

function legacyHandler(handler) {
  if (typeof handler.onRequestStart !== 'function') return handler;
  let abort;
  let resume;
  let paused = false;
  let aborted = false;
  let reason = null;
  const controller = {
    get paused() { return paused; },
    get aborted() { return aborted; },
    get reason() { return reason; },
    pause() { paused = true; },
    resume() { if (paused) { paused = false; resume?.(); } },
    abort(value) {
      if (aborted) return;
      aborted = true;
      reason = value;
      abort?.(value);
    },
  };
  return {
    onConnect(stop, context) { abort = stop; handler.onRequestStart(controller, context); },
    onHeaders(status, headers, next, statusText) {
      resume = next;
      controller.rawHeaders = headers;
      handler.onResponseStart?.(controller, status, requestHeaders(headers), statusText);
      return !controller.paused;
    },
    onData(chunk) { handler.onResponseData?.(controller, chunk); return !controller.paused; },
    onComplete(trailers) {
      controller.rawTrailers = trailers;
      handler.onResponseEnd?.(controller, requestHeaders(trailers));
    },
    onError(error) {
      handler.onResponseError?.(controller, error);
    },
    onUpgrade(status, headers, socket) {
      controller.rawHeaders = headers;
      return handler.onRequestUpgrade?.(controller, status, requestHeaders(headers), socket);
    },
    onResponseStarted: () => handler.onResponseStarted?.(),
    onBodySent: (chunk) => handler.onBodySent?.(chunk),
    onRequestSent: () => handler.onRequestSent?.(),
  };
}

export function createHttpDispatcher({
  lookup, ca, proxyEnv, autoSelectFamily, connectTimeout = 10_000,
  headersTimeout = 300_000, bodyTimeout = 300_000,
} = {}) {
  // Preserve the original factory-time proxy configuration snapshot.
  const agents = new Map([
    ['http:/other', new http.Agent({ keepAlive: true, lookup, proxyEnv, autoSelectFamily })],
    ['https:/other', new https.Agent({ keepAlive: true, lookup, ca, proxyEnv, autoSelectFamily })],
  ]);
  function agentFor(origin) {
    const direct = isLoopbackHost(origin.hostname);
    const key = `${origin.protocol}/${direct ? 'loopback' : 'other'}`;
    if (!agents.has(key)) {
      const Agent = origin.protocol === 'https:' ? https.Agent : http.Agent;
      agents.set(key, new Agent({ keepAlive: true, lookup, ca, proxyEnv: direct ? {} : proxyEnv, autoSelectFamily }));
    }
    return agents.get(key);
  }
  const active = new Set();
  let closed = false;
  let closing;
  let drained;

  function maybeDrained() {
    if (!closed || active.size) return;
    for (const agent of agents.values()) agent.destroy();
    drained?.();
  }

  return {
    dispatch(options, handler) {
      handler = legacyHandler(handler);
      if (closed) {
        queueMicrotask(() => handler.onError(transportError('UND_ERR_CLOSED', 'HTTP transport is closed')));
        return false;
      }
      let request;
      let response;
      let upload;
      let done = false;
      let connectTimer;
      let headersTimer;
      let bodyTimer;
      const clearTimers = () => {
        clearTimeout(connectTimer);
        clearTimeout(headersTimer);
        clearTimeout(bodyTimer);
      };
      const retire = () => {
        clearTimers();
        active.delete(fail);
        maybeDrained();
      };
      function fail(error = new DOMException('The operation was aborted.', 'AbortError')) {
        if (done) return;
        done = true;
        retire();
        upload?.destroy();
        response?.destroy();
        request?.destroy();
        handler.onError(error);
      }
      function timer(ms, code, message) {
        return ms > 0 ? setTimeout(() => fail(transportError(code, message)), ms).unref() : undefined;
      }
      function armBodyTimer() {
        clearTimeout(bodyTimer);
        bodyTimer = timer(options.bodyTimeout ?? bodyTimeout, 'UND_ERR_BODY_TIMEOUT', 'HTTP response body timed out');
      }
      function resume() {
        if (done) return;
        armBodyTimer();
        response.resume();
      }
      active.add(fail);
      try {
        handler.onConnect(fail, {});
        if (done) return true;
        const origin = new URL(options.origin);
        const protocol = origin.protocol;
        if (protocol !== 'http:' && protocol !== 'https:') throw new TypeError('HTTP transport requires http or https');
        const headers = requestHeaders(options.headers);
        const declaredLength = requestContentLength(headers);
        if (options.upgrade) {
          headers.connection = 'Upgrade';
          headers.upgrade = options.upgrade;
        }
        request = (protocol === 'https:' ? https : http).request(origin, {
          path: options.path,
          method: options.method,
          headers,
          agent: agentFor(origin),
        });
        request.once('error', fail);
        connectTimer = timer(connectTimeout, 'UND_ERR_CONNECT_TIMEOUT', 'HTTP connection timed out');
        headersTimer = timer(options.headersTimeout ?? headersTimeout, 'UND_ERR_HEADERS_TIMEOUT', 'HTTP response headers timed out');
        request.once('socket', (socket) => {
          const connected = () => clearTimeout(connectTimer);
          if (!socket.connecting) connected();
          else socket.once(protocol === 'https:' ? 'secureConnect' : 'connect', connected);
        });
        request.once('response', (incoming) => {
          response = incoming;
          clearTimeout(connectTimer);
          clearTimeout(headersTimer);
          if (done) { incoming.destroy(); return; }
          incoming.once('error', fail);
          incoming.once('close', () => {
            if (!incoming.complete) fail(transportError('UND_ERR_SOCKET', 'HTTP response ended before completion'));
          });
          incoming.on('data', (chunk) => {
            if (done) return;
            try {
              armBodyTimer();
              if (handler.onData(chunk) === false) {
                clearTimeout(bodyTimer);
                incoming.pause();
              }
            } catch (error) { fail(error); }
          });
          incoming.once('end', () => {
            if (done) return;
            done = true;
            retire();
            if (!request.writableFinished) { upload?.destroy(); request.destroy(); }
            handler.onComplete(incoming.rawTrailers);
          });
          try {
            handler.onResponseStarted?.();
            armBodyTimer();
            if (handler.onHeaders(incoming.statusCode, incoming.rawHeaders, resume, incoming.statusMessage) === false) {
              clearTimeout(bodyTimer);
              incoming.pause();
            }
          } catch (error) { fail(error); }
        });
        request.once('upgrade', (incoming, socket, head) => {
          if (done) { socket.destroy(); return; }
          try {
            if (!options.upgrade || !handler.onUpgrade) throw new TypeError('Unexpected HTTP upgrade');
            // Bytes after the HTTP headers already belong to the upgraded stream.
            if (head.length) socket.unshift(head);
            if (handler.onUpgrade(incoming.statusCode, incoming.rawHeaders, socket) === false) {
              throw new TypeError('HTTP upgrade was refused');
            }
            done = true;
            retire();
          } catch (error) { socket.destroy(); fail(error); }
        });
        let written = 0;
        upload = Readable.from(options.body ?? [], { objectMode: false });
        const lengthCheck = new Transform({
          transform(chunk, _encoding, next) {
            written += chunk.length;
            if (declaredLength !== null && written > declaredLength) {
              next(transportError('UND_ERR_REQ_CONTENT_LENGTH_MISMATCH', 'Request body exceeds Content-Length'));
            } else {
              try { handler.onBodySent?.(chunk); next(null, chunk); }
              catch (error) { next(error); }
            }
          },
          flush(next) {
            next(declaredLength !== null && written !== declaredLength
              ? transportError('UND_ERR_REQ_CONTENT_LENGTH_MISMATCH', 'Request body does not match Content-Length') : null);
          },
        });
        pipeline(upload, lengthCheck, request, (error) => {
          if (error) fail(error);
          else {
            try { handler.onRequestSent?.(); } catch (error) { fail(error); }
          }
        });
      } catch (error) { fail(error); }
      return true;
    },
    close(callback) {
      closed = true;
      closing ??= new Promise((resolve) => { drained = resolve; });
      maybeDrained();
      if (callback) { closing.then(() => callback(null), callback); return; }
      return closing;
    },
    destroy(error, callback) {
      if (typeof error === 'function') { callback = error; error = undefined; }
      closed = true;
      for (const abort of active) abort(error ?? transportError('UND_ERR_DESTROYED', 'HTTP transport was destroyed'));
      return this.close(callback);
    },
  };
}
