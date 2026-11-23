// Process-local accounting observations for phone-owned ordinary full chat.
// No prompt, output, header, credential or Session event is stored here.
// A full cache must not change whether the ordinary model request is sent.
import { randomUUID } from 'node:crypto';

const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const count = value => Number.isSafeInteger(value) && value >= 0;
const ROOT_LIMIT = 128, RECEIPT_LIMIT = 1024, BYTE_LIMIT = 4 * 1024 * 1024, RAW_LIMIT = 65536;
const key = (sessionId, requestId) => JSON.stringify([sessionId, requestId]);
const code = error => {
  const value = error?.code ?? error?.failure?.code;
  return typeof value === 'string' && /^[a-zA-Z0-9_/-]{1,96}$/u.test(value) ? value : null;
};
const status = value => Number.isInteger(value) && value >= 100 && value <= 599 ? value : null;
const reasonOf = reason => reason && ({ kind: reason.kind,
  ...reason.failure ? { failure: { code: code(reason.failure), status: status(reason.failure.status) } } : {} });
const terminalOf = (reason, error, complete, httpStatus, cancelled = false) => {
  if (cancelled || reason?.kind === 'aborted' || code(error) === 'ABORTED') return 'cancelled';
  if (httpStatus >= 400) return 'http_error';
  if (code(error) === 'STREAM_CLOSED') return 'incomplete';
  if (['TRANSPORT', 'TIMEOUT'].includes(code(error))) return 'network_error';
  if (code(error) === 'REFUSAL') return 'refusal';
  if (code(error) === 'EMPTY_RESPONSE') return 'empty_response';
  if (reason?.kind === 'max-tokens') return 'max_tokens';
  if (reason?.kind === 'tool-calls') return 'tool_calls';
  if (reason?.kind === 'stop') return 'complete';
  return error || reason?.kind === 'error' ? 'provider_error' : complete ? 'complete' : 'incomplete';
};

function initialUsage(provider, model, observed) {
  return { provider, model, start_usage: null, final_usage: null, start_event: null, final_event: null,
    usage_semantics: observed ? 'cumulative' : 'unknown', input_uncached: null, input_cache_read: null,
    input_cache_write: null, output_tokens: null, stop_reason: null, terminal: 'incomplete',
    complete: false, http_status: null,
    ...observed ? {} : { runtime_normalized_usage: [], runtime_normalized_usage_semantics: 'runtime-normalized-events' } };
}

function derive(data) {
  const usage = data.usage, raw = usage.final_usage;
  const value = name => count(raw?.[name]) ? raw[name] : null;
  usage.input_uncached = value('input_tokens'); usage.input_cache_read = value('cache_read_input_tokens');
  usage.input_cache_write = value('cache_creation_input_tokens'); usage.output_tokens = value('output_tokens');
  usage.terminal = data.terminal; usage.complete = data.complete; usage.http_status = data.httpStatus;
  return data;
}

const rawSize = data => Buffer.byteLength(JSON.stringify([
  data.usage.start_usage, data.usage.final_usage, data.usage.runtime_normalized_usage ?? null,
]));

