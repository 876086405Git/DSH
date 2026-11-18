import nodeVersion from '../node-version.json' with { type: 'json' };
import { isMainThread } from 'node:worker_threads';
import { realpath, stat } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { isAbsolute, join, parse } from 'node:path';
import { createAtomicPublisher } from './atomic.mjs';
import { openOwnershipLedger } from './ledger.mjs';
import { openAtomicFuse, readSystemBuildIdentity } from './atomic-fuse.mjs';

export const publicationSymbol = Symbol.for('dsh.go.ohos.publication');
const simulationSymbol = Symbol.for('dsh.go.ohos.sim');
let installing = false;
let installedOwnership;

// Borrow the one already-open main-engine ledger. A subprocess job must not
// acquire a second flock, close this process-wide owner, or use the publication
// state slot for unrelated Git data. Workers receive only a job-bound RPC.
export function borrowInstalledOwnership() {
  if (!isMainThread) {
    throw Object.assign(new Error('Ownership resources belong to the main engine'),
      { code: 'ERR_OHOS_OWNERSHIP_MAIN_THREAD' });
  }
  if (!installedOwnership) {
    throw Object.assign(new Error('The main-engine ownership service is unavailable'),
      { code: 'ERR_OHOS_OWNERSHIP_UNAVAILABLE' });
  }
  return installedOwnership;
}

export async function installPublication() {
  if (process.platform !== 'openharmony' && globalThis[simulationSymbol] !== true) {
    return { installed: false, reason: 'not-openharmony' };
  }
  // Worker startup inherits --import arguments. This service belongs to the
  // single main engine; unrelated virtual shell workers must remain startable.
  if (!isMainThread) return { installed: false, reason: 'not-main-thread' };
  if (process.versions.node !== nodeVersion) {
    throw Object.assign(new Error(`OpenHarmony publication requires Node ${nodeVersion}`),
      { code: 'ERR_OHOS_PUBLICATION_NODE_VERSION' });
  }
  if (installing || Object.hasOwn(globalThis, publicationSymbol)) {
    throw Object.assign(new Error('OpenHarmony publication service is already registered'),
      { code: 'ERR_OHOS_PUBLICATION_DUPLICATE' });
  }
  let binding;
  try { binding = process._linkedBinding('dsh_ohos_publication'); }
  catch (cause) {
    throw Object.assign(new Error('OpenHarmony publication linked binding is unavailable', { cause }),
      { code: 'ERR_OHOS_PUBLICATION_BINDING_MISSING' });
  }
  const required = ['renameNoReplace', 'lockExclusive', 'setOwnershipMarker', 'getOwnershipMarker', 'getSystemBuildIdentity'];
  if (required.some(name => typeof binding[name] !== 'function')) {
    throw Object.assign(new Error('OpenHarmony publication binding lacks required ownership operations'),
      { code: 'ERR_OHOS_PUBLICATION_BINDING_INVALID' });
  }
  installing = true;
  let ledger;
  try {
    const configuredHome = process.env.DSH_HOME;
    let home;
    try {
      if (typeof configuredHome !== 'string' || !isAbsolute(configuredHome) || configuredHome.includes('\0')) {
        throw new TypeError('DSH_HOME must be explicitly set to an absolute existing app-data directory');
      }
      home = await realpath(configuredHome);
      if (home === parse(home).root || !(await stat(home)).isDirectory()) {
        throw new TypeError('DSH_HOME must be an existing app-data directory other than the filesystem root');
      }
    } catch (cause) {
      throw Object.assign(new Error('OpenHarmony publication requires an explicit valid DSH_HOME', { cause }),
        { code: 'ERR_OHOS_PUBLICATION_DATA_DIRECTORY' });
    }
    // Read the actual platform identity before opening or mutating old state.
    // No environment variable, Node version or kernel release substitutes it.
    const build = readSystemBuildIdentity(binding.getSystemBuildIdentity);
    ledger = await openOwnershipLedger({
      directory: join(home, 'ohos-ownership'),
      ownerId: randomUUID(),
      lockExclusive: binding.lockExclusive,
      setOwnershipMarker: binding.setOwnershipMarker,
      getOwnershipMarker: binding.getOwnershipMarker,
    });
    const recovered = await ledger.recover();
    const atomicFuse = await openAtomicFuse({ storage: ledger.publicationAtomicState,
      ownerId: ledger.ownerId, systemVersion: build.systemVersion });
    const recoverySummary = Object.freeze(Object.fromEntries(Object.entries(recovered)
      .map(([name, rows]) => [name, Object.freeze(rows.map(row => Object.freeze({ ...row })))])));
    if (recoverySummary.unresolved.length) {
      process.emitWarning(`${recoverySummary.unresolved.length} publication ownership record(s) could not be safely recovered and were preserved.`,
        { code: 'OHOS_PUBLICATION_RECOVERY_UNRESOLVED' });
    }
    let fallbackWarningIssued = false;
    const publish = createAtomicPublisher({
      renameNoReplace: binding.renameNoReplace,
      ledger,
      atomicFuse,
      onFallback({ reason }) {
        if (fallbackWarningIssued) return;
        fallbackWarningIssued = true;
        const basis = reason === 'disabled-after-crash'
          ? 'An earlier renameat2 trial did not record normal completion and atomic publication is disabled for this system build.'
          : 'renameat2(RENAME_NOREPLACE) is unsupported for this system build after an EINVAL result.';
        process.emitWarning(`${basis} OpenHarmony publication is using exclusive copy; a partial final file can remain after failure or process death.`,
          { code: 'OHOS_PUBLICATION_NONATOMIC_FALLBACK' });
      },
    });
    const service = Object.freeze({
      protocolVersion: 1,
      recovery: 'durable ledger; unidentified or replaced entries are preserved',
      ownerId: ledger.ownerId,
      recoverySummary,
      get atomic() { return atomicFuse.atomic; },
      systemVersion: build.systemVersion,
      systemBuildIdentity: build.identity,
      get pendingCount() { return publish.pendingCount; },
      publish,
      publishAtomic(source, target, options = {}) {
        return publish(source, target, { ...options, requireAtomic: true });
      },
    });
    Object.defineProperty(globalThis, publicationSymbol, { value: service });
    installedOwnership = Object.freeze({
      ownerId: ledger.ownerId,
      reserve: ledger.reserve,
      identify: ledger.identify,
      release: ledger.release,
    });
    return { installed: true, protocolVersion: service.protocolVersion };
  } catch (error) {
    if (ledger) {
      try { await ledger.close(); }
      catch (closeError) { throw new AggregateError([error, closeError], 'Publication startup and ledger close failed', { cause: error }); }
    }
    throw error;
  } finally { installing = false; }
}
