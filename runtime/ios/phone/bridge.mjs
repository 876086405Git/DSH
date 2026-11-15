import http from 'node:http';
import { randomUUID, timingSafeEqual } from 'node:crypto';
import { once } from 'node:events';
import { actionFor } from './actions.mjs';

const result = (text, isError = false) => ({ content: [{ type: 'text', text }], isError });
const failure = (code, text) => result(`${code}: ${text}`, true);
// These need nobody on screen in DSH Go, and answer with a page or a screenshot, a good deal
// larger than anything else here.
const isBrowser = request => /^(browser|runner)-/.test(request.action.kind);
const isSystem = request => request.action.kind.startsWith('system-');
const SYSTEM_RESULT_BYTES = 32768;
const RESULT_BYTES = 16384;
const BROWSER_RESULT_BYTES = 512 * 1024;
const BROWSER_IMAGE_BYTES = 1200 * 1024;
const BODY_BYTES = 32768;
const RESULT_BODY_BYTES = 2 * 1024 * 1024;
// Someone signing in to a site takes longer than someone answering a prompt.
const HANDOFF_MS = 600000;

// Swift owns the bootstrap secret and every actual confirmation/action. This server has
// no approval endpoint; /begin only confirms that the already-confirmed call is still live.
export async function createPhoneBridge({ token, runId, timeoutMs = 120000, browserAction, systemAction }) {
  if (!/^[0-9a-f]{64}$/.test(token) || typeof runId !== 'string' || !runId) throw new Error('Invalid iOS phone bootstrap');
  const secret = Buffer.from(`Bearer ${token}`);
  const pending = new Map();
  let closed = false;
  const reply = (res, status, value) => {
    const bytes = Buffer.from(JSON.stringify(value));
    res.writeHead(status, { 'content-type': 'application/json', 'content-length': bytes.length, 'cache-control': 'no-store' });
    res.end(bytes);
  };
  function finish(id, value) {
    const row = pending.get(id);
    if (!row) return false;
    pending.delete(id);
    clearTimeout(row.timer);
    row.signal.removeEventListener('abort', row.abort);
    row.resolve(value);
    return true;
  }
  const server = http.createServer(async (req, res) => {
    const auth = Buffer.from(req.headers.authorization ?? '');
    if (req.headers.origin !== undefined || auth.length !== secret.length || !timingSafeEqual(auth, secret)) {
      req.resume(); reply(res, 403, { error: 'forbidden' }); return;
    }
    if (req.method !== 'POST') { req.resume(); reply(res, 405, { error: 'method' }); return; }
    try {
      let size = 0;
      const chunks = [];
      for await (const chunk of req) {
        size += chunk.length;
        if (size > (req.url === '/result' ? RESULT_BODY_BYTES : BODY_BYTES)) { reply(res, 413, { error: 'size' }); req.destroy(); return; }
        chunks.push(chunk);
      }
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (body?.runId !== runId || closed) { reply(res, 410, { error: 'retired' }); return; }
      if (req.url === '/claim') {
        const occupied = [...pending.values()].some(row => row.state !== 'pending');
        // With the app away, only what can run with nobody on screen.
        const row = occupied ? undefined : [...pending.values()].find(row =>
          row.state === 'pending' && (body.background !== true || isBrowser(row.request)));
        if (row) row.state = 'claimed';
        reply(res, 200, { request: row?.request ?? null }); return;
      }
      const row = pending.get(body.id);
      if (!row) { reply(res, 410, { error: 'retired' }); return; }
      if (req.url === '/status') { reply(res, 200, { state: row.state }); return; }
      if (req.url === '/begin') {
        if (row.state !== 'claimed') { reply(res, 409, { error: 'already-begun' }); return; }
        row.state = 'executing';
        reply(res, 200, { started: true }); return;
      }
      if (req.url === '/result') {
        const browser = isBrowser(row.request);
        const image = body.image;
        if (!['claimed', 'executing'].includes(row.state) || typeof body.text !== 'string' ||
            Buffer.byteLength(body.text) > (browser ? BROWSER_RESULT_BYTES : isSystem(row.request) ? SYSTEM_RESULT_BYTES : RESULT_BYTES) ||
            typeof body.isError !== 'boolean' ||
            (image !== undefined && (!browser || typeof image !== 'string' || image.length > BROWSER_IMAGE_BYTES))) {
          reply(res, 400, { error: 'result' }); return;
        }
        // A declined prompt may finish in claimed state; success requires /begin.
        if (!body.isError && row.state !== 'executing') { reply(res, 409, { error: 'not-begun' }); return; }
        const value = result(body.text, body.isError);
        if (image !== undefined) value.content.push({ type: 'image', data: image, mimeType: 'image/jpeg' });
        finish(body.id, value);
        reply(res, 200, { accepted: true }); return;
      }
      reply(res, 404, { error: 'route' });
    } catch { if (!res.headersSent) reply(res, 400, { error: 'request' }); }
  });
  server.requestTimeout = 5000;
  server.headersTimeout = 5000;
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return {
    endpoint: Object.freeze({ v: 1, runId, baseUrl: `http://127.0.0.1:${server.address().port}` }),
    call(name, args, execution) {
      if (closed) return Promise.resolve(failure('ERR_IOS_PHONE_RETIRED', '本轮引擎已结束。'));
      let action;
      try {
        if (name.startsWith('browser:')) action = browserAction(name.slice('browser:'.length), args);
        else if (name.startsWith('system:')) action = systemAction(name.slice('system:'.length), args);
        else action = actionFor(name, args);
      } catch (error) { return Promise.resolve(failure(error.code, error.message)); }
      const { signal, callId, agent } = execution;
      if (!signal || signal.aborted || !callId || !agent?.session?.id) return Promise.resolve(failure('ERR_IOS_PHONE_OWNER', '没有仍有效的会话工具调用。'));
      if (pending.size >= 8) return Promise.resolve(failure('ERR_IOS_PHONE_BUSY', '手机动作等待队列已满，请等用户处理。'));
      const id = randomUUID();
      const limit = /-handoff$/.test(action.kind) ? Math.max(timeoutMs, HANDOFF_MS) : timeoutMs;
      const request = Object.freeze({ v: 1, runId, id, owner: { sessionId: agent.session.id, callId },
        action: JSON.parse(JSON.stringify(action)), expiresAt: Date.now() + limit });
      return new Promise(resolve => {
        const abort = () => finish(id, failure('ERR_IOS_PHONE_CANCELLED', '原工具调用已取消；已开始的系统动作可能无法撤销，不要自动重试。'));
        const timer = setTimeout(() => {
          const row = pending.get(id);
          finish(id, failure('ERR_IOS_PHONE_TIMEOUT', row?.state === 'executing'
            ? '系统动作结果未知；请用户核对，不能自动重试。' : '等待用户超时，没有获准执行动作。'));
        }, limit);
        pending.set(id, { request, resolve, signal, abort, timer, state: 'pending' });
        signal.addEventListener('abort', abort, { once: true });
        if (signal.aborted) abort();
      });
    },
    async close() {
      closed = true;
      for (const id of pending.keys()) finish(id, failure('ERR_IOS_PHONE_RETIRED', '本轮引擎已结束；不得重放旧动作。'));
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    },
  };
}
