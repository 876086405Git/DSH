// Two ordinary owned-directory listings, actual service/lookup/SessionStore.
// SDK chooser and Preferences are explicit fixtures, not phone execution.
import { isMainThread } from 'node:worker_threads';
if (isMainThread) {
  const assert = (await import('node:assert/strict')).default;
  const fs = await import('node:fs/promises');
  const { join } = await import('node:path');
  const { createRequire } = await import('node:module');
  const { pathToFileURL } = await import('node:url');
  const { createHash } = await import('node:crypto');
  const { observeDirectoryCalls } = await import('./workspace-directory-instrumentation.mjs');
  const config = JSON.parse(await fs.readFile(process.env.OHOS_937_DIRECTORY_CONFIG, 'utf8'));
  const names = ['physical-workspace-list', 'selected-logical-workspace-list'];
  // Independent complete object; never constructed from a response or UI decoder.
  const expected = Object.freeze({ path: '', entries: [
    Object.freeze({ name: 'a.txt', type: 'file', size: 6 }),
    Object.freeze({ name: 'b-dir', type: 'directory' }),
  ], truncated: false });
  const report = {
    schema: 1,
    scope: 'Actual DSH bin and sole preload; actual WorkspaceFiles.list, registered workspaceFileScope resolver, SessionStore/Session, SandboxedFileSystem and read-only policy. SDK chooser/Preferences doubles. Direct service component, not Dart/carrier/Gateway, full Web Host, persistent Session, watch, SDK or phone.',
    started: new Date().toISOString(), expected,
    cases: names.map(name => ({ name, status: 'BLOCKED', pass: false,
      targetCallStarted: false, targetEntered: false, targetReturned: false, targetRejected: false })),
    modules: [], cleanupErrors: [],
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
  let f, row, observer, logicalBacking, stage = 'setup';
  const nativeStatus = () => f.native.workspaceGrant('status', row.nativeKey, row.nativeGeneration);
  const metadata = value => ({ dev: value.dev, ino: value.ino, mode: value.mode & 0o777 });
  async function prepareOwned(root) {
    assert.deepEqual(await fs.readdir(root), []);
    await fs.writeFile(join(root, 'a.txt'), 'ENTRY\n', { flag: 'wx', mode: 0o600 });
    await fs.mkdir(join(root, 'b-dir'), { mode: 0o700 });
  }
  async function ownedDirectory(root) {
    const names = (await fs.readdir(root)).sort();
    assert.deepEqual(names, ['a.txt', 'b-dir']);
    const [rootInfo, fileInfo, dirInfo, bytes, empty] = await Promise.all([
      fs.lstat(root), fs.lstat(join(root, 'a.txt')), fs.lstat(join(root, 'b-dir')),
      fs.readFile(join(root, 'a.txt')), fs.readdir(join(root, 'b-dir')),
    ]);
    assert.equal(rootInfo.isDirectory(), true);
    assert.equal(fileInfo.isFile(), true);
    assert.equal(dirInfo.isDirectory(), true);
    assert.deepEqual(bytes, Buffer.from('ENTRY\n'));
    assert.deepEqual(empty, []);
    return { root: metadata(rootInfo), names,
      file: { ...metadata(fileInfo), bytes: bytes.length,
        sha256: createHash('sha256').update(bytes).digest('hex') },
      directory: { ...metadata(dirInfo), entries: empty } };
  }
  function recordCalls(entry, mark) {
    entry.calls = observer.since(mark);
    entry.targetEntered = entry.calls.some(call => call.layer === 'api' && call.method === 'list');
    entry.reached = Object.fromEntries([
      ['inspect', 'api', 'inspect'], ['lstat', 'provider', 'lstat'],
      ['confine', 'api', 'confine'], ['listDir', 'provider', 'listDir'],
    ].map(([name, layer, method]) => [name, entry.calls.some(call => call.layer === layer && call.method === method)]));
    entry.notReached = Object.keys(entry.reached).filter(name => !entry.reached[name]);
  }
  try {
    assert.equal(process.argv[1], join(config.payload, 'node_modules/@deepseek-ai/dsh/lib/bin.js'));
    assert.equal(process.platform, 'openharmony');
    assert.equal(typeof globalThis[Symbol.for('dsh.go.ohos.workspace-paths')]?.directory, 'function');
    assert.equal(globalThis[Symbol.for('dsh.go.direct')], undefined);
    report.noSeparateDirectMapping = true;
    const [{ Context }, { Session, SessionStore }, { SystemPrompt }, { SessionProjectionRegistry },
      { SandboxPolicyService }, { SandboxedFileSystem }, { LocalFileSystem },
      { TypertRegistry }, { WorkspaceFiles }, { FsError }, { remoteErrorOf }] = await Promise.all([
        'cordis', 'dsh-session', 'dsh-system-prompt', 'dsh-session-projection',
        'dsh-sandbox-policy', 'dsh-fs-sandbox', 'dsh-fs-local',
        'dsh-typert-registry', 'dsh-api-workspace-files', 'dsh-fs', 'dsh-typert-protocol',
      ].map(load));
    observer = observeDirectoryCalls(LocalFileSystem, WorkspaceFiles);
    await prepareOwned(config.physical);
    report.physicalBefore = await ownedDirectory(config.physical);

    async function run(entry, { directory, backing, logical = false }) {
      let ctx, session, mark, caseStage = 'setup';
      const started = performance.now();
      Object.assign(entry, { status: 'SETUP_ERROR', started: new Date().toISOString(),
        invocation: 'direct-real-api-service', cleanupErrors: [], behaviorErrors: [] });
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
        assert.equal(entry.services.sessions, 'SessionStore');
        assert.equal(entry.services.typert, 'TypertRegistry');
        assert.equal(entry.services.workspaceFiles, 'WorkspaceFiles');
        assert.equal(entry.services.mode, 'read-only');
        assert.equal(ctx.workspaceFiles.config.maxEntries, 2000);
        const id = '937-' + entry.name;
        session = ctx.sessions.create(id, { meta: { cwd: directory } });
        assert(session instanceof Session);
        assert.equal(ctx.sessions.get(id), session);
        assert.equal(session.header.cwd, directory);
        entry.session = { type: session.constructor.name, id, headerCwd: session.header.cwd };
        const provider = ctx.typert.lookups.get('workspaceFileScope');
        assert.equal(typeof provider?.resolve, 'function');
        assert.equal(provider.wire, 'workspaceFileScopeId');
        assert.equal(provider.resource, 'session');
        const scope = await provider.resolve(id);
        assert.deepEqual(scope, { sessionId: id, workspaceRoot: directory });
        entry.lookup = { key: 'workspaceFileScope', wire: provider.wire,
          resource: provider.resource, resolved: scope };
        entry.policy = ctx.sandboxPolicy.resolve({ session });
        assert.equal(entry.policy.mode, 'read-only');
        assert.equal(entry.policy.workspaceRoot, directory);
        entry.ownedBefore = await ownedDirectory(backing);
        entry.arguments = { workspaceFileScopeId: id, path: session.header.cwd };
        if (logical) {
          entry.nativeBefore = nativeStatus();
          assert.equal(entry.nativeBefore.active, true);
          assert.equal(entry.nativeBefore.leases, 0);
          assert.equal(f.fds.size, 0);
        }
        const signal = new AbortController().signal;
        mark = observer.mark();
        caseStage = 'target-call';
        entry.targetCallStarted = true;
        let actual, rejection;
        try {
          // scope is the exact object from the registered production resolver.
          actual = await ctx.workspaceFiles.list(scope, entry.arguments.path, signal);
          entry.targetReturned = true;
        } catch (error) {
          rejection = error;
          entry.targetRejected = true;
          entry.targetError = errorInfo(error);
        }
        recordCalls(entry, mark);
        if (!entry.targetEntered) throw Error('No actual WorkspaceFiles.list method entry observed');
        if (rejection) {
          const remote = remoteErrorOf(rejection);
          entry.knownProductRejection = Boolean(
            remote?.code.startsWith('workspace-file/') || rejection instanceof FsError);
          if (!entry.knownProductRejection) throw rejection;
          entry.behaviorErrors.push({ kind: 'actual-service-rejection', ...entry.targetError });
        } else {
          caseStage = 'assert-result';
          try {
            assert.deepEqual(actual, expected);
            assert.equal(entry.reached.listDir, true);
            assert.equal(session.header.cwd, directory);
            assert.equal(ctx.sessions.get(id), session);
          } catch (error) { entry.behaviorErrors.push({ kind: 'listing-contract', ...errorInfo(error) }); }
          // Full-object assertion precedes this optional JSON evidence projection.
          try { entry.result = JSON.parse(JSON.stringify(actual)); }
          catch (error) { entry.resultSerializationError = errorInfo(error); }
        }
      } catch (error) {
        entry[caseStage === 'setup' ? 'setupError' : 'unexpectedError'] =
          { stage: caseStage, ...errorInfo(error) };
      } finally {
        if (mark !== undefined && !entry.calls) recordCalls(entry, mark);
        if (entry.ownedBefore) {
          try {
            entry.ownedAfter = await ownedDirectory(backing);
            assert.deepEqual(entry.ownedAfter, entry.ownedBefore);
            entry.ownedUnchanged = true;
          } catch (error) { entry.cleanupErrors.push({ stage: 'owned-directory-readback', ...errorInfo(error) }); }
        }
        try {
          entry.contextDisposed = false;
          if (ctx) { await ctx.fiber.dispose(); entry.contextDisposed = true; }
        } catch (error) { entry.cleanupErrors.push({ stage: 'context-dispose', ...errorInfo(error) }); }
        if (logical) {
          entry.nativeAfterContextDisposeTiming = 'after awaited Context fiber.dispose, not before API return';
          try {
            entry.nativeAfterContextDispose = nativeStatus();
            assert.equal(entry.nativeAfterContextDispose.active, true);
            assert.equal(entry.nativeAfterContextDispose.leases, 0);
            assert.equal(f.fds.size, 0);
          } catch (error) { entry.cleanupErrors.push({ stage: 'lease-readback', ...errorInfo(error) }); }
        }
        entry.status = entry.cleanupErrors.length ? 'CLEANUP_FAILED' : entry.setupError ? 'SETUP_ERROR' :
          entry.unexpectedError ? 'UNEXPECTED_ERROR' : !entry.targetEntered ? 'INCOMPLETE' :
          !entry.targetReturned && !entry.targetRejected ? 'INCOMPLETE' :
          entry.behaviorErrors.length ? 'BEHAVIOR_RED' : 'PASS';
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
      const uri = 'file://docs/storage/Users/currentUser/Projects/937-directory-list';
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
      // Backing path is only for owned fixture construction and readback.
      // The actual lookup and API receive the logical Session cwd unchanged.
      await prepareOwned(logicalBacking);
      report.logicalBefore = await ownedDirectory(logicalBacking);
      const directory = '/workspaces/' + id;
      let hostEntry;
      try { hostEntry = await fs.lstat(directory); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      assert.equal(hostEntry, undefined, 'Selected logical root has a same-spelled host entry');
      report.logicalHostPathAbsent = true;
      report.published = { logicalRoot: directory, nativeGrant: row.nativeGrant,
        candidatePath: row.candidatePath, borrowedFDs: f.fds.size, nativeBefore: nativeStatus() };
      assert.equal(report.published.nativeBefore.active, true);
      assert.equal(report.published.nativeBefore.leases, 0);
      stage = 'logical-case';
      await run(report.cases[1], { directory, backing: logicalBacking, logical: true });
    } else report.cases[1].blockedBy = 'physical-positive-control:' + physical.status;
  } catch (error) {
    report[stage === 'setup' || stage === 'select-attach-setup' ? 'setupError' : 'unexpectedError'] =
      { stage, ...errorInfo(error) };
    for (const entry of report.cases) if (entry.status === 'BLOCKED') entry.blockedBy = stage;
  } finally {
    try {
      if (report.physicalBefore) {
        report.physicalAfter = await ownedDirectory(config.physical);
        assert.deepEqual(report.physicalAfter, report.physicalBefore);
      }
      if (report.logicalBefore) {
        report.logicalAfter = await ownedDirectory(logicalBacking);
        assert.deepEqual(report.logicalAfter, report.logicalBefore);
      }
      report.ownedDirectoriesUnchanged = true;
    } catch (error) { report.cleanupErrors.push({ stage: 'final-owned-directory-readback', ...errorInfo(error) }); }
    // Ordinary final teardown only; no subsequent read, revoke test or reselect.
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
    report.targetCallCount = report.cases.filter(value => value.targetEntered).length;
    report.cleanupCompleted = report.cleanupErrors.length === 0 &&
      report.cases.every(value => !value.cleanupErrors?.length);
    report.pass = !report.setupError && !report.unexpectedError && report.cleanupCompleted &&
      report.cases.every(value => value.status === 'PASS' && value.pass && value.targetReturned && value.targetEntered) &&
      report.targetCallCount === 2 && report.ownedDirectoriesUnchanged === true && report.methodsRestored === true &&
      report.nativeRetired?.active === false && report.nativeRetired?.leases === 0 && report.nativeRetired?.drained === true;
    report.ended = new Date().toISOString();
    await fs.writeFile(config.result, JSON.stringify(report, null, 2) + '\n');
  }
}
