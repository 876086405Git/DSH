import { Worker } from 'node:worker_threads';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { isAbsolute } from 'node:path';

const reject = (code, message) => { throw Object.assign(new Error(message), { code }); };
/** Explicit desktop/device measurement seam. Not registered by product startup. */
export function createPythonProbeHost(addon) {
  const native = createRequire(import.meta.url)(addon);
  const worker = new Worker(new URL('./probe-worker.mjs', import.meta.url), { workerData: { addon } });
  worker.unref();
  let active;
  worker.on('message', result => {
    if (result.stream) { active?.[result.stream](Buffer.from(result.chunk)); return; }
    const pending = active; active = undefined; worker.unref();
    if (result.error) pending.reject(Object.assign(new Error(result.error), { code: 'ERR_OHOS_PYTHON_PROBE' }));
    else { pending.stdout(Buffer.from(result.stdout)); pending.stderr(Buffer.from(result.stderr)); pending.resolve({ exitCode: result.exitCode, signal: null }); }
  });
  worker.on('error', error => { active?.reject(error); active = undefined; });
  worker.unref();
  return { contract: 'dsh-python-1', stdin: 'unsupported',
    start({ argv, cwd, env, stdout, stderr }) {
      if (active) reject('ERR_OHOS_PYTHON_BUSY', 'Probe serializes Python jobs');
      if (cwd !== undefined && cwd !== process.cwd()) reject('ERR_OHOS_PYTHON_CWD', 'Probe cannot change App cwd; use absolute paths or App Linux');
      if (env !== undefined && (Object.keys(env).length !== Object.keys(process.env).length || Object.entries(env).some(([key, value]) => process.env[key] !== value))) reject('ERR_OHOS_PYTHON_ENV', 'Probe cannot change App environment; use App Linux');
      let source, args;
      if (argv[0] === '-c' && argv.length >= 2) { source = argv[1]; args = ['-c', ...argv.slice(2)]; }
      else if (isAbsolute(argv[0] ?? '')) { source = readFileSync(argv[0], 'utf8'); args = argv; }
      else reject('ERR_OHOS_PYTHON_ARGUMENTS', 'Probe supports -c or absolute script paths; pip/-m need the production stdlib host');
      const completion = new Promise((resolve, reject) => { active = { resolve, reject, stdout, stderr }; });
      native.prepare(); worker.ref(); worker.postMessage({ source, args });
      return { completion, cancel() { native.cancel(); } };
    },
  };
}
