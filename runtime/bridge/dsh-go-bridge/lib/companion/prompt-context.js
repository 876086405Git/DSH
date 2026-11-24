// Volatile bridge state. The phone owns settings and resynchronizes after the
// advertised instanceId changes; runtime snapshots themselves are engine-owned.
import { createHash, randomUUID } from 'node:crypto';
import { CompanionError, invalid } from './schema.js';
import { validRecallSessionId } from './recall-schema.js';
import { createCompanionUsage } from './usage.js';

export const FULL_PRESET = 'dsh-go-companion-full';
const MAX_SESSIONS = 128, MAX_PENDING = 32, RECENT_MS = 30 * 60 * 1000;
const kinds = new Set(['pet', 'feed', 'task-finished', 'renamed']);
const controls = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/;
const record = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const fields = (v, required, optional = []) => record(v)
  && required.every(k => Object.hasOwn(v, k)) && Object.keys(v).every(k => [...required, ...optional].includes(k));
const text = (v, max) => typeof v === 'string' && [...v].length <= max && !controls.test(v);
export const contextId = v => text(v, 128) && v.length > 0 && !/[\r\n\t]/.test(v);
const time = v => Number.isSafeInteger(v) && v >= 0 && v <= 8640000000000000;
export const contextJson = v => JSON.stringify(v).replaceAll('<', '\\u003c').replaceAll('>', '\\u003e').replaceAll('&', '\\u0026');
const sequence = v => Number.isSafeInteger(v) && v >= 0;
const memoryKinds = new Set(['fact', 'preference', 'episode']);
const phoneConfigEvents = new Set(['agent-preset/selected', 'model/selection',
  'subagent/model-selection-policy', 'permission/preset', 'approval/policy', 'sandbox/mode', 'plan/mode']);

const phoneCollections = new Set(['about_you', 'our_story', 'person', 'recent', 'impression', 'diary']);
const nonempty = v => typeof v === 'string' && v.trim() !== '' && !v.includes('\0') && v.isWellFormed();

function layeredItem(item) {
  if (!fields(item, ['id', 'kind', 'text', 'layer', 'collection'], ['source', 'local_day']) ||
    !phoneCollections.has(item.collection) || !nonempty(item.text)) return false;
  const layer = ['impression', 'diary'].includes(item.collection) ? item.collection : 'card';
  if (item.layer !== layer || (layer === 'diary' ? typeof item.local_day !== 'string' || !/^\d{4}-\d{2}-\d{2}$/u.test(item.local_day) :
    Object.hasOwn(item, 'local_day'))) return false;
  if (item.collection !== 'recent') return !Object.hasOwn(item, 'source');
  const source = item.source;
  return fields(source, ['kind', 'package', 'app', 'observed_at_ms', 'user_confirmed']) &&
    source.kind === 'notice' && source.user_confirmed === false && nonempty(source.package) &&
    nonempty(source.app) && time(source.observed_at_ms);
}

function phoneMemoryOf(value) {
  if (!fields(value, ['archiveId', 'controlRevision', 'historyAfterSeq', 'block']) ||
    !contextId(value.archiveId) || !sequence(value.controlRevision) || !sequence(value.historyAfterSeq) ||
    typeof value.block !== 'string' || !value.block.isWellFormed()) throw invalid();
  let block;
  try { block = JSON.parse(value.block); } catch { throw invalid(); }
  if (!fields(block, ['type', 'version', 'scope', 'items']) || block.type !== 'companion_memory' ||
    ![2, 3].includes(block.version) || block.scope !== 'real' || !Array.isArray(block.items)) throw invalid();
  if (block.version === 2 && (!text(value.block, 1200) || block.items.length > 12)) throw invalid();
  const ids = new Set();
  for (const item of block.items) {
    const valid = block.version === 3 ? layeredItem(item) :
      fields(item, ['id', 'kind', 'text']) && text(item.text, 1200) && nonempty(item.text);
    if (!valid || !contextId(item.id) || !item.id.isWellFormed() || ids.has(item.id) || !memoryKinds.has(item.kind)) throw invalid();
    ids.add(item.id);
  }
  // Keep the phone's exact serialization, including source labels and card order.
  return Object.freeze({ archiveId: value.archiveId, controlRevision: value.controlRevision,
    historyAfterSeq: value.historyAfterSeq, block: value.block });
}

