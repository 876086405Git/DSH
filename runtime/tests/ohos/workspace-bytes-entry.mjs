// Exactly two ordinary 11-byte file windows; direct actual service components.
// SDK chooser/Preferences are explicit fixtures, not phone or RPC execution.
import { isMainThread } from 'node:worker_threads';
if (isMainThread) {
  const assert = (await import('node:assert/strict')).default;
  const fs = await import('node:fs/promises');
  const { join } = await import('node:path');
  const { createRequire } = await import('node:module');
  const { pathToFileURL } = await import('node:url');
  const { createHash } = await import('node:crypto');
  const { observeBytesCalls } = await import('./workspace-bytes-instrumentation.mjs');
  const config = JSON.parse(await fs.readFile(process.env.OHOS_939_BYTES_CONFIG, 'utf8'));
  const names = ['physical-workspace-byte-window', 'selected-logical-workspace-byte-window'];
  const filename = 'byte-marker.txt';
  // Independent literal oracle: no slicing the target's result or decoder fallback.
  const wholeHex = '4142e4b8ade6968743440a';
  const windowHex = 'e4b8ade69687';
  const windowBytes = Object.freeze([0xe4, 0xb8, 0xad, 0xe6, 0x96, 0x87]);
  const range = Object.freeze({ offset: 2, length: 6 });
  const report = {
    schema: 1,
    scope: 'Actual DSH bin/sole preload; real WorkspaceFiles.stat then readBytes(range), registered workspaceFileScope resolver, in-memory SessionStore/Session, SandboxedFileSystem and read-only policy. SDK chooser/Preferences fixtures. No full Host/RPC, Dart, UI, persistent Session, device, whole-file readBytes, multiple windows or extra scenarios.',
    started: new Date().toISOString(),
    fixedOracle: { filename, utf8Text: 'AB中文CD\n', wholeHex, wholeBytes: 11,
      range, dataHex: windowHex, data: windowBytes, dataBytes: 6, eof: false, mode: 0o600 },
    cases: names.map(name => ({ name, status: 'BLOCKED', pass: false,
      preludePassed: false, targetCallStarted: false, targetEntered: false,
      targetReturned: false, targetRejected: false, targetAwaitSettled: false })),
    modules: [], cleanupErrors: [], privateByteWindowObserved: false,
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
  let f, row, observer, logicalBacking, logicalDirectory, stage = 'setup';
  const nativeStatus = () => f.native.workspaceGrant('status', row.nativeKey, row.nativeGeneration);
  const metadata = info => ({ dev: info.dev, ino: info.ino, mode: info.mode & 0o777 });
  async function prepareOwned(root) {
    assert.deepEqual(await fs.readdir(root), []);
    const bytes = Buffer.from('AB中文CD\n', 'utf8');
    assert.equal(bytes.length, 11);
    assert.equal(bytes.toString('hex'), wholeHex);
    await fs.writeFile(join(root, filename), bytes, { flag: 'wx', mode: 0o600 });
  }
  async function ownedFile(root) {
    const children = (await fs.readdir(root)).sort();
    assert.deepEqual(children, [filename]);
    const [rootInfo, fileInfo, bytes] = await Promise.all([
      fs.lstat(root), fs.lstat(join(root, filename)), fs.readFile(join(root, filename)),
    ]);
    assert.equal(rootInfo.isDirectory(), true);
    assert.equal(fileInfo.isFile(), true);
    assert.equal(fileInfo.mode & 0o777, 0o600);
    assert.equal(bytes.length, 11);
    assert.equal(bytes.toString('hex'), wholeHex);
    return { root: metadata(rootInfo), children,
      file: { ...metadata(fileInfo), bytes: bytes.length, hex: bytes.toString('hex'),
        sha256: createHash('sha256').update(bytes).digest('hex') } };
  }
  async function absentHostEntry(path) {
    try { await fs.lstat(path); return false; }
    catch (error) { if (error.code === 'ENOENT') return true; throw error; }
  }
  function recordTargetCalls(entry, mark) {
    entry.calls = observer.since(mark);
    const api = entry.calls.filter(call => call.layer === 'api' && call.method === 'readBytes');
    const provider = entry.calls.filter(call => call.layer === 'provider' && call.method === 'readByteRange');
    entry.targetEntryCount = api.length;
    entry.targetEntered = api.length > 0;
    entry.providerEntryCount = provider.length;
    entry.providerEntered = provider.length > 0;
    entry.providerReturned = provider.some(call => call.returned);
    entry.providerRejected = provider.some(call => call.rejected);
    entry.reached = Object.fromEntries([
      ['inspect', 'api', 'inspect'], ['locateFile', 'api', 'locateFile'],
      ['lstat', 'provider', 'lstat'], ['stat', 'provider', 'stat'],
      ['readByteRange', 'provider', 'readByteRange'], ['wholeReadBytes', 'provider', 'readBytes'],
    ].map(([name, layer, method]) => [name, entry.calls.some(call => call.layer === layer && call.method === method)]));
    entry.notReached = Object.keys(entry.reached).filter(name => !entry.reached[name]);
  }
  try {
    assert.equal(process.argv[1], join(config.payload, 'node_modules/@deepseek-ai/dsh/lib/bin.js'));
    assert.equal(process.platform, 'openharmony');
    assert.equal(typeof globalThis[Symbol.for('dsh.go.ohos.workspace-paths')]?.statFile, 'function');
    assert.equal(globalThis[Symbol.for('dsh.go.direct')], undefined);
    report.noSeparateDirectMapping = true;
    const [{ Context }, { Session, SessionStore }, { SystemPrompt }, { SessionProjectionRegistry },
      { SandboxPolicyService }, { SandboxedFileSystem }, { LocalFileSystem },
      { TypertRegistry }, { WorkspaceFiles }, { FsError }, { remoteErrorOf }] = await Promise.all([
        'cordis', 'dsh-session', 'dsh-system-prompt', 'dsh-session-projection',
        'dsh-sandbox-policy', 'dsh-fs-sandbox', 'dsh-fs-local',
        'dsh-typert-registry', 'dsh-api-workspace-files', 'dsh-fs', 'dsh-typert-protocol',
      ].map(load));
    observer = observeBytesCalls(LocalFileSystem, WorkspaceFiles);
    await prepareOwned(config.physical);
    report.physicalBefore = await ownedFile(config.physical);

    async function run(entry, { directory, backing, logical = false }) {
      let ctx, session, targetMark, caseStage = 'setup';
      const started = performance.now();
      const expectedPath = join(directory, filename); // Known before either API call.
      Object.assign(entry, { status: 'SETUP_ERROR', started: new Date().toISOString(),
        invocation: 'direct-real-api-service', cleanupErrors: [], behaviorErrors: [],
        knownAbsolutePath: expectedPath, privateByteWindowObserved: false });
      try {
        ctx = new Context();
        await ctx.plugin(SystemPrompt, {});
        await ctx.plugin(SessionProjectionRegistry);
        await ctx.plugin(TypertRegistry);
        await ctx.plugin(SessionStore);
        await ctx.plugin(SandboxPolicyService, { mode: 'read-only', workspaceRoot: directory });
        await ctx.plugin(SandboxedFileSystem, { cwd: directory });
        await ctx.plugin(WorkspaceFiles, {});
        entry.services = { fs: ctx.fs.constructor.name, policy: ctx.sandboxPolicy.constructor.name,
          sessions: ctx.sessions.constructor.name, typert: ctx.typert.constructor.name,
          workspaceFiles: ctx.workspaceFiles.constructor.name, mode: ctx.fs.sandboxMode };
        assert.equal(entry.services.fs, 'SandboxedFileSystem');
        assert.equal(entry.services.policy, 'SandboxPolicyService');
        assert.equal(entry.services.sessions, 'SessionStore');
        assert.equal(entry.services.typert, 'TypertRegistry');
        assert.equal(entry.services.workspaceFiles, 'WorkspaceFiles');
        assert.equal(entry.services.mode, 'read-only');
        const id = '939-' + entry.name;
        session = ctx.sessions.create(id, { meta: { cwd: directory } });
        assert(session instanceof Session);
        assert.equal(ctx.sessions.get(id), session);
        assert.equal(session.header.cwd, directory);
        entry.session = { type: session.constructor.name, id, headerCwd: session.header.cwd };
        const resolver = ctx.typert.lookups.get('workspaceFileScope');
        assert.equal(typeof resolver?.resolve, 'function');
        assert.equal(resolver.wire, 'workspaceFileScopeId');
        assert.equal(resolver.resource, 'session');
        const scope = await resolver.resolve(id);
        assert.deepEqual(scope, { sessionId: id, workspaceRoot: directory });
        entry.lookup = { key: 'workspaceFileScope', wire: resolver.wire,
          resource: resolver.resource, resolved: scope };
        entry.policy = ctx.sandboxPolicy.resolve({ session });
        assert.equal(entry.policy.mode, 'read-only');
        assert.equal(entry.policy.workspaceRoot, directory);
        entry.ownedBefore = await ownedFile(backing);
        entry.arguments = { workspaceFileScopeId: id, path: filename, options: { range: { offset: 2, length: 6 } } };
        const signal = new AbortController().signal;
        if (logical) {
          entry.nativeBeforePrelude = nativeStatus();
          assert.equal(entry.nativeBeforePrelude.active, true);
          assert.equal(entry.nativeBeforePrelude.leases, 0);
          assert.equal(f.fds.size, 0);
        }
        caseStage = 'prelude-stat';
        const preludeMark = observer.mark();
        const prelude = await ctx.workspaceFiles.stat(scope, filename, signal);
        entry.preludeCalls = observer.since(preludeMark);
        entry.preludeResult = JSON.parse(JSON.stringify(prelude));
        assert.equal(typeof prelude.version, 'string');
        assert(prelude.version.length > 0);
        assert.deepEqual(prelude, { absolutePath: expectedPath, version: prelude.version, bytes: 11 });
        assert(entry.preludeCalls.some(call => call.layer === 'api' && call.method === 'stat' && call.returned));
        assert(!entry.preludeCalls.some(call => call.observationError));
        entry.ownedAfterPrelude = await ownedFile(backing);
        assert.deepEqual(entry.ownedAfterPrelude, entry.ownedBefore);
        entry.opaqueVersion = prelude.version;
        entry.versionOracleSource = 'independent completed WorkspaceFiles.stat before the target readBytes call; opaque token only';
        entry.expected = { absolutePath: expectedPath, version: prelude.version, bytes: 11,
          offset: 2, data: [...windowBytes], eof: false };
        entry.preludePassed = true;
        if (logical) {
          entry.nativeBeforeTarget = nativeStatus();
          assert.equal(entry.nativeBeforeTarget.active, true);
          assert.equal(entry.nativeBeforeTarget.leases, 0);
          assert.equal(f.fds.size, 0);
        }
        targetMark = observer.mark();
        caseStage = 'target-call';
        entry.targetCallStarted = true;
        let actual, rejection;
        try {
          // Use the exact scope returned by the production registered resolver.
          actual = await ctx.workspaceFiles.readBytes(scope, filename, { range: { offset: 2, length: 6 } }, signal);
          entry.targetReturned = true;
        } catch (error) {
          rejection = error;
          entry.targetRejected = true;
          entry.targetError = errorInfo(error);
        }
        entry.targetAwaitSettled = true;
        entry.targetAwaitSettledAt = new Date().toISOString();
        if (logical) {
          // This is after the actual await settles, before result checks/dispose.
          entry.nativeAfterTargetAwaitTiming = 'after actual readBytes await fulfilled or rejected; before result assertions and Context.dispose';
          try {
            entry.nativeAfterTargetAwait = nativeStatus();
            entry.borrowedFDsAfterTargetAwait = f.fds.size;
            assert.equal(entry.nativeAfterTargetAwait.active, true);
            assert.equal(entry.nativeAfterTargetAwait.leases, 0);
            assert.equal(entry.borrowedFDsAfterTargetAwait, 0);
          } catch (error) { entry.cleanupErrors.push({ stage: 'target-await-resource-readback', ...errorInfo(error) }); }
        }
        recordTargetCalls(entry, targetMark);
        assert.equal(entry.targetEntryCount, 1, 'One real WorkspaceFiles.readBytes entry must be observed');
        assert(!entry.calls.some(call => call.observationError), 'Transparent observation failed');
        const apiCall = entry.calls.find(call => call.layer === 'api' && call.method === 'readBytes');
        assert.equal(apiCall.sessionId, id);
        assert.equal(apiCall.workspaceRoot, directory);
        assert.equal(apiCall.path, filename);
        assert.deepEqual(apiCall.options, { range: { offset: 2, length: 6 } });
        if (entry.targetRejected) {
          assert.equal(apiCall.rejected, true);
          const remote = remoteErrorOf(rejection);
          entry.knownProductRejection = Boolean(rejection instanceof FsError ||
            (typeof remote?.code === 'string' && remote.code.startsWith('workspace-file/')));
          if (!entry.knownProductRejection) throw rejection;
          entry.behaviorErrors.push({ kind: 'actual-service-rejection', ...entry.targetError });
        } else {
          caseStage = 'assert-result';
          // Preserve the whole actual return object's JSON representation first.
          entry.rawResultJSON = JSON.parse(JSON.stringify(actual));
          entry.dataIsUint8Array = actual?.data instanceof Uint8Array;
          entry.dataIsBuffer = Buffer.isBuffer(actual?.data);
          assert.equal(apiCall.returned, true);
          assert.deepEqual(apiCall.returnValue.value, entry.rawResultJSON);
          try {
            assert.equal(Object.getPrototypeOf(actual), Object.prototype);
            assert.deepEqual(Reflect.ownKeys(actual).sort(), ['absolutePath', 'bytes', 'data', 'eof', 'offset', 'version']);
            assert.equal(entry.dataIsUint8Array, true, 'Native raw bytes, not a string or carrier decoder');
            entry.result = { ...actual, data: Array.from(actual.data) };
            entry.dataHex = Buffer.from(actual.data).toString('hex');
            entry.dataByteLength = actual.data.byteLength;
            assert.deepEqual(entry.result, entry.expected);
            assert.equal(entry.dataHex, windowHex);
            assert.equal(entry.dataByteLength, 6);
            assert.equal(entry.providerEntryCount, 1);
            assert.equal(entry.providerReturned, true);
            assert.equal(entry.providerRejected, false);
            assert.equal(entry.reached.wholeReadBytes, false);
            const call = entry.calls.find(value => value.layer === 'provider' && value.method === 'readByteRange');
            assert.equal(call.targetKey, expectedPath);
            assert.equal(call.displayPath, expectedPath);
            assert.deepEqual(call.range, { offset: 2, length: 6 });
            assert.equal(call.returnValue.kind, 'bytes');
            assert.equal(call.returnValue.hex, windowHex);
            assert.deepEqual(call.returnValue.data, windowBytes);
            assert.equal(session.header.cwd, directory);
            assert.equal(ctx.sessions.get(id), session);
            entry.resultOraclePassed = true;
          } catch (error) { entry.behaviorErrors.push({ kind: 'complete-window-contract', ...errorInfo(error) }); }
        }
      } catch (error) {
        entry[caseStage === 'setup' || caseStage === 'prelude-stat' ? 'setupError' : 'unexpectedError'] =
          { stage: caseStage, ...errorInfo(error) };
      } finally {
        if (targetMark !== undefined && !entry.calls) recordTargetCalls(entry, targetMark);
        if (entry.ownedBefore) {
          try {
            entry.ownedAfter = await ownedFile(backing);
            assert.deepEqual(entry.ownedAfter, entry.ownedBefore);
            entry.ownedUnchanged = true;
          } catch (error) { entry.cleanupErrors.push({ stage: 'owned-file-readback', ...errorInfo(error) }); }
        }
        try {
          entry.contextDisposed = false;
          if (ctx) { await ctx.fiber.dispose(); entry.contextDisposed = true; }
        } catch (error) { entry.cleanupErrors.push({ stage: 'context-dispose', ...errorInfo(error) }); }
        if (logical) {
          entry.nativeAfterContextDisposeTiming = 'after awaited Context fiber.dispose; separate from the earlier target-await sample';
          try {
            entry.nativeAfterContextDispose = nativeStatus();
            entry.borrowedFDsAfterContextDispose = f.fds.size;
            assert.equal(entry.nativeAfterContextDispose.active, true);
            assert.equal(entry.nativeAfterContextDispose.leases, 0);
            assert.equal(entry.borrowedFDsAfterContextDispose, 0);
          } catch (error) { entry.cleanupErrors.push({ stage: 'dispose-resource-readback', ...errorInfo(error) }); }
        }
        entry.status = entry.cleanupErrors.length ? 'CLEANUP_FAILED' : entry.setupError ? 'SETUP_ERROR' :
          entry.unexpectedError ? 'UNEXPECTED_ERROR' : !entry.preludePassed || !entry.targetEntered ? 'INCOMPLETE' :
          !entry.targetAwaitSettled || (!entry.targetReturned && !entry.targetRejected) ? 'INCOMPLETE' :
          entry.behaviorErrors.length ? 'BEHAVIOR_RED' : entry.resultOraclePassed ? 'PASS' : 'INCOMPLETE';
        entry.pass = entry.status === 'PASS';
        entry.milliseconds = performance.now() - started;
        entry.ended = new Date().toISOString();
      }
      return entry;
    }

    stage = 'physical-case';
    const physical = await run(report.cases[0], { directory: config.physical, backing: config.physical });
    if (physical.pass) {
      stage = 'select-attach-setup';
      const { workspaceFixture, until } = await import(pathToFileURL(
        join(config.source, 'runtime/tests/ohos/authorized-workspaces-fixture.mjs')));
      f = await workspaceFixture({ after: fn => cleanups.push(fn) }, { pathThrow: true });
      const uri = 'file://docs/storage/Users/currentUser/Projects/939-byte-window';
      const request = f.call(f, 'select', { userGesture: true });
      await until(() => f.pickers.length === 1);
      f.select([uri]);
      const selected = await request.done;
      assert.equal(selected.error, undefined);
      const id = selected.value.workspaces[0].id;
      const attached = await f.call(f, 'attach', { id, userGesture: true }).done;
      assert.equal(attached.error, undefined);
      row = attached.value.workspaces[0];
      assert.equal(row.id, id);
      assert.equal(row.nativeGrant, 'ready');
      assert.equal(row.candidatePath, null);
      assert.equal(f.fds.size, 0);
      logicalBacking = f.uriPaths.get(uri);
      // Only fixture construction/readback use this backing. Product calls use
      // the Session's logical root and unchanged relative byte-marker.txt.
      await prepareOwned(logicalBacking);
      report.logicalBefore = await ownedFile(logicalBacking);
      logicalDirectory = '/workspaces/' + id;
      assert.equal(await absentHostEntry(logicalDirectory), true);
      report.logicalHostPathAbsent = true;
      report.published = { logicalRoot: logicalDirectory, nativeGrant: row.nativeGrant,
        candidatePath: row.candidatePath, borrowedFDs: f.fds.size, nativeBefore: nativeStatus() };
      assert.equal(report.published.nativeBefore.active, true);
      assert.equal(report.published.nativeBefore.leases, 0);
      stage = 'logical-case';
      await run(report.cases[1], { directory: logicalDirectory, backing: logicalBacking, logical: true });
    } else report.cases[1].blockedBy = 'physical-positive-control:' + physical.status;
  } catch (error) {
    report[stage === 'setup' || stage === 'select-attach-setup' ? 'setupError' : 'unexpectedError'] =
      { stage, ...errorInfo(error) };
    for (const entry of report.cases) if (entry.status === 'BLOCKED') entry.blockedBy = stage;
  } finally {
    try {
      if (report.physicalBefore) {
        report.physicalAfter = await ownedFile(config.physical);
        assert.deepEqual(report.physicalAfter, report.physicalBefore);
      }
      if (report.logicalBefore) {
        report.logicalAfter = await ownedFile(logicalBacking);
        assert.deepEqual(report.logicalAfter, report.logicalBefore);
      }
      if (logicalDirectory) {
        report.logicalHostPathStillAbsent = await absentHostEntry(logicalDirectory);
        assert.equal(report.logicalHostPathStillAbsent, true);
      }
      report.ownedFilesUnchanged = true;
    } catch (error) { report.cleanupErrors.push({ stage: 'final-owned-file-readback', ...errorInfo(error) }); }
    // Ordinary teardown only: no later read, reselect or separate revocation case.
    try {
      f?.background();
      if (row) {
        report.nativeRetiredTiming = 'after both cases and ordinary final fixture background';
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
    try { observer?.restore(); report.methodsRestored = true; }
    catch (error) { report.cleanupErrors.push({ stage: 'observer-restore', ...errorInfo(error) }); }
    report.targetCallCount = report.cases.filter(entry => entry.targetEntered).length;
    report.cleanupCompleted = report.cleanupErrors.length === 0 &&
      report.cases.every(entry => !entry.cleanupErrors?.length);
    report.pass = !report.setupError && !report.unexpectedError && report.cleanupCompleted &&
      report.cases.every(entry => entry.status === 'PASS' && entry.pass && entry.preludePassed &&
        entry.targetReturned && entry.targetEntered && entry.resultOraclePassed) &&
      report.targetCallCount === 2 && report.ownedFilesUnchanged === true && report.methodsRestored === true &&
      report.logicalHostPathAbsent === true && report.logicalHostPathStillAbsent === true &&
      report.nativeRetired?.active === false && report.nativeRetired?.leases === 0 && report.nativeRetired?.drained === true;
    report.ended = new Date().toISOString();
    await fs.writeFile(config.result, JSON.stringify(report, null, 2) + '\n');
  }
}
