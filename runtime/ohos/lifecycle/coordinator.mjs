import { createHash } from 'node:crypto';
import { AsyncLocalStorage } from 'node:async_hooks';
import { createToolResultMessage } from '@deepseek-ai/dsh-llm';
import { ActiveBudgetClock } from './budget.mjs';
import { snapshot } from './journal.mjs';
import { setImmediate as nextIoTurn } from 'node:timers/promises';

export const lifecycleSymbol = Symbol.for('dsh.go.ohos.lifecycle');
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const fail = (code, message, cause) => Object.assign(new Error(message, { cause }), { code });
const keyOf = value => JSON.stringify([value.sessionId, value.callSeq]);
const knownString = value => typeof value === 'string' && value.length > 0 && value.length <= 4096 && !value.includes('\0');
const resultFor = (identity, result) => ({
  turn: identity.turn, step: identity.step,
  message: createToolResultMessage({ callId: identity.callId, content: result.content, isError: result.isError }),
  ...(result.error?.info ? { error: result.error.info } : {}),
  ...(result.meta !== undefined ? { meta: result.meta } : {}),
});
const unknownResult = event => event?.data?.error?.code === 'TOOL_OUTCOME_UNKNOWN';

function validateIdentity(identity) {
  if (!identity || !['sessionId', 'callId', 'name', 'originBootId'].every(key => knownString(identity[key]))
      || !Number.isSafeInteger(identity.callSeq) || identity.callSeq < 0
      || !Number.isSafeInteger(identity.turn) || identity.turn < 1
      || !Number.isSafeInteger(identity.step) || identity.step < 1
      || !/^[a-f0-9]{64}$/.test(identity.callHash)) throw fail('ERR_OHOS_LIFECYCLE_IDENTITY', 'Invalid durable call identity');
  return identity;
}

