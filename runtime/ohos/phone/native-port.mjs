import { isMainThread } from 'node:worker_threads';

const unavailable = () => Object.assign(new Error('Native phone callback is unavailable'), { code: 'native_unavailable' });

/** Only request permits are writable here; lifecycle and bridge ownership are native-only. */
export function createNativePhonePort(bootId) {
  if (!isMainThread || typeof bootId !== 'string' || !bootId || bootId.length > 256 || bootId.includes('\0')) throw unavailable();
  const binding = process._linkedBinding('dsh_ohos_publication');
  for (const method of ['bindPhoneEngine', 'getPhoneSnapshot', 'claimPhonePermit', 'revokePhonePermit', 'completePhonePermit']) {
    if (typeof binding[method] !== 'function') throw unavailable();
  }
  if (binding.bindPhoneEngine(bootId) !== true) throw unavailable();
  const identity = request => {
    const { executionNonce, result, ...original } = request;
    return { original, executionNonce, result };
  };
  return Object.freeze({
    snapshot() {
      const state = binding.getPhoneSnapshot();
      if (!state || typeof state.available !== 'boolean' || typeof state.foreground !== 'boolean' ||
          (state.available && (state.engineId !== bootId || typeof state.ownerHash !== 'string' ||
            !/^[a-f0-9]{64}$/.test(state.ownerHash)))) throw unavailable();
      return state;
    },
    claim(request) {
      const { original, executionNonce } = identity(request);
      return binding.claimPhonePermit(original, executionNonce);
    },
    revoke(request) {
      const { original, executionNonce } = identity(request);
      return binding.revokePhonePermit(original, executionNonce);
    },
    complete(request) {
      const { original, executionNonce, result } = identity(request);
      return binding.completePhonePermit(original, executionNonce, result);
    },
  });
}
