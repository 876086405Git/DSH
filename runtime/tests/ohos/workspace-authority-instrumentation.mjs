// Test-only strict-simulation setup for the inherited fixed shell Worker.
// Product code neither reads this configuration nor restores a SIM allowlist.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
const config = JSON.parse(readFileSync(process.env.OHOS_932_CONFIG, 'utf8'));
process.env.DSH_GO_OHOS_SIM_ADDONS = JSON.stringify([
  'libdsh_flock.so', 'libdsh_require_builtin.so',
  'libdsh_workspace_grants.so', 'workspace-publisher.node',
].map(name => join(config.nativeDirectory, name)));
await import('../../ohos/sim/preload.mjs');
// Explicit confirmation-fault fixture. Real native retirement still executes;
// this only makes its success unconfirmed to the production owner, before that
// owner captures methods. It is not evidence of a real kernel close failure.
if (config.scenario === 'retirement-fault' && (await import('node:worker_threads')).isMainThread) {
  const { createRequire } = await import('node:module');
  const binding = createRequire(join(config.payload, 'package.json'))('@dsh-go/ohos-native').load('workspace-grants').binding;
  const retire = binding.retire;
  binding.retire = token => { retire(token); return 0; };
}