export function createCompanionUsage({ instanceId, now = Date.now, limits = {} } = {}) {
  const maxRoots = limits.roots ?? ROOT_LIMIT, maxReceipts = limits.receipts ?? RECEIPT_LIMIT;
  const maxBytes = limits.bytes ?? BYTE_LIMIT, maxRaw = limits.raw ?? RAW_LIMIT;
  if (![maxRoots, maxReceipts, maxBytes, maxRaw].every(value => Number.isSafeInteger(value) && value > 0)) {
    throw new TypeError('Invalid companion usage cache limits');
  }
  const roots = new Map(), receipts = new Map();
  let revision = 0, bytes = 0, disposed = false;
  const next = () => ++revision;
  const at = () => { try { const value = now(); return count(value) ? value : null; } catch { return null; } };
  function gap(groups, reason) {
    for (const group of groups) {
      if (!group.gaps.has(reason)) { group.gaps.add(reason); group.revision = next(); }
    }
  }
  function touch(groups) { for (const group of groups) group.revision = next(); }
  function evict(group) {
    roots.delete(group.key);
    for (const id of group.receipts) {
      const receipt = receipts.get(id);
      if (!receipt) continue;
      receipt.groups.delete(group);
      if (receipt.groups.size === 0 && receipt.data.phase === 'finished') {
        receipts.delete(id); bytes -= receipt.charge;
      }
    }
  }
  function room() {
    for (const group of roots.values()) {
      if (roots.size < maxRoots) return true;
      // Never silently evict unfinished or merely prepared accounting work.
      if (group.ended && group.active === 0) evict(group);
    }
    return roots.size < maxRoots;
  }
  function unknown(sessionId, requestId, reason) {
    return { v: 1, instanceId, sessionId, requestId, binding: null, state: 'unknown', complete: false,
      revision: 0, gaps: [reason], observedAdapterCalls: 0, activeCalls: 0, physicalRequests: null, receipts: [] };
  }
  function createReceipt(call, observation, atMs) {
    const observed = observation !== 'adapter-invoked';
    const data = { receiptId: randomUUID(), callId: call.id, revision: next(), requestIds: call.groups.map(g => g.requestId),
      provider: call.provider, model: call.model, phase: 'active', observation,
      dispatched: observation === 'fetch-invoked' ? true : observation === 'preflight' ? false : null,
      dispatchAtMs: observation === 'fetch-invoked' ? atMs : null, handoffAtMs: call.atMs,
      physicalRequests: observation === 'fetch-invoked' ? 1 : observation === 'preflight' ? 0 : null,
      terminal: 'incomplete', complete: false, httpStatus: null, errorCode: null,
      usage: initialUsage(call.provider, call.model, observed) };
    // Reserve room for bounded timestamps, revision digits and terminal codes.
    // Raw snapshots are charged separately; revisions cannot crowd out close.
    const baseCharge = Buffer.byteLength(JSON.stringify(data)) + 1024, charge = baseCharge + rawSize(data);
    for (const group of roots.values()) {
      if (receipts.size < maxReceipts && bytes + charge <= maxBytes) break;
      if (group.ended && group.active === 0) evict(group);
    }
    if (receipts.size >= maxReceipts || bytes + charge > maxBytes) {
      gap(call.groups, 'capacity'); return undefined;
    }
    const receipt = { data, groups: new Set(call.groups), baseCharge, charge };
    receipts.set(data.receiptId, receipt); bytes += charge;
    for (const group of call.groups) group.receipts.add(data.receiptId);
    if (atMs === null) gap(call.groups, 'clock-unavailable');
    touch(call.groups);
    return receipt;
  }
  function update(receipt, mutate, droppedField) {
    if (!receipt || receipt.data.phase === 'finished') return;
    try {
      let data = structuredClone(receipt.data);
      mutate(data);
      data = derive(data);
      let size = rawSize(data);
      if (size > maxRaw || bytes - receipt.charge + receipt.baseCharge + size > maxBytes) {
        gap(receipt.groups, 'usage-capacity');
        // A new unavailable final must never leave an older final posing as
        // the latest cumulative value. Preserve other already known evidence.
        if (droppedField === 'final_usage') { data.usage.final_usage = null; data.usage.final_event = null; }
        else if (droppedField === 'start_usage') { data.usage.start_usage = null; data.usage.start_event = null; }
        else if (droppedField === 'runtime_normalized_usage') {
          data.usage.runtime_normalized_usage = receipt.data.usage.runtime_normalized_usage;
        } else {
          data.usage.start_usage = null; data.usage.final_usage = null;
          data.usage.start_event = null; data.usage.final_event = null;
          if (data.usage.runtime_normalized_usage) data.usage.runtime_normalized_usage = [];
        }
        derive(data); size = rawSize(data);
      }
      data.revision = next();
      bytes -= receipt.charge; receipt.charge = receipt.baseCharge + size; bytes += receipt.charge;
      receipt.data = data; touch(receipt.groups);
    } catch {
      gap(receipt.groups, 'invalid-usage');
      if (droppedField === 'final_usage') {
        update(receipt, data => { data.usage.final_usage = null; data.usage.final_event = null; });
      }
    }
  }
  function observe(receipt, event) {
    if (!receipt || receipt.data.phase === 'finished') return;
    if (event.type === 'usage') {
      const field = event.event === 'message_start' ? 'start_usage' : event.event === 'message_delta' ? 'final_usage' : undefined;
      if (!field || !object(event.raw)) {
        gap(receipt.groups, 'invalid-usage');
        if (field === 'final_usage') update(receipt, data => { data.usage.final_usage = null; data.usage.final_event = null; });
        return;
      }
      update(receipt, data => {
        data.usage[field] = structuredClone(event.raw);
        data.usage[field === 'start_usage' ? 'start_event' : 'final_event'] = event.event;
      }, field);
    } else if (event.type === 'http') update(receipt, data => { data.httpStatus = status(event.status); });
    else if (event.type === 'stop') update(receipt, data => {
      data.usage.stop_reason = typeof event.stopReason === 'string' ? event.stopReason.slice(0, 96) : null;
    });
    else if (event.type === 'complete') update(receipt, data => { data.complete = true; });
  }
  function closeReceipt(receipt, reason, error, cancelled) {
    update(receipt, data => {
      data.phase = 'finished'; data.errorCode = code(error ?? reason?.failure);
      if (data.httpStatus === null) data.httpStatus = status(error?.failure?.status ?? reason?.failure?.status);
      data.terminal = terminalOf(reason, error ?? reason?.failure, data.complete, data.httpStatus, cancelled);
      if (data.observation === 'preflight' && data.terminal === 'incomplete') data.terminal = 'preflight_error';
    });
  }
  function finishCall(call) {
    if (call.finished || !call.closed || call.pending !== 0) return;
    call.finished = true;
    for (const group of call.groups) { group.active--; group.revision = next(); }
  }
  function openCall(groups, { provider, model }, observed) {
    const call = { id: randomUUID(), groups, provider, model, atMs: at(), pending: 0, physical: 0,
      closed: false, finished: false, reason: undefined, record: undefined };
    for (const group of groups) { group.calls++; group.active++; group.revision = next(); }
    if (!observed) {
      gap(groups, 'physical-count-unknown');
      call.record = createReceipt(call, 'adapter-invoked', call.atMs);
    }
    const safe = operation => { try { return operation(); } catch { gap(groups, 'observer-error'); } };
    return Object.freeze({
      beginPhysical(atMs) {
        return safe(() => {
          if (!observed || call.closed) { gap(groups, 'late-dispatch'); return undefined; }
          call.physical++; call.pending++;
          const receipt = createReceipt(call, 'fetch-invoked', count(atMs) ? atMs : null);
          let closed = false, terminalReason;
          return Object.freeze({
            observe(event) { safe(() => {
              if (closed) return;
              if (event.type === 'terminal') terminalReason = reasonOf(event.reason);
              else observe(receipt, event);
            }); },
            close(reason, error, cancelled = false) {
              safe(() => {
                if (closed) return;
                closed = true; closeReceipt(receipt, reason ?? terminalReason, error, cancelled);
                call.pending--; finishCall(call);
              });
            },
            failed() { gap(groups, 'observer-error'); },
          });
        });
      },
      chunk(chunk) {
        safe(() => {
          if (call.closed) return;
          if (chunk.type === 'finish') call.reason = reasonOf(chunk.reason);
          if (observed) return;
          if (chunk.type === 'usage') {
            if (!object(chunk.usage)) { gap(groups, 'invalid-usage'); return; }
            update(call.record, data => { data.usage.runtime_normalized_usage.push(structuredClone(chunk.usage)); }, 'runtime_normalized_usage');
          } else if (chunk.type === 'finish') update(call.record, data => {
            data.complete = ['stop', 'tool-calls', 'max-tokens'].includes(chunk.reason?.kind) ||
              ['REFUSAL', 'EMPTY_RESPONSE'].includes(code(chunk.reason?.failure));
          });
        });
      },
      close(error, cancelled = false) {
        safe(() => {
          if (call.closed) return;
          call.closed = true;
          if (!observed) closeReceipt(call.record, call.reason, error, cancelled);
          else if (call.physical === 0) {
            const receipt = createReceipt(call, 'preflight', call.atMs);
            closeReceipt(receipt, undefined, error ?? call.reason?.failure, cancelled);
          }
          finishCall(call);
        });
      },
      failed() { gap(groups, 'observer-error'); },
    });
  }
  return Object.freeze({
    prepare(owner, { sessionId, requestId, archiveId, controlRevision, historyAfterSeq, preparedAt }) {
      if (disposed) return false;
      const id = key(sessionId, requestId), binding = { archiveId, controlRevision, historyAfterSeq };
      const prior = roots.get(id);
      if (prior) {
        const same = prior.owner === owner && JSON.stringify(prior.binding) === JSON.stringify(binding);
        if (!same) gap([prior], 'binding-conflict');
        return same;
      }
      if (!room()) return false;
      roots.set(id, { key: id, owner, sessionId, requestId, binding, preparedAt, claimed: false, turn: undefined,
        ended: false, calls: 0, active: 0, revision: next(), receipts: new Set(), gaps: new Set() });
      return true;
    },
    expireUnclaimed(owner, beforeMs) {
      for (const group of roots.values()) {
        // Keep the first preparation time even after a parked lease is bounded
        // away. Retries cannot extend it; claimed accounting outlives that TTL.
        if (group.owner === owner && !group.claimed && !group.ended &&
            group.active === 0 && group.calls === 0 && group.preparedAt < beforeMs) {
          group.ended = true;
          gap([group], 'not-claimed');
        }
      }
    },
    claim(owner, sessionId, requestId, turn) {
      const group = roots.get(key(sessionId, requestId));
      if (disposed || !group || group.owner !== owner || group.ended) return false;
      group.claimed = true; group.turn = turn; group.revision = next(); return true;
    },
    open(owner, sessionId, requestIds, turn, config, observed) {
      if (disposed) return;
      const groups = requestIds.map(id => roots.get(key(sessionId, id)))
        .filter(group => group?.owner === owner && group.claimed && !group.ended && group.turn === turn);
      if (groups.length === 0) return;
      return openCall(groups, config, observed === true);
    },
    failed(owner, sessionId, requestIds) {
      gap(requestIds.map(id => roots.get(key(sessionId, id))).filter(group => group?.owner === owner), 'observer-error');
    },
    end(owner, turn) {
      for (const group of roots.values()) if (group.owner === owner && group.claimed && group.turn === turn) {
        group.ended = true; group.revision = next();
        if (group.calls === 0) gap([group], 'no-call-observation');
      }
    },
    retire(owner) {
      for (const group of roots.values()) if (group.owner === owner) {
        if (!group.ended) gap([group], group.claimed ? 'session-retired' : 'not-claimed');
        group.ended = true;
      }
    },
    snapshot({ instanceId: expected, sessionId, requestId }) {
      if (expected !== instanceId) return unknown(sessionId, requestId, 'instance-changed');
      if (disposed) return unknown(sessionId, requestId, 'instance-disposed');
      const group = roots.get(key(sessionId, requestId));
      if (!group) return unknown(sessionId, requestId, 'not-retained');
      const values = [...group.receipts].map(id => receipts.get(id)?.data).filter(Boolean);
      const gaps = [...group.gaps];
      const state = !group.claimed && !group.ended ? 'pending' : group.ended && group.active === 0 ? 'settled' : 'running';
      const physicalRequests = gaps.length || values.some(receipt => receipt.physicalRequests === null) ? null :
        values.reduce((sum, receipt) => sum + receipt.physicalRequests, 0);
      return structuredClone({ v: 1, instanceId, sessionId, requestId, binding: group.binding, state,
        complete: state === 'settled' && group.calls > 0 && gaps.length === 0 && physicalRequests !== null,
        revision: group.revision, gaps, observedAdapterCalls: group.calls, activeCalls: group.active,
        physicalRequests, receipts: values });
    },
    dispose() {
      disposed = true;
      for (const group of roots.values()) { group.ended = true; gap([group], 'instance-disposed'); }
    },
  });
}
