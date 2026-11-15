// The transport may acknowledge a chunk only after this Promise fulfils.
// Fulfilment means acceptance by this Node Writable and relief of its current
// backpressure, not rendering by the UI or receipt by a remote end user.
const aborted = () => Object.assign(new Error('Guest output delivery cancelled'), {
  name: 'AbortError', code: 'ABORT_ERR',
});
const closed = () => Object.assign(new Error('Guest output consumer closed before delivery completed'), {
  code: 'ERR_IOS_GUEST_OUTPUT_CLOSED',
});

export function deliverGuestOutput(sink, bytes, signal) {
  return new Promise((resolve, reject) => {
    let settled = false, issued = false, returned = false, written = false, needDrain = false, sawDrain = false;
    let acceptedBeforeAbort = false;
    const stopWaiting = () => {
      sink.removeListener('drain', onDrain);
      signal?.removeEventListener('abort', onAbort);
    };
    const cleanup = () => {
      stopWaiting();
      sink.removeListener('error', onError);
      sink.removeListener('close', onClose);
    };
    const fail = (error, pendingWrite = false) => {
      if (!settled) { settled = true; reject(error); }
      // Cancellation settles our Promise, but an outstanding Writable write
      // still owns its later error/close lifecycle. Keep those two observers
      // until its callback succeeds, an error is observed, or it closes.
      if (pendingWrite) stopWaiting();
      else cleanup();
    };
    const complete = () => {
      if (settled || !returned || !written || (needDrain && !sawDrain)) return;
      if (signal?.aborted && !acceptedBeforeAbort) return fail(aborted());
      if (sink.destroyed || sink.writableEnded) return fail(closed());
      settled = true;
      cleanup();
      resolve();
    };
    const onDrain = () => { sawDrain = true; complete(); };
    const onError = error => fail(error);
    const onClose = () => fail(closed());
    const onAbort = () => {
      // A synchronous consumer can cancel inside write(); its return value is
      // not known yet. Decide immediately after that call returns.
      if (issued && !returned) return;
      if (issued && (!needDrain || sawDrain)) {
        // Bytes already crossed this sink's flow-control boundary. Cancellation
        // does not undo them, and is not a substitute for their write callback.
        acceptedBeforeAbort = true;
        signal?.removeEventListener('abort', onAbort);
        complete();
        return;
      }
      fail(aborted(), issued && !written);
    };
    sink.once('drain', onDrain);
    sink.once('error', onError);
    sink.once('close', onClose);
    signal?.addEventListener('abort', onAbort, { once: true });
    if (signal?.aborted) return onAbort();
    if (sink.destroyed || sink.writableEnded || !sink.writable) return onClose();
    try {
      issued = true;
      needDrain = !sink.write(bytes, error => {
        if (error) {
          // A failed callback precedes Node's error event. It can arrive after
          // an earlier close/abort rejection, so ensure its observer exists.
          sink.removeListener('error', onError);
          sink.once('error', onError);
          return fail(error, true);
        }
        written = true;
        if (settled) { cleanup(); return; }
        complete();
      });
      returned = true;
      if (signal?.aborted) onAbort();
      complete();
    } catch (error) { fail(error); }
  });
}
