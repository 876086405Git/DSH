// Actual Cordis MCP plugin auto negotiation + actual router/facade/Control/adapter.
// Guest/native boundary reuses 1204: real TCP and real Python child pipes,
// no VM. A second real job owns the single Linux slot between probe and main.
import assert from 'node:assert/strict';
import { appendFileSync } from 'node:fs';
import { mkdir, copyFile, writeFile, readdir, readFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { setTimeout as delay } from 'node:timers/promises';

const root = resolve(process.env.OHOS_MCP_AUDIT_SOURCE ?? fileURLToPath(new URL('../../../', import.meta.url)));
const variant = process.argv[2] ?? 'plugin-blocked';
assert(['plugin-blocked', 'plugin-normal', 'sdk-esm-blocked', 'sdk-cjs-blocked'].includes(variant));
const blocked = variant !== 'plugin-normal', pluginCase = variant.startsWith('plugin-');
const prefix = resolve(process.env.DSH_PREFIX), out = resolve(process.env.OHOS_MCP_TEST_OUT);
const load = relative => import(pathToFileURL(join(root, relative)));
const { CommandRouter } = await load('runtime/ohos/process/command-router.mjs');
const { LinuxCommandBackend } = await load('runtime/ohos/process/linux-backend.mjs');
const { LinuxControl } = await load('runtime/ohos/linux/control.mjs');
const { LinuxRuntimeBackend } = await load('runtime/ohos/linux/backend.mjs');
const { createChildProcessFacade } = await load('runtime/ohos/process/plugin-process.mjs');
const { createProcessGuest, waitFor } = await load('runtime/tests/ohos/mcp-stdio-guest-fixture.mjs');
const sdkPath = join(prefix, 'node_modules/@modelcontextprotocol/client/dist');
const require = createRequire(import.meta.url);
const { StdioClientTransport } = variant === 'sdk-cjs-blocked' ? require(join(sdkPath, 'stdio.cjs'))
  : await import(pathToFileURL(join(sdkPath, 'stdio.mjs')));
const { Client } = variant === 'sdk-cjs-blocked' ? require(join(sdkPath, 'index.cjs'))
  : await import(pathToFileURL(join(sdkPath, 'index.mjs')));
await mkdir(out);
const work = join(out, 'work'), spill = join(out, 'spill'), receipts = join(out, 'receipts');
for (const dir of [work, spill, receipts]) await mkdir(dir);
const script = join(work, 'server.py');
await copyFile(join(root, 'runtime/tests/ohos/mcp-stdio-server.py'), script);
const command = ['python3', '-u', script, receipts], trace = [];
const record = (event, data = {}) => {
  const row = { seq: trace.length + 1, event, ...data }; trace.push(row);
  appendFileSync(join(out, 'TRACE.jsonl'), JSON.stringify(row) + '\n');
};
const guest = await createProcessGuest({ python: process.env.OHOS_MCP_PYTHON, command, cwd: work, record });
let inner, blocker, router, transport, client, ctx, plugin;
let disposeState = 'not-started', registrationState = 'not-started';
const toolResults = [];
const control = new LinuxControl({ hostPaths: { directory: out, nativeLibraryDirectory: '/fixture/native' } }, {
  async loadModule() { return {
    async loadLinuxInstallationManifest() { return {}; },
    createLinuxInstallationOwner(options) { return {
      state: 'active', bootMode: 'resume', persistentInstanceId: '1257-fixture', nativeOwnerCreated: false,
      async install() {
        inner = new LinuxRuntimeBackend({ configPath: '/fixture/guest.cfg', epoch: guest.peer.epoch,
          temporaryRoot: spill, exports: options.exports.map(item => item.tag) }, {
          createSession: () => ({ socket: guest.socket, requestStop() { record('fixture-native-stop'); },
            async join() { record('fixture-native-join'); return { joined: true, retirementError: false, apiResult: -4 }; } }),
        });
        setImmediate(() => guest.opened()); await inner.opened; return { backend: inner };
      },
      async dispose() { await inner?.dispose(); return { resourcesRetired: true, filesRemoved: false, dataRetained: true, native: null }; },
    }; },
  }; },
});
const children = [], handles = [];
let connectState = 'not-started', connectError, caught;
try {
  router = new CommandRouter({ workspaceRoots: [work], temporaryRoot: spill },
    { linux: roots => new LinuxCommandBackend({ control, ...roots }) });
  const initial = control.status();
  control.command({ v: 1, instanceId: initial.instanceId, attemptId: initial.attemptId, action: 'setEnabled', enabled: true });
  await waitFor(() => control.status().admission, 'actual control admission');
  const facade = createChildProcessFacade(spec => {
    const handle = router.spawnPlugin(spec); handles.push(handle); return handle;
  });
  const spawn = (...args) => {
      const phase = args[2].stdio[2] === 'ignore' ? 'probe' : 'main';
      if (phase === 'main' && blocked) {
        // A concurrent plugin can occupy the single real Control admission slot
        // after auto-probe has been reaped. This driver fixes that ordering.
        blocker = router.spawnPlugin({ argv: command, cwd: work, env: {}, graceMs: 1000,
          stdio: { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' } });
        blocker.stdout.resume(); blocker.stderr.resume(); record('blocking-job-requested');
      }
      const child = facade.spawn(...args), events = [];
      children.push({ child, phase, events });
      for (const name of ['spawn', 'exit', 'close', 'error']) child.on(name, (...values) => {
        events.push(name); record('child-' + name, { phase, values: values.map(value => value instanceof Error
          ? { name: value.name, code: value.code, message: value.message } : value) });
      });
      return child;
  };
  if (pluginCase) {
  // This process-local platform label is the same explicit boundary as 1204.
  // No Node built-in function, SDK method, or plugin method is replaced.
  Object.defineProperty(process, 'platform', { value: 'openharmony' });
  const vendor = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
  const { Context } = await vendor('cordis');
  const { SystemPrompt } = await vendor('dsh-system-prompt');
  const { ToolRuntime } = await vendor('dsh-tools');
  const { SubprocessRuntime } = await vendor('dsh-subprocess');
  const mcp = await vendor('dsh-mcp-client');
  class FixtureSubprocess extends SubprocessRuntime {
    constructor(context) {
      super(context); this.backend = router; this.capabilities = router.capabilities;
      this.pluginProcess = { spawn };
      context.effect(() => async () => { await router.dispose(); await control.shutdown(); }, '1257 explicit guest owner');
    }
  }
  ctx = new Context(); await ctx.plugin(SystemPrompt); await ctx.plugin(ToolRuntime); await ctx.plugin(FixtureSubprocess);
  plugin = ctx.plugin(mcp, { transport: 'stdio', serverName: 'pending1257', command: command[0],
    args: command.slice(1), cwd: work, env: {}, reconnect: { enabled: false }, failOnStartupError: true,
    toolCallTimeoutMs: 1000, maxInstructionBytes: 8192 });
  registrationState = 'pending';
  Promise.resolve(plugin).then(() => { registrationState = 'resolved'; record('registration-resolved'); }, error => {
    registrationState = 'rejected'; connectError = { code: error.code, message: error.message }; record('registration-rejected', connectError);
  });
  } else {
    transport = new StdioClientTransport({ command: command[0], args: command.slice(1), cwd: work, stderr: 'pipe', spawn });
    transport.stderr.resume();
    client = new Client({ name: '1257-pending-start', version: '1' },
      { capabilities: {}, versionNegotiation: { mode: 'auto' } });
    connectState = 'pending';
    client.connect(transport, { timeout: 1000 }).then(() => { connectState = 'resolved'; record('connect-resolved'); }, error => {
      connectState = 'rejected'; connectError = { code: error.code, message: error.message }; record('connect-rejected', connectError);
    });
  }
  await waitFor(() => children.some(row => row.phase === 'main'), 'main requested after actual auto-probe');
  if (blocked) {
    await blocker.started;
    assert.equal(children.at(-1).events.includes('spawn'), false);
    assert.equal(guest.jobs.size, 2, 'probe plus actual blocker; main still waits for the one slot');
    assert.equal(router.linux.live.size, 2);
    record('before-close', { connectState, registrationState, guestJobs: guest.jobs.size, routedLive: router.linux.live.size });
    disposeState = 'pending';
    (pluginCase ? plugin.dispose() : transport.close()).then(() => { disposeState = 'resolved'; record('dispose-resolved'); }, error => {
      disposeState = 'rejected'; record('dispose-rejected', { message: error.message });
    });
    await waitFor(() => children.at(-1).events.includes('close'), 'pending main facade really closed');
    await delay(150);
    const main = children.at(-1);
    record('after-close', { disposeState, registrationState, connectState, events: main.events, killed: main.child.killed,
      closed: main.child._closed, guestJobs: guest.jobs.size, routedLive: router.linux.live.size });
    assert.deepEqual(main.events, ['exit', 'close']);
    assert.equal(main.child.killed, true);
    assert.equal(router.linux.live.size, 1, 'only the deliberately independent blocker remains');
    assert.equal(guest.jobs.size, 2, 'cancelled main never started a Python process');
    if (pluginCase) {
      assert.equal(ctx.tools.get('mcp__pending1257__echo'), undefined);
      assert.equal(disposeState, 'resolved', 'real plugin disposal must settle after its never-started main closed');
    } else {
      assert.equal(connectState, 'rejected', 'closed pre-spawn main must reject pending SDK connect');
      assert.equal(connectError.code, 'CONNECTION_CLOSED');
    }
  } else {
    await plugin;
    const tool = ctx.tools.get('mcp__pending1257__echo'); assert(tool);
    for (const text of ['first before EOF', '第二次仍在同一进程']) {
      const result = await tool.execute({ text }, { signal: new AbortController().signal });
      assert.deepEqual(result, { content: [{ type: 'text', text }] });
      assert.equal(children.at(-1).child._closed, false);
      assert.equal([...guest.jobs.values()].at(-1).inputEnded, false);
      toolResults.push(result);
    }
    await plugin.dispose(); disposeState = 'resolved';
    assert.equal(ctx.tools.get('mcp__pending1257__echo'), undefined);
    await waitFor(() => children.every(row => row.child._closed), 'normal facades closed');
    assert.deepEqual(children.at(-1).events, ['spawn', 'exit', 'close']);
    assert.equal(children.at(-1).child.exitCode, 0);
    assert.equal(router.linux.live.size, 0);
  }
} catch (error) {
  caught = { name: error.name, code: error.code, message: error.message, stack: error.stack };
} finally {
  blocker?.stdin.end();
  if (blocker) await blocker.done;
  await client?.close(); await router?.dispose(); await control.shutdown(); await guest.close();
  // Test-only final cleanup: a failed product disposal must not strand the
  // explicitly independent Python blocker or TCP fixture. Do not count this
  // manual owner teardown as successful product plugin disposal.
  if (!caught) await ctx?.fiber.dispose();
  const requests = [];
  for (const name of (await readdir(receipts)).sort()) {
    for (const line of (await readFile(join(receipts, name), 'utf8')).trim().split('\n')) {
      if (!line) continue; const row = JSON.parse(line); if (row.event === 'request') requests.push(row.message.method);
    }
  }
  const counts = Object.fromEntries(['server/discover', 'initialize', 'tools/list', 'tools/call'].map(method => [method, requests.filter(value => value === method).length]));
  assert.equal(counts.initialize, blocked ? 0 : 1);
  assert.equal(counts['tools/call'], blocked ? 0 : 2);
  const result = { variant, disposeState, registrationState, connectState, connectError, caught, toolResults, requestCounts: counts, scope: 'real SDK and Linux JS/TCP/Python; explicit native and guest boundary',
    guestErrors: guest.errors, children: children.map(row => ({ phase: row.phase, events: row.events,
      exitCode: row.child.exitCode, signalCode: row.child.signalCode, killed: row.child.killed, closed: row.child._closed })),
    guestProcesses: [...guest.jobs.values()].map(row => ({ id: row.id, close: row.close, completed: row.completed })),
    cleanup: { routerLive: router?.live.size, outerLive: router?.linux.live.size, innerLive: inner?.live.size },
    actorMutatesProduct: false, vmStarted: false };
  await writeFile(join(out, 'RESULT.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result));
}
if (caught) process.exitCode = 1;
