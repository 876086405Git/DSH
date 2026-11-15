import * as fs from 'node:fs/promises';
import { join } from 'node:path';
import http from 'node:http';
import assert from 'node:assert/strict';
import { installPublication } from '../../ohos/publication/index.mjs';
import { engineFixture, load } from './lifecycle-engine-fixture.mjs';

const config = JSON.parse(await fs.readFile(process.argv[2], 'utf8'));
const { root, scenario, mode, stopAt, baseline } = config;
await fs.mkdir(join(root, 'home'), { recursive: true });
process.env.DSH_HOME = join(root, 'home');
await installPublication();
assert.equal(process.platform, 'openharmony');
assert.equal(typeof WebAssembly, 'undefined');
const keepAlive = setInterval(() => {}, 1000);
const signalStage = async (stage, payload = {}) => {
  process.stdout.write(JSON.stringify({ stage, scenario, pid: process.pid, ...payload }) + '\n');
  if (stage === stopAt) await new Promise(() => {});
};
globalThis[Symbol.for('dsh.go.ohos.lifecycle.fixture.before-append')] = () => signalStage('outcome');
const post = label => new Promise((resolve, reject) => {
  const req = http.request(config.counterUrl, { method: 'POST', headers: { 'content-type': 'text/plain' } }, res => {
    res.resume(); res.on('end', () => res.statusCode === 200 ? resolve() : reject(new Error('counter rejected request')));
  });
  req.on('error', reject); req.end(label);
});
const effect = async label => {
  const handle = await fs.open(join(root, 'workspace/effects.txt'), 'a', 0o600);
  try { await handle.write(label + '\n'); await handle.sync(); }
  finally { await handle.close(); }
  await post(label);
};
let f;
try {
  f = await engineFixture({ root, useLifecycle: !baseline,
    sourcePath: baseline ? config.baselineSource : undefined,
    beforeResultAppend: baseline ? '\t\t\tawait globalThis[Symbol.for("dsh.go.ohos.lifecycle.fixture.before-append")]();' : '',
    onStage: (kind, body) => signalStage(kind + (body.identity?.callId === 'B' ? ':B' : ''), { callSeq: body.identity?.callSeq }) });
  if (mode === 'run') {
    const owner = await f.create();
    if (scenario.endsWith('-spill')) {
      const { LocalSpillStore } = await load('dsh-spill-local');
      await f.ctx.plugin(LocalSpillStore, { root: join(root, 'spills'), cleanupPeriodDays: 0 });
    }
    if (scenario === 'policy-spill') await f.ctx.plugin(await load('dsh-spill-policy'), { maxInlineTokens: 1024 });
    if (scenario === 'deferred-context') {
      const { createUserMessage } = await load('dsh-llm');
      f.ctx.on('tools/post-execute', async (_exec, _result, next) => ({ ...await next(),
        additionalContexts: [createUserMessage({ content: [{ type: 'text', text: 'deferred context must not disappear' }], source: { kind: 'ptc-mode' } })] }));
    }
    f.register('effect', async ({ label = 'A' }) => {
      if (scenario === 'parallel' && label === 'A') {
        await signalStage('A-active'); await new Promise(() => {});
      }
      await effect(label);
      await signalStage('effect', { label });
      return [{ type: 'text', text: 'durable final ' + label + ' 中文' + (scenario === 'policy-spill' ? ' large complete output 中文'.repeat(2000) : '') }];
    }, { isConcurrencySafe: () => scenario === 'parallel' });
    if (scenario === 'search-spill') {
      const [{ SessionProjectionRegistry }, { LocalFileSystem }, { WorkingDirectoryService }, search, { default: subprocess }] = await Promise.all([
        load('dsh-session-projection'), load('dsh-fs-local'), load('dsh-working-directory'), load('dsh-tool-fs-search'), import('../../ohos/process/index.mjs'),
      ]);
      await f.ctx.plugin(SessionProjectionRegistry);
      await f.ctx.plugin(LocalFileSystem, { cwd: join(root, 'workspace') });
      await f.ctx.plugin(WorkingDirectoryService, { defaultDirectory: join(root, 'workspace') });
      await fs.mkdir(join(root, 'temporary'), { mode: 0o700 });
      await f.ctx.plugin(subprocess, { workspaceRoots: [join(root, 'workspace')], temporaryRoot: join(root, 'temporary') });
      await f.ctx.plugin(search, { sampleOverCapGlobResults: false, globMaxResults: 1 });
      await Promise.all(['一.txt', '二.txt', '三.txt'].map(name => fs.writeFile(join(root, 'workspace', name), name)));
      f.ctx.on('tools/execute', async (_exec, next) => { await effect('A'); return next(); });
      await owner.run([{ id: 'A', name: 'glob', arguments: { pattern: '*.txt' } }]);
    } else await owner.run((scenario === 'parallel' ? ['A', 'B'] : ['A']).map(label => ({ id: label, arguments: { label } })));
    await signalStage('done', { status: f.coordinator.status(owner.session.id) });
  } else {
    const recovered = await f.recover('session-A', { originalOnly: mode === 'original-recovery',
      publicFactory: mode !== 'original-recovery' && stopAt !== 'recovered-flushed',
      onFlushed: () => signalStage('recovered-flushed') });
    const stored = [];
    for (const call of f.coordinator.status('session-A').calls) if (call.hasReturned || call.hasFinalOutcome) {
      try { stored.push(await f.coordinator.result('session-A', call.callSeq)); }
      catch (error) { stored.push({ callSeq: call.callSeq, error: error.code }); }
    }
    let admission;
    try { await f.coordinator.gate('session-A'); admission = 'allowed'; }
    catch (error) { admission = error.code; }
    let independent;
    if (config.independentSession) {
      const other = await f.create(config.independentSession);
      f.register('independent', async () => {
        await fs.writeFile(join(root, 'workspace', config.independentSession), 'new explicitly requested call');
        return [{ type: 'text', text: 'independent result' }];
      });
      await other.run([{ id: 'A', name: 'independent' }]);
      independent = { state: f.coordinator.status(config.independentSession).state,
        oldSessionState: f.coordinator.status('session-A').state,
        effect: await fs.readFile(join(root, 'workspace', config.independentSession), 'utf8') };
    }
    const report = { ...recovered, stored, admission, independent, node: process.version,
      strict: process.platform === 'openharmony' && typeof WebAssembly === 'undefined',
      journal: f.journal.records.map(record => record.body) };
    await fs.writeFile(config.reportPath, JSON.stringify(report, null, 2) + '\n');
    await signalStage('recovered', { reportPath: config.reportPath });
  }
} catch (error) {
  const report = { error: { name: error.name, code: error.code, message: error.message }, status: f?.coordinator.status('session-A') };
  if (config.reportPath) await fs.writeFile(config.reportPath, JSON.stringify(report, null, 2) + '\n');
  process.stderr.write(JSON.stringify(report) + '\n'); process.exitCode = 1;
} finally {
  await f?.close(); clearInterval(keepAlive);
}
