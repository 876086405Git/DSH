// Two controlled ordinary staging cancellations; source preparation only in388.
import { isMainThread } from 'node:worker_threads';
if (isMainThread) {
  const assert = (await import('node:assert/strict')).default;
  const fs = await import('node:fs/promises');
  const sync = await import('node:fs');
  const { join, dirname } = await import('node:path');
  const { createRequire } = await import('node:module');
  const { pathToFileURL } = await import('node:url');
  const { createHash } = await import('node:crypto');
  const { observeWrite, errorValue, wholeObserver, bytesIdentity } = await import('./workspace-write-cancel-instrumentation.mjs');
  const cfg = JSON.parse(await fs.readFile(process.env.OHOS_WRITE_CANCEL_CONFIG, 'utf8'));
  const oracle = JSON.parse(await fs.readFile(cfg.oracle, 'utf8'));
  const BEFORE = 'FIRST\n', AFTER = 'A'.repeat(1048576) + '\n';
  const body = Buffer.from(AFTER), bodyIdentity = bytesIdentity(body);
  const report = { schema: 1, started: new Date().toISOString(), mode: 'controlled-staging-cancellation',
    scope: 'Real DSH sole preload, SessionStore/Session, registered default read/write, Sandbox/Local and paired Native. A transparent Native observation schedules one normal caller AbortController request after the first real positive staging write. Agent carrier, SDK chooser/Preferences and host carrier are fixtures. No guarded copy, failure injection, full Host, UI, phone or VM.',
    cases: oracle.cases.map(row => ({ ...row, status: 'BLOCKED_NOT_RUN', pass: false, targetEntered: false, cleanupErrors: [] })),
    observations: [], modules: [], cleanupErrors: [], runtimeVersion: null, privateProbeObserved: false, body: bodyIdentity, bodyRule: oracle.bodyRule };
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
    assert.equal(calls.length, 3);
    const leaseId = calls[0].input.leaseId;
    assert(Number.isInteger(leaseId) && leaseId > 0);
    assert.deepEqual(calls[0], { method: 'beginWholeOutput', input: { leaseId, relative: entry.filename,
      policy: entry.existing ? 0 : 1, priorMode: entry.existing ? 0o644 : 0, createIfAbsent: false },
      outcome: { status: 'returned', value: 1 } });
    const count = calls[1].outcome.value;
    assert(Number.isInteger(count) && count > 0 && count <= 1048576 && count < body.length);
    assert.deepEqual(calls[1], { method: 'writeWholeOutput', input: { leaseId, content: bytesIdentity(body.subarray(0, 1048576)) },
      outcome: { status: 'returned', value: count } });
    assert.deepEqual(calls[2], { method: 'abortWholeOutput', input: { leaseId }, outcome: { status: 'returned', value: 1 } });
    assert.equal(entry.cancel.trace.scheduled, true); assert.equal(entry.cancel.trace.fired, true);
    assert.equal(entry.cancel.trace.observationError, undefined);
    const methods = ['beginWholeOutput', 'writeWholeOutput'];
    assert.deepEqual(entry.cancel.trace.trigger, { leaseId, requested: bytesIdentity(body.subarray(0, 1048576)),
      returnedBytes: count, nativeMethodsAfterReturn: methods });
    assert.deepEqual(entry.cancel.trace.nativeMethodsAtCallback, methods);
    assert.equal(entry.cancel.beforeAborted, false); assert.equal(entry.cancel.afterAborted, true);
    assert.equal(entry.cancel.callback, 'node:timers.setImmediate after real positive native return');
    assert.equal(entry.cancel.batchReturnedAtRequest, false);
    assert.equal(entry.cancel.providersPendingAtRequest, true);
    assert.equal(entry.cancel.observationError, undefined);
    assert.deepEqual(entry.cancel.reason, oracle.abortReason);
    assert.deepEqual(entry.cancel.targetBeforeAbort, entry.fileBefore);
    assert.equal(entry.cancel.nativeBeforeAbort.active, true);
    assert.equal(entry.cancel.nativeBeforeAbort.generation, entry.nativeBefore.generation);
    assert.equal(entry.cancel.nativeBeforeAbort.leases, 1);
    assert.equal(entry.cancel.borrowedBeforeAbort, 0);
    const staged = entry.cancel.staging;
    assert.match(staged.name, /^\.dsh-edit-[0-9a-f]{32}$/);
    assert.equal(staged.directory, join(dirname(entry.backing), staged.name));
    assert.equal(staged.directoryFact.isDirectory, true); assert.equal(staged.directoryFact.mode & 0o777, 0o700);
    assert.deepEqual(staged.children, ['content']); assert.equal(staged.file, join(staged.directory, 'content'));
    assert.equal(staged.content.isFile, true); assert.equal(staged.content.bytes, count);
    assert.equal(staged.content.exactStat.size, String(count));
    assert.equal(staged.content.sha256, bytesIdentity(body.subarray(0, count)).sha256);
    assert.deepEqual(staged.parentEntries, [...entry.parentBefore, staged.name].sort());
    assert.equal(entry.stagingAbsentAfterAwait, true);
    assert.deepEqual(entry.parentAfterAwait, entry.parentBefore);
    entry.nativeWholeOraclePassed = true;
    entry.nativeWholeCoverage = { phase: 'after first positive real staging write; before second write, closeStage or publication',
      writtenBytes: count, remainingBodyBytes: body.length - count, publicationCalls: 0,
      guardedWx: 'NOT_MEASURED', boundedCopy: 'NOT_MEASURED', effect1: 'NOT_MEASURED', cleanupFailure: 'NOT_MEASURED' };
  }
  function snapshotSync(path) {
    let info; try { info = sync.lstatSync(path, { bigint: true }); }
    catch (error) { if (error.code === 'ENOENT') return { exists: false }; throw error; }
    assert(info.isFile()); const bytes = sync.readFileSync(path);
    return { exists: true, bytes: bytes.length, hex: bytes.toString('hex'), sha256: bytesIdentity(bytes).sha256,
      mode: Number(info.mode & 0o777n), gid: String(info.gid), exactStat: { dev: String(info.dev), ino: String(info.ino), size: String(info.size),
        mtimeNs: String(info.mtimeNs), ctimeNs: String(info.ctimeNs) } };
  }
  function stagingSnapshot(entry, count) {
    const parent = dirname(entry.backing), entries = sync.readdirSync(parent).sort();
    const added = entries.filter(name => !entry.parentBefore.includes(name));
    assert.equal(added.length, 1); assert.match(added[0], /^\.dsh-edit-[0-9a-f]{32}$/);
    const directory = join(parent, added[0]), info = sync.lstatSync(directory, { bigint: true });
    assert(info.isDirectory()); const children = sync.readdirSync(directory).sort(); assert.deepEqual(children, ['content']);
    const file = join(directory, 'content'), stat = sync.lstatSync(file, { bigint: true }); assert(stat.isFile());
    assert.equal(stat.size, BigInt(count)); const bytes = sync.readFileSync(file);
    assert.deepEqual(bytes, body.subarray(0, count));
    return { name: added[0], directory, directoryFact: { isDirectory: true, mode: Number(info.mode & 0o7777n),
      dev: String(info.dev), ino: String(info.ino) }, parentEntries: entries, children, file,
      content: { isFile: true, ...bytesIdentity(bytes), mode: Number(stat.mode & 0o7777n), gid: String(stat.gid),
        exactStat: { dev: String(stat.dev), ino: String(stat.ino), size: String(stat.size), mtimeNs: String(stat.mtimeNs), ctimeNs: String(stat.ctimeNs) } } };
  }
  try {
    assert.equal(wholeObserver.mark(), 0);
    report.nativeWholeGroup = 'WHOLE_WRITE_ABI_V1'; report.unmeasured = oracle.notCovered;
    assert.equal(oracle.before, BEFORE); assert.equal(oracle.existingMode, 0o644);
    assert.deepEqual(oracle.body, bodyIdentity);
    assert.deepEqual(oracle.bodyRule, { encoding: 'utf8', prefix: 'A', repeat: 1048576, suffixByte: 10 });
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
      entry.arguments = { file_path: entry.filename, content: bodyIdentity }; entry.toolConfig = { applyPatch: false };
      const actualArguments = { file_path: entry.filename, content: AFTER };
      entry.observationPolicy = 'Not mounted; write intent is naturally absent, never handwritten.';
      try {
        entry.fileBefore = await snapshot(backing);
        if (entry.existing) assertFile(entry.fileBefore, BEFORE, 0o644); else assert.deepEqual(entry.fileBefore, { exists: false });

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
        const id = 'whole-cancel-' + entry.name; session = ctx.sessions.create(id, { meta: { cwd: directory } });
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
        entry.parentBefore = (await fs.readdir(dirname(backing))).sort();
        assert(entry.parentBefore.every(name => !name.startsWith('.dsh-edit-')));
        const controller = new AbortController(), reason = new Error(oracle.abortReason.message);
        entry.cancel = { callback: 'node:timers.setImmediate after real positive native return', reason: errorValue(reason) };
        entry.cancel.trace = wholeObserver.arm(controller.signal, trigger => {
          entry.cancel.beforeAborted = controller.signal.aborted;
          entry.cancel.batchReturnedAtRequest = entry.writeBatchReturned === true;
          entry.cancel.providersPendingAtRequest = observer.since(writeMark).length === 2 && observer.since(writeMark).every(row => row.outcome === undefined);
          try {
            assert.equal(controller.signal.aborted, false);
            assert(trigger.returnedBytes > 0 && trigger.returnedBytes <= 1048576 && trigger.returnedBytes < body.length);
            entry.cancel.targetBeforeAbort = snapshotSync(backing);
            entry.cancel.staging = stagingSnapshot(entry, trigger.returnedBytes);
            entry.cancel.nativeBeforeAbort = nativeStatus(); entry.cancel.borrowedBeforeAbort = fixture.fds.size;
          } catch (error) { entry.cancel.observationError = failure(error); }
          finally { controller.abort(reason); entry.cancel.afterAborted = controller.signal.aborted; }
        });
        entry.writeBatch = await ctx.tools.execute({ agent, calls: [{ id: entry.writeId, name: 'write', arguments: JSON.stringify(actualArguments) }], signal: controller.signal });
        entry.writeBatchReturned = true; entry.nativeWholeCalls = wholeObserver.since(nativeMark);
        wholeObserver.disarm();
        if (entry.logical) { entry.nativeAfterWriteAwait = nativeStatus(); entry.borrowedAfterWriteAwait = fixture.fds.size;
          entry.nativeAfterWriteAwaitTiming = 'After actual ToolRuntime batch await, before Context.dispose; not instantaneous provider-return sampling';
          assert.equal(entry.nativeAfterWriteAwait.active, true); assert.equal(entry.nativeAfterWriteAwait.generation, grantRow.nativeGeneration);
          assert.equal(entry.nativeAfterWriteAwait.leases, 0); assert.equal(entry.borrowedAfterWriteAwait, 0); }
        entry.writeCalls = observer.since(writeMark); entry.targetEntered = entry.writeCalls.some(row => row.layer === 'local' && row.method === 'writeText' && row.input.target.targetKey === entry.path);
        if (!entry.targetEntered) { caseStage = 'target-not-reached'; throw Error('Expected public Local.writeText target was not reached'); }
        caseStage = 'write-result';
        entry.fileAfterWrite = await snapshot(backing); assert.deepEqual(entry.fileAfterWrite, entry.fileBefore);
        entry.parentAfterAwait = (await fs.readdir(dirname(backing))).sort();
        entry.stagingAbsentAfterAwait = entry.parentAfterAwait.every(name => !name.startsWith('.dsh-edit-'));
        verifyWholeCalls(entry);
        entry.independentAfterVersion = entry.existing ? version(entry.fileAfterWrite, entry.grant) : null;
        if (entry.existing) assert.equal(entry.independentAfterVersion, entry.independentReadVersion);
        const input = { target, content: bodyIdentity, intent: { present: false }, signalAtEntry: { aborted: false, originalCaller: true } };
        const outcome = { status: 'rejected', error: oracle.providerError };
        assert.deepEqual(entry.writeCalls, [
          { layer: 'sandbox', method: 'writeText', input: { ...input, policy: entry.policy }, originalPromiseReturned: true, outcome },
          { layer: 'local', method: 'writeText', input, originalPromiseReturned: true, outcome },
        ]);
        entry.actualWriteIntent = entry.writeCalls[1].input.intent; assert.deepEqual(entry.actualWriteIntent, { present: false });
        assert.deepEqual(entry.writeBatch, batch(entry.writeId, oracle.toolResult));
        entry.mutationObservations = report.observations.filter(row => row.callId === entry.writeId);
        assert.deepEqual(entry.mutationObservations, []);
        assert.equal(ctx.workingDirectory.get(session), directory); assert.equal(ctx.sessions.get(id), session);
        entry.completeOraclePassed = true;
      } catch (error) {
        entry[['setup', 'read-precondition', 'target-not-reached'].includes(caseStage) ? 'setupError' : 'unexpectedError'] = { stage: caseStage, ...failure(error) };
      } finally {
        wholeObserver.disarm();
        if (readMark !== undefined && !entry.readCalls) entry.readCalls = observer.since(readMark);
        if (writeMark !== undefined && !entry.writeCalls) entry.writeCalls = observer.since(writeMark);
        if (nativeMark !== undefined && !entry.nativeWholeCalls) entry.nativeWholeCalls = wholeObserver.since(nativeMark);
        if (entry.writeCalls) entry.targetEntered = entry.writeCalls.some(row => row.layer === 'local' && row.method === 'writeText' && row.input.target.targetKey === entry.path);
        try { entry.fileAtCaseExit = await snapshot(backing); if (entry.fileAfterWrite) assert.deepEqual(entry.fileAtCaseExit, entry.fileAfterWrite); }
        catch (error) { entry.cleanupErrors.push({ stage: 'owned-file-readback', ...failure(error) }); }
        try { entry.parentAtCaseExit = (await fs.readdir(dirname(backing))).sort();
          if (entry.parentBefore) assert.deepEqual(entry.parentAtCaseExit, entry.parentBefore); }
        catch (error) { entry.cleanupErrors.push({ stage: 'owned-staging-readback', ...failure(error) }); }

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
    stage = 'select-attach-setup';
    const { workspaceFixture, until } = await import(pathToFileURL(join(cfg.source, 'runtime/tests/ohos/authorized-workspaces-fixture.mjs')));
    fixture = await workspaceFixture({ after: cleanup => cleanups.push(cleanup) });
    const uri = 'file://docs/storage/Users/currentUser/Projects/whole-write-staging-cancel';
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
    for (const index of [0, 1]) { const entry = report.cases[index]; stage = entry.name;
      if (!await run(entry, report.published.logicalRoot, join(backingRoot, entry.filename))) break; }
  } catch (error) { report[['setup', 'select-attach-setup'].includes(stage) ? 'setupError' : 'unexpectedError'] = { stage, ...failure(error) }; }
  finally {
    for (const entry of report.cases) if (entry.backing) try { entry.fileAtFinalTeardown = await snapshot(entry.backing);
      if (entry.fileAtCaseExit) assert.deepEqual(entry.fileAtFinalTeardown, entry.fileAtCaseExit);
      entry.parentAtFinalTeardown = (await fs.readdir(dirname(entry.backing))).sort();
      if (entry.parentBefore) assert.deepEqual(entry.parentAtFinalTeardown, entry.parentBefore); }
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
      report.writeBatchCount === 2 && report.readBatchCount === 1 && report.hostWorkspacesUnchanged && report.noSeparateDirectMapping &&
      report.nativeRetired?.active === false && report.nativeRetired?.leases === 0 && report.nativeRetired?.drained === true;
    report.ended = new Date().toISOString(); await fs.writeFile(cfg.result, JSON.stringify(report, null, 2) + '\n');
  }
}
