// Independent disk observation, shared by the lifecycle and process-death actors.
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export function selectedPackage(dir, name) {
  const root = join(dir, '.plugin-manager/ohos'), file = join(root, 'active.json');
  if (!existsSync(file)) return;
  const target = JSON.parse(readFileSync(file)).packages[name];
  return target === undefined ? undefined : join(root, 'generations', target);
}
