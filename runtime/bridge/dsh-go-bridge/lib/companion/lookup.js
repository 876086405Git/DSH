// The phone owns durable task/revision/attempts. This bridge keeps only this
// process's receipt metadata and received fences; it never owns a second task DB.
import { createHash, randomUUID } from 'node:crypto';
import { CompanionError, fields, isObject } from './schema.js';
import { contextId } from './prompt-context.js';
import { errorCode, usageReceipt } from './auxiliary.js';
import { lookupAnswerSystem } from './lookup-answer.js';
import { estimateLookupInputTokens } from './lookup-input.js';

const ROOT = '/dsh-go/v1/companion/lookup';
const MAX_BYTES = 65536, MAX_RECORDS = 4096;
const raw = value => value?.[Symbol.for('cordis.original')] ?? value;
const failure = (status, code, message) => new CompanionError(status, 'lookup-' + code, message);
const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const text = value => typeof value === 'string' && value.trim() !== '' && value.isWellFormed() &&
  !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(value);
const time = value => Number.isSafeInteger(value) && value >= 0;
const envelope = ['v', 'instanceId', 'requestId', 'sessionId', 'taskId', 'taskRev', 'deadlineAtMs', 'provider', 'model', 'kind', 'task', 'payload'];
const fenceKeys = ['v', 'instanceId', 'sessionId', 'taskId', 'taskRev', 'cancelled', 'deadlineAtMs'];

function validIdentity(body) {
  return body.v === 1 && ['instanceId', 'sessionId', 'taskId'].every(key => contextId(body[key])) &&
    Number.isSafeInteger(body.taskRev) && body.taskRev > 0 && time(body.deadlineAtMs);
}
function validUrl(value) {
  if (!text(value) || value.length > 8192) return false;
  try { const url = new URL(value); return ['http:', 'https:'].includes(url.protocol) && url.hostname !== '' && !url.username && !url.password; }
  catch { return false; }
}
function validate(body) {
  if (!fields(body, envelope) || !validIdentity(body) || !['requestId', 'provider', 'model'].every(key => contextId(body[key])) ||
      !fields(body.task, ['placeName', 'city', 'localDate', 'zoneId', 'question']) ||
      !['placeName', 'localDate', 'zoneId', 'question'].every(key => text(body.task[key])) ||
      body.task.city !== null && !text(body.task.city) ||
      !/^\d{4}-\d{2}-\d{2}$/u.test(body.task.localDate) ||
      !Number.isFinite(Date.parse(body.task.localDate + 'T00:00:00Z')) ||
      new Date(body.task.localDate + 'T00:00:00Z').toISOString().slice(0, 10) !== body.task.localDate) {
    throw failure(400, 'invalid-request', 'Invalid public lookup task');
  }
  const payload = body.payload;
  if (body.kind === 'search' && fields(payload, ['query']) && text(payload.query) && [...payload.query].length <= 128) return body;
  if (body.kind === 'fetch' && fields(payload, ['url']) && validUrl(payload.url)) return body;
  if (body.kind === 'answer' && fields(payload, ['sources']) && Array.isArray(payload.sources) &&
      payload.sources.length > 0 && payload.sources.length <= 2 &&
      new Set(payload.sources.map(source => source?.fetchRequestId)).size === payload.sources.length &&
      payload.sources.every(source => fields(source, ['fetchRequestId', 'url', 'title', 'content', 'fetchedAtMs']) &&
        contextId(source.fetchRequestId) && validUrl(source.url) && typeof source.title === 'string' &&
        source.title.isWellFormed() && text(source.content) && time(source.fetchedAtMs))) return body;
  throw failure(400, 'invalid-request', 'Invalid public lookup step');
}

