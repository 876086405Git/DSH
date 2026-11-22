// Owner-only, process-local transport. The phone owns proposals and the durable
// budget ledger. No prompt, output, Session history or credential is persisted.
import { createHash, randomUUID } from 'node:crypto';
import { CompanionError, fields, isObject } from './schema.js';
import { contextId, FULL_PRESET } from './prompt-context.js';

const ROOT = '/dsh-go/v1/companion/auxiliary';
const MAX_BYTES = 65536;
const MAX_RECEIPTS = 4096;
const DEADLINE_MS = 90000;
// The pinned Cordis getTraceable wrapper publishes this original identity.
const raw = value => value?.[Symbol.for('cordis.original')] ?? value;
const failure = (status, code, message) => new CompanionError(status, `auxiliary-${code}`, message);
const text = value => typeof value === 'string' && value.trim() !== '' &&
  !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(value) &&
  [...value].every(c => c.codePointAt(0) < 0xd800 || c.codePointAt(0) > 0xdfff);
const inputKeys = ['v', 'instanceId', 'requestId', 'sessionId', 'provider', 'model', 'kind', 'system', 'input', 'maxTokens'];

function validate(value) {
  if (!fields(value, inputKeys) || value.v !== 1 ||
      !['instanceId', 'requestId', 'sessionId', 'provider', 'model'].every(key => contextId(value[key])) ||
      !['extract', 'consolidate', 'followup'].includes(value.kind) || !text(value.system) || !text(value.input) ||
      !Number.isSafeInteger(value.maxTokens) || value.maxTokens < 1 || value.maxTokens > 3000) {
    throw failure(400, 'invalid-request', 'Invalid companion auxiliary request');
  }
  return Object.fromEntries(inputKeys.map(key => [key, value[key]]));
}

export function errorCode(error) {
  const code = error?.code ?? error?.failure?.code;
  return typeof code === 'string' && /^[a-zA-Z0-9_/-]{1,96}$/u.test(code) ? code : 'AUXILIARY_FAILED';
}

export function usageReceipt(record) {
  const count = key => Number.isSafeInteger(record.finalUsage?.[key]) && record.finalUsage[key] >= 0
    ? record.finalUsage[key] : null;
  return {
    provider: record.provider, model: record.model,
    start_usage: record.startUsage, final_usage: record.finalUsage,
    start_event: record.startUsage === null ? null : 'message_start',
    final_event: record.finalUsage === null ? null : 'message_delta',
    usage_semantics: record.rawUsageAvailable ? 'cumulative' : 'unknown',
    // A final cumulative frame replaces, rather than adds to, the start frame.
    // Missing final fields remain unknown even if the start reported them.
    input_uncached: count('input_tokens'), input_cache_read: count('cache_read_input_tokens'),
    input_cache_write: count('cache_creation_input_tokens'), output_tokens: count('output_tokens'),
    stop_reason: record.stopReason, terminal: record.terminal,
    complete: record.complete, http_status: record.httpStatus,
    // These are runtime-normalized observations, never provider raw JSON.
    // Retain their own event boundaries; unknown raw components stay null.
    ...record.rawUsageAvailable ? {} : {
      runtime_normalized_usage: record.normalizedUsage,
      runtime_normalized_usage_semantics: 'runtime-normalized-events',
      host_adapter_handoff_at_ms: record.handoffAtMs,
      runtime_finish_kind: record.runtimeFinishKind,
    },
  };
}

