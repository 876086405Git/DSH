// Exercise production specialized VirtualSubprocessRuntime.prepare/spawn and Worker.
// Supply files/ from a composed iOS runtime. No native kernel or real approval UI
// is used: the owned Git service seam is idle, since these scripts do not run Git.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

if (!process.argv[2]) throw new Error('Expected the composed iOS files directory');
const files = resolve(process.argv[2]);
if (process.argv[3] !== '--child') {
  // Workers inherit this actual production override loader through execArgv.
  execFileSync(process.execPath, ['--import', join(files, 'runtime/ios/guest/overrides.mjs'),
    '--import', join(files, 'runtime/ohos/process/node-worker-preload.mjs'),
    fileURLToPath(import.meta.url), files, '--child'], { stdio: 'inherit', timeout: 30000 });
} else {
  const load = name => import(pathToFileURL(join(files, name)).href);
  const { installSuspendedGuestOwner } = await load('runtime/ios/guest/suspended.mjs');
  const { VirtualSubprocessRuntime } = await load('runtime/ohos/process/runtime.mjs');
  const key = Symbol.for('dsh.go.ios.guest.owner');
  const base = await mkdtemp(join(tmpdir(), 'ios-root-grant-runtime-'));
  const workspace = join(base, 'workspace'), temporary = join(base, 'temporary');
  await mkdir(workspace); await mkdir(temporary);
  const marker = join(workspace, 'marker');
  await writeFile(marker, 'original');
  await writeFile(join(workspace, 'script.mjs'), 'process.stdout.write("actual-node-worker\\n");\n');
  let runtime, owner, approvals = 0, loads = 0, resourceFinishes = 0;
  const dlopen = process.dlopen;
  process.dlopen = () => { loads++; throw new Error('Paused runtime must not load native code'); };
  try {
    owner = installSuspendedGuestOwner({ readMetadata: () => ({
      v: 1, source: 'ios-native-owner', state: 'suspended', installed: 'present',
      available: false, enforcement: 'partial', python: 'unknown',
    }) });
    runtime = new VirtualSubprocessRuntime({ workspaceRoots: [workspace], temporaryRoot: temporary }, {
      // Explicit production test seam: there are no Git messages in these cases.
      createOwnedGitServer: () => ({ handle: () => false, stop() {}, async finish() { resourceFinishes++; } }),
    });
    const policy = { mode: 'workspace-write', workspaceRoot: workspace };
    const execute = async command => {
      const controller = new AbortController();
      const argv = runtime.prepare(['bash', '-c', command], policy, controller.signal);
      assert.equal(runtime.prepared.size, 1);
      const spec = { argv, cwd: workspace, env: {}, signal: controller.signal, graceMs: 1000,
        stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe', control: 'ignore' } };
      const handle = runtime.spawn(spec);
      assert.equal(runtime.prepared.size, 0);
      assert.throws(() => runtime.spawn(spec), { code: 'ERR_OHOS_INVALID_CONFINEMENT' });
      const output = async stream => { let text = ''; for await (const chunk of stream) text += chunk; return text; };
      const [result, stdout, stderr] = await Promise.all([handle.done, output(handle.stdout), output(handle.stderr)]);
      assert.equal(await handle.waitForExit(), true);
      return { ...result, stdout, stderr };
    };
    const virtual = await execute('node script.mjs');
    assert.equal(virtual.exitCode, 0);
    assert.equal(virtual.stdout, 'actual-node-worker\n');
    assert.equal(await readFile(marker, 'utf8'), 'original');
    console.log('PASS actual specialized prepare/spawn executes the retained Node Worker route while suspended');
    const shell = await execute('echo virtual-ok > marker; cat marker');
    assert.equal(shell.exitCode, 0);
    assert.equal(shell.stdout, 'virtual-ok\n');
    assert.equal(await readFile(marker, 'utf8'), 'virtual-ok\n');
    const missing = await execute('python3 -V');
    assert.equal(missing.exitCode, 127);
    let diagnostic = '';
    const rejected = await owner.provider.execute({ decision: { route: 'guest' },
      argv: ['bash', '-c', 'python3 -V'], output: async (_, bytes) => { diagnostic += bytes; } });
    assert.equal(rejected.exitCode, 126);
    assert.match(diagnostic, /ERR_IOS_GUEST_SUSPENDED/);
    console.log('PASS paused virtual shell works, missing Python returns 127, and the Linux provider refuses work');
    const call = new AbortController();
    await assert.rejects(() => owner.authorizeRootWrite({
      reason: 'synthetic one-call root request', command: 'python3 -V', cwd: workspace, policy,
      agent: { session: {} }, callId: 'paused-root-call', signal: call.signal,
      approver: { async request() { approvals++; return 'allowed-once'; } },
    }), { code: 'ERR_IOS_GUEST_SUSPENDED' });
    assert.equal(owner.prepareRootGrant([], Object.create(null)), undefined);
    assert.equal(owner.activateRootGrant(undefined), undefined);
    assert.throws(() => owner.activateRootGrant({}), { code: 'ERR_IOS_GUEST_SUSPENDED' });
    assert.equal(approvals, 0); assert.equal(loads, 0);
    assert.equal(owner.temporaryRoot, undefined);
    assert.equal(resourceFinishes, 3);
    await runtime.dispose(); runtime = undefined;
    assert.equal(globalThis[key], undefined);
    console.log('PASS paused root request has zero root approvals and dlopen; all Worker ranges settle');
  } finally {
    process.dlopen = dlopen;
    await runtime?.dispose();
    if (globalThis[key] === owner) await owner.dispose();
    await rm(base, { recursive: true, force: true });
  }
}
