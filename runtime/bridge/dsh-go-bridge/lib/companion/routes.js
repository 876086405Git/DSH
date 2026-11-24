import { CompanionError, MAX_BODY_BYTES, invalid, ioError } from "./schema.js";
import { createCompanionStore } from "./store.js";
import { cleanPhoneSession, contextId, FULL_PRESET, validatePromptContext } from './prompt-context.js';
import { createRecallCoordinator } from "./recall.js";
import { recallError } from "./recall-schema.js";
import { createCompanionAuxiliaryRoutes } from './auxiliary.js';
import { createCompanionLookupRoutes } from './lookup.js';
import { createSessionToolRoutes } from './session-tools.js';

const ROOT = "/dsh-go/v1/companion";

// Recall requests are flat objects. Reject duplicate keys before a
// JSON parser's last-value-wins rule can make a CAS target ambiguous. Strings
// (including escaped quotes and key-like text in values) are scanned as tokens.
function duplicateTopLevelKey(text) {
  const seen = new Set();
  let depth = 0;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '"') {
      const start = i++;
      for (; i < text.length && text[i] !== '"'; i++) if (text[i] === '\\') i++;
      let next = i + 1;
      while (/\s/.test(text[next] ?? '') && next < text.length) next++;
      if (depth === 1 && text[next] === ':') {
        const key = JSON.parse(text.slice(start, i + 1));
        if (seen.has(key)) return true;
        seen.add(key);
      }
    } else if (text[i] === '{' || text[i] === '[') depth++;
    else if (text[i] === '}' || text[i] === ']') depth--;
  }
  return false;
}

function readJson(req, maxBytes = MAX_BODY_BYTES, strictKeys = false) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    const cleanup = () => {
      req.off("data", data);
      req.off("end", end);
      req.off("error", fail);
      req.off("aborted", abort);
    };
    const fail = () => { cleanup(); reject(invalid()); };
    const abort = () => {
      cleanup();
      // IncomingMessage emits ECONNRESET after 'aborted'; keep that expected error handled.
      req.once("error", () => {});
      reject(invalid());
    };
    const data = (chunk) => {
      size += chunk.length;
      if (size <= maxBytes) chunks.push(chunk);
    };
    const end = () => {
      cleanup();
      if (size > maxBytes) return reject(new CompanionError(413, "too-large", "Companion request body is too large"));
      try {
        const text = new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks));
        const parsed = JSON.parse(text);
        if (strictKeys && duplicateTopLevelKey(text)) throw invalid();
        resolve(parsed);
      }
      catch { reject(invalid()); }
    };
    if (req.aborted || req.destroyed) return reject(invalid());
    req.on("data", data);
    req.on("end", end);
    req.on("error", fail);
    req.on("aborted", abort);
  });
}

