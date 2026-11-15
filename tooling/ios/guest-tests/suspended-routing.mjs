// Run with the pinned private just-bash entry from a composed iOS runtime.
//
// With Linux installed, ordinary scripts run in Linux. While Linux is paused
// after a run that did not finish, the runtime leaves the routing transform out
// (iosGuestRouting in tooling/ios/guest-specialization.py), so the virtual shell
// keeps working as if Linux were not installed. Anything that still reaches the
// paused owner is refused before any work.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { shellCommands } from '../../../runtime/ohos/process/commands.mjs';
import { routingTransform } from '../../../runtime/ios/guest/route.mjs';
import { installSuspendedGuestOwner } from '../../../runtime/ios/guest/suspended.mjs';

if (!process.argv[2]) throw new Error('Expected the pinned private just-bash index.js path');
const { Bash, InMemoryFs, parse } = await import(pathToFileURL(resolve(process.argv[2])).href);

const specialization = readFileSync(new URL('../guest-specialization.py', import.meta.url), 'utf8');
assert.match(specialization, /iosGuestRouting: !!this\.#guest && '\s*'this\.#guest\.metadata\?\.suspended !== true/);

const owner = installSuspendedGuestOwner({ readMetadata: () => ({
  v: 1, source: 'ios-native-owner', state: 'suspended', installed: 'present',
  available: false, enforcement: 'partial', python: 'unknown',
}) });
try {
  assert.equal(owner.provider.metadata.suspended, true);
  const run = async (script, routed) => {
    const fs = new InMemoryFs({ '/workspace/marker': 'original' });
    const argv = ['sh', '-c', script];
    const bash = new Bash({ fs, cwd: '/workspace', python: false, javascript: false, defenseInDepth: false });
    const routing = routed ? routingTransform(argv, { shellCommands, parse }) : undefined;
    if (routing) bash.registerTransformPlugin(routing.plugin);
    const result = await bash.exec(argv[0], { args: argv.slice(1), rawScript: true });
    return { argv, fs, result, decision: routing?.decision };
  };
  const script = 'echo virtual-ok > /workspace/marker; cat /workspace/marker';

  // With Linux running this script would go to Linux and nothing would run here.
  const linux = await run(script, true);
  assert.equal(linux.decision.route, 'guest');
  assert.equal(await linux.fs.readFile('/workspace/marker'), 'original');

  // Paused: no routing transform, so the virtual shell runs it.
  const paused = await run(script, false);
  assert.equal(paused.result.exitCode, 0);
  assert.equal(paused.result.stdout, 'virtual-ok\n');
  assert.equal(await paused.fs.readFile('/workspace/marker'), 'virtual-ok\n');

  // A request that still reaches the paused owner is refused.
  let diagnostic = '';
  const rejected = await owner.provider.execute({ decision: linux.decision, argv: linux.argv,
    output: async (_, bytes) => { diagnostic += bytes; } });
  assert.equal(rejected.exitCode, 126);
  assert.match(diagnostic, /ERR_IOS_GUEST_SUSPENDED/);
  console.log('PASS: paused Linux leaves ordinary scripts to the virtual shell; the paused owner refuses Linux work');
} finally { await owner.dispose(); }
