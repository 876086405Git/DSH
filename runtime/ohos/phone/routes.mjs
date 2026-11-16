import { STATUS_CODES } from 'node:http';
import { PhoneProtocolError } from './queue.mjs';

const fail = (code, status = 400) => new PhoneProtocolError(code, STATUS_CODES[status], status);
const identifier = value => typeof value === 'string' && value.length > 0 && value.length <= 256 && !value.includes('\0');
const common = ['v', 'engineId', 'bridgeGeneration', 'owner'];

function readControl(req) {
  if ((req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase() !== 'application/json') throw fail('content_type', 415);
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0, settled = false;
    const finish = (error, value) => {
      if (settled) return; settled = true; clearTimeout(timer);
      req.off('data', data); req.off('end', end); req.off('error', broken); req.off('aborted', aborted);
      if (error) { req.resume(); reject(error); } else resolve(value);
    };
    const data = chunk => {
      size += chunk.length;
      if (size > 16_384) { finish(fail('too_large', 413)); return; }
      chunks.push(chunk);
    };
    const end = () => {
      try {
        const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks)));
        if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('object required');
        finish(undefined, value);
      } catch { finish(fail('bad_control')); }
    };
    const broken = () => finish(fail('broken_request'));
    const aborted = () => finish(fail('aborted_request'));
    const timer = setTimeout(() => finish(fail('body_timeout', 408)), 10_000);
    req.on('data', data); req.on('end', end); req.on('error', broken); req.on('aborted', aborted);
  });
}

/** Existing listener and signed-cookie policy, plus the separately bound native bridge owner. */
export function registerPhoneRoutes(ctx, queue) {
  let poll = null;
  const next = (auth, res) => {
    const request = queue.next(auth);
    if (request) return Promise.resolve({ v: 1, request });
    // Reconnects replace the previous read, not the task or its execution identity.
    poll?.(fail('poll_replaced', 409));
    return new Promise((resolve, reject) => {
      let settled = false, timer, unsubscribe = () => {};
      const finish = (error, request = null) => {
        if (settled) return; settled = true; clearTimeout(timer); unsubscribe(); res.off('close', closed);
        if (poll === finish) poll = null;
        if (error) reject(error); else resolve({ v: 1, request });
      };
      const wake = () => {
        try { const request = queue.next(auth); if (request) finish(undefined, request); }
        catch (error) { finish(error); }
      };
      const closed = () => finish(fail('client_closed', 499));
      poll = finish; unsubscribe = queue.subscribe(wake); res.once('close', closed);
      timer = setTimeout(() => {
        try { finish(undefined, queue.next(auth)); } catch (error) { finish(error); }
      }, 15_000);
      wake();
    });
  };
  const handler = action => async (req, res) => {
    const headers = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'content-type': 'application/json; charset=utf-8' };
    const reply = (status, body) => {
      if (res.destroyed || res.writableEnded) return;
      if (status === 408 || status === 413) headers.connection = 'close';
      res.writeHead(status, headers); res.end(req.method === 'HEAD' ? undefined : JSON.stringify(body));
    };
    try {
      const connection = ctx.get('connection');
      const rejected = connection === undefined ? 503 : connection.requestRejection(req);
      if (rejected !== undefined) { reply(rejected, { error: { code: 'host_auth', message: STATUS_CODES[rejected] } }); return; }
      if (req.method !== 'POST') { headers.allow = 'POST'; reply(405, { error: { code: 'method', message: 'Method Not Allowed' } }); return; }
      if (new URL(req.url, 'http://localhost').search) throw fail('unexpected_query');
      const body = await readControl(req);
      const fields = action === 'next' ? common : [...common, 'requestId',
        ...(action === 'result' ? ['executionNonce', 'result', 'phase'] : [])];
      if (body.v !== 1 || Object.keys(body).some(key => !fields.includes(key)) || !identifier(body.engineId) ||
          !Number.isSafeInteger(body.bridgeGeneration) || body.bridgeGeneration < 1 ||
          typeof body.owner !== 'string' || !/^[a-f0-9]{64}$/.test(body.owner) ||
          (action !== 'next' && !identifier(body.requestId))) throw fail('bad_control');
      const auth = { engineId: body.engineId, bridgeGeneration: body.bridgeGeneration, owner: body.owner };
      let answer;
      if (action === 'next') answer = await next(auth, res);
      else if (action === 'claim') answer = queue.claim(auth, body.requestId);
      else if (action === 'cancel') answer = queue.cancel(auth, body.requestId);
      else {
        if (!identifier(body.executionNonce) || (body.phase !== undefined && body.phase !== 'waiting_user') ||
            ((body.phase === undefined) === (body.result === undefined))) throw fail('bad_control');
        answer = body.phase === 'waiting_user' ? queue.waiting(auth, body.requestId, body.executionNonce)
          : queue.result(auth, body.requestId, body.executionNonce, body.result);
      }
      reply(200, answer);
    } catch (error) {
      const status = error instanceof PhoneProtocolError ? error.status : 503;
      reply(status, { error: { code: error instanceof PhoneProtocolError ? error.code : 'native_unavailable',
        message: STATUS_CODES[status] ?? 'Phone callback unavailable' } });
    }
  };
  for (const action of ['next', 'claim', 'result', 'cancel']) {
    const path = '/dsh-go/v1/phone/' + action;
    ctx.effect(() => ctx.webServer.register({ kind: 'exact', path, handler: handler(action) }), 'ohos phone ' + action);
  }
  ctx.effect(() => () => poll?.(fail('closed', 410)), 'ohos phone pending read');
}