// Called only after the bridge's existing connection.requestRejection guard.
// Store construction does no I/O, including on hosts that never open this page.
export function createCompanionRoutes({ send, store = createCompanionStore(), signals, ctx, promptContext,
  recall = createRecallCoordinator({ store, promptContext }) }) {
  let tasks, sessionTools;
  const auxiliary = createCompanionAuxiliaryRoutes({ ctx, send, readJson });
  const lookup = createCompanionLookupRoutes({ ctx, send, readJson, resolve: auxiliary.resolve });
  function usageRoute(req) {
    const connection = ctx?.get('connection');
    if (typeof connection?.admit !== 'function' || typeof promptContext?.usageSnapshot !== 'function') {
      throw new CompanionError(503, 'usage-unavailable', 'Companion usage observations are unavailable');
    }
    const admission = connection.admit(req);
    if (admission?.peer?.principal?.kind !== 'owner') {
      throw new CompanionError(admission?.rejection ?? 403, 'usage-forbidden', 'Companion usage observations require the host owner');
    }
    if (req.method !== 'GET') throw new CompanionError(405, 'usage-invalid-request', 'Use GET');
    const params = new URL(req.url, 'http://dsh-go.invalid').searchParams;
    const names = ['instanceId', 'sessionId', 'requestId'];
    if ([...params.keys()].some(name => !names.includes(name)) ||
        names.some(name => params.getAll(name).length !== 1 || !contextId(params.get(name)))) {
      throw new CompanionError(400, 'usage-invalid-request', 'A bridge instance, session and original request are required');
    }
    // Historical accounting remains readable after Agent retirement. Do not
    // resolve a new Agent with the same id to authenticate an old receipt.
    return promptContext.usageSnapshot(Object.fromEntries(names.map(name => [name, params.get(name)])));
  }
  async function promptRoute(req, restoringModel) {
    const connection = ctx?.get('connection');
    if (!promptContext || typeof connection?.admit !== 'function') {
      throw new CompanionError(503, 'unavailable', 'Companion prompt context is unavailable');
    }
    const admission = connection.admit(req);
    if (admission?.peer?.principal?.kind !== 'owner') {
      throw new CompanionError(admission?.rejection ?? 403, 'forbidden', 'Companion prompt context requires the host owner');
    }
    if (req.method !== 'POST' && (req.method !== 'GET' || restoringModel)) {
      throw new CompanionError(405, 'invalid-request', 'Use GET or POST');
    }
    let body;
    if (req.method === 'POST') {
      if (String(req.headers['content-type']).split(';', 1)[0].trim().toLowerCase() !== 'application/json') {
        throw new CompanionError(415, 'content-type', 'Content-Type must be application/json');
      }
      if (restoringModel) {
        body = await readJson(req);
        const model = body?.model;
        if (!model || !contextId(model.provider) || !contextId(model.model) ||
            (model.reasoningEffort !== undefined && !contextId(model.reasoningEffort))) throw invalid();
      } else {
        body = validatePromptContext(await readJson(req, 1024 * 1024));
      }
    }
    const sessionId = body?.sessionId ?? new URL(req.url, 'http://dsh-go.invalid').searchParams.get('sessionId');
    if (!contextId(sessionId)) throw invalid();
    const controller = ctx.get('sessionController'), presets = ctx.get('agentPresets');
    if (typeof controller?.resolveAgent !== 'function' || typeof presets?.presetForSession !== 'function') {
      throw new CompanionError(503, 'unavailable', 'Companion session services are unavailable');
    }
    const found = await controller.resolveAgent(sessionId);
    if (!found?.agent) throw new CompanionError(found?.error?.code === 'session/not-found' ? 404 : 409,
      'session-unavailable', 'Open the companion session before updating its context');
    if (presets.presetForSession(found.agent.session) !== FULL_PRESET) {
      throw new CompanionError(409, 'wrong-session', 'Context is only available for the full companion preset');
    }
    const session = found.agent.session;
    const current = () => ctx.get('agents')?.get(sessionId) === found.agent &&
      found.agent.session === session && presets.presetForSession(session) === FULL_PRESET;
    if (!current()) throw new CompanionError(409, 'session-unavailable', 'Companion session changed; retry after synchronization');
    if (restoringModel) {
      const { agent } = found;
      const llm = (agent.loopCtx ?? agent.ctx)?.get('llm');
      const selected = agent.model?.current();
      const { provider, model, reasoningEffort } = body.model;
      if (!cleanPhoneSession(session) || typeof llm?.resolveCallConfig !== 'function' ||
          typeof agent.model?.select !== 'function') {
        throw new CompanionError(409, 'model-restore-unavailable', 'Restore requires a clean companion session');
      }
      if (selected?.provider !== provider || selected?.model !== model || selected?.reasoningEffort !== reasoningEffort) {
        // Preserve an intervening explicit selection, even in a blank session.
        const seq = session.seq;
        if (Array.from({length: seq}, (_, i) => session.eventAt(i)).some(e => e?.type === 'model/selection')) {
          throw new CompanionError(409, 'selection-changed', 'The session already has a different model selection');
        }
        const restore = { provider, model, ...(reasoningEffort === undefined ? {} : { reasoningEffort }) };
        try { await llm.resolveCallConfig(restore); }
        catch { throw new CompanionError(409, 'model-unavailable', 'The previous companion model is unavailable'); }
        if (!current() || session.seq !== seq) throw new CompanionError(409, 'selection-changed', 'Companion session changed');
        agent.model.select(restore);
      }
      return { sessionId, model: agent.model.current() };
    }
    if (!body) return promptContext.info(found.agent);
    const memoryTicket = promptContext.captureMemory(found.agent);
    const recalled = body.query === undefined || !memoryTicket.allowed
      ? [] : (await store.getContext({ query: body.query, limit: 6 })).memories;
    // Resolve/recall awaited: the host may have retired or switched the Agent.
    if (!current()) {
      throw new CompanionError(409, 'session-unavailable', 'Companion session changed; retry after synchronization');
    }
    // time-context measures the preceding model-visible event (also tools or
    // assistant replies). Read the actual human baseline for the distinct gap.
    let lastHumanAt;
    for (let seq = found.agent.session.seq - 1; seq >= 0; seq--) {
      const event = found.agent.session.eventAt(seq);
      if (event?.type === 'user/message' && event.data?.source?.kind === 'user' &&
          event.data.source.principal === undefined) { lastHumanAt = event.time; break; }
    }
    return promptContext.prepare(found.agent, body, recalled, lastHumanAt, memoryTicket);
  }
  const routes = new Map([
    [ROOT, { method: "GET", run: () => store.getSnapshot() }],
    [`${ROOT}/events`, { method: "POST", run: (body) => store.event(body) }],
    [`${ROOT}/memories/delete`, { method: "POST", run: (body) => recall.mutateMemory("deleteMemory", body) }],
    [`${ROOT}/memories/clear`, { method: "POST", run: (body) => recall.mutateMemory("clearMemories", body) }],
    [`${ROOT}/context`, { method: "POST", run: (body) => store.getContext(body) }],
    [`${ROOT}/export`, { method: "GET", run: () => store.exportData() }],
    [`${ROOT}/recall`, { method: "GET", run: () => recall.capability() }],
    [`${ROOT}/recall/bind`, { method: "POST", strictKeys: true, run: (body) => recall.bind(body) }],
    [`${ROOT}/recall/revoke`, { method: "POST", strictKeys: true, run: (body) => recall.revoke(body) }],
  ]);
  return {
    async handle(req, res, path) {
      if (path !== ROOT && !path.startsWith(`${ROOT}/`)) return false;
      if (path === `${ROOT}/tasks` || path.startsWith(`${ROOT}/tasks/`)) {
        try {
          tasks ??= import('./task-routes.js').then(module => module.createCompanionTaskRoutes({ctx, send, readJson}));
          return await (await tasks).handle(req, res, path);
        } catch {
          req.resume();
          send(res, 503, {error: {code: 'companion/task-unavailable', message: 'Task service is unavailable'}});
          return true;
        }
      }
      if (path.startsWith(ROOT + '/session-tools/')) {
        sessionTools ??= createSessionToolRoutes({ ctx, readJson, send });
        if (await sessionTools.handle(req, res, path)) return true;
      }
      if (await auxiliary.handle(req, res, path)) return true;
      if (await lookup.handle(req, res, path)) return true;
      if (signals && await signals.handle(req, res, path, send)) return true;
      const isRecall = path === `${ROOT}/recall` || path.startsWith(`${ROOT}/recall/`);
      try {
        if (path === `${ROOT}/usage`) {
          const result = usageRoute(req);
          req.resume();
          if (!res.destroyed) send(res, 200, result);
          return true;
        }
        if (path === `${ROOT}/prompt-context` || path === `${ROOT}/restore-model`) {
          const result = await promptRoute(req, path === `${ROOT}/restore-model`);
          req.resume();
          if (!res.destroyed) send(res, 200, result);
          return true;
        }
        const statusMatch = path.match(/^\/dsh-go\/v1\/companion\/recall\/bindings\/([^/]+)$/);
        const route = path === `${ROOT}/memories`
          ? (req.method === "GET" ? { method: "GET", run: () => store.getMemories() }
            : { method: "POST", run: (body) => recall.mutateMemory("upsertMemory", body) })
          : statusMatch ? { method: "GET", run: () => recall.status(statusMatch[1]) } : routes.get(path);
        if (route === undefined) {
          req.resume();
          throw new CompanionError(404, "not-found", "Companion route not found");
        }
        if (req.method !== route.method) {
          req.resume();
          throw new CompanionError(405, "invalid-request", "Method not allowed");
        }
        let body;
        if (route.method === "POST") {
          if (String(req.headers["content-type"]).split(";", 1)[0].trim().toLowerCase() !== "application/json") {
            req.resume();
            throw new CompanionError(415, "content-type", "Content-Type must be application/json");
          }
          body = await readJson(req, route.maxBytes, route.strictKeys);
        } else {
          req.resume();
        }
        const result = await route.run(body);
        if (!res.destroyed) send(res, 200, result);
      } catch (error) {
        req.resume();
        let failure = error instanceof CompanionError ? error : isRecall
          ? recallError(503, "adapter-unavailable", "Automatic recall is unavailable on this host") : ioError();
        if (isRecall && !failure.code.startsWith("companion/recall-")) {
          failure = recallError(failure.status, failure.code.slice("companion/".length), failure.message);
        }
        if (!res.destroyed) send(res, failure.status, { error: { code: failure.code, message: failure.message } });
      }
      return true;
    },
    dispose() { lookup.dispose(); auxiliary.dispose(); return sessionTools?.dispose(); },
  };
}
