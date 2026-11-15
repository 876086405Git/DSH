// Explicit raw-channel fallback: ordinary elapsed monotonic timers, not iOS activity time.
const monotonicDeadline = (ms, reason) => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(reason), ms);
  return { signal: controller.signal, [Symbol.dispose]() { clearTimeout(timer); } };
};
// A single execution queue over a trusted native GuestChannel. The backend owns
// mounts and the kernel; JavaScript never treats a signal acknowledgement as exit.
export class GuestChannelFault extends Error {
  constructor(message, options) {
    super(message, options);
    this.name = 'GuestChannelFault';
    this.code = 'ERR_IOS_GUEST_FAULTED';
  }
}

const cancelled = () => Object.assign(new Error('Guest execution cancelled'), { name: 'AbortError', code: 'ABORT_ERR' });
const timerRange = value => Number.isFinite(value) && value > 0 && value <= 0x7fffffff;

export class SerialGuestChannel {
  #channel;
  #queue = [];
  #active;
  #fault;
  #closed = false;
  #dispose;
  #killWaitMs;
  #cleanupDeadline;

  constructor(channel, { killWaitMs = 2000, cleanupDeadline = monotonicDeadline } = {}) {
    if (!timerRange(killWaitMs)) throw new TypeError('Invalid guest exit confirmation deadline');
    if (typeof cleanupDeadline !== 'function') throw new TypeError('Invalid cleanup deadline factory');
    this.#cleanupDeadline = cleanupDeadline;
    this.#channel = channel;
    this.#killWaitMs = killWaitMs;
  }

  get state() { return this.#fault ? 'faulted' : this.#closed ? 'closed' : this.#active ? 'busy' : 'idle'; }

  // channel.exec must synchronously return an operation before starting async IO.
  // operation.finished includes stream EOF and actual native resource cleanup.
  // operation.signal sends TERM/KILL independently of the execution queue.
  execute(request, { signal, graceMs, output } = {}) {
    if (!timerRange(graceMs)) throw new TypeError('Invalid guest termination grace');
    if (this.#fault) return Promise.reject(this.#fault);
    if (this.#closed) return Promise.reject(new GuestChannelFault('Guest channel has closed'));
    if (signal?.aborted) return Promise.reject(cancelled());
    const completion = Promise.withResolvers();
    completion.promise.catch(() => {});
    const job = { request, signal, graceMs, output, completion, phase: 'queued', timers: [] };
    job.abort = () => this.#cancel(job);
    signal?.addEventListener('abort', job.abort, { once: true });
    this.#queue.push(job);
    queueMicrotask(() => this.#next());
    return completion.promise;
  }

  #clear(job) {
    for (const dispose of job.timers) dispose();
    job.timers.length = 0;
    job.signal?.removeEventListener('abort', job.abort);
  }

  #settle(job, result, error) {
    if (job.phase === 'settled') return;
    this.#clear(job);
    job.phase = 'settled';
    if (this.#active === job) this.#active = undefined;
    if (error) job.completion.reject(error);
    else job.completion.resolve(result);
    queueMicrotask(() => this.#next());
  }

  #break(error) {
    if (this.#fault) return;
    this.#fault = error instanceof GuestChannelFault ? error : new GuestChannelFault('Guest resource exit was not confirmed', { cause: error });
    // A rejected waiter does not release native ownership. This instance is now
    // permanently unusable, including after a late exit notification.
    if (this.#active) {
      const job = this.#active;
      if (job.operation && !job.killSent) {
        job.killSent = true;
        try { Promise.resolve(job.operation.signal('SIGKILL')).catch(() => {}); } catch {}
      }
      try { job.operation?.abandon?.(); } catch {}
      this.#settle(job, undefined, this.#fault);
    }
    for (const job of this.#queue.splice(0)) this.#settle(job, undefined, this.#fault);
  }

  #next() {
    if (this.#active || this.#closed || this.#fault) return;
    let job;
    while ((job = this.#queue.shift())) {
      if (job.phase !== 'queued') continue;
      this.#active = job;
      job.phase = 'running';
      try {
        job.operation = this.#channel.exec(job.request, job.output);
        if (job.cancelling) this.#cancelRunning(job);
        // The native transport cannot manufacture resourcesSettled from an HTTP
        // response or the process leader's early exit callback.
        Promise.resolve(job.operation.finished).then(result => {
          if (job.phase === 'settled') return;
          if (result?.resourcesSettled !== true) {
            this.#break(new GuestChannelFault('Guest exited without a cleanup confirmation'));
            return;
          }
          this.#settle(job, result, job.cancelling ? cancelled() : undefined);
        }, error => { if (job.phase !== 'settled') this.#break(error); });
      } catch (error) {
        this.#break(error);
      }
      return;
    }
  }

  #cancel(job) {
    if (job.phase === 'settled' || job.cancelling) return;
    job.cancelling = true;
    if (job.phase === 'queued') {
      const index = this.#queue.indexOf(job);
      if (index >= 0) this.#queue.splice(index, 1);
      this.#settle(job, undefined, cancelled());
      return;
    }
    if (job.operation) this.#cancelRunning(job);
  }

  #after(job, ms, callback) {
    let deadline;
    try { deadline = this.#cleanupDeadline(ms, new Error('Guest cleanup budget elapsed')); }
    catch (error) { this.#break(error); return; }
    const dispose = () => { deadline.signal.removeEventListener('abort', fired); deadline[Symbol.dispose](); };
    const fired = () => { dispose(); if (job.phase !== 'settled') callback(); };
    job.timers.push(dispose);
    if (deadline.signal.aborted) fired();
    else deadline.signal.addEventListener('abort', fired, { once: true });
  }

  #cancelRunning(job) {
    const kill = () => {
      if (job.phase === 'settled' || job.killSent) return;
      job.killSent = true;
      try { Promise.resolve(job.operation.signal('SIGKILL')).catch(() => {}); } catch {}
      this.#after(job, this.#killWaitMs, () => {
        if (job.phase !== 'settled') this.#break(new GuestChannelFault('Guest did not confirm exit after SIGKILL'));
      });
    };
    try { Promise.resolve(job.operation.signal('SIGTERM')).catch(kill); } catch { kill(); }
    if (!job.killSent) this.#after(job, job.graceMs, kill);
  }

  dispose() {
    if (this.#dispose) return this.#dispose;
    this.#closed = true;
    const jobs = [...this.#queue];
    this.#queue.length = 0;
    if (this.#active) jobs.push(this.#active);
    for (const job of jobs) this.#cancel(job);
    this.#dispose = Promise.allSettled(jobs.map(job => job.completion.promise)).then(() => {
      if (this.#fault) throw this.#fault;
    });
    return this.#dispose;
  }
}
