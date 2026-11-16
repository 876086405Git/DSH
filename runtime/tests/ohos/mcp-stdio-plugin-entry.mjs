// Real Cordis MCP plugin + current production routing and byte protocol.
// The owner/native session/guest-kernel edges are explicit host fixtures.
import assert from 'node:assert/strict';
import { appendFileSync } from 'node:fs';
import { mkdir, readFile, writeFile, readdir, copyFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createProcessGuest, waitFor } from './mcp-stdio-guest-fixture.mjs';
import { CommandRouter } from '../../ohos/process/command-router.mjs';
import { LinuxCommandBackend } from '../../ohos/process/linux-backend.mjs';
import { LinuxControl } from '../../ohos/linux/control.mjs';
import { LinuxRuntimeBackend } from '../../ohos/linux/backend.mjs';
import { createChildProcessFacade } from '../../ohos/process/plugin-process.mjs';

const prefix = resolve(process.env.DSH_PREFIX);
const output = resolve(process.env.OHOS_MCP_TEST_OUT);
const python = resolve(process.env.OHOS_MCP_PYTHON);
const work = join(output, 'work'), spill = join(output, 'spill'), receipts = join(output, 'server-receipts');
for (const path of [work, spill, receipts]) await mkdir(path);
const script = join(work, 'server.py');
await copyFile(fileURLToPath(new URL('./mcp-stdio-server.py', import.meta.url)), script);
const command = ['python3', '-u', script, receipts];
const report = { schema: 1, state: 'SETUP', actualHostPlatform: process.platform, node: process.versions.node,
  scope: 'Real Cordis plugin, SDK, Linux JS routing and TCP protocol with a real local Python stdio server; explicit owner/session/guest-kernel fixtures',
  deviceRun: false, realVM: false, toolResults: [], cleanup: {}, fixtureBoundary: {} };
