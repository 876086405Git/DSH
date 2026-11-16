import { Worker } from 'node:worker_threads';
import { readFileSync, realpathSync, statSync } from 'node:fs';
import { dirname, isAbsolute, resolve, sep } from 'node:path';
import { constants } from 'node:os';
const fail = (code, message) => { throw Object.assign(new Error(message), { code }); };

/** Host-owned configuration only. User argv cannot select an addon, stdlib or root. */
export function createPythonHost({ addon, home, paths, roots, readOnly = false, caFile, approvedLibraries = [] }) {
  // Distribution extension modules resolve the public CPython ABI from the
  // embedding process; a local-only libpython dependency cannot satisfy them.
  const module = { exports: {} }; process.dlopen(module, addon, constants.dlopen.RTLD_NOW | constants.dlopen.RTLD_GLOBAL); const native = module.exports;
  roots = roots.map(root => {
    root = realpathSync(root);
    if (root === sep || !statSync(root).isDirectory()) fail('ERR_OHOS_PYTHON_ROOT', 'Explicit non-root workspace required');
    return root;
  });
  const worker = new Worker(new URL('./host-worker.mjs', import.meta.url), { workerData: { addon, home, paths } });
  let active, ready = false, failed, closed = false, finished = false, disposal;
  const exited = Promise.withResolvers(); exited.promise.catch(() => {});
  const notStarted = () => Object.assign(new Error('Python job ended before admission'), { code: 'ERR_OHOS_NOT_STARTED' });
  worker.on('message', message => {
    if (message.ready) { ready = true; if (active) dispatch(); else if (!closed) worker.unref(); return; }
    if (!active) return;
    if (message.started) { active.started.resolve(); return; }
    if (message.stream) { active[message.stream](Buffer.from(message.chunk)); return; }
    const pending = active; active = undefined; if (!closed) worker.unref();
    if (message.error) {
      const error = Object.assign(new Error(message.error), { code: message.code ?? 'ERR_OHOS_PYTHON_NATIVE' });
      pending.started.reject(error); pending.reject(error);
    } else { pending.started.reject(notStarted()); pending.resolve({ exitCode: message.result.exitCode, signal: null }); }
  });
  worker.on('error', error => { failed = error; });
  worker.on('exit', code => {
    finished = true;
    if (!closed || code !== 0 || active) failed ??= Object.assign(new Error(`Python owner exited unexpectedly (${code})`), { code: 'ERR_OHOS_PYTHON_OWNER_EXIT' });
    if (active) { active.started.reject(failed); active.reject(failed); active = undefined; }
    if (failed) exited.reject(failed); else exited.resolve();
  });
  function dispatch() {
    if (active.cancelled) {
      const pending = active; active = undefined;
      pending.started.reject(notStarted()); pending.resolve({ exitCode: null, signal: 'SIGTERM' });
      if (!closed) worker.unref();
      return;
    }
    native.prepare(); worker.ref(); worker.postMessage(active.request);
    active.dispatched = true;
  }
  return { contract: 'dsh-python-1', stdin: 'unsupported',
    start({ argv, cwd, env, stdout, stderr }) {
      if (closed) fail('ERR_OHOS_PYTHON_CLOSED', 'Python owner is closed');
      if (failed) throw failed;
      if (active) fail('ERR_OHOS_PYTHON_BUSY', 'Python lane already has a job');
      if (!isAbsolute(cwd ?? '')) fail('ERR_OHOS_PYTHON_CWD', 'Absolute cwd required');
      cwd = realpathSync(cwd);
      if (!roots.some(root => cwd === root || cwd.startsWith(root + sep)) || !statSync(cwd).isDirectory()) fail('ERR_OHOS_PYTHON_PATH', 'cwd is outside authorized roots');
      let source, args, file;
      if (argv[0] === '-c' && argv.length >= 2) { source = argv[1]; args = ['-c', ...argv.slice(2)]; }
      else if (argv[0] && !argv[0].startsWith('-')) {
        file = realpathSync(resolve(cwd, argv[0]));
        if (!roots.some(root => file.startsWith(root + sep))) fail('ERR_OHOS_PYTHON_PATH', 'Script is outside authorized roots');
        source = readFileSync(file, 'utf8'); args = [file, ...argv.slice(1)];
      } else fail('ERR_OHOS_PYTHON_ARGUMENTS', 'Supported: python3 -c CODE or a script; pip/-m require App Linux');
      const context = { cwd, env: env ?? {}, roots, readOnly, argv: args, caFile, approvedLibraries,
        filename: file ?? '<string>', ...(file ? { scriptDirectory: dirname(file), scriptFile: file } : {}) };
      const started = Promise.withResolvers(); started.promise.catch(() => {});
      const completion = new Promise((resolve, reject) => { active = { resolve, reject, started, stdout, stderr,
        request: { source, context }, cancelled: false, dispatched: false }; });
      completion.catch(() => {});
      const pending = active;
      if (ready) dispatch();
      return { completion, started: started.promise,
        cancel() { if (active === pending && !pending.cancelled) { pending.cancelled = true; if (pending.dispatched) native.cancel(); } } };
    },
    dispose() {
      if (disposal) return disposal;
      closed = true;
      if (active) {
        if (!active.cancelled) { active.cancelled = true; if (active.dispatched) native.cancel(); }
        if (!active.dispatched) dispatch();
      }
      if (!finished) { worker.ref(); worker.postMessage({ close: true }); }
      // Closing the port permits natural Worker exit; CPython's main
      // interpreter remains quarantined and is never finalized or restarted.
      return disposal = exited.promise;
    },
  };
}
