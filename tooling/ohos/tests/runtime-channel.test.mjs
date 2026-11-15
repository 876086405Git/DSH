import test, { after, afterEach, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { makePack, fileIo, inflateActivity, activeInflaters, RUNTIME_ARCHIVE_ASSET } from './runtime-storage-fixture.mjs';
import { native, MethodCall, nativeModuleLoads, nativeModuleControl, lifecycleControl } from './runtime-host-fixture.mjs';
import { prepareManagedSkillModules } from './managed-skill-loader.mjs';
import { managedSkillIo } from './managed-skill-fixture.mjs';

// Node executes these exact ETS logic bodies after extension/import adaptation.
// This is not an ArkTS compile or an OH filesystem/ResourceManager test.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const source = path.join(root, 'app/ohos/entry/src/main/ets/runtime');
const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-ohos-channel-'));
after(async () => { await fs.rm(temp, { recursive: true, force: true }); });
const corePath = path.join(temp, 'RuntimeCore.mts');
await fs.copyFile(path.join(source, 'RuntimeCore.ets'), corePath);
await fs.copyFile(path.join(source, 'RuntimePaths.ets'), path.join(temp, 'RuntimePaths.mts'));
await fs.copyFile(path.join(source, 'RuntimeLifecycle.ets'), path.join(temp, 'RuntimeLifecycle.mts'));
await prepareManagedSkillModules({ source, directory: temp });
const fixtureUrl = new URL('./runtime-storage-fixture.mjs', import.meta.url).href;
// All three archive modules share the same actual RuntimeCore identity used by
// the Controller and installer. Only unavailable platform imports and type-only
// bindings are adapted; the product method bodies are executed unchanged.
let zipText = await fs.readFile(path.join(source, 'RuntimeZip.ets'), 'utf8');
zipText = zipText.replace("import util from '@ohos.util';", `import { util } from '${fixtureUrl}';`)
  .replace('RuntimeChannelError, RuntimeFile, RuntimeManifest, validateManifest',
    'RuntimeChannelError, type RuntimeFile, type RuntimeManifest, validateManifest')
  .replace("from './RuntimeCore'", "from './RuntimeCore.mts'");
await fs.writeFile(path.join(temp, 'RuntimeZip.mts'), zipText);
let archiveText = await fs.readFile(path.join(source, 'OhosRuntimeArchive.ets'), 'utf8');
archiveText = archiveText.replace("import fs from '@ohos.file.fs';", `import { fileIo as fs } from '${fixtureUrl}';`)
  .replace("import resourceManager from '@ohos.resourceManager';", '')
  .replace("import zlib from '@ohos.zlib';", `import { nativeZlib as zlib } from '${fixtureUrl}';`)
  .replace('RuntimeChannelError, RuntimeFile, RuntimeManifest',
    'RuntimeChannelError, type RuntimeFile, type RuntimeManifest')
  .replace('RuntimeArchiveSource, RuntimeZip, RuntimeZipEntry', 'type RuntimeArchiveSource, RuntimeZip, RuntimeZipEntry')
  .replace("from './RuntimeCore'", "from './RuntimeCore.mts'")
  .replace("from './RuntimeZip'", "from './RuntimeZip.mts'");
await fs.writeFile(path.join(temp, 'OhosRuntimeArchive.mts'), archiveText);
let adapterText = await fs.readFile(path.join(source, 'OhosRuntimeStorage.ets'), 'utf8');
adapterText = adapterText.replace("import fs from '@ohos.file.fs';", `import { fileIo as fs } from '${fixtureUrl}';`)
  .replace("import fileHash from '@ohos.file.hash';", `import { fileHash } from '${fixtureUrl}';`)
  .replace("import resourceManager from '@ohos.resourceManager';", '')
  .replace("import { BusinessError } from '@ohos.base';", '')
  .replace("import util from '@ohos.util';", `import { util } from '${fixtureUrl}';`)
  .replace("from './RuntimeCore'", "from './RuntimeCore.mts'")
  .replace("from './OhosRuntimeArchive'", "from './OhosRuntimeArchive.mts'")
  .replace('RuntimeChannelError, RuntimeFile, RuntimeManifest, RuntimeStorage',
    'RuntimeChannelError, type RuntimeFile, type RuntimeManifest, type RuntimeStorage');
const adapterPath = path.join(temp, 'OhosRuntimeStorage.mts');
await fs.writeFile(adapterPath, adapterText);
const core = await import(pathToFileURL(corePath));
const { OhosRuntimeStorage } = await import(pathToFileURL(adapterPath));

let controllerText = await fs.readFile(path.join(source, 'RuntimeController.ets'), 'utf8');
// Persistence is a separate product patch. Test the actual dependency graph of
// either declared composition; do not add a runtime/product feature switch.
const usesPersistedRuntimeLog = controllerText.includes("from './PersistedRuntimeLog'");
let PersistedRuntimeLog;
if (usesPersistedRuntimeLog) {
  let persistedText = await fs.readFile(path.join(source, 'PersistedRuntimeLog.ets'), 'utf8');
  persistedText = persistedText.replace("import fs from '@ohos.file.fs';", `import { fileIo as fs } from '${fixtureUrl}';`)
    .replace("import util from '@ohos.util';", `import { util } from '${fixtureUrl}';`)
    .replace("import { BusinessError } from '@ohos.base';", '')
    .replace("import { Any } from '@ohos/flutter_ohos';", '')
    .replace("from './RuntimeCore'", "from './RuntimeCore.mts'");
  await fs.writeFile(path.join(temp, 'PersistedRuntimeLog.mts'), persistedText);
  ({ PersistedRuntimeLog } = await import(pathToFileURL(path.join(temp, 'PersistedRuntimeLog.mts'))));
}
beforeEach(() => { if (usesPersistedRuntimeLog) PersistedRuntimeLog.shared = null; });

const hostFixtureUrl = new URL('./runtime-host-fixture.mjs', import.meta.url).href;
const nativeBoundary = path.join(temp, 'native-boundary.mjs');
await fs.writeFile(nativeBoundary, `import host, { markNativeLoad, nativeModuleControl } from '${hostFixtureUrl}';
await nativeModuleControl.beforeLoad?.();
markNativeLoad();
export default host;
`);

// Native loading stays in the production helper; only the unavailable .so boundary
// is redirected to the explicit host fixture. Its default export matches Ark import.
let nativeHostText = await fs.readFile(path.join(source, 'NativeHost.ets'), 'utf8');
nativeHostText = nativeHostText.replace("from 'libdsh_host.so'", `from '${hostFixtureUrl}'`)
  .replace("import('libdsh_host.so')", `import('${pathToFileURL(nativeBoundary).href}')`)
  .replace("from './RuntimeCore'", "from './RuntimeCore.mts'");
await fs.writeFile(path.join(temp, 'NativeHost.mts'), nativeHostText);
controllerText = controllerText.replace("import common from '@ohos.app.ability.common';", '')
  .replace("import UIAbility from '@ohos.app.ability.UIAbility';", '')
  .replace("import util from '@ohos.util';", `import { util } from '${fixtureUrl}';`)
  .replace("import connection from '@ohos.net.connection';", `import { connection } from '${hostFixtureUrl}';`)
  .replace("from 'libdsh_host.so'", `from '${hostFixtureUrl}'`)
  .replace('RuntimeChannelError, RuntimeManifest, RuntimeFile, RuntimeInstaller', 'RuntimeChannelError, type RuntimeManifest, type RuntimeFile, RuntimeInstaller')
  .replace('  InstallProgress,', '  type InstallProgress,')
  .replace("from './RuntimeCore'", "from './RuntimeCore.mts'")
  .replace("from './NativeHost'", "from './NativeHost.mts'")
  .replace("from './PersistedRuntimeLog'", "from './PersistedRuntimeLog.mts'")
  .replace("from './RuntimePaths'", "from './RuntimePaths.mts'")
  .replace("from './RuntimeLifecycle'", "from './RuntimeLifecycle.mts'")
  .replace("from './OhosLifecycleTransport'", `from '${hostFixtureUrl}'`)
  .replace("from './BackgroundCompute'", `from '${hostFixtureUrl}'`)
  .replace("from './ManagedSkillService'", "from './ManagedSkillService.mts'")
  .replace("from './OhosRuntimeStorage'", "from './OhosRuntimeStorage.mts'");
const controllerPath = path.join(temp, 'RuntimeController.mts');
await fs.writeFile(controllerPath, controllerText);
const { RuntimeController } = await import(pathToFileURL(controllerPath));
let entryText = await fs.readFile(path.join(source, '../entryability/EntryAbility.ets'), 'utf8');
entryText = entryText.replace(/^import .*;\n/gm, '');
await fs.writeFile(path.join(temp, 'EntryAbility.mts'),
  `import { RuntimeController } from './RuntimeController.mts';\nimport { FlutterAbility } from '${hostFixtureUrl}';\n` +
  `const VoicePlugin = { onForeground() {}, onBackground() {} };\n` +
  `const NativeFilesPlugin = { onForeground() {}, onBackground() {} };\n` +
  `const NativeMediaPlugin = { onForeground() {}, onBackground() {} };\n` + entryText);
const { default: EntryAbility } = await import(pathToFileURL(path.join(temp, 'EntryAbility.mts')));
let pluginText = await fs.readFile(path.join(source, 'RuntimePlugin.ets'), 'utf8');
pluginText = pluginText.replace(/^import .* from '@ohos\/flutter_ohos[^\n]+\n/gm, '')
  .replace("import { BusinessError } from '@ohos.base';", '')
  .replace("from './RuntimeCore'", "from './RuntimeCore.mts'")
  .replace("from './ManagedSkillService'", "from './ManagedSkillService.mts'")
  .replace("from './RuntimeController'", "from './RuntimeController.mts'");
pluginText = `import { MethodCall, MethodChannel, EventChannel } from '${hostFixtureUrl}';\n` + pluginText;
const pluginPath = path.join(temp, 'RuntimePlugin.mts');
await fs.writeFile(pluginPath, pluginText);
const { RuntimePlugin } = await import(pathToFileURL(pluginPath));
const controllers = [];
afterEach(async () => {
  native.state.phase = 'idle';
  for (const controller of controllers) {
    controller.collect();
    if (usesPersistedRuntimeLog) await controller.persistedLogs.flush();
  }
  RuntimeController.foreground = false; RuntimeController.ability = null;
});
const files = {
  'node_modules/@deepseek-ai/dsh/lib/bin.js': 'console.log("fixture entry");',
  'runtime/ohos/preload.mjs': 'export const fixture = true;',
  'runtime/ohos/process/index.mjs': 'export function apply() {}',
  'runtime/ohos/process/sandbox.mjs': 'export function apply() {}',
  'runtime/ohos/lifecycle/index.mjs': 'export function apply() {}',
  'runtime/ohos/capabilities/index.mjs': 'export function apply() {}',
  'runtime/bridge/dsh-go-bridge/lib/index.js': 'export function apply() {}',
  'runtime/ohos/process/child-process.mjs': 'export const childProcess = true;',
  'runtime/ohos/中文 空格.txt': '中文与 emoji 🐳\n',
};

async function makeCase(name, payload = files, version = 'v1', adjustManifest) {
  const dir = path.join(temp, name);
  await fs.mkdir(dir);
  const pack = await makePack(path.join(dir, 'payload.hap'), payload, version, adjustManifest);
  const storage = new OhosRuntimeStorage(pack.resources, dir);
  const installer = new core.RuntimeInstaller(storage, dir + '/runtime');
  return { dir, ...pack, storage, installer };
}

test('首次落地严格使用单归档rawfile offset/length，真实inflate、中文字节、摘要及完成标记一致', async () => {
  const c = await makeCase('first');
  assert.equal(await c.installer.installed(), null);
  const progress = [];
  const inflatedBefore = inflateActivity.initialized;
  await c.storage.withBundledRuntime(() => c.installer.install(c.manifest, e => progress.push(e)));
  assert.equal((await c.installer.installed()).runtimeVersion, 'v1');
  for (const [name, text] of Object.entries(files)) assert.equal(await fs.readFile(c.installer.root + '/' + name, 'utf8'), text);
  assert.equal(c.resources.opened.size, 0);
  assert.deepEqual(c.resources.reads, [RUNTIME_ARCHIVE_ASSET]);
  assert(c.resources.entries[RUNTIME_ARCHIVE_ASSET].offset > 0);
  assert.equal(inflateActivity.initialized - inflatedBefore, Object.keys(files).length);
  assert.equal(activeInflaters(), 0);
  assert.deepEqual(progress.at(-1), { step: 'configure', done: 1, total: 1 });
});

test('重复安装不读HAP文件；升级只复制实际变更文件并删除旧清单项', async () => {
  const c = await makeCase('upgrade');
  await c.installer.install(c.manifest, () => {});
  const before = await fs.stat(c.installer.root + '/runtime/ohos/preload.mjs');
  c.resources.reads.length = 0;
  const unchangedInflated = inflateActivity.initialized;
  await c.installer.install(c.manifest, () => {});
  assert.deepEqual(c.resources.reads, []);
  assert.equal(inflateActivity.initialized, unchangedInflated);
  const nextFiles = { ...files, 'runtime/ohos/new.txt': '新增' };
  delete nextFiles['runtime/ohos/中文 空格.txt'];
  const next = await makePack(path.join(c.dir, 'payload2.hap'), nextFiles, 'v2');
  const nextInstaller = new core.RuntimeInstaller(new OhosRuntimeStorage(next.resources, c.dir), c.dir + '/runtime');
  await nextInstaller.install(next.manifest, () => {});
  assert.deepEqual(next.resources.reads, [RUNTIME_ARCHIVE_ASSET]);
  assert.equal(inflateActivity.initialized - unchangedInflated, 1);
  assert.equal((await fs.stat(c.installer.root + '/runtime/ohos/preload.mjs')).ino, before.ino);
  await assert.rejects(fs.access(c.installer.root + '/runtime/ohos/中文 空格.txt'));
  assert.equal((await nextInstaller.installed()).runtimeVersion, 'v2');
});

test('复制校验失败保留安装中断标记，不能把半树报告成已安装', async () => {
  // Corrupt the manifest inside the ZIP as well as the installer input. The
  // ZIP/CRC is valid, so the original content SHA gate must detect the failure.
  const c = await makeCase('corrupt', files, 'v1', manifest => { manifest.files[0].sha256 = '0'.repeat(64); });
  await assert.rejects(c.installer.install(c.manifest, () => {}), { code: 'ohos_checksum_failed' });
  assert.equal(await c.installer.installed(), null);
  assert.equal(c.resources.opened.size, 0);
  await fs.access(c.dir + '/runtime/installing.json');
});

test('升级把旧多层目录换为文件时，只清理登记过的空祖先目录', async () => {
  const c = await makeCase('directory-to-file', { ...files, 'nested/a/b/c.txt': 'old' });
  await c.installer.install(c.manifest, () => {});
  const next = await makePack(path.join(c.dir, 'next.hap'), { ...files, 'nested': 'new file' }, 'v2');
  const installer = new core.RuntimeInstaller(new OhosRuntimeStorage(next.resources, c.dir), c.dir + '/runtime');
  await installer.install(next.manifest, () => {});
  assert.equal(await fs.readFile(installer.root + '/nested', 'utf8'), 'new file');
});

test('安装中断后换新HAP，不残留未提交版本已写的新文件或已登记临时文件', async () => {
  // The owned new file remains first in the canonical sorted archive manifest.
  const c = await makeCase('interrupted-upgrade', { '000-uncommitted/new.txt': 'old', ...files }, 'failed-v1');
  await assert.rejects(c.installer.install(c.manifest, e => {
    if (e.step === 'extract' && e.done > 0) throw new Error('injected interruption after first commit');
  }), /injected interruption/);
  assert.equal(await c.installer.installed(), null);
  await fs.access(c.installer.root + '/000-uncommitted/new.txt');
  const next = await makePack(path.join(c.dir, 'next.hap'), files, 'v2');
  const installer = new core.RuntimeInstaller(new OhosRuntimeStorage(next.resources, c.dir), c.dir + '/runtime');
  await installer.install(next.manifest, () => {});
  await assert.rejects(fs.access(installer.root + '/000-uncommitted/new.txt'));
  assert.equal((await installer.installed()).runtimeVersion, 'v2');
  assert.deepEqual(await fs.readdir(c.dir + '/runtime/staging'), []);
});

test('文件改目录的升级在新子文件提交后中断，续装不把当前祖先目录当旧文件删', async () => {
  const c = await makeCase('file-to-directory-resume', { ...files, 'changing': 'v1 file' });
  await c.installer.install(c.manifest, () => {});
  const next = await makePack(path.join(c.dir, 'next.hap'), { ...files, 'changing/child.txt': 'v2 child' }, 'v2');
  const installer = new core.RuntimeInstaller(new OhosRuntimeStorage(next.resources, c.dir), c.dir + '/runtime');
  await assert.rejects(installer.install(next.manifest, e => {
    if (e.step === 'extract' && e.done > 0) throw new Error('interrupted after path changed type');
  }), /interrupted/);
  await installer.install(next.manifest, () => {});
  assert.equal(await fs.readFile(installer.root + '/changing/child.txt', 'utf8'), 'v2 child');
  assert.equal((await installer.installed()).runtimeVersion, 'v2');
});

test('真实SIGKILL发生在首文件提交后：重开拒绝混合树，续装只补剩余文件', async () => {
  const c = await makeCase('killed');
  const childScript = path.join(temp, 'kill-install.mjs');
  await fs.writeFile(childScript, `
    import fs from 'node:fs';
    import { RuntimeInstaller } from ${JSON.stringify(pathToFileURL(corePath).href)};
    import { OhosRuntimeStorage } from ${JSON.stringify(pathToFileURL(adapterPath).href)};
    import { PackedResources } from ${JSON.stringify(fixtureUrl)};
    const data = JSON.parse(process.argv[2]);
    const r = new PackedResources(data.pack, data.entries);
    const i = new RuntimeInstaller(new OhosRuntimeStorage(r, data.dir), data.dir + '/runtime');
    await i.install(data.manifest, e => { if (e.step === 'extract' && e.done > 0) { fs.writeSync(1, 'committed\\n'); process.kill(process.pid, 'SIGSTOP'); } });
  `);
  const child = spawn(process.execPath, [childScript, JSON.stringify({ pack: c.resources.path, entries: c.resources.entries, dir: c.dir, manifest: c.manifest })], { stdio: ['ignore', 'pipe', 'pipe'] });
  let stderr = ''; child.stderr.on('data', b => { stderr += b; });
  const exited = once(child, 'exit');
  let timer;
  const committed = await Promise.race([
    once(child.stdout, 'data').then(([data]) => data.toString().includes('committed')),
    exited.then(() => false),
    new Promise(resolve => { timer = setTimeout(() => resolve(false), 5000); }),
  ]);
  clearTimeout(timer);
  child.kill('SIGKILL');
  const [, signal] = await exited;
  assert.equal(committed, true, stderr);
  assert.equal(signal, 'SIGKILL');
  assert.equal(await c.installer.installed(), null);
  assert.equal(await fs.readFile(c.installer.root + '/' + c.manifest.files[0].path, 'utf8'), files[c.manifest.files[0].path]);
  const inflatedBefore = inflateActivity.initialized;
  await c.installer.install(c.manifest, () => {});
  assert(c.resources.reads.every(asset => asset === RUNTIME_ARCHIVE_ASSET));
  assert.equal(inflateActivity.initialized - inflatedBefore, Object.keys(files).length - 1);
  assert.equal(c.resources.opened.size, 0);
  assert.equal(activeInflaters(), 0);
  assert.equal((await c.installer.installed()).runtimeVersion, 'v1');
});

test('实际短读与短写仍准确落地，raw FD 在失败和成功时都关闭', async () => {
  const c = await makeCase('short');
  const read = fileIo.read, write = fileIo.write;
  fileIo.read = (fd, buffer, opts) => read(fd, buffer, { ...opts, length: Math.min(3, opts.length) });
  fileIo.write = (fd, buffer, opts) => write(fd, buffer.slice(0, Math.min(2, buffer.byteLength)), opts);
  try {
    await c.installer.install(c.manifest, () => {});
    for (const [name, text] of Object.entries(files)) assert.equal(await fs.readFile(c.installer.root + '/' + name, 'utf8'), text);
    assert.equal(c.resources.opened.size, 0);
  } finally { fileIo.read = read; fileIo.write = write; }
});

test('ELF 即使伪装成JS且每次只读1字节，也不能提交到运行时目录', async () => {
  const c = await makeCase('elf', { ...files, 'payload.js': Buffer.from([127, 69, 76, 70, 1, 2, 3]) });
  const read = fileIo.read;
  fileIo.read = (fd, buffer, opts) => read(fd, buffer, { ...opts, length: 1 });
  try { await assert.rejects(c.installer.install(c.manifest, () => {}), { code: 'ohos_native_payload' }); }
  finally { fileIo.read = read; }
  assert.equal(c.resources.opened.size, 0);
  await assert.rejects(fs.access(c.installer.root + '/payload.js'));
});

test('固定依赖中的client.node.js名称是普通JS，不能误判为原生扩展；版本化so仍拒绝', async () => {
  const name = 'node_modules/@deepseek-ai/dsh-api-gateway/lib/client.node.js';
  const body = 'export const fixture = "普通 Node 端 JS";';
  const c = await makeCase('node-js-name', { ...files, [name]: body });
  core.validateManifest(c.manifest);
  await c.installer.install(c.manifest, () => {});
  assert.equal(await fs.readFile(c.installer.root + '/' + name, 'utf8'), body);
  for (const nativeName of ['addon.node', 'lib.so', 'lib.so.1', 'lib.so.1.2.3', 'LIB.SO.26']) {
    const invalid = structuredClone(c.manifest);
    invalid.files.push({ path: nativeName, size: 1, sha256: 'a'.repeat(64) });
    assert.throws(() => core.validateManifest(invalid), { code: 'ohos_manifest_invalid' });
  }
  const elf = await makeCase('node-js-magic', { ...files, [name]: Buffer.from([127, 69, 76, 70, 1, 2, 3]) });
  await assert.rejects(elf.installer.install(elf.manifest, () => {}), { code: 'ohos_native_payload' });
  await assert.rejects(fs.access(elf.installer.root + '/' + name));
});

test('manifest拒绝越界、原生模块、重复及文件/目录冲突', () => {
  const valid = { schema: 1, runtimeVersion: 'v1', dshVersion: 'x', nodeVersion: '24.22.1', files: Object.keys(files).map(name => ({ path: name, size: 1, sha256: 'a'.repeat(64) })) };
  for (const name of ['../escape', '/absolute', 'a//b', 'a/./b', 'a/../b', 'a\\b', 'a\0b', 'libx.so', 'x.node', 'libx.so.1']) {
    const manifest = structuredClone(valid); manifest.files.push({ path: name, size: 1, sha256: 'a'.repeat(64) });
    assert.throws(() => core.validateManifest(manifest), { code: 'ohos_manifest_invalid' }, name);
  }
  for (const name of [valid.files[0].path, 'runtime']) {
    const manifest = structuredClone(valid); manifest.files.push({ path: name, size: 1, sha256: 'a'.repeat(64) });
    assert.throws(() => core.validateManifest(manifest), { code: 'ohos_manifest_invalid' });
  }
});

test('实际符号链接父目录拒绝写入；未知目录内容不因OH递归rmdir被删', async () => {
  const c = await makeCase('links');
  await c.storage.ensureDirectory(c.installer.root);
  const outside = path.join(c.dir, 'outside'); await fs.mkdir(outside);
  await fs.symlink(outside, c.installer.root + '/node_modules');
  await assert.rejects(c.installer.install(c.manifest, () => {}), { code: 'ohos_path_link' });
  assert.deepEqual(await fs.readdir(outside), []);
  await fs.unlink(c.installer.root + '/node_modules');
  const d = c.installer.root + '/runtime/ohos/preload.mjs';
  await fs.mkdir(d, { recursive: true }); await fs.writeFile(d + '/foreign.txt', 'user');
  await assert.rejects(c.installer.install(c.manifest, () => {}), { code: 'ohos_install_path_conflict' });
  assert.equal(await fs.readFile(d + '/foreign.txt', 'utf8'), 'user');
});

test('日志快照/live边界单调去重、2000行有界，敏感值不落日志', () => {
  const logs = new core.RuntimeLogs();
  logs.rememberSecret('fixture-secret-123');
  const first = logs.append('url ?token=abc&x=1 fixture-secret-123 Authorization: Bearer XYZ', 'stdout');
  assert.equal(first.seq, 1);
  assert.doesNotMatch(first.line, /abc|fixture-secret-123|XYZ/);
  const snapshot = logs.snapshot(300);
  const next = logs.append('tail', 'stderr');
  const combined = [...snapshot.entries, ...[first, next].filter(e => e.seq > snapshot.throughSeq)];
  assert.deepEqual(combined.map(e => e.seq), [1, 2]);
  for (let i = 0; i < 2500; i++) logs.append('line', 'stdout');
  assert.equal(logs.snapshot(5000).entries.length, 2000);
  assert.equal(logs.snapshot(0).throughSeq, 2502);
  assert.equal(logs.snapshot(0).entries.length, 0);
  assert.equal(logs.append('x'.repeat(10000), 'stdout').line.length < 8300, true);
});

test('start参数拒绝暗中改变宿主配置，明确拒绝sdcard和安全模式', () => {
  for (const key of ['NODE_OPTIONS', 'DSH_HOME', 'DSH_AGENTS_HOME', 'LD_PRELOAD', 'DSH_GO_OHOS_SIM', 'DSH_GO_OHOS_NATIVE_LIBRARY_DIR', 'NODE_PATH', 'HOME']) {
    assert.throws(() => core.validateEnvironment(new Map([[key, 'value']])), { code: 'ohos_invalid_env' });
  }
  assert.deepEqual(core.validateEnvironment(new Map([['DEEPSEEK_API_KEY', 'test-only']])), { DEEPSEEK_API_KEY: 'test-only' });
  assert.throws(() => core.validateStartOptions(true, null), { code: 'ohos_unsupported' });
  assert.throws(() => core.validateStartOptions(false, 'safe'), { code: 'ohos_unsupported' });
  core.validateStartOptions(false, 'normal');
});

test('原生库目录从公开Context的根和相对分量拼接，不接受绝对、空、NUL或越界分量', () => {
  assert.equal(core.resolveNativeLibraryDir('/private/安装包/', 'libs/arm64/'), '/private/安装包/libs/arm64');
  assert.equal(core.resolveNativeLibraryDir('/app/code', 'libs/arm64'), '/app/code/libs/arm64');
  for (const root of ['', '/', '//', 'relative', '/code\0bad']) {
    assert.throws(() => core.resolveNativeLibraryDir(root, 'libs/arm64'), { code: 'ohos_native_library_path' });
  }
  for (const relative of ['', '/', '/absolute', 'a//b', 'a//', '.', '..', '../b', 'a/../b', 'a/./b', 'a\0b']) {
    assert.throws(() => core.resolveNativeLibraryDir('/app/code', relative), { code: 'ohos_native_library_path' }, relative);
  }
});

test('并发install拒绝第二次进入，第一轮完成后才可继续', async () => {
  const c = await makeCase('busy');
  const first = c.installer.install(c.manifest, () => {});
  await assert.rejects(c.installer.install(c.manifest, () => {}), { code: 'install_busy' });
  await first;
  await c.installer.install(c.manifest, () => {});
});

test('并发发布完整文本不会混写同一临时文件，失败写入不会堵住后续发布', async () => {
  const c = await makeCase('atomic-text');
  const directory = c.dir + '/diagnostics';
  await fs.mkdir(directory);
  const target = directory + '/report.md';
  const values = ['# 长报告\n' + '甲'.repeat(10000), '# 短报告\n乙', ''];
  const other = new OhosRuntimeStorage(c.resources, c.dir);
  for (let attempt = 0; attempt < 10; attempt++) {
    const results = await Promise.allSettled(values.map((value, index) =>
      (index % 2 === 0 ? c.storage : other).writeTextAtomic(target, value)));
    assert.deepEqual(results.map(result => result.status), ['fulfilled', 'fulfilled', 'fulfilled']);
    assert.equal(values.includes(await fs.readFile(target, 'utf8')), true);
    await assert.rejects(fs.access(target + '.tmp'));
  }
  const blocked = directory + '/blocked.md';
  await fs.symlink(target, blocked);
  const results = await Promise.allSettled([
    c.storage.writeTextAtomic(blocked, '不能替换链接'),
    other.writeTextAtomic(target, '# 恢复正常\n'),
  ]);
  assert.equal(results[0].status, 'rejected');
  assert.equal(results[0].reason.code, 'ohos_path_link');
  assert.equal(results[1].status, 'fulfilled');
  assert.equal(await fs.readFile(target, 'utf8'), '# 恢复正常\n');
});

async function controllerCase(name) {
  native.reset();
  const c = await makeCase(name);
  const cacheDir = path.join(c.dir, 'cache'); await fs.mkdir(cacheDir);
  const context = { filesDir: c.dir, cacheDir, resourceManager: c.resources,
    bundleCodeDir: '/private/安装包', applicationInfo: { nativeLibraryPath: 'libs/arm64/' } };
  const controller = new RuntimeController(context); controllers.push(controller);
  await controller.initialize();
  return { ...c, context, controller };
}



test('初始化raw close瞬时失败后，同一Controller的安装可重试且并发安装被拒绝', async () => {
  native.reset();
  const c = await makeCase('initial-close-retry');
  const cacheDir = path.join(c.dir, 'cache'); await fs.mkdir(cacheDir);
  const context = { filesDir: c.dir, cacheDir, resourceManager: c.resources,
    applicationInfo: { accessTokenId: 1 } };
  const close = c.resources.closeRawFd.bind(c.resources);
  let calls = 0, enter, release;
  const entered = new Promise(resolve => { enter = resolve; });
  const released = new Promise(resolve => { release = resolve; });
  c.resources.closeRawFd = async asset => {
    calls++;
    if (calls === 1) throw new Error('injected first close failure');
    if (calls === 2) { enter(); await released; }
    return close(asset);
  };
  const controller = new RuntimeController(context); controllers.push(controller);
  await controller.initialize();
  assert.equal(controller.snapshot().get('bundledVersion'), null);
  assert.equal(c.resources.opened.size, 1);
  const installing = controller.install(false);
  try {
    await Promise.race([entered, installing.then(() => { throw new Error('retired close not reached'); })]);
    await assert.rejects(controller.install(false), { code: 'install_busy' });
    await Promise.all([controller.initialize(), controller.initialize()]);
    assert.equal(c.resources.reads.length, 1);
    release(); await installing;
    assert.equal(controller.snapshot().get('phase'), 'installed');
    assert.equal(controller.snapshot().get('error'), null);
    assert.equal(c.resources.opened.size, 0);
    assert.equal(activeInflaters(), 0);
    assert.equal(c.resources.reads.length, 2);
    assert.equal(native.starts.length, 0);
  } finally {
    release(); await Promise.allSettled([installing]);
    await c.storage.withBundledRuntime(async () => {});
  }
});

test('随包初读持续失败时每次显式安装重试有界，之后恢复不需新Controller', async () => {
  native.reset();
  const c = await makeCase('initial-open-retry');
  const cacheDir = path.join(c.dir, 'cache'); await fs.mkdir(cacheDir);
  const open = c.resources.getRawFd.bind(c.resources);
  let unavailable = true, attempts = 0;
  c.resources.getRawFd = async asset => {
    attempts++;
    if (unavailable) throw new Error('injected unavailable raw resource');
    return open(asset);
  };
  const controller = new RuntimeController({ filesDir: c.dir, cacheDir,
    resourceManager: c.resources, applicationInfo: { accessTokenId: 1 } });
  controllers.push(controller);
  await controller.initialize();
  assert.equal(attempts, 1);
  await assert.rejects(controller.install(false), { code: 'ohos_payload_missing' });
  assert.equal(attempts, 2);
  await controller.initialize();
  assert.equal(attempts, 2);
  unavailable = false;
  await controller.install(false);
  assert.equal(controller.snapshot().get('phase'), 'installed');
  assert.equal(controller.snapshot().get('error'), null);
  assert.equal(attempts, 4);
  assert.equal(c.resources.opened.size, 0);
  assert.equal(activeInflaters(), 0);
  assert.equal(native.starts.length, 0);
});

test('懒加载：构造、状态、日志、路径、安装、诊断与未启动stop不加载Native', async () => {
  assert.equal(nativeModuleLoads, 0);
  const c = await controllerCase('lazy-remote-only');
  const previous = RuntimeController.shared; RuntimeController.shared = c.controller;
  const plugin = new RuntimePlugin();
  const binding = { getApplicationContext: () => c.context, getBinaryMessenger: () => ({ setMessageHandler() {} }) };
  plugin.onAttachedToEngine(binding);
  const invoke = method => new Promise(resolve => plugin.onMethodCall(new MethodCall(method, null), {
    success: value => resolve(value), error: (code, message) => resolve({ code, message }), notImplemented: () => resolve('missing'),
  }));
  try {
    assert.equal(await invoke('guestRoot'), c.dir + '/runtime/rootfs');
    assert.equal((await invoke('getStatus')).get('phase'), 'notInstalled');
    await invoke('getLogs'); await invoke('getLogSnapshot'); await invoke('failureLog');
    const sink = () => {}; c.controller.subscribe(sink); await Promise.resolve(); c.controller.unsubscribe(sink);
    await c.controller.install(false);
    await c.controller.publishDiagnostics('# fixture');
    c.controller.stop(); c.controller.collect(); c.controller.clearFailure();
    assert.equal(nativeModuleLoads, 0);
    assert.equal(native.starts.length, 0);
  } finally { plugin.onDetachedFromEngine(binding); RuntimeController.shared = previous; }
});

test('懒加载：等待动态import期间stop仍取消启动，并发start不重复进入', async () => {
  assert.equal(nativeModuleLoads, 0);
  const c = await controllerCase('lazy-cancel-loading'); await c.controller.install(false);
  let enter, release;
  const entered = new Promise(resolve => { enter = resolve; });
  const paused = new Promise(resolve => { release = resolve; });
  nativeModuleControl.beforeLoad = () => { enter(); return paused; };
  const starting = c.controller.start(null, false, null, false);
  const rejected = assert.rejects(starting, { code: 'ohos_start_cancelled' });
  try {
    await entered;
    await c.controller.start(null, false, null, false);
    assert.equal(c.controller.snapshot().get('phase'), 'starting');
    assert.equal(native.starts.length, 0);
    c.controller.stop(); release(); await rejected;
    assert.equal(native.starts.length, 0); assert.equal(native.state.consumed, false);
    assert.equal(nativeModuleLoads, 1);
    await c.controller.start(null, false, null, false);
    assert.equal(native.starts.length, 1); assert.equal(nativeModuleLoads, 1);
  } finally { release(); nativeModuleControl.beforeLoad = null; }
});

test('Context原生库路径无效时明确报错且不消耗本进程唯一Node启动机会', async () => {
  const c = await controllerCase('native-path-reject');
  await c.controller.install(false);
  c.context.applicationInfo.nativeLibraryPath = '../outside';
  await assert.rejects(c.controller.start(null, false, null, true), { code: 'ohos_native_library_path' });
  assert.equal(native.starts.length, 0); assert.equal(native.state.consumed, false);
  assert.match(c.controller.snapshot().get('error'), /原生库目录/);
  c.context.applicationInfo.nativeLibraryPath = 'libs/arm64/';
  await c.controller.start(null, false, null, true);
  assert.equal(native.starts[0].nativeLibraryDir, '/private/安装包/libs/arm64');
});

test('并发publishDiagnostics在目录尚不存在时也返回完整可用报告', async () => {
  const c = await controllerCase('diagnostics-concurrent');
  await c.controller.install(false);
  const values = ['# 长报告\n' + '甲'.repeat(10000), '# 短报告\n乙', ''];
  const results = await Promise.all(values.map(value => c.controller.publishDiagnostics(value)));
  for (let i = 0; i < results.length; i++) assert.equal(results[i].get('bytes'), Buffer.byteLength(values[i]));
  assert.equal(values.includes(await fs.readFile(results[0].get('path'), 'utf8')), true);
});

test('status与事件沿用Dart字段，ready前不报告running，stop完成后不能再次启动Node', async () => {
  const c = await controllerCase('state');
  const received = [];
  const sink = event => received.push(event);
  c.controller.subscribe(sink);
  await c.controller.install(false);
  await c.controller.start(new Map([['DEEPSEEK_API_KEY', 'fixture-credential']]), false, null, true);
  assert.equal(native.starts.length, 1);
  assert.deepEqual(native.starts[0].workspaceRoots, [c.dir + '/runtime/rootfs/root/workspace']);
  assert.equal(native.starts[0].nativeLibraryDir, '/private/安装包/libs/arm64');
  assert.equal(c.controller.snapshot().get('phase'), 'starting');
  assert.equal(c.controller.snapshot().get('token'), null);
  native.state.phase = 'running'; native.state.baseUrl = 'http://127.0.0.1:3080'; native.state.token = 'fixture-token';
  native.events.push({kind: 'ready', baseUrl: native.state.baseUrl, token: native.state.token},
    {kind: 'log', stream: 'stdout', line: 'fixture-credential fixture-token'});
  c.controller.collect();
  const status = c.controller.snapshot();
  assert.equal(status.get('phase'), 'running'); assert.equal(status.get('token'), 'fixture-token');
  assert.equal(status.get('currentExecutionMode'), 'ohos-embedded');
  assert.equal(status.get('directEngineActive'), false);
  assert.doesNotMatch(c.controller.recentLogs(1)[0], /fixture-/);
  assert.equal(received.some(e => e.get('type') === 'logs'), true);
  await c.controller.start(null, false, null, true); assert.equal(native.starts.length, 1);
  c.controller.stop(); assert.equal(native.stops, 1); assert.equal(c.controller.snapshot().get('phase'), 'stopping');
  native.state.phase = 'exited'; native.state.exitCode = 0; native.state.baseUrl = null; native.state.token = null;
  native.events.push({kind: 'exit', exitCode: 0}); c.controller.collect();
  assert.equal(c.controller.snapshot().get('phase'), 'installed');
  assert.equal(c.controller.snapshot().get('token'), null);
  await assert.rejects(c.controller.start(null, false, null, true), {code: 'ohos_restart_required'});
  await assert.rejects(c.controller.install(false), {code: 'ohos_restart_required'});
  c.controller.unsubscribe(sink);
});

test('stop发生在异步启动准备期间时不会随后偷偷启动；用户AGENTS与关闭可视化指令保留', async () => {
  const c = await controllerCase('cancel-setup');
  await c.controller.install(false);
  const starting = c.controller.start(null, false, null, false);
  c.controller.stop();
  await assert.rejects(starting, {code: 'ohos_start_cancelled'});
  assert.equal(native.starts.length, 0);
  assert.doesNotMatch(await fs.readFile(c.dir + '/runtime/rootfs/root/.dsh/AGENTS.md', 'utf8'), /可视化回复/);
  await fs.writeFile(c.dir + '/runtime/rootfs/root/.dsh/AGENTS.md', '# 用户自有规则\n');
  await c.controller.start(null, false, null, true);
  assert.equal(await fs.readFile(c.dir + '/runtime/rootfs/root/.dsh/AGENTS.md', 'utf8'), '# 用户自有规则\n');
});

test('原生在线程间于drain与state之间退出时保留下一次收尾轮询，失败快照含完整尾部', async () => {
  const c = await controllerCase('terminal-read-order');
  await c.controller.install(false);
  await c.controller.start(null, false, null, true);
  native.state.phase = 'running'; native.state.token = 'test-tail-secret';
  native.afterDrain = () => {
    native.afterDrain = null;
    native.events.push({ kind: 'log', stream: 'stderr', line: '中文适配层尾部 test-tail-secret' });
    native.events.push({ kind: 'exit', exitCode: 23 });
    native.state.phase = 'exited'; native.state.exitCode = 23; native.state.token = null;
  };
  c.controller.collect();
  assert.notEqual(c.controller.timer, null, '旧批次不允许因稍后终态停掉最后一次drain');
  c.controller.collect();
  assert.equal(c.controller.timer, null);
  assert.match(c.controller.recentLogs(50).join('\n'), /中文适配层尾部/);
  assert.match(c.controller.failureLog().join('\n'), /中文适配层尾部/);
  assert.match(c.controller.failureLog().join('\n'), /code=23/);
  assert(!c.controller.failureLog().join('\n').includes('test-tail-secret'));
  const finished = c.controller.failureLog();
  c.controller.collect();
  assert.deepEqual(c.controller.failureLog(), finished);
});

test('实际RuntimePlugin逐个处理28个Android方法，unknown才notImplemented，日志快照形状兼容', async () => {
  const c = await controllerCase('plugin');
  const plugin = new RuntimePlugin();
  const cleared = [];
  const messenger = { setMessageHandler: (name, handler) => cleared.push([name, handler]) };
  const binding = { getApplicationContext: () => c.context, getBinaryMessenger: () => messenger };
  plugin.onAttachedToEngine(binding);
  const invoke = (method, args = {}) => new Promise(resolve => plugin.onMethodCall(new MethodCall(method, new Map(Object.entries(args))), {
    success: value => resolve({kind: 'success', value}),
    error: (code, message) => resolve({kind: 'error', code, message}),
    notImplemented: () => resolve({kind: 'unknown'}),
  }));
  assert.equal((await invoke('getStatus')).value.get('phase'), 'notInstalled');
  assert.equal((await invoke('install')).kind, 'success');
  const snapshot = (await invoke('getLogSnapshot')).value;
  assert.deepEqual(snapshot.get('entries'), []); assert.equal(Number.isInteger(snapshot.get('throughSeq')), true);
  assert.equal((await invoke('getLogs')).kind, 'success');
  assert.equal((await invoke('clearFailure')).kind, 'success');
  assert.equal((await invoke('failureLog')).kind, 'success');
  assert.equal((await invoke('lastKnownGood')).value.get('available'), false);
  assert.equal((await invoke('storageStatus')).value.get('granted'), false);
  assert.equal((await invoke('networkMetered')).value, false);
  const diagnostic = await invoke('publishDiagnostics', {markdown: '# 测试\n'});
  assert.equal(diagnostic.kind, 'success'); assert.equal(diagnostic.value.get('bytes'), Buffer.byteLength('# 测试\n'));
  assert.equal((await invoke('publishDiagnostics', {markdown: ''})).value.get('bytes'), 0);
  for (const method of ['reset', 'restoreLastKnownGood', 'safePreflight', 'moveAside', 'setAutoSafe', 'setDirectEngine',
    'requestStorage', 'openAllFilesAccess', 'batteryExempt',
    'requestBatteryExempt', 'backgroundSettings', 'openBackgroundSettings', 'openVendorSettings', 'voiceModelLine']) {
    assert.deepEqual((await invoke(method)).code, 'ohos_unsupported', method);
  }
  assert.equal((await invoke('installManagedSkill')).value.get('reason'), 'invalid');
  assert.equal((await invoke('cancelManagedSkill')).value, null);
  assert.equal((await invoke('start', {phoneStorage: true})).code, 'ohos_unsupported');
  assert.equal((await invoke('start', {env: new Map()})).value, null);
  assert.equal((await invoke('stop')).value, null);
  native.state.phase = 'exited'; native.state.token = null;
  await invoke('getStatus');
  assert.equal((await invoke('unknownMethod')).kind, 'unknown');
  const events = [];
  const controller = plugin.controller;
  const firstEvent = Promise.withResolvers();
  plugin.onListen(null, { success: value => { events.push(value); firstEvent.resolve(); } });
  await firstEvent.promise;
  const count = events.length;
  plugin.onDetachedFromEngine(binding);
  assert.deepEqual(cleared, [['dsh/runtime/events', null]]);
  native.events.push({ kind: 'log', stream: 'stdout', line: 'late event after detach' });
  controller.collect();
  assert.equal(events.length, count);
  assert.equal((await invoke('getStatus')).code, 'ohos_detached');
});

test('P2 v6: 原生参数、真实沙箱目录和交付指令使用同一个guestRoot', async () => {
  const c = await controllerCase('v6-layout-中文');
  await c.controller.install(false);
  await c.controller.start(null, false, null, true);
  const root = c.dir + '/runtime/rootfs';
  const options = native.starts[0];
  assert.equal(options.guestRoot, root);
  assert.equal(options.dshHome, root + '/root/.dsh');
  assert.deepEqual(options.workspaceRoots, [root + '/root/workspace']);
  assert.equal(options.runtimeRoot, c.dir + '/dsh-runtime/tree');
  for (const relative of ['root/.dsh', 'root/.agents', 'root/workspace/DSH-Go']) {
    assert((await fs.stat(root + '/' + relative)).isDirectory());
  }
  const instructions = await fs.readFile(root + '/root/.dsh/AGENTS.md', 'utf8');
  assert(instructions.includes(root + '/root/workspace/DSH-Go'));
  const diagnostic = await c.controller.publishDiagnostics('# 实际报告\n');
  assert.equal(diagnostic.get('path'), root + '/root/.dsh/dsh-app/diagnostics.md');
  assert.equal(await fs.readFile(diagnostic.get('path'), 'utf8'), '# 实际报告\n');
});

test('P2 v6: guestRoot在未安装且清单读取失败时仍同步返回且不读rawfile', async () => {
  native.reset();
  managedSkillIo.reset();
  const previous = RuntimeController.shared;
  RuntimeController.shared = null;
  let reads = 0, answer;
  const context = { filesDir: '/private/中文 应用/files', cacheDir: '/private/cache', resourceManager: {
    async getRawFd() { reads++; throw new Error('no runtime archive fixture'); },
    async getRawFileContent() { throw new Error('bare manifest reads are forbidden'); },
  } };
  const binding = { getApplicationContext: () => context, getBinaryMessenger: () => ({ setMessageHandler() {} }) };
  const plugin = new RuntimePlugin();
  try {
    plugin.onAttachedToEngine(binding);
    plugin.onMethodCall(new MethodCall('guestRoot', null), {
      success: value => { answer = { value }; }, error: code => { answer = { code }; },
      notImplemented: () => { answer = { missing: true }; },
    });
    assert.equal(reads, 0, 'guestRoot不应先读取安装清单');
    assert.deepEqual(answer, { value: context.filesDir + '/runtime/rootfs' });
    assert.equal(native.starts.length, 0);
    assert.equal(managedSkillIo.calls.length, 0);
  } finally {
    await new Promise(resolve => setImmediate(resolve));
    plugin.onDetachedFromEngine(binding);
    RuntimeController.shared = previous;
  }
});

test('P2 v6: reopenApp无Ability明确报错且不误启Node', async () => {
  const c = await controllerCase('v6-reopen-no-ability');
  const previous = RuntimeController.shared; RuntimeController.shared = c.controller;
  const plugin = new RuntimePlugin();
  const binding = { getApplicationContext: () => c.context, getBinaryMessenger: () => ({ setMessageHandler() {} }) };
  try {
    plugin.onAttachedToEngine(binding);
    const answer = await new Promise(resolve => plugin.onMethodCall(new MethodCall('reopenApp', null), {
      success: value => resolve({ value }), error: (code, message) => resolve({ code, message }),
      notImplemented: () => resolve({ missing: true }),
    }));
    assert.equal(answer.code, 'ohos_no_ability');
    assert.equal(native.starts.length, 0); assert.equal(native.stops, 0);
  } finally { plugin.onDetachedFromEngine(binding); RuntimeController.shared = previous; }
});

test('P2 v6: reopenApp先stop，当前Ability固定Want及SDK错误码消息原样返回', async () => {
  const c = await controllerCase('v6-reopen-current');
  const previous = RuntimeController.shared; RuntimeController.shared = c.controller;
  const plugin = new RuntimePlugin();
  const binding = { getApplicationContext: () => c.context, getBinaryMessenger: () => ({ setMessageHandler() {} }) };
  const attempts = []; let failure = { code: 16000065, message: 'fixture ability not focused' };
  const ability = { context: { filesDir: '/different/AbilityContext/files',
    abilityInfo: { bundleName: 'test.bundle', moduleName: 'entry', name: 'EntryAbility' },
    async restartApp(want) { attempts.push({ want, stops: native.stops }); if (failure) throw failure; },
  } };
  const invoke = () => new Promise(resolve => plugin.onMethodCall(new MethodCall('reopenApp', null), {
    success: value => resolve({ value }), error: (code, message) => resolve({ code, message }),
    notImplemented: () => resolve({ missing: true }),
  }));
  try {
    plugin.onAttachedToEngine(binding);
    plugin.onAttachedToAbility?.({ getAbility: () => ability });
    await c.controller.install(false); await c.controller.start(null, false, null, true);
    native.state.phase = 'running'; native.state.token = 'fixture-reopen-token';
    assert.deepEqual(await invoke(), { code: '16000065', message: 'fixture ability not focused' });
    assert.deepEqual(attempts[0], { want: { bundleName: 'test.bundle', moduleName: 'entry', abilityName: 'EntryAbility' }, stops: 1 });
    assert.equal(c.controller.snapshot().get('managedSkillGeneration'), null);
    native.state.phase = 'exited'; native.state.token = null;
    failure = { code: 16000064, message: 'fixture restart too frequently' };
    assert.deepEqual(await invoke(), { code: '16000064', message: 'fixture restart too frequently' });
    failure = null;
    assert.deepEqual(await invoke(), { value: null });
    assert.equal(native.starts.length, 1);
  } finally { plugin.onDetachedFromEngine(binding); RuntimeController.shared = previous; }
});

async function managedChannelCase(name) {
  managedSkillIo.reset();
  const c = await controllerCase(name);
  const previous = RuntimeController.shared; RuntimeController.shared = c.controller;
  const bindings = [];
  const attach = (plugin = new RuntimePlugin()) => {
    const binding = { getApplicationContext: () => c.context, getBinaryMessenger: () => ({ setMessageHandler() {} }) };
    const replies = [];
    plugin.onAttachedToEngine(binding); bindings.push([plugin, binding]);
    const invoke = (method, args = {}) => new Promise(resolve => plugin.onMethodCall(
      new MethodCall(method, new Map(Object.entries(args))), {
        success(value) { replies.push([method, value]); resolve(value); },
        error(code, message) { replies.push([method, code]); resolve({ code, message }); },
        notImplemented() { replies.push([method, 'notImplemented']); resolve({ missing: true }); },
      }));
    return { plugin, binding, replies, invoke };
  };
  const attached = attach();
  assert.equal((await attached.invoke('getStatus')).get('managedSkillGeneration'), null);
  assert.equal(managedSkillIo.calls.length, 0);
  await c.controller.install(false); await c.controller.start(null, false, null, true);
  native.state.phase = 'running'; native.state.baseUrl = 'http://127.0.0.1:3080'; native.state.token = 'fixture-managed-token';
  const request = async (connection, id, text = '中文技能') => ({ requestId: id,
    expectedRoot: c.controller.paths.guestRoot, expectedToken: native.state.token,
    expectedGeneration: (await connection.invoke('getStatus')).get('managedSkillGeneration'), name: 'dsh-go-ui',
    files: new Map([['notes/readme.txt', text], ['SKILL.md', '---\n# dsh-go:managed\nname: dsh-go-ui\n---\n' + text + '\n']]),
  });
  return { ...c, ...attached, attach, request,
    directory: c.controller.paths.dshHome + '/skills/dsh-go-ui',
    close() {
      for (const [plugin, binding] of bindings) plugin.onDetachedFromEngine(binding);
      RuntimeController.shared = previous;
      managedSkillIo.before = null; managedSkillIo.after = null;
    },
  };
}

test('P2 v6: 实际通道安装中文技能，Activity变化保留grant而stop立即退休', async () => {
  const c = await managedChannelCase('v6-managed-wire');
  try {
    const args = await c.request(c, 'first');
    assert(Number.isSafeInteger(args.expectedGeneration) && args.expectedGeneration > 0);
    assert.equal(managedSkillIo.calls.length, 0, 'status/ready不做技能文件IO');
    const reply = await c.invoke('installManagedSkill', args);
    assert.deepEqual(Object.fromEntries(reply), { result: 'installed', current: true, reason: null });
    assert.equal(await fs.readFile(c.directory + '/notes/readme.txt', 'utf8'), '中文技能');
    const renames = managedSkillIo.calls.filter(call => call.operation === 'rename');
    assert.equal(renames.at(-1).to, c.directory + '/SKILL.md');
    c.plugin.onAttachedToAbility({ getAbility: () => ({ context: {} }) });
    c.plugin.onDetachedFromAbility();
    assert.equal((await c.invoke('getStatus')).get('managedSkillGeneration'), args.expectedGeneration);
    const updated = await c.invoke('installManagedSkill', await c.request(c, 'update', '更新后的正文'));
    assert.equal(updated.get('result'), 'updated'); assert.equal(updated.get('current'), true);
    assert.equal(await fs.readFile(c.directory + '/notes/readme.txt', 'utf8'), '更新后的正文');
    const oldRequest = await c.request(c, 'after-stop', '不能落盘');
    await c.invoke('stop');
    assert.equal((await c.invoke('getStatus')).get('managedSkillGeneration'), null);
    const count = managedSkillIo.calls.length;
    const stale = await c.invoke('installManagedSkill', oldRequest);
    assert.equal(stale.get('current'), false); assert.equal(stale.get('reason'), 'stale');
    assert.equal(managedSkillIo.calls.length, count);
    assert.equal(await fs.readFile(c.directory + '/notes/readme.txt', 'utf8'), '更新后的正文');
    assert.equal(managedSkillIo.opened.size, 0);
  } finally { c.close(); }
});

test('P2 v6: 旧owner取消/迟到detach不伤新owner，同id新任务等待真实IO退出', { timeout: 15000 }, async () => {
  const c = await managedChannelCase('v6-managed-owner');
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  let oldWork, newWork;
  try {
    let held = false;
    managedSkillIo.before = async operation => {
      if (!held && operation.operation === 'write') { held = true; entered.resolve(); await release.promise; }
    };
    const oldArgs = await c.request(c, 'same-id', '旧owner未完成内容');
    oldWork = c.invoke('installManagedSkill', oldArgs);
    await entered.promise;
    const next = c.attach();
    const newArgs = await c.request(next, 'same-id', '新owner内容');
    assert(newArgs.expectedGeneration > oldArgs.expectedGeneration);
    newWork = next.invoke('installManagedSkill', newArgs);
    await c.invoke('cancelManagedSkill', { requestId: 'same-id' });
    c.plugin.onDetachedFromEngine(c.binding);
    const oldReply = await oldWork;
    assert.equal(oldReply.get('reason'), 'stale'); assert.equal(oldReply.get('current'), false);
    assert.equal(managedSkillIo.calls.filter(call => call.operation === 'write').length, 1,
      '新owner不能在旧物理write尚未退出时占用第二个写槽');
    release.resolve();
    const fresh = await newWork;
    assert.deepEqual(Object.fromEntries(fresh), { result: 'installed', current: true, reason: null });
    assert.equal(await fs.readFile(c.directory + '/notes/readme.txt', 'utf8'), '新owner内容');
    assert.equal(c.replies.filter(([method]) => method === 'installManagedSkill').length, 1);
    assert.equal(next.replies.filter(([method]) => method === 'installManagedSkill').length, 1);
    const third = c.attach(next.plugin);
    next.plugin.onDetachedFromEngine(next.binding);
    const thirdArgs = await c.request(third, 'third', '同实例新binding');
    assert(thirdArgs.expectedGeneration > newArgs.expectedGeneration);
    assert.equal((await third.invoke('installManagedSkill', thirdArgs)).get('current'), true);
    assert.equal(managedSkillIo.opened.size, 0);
  } finally {
    release.resolve();
    await Promise.allSettled([oldWork, newWork].filter(Boolean));
    c.close();
  }
});

test('P2 v6: 未轮询的宿主终态也阻止迟到技能提交和成功回报', { timeout: 15000 }, async () => {
  const c = await managedChannelCase('v6-managed-host-exit');
  const entered = Promise.withResolvers(), release = Promise.withResolvers();
  let work;
  try {
    let held = false;
    managedSkillIo.before = async operation => {
      if (!held && operation.operation === 'write') { held = true; entered.resolve(); await release.promise; }
    };
    work = c.invoke('installManagedSkill', await c.request(c, 'exit-before-publish'));
    await entered.promise;
    native.state.phase = 'exited'; native.state.token = null; native.state.exitCode = 0;
    // No collect() or stop(): the service must consult the current host state.
    release.resolve();
    const reply = await work;
    assert.equal(reply.get('current'), false); assert.equal(reply.get('reason'), 'stale');
    await assert.rejects(fs.access(c.directory + '/SKILL.md'), { code: 'ENOENT' });
    await assert.rejects(fs.access(c.directory + '/notes/readme.txt'), { code: 'ENOENT' });
    assert.equal(managedSkillIo.opened.size, 0);
    assert.equal(c.replies.filter(([method]) => method === 'installManagedSkill').length, 1);
  } finally { release.resolve(); if (work) await work; c.close(); }
});

test('真实Entry回调在无本机引擎时只更新内存，迟到的旧Ability后台不得覆盖新前台', async () => {
  const previous = RuntimeController.shared; RuntimeController.shared = null; native.reset();
  const old = new EntryAbility(), current = new EntryAbility();
  const before = { sends: lifecycleControl.sends.length, queries: lifecycleControl.queries, loads: nativeModuleLoads };
  old.onForeground(); old.onBackground(); current.onForeground(); old.onBackground(); old.onDestroy();
  assert.equal(RuntimeController.foreground, true); assert.equal(RuntimeController.ability, current);
  const c = await controllerCase('lifecycle-remote-callbacks'); RuntimeController.shared = c.controller;
  try {
    assert.equal(c.controller.snapshot().get('lifecycle').get('foreground'), true);
    assert.equal(lifecycleControl.sends.length, before.sends); assert.equal(lifecycleControl.queries, before.queries);
    assert.equal(nativeModuleLoads, before.loads);
    current.onBackground(); assert.equal(c.controller.snapshot().get('lifecycle').get('foreground'), false);
    assert.deepEqual(current.superCalls, ['foreground', 'background']);
  } finally { current.onDestroy(); RuntimeController.shared = previous; }
});

test('真实Controller收集已就绪host后才同步当前前后台，stop后不再发晚到控制', async () => {
  const c = await controllerCase('lifecycle-ready-order');
  const previous = RuntimeController.shared; RuntimeController.shared = c.controller;
  const ability = new EntryAbility(); const before = lifecycleControl.sends.length;
  try {
    ability.onForeground();
    assert.equal(lifecycleControl.sends.length, before);
    native.state.phase = 'running'; native.state.baseUrl = 'http://127.0.0.1:3080'; native.state.token = 'lifecycle-fixture-token';
    c.controller.collect(); await Promise.resolve();
    assert.equal(lifecycleControl.sends.length, before + 1);
    assert.equal(lifecycleControl.sends.at(-1).observation.foreground, true);
    ability.onBackground(); await Promise.resolve();
    assert.equal(lifecycleControl.sends.at(-1).observation.foreground, false);
    const count = lifecycleControl.sends.length;
    c.controller.stop(); ability.onForeground(); c.controller.collect(); await Promise.resolve();
    assert.equal(lifecycleControl.sends.length, count);
  } finally { ability.onDestroy(); RuntimeController.shared = previous; }
});

test('生命周期同步失败通过现有Dart可读error和notice事件暴露，同类重试不反复弹提示且恢复会清除', async () => {
  const c = await controllerCase('lifecycle-visible-error');
  const previous = RuntimeController.shared; RuntimeController.shared = c.controller;
  const ability = new EntryAbility(), events = [];
  const sink = event => events.push(event);
  const settle = async () => { for (let i = 0; i < 6; i++) await Promise.resolve(); };
  c.controller.subscribe(sink); await settle(); events.length = 0;
  try {
    lifecycleControl.failure = new Error('fixture-raw-error-never-display'); ability.onForeground();
    native.state.phase = 'running'; native.state.baseUrl = 'http://127.0.0.1:3080'; native.state.token = 'lifecycle-fixture-token';
    c.controller.collect(); await settle();
    const failed = c.controller.snapshot();
    assert.equal(failed.get('phase'), 'running', 'synchronization failure does not invent a Node exit');
    assert.equal(failed.get('lifecycle').get('error'), 'ohos_lifecycle_unavailable');
    assert.match(failed.get('error'), /前后台状态尚未同步/);
    assert.equal(events.filter(e => e.get('type') === 'notice').length, 1);
    assert(events.some(e => e.get('type') === 'status' && e.get('status').get('error') === failed.get('error')));
    ability.onForeground(); await settle(); assert.equal(events.filter(e => e.get('type') === 'notice').length, 1);
    lifecycleControl.failure = null; ability.onForeground(); await settle();
    const recovered = c.controller.snapshot(); assert.equal(recovered.get('error'), null);
    assert(events.some(e => e.get('type') === 'status' && e.get('status').get('error') === null));
    if (process.env.DSH_LIFECYCLE_DART_WIRE) {
      const plain = value => value instanceof Map ? Object.fromEntries([...value].map(([k, v]) => [k, plain(v)]))
        : Array.isArray(value) ? value.map(plain) : value;
      await fs.writeFile(process.env.DSH_LIFECYCLE_DART_WIRE, JSON.stringify({ failed: plain(failed), recovered: plain(recovered), events: events.map(plain) }));
    }
  } finally {
    lifecycleControl.failure = null; c.controller.unsubscribe(sink); c.controller.stop(); ability.onDestroy(); RuntimeController.shared = previous;
  }
});
