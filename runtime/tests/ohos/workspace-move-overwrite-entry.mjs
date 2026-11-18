// Exactly two ordinary own-file read -> optional apply_patch Update File + Move to existing destination cases. No product implementation.
// Actual in-memory SessionStore/Session; Agent carrier and SDK chooser are explicit fixtures.
import { isMainThread } from 'node:worker_threads';

if (isMainThread) {
  const assert = (await import('node:assert/strict')).default;
  const fs = await import('node:fs/promises');
  const { join, dirname } = await import('node:path');
  const { createRequire } = await import('node:module');
  const { pathToFileURL } = await import('node:url');
  const { createHash } = await import('node:crypto');
  const { observeProviderReadMove } = await import('./workspace-move-overwrite-instrumentation.mjs');
  const config = JSON.parse(await fs.readFile(process.env.OHOS_302_MOVE_CONFIG, 'utf8'));
  const names = ['physical-read-then-move-overwrite', 'selected-logical-read-then-move-overwrite'];
  const BEFORE = 'FIRST\n', AFTER = 'SECOND\n', DEST_BEFORE = 'OLD\n';
  const SOURCE_MODE = 0o640, DESTINATION_MODE = 0o600;
  const FIXED_PATCH = ['*** Begin Patch', '*** Update File: marker.txt', '*** Move to: moved.txt', '@@', '-FIRST', '+SECOND', '*** End Patch'].join('\n');
  const BASELINE_FS_LOCAL = '58b45c8775b85de1e9e37386e6f67afa04cc696704472dfd6e89feb39e07ffc9';
  const report = {
    schema: 1,
    scope: 'Actual DSH bin/sole product preload; actual registered read and explicitly enabled apply_patch Update File + Move to existing destination, ToolRuntime, NativeToolExecutor, in-memory SessionStore/Session, WorkingDirectory and SandboxedFileSystem under workspace-write. Explicit Agent carrier and SDK chooser/Preferences fixtures. No full preset activation, chat, persistence, Host, RPC, UI or device.',
    started: new Date().toISOString(),
    node: { version: process.version, architecture: process.arch, simulatedPlatform: process.platform },
    fixedOracle: { sourceBefore: BEFORE, destinationBefore: DEST_BEFORE, destinationAfter: AFTER, sourceAfter: null, sourceBeforeBytes: 6, destinationBeforeBytes: 4, destinationAfterBytes: 7, sourceAfterExists: false, sourceBeforeMode: SOURCE_MODE, destinationBeforeMode: DESTINATION_MODE, destinationAfterMode: SOURCE_MODE, newDestination: false, existingDestination: true, sameRoot: true, partialFailureExercised: false },
    cases: names.map(name => ({ name, status: 'BLOCKED', pass: false, readPreludePassed: false,
      readBatchReturned: false, patchCallStarted: false, patchBatchReturned: false, patchProviderEntered: false })),
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
    try {
      const bytes = await fs.readFile(path), info = await fs.stat(path, { bigint: true });
      assert.equal(info.isFile(), true);
      return { exists: true, bytes: bytes.length, hex: bytes.toString('hex'),
        sha256: createHash('sha256').update(bytes).digest('hex'),
        dev: Number(info.dev), ino: Number(info.ino), mode: Number(info.mode & 0o777n),
        exactStat: { dev: String(info.dev), ino: String(info.ino), size: String(info.size),
          mtimeNs: String(info.mtimeNs), ctimeNs: String(info.ctimeNs) } };
    } catch (error) { if (error.code === 'ENOENT') return { exists: false }; throw error; }
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
  function assertContents(info, value, mode = SOURCE_MODE) {
    assert.equal(info.exists, true);
    const bytes = Buffer.from(value, 'utf8');
    assert.equal(info.bytes, bytes.length);
    assert.equal(info.hex, bytes.toString('hex'));
    assert.equal(info.sha256, createHash('sha256').update(bytes).digest('hex'));
    assert.equal(info.mode, mode);
  }
  async function prepareMarker(root) {
    assert.deepEqual(await fs.readdir(root), []);
    const path = join(root, 'marker.txt');
    await fs.writeFile(path, BEFORE, { flag: 'wx', mode: SOURCE_MODE });
    await fs.writeFile(join(root, 'moved.txt'), DEST_BEFORE, { flag: 'wx', mode: DESTINATION_MODE });
    assertContents(await ownedMarker(path), BEFORE);
    assertContents(await ownedMarker(join(root, 'moved.txt')), DEST_BEFORE, DESTINATION_MODE);
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
  function observedAbsentFor(callId, path) {
    const items = report.observations.filter(value => value.callId === callId);
    assert.equal(items.length, 1);
    assert.deepEqual(items[0].target, { displayPath: path, targetKey: path });
    assert.deepEqual(items[0].observed, { kind: 'absent' });
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
    assert.equal(typeof globalThis[Symbol.for('dsh.go.ohos.workspace-edit')]?.workspaceEditScope, 'function');
    report.ownerSymbolRegistered = true;
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
    observer = observeProviderReadMove(LocalFileSystem);
    physicalMarker = await prepareMarker(config.physical);
    report.physicalMarkerBefore = await ownedMarker(physicalMarker);
    report.physicalDestinationBefore = await ownedMarker(join(dirname(physicalMarker), 'moved.txt'));

    async function run(entry, { directory, marker, logical = false }) {
      let ctx, session, readMark, patchMark, caseStage = 'setup';
      const started = performance.now(), path = join(directory, 'marker.txt'), destination = join(directory, 'moved.txt');
      const destinationBacking = join(dirname(marker), 'moved.txt');
      Object.assign(entry, { status: 'SETUP_ERROR', started: new Date().toISOString(),
        toolConfig: { applyPatch: true },
        readArguments: { file_path: 'marker.txt' },
        patchArguments: { input: FIXED_PATCH },
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
        assert(entry.registeredTools.includes('apply_patch'));
        ctx.on('fs/observed', (target, observed, execution) => report.observations.push({
          target: { displayPath: target.displayPath, targetKey: String(target.targetKey) },
          observed, callId: execution.callId,
        }));
        const id = '302-' + entry.name;
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
        entry.destinationBefore = await ownedMarker(destinationBacking);
        assertContents(entry.destinationBefore, DEST_BEFORE, DESTINATION_MODE);
        const parentInfo = await fs.lstat(dirname(marker));
        assert.equal(parentInfo.isDirectory(), true);
        assert.equal(parentInfo.isSymbolicLink(), false);
        entry.destinationParentPreexists = true;
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

        entry.independentDestinationBeforeVersion = independentVersion(entry.destinationBefore, logical ? entry.grant : undefined);

        // This is a prerequisite for patch, not a replacement fs/observed event.
        caseStage = 'read-precondition';
        const readId = '302-read-' + entry.name;
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
        entry.destinationAfterRead = await ownedMarker(destinationBacking);
        assert.deepEqual(entry.destinationAfterRead, entry.destinationBefore);
        entry.independentReadVersion = independentVersion(entry.markerAfterRead, logical ? entry.grant : undefined);
        assert.equal(entry.readObservation.observed.version, entry.independentReadVersion);
        entry.independentReadVersionVerified = true;
        assert.equal(ctx.workingDirectory.get(session), directory);
        assert.equal(ctx.sessions.get(id), session);
        entry.readPreludePassed = true;

        if (logical) assert.deepEqual(await hostRoot(), { exists: false });
        caseStage = 'patch-execute';
        const patchId = '302-patch-' + entry.name;
        patchMark = observer.mark();
        entry.patchCallStarted = true;
        entry.patchBatch = await ctx.tools.execute({ agent,
          calls: [{ id: patchId, name: 'apply_patch', arguments: JSON.stringify(entry.patchArguments) }],
          signal: new AbortController().signal });
        entry.patchBatchReturned = true;
        if (logical) {
          try {
            entry.nativeAfterPatchAwait = nativeStatus();
            entry.nativeAfterPatchAwaitSampling = 'After actual tool batch await, before Context.dispose; not an instantaneous provider-return sample';
            assert.equal(entry.nativeAfterPatchAwait.active, true);
            assert.equal(entry.nativeAfterPatchAwait.generation, row.nativeGeneration);
            assert.equal(entry.nativeAfterPatchAwait.leases, 0);
            assert.equal(f.fds.size, 0);
            entry.nativeAfterPatchAwaitVerified = true;
          } catch (error) { entry.cleanupErrors.push({ stage: 'lease-after-patch-await', ...errorInfo(error) }); }
        }
        entry.patchProviderCalls = observer.since(patchMark);
        entry.patchProviderEntered = entry.patchProviderCalls.some(call => call.method === 'moveFile' &&
          call.targetKey === path && call.displayPath === path);
        entry.workingDirectoryAfter = ctx.workingDirectory.get(session);
        if (!entry.patchProviderEntered) {
          caseStage = 'patch-target-not-reached';
          throw new Error('Actual patch batch returned without entering the expected public provider target');
        }
        caseStage = 'patch-batch';
        const patchResult = singleResult(entry.patchBatch, patchId);
        entry.patchPresentationMeta = patchResult.meta ?? null;
        assert.deepEqual(entry.patchProviderCalls.map(call => call.method), ['readText', 'moveFile']);
        const calls = entry.patchProviderCalls.filter(call => call.method === 'moveFile');
        assert.equal(calls.length, 1);
        assert.deepEqual({ method: calls[0].method, targetKey: calls[0].targetKey, displayPath: calls[0].displayPath,
          destinationKey: calls[0].destinationKey, destinationPath: calls[0].destinationPath },
          { method: 'moveFile', targetKey: path, displayPath: path, destinationKey: destination, destinationPath: destination });
        assert.deepEqual(calls[0].hunks, [{ lineNumber: 4, oldLines: ['FIRST'], newLines: ['SECOND'], isEndOfFile: false }]);
        entry.actualMoveIntent = calls[0].intent;
        assert.deepEqual(entry.actualMoveIntent, { source: { present: false }, destination: { present: false } });
        entry.publicMoveOutcome = calls[0].outcome;
        assert.equal(entry.workingDirectoryAfter, directory);
        assert.equal(ctx.sessions.get(id), session);
        if (patchResult.isError === true) {
          if (patchResult.error?.info?.code !== 'FS_STALE_VERSION') {
            throw new Error('Unclassified actual patch rejection; see complete patchBatch');
          }
          const message = `Patch rejected before any change (1 problems):\n- operation 1 (move ${path}, patch line 2): cannot move "${path}": file changed since it was read — re-read the file, then retry`;
          assert.deepEqual(patchResult.error, { message, info: { name: 'FsError', code: 'FS_STALE_VERSION' } });
          assert.deepEqual(patchResult.content, [{ type: 'text', text: 'Error: ' + message }]);
          assert.equal(Object.hasOwn(patchResult, 'value'), false);
          entry.knownProductRejection = true;
          entry.behaviorErrors.push({ kind: 'actual-tool-rejection', code: 'FS_STALE_VERSION' });
          entry.sourceInference = {
            kind: 'source inference, not private-probe instrumentation', privateProbeObserved: false,
            sourceBaselineSha256: BASELINE_FS_LOCAL,
            appliesToCurrentInput: logical && config.fsLocalSha256 === BASELINE_FS_LOCAL,
            conditionalConclusion: logical && config.fsLocalSha256 === BASELINE_FS_LOCAL ?
              'For this exact 288 Local provider, moveFile first invokes requireFile(source) without OH probe; with absent host /workspaces, host probe returns null and rejects before destination writeTarget, mkdir, publish or source remove. This is source attribution, not private helper instrumentation or a Native move failure.' : null,
          };
        } else {
          caseStage = 'assert-patch-success';
          try {
            assert.equal(patchResult.isError, false);
            assert.deepEqual(patchResult.value, { phase: 'commit', cancelled: false,
              affectedPaths: [destination, path], operations: [{ index: 0, kind: 'move', path,
                patchLine: 2, destination, status: 'completed', changes: [
                  { path: destination, before: DEST_BEFORE, after: AFTER }, { path, before: BEFORE, after: null }] }] });
            assert.deepEqual(patchResult.content, [{ type: 'text', text:
              `Success. Updated the following files:\nM ${destination}` }]);
            // Existing destination contributes its text hunk without LF; source removal retains its LF.
            assert.deepEqual(patchResult.meta, { diffs: [
              { path: destination, oldText: 'OLD', newText: 'SECOND' },
              { path, oldText: BEFORE, newText: '' }], stopped: false });
            assert.equal(Object.hasOwn(patchResult, 'error'), false);
            const observations = report.observations.filter(item => item.callId === patchId);
            assert.equal(observations.length, 2);
            assert.deepEqual(observations[0].target, { displayPath: destination, targetKey: destination });
            assert.equal(observations[0].observed.kind, 'present');
            assert.equal(typeof observations[0].observed.version, 'string');
            assert.deepEqual(observations[1], { target: { displayPath: path, targetKey: path },
              observed: { kind: 'absent' }, callId: patchId });
            entry.destinationObservation = observations[0];
            entry.patchObservation = observations[1];
            assert.equal(entry.workingDirectoryAfter, directory);
            assert.equal(ctx.sessions.get(id), session);
            entry.patchSuccessOraclePassed = true;
          } catch (error) { entry.behaviorErrors.push({ kind: 'patch-result-contract', ...errorInfo(error) }); }
        }
        caseStage = 'owned-patch-readback';
        entry.markerAfterPatch = await ownedMarker(marker);
        entry.destinationAfterPatch = await ownedMarker(destinationBacking);
        try {
          if (entry.knownProductRejection) {
            assert.deepEqual(entry.markerAfterPatch, entry.markerBefore);
            assert.deepEqual(entry.destinationAfterPatch, entry.destinationBefore);
            entry.independentDestinationUnchangedVersion = independentVersion(entry.destinationAfterPatch, logical ? entry.grant : undefined);
            assert.equal(entry.independentDestinationUnchangedVersion, entry.independentDestinationBeforeVersion);
            entry.independentDestinationUnchangedVersionVerified = true;
            assert.deepEqual(entry.publicMoveOutcome, { status: 'rejected', error: { name: 'FsError', code: 'FS_STALE_VERSION', message: `cannot move \"${path}\": file changed since it was read` } });
            entry.independentUnchangedVersion = independentVersion(entry.markerAfterPatch, logical ? entry.grant : undefined);
            assert.equal(entry.independentUnchangedVersion, entry.independentReadVersion);
            assert.equal(report.observations.filter(item => item.callId === patchId).length, 0);
            entry.independentUnchangedVersionVerified = true;
          } else {
            assert.deepEqual(entry.markerAfterPatch, { exists: false });
            assert.deepEqual(entry.patchObservation?.observed, { kind: 'absent' });
            entry.independentAbsenceVerified = true;
            assertContents(entry.destinationAfterPatch, AFTER);
            entry.independentDestinationVersion = independentVersion(entry.destinationAfterPatch, logical ? entry.grant : undefined);
            assert.equal(entry.destinationObservation.observed.version, entry.independentDestinationVersion);
            assert.notEqual(entry.independentDestinationVersion, entry.independentDestinationBeforeVersion);
            assert.deepEqual(entry.publicMoveOutcome, { status: 'fulfilled', value: {
              sourceBefore: BEFORE, destination: { operation: 'update', version: entry.independentDestinationVersion,
                before: DEST_BEFORE, after: AFTER }, sourceDeleted: true } });
            entry.independentDestinationVersionVerified = true;
            entry.completeMoveContractVerified = true;
          }
          entry.markerOutcomeVerified = true;
        } catch (error) { entry.behaviorErrors.push({ kind: 'owned-marker-outcome', ...errorInfo(error) }); }
      } catch (error) {
        const preparation = ['setup', 'working-directory', 'read-precondition', 'patch-target-not-reached'].includes(caseStage);
        entry[preparation ? 'setupError' : 'unexpectedError'] = { stage: caseStage, ...errorInfo(error) };
      } finally {
        if (readMark !== undefined && !entry.readProviderCalls) entry.readProviderCalls = observer.since(readMark);
        if (patchMark !== undefined && !entry.patchProviderCalls) entry.patchProviderCalls = observer.since(patchMark);
        if (entry.patchProviderCalls) entry.patchProviderEntered = entry.patchProviderCalls.some(call =>
          call.method === 'moveFile' && call.targetKey === path && call.displayPath === path);
        // Preserve actual own-file bytes even if an earlier assertion did not reach the normal readback.
        if (entry.markerBefore && !entry.markerAfterPatch) {
          try { entry.markerAfterInterruption = await ownedMarker(marker); entry.destinationAfterInterruption = await ownedMarker(destinationBacking); }
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
          entry.unexpectedError ? 'UNEXPECTED_ERROR' : !entry.patchBatchReturned ? 'INCOMPLETE' :
          entry.behaviorErrors.length ? 'BEHAVIOR_RED' :
          entry.patchSuccessOraclePassed && entry.markerOutcomeVerified ? 'PASS' : 'INCOMPLETE';
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
      const uri = 'file://docs/storage/Users/currentUser/Projects/302-normal-move-overwrite';
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
      report.logicalDestinationBefore = await ownedMarker(join(dirname(logicalMarker), 'moved.txt'));
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
        entry.destinationAtFinalTeardown = await ownedMarker(join(dirname(marker), 'moved.txt'));
        if (entry.markerAfterPatch) assert.deepEqual(actual, entry.markerAfterPatch);
        if (entry.destinationAfterPatch) assert.deepEqual(entry.destinationAtFinalTeardown, entry.destinationAfterPatch);
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
    report.patchBatchCount = report.cases.filter(value => value.patchBatchReturned).length;
    report.cleanupCompleted = report.cleanupErrors.length === 0 &&
      report.cases.every(value => !value.cleanupErrors?.length);
    report.pass = !report.setupError && !report.unexpectedError && report.cleanupCompleted &&
      report.cases.every(value => value.status === 'PASS' && value.readPreludePassed &&
        value.patchBatchReturned && value.patchProviderEntered && value.patchSuccessOraclePassed &&
        value.markerOutcomeVerified && value.contextDisposed &&
        value.independentReadVersionVerified && value.independentAbsenceVerified &&
        value.independentDestinationVersionVerified && value.completeMoveContractVerified) &&
      report.cases[1].nativeAfterPatchAwaitVerified === true &&
      report.readBatchCount === 2 && report.patchBatchCount === 2 &&
      report.noSeparateDirectMapping === true && report.hostWorkspacesUnchanged === true &&
      report.providerMethodsRestored === true && report.nativeRetired?.active === false &&
      report.nativeRetired?.leases === 0 && report.nativeRetired?.drained === true;
    report.ended = new Date().toISOString();
    await fs.writeFile(config.result, JSON.stringify(report, null, 2) + '\n');
  }
}
