const requestType = 'dsh-ohos-owned-git-request';
const responseType = 'dsh-ohos-owned-git-response';
const ackType = 'dsh-ohos-owned-git-ack';
const fail = (code, message) => Object.assign(new Error(message), { code });
function revive(record, depth = 0) {
  if (!record || depth > 5) return new Error('Git resource operation failed');
  const cause = record.cause === undefined ? undefined : revive(record.cause, depth + 1);
  const error = Array.isArray(record.errors)
    ? new AggregateError(record.errors.map(item => revive(item, depth + 1)), record.message, { cause })
    : new Error(record.message, { cause });
  for (const key of ['name', 'code', 'errno', 'syscall', 'committed']) {
    if (['string', 'number', 'boolean'].includes(typeof record[key])) error[key] = record[key];
  }
  return error;
}

/** Worker-side job-bound facade. The parent determines every authority. */
export function createOwnedGitClient(port) {
  const pending = new Map();
  let sequence = 0, closed = false;
  const close = (error = fail('ERR_OHOS_GIT_RESOURCE_CHANNEL_CLOSED', 'Git resource channel closed')) => {
    if (closed) return;
    closed = true;
    port.off('message', receive);
    port.off('close', disconnected);
    for (const item of pending.values()) item.reject(error);
    pending.clear();
  };
  const receive = message => {
    if (message?.type !== responseType) return;
    if (message.protocolVersion !== 1 || !Number.isSafeInteger(message.requestId)
        || !pending.has(message.requestId) || typeof message.ok !== 'boolean') {
      close(fail('ERR_OHOS_GIT_RESOURCE_PROTOCOL', 'Invalid Git resource response'));
      return;
    }
    const item = pending.get(message.requestId);
    pending.delete(message.requestId);
    try { port.postMessage({ type: ackType, protocolVersion: 1, requestId: message.requestId }); }
    catch (error) { item.reject(error); close(error); return; }
    if (message.ok) item.resolve(message.value);
    else item.reject(revive(message.error));
  };
  const disconnected = () => close();
  port.on('message', receive);
  port.once('close', disconnected);
  const request = (operation, payload) => {
    if (closed) return Promise.reject(fail('ERR_OHOS_GIT_RESOURCE_CHANNEL_CLOSED', 'Git resource channel closed'));
    const requestId = ++sequence, item = Promise.withResolvers();
    pending.set(requestId, item);
    try { port.postMessage({ type: requestType, protocolVersion: 1, requestId, operation, payload }); }
    catch (error) { pending.delete(requestId); item.reject(error); }
    return item.promise;
  };
  return Object.freeze({
    api: Object.freeze({
      createClone: payload => request('createClone', payload),
      commitClone: id => request('commitClone', { id }),
      releaseClone: id => request('releaseClone', { id }),
      createIndex: payload => request('createIndex', payload),
      writeIndex: (id, content) => request('writeIndex', { id, content }),
      writeMetadata: payload => request('writeMetadata', payload),
      commitIndex: id => request('commitIndex', { id }),
      releaseIndex: id => request('releaseIndex', { id }),
    }),
    close,
  });
}
