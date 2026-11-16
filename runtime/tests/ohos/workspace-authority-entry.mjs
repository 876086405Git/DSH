// Imported after the sole product preload with argv[1] equal to the actual DSH
// bin. SDK picker/Preferences boundaries are explicit fixtures; FD publication,
// N-API owner, public Cordis runtime and every positive shell Worker are real.
import { isMainThread, Worker } from 'node:worker_threads';
if (isMainThread) {
  const assert = (await import('node:assert/strict')).default;
  const fs = await import('node:fs/promises');
  const { join } = await import('node:path');
  const { createRequire } = await import('node:module');
  const { pathToFileURL } = await import('node:url');
  const { once } = await import('node:events');
  const config = JSON.parse(await fs.readFile(process.env.OHOS_932_CONFIG, 'utf8'));
  const require = createRequire(join(config.payload, 'package.json'));
  const { Context } = await import(pathToFileURL(require.resolve('@deepseek-ai/cordis')));
  const { default: OhSubprocessRuntime } = await import(pathToFileURL(join(config.payload, 'runtime/ohos/process/index.mjs')));
  const { borrowProcessGrantAuthority } = await import(pathToFileURL(join(config.payload, 'runtime/ohos/process/files/process-authority.mjs')));
  const { workspaceFixture, until } = await import('./authorized-workspaces-fixture.mjs');
  const report = { scope: 'real DSH preload/public factory/native FD; SDK doubles; no full user-session, Linux guest, SDK or device claim',
    scenario: config.scenario, cases: [], started: new Date().toISOString() };
  const cleanups = [], contexts = new Set();
  let f, row, logical, selectedPath, ctx;
  const check = async (name, action) => {
    const start = performance.now();
    try { await action(); report.cases.push({ name, pass: true, milliseconds: performance.now() - start }); }
    catch (error) { report.cases.push({ name, pass: false, error: { code: error.code ?? null, message: error.message, stack: error.stack } }); }
  };
  const newContext = async () => {
    const context = new Context(); contexts.add(context);
    await context.plugin(OhSubprocessRuntime, { workspaceRoots: [config.physical], temporaryRoot: config.temporary });
    return context;
  };
  const status = () => f.native.workspaceGrant('status', row.nativeKey, row.nativeGeneration);
  const start = (context, script, { mode = 'read-only', cwd = logical, root = logical, env = {}, argv, signal } = {}) => {
    const prepared = context.subprocess.prepare(argv ?? ['bash', '-c', script], { mode, workspaceRoot: root }, signal);
    return startPrepared(context, prepared, { cwd, env, signal });
  };
  const startPrepared = (context, argv, { cwd = logical, env = {}, signal } = {}) => {
    const child = context.subprocess.spawn({ argv, cwd, env, signal, graceMs: 100,
      stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
    const stdout = [], stderr = [];
    child.stdout.on('data', bytes => stdout.push(bytes)); child.stderr.on('data', bytes => stderr.push(bytes));
    const completed = (async () => {
      let outcome, error, exitError;
      try { outcome = await child.done; } catch (value) { error = value; }
      try { assert.equal(await child.waitForExit(), true); } catch (value) { exitError = value; }
      return { outcome, error, exitError, stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr) };
    })();
    return { child, completed, stdout: () => Buffer.concat(stdout).toString('utf8') };
  };
  const run = async (script, options = {}, context = ctx) => (await start(context, script, options)).completed;
  const success = (result, expected) => {
    assert.equal(result.error, undefined); assert.equal(result.exitError, undefined);
    assert.equal(result.outcome.exitCode, 0); assert.equal(result.outcome.signal, null);
    if (expected !== undefined) assert.equal(result.stdout.toString('utf8'), expected);
    assert.equal(status().leases, 0, 'all native task leases drained after actual factory completion');
  };
  try {
    await fs.mkdir(config.physical, { recursive: true }); await fs.mkdir(config.temporary, { recursive: true });
    await fs.writeFile(join(config.physical, 'marker'), 'PHYSICAL\n');
    f = await workspaceFixture({ after: fn => cleanups.push(fn) }, { pathThrow: true });
    const uri = 'file://docs/storage/Users/currentUser/Projects/932-official-entry';
    const request = f.call(f, 'select', { userGesture: true });
    await until(() => f.pickers.length === 1); f.select([uri]);
    const selected = await request.done; assert.equal(selected.error, undefined);
    const id = selected.value.workspaces[0].id;
    const attached = await f.call(f, 'attach', { id, userGesture: true }).done;
    assert.equal(attached.error, undefined); row = attached.value.workspaces[0];
    assert.equal(row.nativeGrant, 'ready'); assert.equal(row.candidatePath, null); assert.equal(f.fds.size, 0);
    logical = '/workspaces/' + id; selectedPath = f.uriPaths.get(uri);
    await fs.writeFile(join(selectedPath, 'marker'), 'GRANT\n');
    await fs.mkdir(join(selectedPath, 'sub')); await fs.writeFile(join(selectedPath, 'sub/nested'), 'NESTED\n');
    ctx = await newContext();
    report.published = { nativeGrant: row.nativeGrant, candidatePath: row.candidatePath, borrowedFDs: f.fds.size, logicalRoot: logical };

    if (config.scenario === 'late-host') {
      await check('host absent at sole preload is explicitly unavailable even if ETS loads it later', async () => {
        assert.throws(() => borrowProcessGrantAuthority(), { code: 'ERR_WORKSPACE_HOST_NOT_LOADED' });
        assert.throws(() => start(ctx, 'cat marker'), { code: 'ERR_WORKSPACE_HOST_NOT_LOADED' });
        success(await run('cat marker', { cwd: config.physical, root: config.physical }), 'PHYSICAL\n');
        assert.equal(status().active, true); assert.equal(status().leases, 0);
      });
    } else if (config.scenario === 'retirement-fault') {
      await check('final native retirement uncertainty is a provider failure and quarantines shared grant admission', async () => {
        const first = await run('cat marker');
        assert.equal(first.stdout.toString('utf8'), 'GRANT\n');
        assert.equal(first.error?.code, 'ERR_WORKSPACE_DRAIN'); assert.equal(first.exitError?.code, 'ERR_WORKSPACE_DRAIN');
        assert.equal(status().leases, 0, 'fixture changed confirmation only; actual native release still ran');
        assert.equal(borrowProcessGrantAuthority().unavailableReason, 'ERR_WORKSPACE_DRAIN');
        assert.equal(borrowProcessGrantAuthority().snapshot().some(grant => grant.mountPoint === logical), true);
        const next = await newContext();
        const refused = await run('cat marker', {}, next);
        assert.equal(refused.error?.code, 'ERR_WORKSPACE_DRAIN');
        const physical = await run('cat marker', { cwd: config.physical, root: config.physical }, next);
        success(physical, 'PHYSICAL\n');
        await next.fiber.dispose(); contexts.delete(next);
        await assert.rejects(ctx.subprocess.backend.dispose(), { code: 'ERR_WORKSPACE_DRAIN' });
        // Cordis logs cleanup errors; the provider's disposal promise is the
        // authoritative failure observation, not the framework's aggregate.
        await ctx.fiber.dispose(); contexts.delete(ctx);
      });
    } else {
      await check('public factory preserves app-private physical positive control', async () => {
        success(await run('cat marker', { cwd: config.physical, root: config.physical }), 'PHYSICAL\n');
      });
      await check('ETS pathThrow published object reaches actual public shell Worker and returns marker', async () => {
        success(await run('cat marker'), 'GRANT\n');
      });
      await check('nested cwd preserves exact original grant scope', async () => {
        success(await run('cat nested; cat ../marker', { cwd: logical + '/sub' }), 'NESTED\nGRANT\n');
      });
      await check('workspace-write performs actual create/append/rename/remove within chosen object', async () => {
        success(await run('printf A > written; printf B >> written; mkdir child; mv written child/moved; cat child/moved; rm child/moved; rmdir child', { mode: 'workspace-write' }), 'AB');
        assert.deepEqual((await fs.readdir(selectedPath)).sort(), ['marker', 'sub']);
      });
      await check('read-only task cannot change actual chosen bytes', async () => {
        const result = await run('printf BAD > marker');
        assert(result.error?.code === 'EACCES' || (result.outcome && result.outcome.exitCode !== 0));
        assert.equal(await fs.readFile(join(selectedPath, 'marker'), 'utf8'), 'GRANT\n'); assert.equal(status().leases, 0);
      });
      await check('narrower policy and unprepared logical cwd do not expand authority', async () => {
        assert.throws(() => ctx.subprocess.prepare(['bash', '-c', 'true'], { mode: 'read-only', workspaceRoot: logical + '/sub' }), { code: 'ERR_WORKSPACE_SCOPE_UNSUPPORTED' });
        const child = startPrepared(ctx, ['bash', '-c', 'cat marker']);
        assert.equal((await child.completed).error?.code, 'ERR_WORKSPACE_CONFINEMENT_REQUIRED');
        assert.equal(status().leases, 0);
      });
      await check('cwd outside the one selected root is rejected without a lease', async () => {
        const result = await run('cat marker', { cwd: config.physical });
        assert.equal(result.error?.code, 'EACCES'); assert.equal(status().leases, 0);
      });
      await check('Node scripts and owned-git do not fall back to host paths for grants', async () => {
        for (const command of ['node', 'git']) {
          const result = await run('', { argv: [command, '--version'] });
          assert.equal(result.error?.code, 'ERR_WORKSPACE_SCOPE_UNSUPPORTED');
          const nested = await run(command + ' --version');
          assert.equal(nested.outcome.exitCode, 126); assert.match(nested.stderr.toString('utf8'), /ERR_WORKSPACE_SCOPE_UNSUPPORTED/);
        }
        assert.equal(status().leases, 0);
      });
      await check('late env/loader/binding replacement cannot redirect captured authority or Worker native path', async () => {
        const loader = require('@dsh-go/ohos-native'); const originalLoad = loader.load;
        const binding = originalLoad('workspace-grants').binding;
        const oldSnapshot = binding.snapshot, oldIssue = binding.issue, oldDirectory = process.env.DSH_GO_OHOS_NATIVE_LIBRARY_DIR;
        try {
          binding.snapshot = () => []; binding.issue = () => { throw Error('late replacement'); };
          loader.load = () => { throw Error('late loader replacement'); };
          process.env.DSH_GO_OHOS_NATIVE_LIBRARY_DIR = '/fixture-not-native';
          assert.equal(borrowProcessGrantAuthority().snapshot().some(grant => grant.mountPoint === logical), true);
          success(await run('cat marker', { env: { DSH_GO_OHOS_NATIVE_LIBRARY_DIR: '/caller-not-native' } }), 'GRANT\n');
        } finally {
          binding.snapshot = oldSnapshot; binding.issue = oldIssue; loader.load = originalLoad;
          process.env.DSH_GO_OHOS_NATIVE_LIBRARY_DIR = oldDirectory;
        }
      });
      await check('actual other N-API Worker cannot snapshot/issue/rebind the main owner', async () => {
        const worker = new Worker(new URL('./workspace-authority-owner-probe.mjs', import.meta.url), {
          workerData: { dshOhosVirtualProcess: { protocol: 1 } },
        });
        const exited = once(worker, 'exit'), message = once(worker, 'message');
        const [value] = await message; assert.equal((await exited)[0], 0);
        assert.deepEqual(value, { snapshot: 'ERR_WORKSPACE_OWNER', issue: 'ERR_WORKSPACE_OWNER',
          bind: 'ERR_WORKSPACE_OWNER_ALREADY_BOUND', consumeUnknown: 'ERR_WORKSPACE_TICKET' });
      });
      await check('non-directory Worker initialization failure still retires native task lease', async () => {
        const result = await run('true', { cwd: logical + '/marker' });
        assert.equal(result.error?.code, 'ENOTDIR'); assert.equal(result.exitError, undefined); assert.equal(status().leases, 0);
      });
      await check('ordinary runtime dispose cannot close process authority used by another real Worker', async () => {
        const other = await newContext();
        const running = start(ctx, 'printf ACTIVE; sleep 30');
        await until(() => status().leases === 1 && running.stdout() === 'ACTIVE');
        const second = await run('cat marker', {}, other);
        assert.equal(second.outcome.exitCode, 0); assert.equal(second.stdout.toString('utf8'), 'GRANT\n');
        assert.equal(status().leases, 1); await other.fiber.dispose(); contexts.delete(other); assert.equal(status().leases, 1);
        running.child.terminate(); const ended = await running.completed;
        assert.equal(ended.outcome.signal, 'SIGTERM'); assert.equal(ended.stdout.toString('utf8'), 'ACTIVE');
        assert.equal(ended.exitError, undefined); assert.equal(status().leases, 0);
        const replacement = await newContext(); success(await run('cat marker', {}, replacement), 'GRANT\n');
        await replacement.fiber.dispose(); contexts.delete(replacement);
      });
      await check('queued cancellation creates no native ticket and cannot start after its finish barrier', async () => {
        const first = start(ctx, 'printf HOLD; sleep 30');
        await until(() => status().leases === 1 && first.stdout() === 'HOLD');
        const queued = start(ctx, 'printf BAD > marker', { mode: 'workspace-write' }); queued.child.terminate();
        const cancelled = await queued.completed; assert.equal(cancelled.outcome.signal, 'SIGTERM'); assert.equal(status().leases, 1);
        first.child.terminate(); await first.completed; assert.equal(status().leases, 0);
        success(await run('cat marker'), 'GRANT\n');
      });
      await check('real grant revocation invalidates prepared old generation; explicit reattach creates fresh scope', async () => {
        const prepared = ctx.subprocess.prepare(['bash', '-c', 'cat marker'], { mode: 'read-only', workspaceRoot: logical });
        f.background(); assert.equal(status().active, false);
        const result = await startPrepared(ctx, prepared).completed; assert(result.error); assert.equal(status().leases, 0);
        f.foreground();
        assert.equal((await f.call(f, 'attach', { id, userGesture: true }).done).error, 'reauthorize');
        const oldCount = f.pickers.length, reselect = f.call(f, 'select', { userGesture: true });
        await until(() => f.pickers.length > oldCount); f.select([uri]);
        assert.equal((await reselect.done).error, undefined);
        const attachedAgain = await f.call(f, 'attach', { id, userGesture: true }).done;
        assert.equal(attachedAgain.error, undefined); const old = row.nativeGeneration; row = attachedAgain.value.workspaces[0];
        assert(row.nativeGeneration > old); success(await run('cat marker'), 'GRANT\n');
      });
      await check('renaming chosen root retains its object and does not acquire replacement path', async () => {
        const moved = selectedPath + '-moved'; await fs.rename(selectedPath, moved);
        await fs.mkdir(selectedPath); await fs.writeFile(join(selectedPath, 'marker'), 'REPLACEMENT\n');
        success(await run('cat marker'), 'GRANT\n'); selectedPath = moved;
      });
    }
  } catch (error) {
    report.setupError = { code: error.code ?? null, message: error.message, stack: error.stack };
  } finally {
    for (const context of contexts) {
      try { await context.fiber.dispose(); }
      catch (error) { report.cleanupError ??= { code: error.code ?? null, message: error.message }; }
    }
    try {
      f?.background();
      if (row) { report.nativeRetired = status(); assert.equal(report.nativeRetired.leases, 0); assert.equal(report.nativeRetired.drained, true); }
    } catch (error) { report.cleanupError ??= { code: error.code ?? null, message: error.message }; }
    for (const cleanup of cleanups.reverse()) {
      try { await cleanup(); } catch (error) { report.cleanupError ??= { code: error.code ?? null, message: error.message }; }
    }
    report.pass = !report.setupError && !report.cleanupError && report.cases.length > 0 && report.cases.every(row => row.pass);
    report.ended = new Date().toISOString();
    await fs.writeFile(config.result, JSON.stringify(report, null, 2) + '\n');
  }
}
