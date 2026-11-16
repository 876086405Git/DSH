import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { validateJsonSchemaValue } from '@deepseek-ai/dsh-tools';
import { phoneResultSchema } from './catalog.mjs';

// Admission limits, not measured device capacity. The wire byte limit matches Android's MAX_LINE.
export const PHONE_WIRE_BYTES = 4 * 1024 * 1024;
export const PHONE_PENDING_LIMIT = 8;
const RECENT_LIMIT = 64;
const HANDOFF_MS = 600_000;
const ORDINARY_MS = 30_000;
const outcome = (status, code, message, dispatched = false) =>
  Object.freeze({ status, effect: 'none', evidence: 'unknown', dispatched, code, message });
const key = (engineId, generation) => JSON.stringify([engineId, generation]);
const sameScope = (a, b) => a.engineId === b.engineId && a.bridgeGeneration === b.bridgeGeneration;
const success = {
  mcp__phone__open: ['opened_ui', 'opened_ui'], mcp__phone__intent: ['opened_ui', 'opened_ui'],
  mcp__phone__notify: ['notification_published', 'unknown'], mcp__phone__clipboard: ['clipboard_written', 'unknown'],
  mcp__phone__handoff: ['none', 'user_confirmed'],
};

export class PhoneProtocolError extends Error {
  constructor(code, message, status = 409) { super(message); this.code = code; this.status = status; }
}
const fail = (code, message, status) => new PhoneProtocolError(code, message, status);

/** Owns pending promises only. Durable tool outcomes belong to the existing lifecycle journal. */
export class PhoneQueue {
  #pending = new Map();
  #recent = new Map();
  #calls = new Map();
  #listeners = new Set();
  #timer;
  #scope;
  #lastNow = -1;
  #closed = false;
  constructor(native) { this.native = native; }

