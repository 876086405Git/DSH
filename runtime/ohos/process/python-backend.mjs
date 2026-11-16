import { EventEmitter } from 'node:events';
import { PassThrough, Writable } from 'node:stream';

const failure = (code, message) => Object.assign(new Error(message), { code });
export const pythonCommandName = command => /^(?:\/(?:usr\/)?bin\/)?(python3?|pip)$/.exec(command)?.[1];

/** Host-injected backend. No process-wide builtin patch and no platform spoof. */
export function createPythonBackend({ native } = {}) {
  return {
    supports(command) { return pythonCommandName(command) !== undefined; },
    spawn(command, args = [], { cwd, env, signal, timeoutMs } = {}) {
      const name = pythonCommandName(command);
      if (!name) throw failure('ERR_OHOS_PYTHON_COMMAND', `Unknown Python command: ${command}`);
      if (!native || native.contract !== 'dsh-python-1') throw failure('ERR_OHOS_PYTHON_UNAVAILABLE',
        'Native Python host is unavailable; run this command in App Linux or on a connected computer.');
      if (args.some(arg => typeof arg !== 'string' || arg.includes('\0'))) throw new TypeError('Python argv must contain strings without NUL');
      if (timeoutMs !== undefined && (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || timeoutMs > 2147483647)) throw new RangeError('Invalid Python timeoutMs');
      signal?.throwIfAborted();
      const child = new EventEmitter();
      const started = Promise.withResolvers();
      child.started = started.promise; child.started.catch(() => {});
      let inputError;
      child.stdin = native.stdin === 'unsupported' ? new Writable({ write(chunk, encoding, callback) {
        if (!chunk.length) { callback(); return; }
        inputError ??= failure('ERR_OHOS_PYTHON_STDIN', 'This Python host does not support stdin; use App Linux.');
        child.kill(); callback(inputError);
      } }) : new PassThrough();
      child.stdin.on('error', error => { inputError ??= error; });
      child.stdout = new PassThrough(); child.stderr = new PassThrough();
      child.exitCode = null; child.signalCode = null;
      const argv = name === 'pip' ? ['-m', 'pip', ...args] : [...args];
      let job, done = false, requestedSignal, timer;
      const finish = ({ exitCode, signal: exitSignal = null }, cause) => {
        if (done) return;
        done = true; clearTimeout(timer); signal?.removeEventListener('abort', abort);
        started.reject(cause ?? inputError ?? failure('ERR_OHOS_NOT_STARTED', 'Python job ended before admission'));
        if (inputError) { exitCode = 1; exitSignal = null; child.stderr.write(`${inputError.code}: ${inputError.message}\n`); }
        child.exitCode = exitCode; child.signalCode = exitSignal;
        child.stdin.destroy(); child.stdout.end(); child.stderr.end();
        child.emit('exit', exitCode, exitSignal);
        // Native completion must follow its final output callback.
        setImmediate(() => child.emit('close', exitCode, exitSignal));
      };
      child.kill = (name = 'SIGTERM') => {
        if (done) return false;
        if (!['SIGTERM', 'SIGINT'].includes(name)) throw failure('ERR_OHOS_PYTHON_SIGNAL',
          'Embedded Python supports cooperative SIGTERM/SIGINT only; hard termination requires App Linux.');
        if (requestedSignal) return true;
        requestedSignal = name; job?.cancel(name); return true;
      };
      const abort = () => child.kill('SIGTERM');
      // Defer host entry so consumers can attach error/output listeners first.
      queueMicrotask(() => {
        try {
          if (inputError || requestedSignal || signal?.aborted) { finish({ exitCode: null, signal: requestedSignal ?? 'SIGTERM' }); return; }
          job = native.start({ argv, cwd, env, stdin: child.stdin,
            stdout: chunk => { if (!done) child.stdout.write(chunk); },
            stderr: chunk => { if (!done) child.stderr.write(chunk); } });
          Promise.resolve(job.started).then(() => {
            if (!done) { started.resolve(); child.emit('spawn'); }
          }, started.reject);
          if (requestedSignal) job.cancel(requestedSignal);
          signal?.addEventListener('abort', abort, { once: true });
          if (signal?.aborted) abort();
          if (timeoutMs !== undefined) {
            timer = setTimeout(abort, timeoutMs);
          }
          Promise.resolve(job.completion).then(finish, error => { child.emit('error', error); finish({ exitCode: 1 }, error); });
        } catch (error) { job?.cancel('SIGTERM'); child.emit('error', error); finish({ exitCode: 1 }, error); }
      });
      return child;
    },
  };
}