/** Exact scheduler boundary owner; never infers replay safety from a tool name. */
export class BoundaryCoordinator {
  #journal;
  #rows = new Map();
  #active = new Map();
  #pending = new Map();
  #callScope = new AsyncLocalStorage();
  #resources = new Map();
  #recoveries = new Map();
  #blocked = new Map();
  #gate;
  #controlTail = Promise.resolve();
  #controlVersion = 0;
  #host;
  #hostControl;
  #closing = false;
  #fault;
  #cancelled = new Set();
  #cancelling = new Set();
  #onStage;
  #lastPause = false;
  #manualPaused = false;
  #lastManualPaused = false;
  constructor({ journal, bootId, flushSession, readEvents, resolveAgent = () => undefined,
    revalidateTransport = async () => {}, onStage = () => {} }) {
    if (!journal || !knownString(bootId) || typeof flushSession !== 'function' || typeof readEvents !== 'function') throw new TypeError('Lifecycle requires durable session adapters and boot identity');
    this.#journal = journal;
    this.bootId = bootId;
    this.clock = new ActiveBudgetClock(bootId);
    this.flushSession = flushSession;
    this.readEvents = readEvents;
    this.resolveAgent = resolveAgent;
    this.revalidateTransport = revalidateTransport;
    this.#onStage = onStage;
    try { for (const record of journal.records) this.#fold(record.body); }
    catch (error) { this.#fault = error; }
    this.#manualPaused = this.#lastManualPaused;
    if (this.#lastPause) { this.#gate = Promise.withResolvers(); this.clock.pause(); }
  }
  get protocolVersion() { return 1; }
  #fold(body) {
    if (body.kind === 'header') return;
    if (body.kind === 'pause' || body.kind === 'resume') {
      if (body.manualPaused !== undefined && typeof body.manualPaused !== 'boolean') throw fail('ERR_OHOS_LIFECYCLE_SEQUENCE', 'Invalid durable pause reason');
      this.#lastPause = body.kind === 'pause';
      // Old records predate host callbacks: preserve an explicit old pause.
      this.#lastManualPaused = body.manualPaused ?? this.#lastPause;
      return;
    }
    if (body.kind === 'cancel') {
      if (!knownString(body.sessionId)) throw fail('ERR_OHOS_LIFECYCLE_IDENTITY', 'Cancel has no session identity');
      this.#cancelled.add(body.sessionId); return;
    }
    const identity = validateIdentity(body.identity), key = keyOf(identity);
    let row = this.#rows.get(key);
    if (body.kind === 'prepared' || body.kind === 'untracked') {
      if (row) throw fail('ERR_OHOS_LIFECYCLE_IDENTITY', 'Repeated prepared call identity');
      row = { identity, phase: body.kind }; this.#rows.set(key, row);
      // A checkpoint admitted before cancel may finish after it. It cannot
      // erase the cancellation whose join still owns this session.
      if (!this.#cancelling.has(identity.sessionId)) this.#cancelled.delete(identity.sessionId);
      return;
    }
    if (!row || hash(row.identity) !== hash(identity)) throw fail('ERR_OHOS_LIFECYCLE_IDENTITY', 'Boundary identity changed or has no prepared prefix');
    if (body.kind === 'dispatch') {
      if (row.phase !== 'prepared') throw fail('ERR_OHOS_LIFECYCLE_SEQUENCE', 'Repeated or unordered tool dispatch');
      row.phase = 'dispatch';
    } else if (body.kind === 'returned') {
      if (row.phase !== 'dispatch') throw fail('ERR_OHOS_LIFECYCLE_SEQUENCE', 'Returned outcome has no dispatch');
      row.phase = 'returned'; row.returned = body.result; row.needsPost = body.needsPost;
    } else if (body.kind === 'outcome') {
      if (!['prepared', 'returned'].includes(row.phase)) throw fail('ERR_OHOS_LIFECYCLE_SEQUENCE', 'Final outcome is not at its ordered boundary');
      row.phase = 'outcome'; row.outcome = body.result;
    } else if (body.kind === 'committed') {
      if (row.phase !== 'outcome') throw fail('ERR_OHOS_LIFECYCLE_SEQUENCE', 'Commit has no durable final outcome');
      if (!Number.isSafeInteger(body.sessionResultSeq) || !/^[a-f0-9]{64}$/.test(body.sessionResultHash)) throw fail('ERR_OHOS_LIFECYCLE_IDENTITY', 'Commit lacks exact durable result identity');
      row.phase = 'committed'; row.sessionResultSeq = body.sessionResultSeq; row.sessionResultHash = body.sessionResultHash;
    } else if (body.kind === 'reconciled') {
      if (typeof body.blocking !== 'boolean' || !knownString(body.basis)) throw fail('ERR_OHOS_LIFECYCLE_IDENTITY', 'Invalid reconciliation decision');
      row.reconciliation = { basis: body.basis, blocking: body.blocking, bootId: body.bootId };
    } else {
      throw fail('ERR_OHOS_LIFECYCLE_SEQUENCE', 'Unknown lifecycle record kind');
    }
  }
  #check() {
    if (this.#closing) throw fail('ERR_OHOS_LIFECYCLE_CLOSED', 'Lifecycle service is closing');
    if (this.#fault || this.#journal.corruption || this.#journal.failed) throw fail('ERR_OHOS_LIFECYCLE_BLOCKED', 'Lifecycle persistence or identity requires explicit repair', this.#fault);
  }
  async #record(body, result) {
    try {
      const record = result === undefined ? await this.#journal.append(body) : await this.#journal.appendResult(body, result);
      this.#fold(record.body);
      await this.#onStage(record.body.kind, record.body);
      return record.body;
    } catch (error) { this.#fault ??= error; throw error; }
  }
  #row(meta) {
    const row = this.#rows.get(keyOf({ sessionId: meta.session.id, callSeq: meta.callSeq }));
    if (!row || row.identity.callId !== meta.block.id || row.identity.turn !== meta.turn || row.identity.step !== meta.step) throw fail('ERR_OHOS_LIFECYCLE_IDENTITY', 'Scheduler call does not match its prepared identity');
    return row;
  }
  /** Scope only this scheduler-owned call, including its ordered post policy. */
  withinCall(meta, operation) {
    const row = this.#row(meta);
    return this.#callScope.run(keyOf(row.identity), operation);
  }
  /** Fixed spill consumers report actual successful allocation, never text guesses. */
  externalResource(kind) {
    const key = this.#callScope.getStore();
    if (key === undefined || !this.#pending.has(key)) return;
    if (kind !== 'spill-reference') throw new TypeError('Unknown lifecycle resource kind');
    let resources = this.#resources.get(key);
    if (!resources) this.#resources.set(key, resources = new Set());
    resources.add(kind);
  }
  #unresolved(sessionId) {
    return [...this.#rows.values()].filter(row => row.identity.sessionId === sessionId
      && (row.reconciliation?.blocking === true || row.phase !== 'committed')
      && !this.#pending.has(keyOf(row.identity)) && row.reconciliation?.blocking !== false);
  }
  async gate(sessionId, signal) {
    for (;;) {
      this.#check(); signal?.throwIfAborted();
      // Joining cancellation is an independent live admission boundary. The
      // historical cancelled flag also changes when older records are folded.
      if (this.#cancelling.has(sessionId)) throw fail('ERR_OHOS_LIFECYCLE_CANCELLED', 'Session cancellation has not finished joining');
      if (this.#cancelled.has(sessionId)) {
        if ([...this.#pending.keys()].some(key => JSON.parse(key)[0] === sessionId)) throw fail('ERR_OHOS_LIFECYCLE_CANCELLED', 'Session was cancelled at its lifecycle boundary');
        // The prior signal is permanently aborted. A fresh call after the
        // joined cancellation is a new request, never a replay of that call.
        this.#cancelled.delete(sessionId);
      }
      if (this.#blocked.has(sessionId) || this.#unresolved(sessionId).length) throw fail('ERR_OHOS_LIFECYCLE_RESULT_UNKNOWN', 'Previous tool results require reconciliation before another step');
      if (!this.#gate) return;
      const interrupted = Promise.withResolvers();
      const abort = () => interrupted.reject(signal.reason);
      signal?.addEventListener('abort', abort, { once: true });
      try { await Promise.race([this.#gate.promise, interrupted.promise]); }
      finally { signal?.removeEventListener('abort', abort); }
    }
  }
  async prepared(meta) {
    // Admission failures are local to this call/session. Only a failed durable
    // checkpoint or identity check poisons the shared persistence boundary.
    await this.gate(meta.session.id, meta.signal);
    try {
      if (await this.flushSession(meta.session) !== true) throw fail('ERR_OHOS_LIFECYCLE_NO_CHECKPOINT', 'A durable session flush listener is required');
      const events = await this.readEvents(meta.session.id, meta.callSeq, meta.callSeq + 1);
      const event = events[0];
      if (events.length !== 1 || event.type !== 'tool/call' || event.seq !== meta.callSeq
          || event.data.callId !== meta.block.id || event.data.name !== meta.block.name
          || event.data.turn !== meta.turn || event.data.step !== meta.step) throw fail('ERR_OHOS_LIFECYCLE_IDENTITY', 'Durable tool call prefix does not match scheduler');
      const identity = { sessionId: meta.session.id, callSeq: meta.callSeq, callId: meta.block.id,
        name: meta.block.name, turn: meta.turn, step: meta.step, originBootId: this.bootId, callHash: hash(event) };
      this.#pending.set(keyOf(identity), Promise.withResolvers());
      await this.#record({ kind: 'prepared', bootId: this.bootId, identity });
    } catch (error) {
      if (error?.code !== 'ERR_OHOS_LIFECYCLE_CANCELLED' && !meta.signal?.aborted) this.#fault ??= error;
      throw error;
    }
  }
  async run(meta, dispatch) {
    const row = this.#row(meta), key = keyOf(row.identity);
    await this.gate(meta.session.id, meta.signal);
    await this.#record({ kind: 'dispatch', bootId: this.bootId, identity: row.identity });
    // Keep the accepted dispatch live while waiting for a confirmed pause to
    // end. No second copy is created and no async gap follows final admission.
    const settled = Promise.withResolvers();
    this.#active.set(key, settled.promise);
    try {
      await this.gate(meta.session.id, meta.signal);
      const outcome = await this.withinCall(meta, dispatch);
      await this.#record({ kind: 'returned', bootId: this.bootId, identity: row.identity,
        needsPost: outcome.kind === 'post-result' }, outcome.result);
      return outcome;
    } catch (error) {
      this.#blocked.set(meta.session.id, 'dispatch-without-reliable-outcome');
      throw error;
    } finally { this.#active.delete(key); settled.resolve(); }
  }
  async outcome(meta, result) {
    const row = this.#row(meta);
    // createToolResultMessage mints an identity. Persist that exact projection
    // once, then give the original scheduler the same bytes to append.
    const sessionData = snapshot(resultFor(row.identity, result));
    await this.#record({ kind: 'outcome', bootId: this.bootId, identity: row.identity },
      { v: 1, finalResult: result, sessionData, resources: [...this.#resources.get(keyOf(row.identity)) ?? []] });
    return sessionData;
  }
  async committed(meta) {
    const row = this.#row(meta);
    try {
      if (await this.flushSession(meta.session) !== true) throw fail('ERR_OHOS_LIFECYCLE_NO_CHECKPOINT', 'Committed result lacks a durable session checkpoint');
      const events = await this.readEvents(meta.session.id, meta.callSeq + 1);
      const matches = events.filter(event => event.type === 'tool/result' && event.sourceEventSeqs?.length === 1 && event.sourceEventSeqs[0] === meta.callSeq);
      const outcome = await this.#journal.readResult(row.outcome);
      if (outcome.v !== 1 || matches.length !== 1 || hash(matches[0].data) !== hash(outcome.sessionData)) throw fail('ERR_OHOS_LIFECYCLE_IDENTITY', 'Durable committed result does not match the final outcome');
      await this.#record({ kind: 'committed', bootId: this.bootId, identity: row.identity,
        sessionResultSeq: matches[0].seq, sessionResultHash: hash(matches[0].data) });
      this.#finishCall(keyOf(row.identity));
    } catch (error) { this.#fault ??= error; throw error; }
  }
  #finishCall(key) {
    const pending = this.#pending.get(key);
    this.#pending.delete(key); pending?.resolve();
    this.#resources.delete(key);
  }
  failedGroup(sessionId, callSeqs) {
    for (const callSeq of callSeqs) if (callSeq !== undefined) this.#finishCall(keyOf({ sessionId, callSeq }));
    if (this.#unresolved(sessionId).length) this.#blocked.set(sessionId, 'scheduler-ended-with-uncommitted-outcome');
  }
  /** Transform only the original ordered recovery closers, before they append. */
  async reconcileCold(sessionId, persisted, closers) {
    this.#check();
    const replacements = snapshot(closers);
    const decisions = [];
    // A session predating this protocol is not evidence that nothing ran. An
    // unresolved legacy call receives an explicit unknown origin, never a
    // retroactive prepared/dispatch record or automatic replay permission.
    for (const call of persisted.filter(event => event.type === 'tool/call')) {
      const key = keyOf({ sessionId, callSeq: call.seq });
      const matches = persisted.filter(event => event.type === 'tool/result' && event.sourceEventSeqs?.length === 1 && event.sourceEventSeqs[0] === call.seq);
      if (this.#rows.has(key) || (matches.length === 1 && !unknownResult(matches[0]))) continue;
      await this.#record({ kind: 'untracked', bootId: this.bootId, identity: { sessionId, callSeq: call.seq,
        callId: call.data.callId, name: call.data.name, turn: call.data.turn, step: call.data.step,
        originBootId: 'unrecorded', callHash: hash(call) } });
    }
    const sessionRows = [...this.#rows.values()].filter(row => row.identity.sessionId === sessionId);
    for (const row of sessionRows) {
      const identity = row.identity, call = persisted.find(event => event.seq === identity.callSeq);
      const matches = persisted.filter(event => event.type === 'tool/result' && event.sourceEventSeqs?.length === 1 && event.sourceEventSeqs[0] === identity.callSeq);
      let basis, blocking = false, expected;
      if (!call || call.type !== 'tool/call' || hash(call) !== identity.callHash || matches.length > 1) {
        basis = 'session-identity-mismatch'; blocking = true;
      } else if (row.reconciliation?.basis === 'explicit-abandon-unknown-without-replay' && row.reconciliation.blocking === false) {
        basis = 'explicit-abandon-unknown-without-replay';
      } else if (matches.length === 1) {
        basis = unknownResult(matches[0]) ? 'existing-unknown-placeholder' : 'durable-session-result';
        blocking = unknownResult(matches[0]);
        if (!blocking && row.phase === 'committed' && (row.sessionResultSeq !== matches[0].seq || row.sessionResultHash !== hash(matches[0].data))) {
          basis = 'committed-session-result-changed'; blocking = true;
        } else if (!blocking && row.phase === 'outcome') {
          try {
            const saved = await this.#journal.readResult(row.outcome);
            if (saved.v !== 1 || hash(saved.sessionData) !== hash(matches[0].data)) {
              basis = 'session-final-outcome-mismatch'; blocking = true;
            } else expected = saved.sessionData;
          } catch { basis = 'durable-session-result-with-missing-private-copy'; }
        }
      } else {
        const closer = replacements.find(event => event.type === 'tool/result' && event.sourceEventSeqs?.length === 1 && event.sourceEventSeqs[0] === identity.callSeq);
        if (!closer) { basis = 'missing-ordered-recovery-slot'; blocking = true; }
        else if (row.outcome) {
          try {
            const saved = await this.#journal.readResult(row.outcome);
            if (saved.v !== 1 || !saved.sessionData || !saved.finalResult || !Array.isArray(saved.resources)
                || saved.resources.some(kind => kind !== 'spill-reference')) throw fail('ERR_OHOS_LIFECYCLE_CORRUPT', 'Final result envelope is invalid');
            const result = saved.finalResult;
            basis = 'durable-final-outcome';
            // A cold restart cannot silently discard deferred model context.
            if (result.additionalContexts?.length) { basis = 'outcome-with-deferred-context'; blocking = true; }
            if (saved.resources.length || result.content?.some(block => block.type === 'image')
                || result.value?.stdout?.spillPath || result.value?.stderr?.spillPath || result.value?.jobId) {
              basis = 'outcome-with-external-resource-lifetime'; blocking = true;
            }
            // Keep the original unknown closer when the final JSON depends on
            // resources/context we cannot reconstitute. Otherwise a second cold
            // restart would mistake our own partial restoration for a commit.
            if (!blocking) closer.data = expected = saved.sessionData;
          } catch { basis = 'result-file-unavailable'; blocking = true; }
        } else if (row.phase === 'prepared') {
          closer.data = resultFor(identity, { content: [{ type: 'text', text: 'Tool was not dispatched before the prior engine stopped.' }],
            isError: true, error: { info: { name: 'InterruptedToolCall', code: 'TOOL_NOT_STARTED' } } });
          basis = 'complete-prepared-without-dispatch';
        } else {
          basis = row.returned ? 'returned-awaiting-ordered-finalization' : 'dispatch-without-outcome'; blocking = true;
        }
      }
      decisions.push({ row, basis, blocking, expected });
    }
    this.#recoveries.set(sessionId, decisions);
    return replacements;
  }
  async recoveredCommitted(sessionId, persisted) {
    this.#check();
    const decisions = this.#recoveries.get(sessionId);
    if (!decisions) throw fail('ERR_OHOS_LIFECYCLE_IDENTITY', 'Recovery has no matching read transaction');
    for (const decision of decisions) {
      const { row, expected } = decision;
      if (expected) {
        const matches = persisted.filter(event => event.type === 'tool/result' && event.sourceEventSeqs?.length === 1
          && event.sourceEventSeqs[0] === row.identity.callSeq);
        if (matches.length !== 1 || hash(matches[0].data) !== hash(expected)) throw fail('ERR_OHOS_LIFECYCLE_IDENTITY', 'Recovered final result did not reach durable session storage');
        if (!decision.blocking && row.phase === 'outcome') await this.#record({ kind: 'committed', bootId: this.bootId,
          identity: row.identity, sessionResultSeq: matches[0].seq, sessionResultHash: hash(matches[0].data) });
      }
      await this.#record({ kind: 'reconciled', bootId: this.bootId, identity: row.identity,
        basis: decision.basis, blocking: decision.blocking });
      if (decision.blocking) this.#blocked.set(sessionId, decision.basis);
    }
    if (!decisions.some(decision => decision.blocking)) this.#blocked.delete(sessionId);
    this.#recoveries.delete(sessionId);
    return this.status(sessionId);
  }
  observeHost(observation) {
    this.#check();
    // A cancelled HTTP request may already be executing. An older foreground
    // observation cannot reopen the gate after a newer background observation.
    if (this.#host && observation.revision <= this.#host.revision) return this.#hostControl.then(() => this.status());
    this.#host = { ...observation };
    this.#hostControl = observation.foreground && !this.#manualPaused ? this.#resume() : this.#pause();
    return this.#hostControl.then(() => this.status());
  }
  pause() {
    this.#check();
    this.#manualPaused = true;
    return this.#pause();
  }
  resume() {
    this.#check();
    this.#manualPaused = false;
    // An explicit resume releases only its own cause. Background still owns
    // admission, and this durable pause records the released manual cause.
    return this.#host?.foreground === false ? this.#pause() : this.#resume();
  }
  #pause() {
    const version = ++this.#controlVersion;
    const manualPaused = this.#manualPaused;
    this.#gate ??= Promise.withResolvers();
    const work = this.#controlTail.then(async () => {
      await this.#record({ kind: 'pause', bootId: this.bootId, manualPaused });
      this.clock.pause();
      await this.#journal.flush();
      return { ...this.status(), acknowledgedControlVersion: version };
    });
    this.#controlTail = work.catch(error => { this.#fault ??= error; });
    return work;
  }
  #resume() {
    const version = ++this.#controlVersion;
    const manualPaused = this.#manualPaused;
    const work = this.#controlTail.then(async () => {
      // Process already queued completion/close callbacks before reporting a
      // recovery view. Pending calls still own their original handles.
      await nextIoTurn();
      await this.revalidateTransport();
      await this.#record({ kind: 'resume', bootId: this.bootId, manualPaused });
      if (version === this.#controlVersion) {
        this.clock.resume(); const gate = this.#gate; this.#gate = undefined; gate?.resolve();
      }
      return this.status();
    });
    this.#controlTail = work.catch(error => { this.#fault ??= error; });
    return work;
  }
  async cancel(sessionId) {
    this.#check();
    if (!knownString(sessionId)) throw new TypeError('Session identity is required');
    if (this.#cancelling.has(sessionId)) throw fail('ERR_OHOS_LIFECYCLE_CANCELLING', 'This session already has a joined cancellation in progress');
    this.#cancelled.add(sessionId);
    this.#cancelling.add(sessionId);
    if (this.#gate) { const gate = this.#gate; this.#gate = Promise.withResolvers(); gate.resolve(); }
    try {
      await this.#record({ kind: 'cancel', bootId: this.bootId, sessionId });
      const agent = this.resolveAgent(sessionId);
      if (agent) {
        if (typeof agent.cancel !== 'function' || typeof agent.whenIdle !== 'function') throw fail('ERR_OHOS_LIFECYCLE_CANCEL_UNSUPPORTED', 'Agent has no joinable cancellation boundary');
        agent.cancel({ kind: 'user' });
        await agent.whenIdle();
        if (await this.flushSession(agent.session) !== true) throw fail('ERR_OHOS_LIFECYCLE_NO_CHECKPOINT', 'Cancelled session has no durable checkpoint');
      }
      await Promise.all([...this.#pending].filter(([key]) => JSON.parse(key)[0] === sessionId).map(([, value]) => value.promise));
    } finally {
      this.#cancelling.delete(sessionId);
    }
    return this.status(sessionId);
  }
  async acknowledgeUnknown(sessionId) {
    const checkIdle = () => {
      this.#check();
      if (this.#cancelling.has(sessionId) || [...this.#pending.keys()].some(key => JSON.parse(key)[0] === sessionId)) throw fail('ERR_OHOS_LIFECYCLE_STILL_RUNNING', 'Live calls and cancellation must settle before acknowledging an old unknown');
    };
    checkIdle();
    for (const row of this.#unresolved(sessionId)) await this.#record({ kind: 'reconciled', bootId: this.bootId,
      identity: row.identity, basis: 'explicit-abandon-unknown-without-replay', blocking: false });
    // A cancel may start during one of the durable reconciliation writes.
    checkIdle();
    this.#blocked.delete(sessionId); this.#cancelled.delete(sessionId);
    return this.status(sessionId);
  }
  status(sessionId) {
    const calls = [...this.#rows.values()].filter(row => sessionId === undefined || row.identity.sessionId === sessionId).map(row => ({
      ...row.identity, phase: row.phase, active: this.#pending.has(keyOf(row.identity)),
      dispatchActive: this.#active.has(keyOf(row.identity)),
      hasReturned: !!row.returned, hasFinalOutcome: !!row.outcome,
      ...(row.reconciliation ? { reconciliation: snapshot(row.reconciliation) } : {}),
    }));
    const blocked = this.#fault || this.#journal.failed || this.#journal.corruption;
    const unknown = calls.some(row => !row.active && (row.reconciliation?.blocking === true || row.phase !== 'committed') && row.reconciliation?.blocking !== false);
    const cancelled = sessionId !== undefined && this.#cancelled.has(sessionId);
    const state = blocked || unknown || (sessionId !== undefined && this.#blocked.has(sessionId)) ? 'result-unknown'
      : cancelled ? this.#cancelling.has(sessionId) || calls.some(row => row.active) ? 'cancelling' : 'terminated'
        : this.#gate ? 'paused' : calls.some(row => row.active) || (sessionId !== undefined && this.resolveAgent(sessionId)?.status === 'running') ? 'running' : calls.length ? 'completed' : 'running';
    return { v: 1, bootId: this.bootId, state, closed: this.#closing, paused: !!this.#gate, confirmedPause: this.clock.paused,
      manualPaused: this.#manualPaused,
      blocked: !!blocked, corruption: this.#journal.corruption, controlVersion: this.#controlVersion,
      activeBudgetCount: this.clock.pendingCount, calls,
      ...(this.#host === undefined ? {} : { host: { ...this.#host } }) };
  }
  async result(sessionId, callSeq) {
    const row = this.#rows.get(keyOf({ sessionId, callSeq }));
    if (!row || !(row.outcome || row.returned)) throw fail('ERR_OHOS_LIFECYCLE_RESULT_ABSENT', 'No stored result for this call');
    const saved = await this.#journal.readResult(row.outcome ?? row.returned);
    return { identity: snapshot(row.identity), final: !!row.outcome,
      result: row.outcome ? saved.finalResult : saved,
      ...(row.outcome ? { sessionData: saved.sessionData, resources: saved.resources ?? [] } : {}) };
  }
  async close() {
    this.#closing = true;
    const gate = this.#gate; this.#gate = undefined; gate?.resolve();
    const agents = new Set([...this.#pending.keys()].map(key => this.resolveAgent(JSON.parse(key)[0])).filter(Boolean));
    for (const agent of agents) agent.cancel({ kind: 'disposed' });
    await this.#controlTail;
    await Promise.all([...agents].map(agent => agent.whenIdle()));
    await Promise.all([...this.#pending.values()].map(value => value.promise));
    this.clock.dispose();
    await this.#journal.close();
  }
}
