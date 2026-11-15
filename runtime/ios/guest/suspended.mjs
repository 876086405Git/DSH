import { GuestProvider } from './provider.mjs';
import { createGuestMetadataStore, guestDescription, guestSuspendedMessage } from './metadata.mjs';
import { deliverGuestOutput } from './delivery.mjs';

// Keep the parser's Linux rejection path, but never load or probe a native guest
// for a suspended launch. The frozen snapshot lasts until this engine stops;
// resuming in Settings cannot turn an already running engine back on.
export function installSuspendedGuestOwner({ readMetadata }) {
  const key = Symbol.for('dsh.go.ios.guest.owner');
  if (globalThis[key]) throw new Error('Guest owner already registered');
  const metadata = createGuestMetadataStore();
  if (!metadata.publishJSON(JSON.stringify({ ...readMetadata(),
    state: 'suspended', suspended: true, available: false }))) {
    throw new Error('Suspended guest snapshot is invalid');
  }
  const provider = new GuestProvider({ readMetadata: metadata.read });
  const denied = () => Object.assign(new Error(guestSuspendedMessage), { code: 'ERR_IOS_GUEST_SUSPENDED' });
  const owner = Object.freeze({ provider, deliverOutput: deliverGuestOutput,
    description: guestDescription,
    async authorizeRootWrite() { throw denied(); },
    prepareRootGrant() { return undefined; },
    activateRootGrant(ticket) { if (ticket !== undefined) throw denied(); },
    async dispose() {
      await provider.dispose();
      if (globalThis[key] === owner) delete globalThis[key];
    } });
  globalThis[key] = owner;
  return owner;
}
