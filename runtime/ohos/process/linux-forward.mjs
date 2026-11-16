// just-bash runs in a Worker; a Linux command inside a script asks the parent
// to run it as one guest job and gets its buffered output back.
const runType = 'dsh-ohos-linux-run';
const cancelType = 'dsh-ohos-linux-cancel';
const resultType = 'dsh-ohos-linux-result';
const bytes = value => Buffer.from(value.buffer, value.byteOffset, value.byteLength);

/** Worker side: one just-bash command per forwarded name. */
export function createLinuxForwardClient(port) {
  const pending = new Map();
  let sequence = 0, unavailable = false;
  const receive = message => {
    if (message?.type !== resultType || !pending.has(message.id)) return;
    pending.get(message.id).resolve(message);
    pending.delete(message.id);
  };
  const close = () => {
    port.off('message', receive);
    for (const item of pending.values()) item.reject(Object.assign(new Error('Linux command channel closed'), { code: 'ERR_OHOS_LINUX_CHANNEL_CLOSED' }));
    pending.clear();
  };
  port.on('message', receive);
  port.once('close', close);
  const command = name => async (args, ctx) => {
    ctx.signal?.throwIfAborted();
    const argv = name === 'linux' ? args : [name, ...args];
    if (!argv.length) return { stdout: '', stderr: 'usage: linux <command> [argument...]\n', exitCode: 2 };
    const id = ++sequence, result = Promise.withResolvers();
    pending.set(id, result);
    const abort = () => port.postMessage({ type: cancelType, id });
    ctx.signal?.addEventListener('abort', abort, { once: true });
    try {
      port.postMessage({ type: runType, id, argv, cwd: ctx.cwd, env: Object.fromEntries(ctx.env),
        stdin: Buffer.from(ctx.stdin, 'latin1') });
      const reply = await result.promise;
      ctx.signal?.throwIfAborted();
      unavailable = reply.exitCode === 127;
      return { stdout: bytes(reply.stdout).toString('latin1'), stdoutKind: 'bytes',
        stderr: bytes(reply.stderr).toString('latin1'), stderrKind: 'bytes', exitCode: reply.exitCode };
    } finally {
      pending.delete(id);
      ctx.signal?.removeEventListener('abort', abort);
    }
  };
  // Its own 127 already says why; the shell's generic hint would contradict it.
  return Object.freeze({ command, close, get unavailable() { return unavailable; } });
}

/**
 * Parent side, bound to one shell Worker and its outer job's authority: a
 * forwarded command gets the same workspace root and mode, never more. It
 * wraps the Worker's other resource server so both share one lifecycle.
 */
export function createLinuxForwardServer({ linux, workspaceRoot, mode, send, next }) {
  const jobs = new Map();
  let stopped = false;
  return Object.freeze({
    handle(message) {
      if (message?.type === cancelType) { jobs.get(message.id)?.abort(); return true; }
      if (message?.type !== runType) return next?.handle(message) ?? false;
      const { id, argv, cwd, env, stdin } = message, controller = new AbortController();
      if (stopped) controller.abort();
      const work = linux.forward({ argv, cwd, env, stdin: bytes(stdin), policy: { mode, workspaceRoot }, signal: controller.signal })
        .then(result => send({ type: resultType, id, ...result }))
        // A Worker that is already gone cannot receive its result.
        .catch(() => {})
        .finally(() => jobs.delete(id));
      jobs.set(id, { abort: () => controller.abort(), work });
      return true;
    },
    stop() {
      stopped = true;
      for (const job of jobs.values()) job.abort();
      next?.stop();
    },
    async finish(options) {
      await Promise.allSettled([...jobs.values()].map(job => job.work));
      await next?.finish(options);
    },
  });
}
