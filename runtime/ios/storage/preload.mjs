import { isMainThread } from 'node:worker_threads';

// Workers inherit the host's --import, but never own or migrate app history.
if (isMainThread) {
  const { borrowInstalledOwnership } = await import('../../ohos/publication/index.mjs');
  borrowInstalledOwnership();
  const { migrateContainerPaths } = await import('./relocate.mjs');
  const result = await migrateContainerPaths();
  if (result.status === 'unanchored') process.emitWarning('Existing iOS history has no trusted container-path origin. Its files were preserved and relocation was not marked complete.',
    { code: 'IOS_RELOCATION_ORIGIN_UNAVAILABLE' });
  if (Object.keys(result.quarantineCounts).length) process.emitWarning(
    `iOS relocation preserved session histories in its private quarantine: ${JSON.stringify(result.quarantineCounts)}. Exact original locations and reasons are retained in ios-relocation/quarantine/index.json.`,
    { code: 'IOS_RELOCATION_SESSION_ISOLATED' });
}
