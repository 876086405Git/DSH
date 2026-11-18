import { isMainThread } from 'node:worker_threads';
import { posix } from 'node:path';
import { setImmediate } from 'node:timers/promises';
import { loadGrantBinding } from './authority.mjs';
import { grantFileObservation } from './grant-fs.mjs';
import { borrowProcessGrantAuthority, processWorkspaceGrant, isLogicalWorkspacePath,
  quarantineProcessGrantRetirement } from './process-authority.mjs';

const fail = (code, message = code) => Object.assign(new Error(message), { code });
let binding, moveBinding, wholeBinding, unavailable;

// Evaluated by the sole preload before plugins. No writable global bridge.
if (isMainThread && process.platform === 'openharmony') {
  try {
    borrowProcessGrantAuthority();
    const loaded = loadGrantBinding();
    const methods = ['consume', 'statExact', 'openEditInput', 'readEditInput', 'closeEditInput',
      'beginEdit', 'writeEdit', 'closeEdit', 'publishEdit', 'abortEdit', 'close', 'mutate'];
    binding = Object.freeze(Object.fromEntries(methods.map(name => {
      if (typeof loaded[name] !== 'function') throw fail('ERR_WORKSPACE_EDIT_ABI');
      return [name, loaded[name].bind(loaded)];
    })));
    const moveNames = ['beginMoveOutput', 'publishMoveOutput'];
    if (moveNames.every(name => typeof loaded[name] === 'function')) {
      moveBinding = Object.freeze(Object.fromEntries(moveNames.map(name => [name, loaded[name].bind(loaded)])));
    }
    const wholeNames = ['beginWholeOutput', 'writeWholeOutput', 'closeWholeOutput', 'stepWholeOutput', 'abortWholeOutput'];
    if (wholeNames.every(name => typeof loaded[name] === 'function')) {
      wholeBinding = Object.freeze(Object.fromEntries(wholeNames.map(name => [name, loaded[name].bind(loaded)])));
    }
  } catch (error) { unavailable = error; }
}

function combined(primary, secondary, stage) {
  return Object.assign(new AggregateError([primary, secondary],
    `${primary?.message ?? String(primary)}; ${stage}: ${secondary?.message ?? String(secondary)}`, { cause: primary }),
  { code: primary?.code ?? secondary?.code });
}

function checkAbort(signal) {
  if (signal?.aborted) throw Object.assign(
    new Error('The operation was aborted', { cause: signal.reason }),
    { name: 'AbortError', code: 'ABORT_ERR' });
}

async function turn(signal) {
  await setImmediate();
  checkAbort(signal);
}

