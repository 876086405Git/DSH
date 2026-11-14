// The product host's sole --import. Install the OS-child-process boundary before
// dependencies can capture builtin aliases. Keep sequential dynamic imports:
// network bootstrap must finish before publication's dependencies are evaluated.
await import('./process/child-process.mjs');
const { installProcessGrantAuthority } = await import('./process/files/process-authority.mjs');
installProcessGrantAuthority();
await import('./process/files/workspace-paths.mjs');
await import('./process/files/workspace-edit.mjs');
await import('./linux/host-paths.mjs');
await import('./net/dsh-preload.mjs');
await import('./publication/preload.mjs');
await import('./image/preload.mjs');
await import('./plugins/preload.mjs');
await import('./process/node-worker-preload.mjs');
