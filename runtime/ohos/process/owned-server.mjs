import { createOwnedGitResources } from './owned-resources.mjs';

const requestType = 'dsh-ohos-owned-git-request';
const responseType = 'dsh-ohos-owned-git-response';
const ackType = 'dsh-ohos-owned-git-ack';
const fail = (code, message, cause) => Object.assign(new Error(message, { cause }), { code });

function errorRecord(error, depth = 0) {
  if (depth > 5) return { name: 'Error', message: 'Nested resource error omitted' };
  const record = { name: typeof error?.name === 'string' ? error.name : 'Error',
    message: typeof error?.message === 'string' ? error.message : 'Git resource operation failed' };
  for (const name of ['code', 'errno', 'syscall', 'committed']) {
    if (['string', 'number', 'boolean'].includes(typeof error?.[name])) record[name] = error[name];
  }
  if (error?.cause !== undefined) record.cause = errorRecord(error.cause, depth + 1);
  if (Array.isArray(error?.errors)) record.errors = error.errors.slice(0, 32).map(item => errorRecord(item, depth + 1));
  return record;
}

/** Bind messages to this Worker identity; caller-supplied job ids/roots are never used. */
export function createOwnedGitServer({ send, onFailure = () => {}, ...options } = {}) {
  if (typeof send !== 'function') throw new TypeError('A Worker response function is required');
  const resources = createOwnedGitResources(options);
  const responses = new Set(), failures = new Set(), unacknowledged = new Map();
  let lastRequestId = 0, finalization;
  const fatal = error => {
    failures.add(error);
    resources.stop();
    try { onFailure(error); } catch (cause) { failures.add(cause); }
  };
  const post = message => {
    try { send(message); }
    catch (cause) {
      throw fail('ERR_OHOS_GIT_RESOURCE_DELIVERY', 'Git resource response could not be delivered', cause);
    }
  };
  return Object.freeze({
    handle(message) {
      if (message?.type === ackType) {
        if (message.protocolVersion !== 1 || !Number.isSafeInteger(message.requestId)
            || !unacknowledged.has(message.requestId)) {
          fatal(fail('ERR_OHOS_GIT_RESOURCE_PROTOCOL', 'Invalid or replayed Git resource acknowledgement'));
        } else unacknowledged.delete(message.requestId);
        return true;
      }
      if (message?.type !== requestType) return false;
      const requestId = message.requestId;
      if (message.protocolVersion !== 1 || !Number.isSafeInteger(requestId) || requestId <= lastRequestId) {
        fatal(fail('ERR_OHOS_GIT_RESOURCE_PROTOCOL', 'Invalid or replayed Git resource request'));
        return true;
      }
      lastRequestId = requestId;
      const work = resources.accept(message.operation, message.payload);
      const response = work.then(
        value => {
          unacknowledged.set(requestId, undefined);
          post({ type: responseType, protocolVersion: 1, requestId, ok: true, value });
        },
        error => {
          // postMessage can silently discard a message after Worker exit.
          // Keep the original failure until the receiving client acknowledges it.
          unacknowledged.set(requestId, error);
          post({ type: responseType, protocolVersion: 1, requestId, ok: false, error: errorRecord(error) });
        },
      );
      responses.add(response);
      response.then(() => responses.delete(response), error => { responses.delete(response); fatal(error); });
      return true;
    },
    stop: resources.stop,
    get pendingCount() { return resources.pendingCount + responses.size; },
    get resourceCount() { return resources.resourceCount; },
    finish({ cancelled = false } = {}) {
      if (finalization) return finalization;
      resources.stop();
      finalization = (async () => {
        // Includes delivery callbacks. A failed reply must not lose resources
        // or race ahead of the process-provider failure seen by the runtime.
        await Promise.allSettled([...responses]);
        try { await resources.finish(); } catch (error) { failures.add(error); }
        if (!cancelled) {
          for (const error of unacknowledged.values()) if (error) {
            failures.add(fail('ERR_OHOS_GIT_RESOURCE_UNACKNOWLEDGED',
              'Worker exited before observing a failed Git resource operation', error));
          }
        }
        unacknowledged.clear();
        if (failures.size === 1) throw [...failures][0];
        if (failures.size) throw new AggregateError([...failures], 'Git resource provider did not finish cleanly');
      })();
      return finalization;
    },
  });
}
