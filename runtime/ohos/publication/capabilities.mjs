// Read only the installed service. This does not probe a syscall, recover the
// ledger, or authorize an operation. A route must apply its own existing guard.
const publicationSymbol = Symbol.for('dsh.go.ohos.publication');
const atomicStates = new Set(['untried', 'trying', 'available', 'unsupported', 'disabled-after-crash']);
const validVersion = value => typeof value === 'string' && value.length > 0
  && value.length <= 4096 && value.trim().length > 0 && !value.includes('\0') && value.isWellFormed();

export function readPublicationCapabilities() {
  const service = globalThis[publicationSymbol];
  let atomic = 'unknown', systemVersion = null;
  if (service?.protocolVersion === 1 && typeof service.publish === 'function') {
    const observedAtomic = service.atomic, observedVersion = service.systemVersion;
    if (atomicStates.has(observedAtomic)) atomic = observedAtomic;
    if (validVersion(observedVersion)) systemVersion = observedVersion;
  }
  return Object.freeze({ publication: Object.freeze({ atomic, systemVersion }) });
}
