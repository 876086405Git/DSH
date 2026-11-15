import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Only unavailable platform/timer boundaries are adapted. Production method
// bodies run unchanged; this is not an ArkTS or an OHOS device execution.
export const timers = new Map();
let nextTimer = 1;
export function testSetTimeout(callback, delay) {
  const id = nextTimer++; timers.set(id, { callback, delay }); return id;
}
export function testClearTimeout(id) { timers.delete(id); }
export function tickRetry() {
  const [id, timer] = timers.entries().next().value ?? [];
  if (id === undefined) throw new Error('No scheduled retry');
  timers.delete(id); timer.callback(); return timer.delay;
}
export const permission = { grants: 0, modes: 0, status: 0, supported: true,
  accessCapability: true, backgroundCapability: true, error: null, requestedModes: null };
export const abilityAccessCtrl = {
  GrantStatus: { PERMISSION_GRANTED: 0, PERMISSION_DENIED: -1 },
  createAtManager() { return { checkAccessTokenSync(id, name) {
    permission.grants++; permission.last = { id, name };
    if (permission.error) throw permission.error;
    return permission.status;
  } }; },
};
export const backgroundTaskManager = {
  BackgroundTaskMode: { MODE_TASK_KEEPING: 9 },
  ContinuousTaskRequest: class {
    isModeSupported() {
      permission.modes++; permission.requestedModes = this.backgroundTaskModes;
      return permission.supported;
    }
  },
};
export const canIUse = name => name === 'SystemCapability.Security.AccessToken'
  ? permission.accessCapability : permission.backgroundCapability;

export async function loadHostModules(sourceOverride) {
  const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
  const source = sourceOverride ?? path.join(repo, 'app/ohos/entry/src/main/ets/runtime');
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-lifecycle-host-'));
  const fixture = import.meta.url;
  const model = await fs.readFile(path.join(source, 'RuntimeLifecycle.ets'), 'utf8');
  await fs.writeFile(path.join(directory, 'RuntimeLifecycle.mts'),
    `import { testSetTimeout as setTimeout, testClearTimeout as clearTimeout } from '${fixture}';\n` + model);
  const permissionSource = (await fs.readFile(path.join(source, 'BackgroundCompute.ets'), 'utf8'))
    .replace("import abilityAccessCtrl from '@ohos.abilityAccessCtrl';", '')
    .replace("import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';", '');
  await fs.writeFile(path.join(directory, 'BackgroundCompute.mts'),
    `import { abilityAccessCtrl, backgroundTaskManager, canIUse } from '${fixture}';\n` + permissionSource);
  const modules = { ...await import(pathToFileURL(path.join(directory, 'RuntimeLifecycle.mts'))),
    ...await import(pathToFileURL(path.join(directory, 'BackgroundCompute.mts'))) };
  return { ...modules, directory, async close() { await fs.rm(directory, { recursive: true, force: true }); } };
}
