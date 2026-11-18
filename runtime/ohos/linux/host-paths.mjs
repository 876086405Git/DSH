import { isMainThread } from 'node:worker_threads';
import { isAbsolute, resolve } from 'node:path';

const path = value => typeof value === 'string' && isAbsolute(value) && value !== '/' &&
  !value.includes('\0') && resolve(value) === value;
// Imported by the host's sole preload before plugins. Later env mutations,
// profile configuration and Worker inheritance cannot replace this snapshot.
const host = isMainThread && (process.platform === 'openharmony' || globalThis[Symbol.for('dsh.go.ohos.sim')] === true);
const directory = host ? process.env.DSH_GO_OHOS_LINUX_DIRECTORY : undefined;
const nativeLibraryDirectory = host ? process.env.DSH_GO_OHOS_NATIVE_LIBRARY_DIR : undefined;
const captured = path(directory) && path(nativeLibraryDirectory)
  ? Object.freeze({ directory, nativeLibraryDirectory }) : undefined;
let lockExclusive;
if (host) {
  try {
    const binding = process._linkedBinding('dsh_ohos_publication');
    if (typeof binding.lockExclusive === 'function') lockExclusive = binding.lockExclusive;
  } catch { /* Enabling Linux reports the unavailable trusted capability. */ }
}

export const linuxHostPaths = () => captured;
export const linuxHostLock = () => lockExclusive;
