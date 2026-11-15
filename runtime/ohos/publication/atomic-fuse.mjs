import { createHash } from 'node:crypto';

const states = new Set(['untried', 'trying', 'available', 'unsupported', 'disabled-after-crash']);
const failure = (code, message, cause) => Object.assign(new Error(message, { cause }), { code });
const bounded = (value, max) => typeof value === 'string' && value.length > 0
  && value.length <= max && !value.includes('\0');
const opened = new WeakSet();
const buildFields = Object.freeze(['osFullName', 'displayVersion', 'incrementalVersion', 'securityPatchTag']);

export function readSystemBuildIdentity(getter) {
  if (typeof getter !== 'function') throw new TypeError('A native system build getter is required');
  const read = () => {
    const raw = getter();
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)
        || Object.keys(raw).sort().join(',') !== [...buildFields].sort().join(',')) {
      throw new TypeError('The native system build identity has unexpected fields');
    }
    const value = {};
    for (const name of buildFields) {
      const part = raw[name];
      if (!bounded(part, 1024) || part.trim().length === 0 || !part.isWellFormed()
          || Buffer.byteLength(part, 'utf8') > 1024) {
        throw new TypeError('The native system build identity must contain nonempty strings');
      }
      value[name] = part;
    }
    return Object.freeze(value);
  };
  try {
    // A changing value must not silently create a new epoch on each startup.
    // This checks same-start consistency; stability across upgrades still comes
    // from the pinned platform APIs, not from this two-read observation alone.
    const identity = read(), encoded = JSON.stringify(identity);
    if (JSON.stringify(read()) !== encoded) throw new Error('The native system build identity changed during startup');
    return Object.freeze({ identity,
      systemVersion: 'ohos-build-v1:' + createHash('sha256').update(encoded).digest('hex') });
  } catch (cause) {
    throw failure('ERR_OHOS_PUBLICATION_SYSTEM_BUILD', 'A stable native system build identity is required', cause);
  }
}

// This fixed record is independent of ownership ledger schema 2. Both records
// are protected by the same existing ledger lock and serialized queue.
export function decodeAtomicState(text) {
  let value;
  try { value = JSON.parse(text); }
  catch (cause) {
    throw failure('ERR_OHOS_PUBLICATION_ATOMIC_STATE_CORRUPT', 'Publication atomic state is not valid JSON', cause);
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).sort().join(',') !== 'ownerId,schema,state,systemVersion'
      || value.schema !== 1 || !bounded(value.systemVersion, 4096)
      || !bounded(value.ownerId, 256) || !states.has(value.state)) {
    throw failure('ERR_OHOS_PUBLICATION_ATOMIC_STATE_CORRUPT', 'Invalid publication atomic state');
  }
  return Object.freeze(value);
}

export function encodeAtomicState(value) {
  // Snapshot before an asynchronous operation can observe a caller mutation.
  const text = JSON.stringify(value);
  decodeAtomicState(text);
  return text + '\n';
}

/**
 * One fuse per live ledger. storage.transaction owns the entire operation in
 * the existing ledger queue; its io.read/commit do not enqueue recursively.
 * A new process re-arms even a same-version "available" record. Unsupported
 * and disabled records suppress native calls until the system version changes.
 */
export async function openAtomicFuse({ storage, ownerId, systemVersion } = {}) {
  if (!storage || typeof storage.transaction !== 'function'
      || !bounded(ownerId, 256) || !bounded(systemVersion, 4096)) {
    throw new TypeError('A locked state transaction, process owner and stable system version are required');
  }
  if (opened.has(storage)) {
    throw failure('ERR_OHOS_PUBLICATION_ATOMIC_FUSE_DUPLICATE', 'A publication atomic fuse already owns this ledger');
  }
  opened.add(storage);
  let state = 'untried', verifiedThisProcess = false, poisoned;
  const record = next => Object.freeze({ schema: 1, systemVersion, state: next, ownerId });
  async function persist(io, next) {
    try { await io.commit(record(next)); }
    catch (cause) {
      poisoned = cause;
      throw failure('ERR_OHOS_PUBLICATION_ATOMIC_STATE_WRITE', 'Publication atomic state could not be durably recorded', cause);
    }
    state = next;
  }
  await storage.transaction(async io => {
    const previous = await io.read();
    if (previous !== null) {
      // The real storage validates too; validate injected test stores equally.
      const valid = decodeAtomicState(JSON.stringify(previous));
      if (valid.systemVersion === systemVersion) state = valid.state;
    }
    if (state === 'trying') await persist(io, 'disabled-after-crash');
  });

  return Object.freeze({
    get atomic() { return state; },
    systemVersion,
    run(commitSync, { beforeCommit = () => {} } = {}) {
      if (typeof commitSync !== 'function' || typeof beforeCommit !== 'function') {
        return Promise.reject(new TypeError('Synchronous native commit and ownership check functions are required'));
      }
      return storage.transaction(async io => {
        if (poisoned) {
          throw failure('ERR_OHOS_PUBLICATION_ATOMIC_FUSE_POISONED', 'Publication atomic state failed; restart is required', poisoned);
        }
        if (state === 'unsupported' || state === 'disabled-after-crash') {
          return Object.freeze({ atomic: false, reason: state });
        }
        const armed = !verifiedThisProcess || state !== 'available';
        if (armed) await persist(io, 'trying');
        const rejectReturned = async original => {
          if (armed) {
            try { await persist(io, 'untried'); }
            catch (stateError) {
              throw new AggregateError([original, stateError], 'Publication commit failed and its returned state could not be recorded', { cause: original });
            }
          }
          throw original;
        };

        // Keep the actual ownership check and native commit adjacent in this
        // JS turn. Pre-commit exceptions cannot be mistaken for native EINVAL.
        try {
          if (beforeCommit() !== undefined) throw new TypeError('beforeCommit must synchronously return undefined');
        } catch (error) { return rejectReturned(error); }
        let result;
        try { result = commitSync(); }
        catch (error) {
          if (error?.code === 'EINVAL' && error?.syscall === 'renameat2') {
            await persist(io, 'unsupported');
            verifiedThisProcess = false;
            return Object.freeze({ atomic: false, reason: 'unsupported' });
          }
          return rejectReturned(error);
        }
        if (result !== undefined) return rejectReturned(new TypeError('renameNoReplace must synchronously return undefined'));
        if (armed) {
          try { await persist(io, 'available'); }
          catch (cause) {
            // The final file is already committed. This is never permission to
            // copy again or remove that final file.
            throw Object.assign(failure('ERR_OHOS_PUBLICATION_COMMITTED_STATE', 'Publication committed but its atomic state could not be recorded', cause),
              { committed: true });
          }
        }
        verifiedThisProcess = true;
        return Object.freeze({ atomic: true });
      });
    },
  });
}
