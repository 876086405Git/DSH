// Four ordinary owned-file cases. Real API/Session/registry/FS, no range or codec.
import { isMainThread } from 'node:worker_threads';
if (isMainThread) {
  const assert = (await import('node:assert/strict')).default;
  const fs = await import('node:fs/promises');
  const { join } = await import('node:path');
  const { createRequire } = await import('node:module');
  const { pathToFileURL } = await import('node:url');
  const { createHash } = await import('node:crypto');
  const { observeWholeBytes, plainValue, errorValue } = await import('./workspace-whole-bytes-instrumentation.mjs');
  const config = JSON.parse(await fs.readFile(process.env.OHOS_321_WHOLE_BYTES_CONFIG, 'utf8'));
  const filename = 'byte-marker.bin', fullHex = '4142e4b8ade6968743440a';
  const fullBytes = Buffer.from(fullHex, 'hex');
  const names = ['physical-cap-11', 'physical-cap-10', 'logical-cap-11', 'logical-cap-10'];
  const report = { schema: 1, started: new Date().toISOString(),
    scope: 'Actual DSH bin/sole OH preload; real in-memory SessionStore/Session, registered workspaceFileScope resolver, WorkspaceFiles/SandboxedFileSystem/LocalFileSystem. Direct component API calls, not HTTP/RPC or Flutter. Production ETS chooser/plugin bodies with explicit SDK/Preferences and Native host fixtures. Four ordinary owned 11-byte reads; no range, codec, model, network, cancellation or permission scenario.',
    node: { version: process.version, platform: process.platform, architecture: process.arch },
    fixture: { filename, text: 'AB中文CD\n', bytes: 11, hex: fullHex, mode: 0o600 },
    cases: names.map((name, index) => ({ name, logical: index >= 2, maxFileBytes: index % 2 ? 10 : 11,
      status: 'BLOCKED_NOT_RUN', targetEntered: false, contractPassed: false, diagnosticVerified: false })),
    modules: [], cleanupErrors: [], privateStatObserved: false, newRuntimeGenerated: false, runtimeVersion: null };
  const failure = error => ({ ...errorValue(error), stack: error?.stack ?? null });
  function completeError(error) {
    return { stable: errorValue(error), ownPropertyNames: Object.getOwnPropertyNames(error).sort(),
      enumerable: plainValue(error), stack: error?.stack ?? null,
      cause: error?.cause === undefined ? null : completeError(error.cause) };
  }
  const require = createRequire(join(config.payload, 'package.json'));
  const load = async name => {
    const path = require.resolve('@deepseek-ai/' + name);
    report.modules.push({ name, path });
    return import(pathToFileURL(path));
  };
  const cleanups = [];
  let f, grantRow, observer, physicalMarker, logicalMarker, stage = 'setup';
  const nativeStatus = () => f.native.workspaceGrant('status', grantRow.nativeKey, grantRow.nativeGeneration);
  async function fileSnapshot(path) {
    const bytes = await fs.readFile(path), info = await fs.stat(path, { bigint: true });
    assert(info.isFile());
    return { bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex'), hex: bytes.toString('hex'),
      mode: Number(info.mode & 0o777n), exactStat: { dev: String(info.dev), ino: String(info.ino), size: String(info.size),
        mtimeNs: String(info.mtimeNs), ctimeNs: String(info.ctimeNs) } };
  }
  function independentVersion(snapshot, grant) {
    const x = snapshot.exactStat;
    if (!grant) return [x.dev, x.ino, x.size, x.mtimeNs, x.ctimeNs].join(':');
    const billion = 1000000000n, mt = BigInt(x.mtimeNs), ct = BigInt(x.ctimeNs);
    return ['ohos-grant', grant.id, String(grant.generation), x.dev, x.ino, x.size,
      String(mt / billion), String(mt % billion), String(ct / billion), String(ct % billion)].join(':');
  }
  async function createOwned(root) {
    assert.deepEqual(await fs.readdir(root), []);
    const marker = join(root, filename);
    await fs.writeFile(marker, fullBytes, { flag: 'wx', mode: 0o600 });
    const state = await fileSnapshot(marker);
    assert.equal(state.hex, fullHex); assert.equal(state.bytes, 11); assert.equal(state.mode, 0o600);
    return marker;
  }
  async function hostRoot() {
    try { const info = await fs.lstat('/workspaces'); return { exists: true, directory: info.isDirectory() }; }
    catch (error) { if (error.code === 'ENOENT') return { exists: false }; throw error; }
  }
  const fsError = (code, message) => ({ name: 'FsError', code, message, details: null, isDSHRemoteError: false, cause: null });
  const capError = (path, limit) => ({ name: 'RemoteError', code: 'workspace-file/too-large',
    message: `"${filename}" exceeds the ${limit} byte full-file cap`, details: { path: filename, limit },
    isDSHRemoteError: true,
    cause: fsError('FS_TOO_LARGE', `cannot read "${path}": 11 bytes exceeds the ${limit}-byte limit`) });
  try {
    assert.equal(fullBytes.length, 11); assert.equal(fullBytes.toString('utf8'), 'AB中文CD\n');
    assert.equal(process.argv[1], join(config.payload, 'node_modules/@deepseek-ai/dsh/lib/bin.js'));
    assert.equal(process.platform, 'openharmony');
    report.hostWorkspacesBefore = await hostRoot(); assert.equal(report.hostWorkspacesBefore.exists, false);
    assert.equal(globalThis[Symbol.for('dsh.go.direct')], undefined);
    report.noSeparateDirectMapping = true;
    assert.equal(typeof globalThis[Symbol.for('dsh.go.ohos.workspace-paths')]?.statFile, 'function');
    const [{ Context }, { Session, SessionStore }, { SystemPrompt }, { SessionProjectionRegistry },
      { SandboxPolicyService }, { SandboxedFileSystem }, { LocalFileSystem },
      { TypertRegistry }, { WorkspaceFiles }, { FsError }, { remoteErrorOf }] = await Promise.all([
      'cordis', 'dsh-session', 'dsh-system-prompt', 'dsh-session-projection', 'dsh-sandbox-policy',
      'dsh-fs-sandbox', 'dsh-fs-local', 'dsh-typert-registry', 'dsh-api-workspace-files', 'dsh-fs', 'dsh-typert-protocol',
    ].map(load));
    const { processWorkspaceGrant } = await import(pathToFileURL(join(config.payload, 'runtime/ohos/process/files/process-authority.mjs')));
    observer = observeWholeBytes(LocalFileSystem, WorkspaceFiles);
    physicalMarker = await createOwned(config.physical);

    async function run(entry, { directory, marker, logical = false }) {
      let ctx, targetMark, caseStage = 'setup';
      const began = performance.now(), path = join(directory, filename), limit = entry.maxFileBytes;
      Object.assign(entry, { started: new Date().toISOString(), cleanupErrors: [], targetAwaitSettled: false,
        path, physicalMarker: marker, invocation: 'direct-real-api-service', privateReadWholeBytesObserved: false });
      try {
        ctx = new Context();
        await ctx.plugin(SystemPrompt, {});
        await ctx.plugin(SessionProjectionRegistry);
        await ctx.plugin(TypertRegistry);
        await ctx.plugin(SessionStore);
        await ctx.plugin(SandboxPolicyService, { mode: 'read-only', workspaceRoot: directory });
        await ctx.plugin(SandboxedFileSystem, { cwd: directory });
        await ctx.plugin(WorkspaceFiles, { maxFileBytes: limit });
        entry.services = { fs: ctx.fs.constructor.name, policy: ctx.sandboxPolicy.constructor.name,
          sessions: ctx.sessions.constructor.name, typert: ctx.typert.constructor.name,
          workspaceFiles: ctx.workspaceFiles.constructor.name, mode: ctx.fs.sandboxMode };
        assert.deepEqual(entry.services, { fs: 'SandboxedFileSystem', policy: 'SandboxPolicyService',
          sessions: 'SessionStore', typert: 'TypertRegistry', workspaceFiles: 'WorkspaceFiles', mode: 'read-only' });
        assert.equal(ctx.workspaceFiles.config.maxFileBytes, limit);
        const id = '321-' + entry.name;
        const session = ctx.sessions.create(id, { meta: { cwd: directory } });
        assert(session instanceof Session); assert.equal(ctx.sessions.get(id), session); assert.equal(session.header.cwd, directory);
        entry.session = { id, type: session.constructor.name, headerCwd: session.header.cwd,
          store: 'actual in-memory SessionStore', persistence: false };
        const resolver = ctx.typert.lookups.get('workspaceFileScope');
        assert.equal(typeof resolver?.resolve, 'function');
        assert.equal(resolver.wire, 'workspaceFileScopeId'); assert.equal(resolver.resource, 'session');
        const scope = await resolver.resolve(id);
        assert.deepEqual(scope, { sessionId: id, workspaceRoot: directory });
        entry.lookup = { key: 'workspaceFileScope', wire: resolver.wire, resource: resolver.resource, resolved: scope };
        entry.policy = ctx.sandboxPolicy.resolve({ session });
        assert.equal(entry.policy.mode, 'read-only'); assert.equal(entry.policy.workspaceRoot, directory);
        entry.fileBefore = await fileSnapshot(marker);
        assert.equal(entry.fileBefore.hex, fullHex); assert.equal(entry.fileBefore.bytes, 11); assert.equal(entry.fileBefore.mode, 0o600);
        if (logical) {
          entry.grant = processWorkspaceGrant(directory);
          entry.nativeBefore = nativeStatus();
          assert.equal(entry.nativeBefore.active, true); assert.equal(entry.nativeBefore.leases, 0); assert.equal(f.fds.size, 0);
        }
        entry.independentVersion = independentVersion(entry.fileBefore, entry.grant);
        entry.versionOracleSource = 'Owned backing fs.stat({bigint:true}) dev/ino/size/mtimeNs/ctimeNs and actual processWorkspaceGrant identity, independent of provider stat';
        entry.arguments = { workspaceFileScopeId: id, path: filename, options: {}, maxFileBytes: limit };
        entry.expectedSuccess = { absolutePath: path, version: entry.independentVersion, bytes: 11, offset: 0, data: [...fullBytes], eof: true };
        entry.expectedCapError = capError(path, limit);
        entry.oldLogicalFailurePrediction = fsError('FS_NOT_FOUND', `cannot read "${path}": not found`);
        const signal = new AbortController().signal;
        caseStage = 'prelude-stat';
        const preludeMark = observer.mark();
        const prelude = await ctx.workspaceFiles.stat(scope, filename, signal);
        entry.preludeActual = plainValue(prelude);
        entry.preludeCalls = observer.since(preludeMark);
        const expectedStat = { absolutePath: path, version: entry.independentVersion, bytes: 11 };
        assert.deepEqual(prelude, expectedStat);
        assert.deepEqual(entry.preludeCalls, [
          { layer: 'api', method: 'stat', input: { scope: { sessionId: id, workspaceRoot: directory }, path: filename },
            originalPromiseReturned: true, outcome: { status: 'fulfilled', value: expectedStat } },
          { layer: 'provider', method: 'stat', input: { target: { displayPath: path, targetKey: path } },
            originalPromiseReturned: true, outcome: { status: 'fulfilled', value: { version: entry.independentVersion, type: 'file', size: 11 } } },
        ]);
        entry.preludePassed = true;
        entry.fileAfterPrelude = await fileSnapshot(marker); assert.deepEqual(entry.fileAfterPrelude, entry.fileBefore);
        if (logical) {
          entry.nativeBeforeTarget = nativeStatus();
          assert.equal(entry.nativeBeforeTarget.active, true); assert.equal(entry.nativeBeforeTarget.leases, 0); assert.equal(f.fds.size, 0);
        }
        caseStage = 'target-call'; targetMark = observer.mark();
        let actual, rejection;
        entry.targetCallStarted = true;
        try {
          // The production registered resolver's exact scope; no range/baseFile.
          actual = await ctx.workspaceFiles.readBytes(scope, filename, {}, signal);
          entry.targetReturned = true;
        } catch (error) {
          rejection = error; entry.targetRejected = true;
          entry.actualError = completeError(error);
        }
        entry.targetAwaitSettled = true; entry.targetAwaitSettledAt = new Date().toISOString();
        if (logical) {
          // A sample after the real target await, before assertions and disposal.
          entry.nativeAfterTargetAwaitTiming = 'after actual readBytes await settles; before assertions and Context.fiber.dispose';
          entry.nativeAfterTargetAwait = nativeStatus(); entry.borrowedFDsAfterTargetAwait = f.fds.size;
          assert.equal(entry.nativeAfterTargetAwait.active, true); assert.equal(entry.nativeAfterTargetAwait.leases, 0);
          assert.equal(entry.borrowedFDsAfterTargetAwait, 0);
        }
        entry.publicCalls = observer.since(targetMark);
        entry.targetEntryCount = entry.publicCalls.filter(x => x.layer === 'api' && x.method === 'readBytes').length;
        entry.providerEntryCount = entry.publicCalls.filter(x => x.layer === 'provider' && x.method === 'readBytes').length;
        entry.targetEntered = entry.targetEntryCount === 1;
        entry.readByteRangeEntered = entry.publicCalls.some(x => x.method === 'readByteRange');
        assert.equal(entry.targetEntryCount, 1); assert.equal(entry.providerEntryCount, 1); assert.equal(entry.readByteRangeEntered, false);
        assert(!entry.publicCalls.some(x => x.observationError));
        caseStage = 'complete-contract';
        let apiOutcome, providerOutcome;
        if (rejection === undefined) {
          entry.rawResultJSON = JSON.parse(JSON.stringify(actual));
          entry.dataIsUint8Array = actual?.data instanceof Uint8Array;
          entry.dataIsBuffer = Buffer.isBuffer(actual?.data);
          entry.result = plainValue(actual);
          assert.equal(limit, 11, 'The 10-byte whole-file cap must reject this 11-byte ordinary file');
          assert.equal(Object.getPrototypeOf(actual), Object.prototype);
          assert.deepEqual(Reflect.ownKeys(actual).sort(), ['absolutePath', 'bytes', 'data', 'eof', 'offset', 'version']);
          assert.equal(entry.dataIsUint8Array, true);
          assert.deepEqual(entry.result, entry.expectedSuccess);
          assert.equal(Buffer.from(actual.data).toString('hex'), fullHex);
          apiOutcome = { status: 'fulfilled', value: entry.expectedSuccess };
          providerOutcome = { status: 'fulfilled', value: [...fullBytes] };
          entry.status = 'PASS_FULL_BYTES'; entry.contractPassed = true;
        } else if (remoteErrorOf(rejection)?.code === 'workspace-file/too-large') {
          assert.equal(limit, 10);
          assert.deepEqual(errorValue(rejection), entry.expectedCapError);
          assert.deepEqual(Object.getOwnPropertyNames(rejection).sort(), ['cause', 'code', 'details', 'isDSHRemoteError', 'message', 'name', 'stack']);
          assert.deepEqual(Object.getOwnPropertyNames(rejection.cause).sort(), ['code', 'message', 'name', 'stack']);
          assert(rejection.cause instanceof FsError);
          apiOutcome = { status: 'rejected', error: entry.expectedCapError };
          providerOutcome = { status: 'rejected', error: entry.expectedCapError.cause };
          entry.status = 'PASS_CAP_REFUSAL'; entry.contractPassed = true;
        } else if (logical && rejection instanceof FsError && rejection.code === 'FS_NOT_FOUND') {
          assert.deepEqual(errorValue(rejection), entry.oldLogicalFailurePrediction);
          assert.deepEqual(Object.getOwnPropertyNames(rejection).sort(), ['code', 'message', 'name', 'stack']);
          apiOutcome = providerOutcome = { status: 'rejected', error: entry.oldLogicalFailurePrediction };
          entry.status = 'BEHAVIOR_RED_READ_BYTES'; entry.contractPassed = false;
          entry.errorAttribution = { observed: 'Public provider readBytes and public WorkspaceFiles.readBytes rejected FS_NOT_FOUND',
            sourceInference: 'Pinned Local.readBytes calls readWholeBytes, whose initial host stat rejects absent logical host path before the byte-cap branch; private helper was not instrumented',
            sourceSHA256: config.fsLocalSha256, capBranchReached: 'not instrumented; source order implies no' };
        } else throw rejection;
        const expectedCalls = [
          { layer: 'api', method: 'readBytes', input: { scope: { sessionId: id, workspaceRoot: directory }, path: filename, options: {}, maxFileBytes: limit },
            originalPromiseReturned: true, outcome: apiOutcome },
          { layer: 'provider', method: 'stat', input: { target: { displayPath: path, targetKey: path } },
            originalPromiseReturned: true, outcome: { status: 'fulfilled', value: { version: entry.independentVersion, type: 'file', size: 11 } } },
          { layer: 'provider', method: 'readBytes', input: { target: { displayPath: path, targetKey: path }, maxBytes: limit },
            originalPromiseReturned: true, outcome: providerOutcome },
        ];
        assert.deepEqual(entry.publicCalls, expectedCalls);
        assert.equal(ctx.sessions.get(id), session); assert.equal(session.header.cwd, directory);
        entry.completeObjectAndCallsVerified = true; entry.diagnosticVerified = true;
      } catch (error) {
        entry[['setup', 'prelude-stat'].includes(caseStage) ? 'setupError' : 'unexpectedError'] = { stage: caseStage, ...failure(error) };
        entry.status = ['setup', 'prelude-stat'].includes(caseStage) ? 'SETUP_ERROR' : 'UNEXPECTED_RESULT_STOP';
        entry.contractPassed = false; entry.diagnosticVerified = false;
      } finally {
        if (targetMark !== undefined) entry.publicCalls = observer.since(targetMark);
        if (entry.fileBefore) try {
          entry.fileAfterTargetAwait = await fileSnapshot(marker);
          assert.deepEqual(entry.fileAfterTargetAwait, entry.fileBefore); entry.fileUnchanged = true;
        } catch (error) { entry.cleanupErrors.push({ stage: 'file-after-target-readback', ...failure(error) }); }
        try { if (ctx) { await ctx.fiber.dispose(); entry.contextDisposed = true; } }
        catch (error) { entry.cleanupErrors.push({ stage: 'context-dispose', ...failure(error) }); }
        if (logical) try {
          entry.nativeAfterContextDisposeTiming = 'after awaited Context.fiber.dispose; separate from target-await sample';
          entry.nativeAfterContextDispose = nativeStatus(); entry.borrowedFDsAfterContextDispose = f.fds.size;
          assert.equal(entry.nativeAfterContextDispose.active, true); assert.equal(entry.nativeAfterContextDispose.leases, 0);
          assert.equal(entry.borrowedFDsAfterContextDispose, 0);
        } catch (error) { entry.cleanupErrors.push({ stage: 'lease-after-context-dispose', ...failure(error) }); }
        if (entry.cleanupErrors.length) { entry.status = 'CLEANUP_FAILED'; entry.diagnosticVerified = false; entry.contractPassed = false; }
        entry.milliseconds = performance.now() - began; entry.ended = new Date().toISOString();
      }
      return entry;
    }
    stage = 'physical-cap-11';
    await run(report.cases[0], { directory: config.physical, marker: physicalMarker });
    if (!report.cases[0].contractPassed || !report.cases[0].diagnosticVerified) throw Error('Physical full-read positive control not verified; stop');
    stage = 'physical-cap-10';
    await run(report.cases[1], { directory: config.physical, marker: physicalMarker });
    if (!report.cases[1].contractPassed || !report.cases[1].diagnosticVerified) throw Error('Physical cap-refusal control not verified; stop');
    stage = 'select-attach-setup';
    const { workspaceFixture, until } = await import(pathToFileURL(join(config.source, 'runtime/tests/ohos/authorized-workspaces-fixture.mjs')));
    f = await workspaceFixture({ after: cleanup => cleanups.push(cleanup) });
    const uri = 'file://docs/storage/Users/currentUser/Projects/321-normal-whole-bytes';
    const request = f.call(f, 'select', { userGesture: true });
    await until(() => f.pickers.length === 1); f.select([uri]);
    const selected = await request.done; assert.equal(selected.error, undefined);
    const id = selected.value.workspaces[0].id;
    const attached = await f.call(f, 'attach', { id, userGesture: true }).done;
    assert.equal(attached.error, undefined); grantRow = attached.value.workspaces[0];
    assert.equal(grantRow.id, id); assert.equal(grantRow.nativeGrant, 'ready'); assert.equal(f.fds.size, 0);
    assert.equal(typeof grantRow.candidatePath, 'string');
    assert.equal(grantRow.candidatePath, new URL(uri).pathname);
    logicalMarker = await createOwned(f.uriPaths.get(uri));
    report.published = { logicalRoot: '/workspaces/' + id, nativeGrant: grantRow.nativeGrant,
      normalFileUriPath: grantRow.candidatePath, borrowedFDs: f.fds.size, nativeBefore: nativeStatus(),
      chooserOptions: 'default workspaceFixture options, no pathThrow or null-hint', backingUse: 'fixture creation and independent readback only' };
    for (const index of [2, 3]) {
      stage = names[index];
      await run(report.cases[index], { directory: report.published.logicalRoot, marker: logicalMarker, logical: true });
      if (!report.cases[index].diagnosticVerified) break; // A known complete product red may continue; unexpected/setup stops.
    }
  } catch (error) {
    report[['setup', 'select-attach-setup'].includes(stage) ? 'setupError' : 'unexpectedError'] = { stage, ...failure(error) };
  } finally {
    for (const entry of report.cases) {
      if (!entry.fileBefore) continue;
      try { entry.fileAtFinalTeardown = await fileSnapshot(entry.physicalMarker);
        assert.deepEqual(entry.fileAtFinalTeardown, entry.fileBefore); }
      catch (error) { report.cleanupErrors.push({ stage: 'final-owned-file-readback', case: entry.name, ...failure(error) }); }
    }
    try {
      report.hostWorkspacesAfter = await hostRoot();
      assert.deepEqual(report.hostWorkspacesAfter, report.hostWorkspacesBefore); report.hostWorkspacesUnchanged = true;
    } catch (error) { report.cleanupErrors.push({ stage: 'host-root-readback', ...failure(error) }); }
    try {
      f?.background();
      if (grantRow) {
        report.nativeRetiredTiming = 'after all target cases, during ordinary final fixture background; no request after retirement';
        report.nativeRetired = nativeStatus();
        assert.equal(report.nativeRetired.active, false); assert.equal(report.nativeRetired.leases, 0);
        assert.equal(report.nativeRetired.drained, true); assert.equal(f.fds.size, 0);
      }
    } catch (error) { report.cleanupErrors.push({ stage: 'native-retirement', ...failure(error) }); }
    for (const cleanup of cleanups.reverse()) {
      try { await cleanup(); } catch (error) { report.cleanupErrors.push({ stage: 'fixture-cleanup', ...failure(error) }); }
    }
    try { observer?.restore(); report.publicMethodsRestored = true; }
    catch (error) { report.cleanupErrors.push({ stage: 'observer-restore', ...failure(error) }); }
    report.cleanupCompleted = report.cleanupErrors.length === 0 && report.cases.every(x => !x.cleanupErrors?.length);
    report.targetCallCount = report.cases.filter(x => x.targetEntered).length;
    report.contractPassCount = report.cases.filter(x => x.contractPassed).length;
    report.behaviorRedCount = report.cases.filter(x => x.status === 'BEHAVIOR_RED_READ_BYTES').length;
    report.diagnosticVerified = !report.setupError && !report.unexpectedError && report.cleanupCompleted &&
      report.cases.every(x => x.diagnosticVerified && x.completeObjectAndCallsVerified && x.fileUnchanged && x.contextDisposed) &&
      report.targetCallCount === 4 && report.publicMethodsRestored && report.noSeparateDirectMapping && report.hostWorkspacesUnchanged &&
      report.nativeRetired?.active === false && report.nativeRetired?.leases === 0 && report.nativeRetired?.drained === true;
    report.pass = report.diagnosticVerified && report.contractPassCount === 4;
    report.ended = new Date().toISOString();
    await fs.writeFile(config.result, JSON.stringify(report, null, 2) + '\n');
  }
}
