const networkSymbol = Symbol.for('dsh.go.ohos.net');
const policySymbol = Symbol.for('dsh.go.ohos.lifecycle.transport');
const failure = (code, message) => Object.assign(new Error(message), { code });

/**
 * Retire only the default transport installed by the OH startup seam. This is
 * a new-connection boundary, not a health assertion or replay mechanism.
 * Old close() drains accepted operations; destroy() is never used on them.
 */
export function createLifecycleTransport(network = globalThis[networkSymbol]) {
  let owned = network?.globalDispatcherApi?.baseDispatcher ?? network?.dispatcher;
  let generation = 0, closed = false, last, policyOwner;
  const retiring = new Set(), failures = [];
  const status = () => ({ generation, retiredInFlight: retiring.size + (policyOwner?.status().retiredInFlight ?? 0),
    policy: 'replace-owned-default-for-new-requests',
    credentials: 'original-wall-clock-validation',
    ...(last ?? {}), retirementFailures: [...failures, ...(policyOwner?.status().retirementFailures ?? [])] });
  const retire = dispatcher => {
    let completion;
    try { completion = Promise.resolve(dispatcher.close()); }
    catch (error) { completion = Promise.reject(error); }
    retiring.add(completion);
    completion.catch(error => {
      failures.push(typeof error?.code === 'string' ? error.code : 'ERR_OHOS_TRANSPORT_CLOSE');
      if (failures.length > 16) failures.shift();
    }).finally(() => retiring.delete(completion));
  };
  return {
    status,
    async revalidate() {
      if (closed) throw failure('ERR_OHOS_LIFECYCLE_CLOSED', 'Lifecycle transport owner is closed');
      if (!network || typeof network.createDispatcher !== 'function' || !owned || typeof owned.close !== 'function') {
        throw failure('ERR_OHOS_LIFECYCLE_TRANSPORT', 'OH network startup transport is unavailable');
      }
      const policy = network.dispatcher?.[policySymbol];
      if (policy?.protocolVersion === 1) {
        // The pinned DSH proxy owns route selection. Renew its internal pools
        // in place; replacing this wrapper with a direct dispatcher would lose
        // the selected proxy/no_proxy policy and its teardown ownership.
        policy.renew(); policyOwner = policy; generation++;
        last = { defaultDispatcher: 'policy-connections-renewed',
          globalDispatcher: network.globalDispatcherApi?.getGlobalDispatcher() === network.dispatcher ? 'same-policy-owner' : 'custom-preserved' };
        return status();
      }
      if (network.dispatcher !== owned) {
        last = { defaultDispatcher: 'custom-preserved', globalDispatcher: 'unchanged' };
        return status();
      }
      const replacement = network.createDispatcher({ proxyEnv: process.env.NODE_USE_ENV_PROXY === '1' ? process.env : {} });
      const api = network.globalDispatcherApi;
      const replaceGlobal = api !== undefined && api.getGlobalDispatcher() === owned;
      try {
        if (replaceGlobal) api.setGlobalDispatcher(replacement);
        network.dispatcher = replacement;
      } catch (cause) {
        // Only the not-yet-published replacement is ours to destroy here.
        if (replaceGlobal && api.getGlobalDispatcher() === replacement) api.setGlobalDispatcher(owned);
        await replacement.destroy();
        throw failure('ERR_OHOS_LIFECYCLE_TRANSPORT', 'Could not publish the new default connection owner');
      }
      const previous = owned;
      owned = replacement; generation++;
      last = { defaultDispatcher: 'replaced', globalDispatcher: replaceGlobal ? 'replaced' : api ? 'custom-preserved' : 'not-installed' };
      retire(previous);
      return status();
    },
    // Unloading this observer must not abort an unrelated in-flight request or
    // destroy a dispatcher still installed as the application's default.
    close() { closed = true; },
  };
}
