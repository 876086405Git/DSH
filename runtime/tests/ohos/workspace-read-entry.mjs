// Three ordinary owned-file reads through the actual default tool pipeline.
// SDK chooser/Preferences and the in-memory Agent carrier are explicit fixtures.
import { isMainThread } from 'node:worker_threads';

if (isMainThread) {
  const assert = (await import('node:assert/strict')).default;
  const fs = await import('node:fs/promises');
  const { join } = await import('node:path');
  const { createRequire } = await import('node:module');
  const { pathToFileURL } = await import('node:url');
  const { createHash } = await import('node:crypto');
  const { observeProviderReads } = await import('./workspace-read-instrumentation.mjs');
  const config = JSON.parse(await fs.readFile(process.env.OHOS_936_READ_CONFIG, 'utf8'));
  const names = ['physical-default-whole', 'selected-logical-default-whole', 'selected-logical-small-stream'];
  const report = {
    schema: 1,
    scope: 'Actual DSH bin and sole product preload; actual default read, ToolRuntime, NativeToolExecutor, SandboxedFileSystem, read-only policy, Session and WorkingDirectory. Explicit SDK chooser/Preferences doubles and in-memory Agent carrier. Not a full Web Host, chat, persistent Session, SDK or device test.',
    started: new Date().toISOString(),
    cases: names.map(name => ({ name, status: 'BLOCKED', pass: false, batchReturned: false })),
    observations: [], modules: [], cleanupErrors: [],
  };
  const errorInfo = error => ({ name: error?.name ?? null, code: error?.code ?? null,
    message: error?.message ?? String(error), stack: error?.stack ?? null });
  const require = createRequire(join(config.payload, 'package.json'));
  const load = async name => {
    const path = require.resolve('@deepseek-ai/' + name);
    report.modules.push({ name, path });
    return import(pathToFileURL(path));
  };
  const cleanups = [];
  let f, row, observer, logicalMarker, physicalMarker;
  const nativeStatus = () => f.native.workspaceGrant('status', row.nativeKey, row.nativeGeneration);
  const ownedMarker = async path => {
    const bytes = await fs.readFile(path), info = await fs.stat(path);
    assert.equal(info.isFile(), true);
    return { bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex'),
      dev: info.dev, ino: info.ino, mode: info.mode & 0o777 };
  };
  const hostRoot = async () => {
    try {
      const info = await fs.lstat('/workspaces');
      return { exists: true, directory: info.isDirectory(), dev: info.dev, ino: info.ino };
    } catch (error) { if (error.code === 'ENOENT') return { exists: false }; throw error; }
  };
  let stage = 'setup';
  try {
    assert.equal(process.argv[1], join(config.payload, 'node_modules/@deepseek-ai/dsh/lib/bin.js'));
    assert.equal(process.platform, 'openharmony');
    report.hostWorkspacesBefore = await hostRoot();
    assert.equal(typeof globalThis[Symbol.for('dsh.go.ohos.workspace-paths')]?.directory, 'function');
    const [{ Context }, { Session }, { SystemPrompt }, { SessionProjectionRegistry },
      { SandboxPolicyService }, { SandboxedFileSystem }, { LocalFileSystem },
      { WorkingDirectoryService }, { ToolRuntime }, native, fsTools] = await Promise.all([
        'cordis', 'dsh-session', 'dsh-system-prompt', 'dsh-session-projection',
        'dsh-sandbox-policy', 'dsh-fs-sandbox', 'dsh-fs-local',
        'dsh-working-directory', 'dsh-tools', 'dsh-tool-executor-native', 'dsh-tool-fs',
      ].map(load));
    observer = observeProviderReads(LocalFileSystem);
    await fs.mkdir(config.physical, { recursive: true, mode: 0o700 });
    physicalMarker = join(config.physical, 'marker');
    await fs.writeFile(physicalMarker, 'PHYSICAL\n', { flag: 'wx', mode: 0o600 });
    report.physicalMarkerBefore = await ownedMarker(physicalMarker);

    async function run(entry, { directory, marker, expected, stream = false, logical = false }) {
      let ctx, caseStage = 'setup';
      const started = performance.now();
      Object.assign(entry, { status: 'SETUP_ERROR', started: new Date().toISOString(),
        toolConfig: stream ? { readStreamMinSize: 1 } : {},
        expectedProviderMethod: stream ? 'streamText' : 'readText',
        arguments: { file_path: 'marker' }, cleanupErrors: [], behaviorErrors: [] });
      let callMark;
      try {
        ctx = new Context();
        await ctx.plugin(SystemPrompt, {});
        await ctx.plugin(SessionProjectionRegistry);
        await ctx.plugin(SandboxPolicyService, { mode: 'read-only', workspaceRoot: directory });
        await ctx.plugin(SandboxedFileSystem, { cwd: directory });
        await ctx.plugin(WorkingDirectoryService, { defaultDirectory: directory });
        await ctx.plugin(ToolRuntime, {});
        await ctx.plugin(native);
        await ctx.plugin(fsTools, entry.toolConfig);
        entry.services = { fs: ctx.fs.constructor.name, policy: ctx.sandboxPolicy.constructor.name,
          executor: ctx.tools.selectExecutor().constructor.name, tools: ctx.tools.constructor.name,
          directory: ctx.workingDirectory.constructor.name,
          projections: ctx.sessionProjections.constructor.name, mode: ctx.fs.sandboxMode };
        assert.equal(entry.services.fs, 'SandboxedFileSystem');
        assert.equal(entry.services.executor, 'NativeToolExecutor');
        assert.equal(entry.services.mode, 'read-only');
        assert(ctx.tools.definitions().some(tool => tool.name === 'read'));
        ctx.on('fs/observed', (target, observed, execution) => report.observations.push({
          target: { displayPath: target.displayPath, targetKey: String(target.targetKey) },
          observed, callId: execution.callId,
        }));
        const id = '936-' + entry.name;
        const session = Session.create(id, undefined, {
          version: 4, id, createdAt: Date.now(), isSeeded: false, cwd: directory,
        });
        session.append('turn/start', { turn: 1 });
        const notices = [];
        const agent = { id, session, ctx, inject: notice => notices.push(notice) };
        entry.session = { type: session.constructor.name, id, headerCwd: session.header.cwd };
        entry.notices = notices;
        entry.markerBefore = await ownedMarker(marker);
        caseStage = 'working-directory';
        entry.workingDirectoryBefore = ctx.workingDirectory.get(session);
        entry.ensure = await ctx.workingDirectory.ensure(agent, new AbortController().signal);
        assert.equal(entry.ensure, directory);
        entry.policy = ctx.sandboxPolicy.resolve({ session });
        assert.equal(entry.policy.mode, 'read-only');
        assert.equal(entry.policy.workspaceRoot, directory);
        if (logical) {
          entry.nativeBefore = nativeStatus();
          assert.equal(entry.nativeBefore.active, true);
          assert.equal(entry.nativeBefore.leases, 0);
        }
        const callId = '936-read-' + entry.name;
        callMark = observer.mark();
        caseStage = 'execute';
        entry.batch = await ctx.tools.execute({ agent,
          calls: [{ id: callId, name: 'read', arguments: JSON.stringify(entry.arguments) }],
          signal: new AbortController().signal });
        entry.batchReturned = true;
        entry.providerCalls = observer.since(callMark);
        entry.bodyReached = entry.providerCalls.length > 0;
        entry.workingDirectoryAfter = ctx.workingDirectory.get(session);
        caseStage = 'assert-batch';
        try {
          assert.equal(entry.batch.results.length, 1);
          assert.equal(entry.batch.results[0].callId, callId);
          const result = entry.batch.results[0].result;
          const path = join(directory, 'marker');
          const outcome = { path, offset: 1, lines: [{ number: 1, text: expected }], totalLines: 1 };
          assert.equal(result.isError, false);
          assert.deepEqual(result.meta, outcome);
          assert.deepEqual(result.value, outcome);
          assert.deepEqual(result.content, [{ type: 'text', text:
            `<path>${path}</path>\n<type>file</type>\n<content>\n1: ${expected}\n\n(End of file - total 1 lines)\n</content>` }]);
          assert.equal(entry.workingDirectoryAfter, directory);
          assert.deepEqual(entry.providerCalls, [{ method: entry.expectedProviderMethod,
            targetKey: path, displayPath: path }]);
          const observations = report.observations.filter(value => value.callId === callId);
          assert.equal(observations.length, 1);
          assert.deepEqual(observations[0].target, { displayPath: path, targetKey: path });
          assert.equal(observations[0].observed.kind, 'present');
          assert.equal(typeof observations[0].observed.version, 'string');
          assert.notEqual(observations[0].observed.version, '');
        } catch (error) { entry.behaviorErrors.push(errorInfo(error)); }
      } catch (error) {
        entry[caseStage === 'setup' || caseStage === 'working-directory' ? 'setupError' : 'unexpectedError'] =
          { stage: caseStage, ...errorInfo(error) };
      } finally {
        if (callMark !== undefined && !entry.providerCalls) entry.providerCalls = observer.since(callMark);
        if (entry.providerCalls) entry.bodyReached = entry.providerCalls.length > 0;
        try {
          entry.markerAfter = await ownedMarker(marker);
          entry.markerUnchanged = JSON.stringify(entry.markerAfter) === JSON.stringify(entry.markerBefore);
          if (entry.markerBefore) assert.equal(entry.markerUnchanged, true);
        } catch (error) { entry.cleanupErrors.push({ stage: 'marker-readback', ...errorInfo(error) }); }
        try {
          entry.contextDisposed = false;
          if (ctx) { await ctx.fiber.dispose(); entry.contextDisposed = true; }
        } catch (error) { entry.cleanupErrors.push({ stage: 'context-dispose', ...errorInfo(error) }); }
        if (logical) {
          try {
            entry.nativeAfter = nativeStatus();
            assert.equal(entry.nativeAfter.active, true);
            assert.equal(entry.nativeAfter.leases, 0);
            assert.equal(f.fds.size, 0);
          } catch (error) { entry.cleanupErrors.push({ stage: 'lease-readback', ...errorInfo(error) }); }
        }
        entry.status = entry.cleanupErrors.length ? 'CLEANUP_FAILED' : entry.setupError ? 'SETUP_ERROR' :
          entry.unexpectedError ? 'UNEXPECTED_ERROR' : !entry.batchReturned ? 'INCOMPLETE' :
          entry.behaviorErrors.length ? 'BEHAVIOR_RED' : 'PASS';
        entry.pass = entry.status === 'PASS';
        entry.milliseconds = performance.now() - started;
        entry.ended = new Date().toISOString();
      }
      return entry;
    }

    stage = 'physical-case';
    const physical = await run(report.cases[0], {
      directory: config.physical, marker: physicalMarker, expected: 'PHYSICAL',
    });
    if (physical.pass) {
      stage = 'select-attach-setup';
      const { workspaceFixture, until } = await import(pathToFileURL(
        join(config.source, 'runtime/tests/ohos/authorized-workspaces-fixture.mjs')));
      f = await workspaceFixture({ after: fn => cleanups.push(fn) }, { pathThrow: true });
      const uri = 'file://docs/storage/Users/currentUser/Projects/936-normal-read';
      const request = f.call(f, 'select', { userGesture: true });
      await until(() => f.pickers.length === 1);
      f.select([uri]);
      const selected = await request.done;
      assert.equal(selected.error, undefined);
      const id = selected.value.workspaces[0].id;
      const attached = await f.call(f, 'attach', { id, userGesture: true }).done;
      assert.equal(attached.error, undefined);
      row = attached.value.workspaces[0];
      assert.equal(row.nativeGrant, 'ready');
      assert.equal(row.candidatePath, null);
      assert.equal(f.fds.size, 0);
      // Only fixture preparation uses this owned backing path. The actual read
      // tool receives exactly file_path:'marker' and a logical Session cwd.
      logicalMarker = join(f.uriPaths.get(uri), 'marker');
      await fs.writeFile(logicalMarker, 'GRANT\n', { flag: 'wx', mode: 0o600 });
      report.logicalMarkerBefore = await ownedMarker(logicalMarker);
      report.published = { logicalRoot: '/workspaces/' + id, nativeGrant: row.nativeGrant,
        candidatePath: row.candidatePath, borrowedFDs: f.fds.size, nativeBefore: nativeStatus() };
      assert.equal(report.published.nativeBefore.active, true);
      assert.equal(report.published.nativeBefore.leases, 0);
      const parameters = { directory: report.published.logicalRoot, marker: logicalMarker,
        expected: 'GRANT', logical: true };
      stage = 'logical-whole-case';
      const whole = await run(report.cases[1], parameters);
      if (whole.status === 'PASS' || whole.status === 'BEHAVIOR_RED') {
        stage = 'logical-stream-case';
        await run(report.cases[2], { ...parameters, stream: true });
      } else report.cases[2].blockedBy = whole.status;
    } else for (const entry of report.cases.slice(1)) entry.blockedBy = 'physical-positive-control';
  } catch (error) {
    report[stage === 'setup' || stage === 'select-attach-setup' ? 'setupError' : 'unexpectedError'] =
      { stage, ...errorInfo(error) };
  } finally {
    try {
      if (physicalMarker && report.physicalMarkerBefore) {
        report.physicalMarkerAfter = await ownedMarker(physicalMarker);
        assert.deepEqual(report.physicalMarkerAfter, report.physicalMarkerBefore);
      }
      if (logicalMarker && report.logicalMarkerBefore) {
        report.logicalMarkerAfter = await ownedMarker(logicalMarker);
        assert.deepEqual(report.logicalMarkerAfter, report.logicalMarkerBefore);
        if (report.cases[2].batchReturned) {
          assert.deepEqual(report.cases[1].markerBefore, report.cases[2].markerBefore);
          report.sameLogicalMarkerForWholeAndStream = true;
        }
      }
      report.hostWorkspacesAfter = await hostRoot();
      assert.deepEqual(report.hostWorkspacesAfter, report.hostWorkspacesBefore);
      report.hostWorkspacesUnchanged = true;
    } catch (error) { report.cleanupErrors.push({ stage: 'final-owned-marker-readback', ...errorInfo(error) }); }
    // Ordinary teardown only: no subsequent read, reselect or failure scenario.
    try {
      f?.background();
      if (row) {
        report.nativeRetired = nativeStatus();
        assert.equal(report.nativeRetired.active, false);
        assert.equal(report.nativeRetired.leases, 0);
        assert.equal(report.nativeRetired.drained, true);
        assert.equal(f.fds.size, 0);
      }
    } catch (error) { report.cleanupErrors.push({ stage: 'native-retirement', ...errorInfo(error) }); }
    for (const cleanup of cleanups.reverse()) {
      try { await cleanup(); }
      catch (error) { report.cleanupErrors.push({ stage: 'fixture-cleanup', ...errorInfo(error) }); }
    }
    try { observer?.restore(); report.providerMethodsRestored = true; }
    catch (error) { report.cleanupErrors.push({ stage: 'provider-observer-restore', ...errorInfo(error) }); }
    report.batchCount = report.cases.filter(value => value.batchReturned).length;
    report.cleanupCompleted = report.cleanupErrors.length === 0 &&
      report.cases.every(value => !value.cleanupErrors?.length);
    report.pass = !report.setupError && !report.unexpectedError && report.cleanupCompleted &&
      report.cases.every(value => value.status === 'PASS' && value.pass && value.batchReturned) &&
      report.batchCount === 3 && report.sameLogicalMarkerForWholeAndStream === true &&
      report.hostWorkspacesUnchanged === true && report.providerMethodsRestored === true &&
      report.nativeRetired?.active === false && report.nativeRetired?.leases === 0 &&
      report.nativeRetired?.drained === true;
    report.ended = new Date().toISOString();
    await fs.writeFile(config.result, JSON.stringify(report, null, 2) + '\n');
  }
}
