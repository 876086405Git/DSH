import { realpathSync, statSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Worker } from 'node:worker_threads';

const failure = (code, message) => Object.assign(new Error(message), { code });
const inside = (root, path) => path === root || path.startsWith(root + '/');
const preloadURLs = [new URL('../preload.mjs', import.meta.url).href, new URL('./node-worker-preload.mjs', import.meta.url).href];
export function nodeScriptAvailable() {
  if (globalThis[Symbol.for('dsh.go.ohos.nodeWorker.preload')] !== 1) return false;
  const flags = process.execArgv;
  for (let index = 0; index < flags.length; index++) {
    const value = flags[index] === '--import' ? flags[++index] : flags[index].startsWith('--import=') ? flags[index].slice(9) : undefined;
    if (value === undefined) continue;
    let url;
    try { url = value.startsWith('file:') ? new URL(value).href : pathToFileURL(resolve(value)).href; }
    catch { continue; }
    if (preloadURLs.includes(url)) return true;
  }
  return false;
}

/** A native Worker entry preserves CJS require.main and ESM import.meta.main. */
export function createNodeScriptWorker({ args, cwd, roots, workspaceRoots, readOnly = false, env, stdin = '' }) {
  if (!nodeScriptAvailable()) throw failure('ERR_OHOS_NODE_PRELOAD_REQUIRED', 'Node scripts require the inherited OHOS product preload');
  if (!Array.isArray(args) || args.some(value => typeof value !== 'string' || value.includes('\0'))) throw new TypeError('Node script arguments must be NUL-free strings');
  if (args[0] === '--') args = args.slice(1);
  if (!args.length || !args[0] || args[0].startsWith('-')) throw failure('ERR_OHOS_NODE_SCRIPT_ARGUMENTS', 'Only node <script.js|script.cjs|script.mjs> [arguments] is available');
  if (typeof cwd !== 'string' || !isAbsolute(cwd) || !Array.isArray(roots) || !Array.isArray(workspaceRoots)) throw new TypeError('Node script requires explicit absolute working roots');
  const canonicalCwd = realpathSync(cwd), entry = realpathSync(resolve(canonicalCwd, args[0]));
  const canonicalRoots = roots.map(root => realpathSync(root)), canonicalWorkspaces = workspaceRoots.map(root => realpathSync(root));
  if (canonicalRoots.includes('/') || canonicalWorkspaces.includes('/')
      || !canonicalWorkspaces.some(root => inside(root, canonicalCwd))
      || !canonicalRoots.some(root => inside(root, entry))) throw failure('EACCES', 'EACCES: OHOS_SANDBOX_DENIED: Node script entry or cwd is outside the authorized roots');
  if (!statSync(canonicalCwd).isDirectory() || !statSync(entry).isFile()) throw failure('ERR_OHOS_NODE_SCRIPT_ARGUMENTS', 'Node script entry must be a regular file and cwd a directory');
  if (!/\.(?:js|cjs|mjs)$/.test(entry)) throw failure('ERR_OHOS_NODE_SCRIPT_ARGUMENTS', 'This Node Worker backend accepts .js, .cjs and .mjs files');
  if (typeof stdin !== 'string' && !(stdin instanceof Uint8Array)) throw new TypeError('Node script stdin must be a string or byte array');
  const input = Buffer.from(stdin);
  if (input.length > 64 * 1024 * 1024) throw failure('ERR_OHOS_NODE_INPUT_LIMIT', 'Node script batch stdin exceeds 64 MiB');
  const worker = new Worker(pathToFileURL(entry), {
    workerData: { dshOhosNodeScript: { protocol: 1, cwd: canonicalCwd, roots: canonicalRoots,
      workspaceRoots: canonicalWorkspaces, readOnly, stdin: input } },
    argv: args.slice(1), env, stdout: true, stderr: true,
    resourceLimits: { maxOldGenerationSizeMb: 256 },
    // Do not supply execArgv: Node rejects explicitly supplied --jitless. Its
    // inherited V8 flags and sole product --import remain in force by default.
  });
  return worker;
}
