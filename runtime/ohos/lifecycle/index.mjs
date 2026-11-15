import { randomUUID } from 'node:crypto';
import { realpath } from 'node:fs/promises';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { STATUS_CODES } from 'node:http';

export const name = 'dsh-go-ohos-lifecycle';
export const inject = ['sessions', 'sessionPersistence', 'agents', 'subprocess'];
const lifecycleSymbol = Symbol.for('dsh.go.ohos.lifecycle');
const simulationSymbol = Symbol.for('dsh.go.ohos.sim');
const publicationSymbol = Symbol.for('dsh.go.ohos.publication');
const fail = (code, message, status = 409) => Object.assign(new Error(message), { code, status });
const validSession = value => typeof value === 'string' && value.length > 0 && value.length <= 4096 && !value.includes('\0');
const inside = (root, path) => { const suffix = relative(root, path); return suffix === '' || (!suffix.startsWith('..' + sep) && suffix !== '..' && !isAbsolute(suffix)); };

function readJson(req) {
  if ((req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase() !== 'application/json') throw fail('ERR_OHOS_LIFECYCLE_REQUEST', 'Expected application/json', 415);
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0, settled = false;
    const finish = (error, value) => {
      if (settled) return; settled = true; clearTimeout(timer);
      req.off('data', data); req.off('end', end); req.off('error', broken); req.off('aborted', aborted);
      if (error) { req.resume(); reject(error); } else resolve(value);
    };
    const data = chunk => {
      size += chunk.length;
      if (size > 8192) { finish(fail('ERR_OHOS_LIFECYCLE_REQUEST', 'Control body is too large', 413)); return; }
      chunks.push(chunk);
    };
    const end = () => {
      try {
        const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks)));
        if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('not an object');
        finish(undefined, value);
      } catch { finish(fail('ERR_OHOS_LIFECYCLE_REQUEST', 'Invalid JSON control object', 400)); }
    };
    const broken = () => finish(fail('ERR_OHOS_LIFECYCLE_REQUEST', 'Request stream failed', 400));
    const aborted = () => finish(fail('ERR_OHOS_LIFECYCLE_REQUEST', 'Request was aborted', 400));
    const timer = setTimeout(() => finish(fail('ERR_OHOS_LIFECYCLE_REQUEST', 'Request body timed out', 408)), 10_000);
    req.on('data', data); req.on('end', end); req.on('error', broken); req.on('aborted', aborted);
  });
}

/** Exact authenticated control routes; status queries never execute recovery. */
export function registerLifecycleRoutes(ctx, coordinator, transport) {
  const handler = resultRoute => async (req, res) => {
    const headers = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'content-type': 'application/json; charset=utf-8' };
    const reply = (status, body) => {
      if (status === 408 || status === 413) headers.connection = 'close';
      res.writeHead(status, headers); res.end(req.method === 'HEAD' ? undefined : JSON.stringify(body));
    };
    try {
      const connection = ctx.get('connection');
      const rejected = connection === undefined ? 503 : connection.requestRejection(req);
      if (rejected !== undefined) { reply(rejected, { error: STATUS_CODES[rejected] ?? 'Request rejected' }); return; }
      const allowed = resultRoute ? ['GET'] : ['GET', 'POST'];
      if (!allowed.includes(req.method)) { headers.allow = allowed.join(', '); reply(405, { error: 'Method Not Allowed' }); return; }
      const url = new URL(req.url, 'http://localhost');
      if (req.method === 'GET') {
        const sessionId = url.searchParams.get('sessionId') ?? undefined;
        if (url.searchParams.getAll('sessionId').length > 1 || (sessionId !== undefined && !validSession(sessionId))) throw fail('ERR_OHOS_LIFECYCLE_REQUEST', 'Invalid session identity', 400);
        if (resultRoute) {
          const sequence = url.searchParams.get('callSeq');
          if (!sessionId || !/^(0|[1-9][0-9]*)$/.test(sequence ?? '') || !Number.isSafeInteger(Number(sequence))
              || url.searchParams.getAll('callSeq').length !== 1 || [...url.searchParams.keys()].some(key => !['sessionId', 'callSeq'].includes(key))) {
            throw fail('ERR_OHOS_LIFECYCLE_REQUEST', 'Result needs one sessionId and callSeq', 400);
          }
          reply(200, await coordinator.result(sessionId, Number(sequence)));
        } else {
          if ([...url.searchParams.keys()].some(key => key !== 'sessionId')) throw fail('ERR_OHOS_LIFECYCLE_REQUEST', 'Unknown status query field', 400);
          reply(200, { ...coordinator.status(sessionId), transport: transport.status() });
        }
        return;
      }
      if (url.search) throw fail('ERR_OHOS_LIFECYCLE_REQUEST', 'Control arguments belong in the JSON body', 400);
      const body = await readJson(req);
      if (body.operation === 'host') {
        if (Object.keys(body).some(key => !['operation', 'revision', 'foreground', 'computePermission'].includes(key)) ||
            !Number.isSafeInteger(body.revision) || body.revision < 1 || typeof body.foreground !== 'boolean' ||
            !['granted', 'denied', 'unknown'].includes(body.computePermission)) {
          throw fail('ERR_OHOS_LIFECYCLE_REQUEST', 'Invalid host observation', 400);
        }
        const state = await coordinator.observeHost({ revision: body.revision, foreground: body.foreground,
          computePermission: body.computePermission });
        // Host acknowledgements stay bounded even after thousands of calls.
        const { v, host, closed, blocked, paused, confirmedPause, controlVersion } = state;
        reply(200, { v, host, closed, blocked, paused, confirmedPause, controlVersion });
        return;
      }
      if (Object.keys(body).some(key => !['operation', 'sessionId'].includes(key))) throw fail('ERR_OHOS_LIFECYCLE_REQUEST', 'Unknown control field', 400);
      let status;
      if (['pause', 'resume'].includes(body.operation)) {
        if (body.sessionId !== undefined) throw fail('ERR_OHOS_LIFECYCLE_REQUEST', 'Pause and resume control this engine', 400);
        status = await coordinator[body.operation]();
      } else if (['cancel', 'acknowledgeUnknown'].includes(body.operation) && validSession(body.sessionId)) {
        status = await coordinator[body.operation](body.sessionId);
      } else throw fail('ERR_OHOS_LIFECYCLE_REQUEST', 'Unknown operation or missing session identity', 400);
      reply(200, { ...status, transport: transport.status() });
    } catch (error) {
      const status = error.code === 'ERR_OHOS_LIFECYCLE_RESULT_ABSENT' ? 404 : error.status ?? (error instanceof TypeError ? 400 : 409);
      // Result data stays in the authenticated result route. Raw causes can
      // contain paths/credentials and never enter control errors or logs.
      reply(status, { error: { code: typeof error.code === 'string' ? error.code : 'ERR_OHOS_LIFECYCLE_CONTROL',
        message: STATUS_CODES[status] ?? 'Lifecycle operation failed' } });
    }
  };
  for (const [path, result] of [['/dsh-go/v1/lifecycle', false], ['/dsh-go/v1/lifecycle/result', true]]) {
    ctx.effect(() => ctx.webServer.register({ kind: 'exact', path, handler: handler(result) }), 'ohos lifecycle ' + path);
  }
}

