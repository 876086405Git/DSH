// Real DSH bin + sole product preload + public SandboxedFileSystem. The OS
// picker, access-token service and fileShare state are explicit SDK fixtures.
import { isMainThread } from 'node:worker_threads';
if (isMainThread) {
  const assert = (await import('node:assert/strict')).default;
  const fs = await import('node:fs/promises');
  const { join } = await import('node:path');
  const { pathToFileURL } = await import('node:url');
  const { createRequire } = await import('node:module');
  const config = JSON.parse(await fs.readFile(process.env.OHOS_PHONE_FOLDER_CONFIG, 'utf8'));
  const report = { scope: 'Actual ETS / native FD / public Node file provider; explicit permission and picker boundaries. No OH SDK, phone or full chat claim.', cases: [], wire: [], cleanupErrors: [] };
  const cleanups = [];
  let fixture, boot, row, ctx, chosen, target;
  const check = async (name, action) => {
    try { await action(); report.cases.push({ name, pass: true }); }
    catch (error) { report.cases.push({ name, pass: false, code: error.code, message: error.message, stack: error.stack }); throw error; }
  };
  try {
    assert.equal(process.platform, 'openharmony');
    assert.equal(process.argv[1], join(config.payload, 'node_modules/@deepseek-ai/dsh/lib/bin.js'));
    const require = createRequire(join(config.payload, 'package.json'));
    const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
    const [{ Context }, { SessionProjectionRegistry }, { SandboxPolicyService }, { SandboxedFileSystem }] = await Promise.all([
      'cordis', 'dsh-session-projection', 'dsh-sandbox-policy', 'dsh-fs-sandbox'].map(load));
    const { borrowProcessGrantAuthority } = await import(pathToFileURL(join(config.payload, 'runtime/ohos/process/files/process-authority.mjs')));
    const { workspaceFixture, until } = await import(pathToFileURL(join(config.source, 'runtime/tests/ohos/authorized-workspaces-fixture.mjs')));
    const module = JSON.parse(await fs.readFile(join(config.source, 'app/ohos/entry/src/main/module.json5'), 'utf8'));
    const names = module.module.requestPermissions.map(value => value.name);
    fixture = await workspaceFixture({ after: action => cleanups.push(action) }, {
      pathThrow: true, permissionDenied: !names.includes('ohos.permission.FILE_ACCESS_PERSIST'),
    });
    boot = fixture;
    const call = async (method, extra = {}) => {
      const result = await fixture.call(boot, method, { userGesture: true, ...extra }).done;
      assert.equal(result.error, undefined, method + ': ' + result.error);
      if (result.value?.workspaces) report.wire.push({ method, value: result.value });
      return result.value;
    };
    const status = () => fixture.native.workspaceGrant('status', row.nativeKey, row.nativeGeneration);
    const permission = { mode: 'workspace-write', workspaceRoot: '' };
    const uri = 'file://docs/storage/Users/currentUser/Projects/phone-native-read-write';
    await check('actual module declares only FILE_ACCESS_PERSIST for folder persistence', async () => {
      assert.deepEqual(names.filter(name => /FILE_ACCESS|READ_MEDIA|WRITE_MEDIA|READ_IMAGEVIDEO|WRITE_IMAGEVIDEO/.test(name)), ['ohos.permission.FILE_ACCESS_PERSIST']);
      assert.equal((await call('capabilities')).persistencePermission, 'granted');
    });
    await check('user FOLDER selection then real persist control flow', async () => {
      const pending = fixture.call(boot, 'select', { userGesture: true });
      await until(() => fixture.pickers.length === 1);
      assert.equal(fixture.pickers[0].options.selectMode, 1);
      fixture.select([uri]);
      const selection = await pending.done; assert.equal(selection.error, undefined);
      report.wire.push({ method: 'select', value: selection.value });
      row = selection.value.workspaces[0];
      assert.equal(row.nativeGrant, 'unattached');
      row = (await call('persist', { id: row.id })).workspaces[0];
      assert.equal(row.persistence, 'persisted');
      assert.equal(row.candidatePath, null);
    });
    await check('URI directory FD reaches the existing native Node owner without a path conversion', async () => {
      row = (await call('attach', { id: row.id })).workspaces[0];
      assert.equal(row.nativeGrant, 'ready'); assert.equal(row.candidatePath, null);
      assert.equal(fixture.fds.size, 0);
      permission.workspaceRoot = '/workspaces/' + row.id;
      assert.equal(borrowProcessGrantAuthority().snapshot().some(value => value.mountPoint === permission.workspaceRoot), true);
      chosen = fixture.uriPaths.get(uri);
      await fs.writeFile(join(chosen, 'marker'), 'selected directory\n', { flag: 'wx' });
      await assert.rejects(fs.lstat(permission.workspaceRoot), { code: 'ENOENT' });
      ctx = new Context();
      await ctx.plugin(SessionProjectionRegistry).await();
      await ctx.plugin(SandboxPolicyService, permission).await();
      await ctx.plugin(SandboxedFileSystem, { cwd: permission.workspaceRoot }).await();
      assert.equal(ctx.fs.constructor.name, 'SandboxedFileSystem');
      target = await ctx.fs.resolve('marker');
    });
    await check('actual public Node provider reads and atomically writes selected directory bytes', async () => {
      assert.equal(await ctx.fs.readText(target), 'selected directory\n');
      await ctx.fs.writeText(target, 'written by actual Node provider\n', undefined, undefined, permission);
      assert.equal(await fs.readFile(join(chosen, 'marker'), 'utf8'), 'written by actual Node provider\n');
      assert.equal(await ctx.fs.readText(target), 'written by actual Node provider\n');
      const created = await ctx.fs.resolve('created.txt');
      await ctx.fs.writeText(created, 'new file\n', { kind: 'createIfAbsent' }, undefined, permission);
      assert.equal(await fs.readFile(join(chosen, 'created.txt'), 'utf8'), 'new file\n');
      assert.equal(status().leases, 0);
    });
    await check('read-only task refuses a write despite OS READ|WRITE authorization', async () => {
      await assert.rejects(ctx.fs.writeText(target, 'wrong', undefined, undefined,
        { mode: 'read-only', workspaceRoot: permission.workspaceRoot }), { code: 'FS_SANDBOX_DENIED' });
      assert.equal(await fs.readFile(join(chosen, 'marker'), 'utf8'), 'written by actual Node provider\n');
    });
    await check('deactivation retires native admission before a subsequent Node read', async () => {
      // In the real SDK, Picker's temporary grant and persisted grant are
      // distinct. Explicitly activate before testing deactivate's lifecycle.
      await call('activate', { id: row.id });
      row = (await call('attach', { id: row.id })).workspaces[0];
      await call('deactivate', { id: row.id });
      assert.equal(status().active, false); assert.equal(status().drained, true);
      await assert.rejects(ctx.fs.readText(target), { code: 'FS_IO_ERROR' });
    });
    await check('OS persistence check and activation restore the same ID with a fresh native generation', async () => {
      const oldGeneration = row.nativeGeneration;
      await call('activate', { id: row.id });
      row = (await call('attach', { id: row.id })).workspaces[0];
      assert(row.nativeGeneration > oldGeneration);
      assert.equal(await ctx.fs.readText(target), 'written by actual Node provider\n');
    });
    await check('background invalidates old FD lease and fresh foreground does not revive it', async () => {
      boot.background();
      assert.equal(status().active, false);
      boot.foreground();
      assert.equal((await fixture.call(boot, 'attach', { userGesture: true, id: row.id }).done).error, 'reauthorize');
      await assert.rejects(ctx.fs.readText(target), { code: 'FS_IO_ERROR' });
    });
    await check('fresh ETS module reload reads saved record but must query and activate before Node reuse', async () => {
      fixture.active.clear();
      boot = fixture.boot();
      const restored = (await call('list')).workspaces[0];
      assert.equal(restored.authorization, 'needsRestore');
      assert.equal(restored.nativeGrant, 'unattached');
      assert.equal((await fixture.call(boot, 'attach', { userGesture: true, id: row.id }).done).error, 'reauthorize');
      const mark = fixture.operations.length;
      await call('activate', { id: row.id });
      row = (await call('attach', { id: row.id })).workspaces[0];
      assert.deepEqual(fixture.operations.slice(mark).filter(value => ['checkPersistent', 'activate', 'openDirectory', 'closeDirectory'].includes(value.op)).map(value => value.op),
        ['checkPersistent', 'activate', 'openDirectory', 'closeDirectory']);
      assert.equal(await ctx.fs.readText(target), 'written by actual Node provider\n');
      await ctx.fs.writeText(target, 'after explicit restore\n', undefined, undefined, permission);
      assert.equal(await fs.readFile(join(chosen, 'marker'), 'utf8'), 'after explicit restore\n');
    });
    await check('OS revoke removes persistent access and Node cannot reuse the former logical root', async () => {
      const revoked = (await call('revoke', { id: row.id })).workspaces[0];
      assert.equal(revoked.persistence, 'absent');
      assert.equal(fixture.persisted.has(uri), false);
      assert.equal(status().active, false); assert.equal(status().leases, 0); assert.equal(status().drained, true);
      await assert.rejects(ctx.fs.readText(target), { code: 'FS_IO_ERROR' });
      assert.equal((await fixture.call(boot, 'activate', { userGesture: true, id: row.id }).done).error, 'reauthorize');
      assert.equal(await fs.readFile(join(chosen, 'marker'), 'utf8'), 'after explicit restore\n');
    });
  } catch (error) { report.failure = { code: error.code, message: error.message, stack: error.stack }; }
  finally {
    try { boot?.background(); } catch (error) { report.cleanupErrors.push(error.message); }
    try { await ctx?.fiber.dispose(); } catch (error) { report.cleanupErrors.push(error.message); }
    for (const cleanup of cleanups.reverse()) { try { await cleanup(); } catch (error) { report.cleanupErrors.push(error.message); } }
    report.pass = report.cases.length === 10 && report.cases.every(row => row.pass) && report.cleanupErrors.length === 0 && !report.failure;
    await fs.writeFile(config.result, JSON.stringify(report, null, 2) + '\n');
  }
}