/** Existing VirtualSubprocessRuntime job shape; collector is its OutputCollector factory. */
export function createPythonRuntimeBackend({ native, createCollector } = {}) {
  const backend = createPythonBackend({ native });
  const live = new Set(), resourceFailures = new Set();
  let closed = false, disposal;
  return {
    supports: backend.supports,
    live,
    get closed() { return closed; },
    capabilities: Object.freeze({ confinement: 'none', trustedOnly: true }),
    spawn(spec) {
      if (closed) throw failure('ERR_OHOS_PYTHON_CLOSED', 'Python command provider is closed');
      if (spec.policy !== undefined) throw failure('ERR_OHOS_PYTHON_CONFINEMENT', 'Embedded Python cannot enforce a prepared confinement policy; use App Linux.');
      if (!Number.isFinite(spec.graceMs) || spec.graceMs <= 0 || spec.graceMs > 2147483647) throw new RangeError('Invalid graceMs');
      if (spec.stdio.control === 'pipe') throw failure('ERR_OHOS_PYTHON_CONTROL', 'Python has no control channel');
      const collected = {};
      for (const name of ['stdout', 'stderr']) {
        const mode = spec.stdio[name];
        if (mode !== 'pipe' && mode !== 'inherit') {
          if (typeof createCollector !== 'function') throw failure('ERR_OHOS_PYTHON_COLLECTOR', 'Host must provide its OutputCollector factory');
          collected[name] = createCollector(mode, name);
        }
      }
      const child = backend.spawn(spec.argv[0], spec.argv.slice(1), spec);
      let error, finished = false;
      for (const name of ['stdout', 'stderr']) {
        if (collected[name]) child[name].on('data', bytes => {
          try { collected[name].push(bytes); } catch (cause) { error ??= cause; child.kill(); }
        });
        else if (spec.stdio[name] === 'inherit') child[name].pipe(process[name], { end: false });
      }
      child.on('error', cause => { error ??= cause; });
      const done = new Promise((resolve, reject) => child.once('close', (exitCode, signal) => {
        finished = true;
        for (const collector of Object.values(collected)) {
          try { collector.seal(); } catch (cause) { error ??= cause; resourceFailures.add(cause); }
        }
        live.delete(handle);
        if (error) reject(error); else resolve({ exitCode, signal });
      }));
      done.catch(() => {});
      if (spec.stdio.stdin !== 'pipe') child.stdin.end(spec.stdio.stdin === 'ignore' ? undefined : spec.stdio.stdin.data);
      const handle = {
        stdin: spec.stdio.stdin === 'pipe' ? child.stdin : undefined,
        stdout: spec.stdio.stdout === 'pipe' ? child.stdout : undefined,
        stderr: spec.stdio.stderr === 'pipe' ? child.stderr : undefined,
        control: undefined, collected, done, started: child.started,
        terminate(signal) { child.kill(signal); },
        async waitForExit(signal) {
          if (finished) { await done; return true; }
          if (signal?.aborted) return false;
          let abort;
          const stopped = new Promise(resolve => { abort = () => resolve(false); signal?.addEventListener('abort', abort, { once: true }); });
          try { return await Promise.race([done.then(() => true), stopped]); }
          finally { signal?.removeEventListener('abort', abort); }
        },
      };
      live.add(handle);
      return handle;
    },
    dispose() {
      if (disposal) return disposal;
      closed = true;
      const jobs = [...live];
      for (const job of jobs) job.terminate();
      return disposal = (async () => {
        await Promise.allSettled(jobs.map(job => job.done));
        if (typeof native?.dispose !== 'function') throw failure('ERR_OHOS_PYTHON_DISPOSE', 'Python host does not provide an owner exit barrier');
        try { await native.dispose(); } catch (error) { resourceFailures.add(error); }
        if (resourceFailures.size === 1) throw [...resourceFailures][0];
        if (resourceFailures.size) throw new AggregateError([...resourceFailures], 'Python owner resources did not close cleanly');
      })();
    },
  };
}
