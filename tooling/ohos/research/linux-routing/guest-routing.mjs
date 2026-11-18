import assert from 'node:assert/strict';
import { access, mkdir, readFile, realpath, writeFile } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { Readable } from 'node:stream';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { CommandRouter } from '../../../../runtime/ohos/process/command-router.mjs';
import { createLinuxCommandBackend } from '../../../../runtime/ohos/process/linux-backend.mjs';
import { LinuxControl } from '../../../../runtime/ohos/linux/control.mjs';
import { LinuxInstallationOwner, loadLinuxInstallationManifest } from '../../../../runtime/ohos/linux/owner.mjs';

const [nativeLibraryDirectory, assetsDirectory, archive, directory, workspace, resultPath] = process.argv.slice(2);
const checks = [], timings = {};
const check = (name, pass, facts = {}) => {
  const row = { name, pass: !!pass, ...facts }; checks.push(row); console.log(JSON.stringify(row)); assert.ok(pass, name);
};
// Production LinuxControl/owner/backend/native guest. Only the pinned archive
// download is served from the verified local file.
const control = new LinuxControl({ hostPaths: { directory, nativeLibraryDirectory }, assetsDirectory }, {
  async loadModule() {
    return { loadLinuxInstallationManifest, createLinuxInstallationOwner: options => new LinuxInstallationOwner(options,
      { download: { fetch: async () => new Response(Readable.toWeb(createReadStream(archive)), { status: 200 }) } }) };
  },
});
await mkdir(workspace);
const work = await realpath(workspace);
const router = new CommandRouter({ workspaceRoots: [work] }, { linux: roots => createLinuxCommandBackend({ control, ...roots }) });
const command = (action, fields = {}) => { const state = control.status(); return control.command({ v: 1, instanceId: state.instanceId, attemptId: state.attemptId, action, ...fields }); };
async function waitFor(predicate, label, milliseconds) {
  const deadline = Date.now() + milliseconds;
  while (Date.now() < deadline) { const state = control.status(); if (predicate(state)) return state; await delay(100); }
  throw new Error(label + ' deadline');
}
// The agent's bash tool: one `bash -c` script under a prepared session policy.
async function bash(label, script, { mode = 'workspace-write', signal } = {}) {
  const started = Date.now();
  const job = router.spawn({ argv: router.prepare(['bash', '-c', script], { mode, workspaceRoot: work }), cwd: work, graceMs: 15000, signal,
    env: {}, stdio: { stdin: 'ignore', stdout: { maxBytes: 1 << 20 }, stderr: { maxBytes: 1 << 20 } } });
  const outcome = await job.done;
  timings[label] = (Date.now() - started) / 1000;
  return { ...outcome, stdout: job.collected.stdout.snapshot().bytes.toString(), stderr: job.collected.stderr.snapshot().bytes.toString(), seconds: timings[label] };
}
const exists = path => access(path).then(() => true, () => false);
const deadline = setTimeout(() => { console.error('LINUX_ROUTING_DEADLINE'); process.exit(90); }, 840000);
let shutdown;
try {
  let result = await bash('disabled', "python3 -c 'print(1)'");
  check('with Linux off a routed command exits 127 and names the switch', result.exitCode === 127 &&
    result.stderr === 'ERR_OHOS_LINUX_DISABLED: Linux 环境未开启：请在 设置 · 能力 · Linux 环境 中打开后重试。\n' && !control.status().ownerRetained, result);
  check('the VM exports exactly this router\'s roots', JSON.stringify(control.exports.map(item => item.path)) === JSON.stringify([router.temporaryRoot, work]),
    { exports: control.exports });

  const enabling = Date.now();
  command('setEnabled', { enabled: true });
  await waitFor(state => state.admission, 'install and open', 600000);
  timings.installAndOpen = (Date.now() - enabling) / 1000;

  result = await bash('gh', 'gh --version');
  check('gh --version inside bash -c', result.exitCode === 0 && /^gh version \d/.test(result.stdout), result);
  result = await bash('python3', "python3 -c 'print(1)'");
  check("python3 -c 'print(1)' inside bash -c", result.exitCode === 0 && result.stdout === '1\n', result);
  result = await bash('pip', 'pip --version');
  check('pip --version inside bash -c', result.exitCode === 0 && /^pip \d+\.\d+/.test(result.stdout), result);

  await writeFile(join(work, 'from-host.txt'), 'written by the host\n');
  result = await bash('workspace', [
    "python3 -c \"import os; print(os.getcwd()); print(open('from-host.txt').read(), end=''); open('from-guest.txt', 'w').write('written in the guest\\n')\"",
    'cat from-guest.txt',
  ].join('\n'));
  const fromGuest = await readFile(join(work, 'from-guest.txt'), 'utf8').catch(() => null);
  check('the guest reads and writes the session workspace through 9P at the same path; host and virtual shell see it',
    result.exitCode === 0 && result.stdout === `${work}\nwritten by the host\nwritten in the guest\n` && fromGuest === 'written in the guest\n', { ...result, fromGuest });

  result = await bash('identity', "linux sh -c 'id -u; pwd; ls /run/dsh-9p >/dev/null 2>&1 && echo bases-visible || echo bases-hidden; grep -c \" 9p \" /proc/self/mounts'");
  check('the job runs as the unprivileged guest user and mounts only its two directories', result.exitCode === 0 &&
    result.stdout === `60081\n${work}\nbases-hidden\n2\n`, result);

  result = await bash('tmpdir', "python3 -c \"import tempfile; f = tempfile.NamedTemporaryFile('w', delete=False); f.write('shared temp\\n'); f.close(); print(f.name)\"");
  const tempFile = result.stdout.trim();
  check('TMPDIR is the session\'s private temporary root, shared with the host', result.exitCode === 0 &&
    tempFile.startsWith(router.temporaryRoot + '/') && await readFile(tempFile, 'utf8') === 'shared temp\n', result);

  result = await bash('read-only', "python3 -c \"print(open('from-host.txt').read(), end='')\"; python3 -c \"open('ro.txt', 'w')\"", { mode: 'read-only' });
  check('a read-only session reads the workspace and cannot write it', result.exitCode === 1 && result.stdout === 'written by the host\n' &&
    /Read-only file system/.test(result.stderr) && !await exists(join(work, 'ro.txt')), result);

  const controller = new AbortController();
  const running = bash('cancel', "python3 -c \"import pathlib, time; pathlib.Path('cancel-started').write_text('1'); time.sleep(60); pathlib.Path('cancel-finished').write_text('1')\"", { signal: controller.signal });
  const waitStarted = Date.now();
  while (!await exists(join(work, 'cancel-started'))) { if (Date.now() - waitStarted > 120000) throw new Error('cancel job did not start'); await delay(100); }
  const aborted = Date.now(); controller.abort();
  result = await running;
  timings.cancelToSettled = (Date.now() - aborted) / 1000;
  await delay(1000);
  check('cancelling the agent script kills its guest job tree', result.exitCode === null && result.signal === 'SIGTERM' &&
    !await exists(join(work, 'cancel-finished')), { ...result, cancelToSettled: timings.cancelToSettled });
  result = await bash('after-cancel', "python3 -c 'print(2)'");
  check('the guest lane is free again after cancellation', result.exitCode === 0 && result.stdout === '2\n', result);

  command('shutdown');
  shutdown = await waitFor(state => state.shutdownComplete || state.state === 'unknown', 'shutdown', 60000);
  check('final shutdown confirms native retirement', shutdown.shutdownComplete && shutdown.retirement.resourcesRetired, { retirement: shutdown.retirement });
  result = await bash('after-shutdown', "gh --version");
  check('after shutdown routed commands fail clearly', result.exitCode === 127 && /ERR_OHOS_LINUX_/.test(result.stderr), result);
  await writeFile(resultPath, JSON.stringify({ passed: true, checks, timings, shutdown, workspace: work, temporaryRoot: router.temporaryRoot,
    scope: 'Agent-style bash -c through the production CommandRouter, virtual shell Worker and Linux command backend into production LinuxControl/owner/backend and a real TinyEMU guest with virtio-9p exports. Only the pinned archive download is a local fixture. No HAP/device/Huawei network.' }, null, 2) + '\n');
} finally {
  clearTimeout(deadline);
  await router.dispose();
  await control.shutdown();
}
