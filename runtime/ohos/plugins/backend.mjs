import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { createRegistry, parseRegistrySpec } from './registry.mjs';
import { runProfileOperation } from './installer.mjs';
import { beginTransaction, recoverProfile, transactionFor } from './store.mjs';
import { installPluginResolution } from './resolution.mjs';

const require = createRequire(new URL('../../../package.json', import.meta.url));

export function createPluginBackend({ fetchImpl = globalThis.fetch } = {}) {
  installPluginResolution();
  return {
    recoverProfile,
    begin(profile) { return beginTransaction(profile.dir); },
    restore(dir) { transactionFor(dir).rollbackAttempt(); },
    registry() { return 'https://registry.npmjs.org/'; },
    accepts(spec) {
      try { parseRegistrySpec(spec); return true; } catch { return false; }
    },
    async view(dir, spec, options) {
      try {
        recoverProfile(dir);
        const registry = createRegistry({ registry: options.registry ?? 'https://registry.npmjs.org',
          fetchImpl, signal: options.signal, timeoutMs: options.timeoutMs });
        const answer = await registry.view(spec, options.fields);
        return { exitCode: 0, stdout: JSON.stringify(answer), stderr: '', timedOut: false };
      } catch (error) {
        return { exitCode: 1, stdout: '', stderr: `${error.code ?? error.name}: ${error.message}`,
          timedOut: error.name === 'TimeoutError', ...(options.signal?.aborted ? { cause: error } : {}) };
      }
    },
    async run(context, args, options) {
      const { createRuntimeResolution } = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-app-boot')));
      const resolution = await createRuntimeResolution({ installAnchor: context.installAnchor, home: context.home });
      const hostPackages = new Map(resolution.entries.filter(entry => entry.scope === 'installation').map(entry => [entry.name, entry]));
      return runProfileOperation(context, args, { ...options, fetchImpl, hostPackages });
    },
  };
}
