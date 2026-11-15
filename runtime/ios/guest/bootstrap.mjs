// Dynamically import ONLY after the trusted App owner confirms installation.
import { lstatSync, readFileSync } from 'node:fs';
import { rm } from 'node:fs/promises';
import { createRootWriteGrants } from './root-grants.mjs';
import { GuestProvider } from './provider.mjs';
import { createNativeGuestChannel } from './native-channel.mjs';
import { deliverGuestOutput } from './delivery.mjs';
import { guestFilePath } from './file-paths.mjs';
import { guestDescription } from './metadata.mjs';
import { createCleanupBudget } from './cleanup-budget.mjs';
// The fixed installer marker is state evidence, never a replacement for native admission.
export function readGuestInstallation(root) {
  try {
    const directory = lstatSync(root), data = lstatSync(root + '/data'), database = lstatSync(root + '/meta.db');
    const marker = lstatSync(root + '/installed.json');
    if (!directory.isDirectory() || !data.isDirectory() || !database.isFile() || !marker.isFile() || marker.size > 4096) return 'invalid';
    const value = JSON.parse(readFileSync(root + '/installed.json', 'utf8'));
    return value.schema === 1 && value.version === '3.24.4' &&
      value.archiveSHA256 === '4b14c18f7e90a063b61462ea1462a5732c154bf6adad594974fe6487cd98a8de' ? 'present' : 'invalid';
  } catch (error) { return ['ENOENT', 'ENOTDIR'].includes(error.code) ? 'absent' : 'invalid'; }
}

export function installGuestOwner({ native, root, protectedPaths, temporaryRoot, readMetadata }) {
  const key = Symbol.for('dsh.go.ios.guest.owner');
  if (globalThis[key]) throw new Error('Guest owner already registered');
  const metadata = readMetadata();
  const status = native.status();
  if (metadata.installed !== 'present' || !status.available || status.state === 'quarantined') throw new Error('Guest installation or native capability unavailable');
  const identity = lstatSync(temporaryRoot, { bigint: true });
  if (!identity.isDirectory() || identity.isSymbolicLink()) throw new Error("Guest temp must be an owned directory");
  const rootIdentity = native.rootIdentity(root);
  const budget = createCleanupBudget();
  let provider, grants;
  try {
    provider = new GuestProvider({ channel: createNativeGuestChannel(native, { root, protectedPaths, readInstallation: () => readGuestInstallation(root) }),
    temporaryRoot, readMetadata: () => {
      const cached = readMetadata(), current = native.status(), installation = readGuestInstallation(root);
      const available = installation === 'present' && current.available === true && current.state !== 'quarantined';
      return { ...cached, installed: installation === 'invalid' ? 'unknown' : installation, available: cached.available && available,
        state: installation !== 'present' ? 'unavailable' : !available ? 'faulted' : current.state === 'running' ? 'busy' : cached.state };
    }, forbiddenRoots: protectedPaths, cleanupDeadline: budget.deadline });
    grants = createRootWriteGrants({ root, identity: rootIdentity, readMetadata: () => provider.metadata });
  } catch (error) { budget.dispose(); throw error; }
  const disposeProvider = provider.dispose.bind(provider);
  let disposal;
  const disposeOwner = () => disposal ??= (async () => {
    try {
      await disposeProvider();
      const state = native.status().state;
      if (state === 'cold' || state === 'ready') {
        const current = lstatSync(temporaryRoot, { bigint: true });
        if (current.dev !== identity.dev || current.ino !== identity.ino || !current.isDirectory()) throw new Error('Guest temp identity changed');
        await rm(temporaryRoot, { recursive: true });
      }
    } finally { grants.close(); budget.dispose(); if (globalThis[key] === owner) delete globalThis[key]; }
  })();
  const owner = Object.freeze({ provider, temporaryRoot,
    authorizeRootWrite: grants.authorize, prepareRootGrant: grants.prepare, activateRootGrant: grants.activate, deliverOutput: deliverGuestOutput,
    filePath: (path, options, subprocess, flags) => guestFilePath(path, options, subprocess, flags, temporaryRoot), description: guestDescription,
    dispose: disposeOwner });
  globalThis[key] = owner;
  return owner;
}