  #finish(row, result, submitted) {
    if (!this.#pending.delete(row.request.requestId)) return;
    row.signal.removeEventListener('abort', row.abort);
    // Terminal cache retains no model arguments or resolver/listener closures.
    const receipt = { request: { engineId: row.request.engineId, bridgeGeneration: row.request.bridgeGeneration,
      requestId: row.request.requestId }, nonce: row.nonce, callKey: row.callKey, result, submitted };
    this.#recent.set(row.request.requestId, receipt);
    while (this.#recent.size > RECENT_LIMIT) {
      const first = this.#recent.keys().next().value;
      this.#calls.delete(this.#recent.get(first).callKey); this.#recent.delete(first);
    }
    row.resolve(result);
    if (!this.#pending.size) { clearTimeout(this.#timer); this.#timer = undefined; }
    this.#notify();
  }

  #stop(row, status, code, message) {
    let started = false;
    if (row.nonce) {
      try { started = this.native.revoke({ ...row.request, executionNonce: row.nonce }); }
      catch { started = null; }
    }
    const uncertain = started !== false && row.request.tool !== 'mcp__phone__handoff';
    this.#finish(row, outcome(uncertain ? 'unknown' : status, code,
      uncertain ? `${message} 动作可能已经派发，结果未知；不会自动重试。` : message, started !== false));
  }

  #notify() {
    for (const listener of [...this.#listeners]) {
      try { listener(); }
      catch { process.emitWarning('A phone callback subscriber failed', { code: 'OHOS_PHONE_LISTENER' }); }
    }
  }

  #sync() {
    let state;
    try { state = this.native.snapshot(); } catch { state = null; }
    if (!state?.available || typeof state.engineId !== 'string' || !state.engineId ||
        !Number.isSafeInteger(state.bridgeGeneration) || state.bridgeGeneration <= 0 ||
        !Number.isSafeInteger(state.nowMs) || state.nowMs < 0 ||
        (this.#scope === key(state.engineId, state.bridgeGeneration) && state.nowMs < this.#lastNow)) {
      for (const row of [...this.#pending.values()]) this.#stop(row, 'failed', 'native_unavailable', '本机手机回调或持续计时不可用。');
      // Off screen the app has no owner attached, and that is the reason worth giving.
      if (state?.foreground === false) throw fail('not_foreground', 'DSH不在前台，不能执行手机操作。');
      throw fail('native_unavailable', '本机手机回调或持续计时不可用。', 503);
    }
    const scope = key(state.engineId, state.bridgeGeneration);
    if (this.#scope !== scope) {
      for (const row of [...this.#pending.values()]) this.#stop(row, 'failed', 'owner_retired', '本次手机回调已退役。');
      this.#scope = scope;
    }
    this.#lastNow = state.nowMs;
    for (const row of [...this.#pending.values()]) {
      if (state.nowMs >= row.request.deadlineMs) this.#stop(row, 'timed_out', 'deadline_expired', '手机操作等待超时。');
      else if (!state.foreground && !row.nonce) this.#stop(row, 'failed', 'not_foreground', 'DSH已不在前台，此操作没有派发。');
    }
    return state;
  }

  #arm() {
    if (this.#timer !== undefined || !this.#pending.size) return;
    const next = Math.min(1000, ...[...this.#pending.values()].map(row => Math.max(1, row.request.deadlineMs - this.#lastNow)));
    this.#timer = setTimeout(() => {
      this.#timer = undefined;
      try { this.#sync(); } catch { /* #sync has settled pending calls with an explicit failure. */ }
      this.#arm();
    }, next);
  }

  #authorize(auth, foreground) {
    if (this.#closed) throw fail('closed', '手机回调已关闭。', 410);
    const state = this.#sync();
    if (!auth || !sameScope(auth, state) || typeof auth.owner !== 'string' || !/^[a-f0-9]{64}$/.test(auth.owner) ||
        typeof state.ownerHash !== 'string' || !/^[a-f0-9]{64}$/.test(state.ownerHash) ||
        !timingSafeEqual(createHash('sha256').update(auth.owner).digest(), Buffer.from(state.ownerHash, 'hex'))) {
      throw fail('wrong_owner', '手机回调身份无效。', 403);
    }
    if (foreground && !state.foreground) throw fail('not_foreground', '请回到DSH前台再操作。');
    return state;
  }

  enqueue({ sessionId, callId, tool, args, signal }) {
    if (this.#closed) throw fail('closed', '手机回调已关闭。', 410);
    const state = this.#sync();
    if (!state.foreground) throw fail('not_foreground', 'DSH不在前台，不能执行手机操作。');
    if (signal.aborted) return Promise.resolve(outcome('cancelled', 'cancelled', '手机操作已取消，没有派发。'));
    const callKey = JSON.stringify([sessionId, callId]);
    if (this.#calls.has(callKey)) throw fail('duplicate_call', '同一工具调用不能重新派发。');
    if (this.#pending.size >= PHONE_PENDING_LIMIT) throw fail('busy', '等待中的手机操作过多，请等当前操作结束。');
    const timeoutMs = tool === 'mcp__phone__handoff' ? HANDOFF_MS : ORDINARY_MS;
    const request = { v: 1, engineId: state.engineId, bridgeGeneration: state.bridgeGeneration,
      requestId: randomUUID(), sessionId, callId, tool, args, timeoutMs, deadlineMs: state.nowMs + timeoutMs };
    if (Buffer.byteLength(JSON.stringify(request)) > PHONE_WIRE_BYTES - 1024) throw fail('too_large', '手机请求超过4MiB传输上限。', 413);
    const pending = Promise.withResolvers();
    const row = { request, callKey, signal, resolve: pending.resolve, phase: 'queued', nonce: null };
    row.abort = () => this.#stop(row, 'cancelled', 'cancelled', '手机操作已取消。');
    signal.addEventListener('abort', row.abort, { once: true });
    this.#calls.set(callKey, request.requestId); this.#pending.set(request.requestId, row);
    this.#arm(); this.#notify();
    return pending.promise;
  }

  /** Whether a call could start now: when it can't, asking first only wastes the answer. */
  canRun() {
    if (this.#closed) return false;
    try { const state = this.native.snapshot(); return state?.available === true && state.foreground === true; }
    catch { return false; }
  }

  next(auth) {
    this.#authorize(auth, true);
    const row = [...this.#pending.values()].find(value => value.phase === 'queued');
    return row ? structuredClone(row.request) : null;
  }

  claim(auth, requestId) {
    this.#authorize(auth, true);
    const row = this.#pending.get(requestId);
    if (!row || row.phase !== 'queued') throw fail('not_pending', '请求已领取、结束或不存在。', 410);
    const executionNonce = randomUUID();
    // Synchronous native registration repeats foreground/generation/deadline checks.
    if (this.native.claim({ ...row.request, executionNonce }) !== true) throw fail('native_busy', '前一次原生手机操作还没有退出。');
    row.nonce = executionNonce; row.phase = 'claimed';
    this.#notify();
    return { request: structuredClone(row.request), executionNonce };
  }

  waiting(auth, requestId, executionNonce) {
    this.#authorize(auth, false);
    const row = this.#pending.get(requestId);
    if (!row || !row.nonce || row.nonce !== executionNonce || row.request.tool !== 'mcp__phone__handoff') throw fail('stale', '交还提示已失效。', 410);
    row.phase = 'waiting_user'; this.#notify();
    return { accepted: true, phase: row.phase };
  }

  result(auth, requestId, executionNonce, result) {
    const state = this.#authorize(auth, false);
    const old = this.#recent.get(requestId);
    if (old) {
      if (old.nonce !== executionNonce || !sameScope(old.request, auth)) throw fail('stale', '手机回执身份已失效。', 410);
      if (old.submitted && !isDeepStrictEqual(old.submitted, result)) throw fail('conflicting_result', '同一请求不能报告不同结果。');
      return { accepted: old.submitted !== undefined, result: structuredClone(old.result) };
    }
    const row = this.#pending.get(requestId);
    if (!row || !row.nonce || row.nonce !== executionNonce) throw fail('stale', '手机回执身份已失效。', 410);
    const expected = result.effect === 'reminder_scheduled' && row.request.tool === 'mcp__phone__intent' &&
      ['alarm', 'timer'].includes(row.request.args.kind) ? ['reminder_scheduled', 'unknown'] : success[row.request.tool];
    if (validateJsonSchemaValue(phoneResultSchema, result).length || !/^[a-z][a-z0-9_]{0,63}$/.test(result.code) ||
        Buffer.byteLength(result.message) > 8192 ||
        (result.status === 'succeeded' && (!result.dispatched ||
          result.effect !== expected?.[0] || result.evidence !== expected?.[1])) ||
        (result.status !== 'succeeded' && (result.effect !== 'none' || result.evidence !== 'unknown'))) {
      throw fail('bad_result', '手机回执格式或结果证据无效。', 400);
    }
    if (row.request.tool === 'mcp__phone__handoff' && result.evidence === 'user_confirmed' && !state.foreground) {
      throw fail('not_foreground', '请回到DSH前台再点继续。');
    }
    // Native rejects a success before dispatch and keeps a still-running system action occupied.
    if (this.native.complete({ ...row.request, executionNonce, result }) !== true) throw fail('not_completed', '原生手机操作尚未确认结束。');
    const value = structuredClone(result);
    this.#finish(row, value, structuredClone(value));
    return { accepted: true, result: structuredClone(value) };
  }

  cancel(auth, requestId) {
    this.#authorize(auth, false);
    const row = this.#pending.get(requestId);
    if (row) this.#stop(row, 'cancelled', 'user_stopped', '用户停止了本次手机操作。');
    return { accepted: row !== undefined };
  }

  subscribe(listener) { this.#listeners.add(listener); return () => this.#listeners.delete(listener); }
  status() { return { pending: this.#pending.size, recent: this.#recent.size, listeners: this.#listeners.size, timer: this.#timer !== undefined }; }
  close() {
    if (this.#closed) return;
    this.#closed = true;
    for (const row of [...this.#pending.values()]) this.#stop(row, 'cancelled', 'closed', '引擎手机回调已关闭。');
    clearTimeout(this.#timer); this.#timer = undefined; this.#listeners.clear(); this.#recent.clear(); this.#calls.clear();
  }
}