const localClock = v => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}[+-]\d{2}:\d{2}$/u.test(v);
const clockFields = v => localClock(v.localTime) && (v.zoneId === undefined || nonempty(v.zoneId));

function deviceContextOf(value) {
  if (!fields(value, ['window', 'localTime'], ['zoneId', 'originalMessage', 'noticeReply', 'selectedPage']) ||
    !['room', 'floating', 'notification', 'voice'].includes(value.window) || !clockFields(value)) throw invalid();
  if (value.originalMessage !== undefined && (!fields(value.originalMessage, ['localTime'], ['zoneId']) ||
    !clockFields(value.originalMessage))) throw invalid();
  if (value.selectedPage !== undefined && typeof value.selectedPage !== 'string') throw invalid();
  const notice = value.noticeReply;
  if (notice !== undefined && (!fields(notice, ['source', 'phase', 'app', 'package', 'observed_at_ms', 'summary'], ['shown_draft']) ||
    notice.source !== 'notice' || !nonempty(notice.app) || !nonempty(notice.package) || !nonempty(notice.summary) ||
    !time(notice.observed_at_ms) || !(notice.phase === 'draft' && notice.shown_draft === undefined ||
      notice.phase === 'confirmed' && nonempty(notice.shown_draft)))) throw invalid();
  return value;
}

export function cleanPhoneSession(session) {
  if (session.header?.isSeeded !== false || session.header.parentSession !== undefined ||
    session.inheritedEventCount !== 0 || !sequence(session.seq) || typeof session.eventAt !== 'function') return false;
  for (let seq = 0; seq < session.seq; seq++) {
    if (!phoneConfigEvents.has(session.eventAt(seq)?.type)) return false;
  }
  return true;
}

// The person's persona and names, at whatever length they wrote them.
function profileOf(value) {
  const keys = ['persona', 'name', 'callMe', 'moves'];
  if (!fields(value, keys)) throw invalid();
  const result = {};
  for (const key of keys) {
    if (typeof value[key] !== 'string') throw invalid();
    result[key] = value[key].trim();
  }
  return Object.freeze(result);
}

export function validatePromptContext(value) {
  if (!fields(value, ['v', 'sessionId', 'requestId', 'instanceId', 'events'],
    ['profile', 'expectedProfileRevision', 'query', 'phoneMemory', 'deviceContext']) || value.v !== 1 ||
    !contextId(value.sessionId) || !contextId(value.requestId) || !contextId(value.instanceId) ||
    !Array.isArray(value.events) || value.events.length > 8 ||
    (value.query !== undefined && !text(value.query, 256)) ||
    (Object.hasOwn(value, 'phoneMemory') && Object.hasOwn(value, 'query'))) throw invalid();
  const out = { v: 1, sessionId: value.sessionId, requestId: value.requestId, instanceId: value.instanceId };
  if (Object.hasOwn(value, 'profile') !== Object.hasOwn(value, 'expectedProfileRevision')) throw invalid();
  if (Object.hasOwn(value, 'profile')) {
    if (!Number.isSafeInteger(value.expectedProfileRevision) || value.expectedProfileRevision < 0) throw invalid();
    out.profile = profileOf(value.profile);
    out.expectedProfileRevision = value.expectedProfileRevision;
  }
  const ids = new Set();
  out.events = value.events.map(e => {
    if (!fields(e, ['id', 'kind', 'at'], ['detail']) || !contextId(e.id) || !kinds.has(e.kind) ||
      !time(e.at) || (e.detail !== undefined && !text(e.detail, 160)) || ids.has(e.id)) throw invalid();
    ids.add(e.id);
    return Object.freeze({ id: e.id, kind: e.kind, at: e.at, ...(e.detail ? { detail: e.detail } : {}) });
  });
  if (value.query !== undefined) out.query = value.query;
  if (Object.hasOwn(value, 'phoneMemory')) out.phoneMemory = phoneMemoryOf(value.phoneMemory);
  if (Object.hasOwn(value, 'deviceContext')) out.deviceContext = deviceContextOf(value.deviceContext);
  return out;
}