let sequence = 0;
const record = (event, fields = {}) => {
  const value = { seq: ++sequence, event, ...fields };
  appendFileSync(join(output, 'TRACE.jsonl'), JSON.stringify(value) + '\n'); return value.seq;
};
const errorValue = error => ({ name: error.name, code: error.code, message: error.message, stack: error.stack });
let guest, control, inner, router, ctx, plugin, failure, contextDisposed = false;
const jobs = [], children = [];
let ownerDisposals = 0, sessionStops = 0, sessionJoins = 0;
try {
  assert.equal(process.platform, 'linux');
  assert.equal(process.versions.node, '24.22.1');
  Object.defineProperty(process, 'platform', { value: 'openharmony' });
  guest = await createProcessGuest({ python, command, cwd: work, record });
  control = new LinuxControl({ hostPaths: { directory: output, nativeLibraryDirectory: '/explicit-fixture/native' } }, {
    async loadModule() {
      return {
        async loadLinuxInstallationManifest() { return {}; },
        createLinuxInstallationOwner(input) {
          return { state: 'active', bootMode: 'resume', persistentInstanceId: 'explicit-host-fixture', nativeOwnerCreated: false,
            async install() {
              inner = new LinuxRuntimeBackend({ configPath: '/explicit-fixture/guest.cfg', epoch: guest.peer.epoch,
                temporaryRoot: spill, exports: input.exports.map(row => row.tag) }, {
                createSession: () => ({ socket: guest.socket,
                  requestStop() { sessionStops++; },
                  async join() { sessionJoins++; return { joined: true, retirementError: false, apiResult: -4 }; } }),
              });
              setImmediate(() => guest.opened()); await inner.opened; return { backend: inner };
            },
            async dispose() {
              ownerDisposals++;
              report.fixtureBoundary.innerDispose = await inner?.dispose();
              return { resourcesRetired: true, filesRemoved: false, dataRetained: false, native: null };
            },
          };
        },
      };
    },
  });
  router = new CommandRouter({ workspaceRoots: [work], temporaryRoot: spill },
    { linux: roots => new LinuxCommandBackend({ control, ...roots }) });
  assert.equal(router.select(command), router.linux);
  assert.equal(router.nativePython, undefined);
  const initial = control.status();
  control.command({ v: 1, instanceId: initial.instanceId, attemptId: initial.attemptId, action: 'setEnabled', enabled: true });
  await waitFor(() => control.status().admission, 'explicit fixture admitted');
  const facade = createChildProcessFacade(spec => {
    assert.deepEqual(spec.argv, command);
    const job = router.spawnPlugin(spec), row = { job, outcome: null, error: null };
    jobs.push(row);
    record('router-plugin-spawn', { index: jobs.length - 1, argv: spec.argv, cwd: spec.cwd, stdio: spec.stdio });
    job.started.then(() => record('outer-started', { index: jobs.indexOf(row) }), error => { row.error = errorValue(error); });
    job.done.then(value => { row.outcome = value; record('outer-done', { index: jobs.indexOf(row), outcome: value }); },
      error => { row.error = errorValue(error); record('outer-error', { index: jobs.indexOf(row), error: row.error }); });
    return job;
  });
  const load = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
  const [{ Context }, { SystemPrompt }, { ToolRuntime }, { SubprocessRuntime }, mcp] =
    await Promise.all(['cordis', 'dsh-system-prompt', 'dsh-tools', 'dsh-subprocess', 'dsh-mcp-client'].map(load));
  // The ordinary Cordis provider seam carries the fixture installation owner.
  // Actual routing/facade methods are delegated unchanged; MCP/SDK methods are
  // never replaced, and no Node built-in is globally redirected.
  class FixtureSubprocess extends SubprocessRuntime {
    constructor(context) {
      super(context); this.backend = router; this.capabilities = router.capabilities;
      this.pluginProcess = { spawn(...args) {
        const child = facade.spawn(...args), row = { child, closed: null, errors: [] };
        children.push(row);
        child.on('close', (code, signal) => { row.closed = { code, signal }; record('facade-close', { index: children.indexOf(row), code, signal }); });
        child.on('error', error => row.errors.push(errorValue(error)));
        return child;
      } };
      context.effect(() => async () => { await router.dispose(); await control.shutdown(); }, 'explicit host fixture provider');
    }
  }
  ctx = new Context();
  await ctx.plugin(SystemPrompt); await ctx.plugin(ToolRuntime); await ctx.plugin(FixtureSubprocess);
  report.state = 'TARGET_STARTED';
  plugin = await ctx.plugin(mcp, { transport: 'stdio', serverName: 'linux_fixture', command: command[0],
    args: command.slice(1), cwd: work, env: {}, reconnect: { enabled: false }, failOnStartupError: true,
    toolCallTimeoutMs: 3000, maxInstructionBytes: 8192 });
  const tool = ctx.tools.get('mcp__linux_fixture__echo');
  assert(tool, 'the actual plugin must register its discovered tool');
  record('plugin-tool-registered', { name: tool.name });
  assert.equal(jobs.length, 2, 'one normal discovery probe and one main server');
  const main = [...guest.jobs.values()].at(-1);
  assert.deepEqual(main.mounts, [
    { tag: 'dsh1', source: '', target: work, readOnly: false },
    { tag: 'dsh0', source: '', target: spill, readOnly: false },
  ]);
  report.mainJob = main.id;
  for (const text of ['第一条：雪', 'second request before EOF']) {
    const value = await tool.execute({ text }, { signal: new AbortController().signal });
    // createExecutor projects successful MCP responses to the ToolRuntime
    // content vocabulary; isError:false is not a field of that public value.
    assert.deepEqual(value, { content: [{ type: 'text', text }] });
    assert.equal(main.inputEnded, false);
    assert.equal(main.close, null);
    assert.equal(jobs[1].outcome, null);
    assert.equal(children[1].child.stdin.writableEnded, false);
    report.toolResults.push({ text, value, job: main.id, beforeEOF: true, beforeClose: true,
      event: record('plugin-tool-result', { job: main.id, text, value, beforeEOF: true, beforeClose: true }) });
  }
  await plugin.dispose(); plugin = undefined;
  assert.equal(ctx.tools.get('mcp__linux_fixture__echo'), undefined);
  await waitFor(() => children.every(row => row.closed) && jobs.every(row => row.outcome), 'all facades and routed jobs closed');
  assert.deepEqual(jobs[1].outcome, { exitCode: 0, signal: null });
  assert.deepEqual(children[1].closed, { code: 0, signal: null });
  assert.deepEqual(main.close, { code: 0, signal: null });
  assert.equal(main.cancelled, false);
  assert.equal(main.inputEnded, true);
  assert(children.every(row => row.errors.length === 0));
  assert(jobs.every(row => row.error === null));
  assert.deepEqual(await Promise.all(jobs.map(row => row.job.waitForExit())), [true, true]);
  assert.deepEqual([router.live.size, router.linux.live.size, inner.live.size], [0, 0, 0]);
  const files = await readdir(receipts);
  report.servers = [];
  for (const name of files.sort()) {
    const lines = (await readFile(join(receipts, name), 'utf8')).trimEnd().split('\n').map(JSON.parse);
    report.servers.push({ name, events: lines });
  }
  assert.equal(report.servers.length, 2);
  const mainEvents = report.servers.find(row => row.events[0].pid === main.child.pid).events;
  assert.equal(mainEvents.filter(row => row.event === 'request' && row.message.method === 'initialize').length, 1);
  assert.equal(mainEvents.filter(row => row.event === 'request' && row.message.method === 'tools/list').length, 1);
  const calls = mainEvents.filter(row => row.event === 'request' && row.message.method === 'tools/call');
  assert.equal(calls.length, 2); assert.notEqual(calls[0].message.id, calls[1].message.id);
  for (const call of calls) {
    const response = mainEvents.find(row => row.event === 'response' && row.message.id === call.message.id);
    assert.deepEqual(response.message, { jsonrpc: '2.0', id: call.message.id,
      result: { content: [{ type: 'text', text: call.message.params.arguments.text }], isError: false } });
  }
  assert.equal(mainEvents.at(-1).event, 'stdin-eof');
  report.mainRequests = calls.map(row => row.message);
  report.mainProcess = { pid: main.child.pid, close: main.close, receivedBytes: main.received,
    acceptedBytes: main.accepted, producedBytes: main.sent, consumedBytes: main.acked };
  report.probe = { process: [...guest.jobs.values()][0].close, outer: jobs[0].outcome, facade: children[0].closed,
    scope: 'SDK auto-probe ends and requests termination; its signal outcome is recorded separately' };
  report.state = 'PASS_SCOPED_HOST_STDIO_MCP_PLUGIN';
} catch (error) {
  failure = error; report.error = errorValue(error);
  report.state = report.state === 'SETUP' ? 'SETUP_FAILED' : 'TARGET_FAILED';
} finally {
  const cleanup = async (name, operation) => {
    try { const value = await operation(); report.cleanup[name] = { completed: true, value }; }
    catch (error) { failure ??= error; report.cleanup[name] = { completed: false, error: errorValue(error) }; }
  };
  if (plugin) await cleanup('plugin', () => plugin.dispose());
  if (ctx) await cleanup('context', async () => { await ctx.fiber.dispose(); contextDisposed = true; });
  else {
    if (router) await cleanup('router', () => router.dispose());
    if (control) await cleanup('control', () => control.shutdown());
  }
  if (guest) await cleanup('realServerProcessesAndSockets', () => guest.close());
  report.fixtureBoundary = { ...report.fixtureBoundary, ownerDisposals, sessionStops, sessionJoins,
    scope: 'Session join/rootfs close acknowledgements are fixture values; actual Python process close is separately observed' };
  report.finalLive = { router: router?.live.size, outer: router?.linux.live.size, inner: inner?.live.size };
  report.finalControl = control?.status();
  report.guestFixtureErrors = guest?.errors;
  if (failure || !contextDisposed || guest?.errors.length || Object.values(report.finalLive).some(value => value !== 0)
      || report.finalControl?.shutdownComplete !== true) {
    report.priorState = report.state; report.state = 'FAILED';
  }
  await writeFile(join(output, 'REPORT.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ state: report.state, toolResults: report.toolResults.length, finalLive: report.finalLive }));
}
process.exitCode = report.state === 'PASS_SCOPED_HOST_STDIO_MCP_PLUGIN' ? 0 : 1;
