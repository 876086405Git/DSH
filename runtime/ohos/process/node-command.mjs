import { createNodeScriptWorker, formatNodeScriptError } from './node-script.mjs';

/** Preserve just-bash routing: a node command is buffered inside its statement. */
export function nodeCommand({ roots, workspaceRoots, readOnly }) {
  return async (args, ctx) => {
    ctx.signal?.throwIfAborted();
    let worker;
    try {
      const env = Object.fromEntries(ctx.env);
      if (globalThis[Symbol.for('dsh.go.ohos.sim')] === true && process.env.DSH_GO_OHOS_SIM_PLATFORM) env.DSH_GO_OHOS_SIM_PLATFORM = process.env.DSH_GO_OHOS_SIM_PLATFORM;
      worker = createNodeScriptWorker({ args, cwd: ctx.cwd, roots, workspaceRoots, readOnly,
        env, stdin: Buffer.from(ctx.stdin, 'latin1') });
    } catch (error) {
      return { stdout: '', stderr: `${error.code ?? 'ERR_OHOS_NODE_SCRIPT'}: ${error.message}\n`,
        exitCode: error.code === 'ERR_OHOS_NODE_SCRIPT_ARGUMENTS' ? 2 : error.code === 'ERR_OHOS_NODE_PRELOAD_REQUIRED' ? 127 : 1 };
    }
    const result = await new Promise(resolve => {
      const output = { stdout: [], stderr: [] }; let bytes = 0, overflow = false;
      const abort = () => { void worker.terminate(); };
      ctx.signal?.addEventListener('abort', abort, { once: true });
      if (ctx.signal?.aborted) abort();
      for (const name of ['stdout', 'stderr']) worker[name].on('data', chunk => {
        bytes += chunk.length;
        if (bytes > 64 * 1024 * 1024) { overflow = true; void worker.terminate(); return; }
        output[name].push(Buffer.from(chunk));
      });
      worker.on('error', error => output.stderr.push(Buffer.from(formatNodeScriptError(error) + '\n')));
      worker.once('exit', exitCode => {
        ctx.signal?.removeEventListener('abort', abort);
        resolve({ stdout: Buffer.concat(output.stdout).toString('latin1'), stdoutKind: 'bytes',
          stderr: Buffer.concat(output.stderr).toString('latin1') + (overflow ? 'ERR_OHOS_NODE_OUTPUT_LIMIT: Node command output exceeds 64 MiB\n' : ''), stderrKind: 'bytes',
          // Match an external POSIX command before Bash tests the status.
          exitCode: overflow ? 1 : (exitCode & 0xff) });
      });
    });
    ctx.signal?.throwIfAborted();
    return result;
  };
}