export function createCompanionLookupRoutes({ ctx, send, readJson, resolve, instanceId = randomUUID(), now = Date.now } = {}) {
  const receipts = new Map(), fences = new Map();
  let closed = false, active;
  function admit(req) {
    const connection = ctx?.get('connection');
    if (closed || typeof connection?.admit !== 'function') throw failure(503, 'unavailable', 'Public lookup is unavailable');
    const admission = connection.admit(req);
    if (admission?.peer?.principal?.kind !== 'owner') throw failure(admission?.rejection ?? 403, 'forbidden', 'Public lookup requires the host owner');
  }
  function instance(value) {
    if (value !== instanceId) {
      const error = failure(409, 'instance-changed', 'The prior host instance cannot be verified');
      error.dispatched = null; throw error;
    }
  }
  function receiveFence(body, cancelled, taskDigest) {
    const previous = fences.get(body.taskId);
    if (previous && (previous.sessionId !== body.sessionId || previous.taskRev > body.taskRev ||
        previous.taskRev === body.taskRev && (previous.deadlineAtMs !== body.deadlineAtMs ||
          previous.cancelled && !cancelled || taskDigest && previous.taskDigest && previous.taskDigest !== taskDigest))) {
      throw failure(409, 'task-conflict', 'The public lookup task or revision changed');
    }
    if (!previous && fences.size >= MAX_RECORDS) throw failure(503, 'capacity', 'Public lookup receipt capacity is exhausted');
    const fence = previous?.taskRev === body.taskRev ? previous : {
      sessionId: body.sessionId, taskRev: body.taskRev, deadlineAtMs: body.deadlineAtMs, cancelled: false,
    };
    fence.cancelled ||= cancelled;
    if (taskDigest) fence.taskDigest = taskDigest;
    fences.set(body.taskId, fence);
    if (active?.taskId === body.taskId && (active.taskRev < fence.taskRev || fence.cancelled)) {
      active.controller.abort(new Error('A newer task fence arrived'));
    }
    return fence;
  }
  function snapshot(record) {
    return { v: 1, instanceId, requestId: record.requestId, taskId: record.taskId, taskRev: record.taskRev,
      phase: record.finished ? 'finished' : 'accepted', bodyRetained: false,
      dispatched: record.finished ? record.dispatched : record.dispatched === true ? true : null,
      dispatchAtMs: record.dispatchAtMs, ...(record.finish ? { finish: record.finish } : {}) };
  }
  async function execute(req, res, body) {
    instance(body.instanceId);
    const requestDigest = digest(body), previous = receipts.get(body.requestId);
    if (previous) {
      const error = failure(409, previous.digest === requestDigest ? 'request-used' : 'request-conflict', 'This lookup request ID was already used');
      error.dispatched = null; error.receipt = snapshot(previous); throw error;
    }
    const fence = receiveFence(body, false, digest(body.task));
    if (now() >= body.deadlineAtMs) throw failure(409, 'expired', 'The original lookup deadline has passed');
    if (active) throw failure(409, 'busy', 'Another public lookup step is active');
    if (receipts.size >= MAX_RECORDS) throw failure(503, 'capacity', 'Public lookup receipt capacity is exhausted');
    const controller = new AbortController();
    const record = { requestId: body.requestId, taskId: body.taskId, taskRev: body.taskRev, kind: body.kind,
      digest: requestDigest, controller, provider: body.provider, model: body.model,
      dispatched: false, dispatchAtMs: null, httpStatus: null, complete: false, terminal: 'incomplete', finished: false,
      startUsage: null, finalUsage: null, stopReason: null, rawUsageAvailable: false,
      normalizedUsage: [], handoffAtMs: null, runtimeFinishKind: null, text: '', result: null, inputBudget: null };
    receipts.set(body.requestId, record); active = record;
    const abort = () => controller.abort(new Error('Public lookup HTTP closed'));
    req.once('aborted', abort); res.once('close', abort);
    const timer = setTimeout(() => controller.abort(new Error('Original public lookup deadline')),
      Math.min(body.deadlineAtMs - now(), body.kind === 'answer' ? 90000 : 120000));
    timer.unref?.();
    const emit = event => {
      if (!res.destroyed && !res.writableEnded) {
        try { res.write(JSON.stringify({ ...event, requestId: body.requestId, taskId: body.taskId, taskRev: body.taskRev }) + '\n'); }
        catch { controller.abort(new Error('Public lookup response closed')); }
      }
    };
    let failureCode;
    try {
      res.writeHead(200, { 'content-type': 'application/x-ndjson; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
      emit({ type: 'accepted', instanceId, provider: body.provider, model: body.model });
      const target = await resolve(body.sessionId, body, failure);
      record.agent = target.agent;
      const web = target.scope.get('web');
      const guard = () => {
        controller.signal.throwIfAborted(); admit(req); target.guard();
        if (fences.get(body.taskId) !== fence || fence.cancelled || now() >= body.deadlineAtMs) throw failure(409, 'task-changed', 'The task fence or original deadline changed');
        if (body.kind !== 'answer' && raw(target.scope.get('web')) !== raw(web)) throw failure(409, 'unavailable', 'The direct lookup service changed');
      };
      const observe = event => {
        if (event.type === 'dispatch') {
          record.dispatched = true; record.dispatchAtMs = event.atMs;
          emit({ type: 'dispatch', boundary: 'fetch-invoked', atMs: event.atMs });
        } else if (event.type === 'http') {
          record.httpStatus = event.status; emit({ type: 'http', status: event.status, atMs: event.atMs ?? now() });
        } else if (event.type === 'provider-result') {
          record.complete = true;
          // Stream actual API JSON once; the host receipt never keeps page bodies.
          emit({ type: 'provider-result', raw: event.raw });
        } else if (event.type === 'handoff') {
          record.dispatched = null; record.handoffAtMs = event.atMs;
        } else if (event.type === 'usage') {
          if (!isObject(event.raw) || Buffer.byteLength(JSON.stringify(event.raw)) > MAX_BYTES) throw failure(502, 'invalid-usage', 'Provider usage is not a bounded object');
          const value = structuredClone(event.raw);
          if (event.event === 'message_start') record.startUsage = value;
          else if (event.event === 'message_delta') record.finalUsage = value;
          else throw failure(502, 'invalid-usage', 'Unknown provider usage event');
          emit({ type: 'usage', event: event.event, semantics: 'cumulative', raw: value });
        } else if (event.type === 'stop') record.stopReason = event.stopReason;
        else if (event.type === 'complete') record.complete = true;
      };
      guard();
      if (body.kind !== 'answer') {
        if (typeof web?.prepareCompanionLookupCall !== 'function') throw failure(503, 'unavailable', 'This host has no direct lookup hook');
        const call = web.prepareCompanionLookupCall({ kind: body.kind, llmProvider: body.provider, ...body.payload }, controller.signal, { guard, observe });
        const result = await call.invoke();
        record.result = body.kind === 'search' ? { sources: result.sources.slice(0, 5).map(source => ({
          url: source.url.slice(0, 8192), ...(source.title ? { title: [...source.title].slice(0, 300).join('') } : {}),
          ...(source.snippet ? { snippet: [...source.snippet].slice(0, 300).join('') } : {}),
        })), metadataOnly: true } : { url: result.url };
        record.terminal = 'complete';
      } else {
        if (!target.capability || typeof target.llm.prepareCompanionAuxiliaryCall !== 'function') throw failure(422, 'unavailable', 'The selected model has no task transport');
        record.rawUsageAvailable = target.capability.rawUsage === 'deepseek-messages-cumulative';
        const reasoningEffort = record.rawUsageAvailable ? 'off' : target.selected.reasoningEffort;
        const config = { provider: body.provider, model: body.model, maxTokens: 800,
          ...(reasoningEffort === undefined ? {} : { reasoningEffort }) };
        let call;
        const checkRequest = (input, scope) => {
          guard();
          record.inputBudget = { estimatedTokens: estimateLookupInputTokens(input), outputReserve: 800,
            contextWindow: call.contextWindow, scope, estimator: 'companion-heuristic-v1' };
          return record.inputBudget.estimatedTokens <= 12000 && (call.contextWindow === null ||
            record.inputBudget.estimatedTokens + 800 <= call.contextWindow);
        };
        call = await target.llm.prepareCompanionAuxiliaryCall(config, controller.signal, { guard, observe, checkRequest });
        guard();
        if (!Object.hasOwn(call, 'contextWindow')) throw failure(422, 'unavailable', 'This host cannot check the prepared lookup input');
        if (call.config.provider !== body.provider || call.config.model !== body.model || call.config.maxTokens !== 800 ||
            reasoningEffort !== undefined && call.config.reasoningEffort !== reasoningEffort) throw failure(409, 'selection-changed', 'The answer model controls changed');
        let finish, outputBytes = 0;
        for await (const chunk of call.stream({ system: lookupAnswerSystem, input: JSON.stringify({ task: body.task, sources: body.payload.sources }) })) {
          guard();
          if (chunk.type === 'tool-call-delta' || chunk.type === 'block-start' && chunk.blockType === 'tool-call') throw failure(502, 'tool-output', 'A lookup answer cannot execute tools');
          if (chunk.type === 'text-delta' || chunk.type === 'reasoning-delta') {
            outputBytes += Buffer.byteLength(chunk.text);
            if (outputBytes > MAX_BYTES) throw failure(502, 'output-limit', 'Lookup answer exceeded its byte bound');
            if (chunk.type === 'text-delta') { record.text += chunk.text; emit({ type: 'text', text: chunk.text }); }
          }
          if (chunk.type === 'finish') finish = chunk.reason;
          if (chunk.type === 'usage' && !record.rawUsageAvailable) {
            if (!isObject(chunk.usage)) throw failure(502, 'invalid-usage', 'Runtime usage is not an object');
            const value = structuredClone(chunk.usage); record.normalizedUsage.push(value);
            if (Buffer.byteLength(JSON.stringify(record.normalizedUsage)) > MAX_BYTES) throw failure(502, 'invalid-usage', 'Runtime usage exceeded its byte bound');
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
        record.result = { text: record.text };
      }
    } catch (error) {
      failureCode = errorCode(error);
      if (failureCode === 'COMPANION_LOOKUP_INPUT_LIMIT') failureCode = 'companion/lookup-input-limit';
      record.terminal = controller.signal.aborted ? 'cancelled' : record.dispatched === false ? 'preflight_error'
        : record.httpStatus >= 400 ? 'http_error'
          : body.kind !== 'answer' && (record.complete || error.cause instanceof SyntaxError) ? 'invalid_response'
            : failureCode === 'STREAM_CLOSED' ? 'incomplete' : 'network_error';
      if (body.kind === 'answer') record.result = { text: record.text };
    } finally {
      clearTimeout(timer); req.off('aborted', abort); res.off('close', abort); controller.abort();
      record.finished = true;
      record.finish = { type: 'finish', requestId: body.requestId, taskId: body.taskId, taskRev: body.taskRev,
        dispatched: record.dispatched, dispatchAtMs: record.dispatchAtMs, httpStatus: record.httpStatus,
        terminal: record.terminal, complete: record.complete, result: record.result, bodyRetained: false, inputBudget: record.inputBudget,
        usage: body.kind === 'answer' ? usageReceipt(record) : null, ...(failureCode ? { error: { code: failureCode } } : {}) };
      emit(record.finish);
      if (!res.destroyed && !res.writableEnded) res.end();
      delete record.agent; delete record.controller; delete record.text;
      if (active === record) active = undefined;
    }
  }
  return {
    async handle(req, res, path) {
      if (path !== ROOT && !path.startsWith(ROOT + '/')) return false;
      try {
        admit(req);
        const url = new URL(req.url, 'http://dsh-go.invalid');
        if (path === ROOT && req.method === 'GET') {
          req.resume();
          if ([...url.searchParams.keys()].some(key => key !== 'sessionId') || url.searchParams.getAll('sessionId').length !== 1) throw failure(400, 'invalid-request', 'One full companion session is required');
          const target = await resolve(url.searchParams.get('sessionId'), undefined, failure), web = target.scope.get('web');
          const direct = typeof web?.companionLookupCapability === 'function'
            ? await web.companionLookupCapability(target.selected.provider) : { search: false, fetch: false };
          target.guard(); admit(req);
          if (raw(target.scope.get('web')) !== raw(web)) throw failure(409, 'unavailable', 'The direct lookup service changed');
          send(res, 200, { v: 1, instanceId, provider: target.selected.provider, model: target.selected.model,
            direct, answer: target.capability ?? null });
        } else if (req.method === 'POST' && (path === ROOT || path === ROOT + '/fence')) {
          if (String(req.headers['content-type']).split(';', 1)[0].trim().toLowerCase() !== 'application/json') throw failure(415, 'content-type', 'Content-Type must be application/json');
          const body = await readJson(req, MAX_BYTES, true);
          if (path === ROOT) await execute(req, res, validate(body));
          else {
            if (!fields(body, fenceKeys) || !validIdentity(body) || typeof body.cancelled !== 'boolean') throw failure(400, 'invalid-request', 'Invalid lookup fence');
            instance(body.instanceId);
            const fence = receiveFence(body, body.cancelled);
            send(res, 200, { v: 1, instanceId, taskId: body.taskId, taskRev: fence.taskRev, cancelled: fence.cancelled, received: true });
          }
        } else if (req.method === 'GET' && path.startsWith(ROOT + '/requests/')) {
          req.resume(); instance(url.searchParams.get('instanceId'));
          if ([...url.searchParams.keys()].some(key => key !== 'instanceId') || url.searchParams.getAll('instanceId').length !== 1) throw failure(400, 'invalid-request', 'One receipt instance is required');
          let id;
          try { id = decodeURIComponent(path.slice((ROOT + '/requests/').length)); } catch {}
          if (!contextId(id)) throw failure(400, 'invalid-request', 'Invalid lookup request ID');
          const record = receipts.get(id);
          if (!record) { const error = failure(404, 'request-unknown', 'No receipt exists in this host instance'); error.dispatched = null; throw error; }
          send(res, 200, snapshot(record));
        } else throw failure(path === ROOT ? 405 : 404, 'invalid-request', 'Unknown lookup route or method');
      } catch (error) {
        req.resume();
        if (!res.destroyed && !res.headersSent) {
          const known = error instanceof CompanionError, code = known && error.code.startsWith('companion/lookup-')
            ? error.code : known ? 'companion/lookup-' + error.code.slice('companion/'.length) : 'companion/lookup-unavailable';
          send(res, known ? error.status : 503, { error: { code, message: known ? error.message : 'Public lookup is unavailable' },
            dispatched: Object.hasOwn(error, 'dispatched') ? error.dispatched : false, ...(error.receipt ? { receipt: error.receipt } : {}) });
        }
      }
      return true;
    },
    dispose() { closed = true; active?.controller.abort(new Error('Lookup bridge disposed')); },
  };
}
