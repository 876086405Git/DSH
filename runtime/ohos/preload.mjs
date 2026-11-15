// The product host's sole --import. Install the OS-child-process boundary before
// dependencies can capture builtin aliases. Keep sequential dynamic imports:
// network bootstrap must finish before publication's dependencies are evaluated.
await import('./process/child-process.mjs');
await import('./net/dsh-preload.mjs');
await import('./publication/preload.mjs');
await import('./process/node-worker-preload.mjs');
