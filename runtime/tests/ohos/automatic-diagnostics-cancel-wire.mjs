// Actual current ETS and real Linux persistence; HiAppEvent delivery is an explicit fixture.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(process.env.OHOS_DIAGNOSTIC_SOURCE_ROOT ?? fileURLToPath(new URL('../../../', import.meta.url)));
const { diagnosticsFixture } = await import(pathToFileURL(resolve(root, 'runtime/tests/ohos/diagnostics-fixture.mjs')).href);
const cleanups = [];
const f = await diagnosticsFixture({ after: operation => cleanups.push(operation) });
let plugin;
try {
  const event = (time, name) => ({ domain: 'OS', name, eventType: 1,
    params: { time, ...(name === 'APP_CRASH' ? { crash_type: 'NativeCrash' } : {}) } });
  f.faults.queue.push(event(200, 'APP_FREEZE'));
  plugin = f.attach();
  const first = await f.call(plugin, 'info').done;
  assert.equal(first.error, undefined);
  f.emitFault(event(300, 'APP_CRASH'));
  const second = await f.call(plugin, 'info').done;
  assert.equal(second.error, undefined);
  assert.deepEqual(first.value.evidence.processExits,
    [{ at: 200, source: 'hiAppEvent', event: 'APP_FREEZE' }]);
  assert.deepEqual(second.value.evidence.processExits,
    [{ at: 200, source: 'hiAppEvent', event: 'APP_FREEZE' },
      { at: 300, source: 'hiAppEvent', event: 'APP_CRASH', crashType: 'NativeCrash' }]);
  assert.equal(f.fds.size, 0);
  plugin.detach();
  assert.equal(f.faults.watchers.size, 0);
  await fs.writeFile(process.env.OHOS_CANCEL_OWNER_WIRE, JSON.stringify({
    scope: 'Two increasing-time OH snapshots from actual ETS; explicit HiAppEvent fixture, no phone crash claim',
    snapshots: [first.value, second.value],
    resources: { descriptors: f.fds.size, watchers: f.faults.watchers.size, pendingSdkEvents: f.faults.queue.length },
    sdkOperations: f.faults.operations,
  }, null, 2) + '\n');
  console.log('Two current ETS snapshots produced; descriptors/watchers/pending events are zero');
} finally {
  plugin?.detach();
  for (const cleanup of cleanups) await cleanup();
}
