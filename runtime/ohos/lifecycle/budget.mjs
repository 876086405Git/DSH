import { performance } from 'node:perf_hooks';

/**
 * Only explicit, confirmed logical pauses in this process affect this clock.
 * Unannounced SIGSTOP, busy CPU and delayed callbacks remain elapsed budget.
 * It neither changes wall time nor owns connection/authentication deadlines.
 */
export class ActiveBudgetClock {
  #pauseStart;
  #excluded = 0;
  #deadlines = new Set();
  #closed = false;
  constructor(bootId) {
    if (typeof bootId !== 'string' || !bootId) throw new TypeError('Clock boot identity is required');
    this.bootId = bootId;
  }
  now() { return (this.#pauseStart ?? performance.now()) - this.#excluded; }
  get paused() { return this.#pauseStart !== undefined; }
  get pendingCount() { return this.#deadlines.size; }
  pause() {
    if (this.paused) return;
    // An already expired budget cannot be resurrected by pausing before its
    // delayed timer callback happens to run.
    const now = this.now();
    for (const entry of [...this.#deadlines]) if (entry.end <= now) entry.expire();
    this.#pauseStart = performance.now();
    for (const entry of this.#deadlines) entry.disarm();
  }
  resume() {
    if (this.paused) {
      this.#excluded += performance.now() - this.#pauseStart;
      this.#pauseStart = undefined;
    }
    // Without a confirmed pause, elapsed monotonic time is still charged.
    // Reconciliation also handles a due callback not yet delivered by libuv.
    for (const entry of this.#deadlines) entry.arm();
  }
  deadline(upstream, timeoutMs, reason) {
    if (this.#closed) throw Object.assign(new Error('Active budget owner is closed'), { code: 'ERR_OHOS_LIFECYCLE_CLOSED' });
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || timeoutMs > 2147483647) throw new RangeError('Invalid active timeout budget');
    const controller = new AbortController();
    let timer, disposed = false;
    const remove = () => {
      if (disposed) return;
      disposed = true;
      clearTimeout(timer);
      upstream?.removeEventListener('abort', cancelled);
      this.#deadlines.delete(entry);
    };
    const cancelled = () => { controller.abort(upstream.reason); remove(); };
    const entry = {
      end: this.now() + timeoutMs,
      disarm: () => { clearTimeout(timer); timer = undefined; },
      expire: () => { controller.abort(reason); remove(); },
      arm: () => {
        clearTimeout(timer);
        if (disposed || this.paused) return;
        const remaining = entry.end - this.now();
        if (remaining <= 0) { entry.expire(); return; }
        timer = setTimeout(entry.arm, Math.max(1, Math.ceil(remaining)));
      },
    };
    this.#deadlines.add(entry);
    if (upstream?.aborted) cancelled();
    else {
      upstream?.addEventListener('abort', cancelled, { once: true });
      entry.arm();
    }
    return { signal: controller.signal, [Symbol.dispose]: remove };
  }
  dispose() {
    this.#closed = true;
    for (const entry of [...this.#deadlines]) entry.expire();
  }
}
