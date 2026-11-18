import { realpathSync, statSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Worker } from 'node:worker_threads';
import { inspect } from 'node:util';

// Worker error events may carry any deserialized thrown value, including null.
export function formatNodeScriptError(error) {
  if (error != null && typeof error.stack === 'string') return error.stack;
  return typeof error === 'string' ? error : inspect(error);
}

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

// A fixed data-module entry runs the inherited --import before user code.
// CommonJS Worker({eval:true}) skips that ESM preload path on fixed Node 24.
// Source travels as workerData, never as an expanded URL in the host thread.
const inlineBootstrap = new URL('data:text/javascript;dsh-ohos-inline,' + encodeURIComponent(`
import { createRequire, Module } from 'node:module';
import { Script, constants } from 'node:vm';
import { workerData } from 'node:worker_threads';
import outputConsole from 'node:console';
const { source, mode, filename, base } = workerData.dshOhosNodeScript.inline;
if (mode === 'stdin') process.argv.splice(1, 0, '-');
let script;
try {
  script = new Script(source, { filename: base,
    importModuleDynamically: constants.USE_MAIN_CONTEXT_DEFAULT_LOADER });
} catch (error) {
  if (mode === 'print') throw error;
  await import('dsh-ohos-inline:source');
}
if (script) {
  globalThis.require = createRequire(base);
  globalThis.module = new Module(filename);
  globalThis.module.filename = base;
  globalThis.module.paths = globalThis.require.resolve.paths('_');
  globalThis.exports = globalThis.module.exports;
  globalThis.__filename = filename;
  globalThis.__dirname = '.';
  const result = script.runInThisContext();
  if (mode === 'print') {
    const log = outputConsole.log;
    const print = () => log(result);
    process.on('exit', print);
    process.once('beforeExit', () => { print(); process.off('exit', print); });
  }
}
`));
function inlineEntry(source, mode, cwd) {
  const filename = mode === 'stdin' ? '[stdin]' : '[eval]';
  return { source, mode, filename, base: resolve(cwd, filename) };
}

/** Native script entries preserve CJS/ESM main semantics; inline code uses the same guarded Worker. */
export function createNodeScriptWorker({ args, cwd, roots, workspaceRoots, readOnly = false, env, stdin = '', streamStdin = false }) {
  if (!nodeScriptAvailable()) throw failure('ERR_OHOS_NODE_PRELOAD_REQUIRED', 'Node scripts require the inherited OHOS product preload');
  if (!Array.isArray(args) || args.some(value => typeof value !== 'string' || value.includes('\0'))) throw new TypeError('Node script arguments must be NUL-free strings');
  if (args[0] === '--') args = args.slice(1);
  if (typeof cwd !== 'string' || !isAbsolute(cwd) || !Array.isArray(roots) || !Array.isArray(workspaceRoots)) throw new TypeError('Node script requires explicit absolute working roots');
  const canonicalCwd = realpathSync(cwd);
  const canonicalRoots = roots.map(root => realpathSync(root)), canonicalWorkspaces = workspaceRoots.map(root => realpathSync(root));
  if (canonicalRoots.includes('/') || canonicalWorkspaces.includes('/')
      || !canonicalWorkspaces.some(root => inside(root, canonicalCwd))
      || !canonicalRoots.some(root => inside(root, canonicalCwd))) throw failure('EACCES', 'EACCES: OHOS_SANDBOX_DENIED: Node script entry or cwd is outside the authorized roots');
  if (!statSync(canonicalCwd).isDirectory()) throw failure('ERR_OHOS_NODE_SCRIPT_ARGUMENTS', 'Node script cwd must be a directory');
  if (typeof stdin !== 'string' && !(stdin instanceof Uint8Array)) throw new TypeError('Node script stdin must be a string or byte array');
  let input = Buffer.from(stdin);
  if (input.length > 64 * 1024 * 1024) throw failure('ERR_OHOS_NODE_INPUT_LIMIT', 'Node script batch stdin exceeds 64 MiB');
  let entry, argv, inline;
  if (!args.length || args[0] === '-') {
    if (streamStdin) throw failure('ERR_OHOS_NODE_SCRIPT_ARGUMENTS', 'Streaming stdin requires a script or -e; streaming program source is not supported');
    inline = inlineEntry(input.toString('utf8'), 'stdin', canonicalCwd); entry = inlineBootstrap; argv = args.slice(1); input = Buffer.alloc(0);
  } else if (['-e', '--eval', '-p', '--print'].includes(args[0])) {
    if (args.length < 2) throw failure('ERR_OHOS_NODE_SCRIPT_ARGUMENTS', 'Node eval/print requires source text');
    if (Buffer.byteLength(args[1]) > 64 * 1024 * 1024) throw failure('ERR_OHOS_NODE_INPUT_LIMIT', 'Node inline source exceeds 64 MiB');
    inline = inlineEntry(args[1], ['-p', '--print'].includes(args[0]) ? 'print' : 'eval', canonicalCwd); entry = inlineBootstrap;
    argv = args.slice(args[2] === '--' ? 3 : 2);
  } else if (['-v', '--version'].includes(args[0])) {
    inline = inlineEntry('console.log(process.version)', 'eval', canonicalCwd); entry = inlineBootstrap; argv = []; input = Buffer.alloc(0);
  } else {
    if (!args[0] || args[0].startsWith('-')) throw failure('ERR_OHOS_NODE_SCRIPT_ARGUMENTS', 'Unsupported Node option; use a script, -e, -p, --version or stdin');
    const filename = realpathSync(resolve(canonicalCwd, args[0]));
    if (!canonicalRoots.some(root => inside(root, filename))) throw failure('EACCES', 'EACCES: OHOS_SANDBOX_DENIED: Node script entry is outside the authorized roots');
    if (!statSync(filename).isFile()) throw failure('ERR_OHOS_NODE_SCRIPT_ARGUMENTS', 'Node script entry must be a regular file');
    if (!/\.(?:js|cjs|mjs)$/.test(filename)) throw failure('ERR_OHOS_NODE_SCRIPT_ARGUMENTS', 'This Node Worker backend accepts .js, .cjs and .mjs files');
    entry = pathToFileURL(filename); argv = args.slice(1);
  }
  return new Worker(entry, {
    workerData: { dshOhosNodeScript: { protocol: 1, cwd: canonicalCwd, roots: canonicalRoots,
      workspaceRoots: canonicalWorkspaces, readOnly, stdin: input, streamStdin, inline } },
    argv, env, stdin: streamStdin, stdout: true, stderr: true,
    resourceLimits: { maxOldGenerationSizeMb: 256 },
    // Preserve inherited --jitless and the sole product --import.
  });
}
