import { guestInstallRequiredMessage, guestSuspendedMessage } from './metadata.mjs';
// root is the fakefs container (data + meta.db); the C backend appends /data.
// Trusted owner injection only. This module neither probes nor boots a kernel.
export function createNativeGuestChannel(native, { root, protectedPaths = [], readInstallation }) {
  // Once this engine has observed a suspended task, an explicit settings resume
  // only affects a fresh owner after engine restart. Queued calls check again at
  // dispatch time so clearing the disk record cannot release old queued work.
  let suspended = false;
  return Object.freeze({
    get suspended() { return suspended; },
    exec(request, output) {
      if (suspended) return Object.freeze({
        finished: Promise.resolve().then(() => output('stderr', Buffer.from(guestSuspendedMessage + '\n')))
          .then(() => ({ exitCode: 126, signal: null, resourcesSettled: true })),
        signal() {}, abandon() {},
      });
      const workspace = request.mounts.find(m => m.guest === '/workspace')?.host;
      const temporary = request.mounts.find(m => m.guest === '/tmp')?.host;
      if (!workspace || !temporary || !['read-only', 'workspace-write'].includes(request.mode)) throw new TypeError('Invalid guest mounts or policy');
      const completion = Promise.withResolvers();
      completion.promise.catch(() => {});
      let id, ended = false, signalled = false, retry;
      const streams = [Promise.resolve(), Promise.resolve()];
      const input = Buffer.from(request.stdin ?? '');
      let offset = 0;
      const fail = error => {
        if (ended) return;
        ended = true;
        clearTimeout(retry);
        try { native.abandon(id); } catch {}
        completion.reject(error);
      };
      const feed = () => {
        if (ended || signalled) return;
        try {
          while (offset < input.length) {
            const chunk = input.subarray(offset, offset + 65536);
            const written = native.stdinWrite(id, chunk);
            if (!Number.isInteger(written) || written <= 0 || written > chunk.length) throw new Error('Invalid native stdin progress');
            offset += written;
          }
          native.stdinClose(id);
        } catch (error) {
          // Darwin EAGAIN=35; Linux replay EAGAIN=11. No other errors retry.
          if ([11, 35].includes(error.errno)) retry = setTimeout(feed, 5);
          else fail(error);
        }
      };
      const event = value => {
        if (ended) return;
        if (value.id !== id) return fail(new Error('Guest event identity mismatch'));
        if (value.type === 'started') { feed(); return; }
        if (value.type === 'stdout' || value.type === 'stderr') {
          const stream = value.type === 'stdout' ? 1 : 2;
          streams[stream - 1] = streams[stream - 1].then(async () => {
            if (ended) return;
            await output(value.type, value.data);
            if (!ended) native.ack(id, stream, value.end);
          });
          streams[stream - 1].catch(fail);
        } else if (value.type === 'exit') {
          if (value.errorCode === 'ios_guest_suspended') suspended = true;
          clearTimeout(retry);
          // Native confirms ACKs or explicit discard; still await every JS consumer.
          // Cancellation cannot retire a live consumer merely because C has settled.
          ended = true;
          Promise.all(streams).then(() => {
            if ((value.abandoned && !signalled) || value.resourcesSettled !== true || native.status().state === 'quarantined') {
              completion.reject(Object.assign(new Error('Guest native exit was not cleanly settled'), { nativeError: value.error }));
            } else if (value.error) {
              // Recheck after a settled native error: uninstall can win after preflight.
              // ENOENT alone is insufficient; a missing guest executable must stay a task error.
              const missing = readInstallation?.() === 'absent';
              const diagnostic = value.errorCode === 'ios_guest_suspended' ? guestSuspendedMessage :
                missing ? guestInstallRequiredMessage : `ERR_IOS_GUEST_TASK: Native task failed (errno ${value.error}).`;
              Promise.resolve(output('stderr', Buffer.from(diagnostic + '\n'))).then(
                () => completion.resolve({ exitCode: suspended ? 126 : missing ? 127 : 126, signal: null, nativeError: value.error, resourcesSettled: true }), completion.reject);
            } else completion.resolve({ exitCode: value.exitCode, signal: null, resourcesSettled: true });
          }, completion.reject).catch(completion.reject);
        } else fail(new Error('Unknown guest event'));
      };
      id = native.start({ root, cwd: request.cwd, workspace, temporary,
        argv: [...request.argv], env: Object.entries(request.env).map(([k, v]) => `${k}=${v}`),
        readOnly: request.mode === 'read-only', rootWritable: request.rootWritable === true,
        ...(request.rootWritable === true ? { expectedRootDevice: request.expectedRootDevice, expectedRootInode: request.expectedRootInode } : {}), protectedPaths: [...protectedPaths] }, event);
      return Object.freeze({ finished: completion.promise, abandon() { fail(new Error('Guest operation abandoned by owner')); }, signal(name) {
        if (ended) return;
        if (name === 'SIGTERM') native.cancel(id);
        else if (name === 'SIGKILL') native.kill(id);
        else throw new TypeError('Unsupported guest signal');
        // Record intent only after the native request succeeds. Discarded output
        // is acceptable on this operation only after its consumers also settle.
        signalled = true;
        clearTimeout(retry);
      } });
    },
  });
}
