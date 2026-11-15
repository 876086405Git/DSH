import { FsError } from '@deepseek-ai/dsh-fs';
import { GuestPaths } from './paths.mjs';

const alias = path => path === '/workspace' || path.startsWith('/workspace/') || path === '/tmp' || path.startsWith('/tmp/');

// The iOS file tools supply the immutable session root. Ordinary provider
// calls and remote filesystems keep their existing path contract.
export function guestFilePath(path, options, subprocess, { followFinalLink = true } = {}, temporaryRoot) {
  if (!options || !Object.hasOwn(options, 'iosGuestWorkspaceRoot') || !alias(path)) return path;
  try {
    const paths = new GuestPaths({
      workspaceRoot: options.iosGuestWorkspaceRoot,
      temporaryRoot,
      forbiddenRoots: [process.env.DSH_HOME, process.env.DSH_AGENTS_HOME].filter(Boolean),
    });
    // Host paths may themselves live below /tmp in a validation environment.
    // Recognize configured host roots before interpreting the guest spelling.
    if (subprocess?.isHostPath(path)) return path;
    return paths.toHost(path, { followFinalLink });
  } catch (error) {
    if (error.code !== 'EACCES') throw error;
    throw new FsError(error.message, 'FS_SANDBOX_DENIED', { cause: error });
  }
}
