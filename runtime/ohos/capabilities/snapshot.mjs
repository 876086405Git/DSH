import { readPublicationCapabilities } from '../publication/capabilities.mjs';

const support = value => value === true ? 'supported' : value === false ? 'unsupported' : 'unknown';
const choice = (value, allowed) => allowed.includes(value) ? value : 'unknown';

// A registered, live boundary owner is required. A GET only reads its state;
// it never opens a journal, acknowledges an unknown, or resumes any work.
function lifecycleCapabilities(ctx) {
  try {
    const owner = ctx.get('ohosLifecycle');
    if (owner?.protocolVersion === 1 && typeof owner.status === 'function') {
      const state = owner.status();
      if (state?.v === 1 && state.closed === false) return {
        computePermission: choice(state.host?.computePermission, ['granted', 'denied']),
        resume: state.blocked === false ? 'reconcile' : 'none',
      };
    }
  } catch {}
  return { computePermission: 'unknown', resume: 'none' };
}

// Read installed services only. This must not load an addon, probe a command,
// inspect the filesystem, or retry a publication while answering a GET.
export function runtimeCapabilities(ctx, bootId) {
  const subprocess = ctx.get('subprocess')?.capabilities;
  const shell = ctx.get('shell');
  const storage = ctx.get('sessionPersistence')?.dshGoRuntimeCapabilities;
  const loader = ctx.get('loader');
  const bundles = ctx.get('profileContext')?.startedBundles;
  const bundled = Array.isArray(bundles) && bundles.length > 0 && loader !== undefined &&
    [...loader.entries()].some(entry => !entry.disabled && entry.fiber?.state === 2 &&
      typeof entry.options.name === 'string' && entry.options.name.startsWith('@deepseek-ai/'));
  const commands = subprocess?.commands;
  return {
    v: 1, bootId, platform: process.platform, arch: process.arch,
    nodeVersion: process.versions.node, simulated: globalThis[Symbol.for('dsh.go.ohos.sim')] === true,
    shell: {
      kind: shell === undefined ? 'none' : choice(subprocess?.kind, ['virtual', 'system', 'none']),
      commands: shell === undefined ? [] : Array.isArray(commands) && commands.every(value => typeof value === 'string') ? [...commands] : null,
      pty: shell === undefined ? 'unsupported' : support(subprocess?.pty),
    },
    processSpawn: support(subprocess?.processSpawn),
    nodeScripts: choice(subprocess?.nodeScripts, ['worker', 'worker-rebased', 'process', 'none']),
    python: support(subprocess?.python),
    // Presence alone does not prove that code generation is permitted.
    wasm: typeof globalThis.WebAssembly === 'undefined' ? 'unsupported' : 'unknown',
    plugins: { bundled: bundled ? 'supported' : 'unknown', marketInstall: 'unsupported' },
    // The signed HAP's native inventory and per-module load observations are
    // not yet supplied by the host. Do not turn a package name into "loaded".
    nativeModules: null,
    storage: { sessionLock: choice(storage?.sessionLock, ['kernel', 'main-thread', 'none']) },
    background: { policy: 'may-freeze', ...lifecycleCapabilities(ctx) },
    ...readPublicationCapabilities(),
  };
}
