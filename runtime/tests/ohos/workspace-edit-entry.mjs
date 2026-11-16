// Exactly two ordinary own-file read -> edit cases. Not a production save implementation.
// Actual in-memory SessionStore/Session; Agent carrier and SDK chooser are explicit fixtures.
import { isMainThread } from 'node:worker_threads';

if (isMainThread) {
  const assert = (await import('node:assert/strict')).default;
  const fs = await import('node:fs/promises');
  const { join } = await import('node:path');
  const { createRequire } = await import('node:module');
  const { pathToFileURL } = await import('node:url');
  const { createHash } = await import('node:crypto');
  const { observeProviderReadEdit } = await import('./workspace-edit-instrumentation.mjs');
  const config = JSON.parse(await fs.readFile(process.env.OHOS_938_EDIT_CONFIG, 'utf8'));
  const names = ['physical-read-then-edit', 'selected-logical-read-then-edit'];
  const BEFORE = 'FIRST\n', AFTER = 'SECOND\n';
  const BASELINE_FS_LOCAL = '6a071078387ad540c6fc9727500f73941404be5cfd77c8711a49719693255e7e';
  const report = {
    schema: 1,
    scope: 'Actual DSH bin/sole product preload; actual default tool read and edit, ToolRuntime, NativeToolExecutor, in-memory SessionStore/Session, WorkingDirectory and SandboxedFileSystem under workspace-write. Explicit Agent carrier and SDK chooser/Preferences fixtures. No full preset activation, chat, persistence, Host, RPC, UI or device.',
    started: new Date().toISOString(),
    fixedOracle: { before: BEFORE, after: AFTER, beforeBytes: 6, afterBytes: 7, mode: 0o644 },
    cases: names.map(name => ({ name, status: 'BLOCKED', pass: false, readPreludePassed: false,
      readBatchReturned: false, editCallStarted: false, editBatchReturned: false, editProviderEntered: false })),
    observations: [], modules: [], cleanupErrors: [], privateProbeObserved: false,
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
  let f, row, observer, logicalMarker, physicalMarker, stage = 'setup';
  const nativeStatus = () => f.native.workspaceGrant('status', row.nativeKey, row.nativeGeneration);
  async function ownedMarker(path) {
    const bytes = await fs.readFile(path), info = await fs.stat(path, { bigint: true });
    assert.equal(info.isFile(), true);
    return { bytes: bytes.length, hex: bytes.toString('hex'),
      sha256: createHash('sha256').update(bytes).digest('hex'),
      dev: Number(info.dev), ino: Number(info.ino), mode: Number(info.mode & 0o777n),
      exactStat: { dev: String(info.dev), ino: String(info.ino), size: String(info.size),
        mtimeNs: String(info.mtimeNs), ctimeNs: String(info.ctimeNs) } };
  }
  // Independent node:fs bigint stat over the owned backing file, never a product helper.
  // Matches the fixed 941 exact-stat version contract; not a new wire format.
  function independentVersion(info, grant) {
    const s = info.exactStat;
    if (!grant) return [s.dev, s.ino, s.size, s.mtimeNs, s.ctimeNs].join(':');
    const billion = 1000000000n, mt = BigInt(s.mtimeNs), ct = BigInt(s.ctimeNs);
    return ['ohos-grant', grant.id, String(grant.generation), s.dev, s.ino, s.size,
      String(mt / billion), String(mt % billion), String(ct / billion), String(ct % billion)].join(':');
  }
  function assertContents(info, value) {
    const bytes = Buffer.from(value, 'utf8');
    assert.equal(info.bytes, bytes.length);
    assert.equal(info.hex, bytes.toString('hex'));
    assert.equal(info.sha256, createHash('sha256').update(bytes).digest('hex'));
    assert.equal(info.mode, 0o644);
  }
  async function prepareMarker(root) {
    assert.deepEqual(await fs.readdir(root), []);
    const path = join(root, 'marker.txt');
    await fs.writeFile(path, BEFORE, { flag: 'wx', mode: 0o644 });
    assertContents(await ownedMarker(path), BEFORE);
    return path;
  }
  async function hostRoot() {
    try {
      const info = await fs.lstat('/workspaces');
      return { exists: true, directory: info.isDirectory(), dev: info.dev, ino: info.ino };
    } catch (error) { if (error.code === 'ENOENT') return { exists: false }; throw error; }
  }
  function singleResult(batch, callId) {
    assert.equal(batch.results.length, 1);
    assert.equal(batch.results[0].callId, callId);
    assert.deepEqual(batch.additionalContexts, []);
    assert.equal(batch.concluded, false);
    return batch.results[0].result;
  }
  function observedFor(callId, path) {
    const items = report.observations.filter(value => value.callId === callId);
    assert.equal(items.length, 1);
    assert.deepEqual(items[0].target, { displayPath: path, targetKey: path });
    assert.equal(items[0].observed.kind, 'present');
    assert.equal(typeof items[0].observed.version, 'string');
    assert.notEqual(items[0].observed.version, '');
    return items[0];
  }
  try {
    assert.equal(process.argv[1], join(config.payload, 'node_modules/@deepseek-ai/dsh/lib/bin.js'));
    assert.equal(process.platform, 'openharmony');
    report.hostWorkspacesBefore = await hostRoot();
    assert.equal(report.hostWorkspacesBefore.exists, false);
    assert.equal(globalThis[Symbol.for('dsh.go.direct')], undefined);
    report.noSeparateDirectMapping = true;
    assert.equal(typeof globalThis[Symbol.for('dsh.go.ohos.workspace-paths')]?.directory, 'function');
    const [{ Context }, { Session, SessionStore }, { SystemPrompt }, { SessionProjectionRegistry },
      { SandboxPolicyService }, { SandboxedFileSystem }, { LocalFileSystem },
      { WorkingDirectoryService }, { ToolRuntime }, native, fsTools] = await Promise.all([
        'cordis', 'dsh-session', 'dsh-system-prompt', 'dsh-session-projection',
        'dsh-sandbox-policy', 'dsh-fs-sandbox', 'dsh-fs-local',
        'dsh-working-directory', 'dsh-tools', 'dsh-tool-executor-native', 'dsh-tool-fs',
      ].map(load));
    const grantModule = join(config.payload, 'runtime/ohos/process/files/process-authority.mjs');
    const { processWorkspaceGrant } = await import(pathToFileURL(grantModule));
    report.modules.push({ name: 'process-authority', path: grantModule });
    observer = observeProviderReadEdit(LocalFileSystem);
    physicalMarker = await prepareMarker(config.physical);
    report.physicalMarkerBefore = await ownedMarker(physicalMarker);

    async function run(entry, { directory, marker, logical = false }) {
      let ctx, session, readMark, editMark, caseStage = 'setup';
      const started = performance.now(), path = join(directory, 'marker.txt');
      Object.assign(entry, { status: 'SETUP_ERROR', started: new Date().toISOString(),
        toolConfig: { applyPatch: false },
        readArguments: { file_path: 'marker.txt' },
        editArguments: { file_path: 'marker.txt', old_string: 'FIRST', new_string: 'SECOND', replace_all: false },
        cleanupErrors: [], behaviorErrors: [], privateProbeObserved: false,
        observationPolicy: 'Not mounted, matching the inspected standard declaration; no handwritten intent.' });
      try {
        ctx = new Context();
        await ctx.plugin(SystemPrompt, {});
        await ctx.plugin(SessionProjectionRegistry);
        await ctx.plugin(SessionStore);
        await ctx.plugin(SandboxPolicyService, { mode: 'workspace-write', workspaceRoot: directory });
        await ctx.plugin(SandboxedFileSystem, { cwd: directory });
        await ctx.plugin(WorkingDirectoryService, { defaultDirectory: directory });
        await ctx.plugin(ToolRuntime, {});
        await ctx.plugin(native);
        await ctx.plugin(fsTools, entry.toolConfig);
        entry.services = { fs: ctx.fs.constructor.name, policy: ctx.sandboxPolicy.constructor.name,
          executor: ctx.tools.selectExecutor().constructor.name, tools: ctx.tools.constructor.name,
          directory: ctx.workingDirectory.constructor.name, sessions: ctx.sessions.constructor.name,
          projections: ctx.sessionProjections.constructor.name, mode: ctx.fs.sandboxMode };
        assert.equal(entry.services.fs, 'SandboxedFileSystem');
        assert.equal(entry.services.executor, 'NativeToolExecutor');
        assert.equal(entry.services.sessions, 'SessionStore');
        assert.equal(entry.services.mode, 'workspace-write');
        entry.registeredTools = ctx.tools.definitions().map(tool => tool.name);
        assert(entry.registeredTools.includes('read'));
        assert(entry.registeredTools.includes('edit'));
        ctx.on('fs/observed', (target, observed, execution) => report.observations.push({
          target: { displayPath: target.displayPath, targetKey: String(target.targetKey) },
          observed, callId: execution.callId,
        }));
        const id = '938-' + entry.name;
        session = ctx.sessions.create(id, { meta: { cwd: directory } });
        assert(session instanceof Session);
        assert.equal(ctx.sessions.get(id), session);
        assert.equal(session.header.cwd, directory);
        session.append('turn/start', { turn: 1 });
        const notices = [], agent = { id, session, ctx, inject: notice => notices.push(notice) };
        entry.session = { type: session.constructor.name, id, headerCwd: session.header.cwd,
          store: 'actual in-memory SessionStore', persistence: false, agentCarrier: 'fixture' };
        entry.notices = notices;
        entry.markerBefore = await ownedMarker(marker);
        assertContents(entry.markerBefore, BEFORE);
        caseStage = 'working-directory';
        entry.workingDirectoryBefore = ctx.workingDirectory.get(session);
        entry.ensure = await ctx.workingDirectory.ensure(agent, new AbortController().signal);
        assert.equal(entry.ensure, directory);
        entry.policy = ctx.sandboxPolicy.resolve({ session });
        assert.equal(entry.policy.mode, 'workspace-write');
        assert.equal(entry.policy.workspaceRoot, directory);
        if (logical) {
          entry.nativeBefore = nativeStatus();
          assert.equal(entry.nativeBefore.active, true);
          assert.equal(entry.nativeBefore.leases, 0);
          entry.grant = processWorkspaceGrant(directory); // Read an existing grant; never issue a ticket.
          assert.equal(entry.grant.mountPoint, directory);
          assert.equal(entry.grant.writable, true);
          assert.equal(f.fds.size, 0);
        }

        // This is a prerequisite for edit, not a replacement fs/observed event.
        caseStage = 'read-precondition';
        const readId = '938-read-' + entry.name;
        readMark = observer.mark();
        entry.readBatch = await ctx.tools.execute({ agent,
          calls: [{ id: readId, name: 'read', arguments: JSON.stringify(entry.readArguments) }],
          signal: new AbortController().signal });
        entry.readBatchReturned = true;
        entry.readProviderCalls = observer.since(readMark);
        const readResult = singleResult(entry.readBatch, readId);
        const readValue = { path, offset: 1, lines: [{ number: 1, text: 'FIRST' }], totalLines: 1 };
        assert.equal(readResult.isError, false);
        assert.deepEqual(readResult.meta, readValue);
        assert.deepEqual(readResult.value, readValue);
        assert.deepEqual(readResult.content, [{ type: 'text', text:
          `<path>${path}</path>\n<type>file</type>\n<content>\n1: FIRST\n\n(End of file - total 1 lines)\n</content>` }]);
        assert.deepEqual(entry.readProviderCalls, [{ method: 'readText', targetKey: path, displayPath: path }]);
        entry.readObservation = observedFor(readId, path);
        entry.markerAfterRead = await ownedMarker(marker);
        assert.deepEqual(entry.markerAfterRead, entry.markerBefore);
        entry.independentReadVersion = independentVersion(entry.markerAfterRead, logical ? entry.grant : undefined);
        assert.equal(entry.readObservation.observed.version, entry.independentReadVersion);
        entry.independentReadVersionVerified = true;
        assert.equal(ctx.workingDirectory.get(session), directory);
        assert.equal(ctx.sessions.get(id), session);
        entry.readPreludePassed = true;

        caseStage = 'edit-execute';
        const editId = '938-edit-' + entry.name;
        editMark = observer.mark();
        entry.editCallStarted = true;
        entry.editBatch = await ctx.tools.execute({ agent,
          calls: [{ id: editId, name: 'edit', arguments: JSON.stringify(entry.editArguments) }],
          signal: new AbortController().signal });
        entry.editBatchReturned = true;
        if (logical) {
          try {
            entry.nativeAfterEditAwait = nativeStatus();
            entry.nativeAfterEditAwaitSampling = 'After actual tool batch await, before Context.dispose; not an instantaneous provider-return sample';
            assert.equal(entry.nativeAfterEditAwait.active, true);
            assert.equal(entry.nativeAfterEditAwait.generation, row.nativeGeneration);
            assert.equal(entry.nativeAfterEditAwait.leases, 0);
            assert.equal(f.fds.size, 0);
            entry.nativeAfterEditAwaitVerified = true;
          } catch (error) { entry.cleanupErrors.push({ stage: 'lease-after-edit-await', ...errorInfo(error) }); }
        }
        entry.editProviderCalls = observer.since(editMark);
        entry.editProviderEntered = entry.editProviderCalls.some(call => call.method === 'editText' &&
          call.targetKey === path && call.displayPath === path);
        entry.workingDirectoryAfter = ctx.workingDirectory.get(session);
        if (!entry.editProviderEntered) {
          caseStage = 'edit-target-not-reached';
          throw new Error('Actual edit batch returned without entering the expected public provider target');
        }
        caseStage = 'edit-batch';
        const editResult = singleResult(entry.editBatch, editId);
        entry.editPresentationMeta = editResult.meta ?? null;
        const calls = entry.editProviderCalls;
        assert.equal(calls.length, 1);
        assert.deepEqual({ method: calls[0].method, targetKey: calls[0].targetKey, displayPath: calls[0].displayPath,
          edit: calls[0].edit }, { method: 'editText', targetKey: path, displayPath: path,
          edit: { oldString: 'FIRST', newString: 'SECOND', replaceAll: false } });
        entry.actualEditIntent = calls[0].intent;
        assert.equal(entry.workingDirectoryAfter, directory);
        assert.equal(ctx.sessions.get(id), session);
        if (editResult.isError === true) {
          if (editResult.error?.info?.code !== 'FS_STALE_VERSION') {
            throw new Error('Unclassified actual edit rejection; see complete editBatch');
          }
          const message = `cannot edit "${path}": file changed since it was read — re-read the file, then retry`;
          assert.deepEqual(editResult.error, { message, info: { name: 'FsError', code: 'FS_STALE_VERSION' } });
          assert.deepEqual(editResult.content, [{ type: 'text', text: 'Error: ' + message }]);
          assert.equal(Object.hasOwn(editResult, 'value'), false);
          entry.knownProductRejection = true;
          entry.behaviorErrors.push({ kind: 'actual-tool-rejection', code: 'FS_STALE_VERSION' });
          entry.sourceInference = {
            kind: 'source inference, not private-probe instrumentation', privateProbeObserved: false,
            sourceBaselineSha256: BASELINE_FS_LOCAL,
            appliesToCurrentInput: logical && config.fsLocalSha256 === BASELINE_FS_LOCAL,
            conditionalConclusion: logical && config.fsLocalSha256 === BASELINE_FS_LOCAL ?
              'For the inspected 937 provider and absent logical host root, its first host probe returns absent before readForEdit/writeFileAtomic. No native write-failure claim.' : null,
          };
        } else {
          caseStage = 'assert-edit-success';
          try {
            assert.equal(editResult.isError, false);
            assert.deepEqual(editResult.value, { path, before: BEFORE, after: AFTER });
            assert.deepEqual(editResult.content, [{ type: 'text', text:
              `The file ${path} has been updated successfully.` }]);
            // An independent one-line diff oracle; never reuse the read presentation shape.
            assert.deepEqual(editResult.meta, { path, diffs: [{ path, oldText: 'FIRST', newText: 'SECOND' }] });
            assert.equal(Object.hasOwn(editResult, 'error'), false);
            entry.editObservation = observedFor(editId, path);
            assert.equal(entry.workingDirectoryAfter, directory);
            assert.equal(ctx.sessions.get(id), session);
            entry.editSuccessOraclePassed = true;
          } catch (error) { entry.behaviorErrors.push({ kind: 'edit-result-contract', ...errorInfo(error) }); }
        }
        caseStage = 'owned-edit-readback';
        entry.markerAfterEdit = await ownedMarker(marker);
        try {
          if (entry.knownProductRejection) assert.deepEqual(entry.markerAfterEdit, entry.markerBefore);
          else {
            assertContents(entry.markerAfterEdit, AFTER); // Atomic publication may change inode.
            entry.independentEditVersion = independentVersion(entry.markerAfterEdit, logical ? entry.grant : undefined);
            assert.equal(entry.editObservation?.observed.version, entry.independentEditVersion);
            assert.notEqual(entry.independentEditVersion, entry.independentReadVersion);
            entry.independentEditVersionVerified = true;
          }
          entry.markerOutcomeVerified = true;
        } catch (error) { entry.behaviorErrors.push({ kind: 'owned-marker-outcome', ...errorInfo(error) }); }
      } catch (error) {
        const preparation = ['setup', 'working-directory', 'read-precondition', 'edit-target-not-reached'].includes(caseStage);
        entry[preparation ? 'setupError' : 'unexpectedError'] = { stage: caseStage, ...errorInfo(error) };
      } finally {
        if (readMark !== undefined && !entry.readProviderCalls) entry.readProviderCalls = observer.since(readMark);
        if (editMark !== undefined && !entry.editProviderCalls) entry.editProviderCalls = observer.since(editMark);
        if (entry.editProviderCalls) entry.editProviderEntered = entry.editProviderCalls.some(call =>
          call.method === 'editText' && call.targetKey === path && call.displayPath === path);
        // Preserve actual own-file bytes even if an earlier assertion did not reach the normal readback.
        if (entry.markerBefore && !entry.markerAfterEdit) {
          try { entry.markerAfterInterruption = await ownedMarker(marker); }
          catch (error) { entry.evidenceReadbackError = errorInfo(error); }
        }
        try {
          entry.contextDisposed = false;
          if (ctx) { await ctx.fiber.dispose(); entry.contextDisposed = true; }
        } catch (error) { entry.cleanupErrors.push({ stage: 'context-dispose', ...errorInfo(error) }); }
        if (logical) {
          try {
            entry.nativeAfterContextDispose = nativeStatus();
            assert.equal(entry.nativeAfterContextDispose.active, true);
            assert.equal(entry.nativeAfterContextDispose.leases, 0);
            assert.equal(f.fds.size, 0);
          } catch (error) { entry.cleanupErrors.push({ stage: 'lease-after-context-dispose', ...errorInfo(error) }); }
        }
        entry.status = entry.cleanupErrors.length ? 'CLEANUP_FAILED' : entry.setupError ? 'SETUP_ERROR' :
          entry.unexpectedError ? 'UNEXPECTED_ERROR' : !entry.editBatchReturned ? 'INCOMPLETE' :
          entry.behaviorErrors.length ? 'BEHAVIOR_RED' :
          entry.editSuccessOraclePassed && entry.markerOutcomeVerified ? 'PASS' : 'INCOMPLETE';
        entry.pass = entry.status === 'PASS';
        entry.milliseconds = performance.now() - started;
        entry.ended = new Date().toISOString();
      }
      return entry;
    }

    stage = 'physical-case';
    const physical = await run(report.cases[0], { directory: config.physical, marker: physicalMarker });
    if (physical.pass) {
      stage = 'select-attach-setup';
      const { workspaceFixture, until } = await import(pathToFileURL(
        join(config.source, 'runtime/tests/ohos/authorized-workspaces-fixture.mjs')));
      f = await workspaceFixture({ after: fn => cleanups.push(fn) });
      const uri = 'file://docs/storage/Users/currentUser/Projects/938-normal-edit';
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
      assert.equal(f.fds.size, 0);
      // Only owned fixture setup/readback use backing; tools receive marker.txt and logical cwd.
      logicalMarker = await prepareMarker(f.uriPaths.get(uri));
      report.logicalMarkerBefore = await ownedMarker(logicalMarker);
      report.published = { logicalRoot: '/workspaces/' + id, nativeGrant: row.nativeGrant,
        candidatePath: row.candidatePath, borrowedFDs: f.fds.size, nativeBefore: nativeStatus() };
      assert.equal(report.published.nativeBefore.active, true);
      assert.equal(report.published.nativeBefore.leases, 0);
      stage = 'logical-case';
      await run(report.cases[1], { directory: report.published.logicalRoot, marker: logicalMarker, logical: true });
    } else report.cases[1].blockedBy = 'physical-positive-control';
  } catch (error) {
    report[['setup', 'select-attach-setup'].includes(stage) ? 'setupError' : 'unexpectedError'] =
      { stage, ...errorInfo(error) };
  } finally {
    try {
      for (const [index, marker] of [[0, physicalMarker], [1, logicalMarker]]) {
        if (!marker) continue;
        const actual = await ownedMarker(marker), entry = report.cases[index];
        entry.markerAtFinalTeardown = actual;
        if (entry.markerAfterEdit) assert.deepEqual(actual, entry.markerAfterEdit);
      }
      if (report.hostWorkspacesBefore !== undefined) {
        report.hostWorkspacesAfter = await hostRoot();
        assert.deepEqual(report.hostWorkspacesAfter, report.hostWorkspacesBefore);
        report.hostWorkspacesUnchanged = true;
      }
    } catch (error) { report.cleanupErrors.push({ stage: 'final-owned-marker-readback', ...errorInfo(error) }); }
    // Ordinary teardown only, with no subsequent operation or reselect scenario.
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
    report.readBatchCount = report.cases.filter(value => value.readBatchReturned).length;
    report.editBatchCount = report.cases.filter(value => value.editBatchReturned).length;
    report.cleanupCompleted = report.cleanupErrors.length === 0 &&
      report.cases.every(value => !value.cleanupErrors?.length);
    report.pass = !report.setupError && !report.unexpectedError && report.cleanupCompleted &&
      report.cases.every(value => value.status === 'PASS' && value.readPreludePassed &&
        value.editBatchReturned && value.editProviderEntered && value.editSuccessOraclePassed &&
        value.markerOutcomeVerified && value.contextDisposed &&
        value.independentReadVersionVerified && value.independentEditVersionVerified) &&
      report.cases[1].nativeAfterEditAwaitVerified === true &&
      report.readBatchCount === 2 && report.editBatchCount === 2 &&
      report.noSeparateDirectMapping === true && report.hostWorkspacesUnchanged === true &&
      report.providerMethodsRestored === true && report.nativeRetired?.active === false &&
      report.nativeRetired?.leases === 0 && report.nativeRetired?.drained === true;
    report.ended = new Date().toISOString();
    await fs.writeFile(config.result, JSON.stringify(report, null, 2) + '\n');
  }
}
