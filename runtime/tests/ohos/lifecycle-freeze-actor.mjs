import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { bootstrapDshNetwork } from '../../ohos/net/bootstrap.mjs';
import { installPublication } from '../../ohos/publication/index.mjs';
import { createLifecycleTransport } from '../../ohos/lifecycle/transport.mjs';

const config = JSON.parse(await fs.readFile(process.argv[2], 'utf8'));
await fs.mkdir(join(config.root, 'home'), { recursive: true });
process.env.DSH_HOME = join(config.root, 'home');
const network = bootstrapDshNetwork(join(resolve(process.env.DSH_LIFECYCLE_TEST_PREFIX), 'node_modules/@deepseek-ai/dsh/lib/bin.js'));
const transport = createLifecycleTransport(network);
await installPublication();
const { engineFixture, load } = await import('./lifecycle-engine-fixture.mjs');
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
const commands = input[Symbol.asyncIterator]();
const keepAlive = setInterval(() => {}, 1000);
const report = { mode: config.mode, tool: config.tool, logical: config.logical, strict: process.platform === 'openharmony' && typeof WebAssembly === 'undefined' };
const send = (stage, value = {}) => process.stdout.write(JSON.stringify({ stage, ...value }) + '\n');
let f, active, held, shellResult;
try {
  f = await engineFixture({ root: config.root, useLifecycle: config.mode !== 'baseline', revalidateTransport: () => transport.revalidate() });
  const owner = await f.create();
  const ready = Promise.withResolvers(), released = Promise.withResolvers();
  if (config.tool === 'bash') {
    const [{ default: OhSubprocessRuntime }, { LocalBashExecutor }] = await Promise.all([
      import('../../ohos/process/index.mjs'), load('dsh-bash-local'),
    ]);
    const temp = join(config.root, 'process-tmp'); await fs.mkdir(temp);
    await f.ctx.plugin(OhSubprocessRuntime, { workspaceRoots: [join(config.root, 'workspace')], temporaryRoot: temp });
    await f.ctx.plugin(LocalBashExecutor, { cwd: join(config.root, 'workspace'), timeoutMs: 2000, maxTimeoutMs: 30000, maxOutputBytes: 65536, maxSpillBytes: 1048576, graceMs: 100 });
  } else await f.ctx.plugin(await load('dsh-tool-call-timeout-policy'));
  const token = await (await network.fetch(config.server + '/issue')).json();
  f.register('effect', async (_args, exec) => {
    const file = await fs.open(join(config.root, 'workspace/effect.txt'), 'a', 0o600);
    try { await file.write('once\n'); await file.sync(); } finally { await file.close(); }
    const response = await network.fetch(config.server + '/hold', { method: 'POST', body: 'single-side-effect', headers: { authorization: 'Bearer ' + token.token } });
    held = response.text();
    let shell;
    if (config.tool === 'bash') shell = await f.ctx.shell.execute(f.ctx.shell.resolve({ command: 'sleep 30; printf forbidden > after-cancel', signal: exec.signal }));
    ready.resolve();
    if (shell) { shellResult = await shell.result(); return [{ type: 'text', text: JSON.stringify(shellResult) }]; }
    await new Promise((resolve, reject) => {
      const abort = () => { exec.signal.removeEventListener('abort', abort); reject(exec.signal.reason); };
      if (exec.signal.aborted) { abort(); return; }
      exec.signal.addEventListener('abort', abort, { once: true });
      released.promise.then(() => { exec.signal.removeEventListener('abort', abort); resolve(); });
    });
    exec.signal.throwIfAborted();
    await fs.writeFile(join(config.root, 'workspace/completed.txt'), 'completed');
    return [{ type: 'text', text: 'completed once' }];
  }, config.tool === 'bash' ? {} : { timeoutMs: 800 });
  active = owner.run([{ id: 'freeze-call' }]);
  active.catch(() => {});
  await ready.promise;
  send('ready', { status: f.coordinator.status(owner.session.id), budget: config.tool === 'bash' ? 2000 : 800 });
  for await (const command of commands) {
    if (command === 'pause') {
      const status = await f.coordinator.pause();
      send('paused', { status });
    } else if (command === 'resume') {
      const status = await f.coordinator.resume();
      report.afterResume = status;
      report.inFlightBody = await held;
      const auth = await network.fetch(config.server + '/write', { method: 'POST', headers: { authorization: 'Bearer ' + token.token } });
      report.authenticationAfterFreeze = auth.status; await auth.arrayBuffer();
      send('resumed', { status, authenticationAfterFreeze: auth.status });
    } else if (command === 'release') {
      if (config.tool === 'bash') {
        report.liveBeforeCancel = f.ctx.subprocess.backend.live.size;
        report.cancelled = await f.coordinator.cancel(owner.session.id);
      } else released.resolve();
      try { await active; } catch (error) { report.runError = { code: error.code, message: error.message }; }
      await f.ctx.sessions.flush(owner.session);
      report.events = await f.readEvents(owner.session.id);
      report.status = f.coordinator.status(owner.session.id);
      if (config.tool === 'bash') { report.shellResult = shellResult; report.liveAfterCancel = f.ctx.subprocess.backend.live.size; }
      report.effects = await fs.readFile(join(config.root, 'workspace/effect.txt'), 'utf8');
      report.completedMarker = await fs.stat(join(config.root, 'workspace/completed.txt')).then(() => true, () => false);
      report.forbiddenMarker = await fs.stat(join(config.root, 'workspace/after-cancel')).then(() => true, () => false);
      report.transport = transport.status();
      await fs.writeFile(config.reportPath, JSON.stringify(report, null, 2) + '\n');
      send('done', { reportPath: config.reportPath }); break;
    } else throw new Error('unknown controller command');
  }
} catch (error) {
  process.stderr.write(error.stack + '\n'); process.exitCode = 1;
} finally {
  input.close(); process.stdin.destroy();
  await f?.close(); transport.close(); await network.dispatcher.destroy(); clearInterval(keepAlive);
}