// The trusted sandbox provider supplies its checked target and the same policy.
// Creation acquires nothing; LocalFileSystem invokes the closure under its lock.
function workspaceOperationScope(target, policy, requestSignal, destination) {
  if (process.platform !== 'openharmony' || !isLogicalWorkspacePath(String(target.targetKey))) return;
  return async action => {
    let commitPhase = false;
    // Move's original last cancellation check is before the entire destination
    // publication/source-removal section. This private view has no listeners.
    const signal = destination ? {
      get aborted() { return !commitPhase && !!requestSignal?.aborted; },
      get reason() { return requestSignal?.reason; },
    } : requestSignal;
    const moveFacts = { destination: 'unpublished', source: 'not-attempted' };
    checkAbort(signal);
    if (!isMainThread) throw fail('ERR_WORKSPACE_OWNER');
    if (unavailable) throw unavailable;
    if (!binding) throw fail('ERR_WORKSPACE_OWNER_UNINITIALIZED');
    const canonical = posix.resolve(String(target.targetKey));
    const root = canonical.split('/').slice(0, 3).join('/');
    const relative = canonical.slice(root.length + 1);
    let destinationRelative;
    if (destination) {
      if (!moveBinding) throw fail('ERR_WORKSPACE_MOVE_ABI');
      const to = posix.resolve(String(destination.targetKey));
      if (!isLogicalWorkspacePath(to) || to.split('/').slice(0, 3).join('/') !== root) throw fail('ERR_WORKSPACE_MOVE_SCOPE', '暂不支持在两个授权文件夹之间移动。请先复制到目标文件夹，确认成功后再删除原文件。');
      destinationRelative = to.slice(root.length + 1);
    }
    let grant;
    try { grant = processWorkspaceGrant(root); }
    catch (error) {
      if (error.code !== 'ERR_WORKSPACE_UNAVAILABLE') throw error;
      throw Object.assign(new Error('文件夹授权当前不可用，请在系统选择器中重新选择该文件夹。', { cause: error }),
        { code: 'ENOENT', reason: 'ERR_WORKSPACE_REAUTHORIZATION_REQUIRED' });
    }
    if (policy.mode === 'read-only' || !grant.writable) throw fail('EACCES', '授权文件夹没有本次编辑所需的写入权限。');
    const lease = borrowProcessGrantAuthority().issue([grant], { readOnly: false, workspaceRoot: root });
    let handle, result, failure, failed = false, committed = false, publicationAttempted = false, cleanupFailed = false, wholeWritePartial = false;
    let wholeAttempted = false, wholeEffectUnknown = false;
    function recordFailure(error, stage) {
      failure = failed ? combined(failure, error, stage) : error;
      failed = true;
    }

    async function probe(path = relative) {
      await setImmediate();
      if (!committed) checkAbort(signal);
      let info;
      try { info = binding.statExact(handle, path); }
      catch (error) {
        if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return null;
        throw error;
      }
      if (info.type === 3) throw fail('ELOOP');
      return { ...grantFileObservation(info, grant), mode: info.mode & 0o777 };
    }

    // Private FileHandle shape for the existing bounded diff reader. Its stat
    // reports the same input FD's initial fstat captured by OpenEditInput.
    async function openDiffInput(path = relative) {
      await turn(signal);
      const size = BigInt(binding.openEditInput(handle, path));
      let opened = true;
      return Object.freeze({
        async stat() { return { isFile: () => true, size }; },
        async read(buffer, offset, length, position) {
          if (!opened || position !== null || !Number.isSafeInteger(length) || length < 0 || length > 65536) {
            throw fail('ERR_WORKSPACE_ARGUMENT');
          }
          await turn(signal);
          const part = binding.readEditInput(handle, length);
          part.copy(buffer, offset);
          return { bytesRead: part.length };
        },
        async close() {
          if (!opened) return;
          try { binding.closeEditInput(handle); opened = false; }
          catch (error) {
            cleanupFailed = true;
            const aborted = signal?.aborted ? Object.assign(
              new Error('The operation was aborted', { cause: signal.reason }),
              { name: 'AbortError', code: 'ABORT_ERR' }) : null;
            const cause = aborted ? combined(aborted, error, 'input close failed') : error;
            throw Object.assign(new Error(cause?.message ?? String(cause), { cause }), {
              code: error?.code, workspaceEditCleanupFailed: true,
            });
          }
        },
      });
    }

    async function remove() {
      if (cleanupFailed) throw fail('ERR_WORKSPACE_DRAIN', 'workspace input close was not confirmed');
      await turn(signal);
      publicationAttempted = true;
      // Single-file unlink only: never select AT_REMOVEDIR or recursive rm.
      // A throw may occur after the native unlink, so keep the attempted fact.
      try { binding.mutate(handle, 'remove', relative, false); }
      catch (error) {
        // These current ABI errors arise before successful unlink. In
        // particular, permission failures keep the original permission result.
        // N-API return-value construction is not in this known-rejection list.
        if (['ENOENT', 'EEXIST', 'ENOTDIR', 'EISDIR', 'ENOTEMPTY', 'ELOOP', 'EACCES', 'EPERM', 'EIO',
          'ERR_WORKSPACE_LEASE', 'ERR_WORKSPACE_ARGUMENT', 'ERR_WORKSPACE_PATH', 'ERR_WORKSPACE_RETIRED',
          'ERR_WORKSPACE_CLOSE_FAILED', 'ERR_WORKSPACE_TASK_RETIRED', 'ERR_WORKSPACE_READ_ONLY',
          'ERR_WORKSPACE_INTERNAL'].includes(error?.code)) publicationAttempted = false;
        throw error;
      }
      committed = true;
    }

    async function read() {
      let opened = false, content, readFailure, readFailed = false;
      try {
        await turn(signal);
        const sizeText = binding.openEditInput(handle, relative);
        opened = true;
        const exactSize = BigInt(sizeText);
        // Node v24.22.1 default fs/promises.readFile checks the initial stat size.
        if (exactSize > 2147483647n) throw Object.assign(
          new RangeError(`File size (${sizeText}) is greater than 2 GiB`), { code: 'ERR_FS_FILE_TOO_LARGE' });
        const size = Number(exactSize);
        let total = 0;
        if (size > 0) {
          const bytes = Buffer.allocUnsafeSlow(size);
          while (true) {
            await turn(signal);
            const part = binding.readEditInput(handle, Math.min(size - total, 524288));
            part.copy(bytes, total);
            total += part.length;
            // A known positive size <=512 KiB also finishes on a positive short read.
            if (part.length === 0 || total === size || size <= 524288) {
              content = bytes.subarray(0, total);
              break;
            }
          }
        } else {
          const parts = [];
          while (true) {
            await turn(signal);
            const part = binding.readEditInput(handle, 65536);
            if (part.length === 0) { content = Buffer.concat(parts, total); break; }
            parts.push(part);
            total += part.length;
          }
        }
      } catch (error) { readFailure = error; readFailed = true; }
      if (opened) {
        try { binding.closeEditInput(handle); }
        catch (error) {
          cleanupFailed = true;
          readFailure = readFailed ? combined(readFailure, error, 'input close failed') : error;
          readFailed = true;
        }
      }
      if (readFailed) throw readFailure;
      return content;
    }

    async function write(content, mode) {
      await turn(signal);
      binding.beginEdit(handle, relative, mode);
      const bytes = Buffer.from(content, 'utf8');
      let offset = 0;
      while (offset < bytes.length) {
        await turn(signal);
        const part = bytes.subarray(offset, Math.min(offset + 1048576, bytes.length));
        const written = binding.writeEdit(handle, part);
        if (written <= 0 || written > part.length) throw fail('EIO', 'workspace edit made invalid write progress');
        offset += written;
      }
      binding.closeEdit(handle);
      await turn(signal);
      publicationAttempted = true;
      // A normal return confirms rename. The bool concerns only directory removal.
      binding.publishEdit(handle);
      committed = true;
    }

    // Whole-write is an independent optional ABI group. Never use Move's
    // synchronous fallback or commit shield when the original signal applies.
    async function writeWhole(content, mode, options = {}) {
      if (!wholeBinding) throw fail('ERR_WORKSPACE_WHOLE_ABI');
      await turn(signal);
      wholeAttempted = true;
      // Explicit policy: mode 0 remains a valid preserved existing-file mode.
      wholeBinding.beginWholeOutput(handle, relative, mode === undefined ? 1 : 0,
        mode === undefined ? 0 : mode, options.createIfAbsent === true);
      const bytes = Buffer.from(content, 'utf8');
      for (let offset = 0; offset < bytes.length;) {
        await turn(signal);
        const part = bytes.subarray(offset, Math.min(offset + 1048576, bytes.length));
        const count = wholeBinding.writeWholeOutput(handle, part);
        if (count <= 0 || count > part.length) throw fail('EIO', 'workspace whole write made invalid progress');
        offset += count;
      }
      wholeBinding.closeWholeOutput(handle);
      await turn(signal);
      const observe = effect => {
        if (!Number.isInteger(effect) || effect < 0 || effect > 2 || (wholeWritePartial && effect === 0)) {
          throw fail('ERR_WORKSPACE_WHOLE_ABI');
        }
        wholeEffectUnknown = false;
        publicationAttempted = effect !== 0;
        if (effect === 1) wholeWritePartial = true;
        if (effect === 2) committed = true;
      };
      while (true) {
        publicationAttempted = true;
        wholeEffectUnknown = true;
        let step;
        try { step = wholeBinding.stepWholeOutput(handle); }
        catch (error) {
          if (error.workspaceWholeEffect !== undefined) observe(error.workspaceWholeEffect);
          throw error;
        }
        if (!step || step.schemaVersion !== 1 || step.effectKnown !== true ||
            typeof step.stagingRemoved !== 'boolean' || !Number.isInteger(step.continuation)) {
          throw fail('ERR_WORKSPACE_WHOLE_ABI');
        }
        const valid = step.effect === 2 ? step.continuation === 0 :
          step.effect === 0 ? step.continuation === 1 && !step.stagingRemoved :
          step.effect === 1 && [2, 3].includes(step.continuation) && !step.stagingRemoved;
        if (!valid) throw fail('ERR_WORKSPACE_WHOLE_ABI');
        observe(step.effect);
        if (committed) return; // stagingRemoved is diagnostic, never a retire claim.
        // Body complete: preserve the original sync/mode/close tail without
        // a new late-cancellation point. All other steps yield to the signal.
        if (step.continuation !== 3) await turn(signal);
      }
    }

    async function writeMove(content, mode, options) {
      if (!commitPhase) throw fail('ERR_WORKSPACE_EDIT_STATE');
      await turn(signal);
      moveBinding.beginMoveOutput(handle, destinationRelative, mode, options.createIfAbsent === true);
      const bytes = Buffer.from(content, 'utf8');
      for (let offset = 0; offset < bytes.length;) {
        await turn(signal);
        const part = bytes.subarray(offset, Math.min(offset + 1048576, bytes.length));
        const count = binding.writeEdit(handle, part);
        if (count <= 0 || count > part.length) throw fail('EIO', 'workspace move made invalid write progress');
        offset += count;
      }
      binding.closeEdit(handle);
      await turn(signal);
      moveFacts.destination = 'unknown';
      try { moveBinding.publishMoveOutput(handle); }
      catch (error) {
        if (error.workspaceMoveEffect === 0) moveFacts.destination = 'unpublished';
        else if (error.workspaceMoveEffect === 1) moveFacts.destination = 'partial';
        else if (error.workspaceMoveEffect === 2) moveFacts.destination = 'published';
        throw error;
      }
      moveFacts.destination = 'published';
    }

    async function removeMoveSource() {
      if (!commitPhase || moveFacts.destination !== 'published') throw fail('ERR_WORKSPACE_EDIT_STATE');
      if (cleanupFailed) throw fail('ERR_WORKSPACE_DRAIN');
      await turn(signal);
      moveFacts.source = 'unknown';
      try { binding.mutate(handle, 'remove', relative, false); }
      catch (error) {
        const known = ['ENOENT', 'EEXIST', 'ENOTDIR', 'EISDIR', 'ENOTEMPTY', 'ELOOP', 'EACCES', 'EPERM', 'EIO',
          'ERR_WORKSPACE_LEASE', 'ERR_WORKSPACE_ARGUMENT', 'ERR_WORKSPACE_PATH', 'ERR_WORKSPACE_RETIRED',
          'ERR_WORKSPACE_CLOSE_FAILED', 'ERR_WORKSPACE_TASK_RETIRED', 'ERR_WORKSPACE_READ_ONLY', 'ERR_WORKSPACE_INTERNAL'].includes(error?.code);
        if (known) {
          moveFacts.source = 'not-deleted';
          throw Object.assign(new Error(error.message, { cause: error }), { code: error.code, workspaceMoveSourceUnchanged: true });
        }
        throw error;
      }
      moveFacts.source = 'deleted';
    }

    try {
      handle = binding.consume(lease.mounts[0].ticket);
      const io = destination ? Object.freeze({
        source: Object.freeze({ probe: () => probe(), read, remove: removeMoveSource }),
        destination: Object.freeze({ probe: () => probe(destinationRelative),
          openDiffInput: () => openDiffInput(destinationRelative), write: writeMove }),
        beginCommit() { checkAbort(signal); commitPhase = true; },
      }) : Object.freeze({ probe, read, write, writeWhole, openDiffInput, remove });
      result = await action(io);
    } catch (error) { recordFailure(error, 'workspace edit failed'); }
    if (handle !== undefined) {
      try {
        if (wholeAttempted) wholeBinding.abortWholeOutput(handle);
        else binding.abortEdit(handle);
      }
      catch (error) {
        cleanupFailed = true;
        recordFailure(error, 'workspace edit cleanup failed');
      }
      try { binding.close(handle); }
      catch (error) {
        cleanupFailed = true;
        recordFailure(error, 'workspace lease close failed');
      }
    }
    let drained = false;
    try { drained = lease.retire() === true; }
    catch (error) { recordFailure(error, 'workspace lease retirement failed'); }
    if (!drained) {
      cleanupFailed = true;
      quarantineProcessGrantRetirement();
      recordFailure(fail('ERR_WORKSPACE_DRAIN'), 'workspace lease retirement was not confirmed');
    }
    if (failed) {
      if (destination) {
        throw Object.assign(new Error(failure?.message ?? String(failure), { cause: failure }), {
          code: failure?.code, workspaceMoveFacts: Object.freeze({ ...moveFacts, cleanupFailed }),
          workspaceMoveResult: result,
        });
      }
      if (committed || publicationAttempted || cleanupFailed) {
        throw Object.assign(new Error(failure?.message ?? String(failure), { cause: failure }), {
          code: failure?.code,
          workspaceEditState: committed ? 'committed' : wholeEffectUnknown ? 'unknown' : wholeWritePartial ? 'partial' : publicationAttempted ? 'unknown' : 'unpublished',
          workspaceEditCleanupFailed: cleanupFailed,
        });
      }
      throw failure;
    }
    return result;
  };
}

export function workspaceEditScope(target, policy, signal) {
  return workspaceOperationScope(target, policy, signal);
}

export function workspaceMoveScope(source, destination, policy, signal) {
  if (process.platform !== 'openharmony') return;
  const fromLogical = isLogicalWorkspacePath(String(source.targetKey));
  const toLogical = isLogicalWorkspacePath(String(destination.targetKey));
  if (!fromLogical && !toLogical) return;
  if (!fromLogical || !toLogical) throw fail('ERR_WORKSPACE_MOVE_SCOPE', '暂不支持在授权文件夹与普通路径之间直接移动。请先复制到目标位置，确认成功后再删除原文件。');
  return workspaceOperationScope(source, policy, signal, destination);
}

// Patched DSH reaches this through a registered symbol, like workspace-paths,
// so the provider loads the same way in every runtime layout.
if (isMainThread && process.platform === 'openharmony') {
  Object.defineProperty(globalThis, Symbol.for('dsh.go.ohos.workspace-edit'), {
    value: Object.freeze({ workspaceEditScope, workspaceMoveScope }), writable: false, configurable: false,
  });
}