export async function apply(ctx, config = {}) {
  if (process.platform !== 'openharmony' && globalThis[simulationSymbol] !== true) return;
  if (Object.hasOwn(globalThis, lifecycleSymbol)) throw fail('ERR_OHOS_LIFECYCLE_DUPLICATE', 'One lifecycle owner is allowed for this engine process');
  const [{ ohosLifecycleProtocol }, { ohosLifecycleBudgetProtocol }, { openBoundaryJournal }, { BoundaryCoordinator }, { createLifecycleTransport }] = await Promise.all([
    import('@deepseek-ai/dsh-agent-loop'), import('@deepseek-ai/dsh-timeout'), import('./journal.mjs'), import('./coordinator.mjs'), import('./transport.mjs'),
  ]);
  if (ohosLifecycleProtocol !== 1 || ohosLifecycleBudgetProtocol !== 1) throw fail('ERR_OHOS_LIFECYCLE_PROTOCOL', 'Pinned engine scheduler and timeout lifecycle seams are required');
  const publication = globalThis[publicationSymbol];
  if (publication?.protocolVersion !== 1) throw fail('ERR_OHOS_LIFECYCLE_PUBLICATION', 'OH publication startup must precede lifecycle setup');
  if (Object.keys(config).some(key => key !== 'directory')) throw new TypeError('Unknown lifecycle configuration key');
  const home = process.env.DSH_HOME;
  if (typeof home !== 'string' || !isAbsolute(home) || home.includes('\0')) throw new TypeError('An explicit private DSH_HOME is required');
  const canonicalHome = await realpath(home);
  const directory = config.directory ?? join(canonicalHome, 'ohos-lifecycle');
  if (typeof directory !== 'string' || !isAbsolute(directory) || resolve(directory) !== directory || directory.includes('\0')) throw new TypeError('Lifecycle directory must be an absolute canonical private path');
  const roots = ctx.subprocess.backend?.roots;
  if (!Array.isArray(roots) || !roots.length || roots.some(root => typeof root !== 'string' || !isAbsolute(root))) throw fail('ERR_OHOS_LIFECYCLE_PRIVATE_ROOT', 'OH workspace roots must be known before opening private results');
  if (roots.some(root => inside(root, directory))) throw fail('ERR_OHOS_LIFECYCLE_PRIVATE_ROOT', 'Lifecycle logs cannot be stored inside any tool-mounted root');
  const journal = await openBoundaryJournal({ directory, lockExclusive: process._linkedBinding('dsh_ohos_publication').lockExclusive });
  const transport = createLifecycleTransport();
  const coordinator = new BoundaryCoordinator({ journal, bootId: publication.ownerId ?? randomUUID(),
    flushSession: session => ctx.sessions.flush(session),
    async readEvents(id, from = 0, to) {
      const handle = await ctx.sessionPersistence.open(id, 'read');
      try { return (await handle.read(from, to)).events; }
      finally { await handle.close(); }
    },
    resolveAgent: id => ctx.agents.get(id), revalidateTransport: () => transport.revalidate() });
  // After teardown a patched scheduler sees a closed owner and fails closed;
  // it must not fall back to unjournaled dispatch because a plugin unloaded.
  Object.defineProperty(globalThis, lifecycleSymbol, { value: coordinator, configurable: false, writable: false });
  ctx.provide('ohosLifecycle', coordinator);
  ctx.effect(() => async () => { await coordinator.close(); transport.close(); }, 'ohos lifecycle joined shutdown');
  ctx.inject(['webServer'], webCtx => registerLifecycleRoutes(webCtx, coordinator, transport));
}
