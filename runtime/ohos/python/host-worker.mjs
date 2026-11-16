import { parentPort, workerData } from 'node:worker_threads';
import { readFileSync } from 'node:fs';
import { constants } from 'node:os';
const module = { exports: {} };
process.dlopen(module, workerData.addon, constants.dlopen.RTLD_NOW | constants.dlopen.RTLD_GLOBAL);
const native = module.exports;
native.initialize(workerData.home, workerData.paths);
const platform = readFileSync(new URL('./platform.py', import.meta.url), 'utf8');
parentPort.postMessage({ ready: true });
parentPort.on('message', ({ source, context, close }) => {
  if (close) { parentPort.close(); return; }
  parentPort.postMessage({ started: true });
  const pending = { stdout: [], stderr: [] }, sizes = { stdout: 0, stderr: 0 };
  let total = 0, emitted = false, last = performance.now();
  const flush = () => {
    for (const stream of ['stdout', 'stderr']) if (sizes[stream]) {
      parentPort.postMessage({ stream, chunk: Buffer.concat(pending[stream], sizes[stream]) });
      pending[stream] = []; sizes[stream] = 0;
    }
    emitted = true; last = performance.now();
  };
  const output = (stream, chunk) => {
    total += chunk.length;
    if (total > 16 * 1024 * 1024) throw Object.assign(new Error('Python output exceeds 16 MiB; use App Linux for larger output'), { code: 'ERR_OHOS_PYTHON_OUTPUT_LIMIT' });
    pending[stream].push(chunk); sizes[stream] += chunk.length;
    if (!emitted || sizes[stream] >= 16384 || performance.now() - last >= 10) flush();
  };
  try {
    const encoded = JSON.stringify(JSON.stringify(context));
    // Execute host adaptation and user code with explicit fresh __main__ globals.
    const program = `import json,types,sys\n${platform}\n_dsh_context=json.loads(${encoded})\n_dsh_install(_dsh_context)\n` +
      `_dsh_main=types.ModuleType('__main__')\nsys.modules['__main__']=_dsh_main\n` +
      `if 'scriptFile' in _dsh_context: _dsh_main.__file__=_dsh_context['scriptFile']\n` +
      `exec(compile(json.loads(${JSON.stringify(JSON.stringify(source))}), _dsh_context['filename'], 'exec'), _dsh_main.__dict__)\n`;
    const result = JSON.parse(native.run(program, 30000,
      output));
    flush(); parentPort.postMessage({ result });
  } catch (error) { flush(); parentPort.postMessage({ error: error.message, code: error.code }); }
});
