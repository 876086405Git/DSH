// Negative ownership probe only. Positive access uses the public factory's
// actual shell Worker, never this probe and never a manually issued ticket.
import { parentPort } from 'node:worker_threads';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
const config = JSON.parse(readFileSync(process.env.OHOS_932_CONFIG, 'utf8'));
const binding = createRequire(join(config.payload, 'package.json'))('@dsh-go/ohos-native').load('workspace-grants').binding;
const result = {};
for (const [name, action] of Object.entries({
  snapshot: () => binding.snapshot(),
  issue: () => binding.issue('1'.repeat(64), 'untrusted', 1, true),
  bind: () => binding.bindOwner(join(config.nativeDirectory, 'libdsh_host.so')),
  consumeUnknown: () => binding.consume('2'.repeat(64)),
})) {
  try { action(); result[name] = 'unexpected-success'; }
  catch (error) { result[name] = error.code; }
}
parentPort.postMessage(result); parentPort.close();
