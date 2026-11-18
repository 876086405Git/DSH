import { spawn } from 'node:child_process';
import * as fs from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';

// Both children use the product preload. The parent never creates a publication
// temporary, provides a receipt, calls recovery, or removes a temporary before
// assertions. The old 30 preload runs this same driver as a failure control.
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const self = fileURLToPath(import.meta.url);
const symbol = Symbol.for('dsh.go.ohos.publication');
const emit = value => process.getBuiltinModule('fs').writeSync(1, JSON.stringify(value) + '\n');
function gate(phase, path) {
  emit({ gate: phase, temporaryPath: path });
  setInterval(() => {}, 1000);
  return new Promise(() => {});
}

if (process.argv[2] === 'child') {
  const config = JSON.parse(await fs.readFile(process.argv[3], 'utf8'));
  const service = globalThis[symbol];
  assert.equal(service?.protocolVersion, 1);
  emit({ startup: true, ownerId: service.ownerId ?? null, recoverySummary: service.recoverySummary ?? null });
  const childFs = { link: fs.link, async open(path, ...args) {
    // Path observation for the gate, never a cleanup rule.
    const temporary = args[0] === 'wx' && path !== config.source && path !== config.target;
    if (temporary && config.phase === 'reserved-before-open') await gate(config.phase, path);
    const handle = await fs.open(path, ...args);
    if (!temporary) return handle;
    if (config.phase === 'created-before-identify') await gate(config.phase, path);
    const writeFile = handle.writeFile.bind(handle), sync = handle.sync.bind(handle), close = handle.close.bind(handle);
    let writes = 0;
    handle.writeFile = async bytes => {
      if (writes === 0 && config.phase === 'identified-before-write') await gate(config.phase, path);
      await writeFile(bytes);
      if (++writes === 1 && config.phase === 'mid-copy') await gate(config.phase, path);
    };
    handle.sync = async () => { await sync(); if (config.phase === 'after-sync') await gate(config.phase, path); };
    handle.close = async () => {
      await close();
      if (config.phase === 'after-commit') {
        assert.equal((await fs.stat(config.target)).size, config.sourceBytes);
        await gate(config.phase, path);
      }
    };
    return handle;
  } };
  const { publishOhosExclusive } = await import(pathToFileURL(config.moduleFile));
  try { await publishOhosExclusive(config.source, config.target, childFs); emit({ published: true }); }
  catch (error) {
    emit({ published: false, code: error.code, name: error.name, message: error.message });
    if (error.code !== 'EEXIST') process.exitCode = 1;
  }
} else {
  const args = new Map();
  for (let i = 2; i < process.argv.length; i += 2) {
    if (!process.argv[i].startsWith('--') || !process.argv[i + 1]) throw new Error('expected --name value pairs');
    args.set(process.argv[i].slice(2), process.argv[i + 1]);
  }
  for (const name of ['node', 'simulation', 'publication', 'linked-lib', 'prefix', 'out']) {
    if (!args.has(name)) throw new Error(`missing --${name}`);
    args.set(name, resolve(args.get(name)));
  }
  const phases = args.has('phases') ? args.get('phases').split(',') : [
    'reserved-before-open', 'created-before-identify', 'identified-before-write', 'mid-copy', 'after-sync', 'after-commit',
  ];
  const directory = await fs.mkdtemp(join(tmpdir(), 'dsh-publication-ledger-kill-'));
  const rows = [], temporaryModules = [];
  const publicationPreload = join(args.get('publication'), 'preload.mjs');
  const inputs = { driver: { path: self, sha256: sha(await fs.readFile(self)) }, publication: {} };
  for (const [name, path] of [['node', args.get('node')], ['linkedLibrary', args.get('linked-lib')], ['simulation', args.get('simulation')]]) {
    inputs[name] = { path, sha256: sha(await fs.readFile(path)) };
  }
  for (const file of ['atomic.mjs', 'index.mjs', 'preload.mjs', 'ledger.mjs']) {
    try { inputs.publication[file] = sha(await fs.readFile(join(args.get('publication'), file))); }
    catch (error) { if (error.code !== 'ENOENT') throw error; inputs.publication[file] = null; }
  }
  async function state(path) {
    try { const bytes = await fs.readFile(path); return { exists: true, bytes: bytes.length, sha256: sha(bytes) }; }
    catch (error) { if (error.code === 'ENOENT') return { exists: false }; throw error; }
  }
  async function ledgerState(home) {
    try { return JSON.parse(await fs.readFile(join(home, 'ohos-ownership/ledger.json'), 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  }
  async function run(config, stopAtGate) {
    const path = join(directory, `config-${randomUUID()}.json`); await fs.writeFile(path, JSON.stringify(config));
    const env = { PATH: process.env.PATH, LANG: 'C.UTF-8', LD_PRELOAD: args.get('linked-lib'),
      DSH_GO_OHOS_SIM_PLATFORM: 'openharmony', DSH_HOME: config.home };
    const argv = ['--jitless', '--import', args.get('simulation'), '--import', publicationPreload, self, 'child', path];
    const child = spawn(args.get('node'), argv, { env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '', killedAtGate = false, timedOut = false;
    const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, 15000);
    child.stdout.on('data', chunk => {
      stdout += chunk;
      if (stopAtGate && !killedAtGate && stdout.includes(`"gate":"${config.phase}"`)) {
        killedAtGate = true; child.kill('SIGKILL');
      }
    });
    child.stderr.on('data', chunk => { stderr += chunk; });
    return await new Promise((accept, reject) => {
      child.once('error', error => { clearTimeout(timer); reject(error); });
      child.once('close', (code, signal) => {
        clearTimeout(timer); let events = [];
        try { events = stdout.trim().split('\n').filter(Boolean).map(line => JSON.parse(line)); } catch {}
        accept({ code, signal, stdout, stderr, events, killedAtGate, timedOut, argv });
      });
    });
  }
  async function moduleFor(provider) {
    const original = join(args.get('prefix'), 'node_modules/@deepseek-ai', provider, 'lib/index.js');
    const bytes = await fs.readFile(original);
    const moduleFile = join(dirname(original), `.m3b-recovery-${randomUUID()}.mjs`);
    await fs.writeFile(moduleFile, Buffer.concat([bytes, Buffer.from('\nexport { publishOhosExclusive };\n')]), { flag: 'wx' });
    temporaryModules.push(moduleFile);
    return { moduleFile, providerSHA256: sha(bytes), original };
  }
  try {
    for (const provider of ['dsh-attachment-local', 'dsh-session-persistence-jsonl']) {
      const module = await moduleFor(provider);
      for (const phase of phases) {
        const row = { provider, phase, providerSHA256: module.providerSHA256, passed: false }; rows.push(row);
        const caseDirectory = join(directory, `${provider}-${phase}`); await fs.mkdir(caseDirectory);
        const home = join(caseDirectory, 'app-data'); await fs.mkdir(home, { mode: 0o700 });
        const source = join(caseDirectory, 'source'), target = join(caseDirectory, 'final');
        const bytes = Buffer.alloc(3 * 65536 + 17, 97); await fs.writeFile(source, bytes);
        const config = { ...module, source, target, home, sourceBytes: bytes.length, phase };
        try {
          const first = row.first = await run(config, true);
          assert.equal(first.timedOut, false, first.stderr); assert.equal(first.killedAtGate, true, first.stderr);
          assert.equal(first.signal, 'SIGKILL');
          const temporaryPath = first.events.find(event => event.gate === phase)?.temporaryPath;
          assert.equal(typeof temporaryPath, 'string'); row.temporaryPath = temporaryPath;
          row.afterKill = { source: await state(source), final: await state(target),
            temporary: await state(temporaryPath), ledger: await ledgerState(home) };
          assert.equal(row.afterKill.source.sha256, sha(bytes));
          if (phase === 'after-commit') {
            assert.equal(row.afterKill.final.sha256, sha(bytes)); assert.deepEqual(row.afterKill.temporary, { exists: false });
          } else {
            assert.deepEqual(row.afterKill.final, { exists: false });
            if (phase === 'mid-copy') assert.equal(row.afterKill.temporary.bytes, 65536);
            if (phase === 'after-sync') assert.equal(row.afterKill.temporary.sha256, sha(bytes));
          }
          const retry = row.retry = await run({ ...config, phase: 'retry' }, false);
          assert.equal(retry.timedOut, false); assert.equal(retry.code, 0, retry.stderr);
          const startup = retry.events.find(event => event.startup), outcome = retry.events.find(event => 'published' in event);
          row.afterRetry = { source: await state(source), final: await state(target),
            temporary: await state(temporaryPath), ledger: await ledgerState(home) };
          assert.equal(row.afterRetry.source.sha256, sha(bytes)); assert.equal(row.afterRetry.final.sha256, sha(bytes));
          if (phase === 'after-commit') { assert.equal(outcome?.published, false); assert.equal(outcome.code, 'EEXIST'); }
          else assert.equal(outcome?.published, true);
          // Check the actual leftover before metadata: the old control fails
          // because restart left its half-written temporary behind.
          if (phase !== 'created-before-identify') {
            assert.deepEqual(row.afterRetry.temporary, { exists: false }, 'restart must automatically remove the registered temporary');
          }
          const firstOwner = first.events.find(event => event.startup)?.ownerId;
          assert.equal(typeof firstOwner, 'string'); assert.notEqual(startup?.ownerId, firstOwner);
          assert(startup?.recoverySummary, 'production preload must report disk-ledger recovery');
          const summary = startup.recoverySummary;
          const expectedKind = phase === 'created-before-identify' ? 'unresolved'
            : ['reserved-before-open', 'after-commit'].includes(phase) ? 'missing' : 'removed';
          for (const kind of ['removed', 'missing', 'unresolved']) assert.equal(summary[kind].length, kind === expectedKind ? 1 : 0);
          assert.equal(summary[expectedKind][0].path, temporaryPath);
          if (phase === 'created-before-identify') {
            assert.equal(summary.unresolved[0].reason, 'reserved-without-inode');
            assert.equal(row.afterRetry.temporary.bytes, 0); assert.equal(row.afterRetry.ledger.entries.length, 1);
          } else assert.deepEqual(row.afterRetry.ledger.entries, []);
          row.passed = true;
        } catch (error) { row.failure = { name: error.name, code: error.code, message: error.message, stack: error.stack }; }
        console.log(`${provider}:${phase}: ${row.passed ? 'PASS' : 'FAIL'}`);
      }
      assert.equal(sha(await fs.readFile(module.original)), module.providerSHA256, 'provider bytes remain unchanged');
    }
    await fs.mkdir(dirname(args.get('out')), { recursive: true });
    await fs.writeFile(args.get('out'), JSON.stringify({ inputs,
      scope: 'real provider helper with export-only instrumentation, product preload and disk ledger; Linux SIGKILL, not power loss or OHOS ABI',
      parentDoesNotSupplyReceipt: true, parentDoesNotRecoverOrUnlinkPublicationTemporary: true,
      result: { passed: rows.filter(row => row.passed).length, failed: rows.filter(row => !row.passed).length, skipped: 0 }, rows }, null, 2) + '\n');
    if (rows.some(row => !row.passed)) process.exitCode = 1;
  } finally {
    for (const path of temporaryModules) await fs.rm(path, { force: true });
    // All automatic-recovery assertions precede fixture teardown.
    await fs.rm(directory, { recursive: true, force: true });
  }
}
