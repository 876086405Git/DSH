// Test Worker boundary: actual fixed Bash, filesystem, N-API and directory-FD service.
import { parentPort, workerData } from 'node:worker_threads';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
let filesystem;
const reply = {};
try {
  const binding = createRequire(import.meta.url)(workerData.binding);
  const base = pathToFileURL(workerData.processDirectory + '/');
  const { Bash } = await import(new URL('build/just-bash/index.js', base));
  const { createFilesystem } = await import(new URL('filesystem.mjs', base));
  filesystem = createFilesystem([workerData.temporary], { mode: workerData.readOnly ? 'read-only' : 'workspace-write' },
    { grantMounts: workerData.mounts, binding });
  const bash = new Bash({ fs: filesystem.fs, cwd: workerData.cwd, env: {},
    javascript: false, python: false, defenseInDepth: false });
  filesystem.seal();
  reply.result = await bash.exec(workerData.script);
  if (workerData.observed) {
    reply.observation = (await import(pathToFileURL(path.join(workerData.processDirectory, 'files/copy-observer.mjs')))).observations();
  }
} catch (error) {
  reply.failure = { name: error.name, code: error.code ?? null, message: error.message, stack: error.stack };
} finally {
  try { filesystem?.close(); reply.filesystemClosed = true; }
  catch (error) { reply.closeFailure = { name: error.name, code: error.code ?? null, message: error.message }; }
  parentPort.postMessage(reply);
  parentPort.close();
}