// Internal callers pass the actual Agent/Session objects, never just a reused
// sessionId. A ticket fences a query that was already awaiting storage at bind.
export function createCompanionPromptContext({ now = Date.now, instanceId = randomUUID(),
  isCurrent = () => true, allowMemory = () => true, usageLimits } = {}) {
  const sessions = new Map(), tickets = new WeakMap(), disabledSessions = new WeakSet();
  const phoneArchives = new Map(), phoneRequests = new WeakMap(), retiredPhoneAgents = new WeakSet();
  const usage = createCompanionUsage({ now, instanceId, limits: usageLimits });
  let closed = false, highWater = 0;
  const available = () => {
    if (closed) throw new CompanionError(503, 'unavailable', 'Companion context instance was disposed');
  };
  const at = () => {
    available();
    const value = now();
    if (!time(value)) throw new CompanionError(503, 'unavailable', 'Companion clock is unavailable');
    highWater = Math.max(highWater, value);
    return value;
  };
  const changed = () => new CompanionError(409, 'session-unavailable', 'Companion session changed; synchronize again');
  const stalePhone = () => new CompanionError(409, 'memory-context-stale', 'Use a new clean companion session after memory control changes');
  const phoneSupported = agent => agent.ctx?.get('llm')?.dshGoPhoneMemory === true;
  const usageSupported = agent => agent.ctx?.get('llm')?.dshGoCompanionChatUsage === true;
  const live = agent => validRecallSessionId(agent?.id) && agent.session?.id === agent.id && isCurrent(agent) === true;
  const lookup = agent => {
    if (closed || !live(agent)) return undefined;
    const value = sessions.get(agent.id);
    return value?.agent === agent && value.session === agent.session ? value : undefined;
  };
  function invalidate(value, disable = false) {
    if (value.memoryEpoch === Number.MAX_SAFE_INTEGER) {
      value.memoryDisabled = true;
    } else value.memoryEpoch++;
    value.memoryDisabled ||= disable;
    value.memories = [];
    for (const lease of [...value.pending.values(), ...value.parked.values()]) {
      lease.memories = [];
      lease.memoryEpoch = value.memoryEpoch;
    }
  }
  function refreshMemory(value) {
    let allowed = false;
    try { allowed = allowMemory(value.agent) === true; } catch { /* fail closed for memory only */ }
    if (!value.memoryDisabled && (!allowed || disabledSessions.has(value.session))) invalidate(value, true);
  }
  function open(agent) {
    available();
    if (!live(agent)) throw changed();
    let value = lookup(agent);
    if (!value) {
      if (!sessions.has(agent.id) && sessions.size >= MAX_SESSIONS) {
        throw new CompanionError(409, 'limit-reached', 'Companion context session limit reached');
      }
      const replaced = sessions.get(agent.id);
      if (replaced) usage.retire(replaced.session);
      if (replaced?.phone) {
        retiredPhoneAgents.add(replaced.agent); replaced.phoneAbort.abort(stalePhone());
      }
      // Reusing the id never copies leases, receipts or profile from an old
      // actual Agent/Session. A late callback cannot open or replace a state.
      value = { agent, session: agent.session, profile: undefined, revision: 0,
        pending: new Map(), parked: new Map(), receipts: new Map(), seen: new Set(),
        turn: undefined, events: [], memories: [], memoryEpoch: 0, memoryDisabled: false,
        currentMemoryEpoch: 0, lastHumanAt: undefined, idleMinutes: undefined,
        phone: undefined, phoneStale: false, phoneAbort: undefined, activeInput: undefined,
        usageRequests: new Set() };
      for (let seq = (agent.session.seq ?? 0) - 1; seq >= 0; seq--) {
        const event = agent.session.eventAt(seq);
        if (event?.type === 'user/message' && owner(event.data) && time(event.time)) {
          value.lastHumanAt = event.time; break;
        }
      }
      sessions.set(agent.id, value);
    }
    refreshMemory(value);
    return value;
  }
  const owner = message => message?.source?.kind === 'user' && message.source.principal === undefined;
  const expired = lease => highWater - lease.at > RECENT_MS;
  function prune(value) {
    usage.expireUnclaimed(value.session, highWater - RECENT_MS);
    for (const map of [value.pending, value.parked]) {
      for (const [id, lease] of map) if (expired(lease)) map.delete(id);
    }
    // A discarded Inbox occurrence is a parked lease, not a cancellation.
    // Parked requests do not occupy the 32 active preparation slots.
    while (value.parked.size > 64) value.parked.delete(value.parked.keys().next().value);
    for (const id of value.receipts.keys()) {
      if (value.receipts.size <= 128) break;
      if (!value.pending.has(id) && !value.parked.has(id)) value.receipts.delete(id);
    }
    while (value.seen.size > 256) value.seen.delete(value.seen.values().next().value);
  }
  const describe = value => ({ v: 1, supported: true, instanceId, sessionId: value.agent.id,
    profileRevision: value.revision, persistence: 'connection', requestBinding: 'rpcId',
    maxEvents: 8,
    memoryMode: value.phone ? 'phone' : value.memoryDisabled ? 'automatic' : 'query', memoryEpoch: value.memoryEpoch,
    ...(phoneSupported(value.agent) ? { phoneMemory: true, phoneMemoryVersion: 3, selectedPage: true } : {}),
    ...(usageSupported(value.agent) ? { chatUsage: true } : {}) });
  function capture(agent) {
    const value = open(agent);
    const token = Object.freeze({ allowed: !value.memoryDisabled && !value.phone });
    tickets.set(token, { value, epoch: value.memoryEpoch });
    return token;
  }
  function preparePhone(current, phone) {
    if (!phoneSupported(current.agent)) {
      throw new CompanionError(409, 'phone-memory-unsupported', 'This engine does not support request-only phone memory');
    }
    if (current.memoryDisabled) {
      throw new CompanionError(409, 'memory-mode-conflict', 'Automatic recall requires a separate clean companion session');
    }
    if (current.phone && current.phone.archiveId !== phone.archiveId) throw stalePhone();
    const known = phoneArchives.get(phone.archiveId);
    if (known && (phone.controlRevision < known.controlRevision || phone.historyAfterSeq < known.historyAfterSeq ||
      phone.controlRevision === known.controlRevision && phone.historyAfterSeq !== known.historyAfterSeq)) throw stalePhone();
    if (!known && phoneArchives.size >= MAX_SESSIONS) {
      throw new CompanionError(409, 'limit-reached', 'Companion phone archive limit reached');
    }
    if (!known || phone.controlRevision > known.controlRevision) {
      phoneArchives.set(phone.archiveId, { controlRevision: phone.controlRevision, historyAfterSeq: phone.historyAfterSeq });
      for (const value of sessions.values()) {
        if (value.phone?.archiveId !== phone.archiveId) continue;
        value.phoneStale = true; value.activeInput = undefined;
        value.phoneAbort.abort(stalePhone());
        for (const lease of [...value.pending.values(), ...value.parked.values()]) lease.phoneMemory = undefined;
      }
    }
    if (current.phoneStale || current.phone && (current.phone.archiveId !== phone.archiveId ||
      current.phone.controlRevision !== phone.controlRevision || current.phone.historyAfterSeq !== phone.historyAfterSeq)) throw stalePhone();
    if (!current.phone) {
      if (!cleanPhoneSession(current.session)) throw stalePhone();
      current.phone = { archiveId: phone.archiveId, controlRevision: phone.controlRevision, historyAfterSeq: phone.historyAfterSeq };
      current.phoneAbort = new AbortController();
      // Fences old queries that were awaiting storage before phone ownership.
      invalidate(current);
    }
  }
  return {
    info(agent) { at(); return describe(open(agent)); },
    profile(agent) { return lookup(agent)?.profile; },
    captureMemory: capture,
    // Called synchronously inside recall's serial bind, before publishing a
    // marker/ready. Even a later failed bind cannot restore an old query result.
    disableMemory(agent) {
      available();
      if (!live(agent)) throw changed();
      if (lookup(agent)?.phone) {
        throw new CompanionError(409, 'memory-mode-conflict', 'Phone memory and automatic recall cannot share a session');
      }
      // A recall-only session must not consume a profile/sidecar slot, nor
      // inherit this endpoint's narrower 128-codepoint wire ID limit.
      disabledSessions.add(agent.session);
      const value = lookup(agent);
      if (value) invalidate(value, true);
    },
    retireMemory(agent) {
      const value = sessions.get(agent?.id);
      if (value?.agent === agent) { disabledSessions.add(value.session); invalidate(value, true); }
    },
    invalidateMemories() {
      if (closed) return;
      for (const value of sessions.values()) invalidate(value);
    },
    prepare(agent, input, memories = [], lastHumanAt, memoryTicket) {
      const value = validatePromptContext(input);
      if (value.instanceId !== instanceId) throw new CompanionError(409, 'context-restarted', 'Reload companion context capability');
      at();
      const ticket = tickets.get(memoryTicket ?? capture(agent));
      const current = lookup(agent);
      if (!ticket || ticket.value !== current || value.sessionId !== agent.id) throw changed();
      refreshMemory(current);
      prune(current);
      const digest = createHash('sha256').update(JSON.stringify(value)).digest('hex');
      const receipt = current.receipts.get(value.requestId);
      if (receipt && receipt.digest !== digest) {
        throw new CompanionError(409, 'request-conflict', 'Request id already has different companion context');
      }
      if (receipt && !receipt.committed && expired(receipt)) {
        throw new CompanionError(409, 'request-expired', 'Companion request lease expired; prepare a new request');
      }
      if (!receipt && value.profile && current.revision !== value.expectedProfileRevision) {
        throw new CompanionError(409, 'profile-conflict', 'Reload companion profile revision');
      }
      let lease = current.pending.get(value.requestId) ?? current.parked.get(value.requestId);
      if (!lease && !receipt?.committed && current.pending.size >= MAX_PENDING) {
        throw new CompanionError(409, 'limit-reached', 'Too many pending companion contexts');
      }
      if (current.phone && value.query !== undefined) {
        throw new CompanionError(409, 'memory-mode-conflict', 'Phone memory sessions do not read host query memory');
      }
      if (value.deviceContext && !phoneSupported(agent)) {
        throw new CompanionError(409, 'device-context-unsupported', 'The engine cannot attach device context to this request');
      }
      if (value.phoneMemory) preparePhone(current, value.phoneMemory);
      if (!lease && !receipt?.committed) {
        lease = { at: receipt?.at ?? highWater, events: value.events,
          memories: !current.memoryDisabled && !current.phone && ticket.epoch === current.memoryEpoch
            ? structuredClone(memories) : [], memoryEpoch: current.memoryEpoch,
          phoneMemory: value.phoneMemory, deviceContext: value.deviceContext &&
            `<companion_device_context>${contextJson(value.deviceContext)}</companion_device_context>` };
        current.pending.set(value.requestId, lease);
      }
      // A retry reuses its original lease/expiry and never reapplies a profile
      // that has since changed. It can reconstruct an evicted parked lease.
      if (!receipt) {
        if (value.profile && JSON.stringify(value.profile) !== JSON.stringify(current.profile)) {
          if (current.revision === Number.MAX_SAFE_INTEGER) {
            current.pending.delete(value.requestId);
            throw new CompanionError(503, 'unavailable', 'Companion revision limit reached');
          }
          current.profile = value.profile; current.revision++;
        }
        current.receipts.set(value.requestId, { digest, at: highWater, committed: false });
      }
      if (time(lastHumanAt) && (current.lastHumanAt === undefined || lastHumanAt > current.lastHumanAt)) {
        current.lastHumanAt = lastHumanAt;
      }
      prune(current);
      if (value.phoneMemory && usageSupported(agent)) usage.prepare(current.session, {
        sessionId: value.sessionId, requestId: value.requestId, archiveId: value.phoneMemory.archiveId,
        controlRevision: value.phoneMemory.controlRevision, historyAfterSeq: value.phoneMemory.historyAfterSeq,
        preparedAt: receipt?.at ?? highWater,
      });
      return { ...describe(current), ...(value.profile ? {
        profileAccepted: JSON.stringify(current.profile) === JSON.stringify(value.profile) } : {}) };
    },
    claim(agent, message, turn) {
      if (!owner(message)) {
        if (message?.source?.kind === 'user') {
          const current = lookup(agent);
          current?.usageRequests.clear();
          // A guest input cannot carry forward the owner's external notification.
          if (current?.activeInput?.deviceContext) {
            const active = current.activeInput;
            current.activeInput = active.phoneMemory ? { ...active, deviceContext: undefined } : undefined;
          }
        }
        return;
      }
      const current = lookup(agent);
      if (!current) return;
      const clock = at();
      refreshMemory(current); prune(current);
      if (current.turn !== turn) {
        current.turn = turn; current.events = []; current.memories = [];
        current.usageRequests.clear();
      }
      // Billing ownership survives the memory-selection TTL once claimed.
      // A human without a prepared phone sidecar cannot borrow an old owner.
      if (contextId(message.source.rpcId) && usage.claim(current.session, agent.id, message.source.rpcId, turn)) {
        current.usageRequests.add(message.source.rpcId);
      } else current.usageRequests.clear();
      // Recompute for EVERY owner human claim, including a same-turn steer
      // with no sidecar. A short or negative gap explicitly clears old idle.
      const gap = current.lastHumanAt === undefined ? undefined : clock - current.lastHumanAt;
      current.idleMinutes = gap !== undefined && gap >= RECENT_MS ? Math.floor(gap / 60000) : undefined;
      current.memories = [];
      current.activeInput = undefined;
      current.currentMemoryEpoch = current.memoryEpoch;
      // A human claim can originate outside the RPC transport. It still
      // refreshes temporal/current-query state, but cannot claim a lease.
      if (!contextId(message.source.rpcId)) return;
      const pending = current.pending.get(message.source.rpcId) ?? current.parked.get(message.source.rpcId);
      if (!pending) return;
      for (const event of pending.events) {
        if (clock < event.at || highWater - event.at > RECENT_MS || current.seen.has(event.id) ||
          current.events.some(e => e.id === event.id)) continue;
        current.events.push(event);
      }
      current.events = current.events.slice(-8);
      if (!current.memoryDisabled && pending.memoryEpoch === current.memoryEpoch) current.memories = pending.memories;
      if (!current.phoneStale && (pending.phoneMemory || pending.deviceContext)) {
        current.activeInput = { requestId: message.source.rpcId, at: pending.at,
          phoneMemory: pending.phoneMemory, deviceContext: pending.deviceContext };
      }
    },
    commit(session, message, committedAt) {
      if (closed || !owner(message)) return;
      const current = sessions.get(session?.id);
      if (!current || current.session !== session || lookup(current.agent) !== current) return;
      if (time(committedAt)) current.lastHumanAt = committedAt;
      const requestId = message.source.rpcId;
      const pending = current.pending.get(requestId) ?? current.parked.get(requestId);
      if (pending) for (const event of pending.events) current.seen.add(event.id);
      const receipt = current.receipts.get(requestId);
      if (receipt) receipt.committed = true;
      current.pending.delete(requestId); current.parked.delete(requestId);
      at(); prune(current);
    },
    discard(agent, message) {
      if (!owner(message) || !contextId(message.source.rpcId)) return;
      const current = lookup(agent);
      if (!current) return;
      at(); prune(current);
      const id = message.source.rpcId, pending = current.pending.get(id);
      if (pending) {
        current.pending.delete(id); current.parked.set(id, pending);
        prune(current);
      }
    },
    end(session) {
      if (closed) return;
      const current = sessions.get(session?.id);
      if (current?.session === session) {
        usage.end(session, current.turn);
        current.turn = undefined; current.events = []; current.memories = []; current.idleMinutes = undefined;
        current.activeInput = undefined;
        current.usageRequests.clear();
      }
    },
    retire(agent) {
      const current = sessions.get(agent?.id);
      if (current?.agent === agent) {
        usage.retire(current.session);
        if (current.phone) {
          retiredPhoneAgents.add(agent); current.phoneAbort.abort(stalePhone());
        }
        invalidate(current, true);
        sessions.delete(agent.id);
      }
    },
    // Called only for a marked main-loop request by the final LlmRuntime
    // adapter boundary. No text is added to Session, projections or snapshots.
    forRequest(agent, options) {
      if (retiredPhoneAgents.has(agent)) throw stalePhone();
      const current = lookup(agent);
      if (!current || !current.phone && !current.activeInput) return options;
      at();
      if (options.sessionId !== agent.id || current.phoneStale) throw stalePhone();
      const signal = current.phoneAbort && options.signal ? AbortSignal.any([options.signal, current.phoneAbort.signal])
        : current.phoneAbort?.signal ?? options.signal;
      signal?.throwIfAborted();
      if (current.activeInput && expired(current.activeInput)) current.activeInput = undefined;
      const active = current.activeInput;
      let result = { ...options, signal };
      // A tool step may have other user-role runtime records after this human.
      // A different owner human (even without a usable RPC id) replaces it.
      const index = options.messages.findLastIndex(message => message.role === 'user' && owner(message));
      const message = options.messages[index];
      if (active && message?.source.rpcId === active.requestId) {
        const extra = [];
        if (active.deviceContext) extra.push(Object.freeze({ type: 'text', text: active.deviceContext }));
        if (active.phoneMemory && JSON.parse(active.phoneMemory.block).items.length) {
          extra.push(Object.freeze({ type: 'text', text: active.phoneMemory.block }));
        }
        if (extra.length) {
          const messages = options.messages.slice();
          messages[index] = Object.freeze({ ...message, content: Object.freeze([...message.content, ...extra]) });
          result.messages = Object.freeze(messages);
        }
      }
      result = Object.freeze(result);
      phoneRequests.set(result, { current, active, usageRequestIds: [...current.usageRequests],
        humanRequestId: message?.source.rpcId, turn: current.turn });
      return result;
    },
    // Called only at the marked runtime adapter boundary, with the exact
    // Agent and request copy already verified above. No wire-supplied owner.
    observeUsageRequest(agent, options, observed) {
      const request = phoneRequests.get(options);
      if (!request || request.current !== lookup(agent) || !usageSupported(agent) ||
          !request.usageRequestIds.includes(request.humanRequestId)) return undefined;
      try {
        return usage.open(request.current.session, agent.id, request.usageRequestIds, request.turn,
          { provider: options.provider, model: options.model }, observed);
      } catch {
        usage.failed(request.current.session, agent.id, request.usageRequestIds);
        return undefined;
      }
    },
    usageSnapshot(query) { return usage.snapshot(query); },
    // The default direct adapter invokes this synchronously at its physical
    // fetch boundary, after asynchronous credentials/attachment preparation.
    guardRequest(agent, options) {
      const request = phoneRequests.get(options);
      if (!request) return;
      at();
      const current = lookup(agent);
      if (current !== request.current || current.phoneStale || current.activeInput !== request.active ||
        request.active && expired(request.active)) throw stalePhone();
      options.signal?.throwIfAborted();
    },
    render(agent) {
      const current = lookup(agent);
      if (!current) return '';
      const clock = at();
      refreshMemory(current); prune(current);
      const events = current.events.filter(e => clock >= e.at && highWater - e.at <= RECENT_MS);
      const memories = current.memoryDisabled || current.currentMemoryEpoch !== current.memoryEpoch ? []
        : current.memories.filter(m => m.expiresAt === null || m.expiresAt > highWater).map(m => m.text);
      if (!events.length && !memories.length && current.idleMinutes === undefined) return '';
      return `<companion_context>${contextJson({ ...(events.length ? { events } : {}),
        ...(memories.length ? { memories } : {}),
        ...(current.idleMinutes === undefined ? {} : { idleSinceHumanMinutes: current.idleMinutes }) })}</companion_context>`;
    },
    clear() {
      usage.dispose();
      for (const current of sessions.values()) if (current.phone) {
        retiredPhoneAgents.add(current.agent); current.phoneAbort.abort(stalePhone());
      }
      closed = true; sessions.clear(); phoneArchives.clear();
    },
  };
}
