import { isMainThread } from 'node:worker_threads';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { realpathSync, statSync } from 'node:fs';
import { createGrantAuthority } from './authority.mjs';

const require = createRequire(import.meta.url);
const fail = code => Object.assign(new Error(code), { code });
let attempted = false, installed, unavailable, nativeDirectory, retirementFailed = false;

// The sole application preload calls this before any plugin. The host DSO must
// already be loaded by App startup: native bindOwner uses RTLD_NOLOAD, and never
// creates another workspace registry. An absent optional component is explicit
// when a logical workspace is requested; physical app-private work still works.
export function installProcessGrantAuthority() {
  if (!isMainThread || process.platform !== 'openharmony') return false;
  if (attempted) return installed !== undefined;
  attempted = true;
  try {
    const loaded = require('@dsh-go/ohos-native').load('workspace-grants');
    const directory = dirname(loaded.path);
    const hostLibrary = join(directory, 'libdsh_host.so');
    if (realpathSync(hostLibrary) !== hostLibrary || !statSync(hostLibrary).isFile()) {
      throw fail('ERR_WORKSPACE_HOST_PATH');
    }
    // Capture methods as well as the canonical path. A later mutation of the
    // loader's exports or process.env cannot redirect this process authority.
    const binding = Object.freeze(Object.fromEntries(['bindOwner', 'snapshot', 'issue', 'retire'].map(name => {
      if (typeof loaded.binding[name] !== 'function') throw fail('ERR_WORKSPACE_HOST_ABI');
      return [name, loaded.binding[name].bind(loaded.binding)];
    })));
    const authority = createGrantAuthority({ hostLibrary, binding });
    installed = Object.freeze({ snapshot: authority.snapshot,
      issue(...args) {
        if (retirementFailed) throw fail('ERR_WORKSPACE_DRAIN');
        return authority.issue(...args);
      },
      get unavailableReason() { return retirementFailed ? 'ERR_WORKSPACE_DRAIN' : null; },
    });
    nativeDirectory = directory;
    return true;
  } catch (error) {
    unavailable = error;
    return false;
  }
}

export function borrowProcessGrantAuthority() {
  if (!isMainThread) throw fail('ERR_WORKSPACE_OWNER');
  if (!installed) throw unavailable ?? fail('ERR_WORKSPACE_OWNER_UNINITIALIZED');
  return installed;
}

// Internal shell-Worker loading input, not an environment-derived grant and not
// a caller configuration. It is never included in the shell's own environment.
export function processGrantNativeDirectory() {
  borrowProcessGrantAuthority();
  return nativeDirectory;
}

// Call after the last consumer boundary (Worker exit/pipes, or a main-thread
// metadata handle close) failed to confirm D. Cancellation's early R without D
// is normal. The debt belongs to the process across Cordis runtime instances.
export function quarantineProcessGrantRetirement() {
  borrowProcessGrantAuthority();
  retirementFailed = true;
}

export const isLogicalWorkspacePath = path => typeof path === 'string'
  && (path === '/workspaces' || path.startsWith('/workspaces/'));

export function processWorkspaceGrant(path) {
  if (!/^\/workspaces\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(path)) {
    throw fail('ERR_WORKSPACE_SCOPE_UNSUPPORTED');
  }
  const grant = borrowProcessGrantAuthority().snapshot().find(row => row.mountPoint === path);
  if (!grant) throw fail('ERR_WORKSPACE_UNAVAILABLE');
  return grant;
}