export function createCompanionAuxiliaryRoutes({ ctx, send, readJson, instanceId = randomUUID(), timeoutMs = DEADLINE_MS } = {}) {
  const receipts = new Map();
  // Full receipts are bounded; exact replay protection lasts for this instance.
  // This smaller index still grows with the number of accepted request IDs.
  const requestDigests = new Map();
  let closed = false, active;

  function admit(req) {
    const connection = ctx?.get('connection');
    if (closed || typeof connection?.admit !== 'function') throw failure(503, 'unavailable', 'Companion auxiliary transport is unavailable');
    const admission = connection.admit(req);
    if (admission?.peer?.principal?.kind !== 'owner') throw failure(admission?.rejection ?? 403, 'forbidden', 'Companion auxiliary transport requires the host owner');
  }

  async function resolve(sessionId, requested, fail = failure) {
    if (!contextId(sessionId)) throw fail(400, 'invalid-request', 'A companion session is required');
    const controller = ctx.get('sessionController'), presets = ctx.get('agentPresets');
    if (typeof controller?.resolveAgent !== 'function' || typeof presets?.presetForSession !== 'function') {
      throw fail(503, 'unavailable', 'Companion session services are unavailable');
    }
    const found = await controller.resolveAgent(sessionId);
    const agent = found?.agent;
    if (!agent || presets.presetForSession(agent.session) !== FULL_PRESET) throw fail(409, 'session-unavailable', 'Open the full companion session before using its model channel');
    const session = agent.session, scope = agent.loopCtx ?? agent.ctx ?? ctx;
    const llm = scope.get('llm');
    const selected = agent.model?.current();
    if (!contextId(selected?.provider) || !contextId(selected?.model)) throw fail(409, 'model-unavailable', 'Select a model in the companion session');
    const guard = () => {
      const current = agent.model?.current();
      if (closed || ctx.get('agents')?.get(sessionId) !== agent || agent.session !== session || agent.dshGoDeleting ||
          (agent.loopCtx ?? agent.ctx ?? ctx) !== scope || raw(scope.get('llm')) !== raw(llm) ||
          presets.presetForSession(session) !== FULL_PRESET || current?.provider !== selected.provider ||
          current?.model !== selected.model || current?.reasoningEffort !== selected.reasoningEffort ||
          requested && (requested.provider !== current.provider || requested.model !== current.model)) {
        throw fail(409, 'selection-changed', 'The companion session or selected model changed');
      }
    };
    guard();
    const capability = typeof llm?.companionAuxiliaryCapability === 'function'
      ? llm.companionAuxiliaryCapability(selected.provider) : undefined;
    return { agent, session, scope, llm, selected, guard, capability };
  }

  function snapshot(record) {
    return { v: 1, instanceId, requestId: record.requestId, phase: record.finished ? 'finished' : 'accepted',
      // An active pre-fetch request can still dispatch later: never prove false.
      dispatched: record.finished ? record.dispatched : record.dispatched === true ? true : null,
      dispatchAtMs: record.dispatchAtMs, ...(record.finish ? { finish: record.finish } : {}) };
  }

  async function execute(req, res, body) {
    if (body.instanceId !== instanceId) {
      const error = failure(409, 'instance-changed', 'The companion bridge restarted; do not resend an uncertain prior request');
      error.dispatched = null;
      throw error;
    }
    const digest = createHash('sha256').update(JSON.stringify(body)).digest('hex');
    const previousDigest = requestDigests.get(body.requestId);
    if (previousDigest !== undefined) {
      const error = failure(409, previousDigest === digest ? 'request-used' : 'request-conflict', 'This auxiliary request ID has already been used');
      error.dispatched = null;
      const previous = receipts.get(body.requestId);
      if (previous) error.receipt = snapshot(previous);
      throw error;
    }
    if (active) throw failure(409, 'busy', 'Another companion auxiliary request is still active');
    // The busy gate proves all retained records have finished; evict only detail.
    if (receipts.size === MAX_RECEIPTS) receipts.delete(receipts.keys().next().value);
    const controller = new AbortController();
    const record = { requestId: body.requestId, provider: body.provider, model: body.model, controller,
      dispatched: false, dispatchAtMs: null, startUsage: null, finalUsage: null, stopReason: null,
      httpStatus: null, complete: false, terminal: 'incomplete', finished: false,
      rawUsageAvailable: false, normalizedUsage: [], handoffAtMs: null, runtimeFinishKind: null };
    requestDigests.set(body.requestId, digest);
    receipts.set(body.requestId, record);
    active = record;
    const abort = () => controller.abort(new Error('Auxiliary client disconnected'));
    req.once('aborted', abort);
    res.once('close', abort);
    const deadline = setTimeout(() => controller.abort(new Error('Auxiliary request deadline')), timeoutMs);
    deadline.unref?.();
    const emit = event => {
      if (!res.destroyed && !res.writableEnded) {
        try { res.write(`${JSON.stringify({ ...event, requestId: body.requestId })}\n`); }
        catch { controller.abort(new Error('Auxiliary response closed')); }
      }
    };
    const observe = event => {
      if (event.type === 'dispatch') {
        record.dispatched = true; record.dispatchAtMs = event.atMs;
        emit({ type: 'dispatch', atMs: event.atMs, boundary: 'fetch-invoked' });
      } else if (event.type === 'handoff') {
        // Entering adapter.stream cannot prove that its transport sent or did
        // not send. The phone already reserved before handing this HTTP over.
        record.dispatched = null; record.handoffAtMs = event.atMs;
      } else if (event.type === 'http') record.httpStatus = event.status;
      else if (event.type === 'stop') record.stopReason = event.stopReason;
      else if (event.type === 'complete') record.complete = true;
      else if (event.type === 'usage') {
        if (!isObject(event.raw) || Buffer.byteLength(JSON.stringify(event.raw)) > MAX_BYTES) throw failure(502, 'invalid-usage', 'Provider usage is not a bounded object');
        const value = structuredClone(event.raw);
        if (event.event === 'message_start') record.startUsage = value;
        else if (event.event === 'message_delta') record.finalUsage = value;
        else throw failure(502, 'invalid-usage', 'Unknown provider usage event');
        emit({ type: 'usage', event: event.event, semantics: 'cumulative', raw: value });
      }
    };
    let failureCode;
    try {
      res.writeHead(200, { 'content-type': 'application/x-ndjson; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
      emit({ type: 'accepted', instanceId, provider: body.provider, model: body.model });
      controller.signal.throwIfAborted();
      const target = await resolve(body.sessionId, body);
      record.agent = target.agent;
      if (!target.capability || typeof target.llm.prepareCompanionAuxiliaryCall !== 'function') throw failure(422, 'unavailable', 'This provider has no callable auxiliary model transport');
      record.rawUsageAvailable = target.capability.rawUsage === 'deepseek-messages-cumulative';
      const guard = () => { controller.signal.throwIfAborted(); target.guard(); };
      guard();
      // DeepSeek's verified extraction path disables thinking. Other models
      // retain the selected effort/default; do not impose an unsupported knob.
      const reasoningEffort = record.rawUsageAvailable ? 'off' : target.selected.reasoningEffort;
      const call = await target.llm.prepareCompanionAuxiliaryCall({ provider: body.provider, model: body.model,
        ...(reasoningEffort === undefined ? {} : { reasoningEffort }), maxTokens: body.maxTokens }, controller.signal, { guard, observe });
      guard();
      if (call.config.provider !== body.provider || call.config.model !== body.model ||
          call.config.maxTokens !== body.maxTokens || reasoningEffort !== undefined && call.config.reasoningEffort !== reasoningEffort) throw failure(409, 'selection-changed', 'The auxiliary request controls changed');
      let outputBytes = 0, finish;
      for await (const chunk of call.stream({ system: body.system, input: body.input })) {
        guard();
        if (chunk.type === 'tool-call-delta' || chunk.type === 'block-start' && chunk.blockType === 'tool-call') {
          throw failure(502, 'tool-output', 'Auxiliary requests cannot execute tools');
        }
        if (chunk.type === 'text-delta' || chunk.type === 'reasoning-delta') {
          outputBytes += Buffer.byteLength(chunk.text);
          if (outputBytes > MAX_BYTES) throw failure(502, 'output-limit', 'Auxiliary output exceeded its byte limit');
          if (chunk.type === 'text-delta') emit({ type: 'text', text: chunk.text });
        }
        if (chunk.type === 'finish') finish = chunk.reason;
        if (chunk.type === 'usage' && !record.rawUsageAvailable) {
          if (!isObject(chunk.usage)) throw failure(502, 'invalid-usage', 'Runtime usage is not an object');
          const value = structuredClone(chunk.usage);
          record.normalizedUsage.push(value);
          if (Buffer.byteLength(JSON.stringify(record.normalizedUsage)) > MAX_BYTES) throw failure(502, 'invalid-usage', 'Runtime usage exceeded its byte limit');
          emit({ type: 'runtime-usage', semantics: 'runtime-normalized', usage: value });
        }
      }
      if (!record.rawUsageAvailable) {
        record.complete = ['stop', 'max-tokens'].includes(finish?.kind) || ['REFUSAL', 'EMPTY_RESPONSE'].includes(finish?.failure?.code);
        record.runtimeFinishKind = finish?.kind ?? null;
      }
      if (record.complete && finish?.kind === 'stop') record.terminal = 'complete';
      else if (record.complete && finish?.kind === 'max-tokens') record.terminal = 'max_tokens';
      else if (record.stopReason === 'refusal' || finish?.failure?.code === 'REFUSAL') record.terminal = 'refusal';
      else if (finish?.kind === 'aborted') record.terminal = 'cancelled';
      else if (finish?.kind === 'error') { record.terminal = 'provider_error'; failureCode = errorCode(finish.failure); }
    } catch (error) {
      failureCode = errorCode(error);
      record.terminal = controller.signal.aborted ? 'cancelled' : record.dispatched === false ? 'preflight_error'
        : record.httpStatus >= 400 ? 'http_error' : failureCode === 'STREAM_CLOSED' ? 'incomplete'
          : ['TRANSPORT', 'TIMEOUT'].includes(failureCode) ? 'network_error' : 'provider_error';
    } finally {
      clearTimeout(deadline);
      req.off('aborted', abort); res.off('close', abort);
      controller.abort();
      record.finished = true;
      record.finish = { type: 'finish', requestId: body.requestId, dispatched: record.dispatched,
        dispatchAtMs: record.dispatchAtMs, terminal: record.terminal, complete: record.complete,
        stopReason: record.stopReason, httpStatus: record.httpStatus, usage: usageReceipt(record),
        ...(failureCode ? { error: { code: failureCode } } : {}) };
      emit(record.finish);
      if (!res.destroyed && !res.writableEnded) res.end();
      delete record.agent; delete record.controller;
      if (active === record) active = undefined;
    }
  }

  // These hooks cancel promptly; the synchronous physical guard remains the
  // final check if a switch/disposal happens during asynchronous preparation.
  const removeDisposed = ctx?.on?.('agent/disposed', ({ agent }) => {
    if (active?.agent === agent) active.controller.abort();
  });
  const removeSelection = ctx?.on?.('session/event', (session, event) => {
    if (event.type === 'model/selection' && active?.agent?.session === session) active.controller.abort();
  });

  return {
    resolve,
    async handle(req, res, path) {
      if (path !== ROOT && !path.startsWith(`${ROOT}/`)) return false;
      try {
        admit(req);
        const url = new URL(req.url, 'http://dsh-go.invalid');
        if (path === ROOT && req.method === 'GET') {
          req.resume();
          const target = await resolve(url.searchParams.get('sessionId'));
          send(res, 200, { v: 1, instanceId, provider: target.selected.provider, model: target.selected.model,
            supported: Boolean(target.capability), ...(target.capability ? { capability: target.capability } : { reason: 'adapter-call-unavailable' }) });
        } else if (path === ROOT && req.method === 'POST') {
          if (String(req.headers['content-type']).split(';', 1)[0].trim().toLowerCase() !== 'application/json') throw failure(415, 'content-type', 'Content-Type must be application/json');
          const body = validate(await readJson(req, MAX_BYTES, true));
          await execute(req, res, body);
        } else if (path.startsWith(`${ROOT}/requests/`) && req.method === 'GET') {
          req.resume();
          const id = decodeURIComponent(path.slice(`${ROOT}/requests/`.length));
          if (url.searchParams.get('instanceId') !== instanceId) {
            const error = failure(409, 'instance-changed', 'The companion bridge instance changed');
            error.dispatched = null; throw error;
          }
          const record = contextId(id) && receipts.get(id);
          if (!record) { const error = failure(404, 'request-unknown', 'No receipt exists in this bridge instance'); error.dispatched = null; throw error; }
          send(res, 200, snapshot(record));
        } else throw failure(path === ROOT ? 405 : 404, 'invalid-request', 'Unknown companion auxiliary route or method');
      } catch (error) {
        req.resume();
        if (!res.destroyed && !res.headersSent) send(res, error instanceof CompanionError ? error.status : 503, {
          error: { code: errorCode(error), message: error instanceof CompanionError ? error.message : 'Companion auxiliary transport is unavailable' },
          dispatched: Object.hasOwn(error, 'dispatched') ? error.dispatched : false,
          ...(error.receipt ? { receipt: error.receipt } : {}),
        });
      }
      return true;
    },
    dispose() {
      closed = true;
      active?.controller.abort();
      if (typeof removeDisposed === 'function') removeDisposed();
      if (typeof removeSelection === 'function') removeSelection();
    },
  };
}
