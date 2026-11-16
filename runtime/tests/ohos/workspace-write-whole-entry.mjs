// Four ordinary after-only cases for the new WHOLE_WRITE_V1 group. Source preparation only in365.
import { isMainThread } from 'node:worker_threads';
if (isMainThread) {
  const assert = (await import('node:assert/strict')).default;
  const fs = await import('node:fs/promises');
  const { join, dirname } = await import('node:path');
  const { createRequire } = await import('node:module');
  const { pathToFileURL } = await import('node:url');
  const { createHash } = await import('node:crypto');
  const { observeWrite, errorValue, wholeObserver } = await import('./workspace-write-whole-instrumentation.mjs');
  const cfg = JSON.parse(await fs.readFile(process.env.OHOS_WHOLE_WRITE_CONFIG, 'utf8'));
  const oracle = JSON.parse(await fs.readFile(cfg.oracle, 'utf8'));
  const BEFORE = 'FIRST\n', AFTER = 'SECOND\n';
  const report = { schema: 1, started: new Date().toISOString(), mode: 'after-only',
    scope: 'Real DSH sole preload, in-memory SessionStore/Session, registered ToolRuntime/default read/write, Sandbox/Local and paired Native. Agent carrier, SDK chooser/Preferences and host carrier are fixtures. Not full Host/preset activation, model, Flutter, phone or VM.',
    cases: oracle.cases.map(row => ({ ...row, status: 'BLOCKED_NOT_RUN', pass: false, targetEntered: false, cleanupErrors: [] })),
    observations: [], modules: [], cleanupErrors: [], runtimeVersion: null, privateProbeObserved: false };
  const require = createRequire(join(cfg.payload, 'package.json'));
  const load = async name => { const path = require.resolve('@deepseek-ai/' + name);
    report.modules.push({ name, path }); return import(pathToFileURL(path)); };
  const failure = error => ({ ...errorValue(error), stack: error?.stack ?? null });
  const cleanups = []; let fixture, grantRow, observer, stage = 'setup';
  const nativeStatus = () => fixture.native.workspaceGrant('status', grantRow.nativeKey, grantRow.nativeGeneration);
  async function snapshot(path) {
    let info; try { info = await fs.lstat(path, { bigint: true }); }
    catch (error) { if (error.code === 'ENOENT') return { exists: false }; throw error; }
    assert(info.isFile()); const bytes = await fs.readFile(path);
    return { exists: true, bytes: bytes.length, hex: bytes.toString('hex'), sha256: createHash('sha256').update(bytes).digest('hex'),
      mode: Number(info.mode & 0o777n), gid: String(info.gid), exactStat: { dev: String(info.dev), ino: String(info.ino), size: String(info.size),
        mtimeNs: String(info.mtimeNs), ctimeNs: String(info.ctimeNs) } };
  }
  function version(state, grant) {
    const x = state.exactStat;
    if (!grant) return [x.dev, x.ino, x.size, x.mtimeNs, x.ctimeNs].join(':');
    const unit = 1000000000n, mt = BigInt(x.mtimeNs), ct = BigInt(x.ctimeNs);
    return ['ohos-grant', grant.id, String(grant.generation), x.dev, x.ino, x.size,
      String(mt / unit), String(mt % unit), String(ct / unit), String(ct % unit)].join(':');
  }
  function assertFile(state, text, mode) {
    const bytes = Buffer.from(text, 'utf8'); assert.equal(state.exists, true);
    assert.equal(state.bytes, bytes.length); assert.equal(state.hex, bytes.toString('hex'));
    assert.equal(state.sha256, createHash('sha256').update(bytes).digest('hex')); assert.equal(state.mode, mode);
  }
  async function hostRoot() {
    try { await fs.lstat('/workspaces'); return { exists: true }; }
    catch (error) { if (error.code === 'ENOENT') return { exists: false }; throw error; }
  }
  function observed(callId, path, expectedVersion) {
    const rows = report.observations.filter(row => row.callId === callId);
    assert.deepEqual(rows, [{ callId, target: { displayPath: path, targetKey: path },
      observed: { kind: 'present', version: expectedVersion } }]); return rows[0];
  }
  function batch(callId, result) { return { results: [{ callId, result }], additionalContexts: [], concluded: false }; }
  function verifyWholeCalls(entry) {
    const calls = entry.nativeWholeCalls;
    assert(Array.isArray(calls));
    if (!entry.logical) { assert.deepEqual(calls, []); entry.nativeWholeOraclePassed = true; return; }
    assert(calls.length >= 5);
    const leaseId = calls[0].input.leaseId; assert(Number.isInteger(leaseId) && leaseId > 0);
    const begin = { method: 'beginWholeOutput', input: { leaseId, relative: entry.filename,
      policy: entry.existing ? 0 : 1, priorMode: entry.existing ? 0o644 : 0, createIfAbsent: false },
      outcome: { status: 'returned', value: 1 } };
    assert.deepEqual(calls[0], begin);
    let index = 1, offset = 0; const bytes = Buffer.from(AFTER);
    while (calls[index]?.method === 'writeWholeOutput') {
      const row = calls[index++]; assert.deepEqual(row.input, { leaseId, bytes: bytes.length - offset, hex: bytes.subarray(offset).toString('hex') });
      assert.equal(row.outcome.status, 'returned'); const count = row.outcome.value;
      assert(Number.isInteger(count) && count > 0 && count <= bytes.length - offset); offset += count;
    }
    assert.equal(offset, bytes.length);
    assert.deepEqual(calls[index++], { method: 'closeWholeOutput', input: { leaseId }, outcome: { status: 'returned', value: 1 } });
    assert.deepEqual(calls[index++], { method: 'stepWholeOutput', input: { leaseId }, outcome: { status: 'returned', value: {
      schemaVersion: 1, effectKnown: true, effect: 2, continuation: 0, stagingRemoved: true } } });
    assert.deepEqual(calls[index++], { method: 'abortWholeOutput', input: { leaseId }, outcome: { status: 'returned', value: 1 } });
    assert.equal(index, calls.length);
    entry.nativeWholeOraclePassed = true;
    entry.nativeWholeCoverage = { unguardedPublication: 'confirmed-effect2', copyFdClose: 'abort returned; lease observations separate',
      guardedWx: 'NOT_MEASURED', boundedCopy: 'NOT_MEASURED', cancellation: 'NOT_MEASURED', effect1: 'NOT_MEASURED', cleanupFailure: 'NOT_MEASURED' };
  }
  try {
    assert.deepEqual(oracle.newFileMode, { policy: 'directory-default', requestedMode: 0o666, oracle: 'independent same-parent Node wx creation; mode and gid, not ACL contents' });
    assert.equal(wholeObserver.mark(), 0);
    report.nativeWholeGroup = 'WHOLE_WRITE_ABI_V1';
    report.unmeasured = oracle.notCovered;
    assert.equal(oracle.before, BEFORE); assert.equal(oracle.after, AFTER); assert.equal(oracle.existingMode, 0o644);
    assert.equal(process.argv[1], join(cfg.payload, 'node_modules/@deepseek-ai/dsh/lib/bin.js'));
    assert.equal(process.platform, 'openharmony');
    report.hostWorkspacesBefore = await hostRoot(); assert.deepEqual(report.hostWorkspacesBefore, { exists: false });
    assert.equal(globalThis[Symbol.for('dsh.go.direct')], undefined); report.noSeparateDirectMapping = true;
    assert.equal(typeof globalThis[Symbol.for('dsh.go.ohos.workspace-edit')]?.workspaceEditScope, 'function');
    // Normal setup; sequential loading avoids introducing a parallel ESM/CJS driver race.
    const { Context } = await load('cordis'); const { Session, SessionStore } = await load('dsh-session');
    const { SystemPrompt } = await load('dsh-system-prompt'); const { SessionProjectionRegistry } = await load('dsh-session-projection');
    const { SandboxPolicyService } = await load('dsh-sandbox-policy'); const { SandboxedFileSystem } = await load('dsh-fs-sandbox');
    const { LocalFileSystem } = await load('dsh-fs-local'); const { WorkingDirectoryService } = await load('dsh-working-directory');
    const { ToolRuntime } = await load('dsh-tools'); const nativeExecutor = await load('dsh-tool-executor-native'); const fsTools = await load('dsh-tool-fs');
    const authorityPath = join(cfg.payload, 'runtime/ohos/process/files/process-authority.mjs');
    const { processWorkspaceGrant } = await import(pathToFileURL(authorityPath)); report.modules.push({ name: 'process-authority', path: authorityPath });
    observer = observeWrite(LocalFileSystem, SandboxedFileSystem);
    async function run(entry, directory, backing) {
      let ctx, session, readMark, writeMark, nativeMark, caseStage = 'setup'; const started = performance.now();
      entry.started = new Date().toISOString(); entry.directory = directory; entry.path = join(directory, entry.filename); entry.backing = backing;
      entry.arguments = { file_path: entry.filename, content: AFTER }; entry.toolConfig = { applyPatch: false };
      entry.observationPolicy = 'Not mounted; write intent is naturally absent, never handwritten.';
      try {
        entry.fileBefore = await snapshot(backing);
        if (entry.existing) assertFile(entry.fileBefore, BEFORE, 0o644); else assert.deepEqual(entry.fileBefore, { exists: false });
        if (!entry.existing) {
          // Independent OS default witness in the same actual fixture parent.
          // No chmod, global umask update, identity/permission switch, or oracle from the writer.
          entry.defaultReferencePath = join(dirname(backing), 'directory-default-reference.txt');
          const reference = await fs.open(entry.defaultReferencePath, 'wx', 0o666);
          let observed;
          try { observed = await reference.stat({ bigint: true }); assert(observed.isFile()); }
          finally { await reference.close(); }
          entry.defaultReference = await snapshot(entry.defaultReferencePath);
          assertFile(entry.defaultReference, '', Number(observed.mode & 0o777n));
          assert.equal(entry.defaultReference.gid, String(observed.gid));
          assert.equal(entry.defaultReference.exactStat.dev, String(observed.dev));
          assert.equal(entry.defaultReference.exactStat.ino, String(observed.ino));
          // App-workspace files keep the upstream (and Android) 0600; granted folders follow the directory default.
          entry.expectedNewMode = entry.logical ? entry.defaultReference.mode : 0o600; entry.expectedNewGid = entry.defaultReference.gid;
          entry.defaultReferenceBasis = 'normal Node wx(0666), same backing parent; no mode/gid changes';
        }

        ctx = new Context(); await ctx.plugin(SystemPrompt, {}); await ctx.plugin(SessionProjectionRegistry); await ctx.plugin(SessionStore);
        await ctx.plugin(SandboxPolicyService, { mode: 'workspace-write', workspaceRoot: directory });
        await ctx.plugin(SandboxedFileSystem, { cwd: directory }); await ctx.plugin(WorkingDirectoryService, { defaultDirectory: directory });
        await ctx.plugin(ToolRuntime, {}); await ctx.plugin(nativeExecutor); await ctx.plugin(fsTools, entry.toolConfig);
        entry.services = { fs: ctx.fs.constructor.name, policy: ctx.sandboxPolicy.constructor.name, executor: ctx.tools.selectExecutor().constructor.name,
          tools: ctx.tools.constructor.name, directory: ctx.workingDirectory.constructor.name, sessions: ctx.sessions.constructor.name,
          projections: ctx.sessionProjections.constructor.name, mode: ctx.fs.sandboxMode };
        assert.deepEqual(entry.services, { fs: 'SandboxedFileSystem', policy: 'SandboxPolicyService', executor: 'NativeToolExecutor', tools: 'ToolsService',
          directory: 'WorkingDirectoryService', sessions: 'SessionStore', projections: 'SessionProjectionRegistry', mode: 'workspace-write' });
        entry.registeredTools = ctx.tools.definitions().map(tool => tool.name); assert(entry.registeredTools.includes('write') && entry.registeredTools.includes('read'));
        ctx.on('fs/observed', (target, state, execution) => report.observations.push({ callId: execution.callId,
          target: { displayPath: target.displayPath, targetKey: String(target.targetKey) }, observed: state }));
        const id = 'whole-write-' + entry.name; session = ctx.sessions.create(id, { meta: { cwd: directory } });
        assert(session instanceof Session); assert.equal(ctx.sessions.get(id), session); assert.equal(session.header.cwd, directory);
        session.append('turn/start', { turn: 1 }); const notices = [], agent = { id, session, ctx, inject: notice => notices.push(notice) };
        entry.session = { type: session.constructor.name, id, headerCwd: session.header.cwd, store: 'actual in-memory SessionStore', persistence: false, agentCarrier: 'fixture' };
        entry.notices = notices; entry.ensure = await ctx.workingDirectory.ensure(agent, new AbortController().signal); assert.equal(entry.ensure, directory);
        entry.policy = ctx.sandboxPolicy.resolve({ session }); assert.deepEqual(entry.policy, { mode: 'workspace-write', workspaceRoot: directory, sessionId: id });
        if (entry.logical) {
          entry.grant = processWorkspaceGrant(directory); assert.equal(entry.grant.mountPoint, directory); assert.equal(entry.grant.writable, true);
          entry.nativeBefore = nativeStatus(); assert.equal(entry.nativeBefore.active, true); assert.equal(entry.nativeBefore.leases, 0);
          assert.equal(entry.nativeBefore.generation, grantRow.nativeGeneration); assert.equal(fixture.fds.size, 0);
        }
        const target = { displayPath: entry.path, targetKey: entry.path };
        if (entry.existing) {
          caseStage = 'read-precondition'; entry.readId = 'read-' + entry.name; readMark = observer.mark();
          entry.readBatch = await ctx.tools.execute({ agent, calls: [{ id: entry.readId, name: 'read', arguments: JSON.stringify({ file_path: entry.filename }) }], signal: new AbortController().signal });
          entry.readBatchReturned = true; entry.readCalls = observer.since(readMark);
          const value = { path: entry.path, offset: 1, lines: [{ number: 1, text: 'FIRST' }], totalLines: 1 };
          assert.deepEqual(entry.readBatch, batch(entry.readId, { isError: false, content: [{ type: 'text', text:
            `<path>${entry.path}</path>\n<type>file</type>\n<content>\n1: FIRST\n\n(End of file - total 1 lines)\n</content>` }], meta: value, value }));
          assert.deepEqual(entry.readCalls, [{ layer: 'local', method: 'readText', input: { target }, originalPromiseReturned: true, outcome: { status: 'fulfilled', value: BEFORE } }]);
          entry.fileAfterRead = await snapshot(backing); assert.deepEqual(entry.fileAfterRead, entry.fileBefore);
          entry.independentReadVersion = version(entry.fileAfterRead, entry.grant); entry.readObservation = observed(entry.readId, entry.path, entry.independentReadVersion);
          entry.readPreludePassed = true;
        } else { entry.readPreludeNotApplicable = true; entry.fileAfterRead = await snapshot(backing); assert.deepEqual(entry.fileAfterRead, { exists: false }); }
        entry.fileBeforeWrite = await snapshot(backing); assert.deepEqual(entry.fileBeforeWrite, entry.fileBefore);
        caseStage = 'write-execute'; entry.writeId = 'write-' + entry.name; writeMark = observer.mark(); entry.writeCallStarted = true;
        nativeMark = wholeObserver.mark();
        entry.writeBatch = await ctx.tools.execute({ agent, calls: [{ id: entry.writeId, name: 'write', arguments: JSON.stringify(entry.arguments) }], signal: new AbortController().signal });
        entry.writeBatchReturned = true; entry.nativeWholeCalls = wholeObserver.since(nativeMark);
        if (entry.logical) { entry.nativeAfterWriteAwait = nativeStatus(); entry.borrowedAfterWriteAwait = fixture.fds.size;
          entry.nativeAfterWriteAwaitTiming = 'After actual ToolRuntime batch await, before Context.dispose; not instantaneous provider-return sampling';
          assert.equal(entry.nativeAfterWriteAwait.active, true); assert.equal(entry.nativeAfterWriteAwait.generation, grantRow.nativeGeneration);
          assert.equal(entry.nativeAfterWriteAwait.leases, 0); assert.equal(entry.borrowedAfterWriteAwait, 0); }
        entry.writeCalls = observer.since(writeMark); entry.targetEntered = entry.writeCalls.some(row => row.layer === 'local' && row.method === 'writeText' && row.input.target.targetKey === entry.path);
        if (!entry.targetEntered) { caseStage = 'target-not-reached'; throw Error('Expected public Local.writeText target was not reached'); }
        caseStage = 'write-result'; entry.fileAfterWrite = await snapshot(backing); assertFile(entry.fileAfterWrite, AFTER, entry.existing ? 0o644 : entry.expectedNewMode);
        if (!entry.existing) assert.equal(entry.fileAfterWrite.gid, entry.expectedNewGid);
        verifyWholeCalls(entry);
        entry.independentWriteVersion = version(entry.fileAfterWrite, entry.grant);
        if (entry.existing) assert.notEqual(entry.independentWriteVersion, entry.independentReadVersion);
        const operation = entry.existing ? 'update' : 'create', before = entry.existing ? BEFORE : null;
        const provider = { operation, version: entry.independentWriteVersion, before, after: AFTER };
        const input = { target, content: AFTER, intent: { present: false } };
        assert.deepEqual(entry.writeCalls, [
          { layer: 'sandbox', method: 'writeText', input: { ...input, policy: entry.policy }, originalPromiseReturned: true, outcome: { status: 'fulfilled', value: provider } },
          { layer: 'local', method: 'writeText', input, originalPromiseReturned: true, outcome: { status: 'fulfilled', value: provider } },
        ]);
        entry.actualWriteIntent = entry.writeCalls[1].input.intent; assert.deepEqual(entry.actualWriteIntent, { present: false });
        const value = { path: entry.path, operation, before, after: AFTER };
        const meta = { operation, path: entry.path, diffs: entry.existing ? [{ path: entry.path, oldText: 'FIRST', newText: 'SECOND' }] : [] };
        assert.deepEqual(entry.writeBatch, batch(entry.writeId, { isError: false, content: [{ type: 'text', text:
          `<path>${entry.path}</path>\n<type>file</type>\n<content>\n${entry.existing ? 'Updated' : 'Created'} file\n</content>` }], meta, value }));
        entry.writeObservation = observed(entry.writeId, entry.path, entry.independentWriteVersion);
        assert.equal(ctx.workingDirectory.get(session), directory); assert.equal(ctx.sessions.get(id), session);
        entry.completeOraclePassed = true;
      } catch (error) {
        entry[['setup', 'read-precondition', 'target-not-reached'].includes(caseStage) ? 'setupError' : 'unexpectedError'] = { stage: caseStage, ...failure(error) };
      } finally {
        if (readMark !== undefined && !entry.readCalls) entry.readCalls = observer.since(readMark);
        if (writeMark !== undefined && !entry.writeCalls) entry.writeCalls = observer.since(writeMark);
        if (nativeMark !== undefined && !entry.nativeWholeCalls) entry.nativeWholeCalls = wholeObserver.since(nativeMark);
        if (entry.writeCalls) entry.targetEntered = entry.writeCalls.some(row => row.layer === 'local' && row.method === 'writeText' && row.input.target.targetKey === entry.path);
        try { entry.fileAtCaseExit = await snapshot(backing); if (entry.fileAfterWrite) assert.deepEqual(entry.fileAtCaseExit, entry.fileAfterWrite); }
        catch (error) { entry.cleanupErrors.push({ stage: 'owned-file-readback', ...failure(error) }); }
        try { if (entry.defaultReferencePath) { entry.defaultReferenceAtExit = await snapshot(entry.defaultReferencePath);
          assert.deepEqual(entry.defaultReferenceAtExit, entry.defaultReference); } }
        catch (error) { entry.cleanupErrors.push({ stage: 'independent-default-reference-readback', ...failure(error) }); }

        try { if (ctx) { await ctx.fiber.dispose(); entry.contextDisposed = true; } }
        catch (error) { entry.cleanupErrors.push({ stage: 'context-dispose', ...failure(error) }); }
        if (entry.logical && grantRow) try { entry.nativeAfterContextDispose = nativeStatus(); entry.borrowedAfterContextDispose = fixture.fds.size;
          assert.equal(entry.nativeAfterContextDispose.active, true); assert.equal(entry.nativeAfterContextDispose.leases, 0);
          assert.equal(entry.nativeAfterContextDispose.generation, grantRow.nativeGeneration); assert.equal(entry.borrowedAfterContextDispose, 0); }
        catch (error) { entry.cleanupErrors.push({ stage: 'lease-after-context-dispose', ...failure(error) }); }
        entry.status = entry.cleanupErrors.length ? 'CLEANUP_FAILED' : entry.setupError ? 'SETUP_ERROR' : entry.unexpectedError ? 'UNEXPECTED_RESULT_STOP' :
          entry.completeOraclePassed && entry.contextDisposed ? 'PASS' : 'INCOMPLETE'; entry.pass = entry.status === 'PASS';
        entry.seconds = (performance.now() - started) / 1000; entry.ended = new Date().toISOString();
      }
      return entry.pass;
    }
    for (const index of [0, 1]) {
      const entry = report.cases[index], directory = cfg.physical[index], backing = join(directory, entry.filename);
      assert.deepEqual(await fs.readdir(directory), []);
      if (entry.existing) await fs.writeFile(backing, BEFORE, { flag: 'wx', mode: 0o644 });
      stage = entry.name; if (!await run(entry, directory, backing)) throw Error('Physical case did not pass; stop before logical setup');
    }
    stage = 'select-attach-setup';
    const { workspaceFixture, until } = await import(pathToFileURL(join(cfg.source, 'runtime/tests/ohos/authorized-workspaces-fixture.mjs')));
    fixture = await workspaceFixture({ after: cleanup => cleanups.push(cleanup) });
    const uri = 'file://docs/storage/Users/currentUser/Projects/whole-write-normal-after';
    const request = fixture.call(fixture, 'select', { userGesture: true }); await until(() => fixture.pickers.length === 1); fixture.select([uri]);
    const selected = await request.done; assert.equal(selected.error, undefined); const id = selected.value.workspaces[0].id;
    const attached = await fixture.call(fixture, 'attach', { id, userGesture: true }).done; assert.equal(attached.error, undefined);
    grantRow = attached.value.workspaces[0]; assert.equal(grantRow.id, id); assert.equal(grantRow.nativeGrant, 'ready');
    assert.equal(grantRow.candidatePath, new URL(uri).pathname); assert.equal(fixture.fds.size, 0);
    const backingRoot = fixture.uriPaths.get(uri); assert.deepEqual(await fs.readdir(backingRoot), []);
    await fs.writeFile(join(backingRoot, 'existing.txt'), BEFORE, { flag: 'wx', mode: 0o644 });
    assert.deepEqual(await snapshot(join(backingRoot, 'new.txt')), { exists: false });
    report.published = { logicalRoot: '/workspaces/' + id, normalFileUriPath: grantRow.candidatePath,
      chooserOptions: 'default workspaceFixture; no pathThrow/null hint', backingUse: 'owned fixture and independent readback only' };
    for (const index of [2, 3]) { const entry = report.cases[index]; stage = entry.name;
      if (!await run(entry, report.published.logicalRoot, join(backingRoot, entry.filename))) break; }
  } catch (error) { report[['setup', 'select-attach-setup'].includes(stage) ? 'setupError' : 'unexpectedError'] = { stage, ...failure(error) }; }
  finally {
    for (const entry of report.cases) if (entry.backing) try { entry.fileAtFinalTeardown = await snapshot(entry.backing);
      if (entry.fileAtCaseExit) assert.deepEqual(entry.fileAtFinalTeardown, entry.fileAtCaseExit); }
    catch (error) { report.cleanupErrors.push({ stage: 'final-file-readback', case: entry.name, ...failure(error) }); }
    try { if (report.hostWorkspacesBefore) { report.hostWorkspacesAfter = await hostRoot();
      assert.deepEqual(report.hostWorkspacesAfter, report.hostWorkspacesBefore); report.hostWorkspacesUnchanged = true; } }
    catch (error) { report.cleanupErrors.push({ stage: 'host-root-readback', ...failure(error) }); }
    try { fixture?.background(); if (grantRow) { report.nativeRetired = nativeStatus();
      assert.equal(report.nativeRetired.active, false); assert.equal(report.nativeRetired.leases, 0);
      assert.equal(report.nativeRetired.drained, true); assert.equal(fixture.fds.size, 0); } }
    catch (error) { report.cleanupErrors.push({ stage: 'final-ordinary-retirement', ...failure(error) }); }
    for (const cleanup of cleanups.reverse()) try { await cleanup(); } catch (error) { report.cleanupErrors.push({ stage: 'fixture-cleanup', ...failure(error) }); }
    try { observer?.restore(); report.publicMethodsRestored = true; } catch (error) { report.cleanupErrors.push({ stage: 'observer-restore', ...failure(error) }); }
    try { report.nativeWholeCalls = wholeObserver.all(); wholeObserver.restore(); report.nativeWholeMethodsRestored = true; }
    catch (error) { report.cleanupErrors.push({ stage: 'native-observer-restore', ...failure(error) }); }

    report.cleanupCompleted = report.cleanupErrors.length === 0 && report.cases.every(row => !row.cleanupErrors.length);
    report.writeBatchCount = report.cases.filter(row => row.writeBatchReturned).length;
    report.readBatchCount = report.cases.filter(row => row.readBatchReturned).length;
    report.pass = !report.setupError && !report.unexpectedError && report.cleanupCompleted && report.publicMethodsRestored &&
      report.nativeWholeMethodsRestored && report.cases.every(row => row.pass && row.completeOraclePassed && row.contextDisposed && row.targetEntered && row.nativeWholeOraclePassed) &&
      report.writeBatchCount === 4 && report.readBatchCount === 2 && report.hostWorkspacesUnchanged && report.noSeparateDirectMapping &&
      report.nativeRetired?.active === false && report.nativeRetired?.leases === 0 && report.nativeRetired?.drained === true;
    report.ended = new Date().toISOString(); await fs.writeFile(cfg.result, JSON.stringify(report, null, 2) + '\n');
  }
}
