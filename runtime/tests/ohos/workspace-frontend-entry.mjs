// Frontend observer, imported after the sole product preload and before the real
// DSH bin. No product method, ticket issuer, or positive shell Worker is replaced.
import { isMainThread } from 'node:worker_threads';
if (isMainThread) {
  const assert = (await import('node:assert/strict')).default;
  const fs = await import('node:fs/promises');
  const { join } = await import('node:path');
  const { pathToFileURL } = await import('node:url');
  const { createRequire } = await import('node:module');
  const config = JSON.parse(await fs.readFile(process.env.OHOS_933_CONFIG, 'utf8'));
  const report = {
    scope: 'Explicit payload: real DSH bin/sole product preload/ETS FD/public shell factory; controlled SDK, storage unit, session projection and prompt seams. Composition provenance is supplied by the caller; not complete chat, SDK or device.',
    plannedCases: 9, cases: [], started: new Date().toISOString(),
  };
  const contexts = new Set(), cleanups = [], successful = new Set();
  let f, row, logicalRoot, chosen, physicalContext, logicalContext, logicalSession, logicalWorkspace, beforeRevocation;
  let sequence = 0;
  const errorRecord = error => ({ name: error?.name ?? 'Error', code: error?.code ?? null,
    reason: error?.reason ?? null, message: String(error?.message ?? error), stack: error?.stack ?? null });
  const check = async (name, action, dependencies = []) => {
    const absent = dependencies.filter(value => !successful.has(value));
    if (absent.length) { report.cases.push({ name, status: 'BLOCKED', pass: false, dependencies: absent }); return; }
    const start = performance.now();
    try {
      const evidence = await action(); successful.add(name);
      report.cases.push({ name, status: 'PASS', pass: true, milliseconds: performance.now() - start, evidence: evidence ?? null });
    } catch (error) {
      report.cases.push({ name, status: 'BEHAVIOR_RED', pass: false,
        milliseconds: performance.now() - start, error: errorRecord(error) });
    }
  };
  const nativeStatus = () => f.native.workspaceGrant('status', row.nativeKey, row.nativeGeneration);
  const noHostDirectory = async path => {
    try { await fs.lstat(path); }
    catch (error) { if (error.code === 'ENOENT') return; throw error; }
    assert.fail('logical grant root unexpectedly exists as a host directory');
  };
  const closeContext = async state => {
    if (state.closed) return;
    const errors = [];
    for (const action of [
      async () => { if (state.ctx.get('subprocess')) await state.ctx.subprocess.backend.dispose(); },
      async () => { if (state.registryPlugin) await state.registryPlugin.dispose(); },
      async () => { if (state.facility) await state.facility.closeAll(); },
      async () => state.ctx.fiber.dispose(),
    ]) { try { await action(); } catch (error) { errors.push(error); } }
    state.closed = true; contexts.delete(state);
    if (errors.length) throw new AggregateError(errors, 'research context cleanup failed');
  };
  try {
    const require = createRequire(join(config.payload, 'package.json'));
    const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
    const [{ Context }, { DomainFacility }, { WorkspaceRegistry }, { LocalFileSystem }, { WorkingDirectoryService }] =
      await Promise.all(['cordis', 'dsh-storage-domain', 'dsh-workspace', 'dsh-fs-local', 'dsh-working-directory'].map(load));
    const { default: OhSubprocessRuntime } = await import(pathToFileURL(join(config.payload, 'runtime/ohos/process/index.mjs')));
    const { workspaceFixture, until } = await import(pathToFileURL(join(config.source, 'runtime/tests/ohos/authorized-workspaces-fixture.mjs')));
    assert.equal(process.argv[1], join(config.payload, 'node_modules/@deepseek-ai/dsh/lib/bin.js'));
    assert.equal(process.platform, 'openharmony');
    report.productPreloadReturned = true;
    for (const name of ['physical', 'temporary']) await fs.mkdir(config[name], { recursive: true, mode: 0o700 });
    await fs.writeFile(join(config.physical, 'marker'), '933-PHYSICAL-ROOT\n', { flag: 'wx', mode: 0o600 });
    await fs.mkdir(join(config.physical, 'sub'));
    await fs.writeFile(join(config.physical, 'sub/nested'), '933-PHYSICAL-SUB\n', { flag: 'wx', mode: 0o600 });

    f = await workspaceFixture({ after: fn => cleanups.push(fn) }, { pathThrow: true });
    const uri = 'file://docs/storage/Users/currentUser/Projects/933-frontend-fixture';
    const pending = f.call(f, 'select', { userGesture: true });
    await until(() => f.pickers.length === 1); f.select([uri]);
    const selection = await pending.done; assert.equal(selection.error, undefined);
    const id = selection.value.workspaces[0].id;
    const attach = await f.call(f, 'attach', { id, userGesture: true }).done;
    assert.equal(attach.error, undefined); row = attach.value.workspaces[0];
    assert.equal(row.nativeGrant, 'ready'); assert.equal(row.candidatePath, null); assert.equal(f.fds.size, 0);
    assert.equal(nativeStatus().active, true); assert.equal(nativeStatus().leases, 0);
    logicalRoot = '/workspaces/' + id; chosen = f.uriPaths.get(uri);
    await noHostDirectory(logicalRoot);
    await fs.writeFile(join(chosen, 'marker'), '933-LOGICAL-ROOT\n', { flag: 'wx', mode: 0o600 });
    await fs.mkdir(join(chosen, 'sub'));
    await fs.writeFile(join(chosen, 'sub/nested'), '933-LOGICAL-SUB\n', { flag: 'wx', mode: 0o600 });
    const selectedIdentity = await fs.stat(chosen);
    report.publication = { logicalRoot, nativeGrant: row.nativeGrant, candidatePath: row.candidatePath,
      borrowedFDs: f.fds.size, generation: row.nativeGeneration,
      selectedDirectory: { dev: selectedIdentity.dev, ino: selectedIdentity.ino, mode: selectedIdentity.mode } };

    const createSession = (state, cwd) => {
      const id = '933-fixture-session-' + (++sequence), events = [];
      const session = { id, header: Object.freeze({ version: 4, id, createdAt: Date.now(), isSeeded: false, cwd }), events,
        append(type, data) { events.push({ type, data: structuredClone(data) }); } };
      state.sessions.set(id, session); return session;
    };
    const makeAgent = (state, session) => {
      const notices = [];
      return { id: session.id, session, ctx: state.ctx, notices, inject(message) { notices.push(message); } };
    };
    const makeContext = async (label, medium = { global: null, tables: { workspaces: {} } }, sessions = new Map()) => {
      const ctx = new Context();
      const state = { ctx, label, medium, sessions, writes: [], closed: false }; contexts.add(state);
      ctx.provide('sessions', { list: () => [...sessions.values()], get: id => sessions.get(id) });
      ctx.provide('sessionPersistence', { list: async () => [...sessions.values()].map(session => ({ header: structuredClone(session.header) })) });
      // Only the storage unit is controlled. DomainFacility validation, write
      // ordering and WorkspaceRegistry operations are their actual modules.
      ctx.provide('storage', { backend: { get: () => ({ kv: { open: async () => ({
        loadAll: async () => structuredClone(medium), close: async () => {},
        setGlobal: async value => { medium.global = structuredClone(value); state.writes.push('global'); },
        putRecord: async (table, id, value) => { medium.tables[table][id] = structuredClone(value); state.writes.push('put'); },
        deleteRecord: async (table, id) => { delete medium.tables[table][id]; state.writes.push('delete'); },
      }) } }) } });
      state.facility = new DomainFacility(ctx, { backend: 'controlled-storage-unit' });
      ctx.provide('storageDomain', state.facility);
      // Controlled projection replay invokes the actual definition registered
      // by WorkingDirectoryService; it is not the production Session registry.
      ctx.provide('sessionProjections', { async register(definition) {
        return { stateOf(session) {
          let value = definition.init(session.header);
          for (const event of session.events) value = definition.apply(value, event);
          return definition.stateSchema.parse(value);
        } };
      } });
      ctx.provide('systemPrompt', { context() {}, getContextOrder() { return 1; } });
      state.registryPlugin = ctx.plugin(WorkspaceRegistry); await state.registryPlugin.await();
      await ctx.plugin(LocalFileSystem, { cwd: config.physical, diffBasisMaxBytes: 10 * 1024 * 1024 }).await();
      await ctx.plugin(WorkingDirectoryService, { defaultDirectory: config.physical }).await();
      await ctx.plugin(OhSubprocessRuntime, { workspaceRoots: [config.physical], temporaryRoot: config.temporary }).await();
      return state;
    };
    const streamCapture = stream => {
      const chunks = [];
      const done = new Promise((resolve, reject) => {
        stream.on('data', bytes => chunks.push(Buffer.from(bytes)));
        stream.once('end', resolve); stream.once('error', reject);
      });
      done.catch(() => {});
      return { done, value: () => Buffer.concat(chunks).toString('utf8') };
    };
    const shellAfterEnsure = async (state, agent, script, expected) => {
      const cwd = await state.ctx.workingDirectory.ensure(agent);
      // The only request token is produced by the public product factory.
      // No native issue/consume call or alternate positive Worker exists here.
      const argv = state.ctx.subprocess.prepare(['bash', '-c', script],
        { mode: 'read-only', workspaceRoot: agent.session.header.cwd });
      const child = state.ctx.subprocess.spawn({ argv, cwd, env: {}, graceMs: 200,
        stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' } });
      const stdout = streamCapture(child.stdout), stderr = streamCapture(child.stderr);
      const settled = await Promise.allSettled([child.done, child.waitForExit(), stdout.done, stderr.done]);
      const errors = settled.filter(value => value.status === 'rejected').map(value => value.reason);
      if (errors.length) throw new AggregateError(errors, 'public shell/exit/stream barrier failed');
      const outcome = settled[0].value;
      assert.equal(settled[1].value, true); assert.equal(outcome.exitCode, 0); assert.equal(outcome.signal, null);
      assert.equal(stdout.value(), expected); assert.equal(stderr.value(), '');
      assert.equal(nativeStatus().leases, 0);
      return { cwd, outcome, stdout: stdout.value(), stderr: stderr.value(), realExit: true, streamsEnded: true, nativeLeases: 0 };
    };
    const noticeText = agent => agent.notices.flatMap(value => value.content ?? []).filter(value => value.type === 'text').map(value => value.text).join('\n');

    physicalContext = await makeContext('physical');
    await check('physical-registry-default-create-status', async () => {
      let resolutions = 0;
      const workspace = await physicalContext.ctx.workspaceRegistry.initializeDefault(async () => { resolutions++; return config.physical; });
      const same = await physicalContext.ctx.workspaceRegistry.create(config.physical, 'must not replace default title');
      assert.equal(same.id, workspace.id); assert.equal(workspace.path, await fs.realpath(config.physical));
      assert.equal(await workspace.status(), 'ok'); assert.equal(physicalContext.medium.global.defaultWorkspaceId, workspace.id);
      assert.equal((await physicalContext.ctx.workspaceRegistry.initializeDefault(async () => { resolutions++; throw Error('default resolver unexpectedly repeated'); })).id, workspace.id);
      assert.equal(resolutions, 1); physicalContext.workspace = workspace;
      return { id: workspace.id, path: workspace.path, status: 'ok', records: Object.keys(physicalContext.medium.tables.workspaces).length };
    });
    await check('physical-working-directory-relative-recovery-and-public-shell', async () => {
      const session = createSession(physicalContext, config.physical), agent = makeAgent(physicalContext, session);
      await physicalContext.workspace.attachSession(session.id);
      assert.equal(await physicalContext.ctx.workingDirectory.ensure(agent), config.physical);
      await physicalContext.ctx.workingDirectory.set(agent, 'sub');
      const nested = await shellAfterEnsure(physicalContext, agent, 'cat nested; cat ../marker', '933-PHYSICAL-SUB\n933-PHYSICAL-ROOT\n');
      await fs.rm(join(config.physical, 'sub'), { recursive: true });
      assert.equal(await physicalContext.ctx.workingDirectory.ensure(agent), config.physical);
      assert.match(noticeText(agent), /unavailable/);
      const root = await shellAfterEnsure(physicalContext, agent, 'cat marker', '933-PHYSICAL-ROOT\n');
      physicalContext.agent = agent; return { nested, root, originalCwd: session.header.cwd };
    }, ['physical-registry-default-create-status']);

    logicalContext = await makeContext('logical');
    await check('logical-registry-default-create-status-without-host-directory', async () => {
      // Probe real create first in a separate empty registry. On the old host-
      // realpath implementation it rejects before default can attempt mkdir.
      const probe = await makeContext('logical-create-probe');
      const directlyCreated = await probe.ctx.workspaceRegistry.create(logicalRoot, '933 logical create probe');
      assert.equal(directlyCreated.path, logicalRoot); assert.equal(await directlyCreated.status(), 'ok');
      await closeContext(probe);
      let resolutions = 0;
      logicalWorkspace = await logicalContext.ctx.workspaceRegistry.initializeDefault(async () => { resolutions++; return logicalRoot; });
      const same = await logicalContext.ctx.workspaceRegistry.create(logicalRoot, 'must not replace default title');
      assert.equal(same.id, logicalWorkspace.id); assert.equal(same.path, logicalRoot);
      assert.equal(await same.status(), 'ok'); assert.equal(logicalContext.medium.global.defaultWorkspaceId, same.id);
      assert.equal((await logicalContext.ctx.workspaceRegistry.initializeDefault(async () => { resolutions++; return config.physical; })).id, same.id);
      assert.equal(resolutions, 1); await noHostDirectory(logicalRoot);
      assert.equal(nativeStatus().leases, 0);
      return { id: same.id, path: same.path, status: 'ok', nativeLeases: 0, hostDirectoryAbsent: true };
    });
    await check('logical-history-ensure-and-public-shell-marker', async () => {
      logicalSession = createSession(logicalContext, logicalRoot);
      const agent = makeAgent(logicalContext, logicalSession); logicalContext.agent = agent;
      await logicalWorkspace.attachSession(logicalSession.id);
      assert.deepEqual(logicalWorkspace.sessionIds, [logicalSession.id]);
      assert.equal(await logicalContext.ctx.workingDirectory.ensure(agent), logicalRoot);
      const shell = await shellAfterEnsure(logicalContext, agent, 'cat marker', '933-LOGICAL-ROOT\n');
      return { shell, sessionId: logicalSession.id, originalCwd: logicalSession.header.cwd,
        persistedSessionIds: logicalContext.medium.tables.workspaces[logicalWorkspace.id].sessionIds };
    }, ['logical-registry-default-create-status-without-host-directory']);
    await check('logical-relative-subdirectory-preserves-original-root', async () => {
      const agent = logicalContext.agent;
      await logicalContext.ctx.workingDirectory.set(agent, 'sub');
      assert.equal(logicalContext.ctx.workingDirectory.get(logicalSession), logicalRoot + '/sub');
      assert.equal(logicalSession.header.cwd, logicalRoot);
      return await shellAfterEnsure(logicalContext, agent, 'cat nested; cat ../marker', '933-LOGICAL-SUB\n933-LOGICAL-ROOT\n');
    }, ['logical-history-ensure-and-public-shell-marker']);
    await check('removed-logical-subdirectory-recovers-original-logical-root', async () => {
      const agent = logicalContext.agent, noticeCount = agent.notices.length;
      await fs.rm(join(chosen, 'sub'), { recursive: true });
      assert.equal(await logicalContext.ctx.workingDirectory.ensure(agent), logicalRoot);
      assert.equal(logicalContext.ctx.workingDirectory.get(logicalSession), logicalRoot);
      assert.equal(logicalSession.header.cwd, logicalRoot); assert.notEqual(logicalRoot, config.physical);
      assert.equal(agent.notices.length, noticeCount + 1); assert.match(noticeText(agent), /unavailable/);
      assert.deepEqual(logicalSession.events.at(-1), { type: 'working-directory/change', data: { cwd: logicalRoot } });
      const shell = await shellAfterEnsure(logicalContext, agent, 'cat marker', '933-LOGICAL-ROOT\n');
      assert.deepEqual(logicalWorkspace.sessionIds, [logicalSession.id]); return { shell, recoveredNotice: true };
    }, ['logical-relative-subdirectory-preserves-original-root']);
    await check('revocation-requires-reselection-without-private-directory-fallback', async () => {
      const agent = logicalContext.agent;
      beforeRevocation = { medium: structuredClone(logicalContext.medium), cwd: logicalContext.ctx.workingDirectory.get(logicalSession),
        events: structuredClone(logicalSession.events), notices: agent.notices.length };
      f.background(); assert.equal(nativeStatus().active, false); assert.equal(nativeStatus().leases, 0);
      assert.equal(await logicalWorkspace.status(), 'missing-dir');
      let error; try { await logicalContext.ctx.workingDirectory.ensure(agent); } catch (value) { error = value; }
      assert(error, 'revoked grant must not succeed through a private fallback');
      assert.equal(error.code, 'ENOENT'); assert.equal(error.reason, 'ERR_WORKSPACE_REAUTHORIZATION_REQUIRED');
      assert.match(error.message, /系统选择器.*重新选择|重新选择.*文件夹/);
      assert.equal(logicalContext.ctx.workingDirectory.get(logicalSession), beforeRevocation.cwd);
      assert.deepEqual(logicalSession.events, beforeRevocation.events); assert.equal(agent.notices.length, beforeRevocation.notices);
      assert.deepEqual(logicalContext.medium, beforeRevocation.medium);
      assert.deepEqual(logicalWorkspace.sessionIds, [logicalSession.id]);
      assert.equal(await fs.readFile(join(config.physical, 'marker'), 'utf8'), '933-PHYSICAL-ROOT\n');
      assert.equal(nativeStatus().leases, 0);
      return { error: { code: error.code, reason: error.reason, message: error.message },
        unchangedCurrentCwd: beforeRevocation.cwd, unchangedHistory: true, nativeLeases: 0 };
    }, ['logical-history-ensure-and-public-shell-marker']);
    await check('registry-reopen-retains-unavailable-history-and-default-identity', async () => {
      assert(beforeRevocation, 'revocation must have begun before this check');
      const medium = logicalContext.medium, sessions = logicalContext.sessions, workspaceId = logicalWorkspace.id;
      await closeContext(logicalContext);
      const reopened = await makeContext('reopened-after-revocation', medium, sessions);
      logicalContext = reopened;
      const workspace = reopened.ctx.workspaceRegistry.get(workspaceId); assert(workspace);
      assert.equal(workspace.path, logicalRoot); assert.equal(await workspace.status(), 'missing-dir');
      assert.deepEqual(workspace.sessionIds, [logicalSession.id]);
      assert.deepEqual(medium.tables.workspaces[workspaceId].sessionIds, [logicalSession.id]);
      let resolved = false;
      const same = await reopened.ctx.workspaceRegistry.initializeDefault(async () => { resolved = true; return config.physical; });
      assert.equal(same.id, workspaceId); assert.equal(resolved, false);
      assert.deepEqual(medium, beforeRevocation.medium);
      const agent = makeAgent(reopened, logicalSession);
      await assert.rejects(reopened.ctx.workingDirectory.ensure(agent), error =>
        error.code === 'ENOENT' && error.reason === 'ERR_WORKSPACE_REAUTHORIZATION_REQUIRED' && /重新选择/.test(error.message));
      assert.equal(reopened.ctx.workingDirectory.get(logicalSession), beforeRevocation.cwd);
      assert.deepEqual(logicalSession.events, beforeRevocation.events); assert.equal(nativeStatus().leases, 0);
      return { workspaceId, path: workspace.path, sessionIds: workspace.sessionIds, status: 'missing-dir',
        defaultUnchanged: true, controlledStorageUnchanged: true, scope: 'Cordis/domain reopen, not App restart or durable storage proof' };
    }, ['revocation-requires-reselection-without-private-directory-fallback']);
    await check('ordinary-physical-public-shell-remains-available-after-grant-revocation', async () => {
      assert.equal(nativeStatus().active, false, 'the grant must actually be revoked before this after-revocation check');
      return await shellAfterEnsure(physicalContext, physicalContext.agent, 'cat marker', '933-PHYSICAL-ROOT\n');
    }, ['physical-working-directory-relative-recovery-and-public-shell', 'revocation-requires-reselection-without-private-directory-fallback']);
  } catch (error) {
    report.setupError = errorRecord(error);
  } finally {
    report.cleanupErrors = [];
    for (const state of [...contexts].reverse()) {
      try { await closeContext(state); } catch (error) { report.cleanupErrors.push(errorRecord(error)); }
    }
    try {
      f?.background();
      if (row) {
        report.finalNative = nativeStatus();
        assert.equal(report.finalNative.active, false); assert.equal(report.finalNative.leases, 0); assert.equal(report.finalNative.drained, true);
      }
    } catch (error) { report.cleanupErrors.push(errorRecord(error)); }
    for (const cleanup of cleanups.reverse()) {
      try { await cleanup(); } catch (error) { report.cleanupErrors.push(errorRecord(error)); }
    }
    report.pass = !report.setupError && report.cleanupErrors.length === 0 && report.cases.length === report.plannedCases && report.cases.every(value => value.pass);
    report.finished = new Date().toISOString();
    await fs.writeFile(config.result, JSON.stringify(report, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  }
}
