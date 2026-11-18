import test, { after, afterEach, beforeEach } from 'node:test';
import { assertEntryAbilityImports } from '../../../runtime/tests/ohos/entry-ability-fixture.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
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
// Each test's synthetic Context is a separate app process; reset only the
// module singleton state in this test transform, never production admission.
nativeHostText += '\nexport function resetNativeFixture() { loaded = null; loading = null; touched = false; recovery = null; }\n';
await fs.writeFile(path.join(temp, 'NativeHost.mts'), nativeHostText);
const nativeHostModule = await import(pathToFileURL(path.join(temp, 'NativeHost.mts')));
beforeEach(() => { nativeHostModule.resetNativeFixture(); RuntimeController.shared = null; });
const recoveryFixtureUrl = pathToFileURL(path.join(temp, 'recovery-io.mjs')).href;
await fs.writeFile(path.join(temp, 'recovery-io.mjs'), `import { fileIo } from '${fixtureUrl}';
export const recoveryIo = {...fileIo, async lstat(path) { try { return await fileIo.lstat(path); } catch(error) { if(error.code==='ENOENT')error.code=13900002; throw error; } }};
`);
for (const name of ['RuntimeRecovery', 'OhosRecoveryStorage']) {
  let text = await fs.readFile(path.join(source, name+'.ets'), 'utf8');
  text = text.replace("import common from '@ohos.app.ability.common';", '')
    .replace("import { BusinessError } from '@ohos.base';", '')
    .replace("import fs from '@ohos.file.fs';", `import { recoveryIo as fs } from '${recoveryFixtureUrl}';`)
    .replace("import { RecoveryStorage }", "import type { RecoveryStorage }")
    .replace("from './RuntimeRecovery'", "from './RuntimeRecovery.mts'")
    .replace("from './OhosRuntimeStorage'", "from './OhosRuntimeStorage.mts'")
    .replace("from './RuntimeCore'", "from './RuntimeCore.mts'");
  await fs.writeFile(path.join(temp, name+'.mts'), text);
}

// The last good config runs on its real modules; a Controller without them keeps its own.
if (controllerText.includes("from './RuntimeLastKnownGood'")) {
  const lkgIoUrl=pathToFileURL(path.join(temp,'lkg-io.mjs')).href;
  await fs.writeFile(path.join(temp,'lkg-io.mjs'), `import {recoveryIo} from '${recoveryFixtureUrl}';
export const lkgIo={...recoveryIo,async open(...args){try{return await recoveryIo.open(...args);}catch(e){if(e.code==='ENOENT')e.code=13900002;throw e;}},async listFile(...args){try{return await recoveryIo.listFile(...args);}catch(e){if(e.code==='ENOENT')e.code=13900002;throw e;}}};`);
  let text = (await fs.readFile(path.join(source,'RuntimeLastKnownGood.ets'),'utf8'))
    .replace("from './RuntimeCore'", "from './RuntimeCore.mts'");
  await fs.writeFile(path.join(temp,'RuntimeLastKnownGood.mts'),text);
  text=(await fs.readFile(path.join(source,'OhosLastKnownGoodStorage.ets'),'utf8'))
    .replace("import fs from '@ohos.file.fs';", `import { lkgIo as fs } from '${lkgIoUrl}';`)
    .replace("import fileHash from '@ohos.file.hash';", `import { fileHash } from '${fixtureUrl}';`)
    .replace("import util from '@ohos.util';", `import { util } from '${fixtureUrl}';`)
    .replace("import common from '@ohos.app.ability.common';", '')
    .replace("import { BusinessError } from '@ohos.base';", '')
    .replace("import bundleManager from '@ohos.bundle.bundleManager';", `const bundleManager={BundleFlag:{GET_BUNDLE_INFO_WITH_HAP_MODULE:2},async getBundleInfoForSelf(){return {name:'fixture.dsh',versionCode:1,hapModulesInfo:[{name:'entry',hashValue:'fixture-hap-hash'}]};}};`)
    .replace("import { LkgStorage, LkgPair, LkgProfile, LkgVersion }", "import type { LkgStorage, LkgPair, LkgProfile, LkgVersion }")
    .replace("from './RuntimeLastKnownGood'", "from './RuntimeLastKnownGood.mts'")
    .replace("from './RuntimeCore'", "from './RuntimeCore.mts'")
    .replace("from './OhosRuntimeStorage'", "from './OhosRuntimeStorage.mts'");
  await fs.writeFile(path.join(temp,'OhosLastKnownGoodStorage.mts'),text);
  controllerText=controllerText.replace('RuntimeLastKnownGood, LkgBoot','RuntimeLastKnownGood, type LkgBoot')
    .replace("from './RuntimeLastKnownGood'", "from './RuntimeLastKnownGood.mts'")
    .replace("from './OhosLastKnownGoodStorage'", "from './OhosLastKnownGoodStorage.mts'");
}

controllerText = controllerText.replace("import common from '@ohos.app.ability.common';", '')
  .replace("import hilog from '@ohos.hilog';", 'const hilog = { info() {}, warn() {} };')
  .replace("import UIAbility from '@ohos.app.ability.UIAbility';", '')
  .replace("import util from '@ohos.util';", `import { util } from '${fixtureUrl}';`)
  .replace("import connection from '@ohos.net.connection';", `import { connection } from '${hostFixtureUrl}';`)
  .replace("from 'libdsh_host.so'", `from '${hostFixtureUrl}'`)
  .replace('RuntimeChannelError, RuntimeManifest, RuntimeFile, RuntimeInstaller', 'RuntimeChannelError, type RuntimeManifest, type RuntimeFile, RuntimeInstaller')
  .replace('  InstallProgress,', '  type InstallProgress,')
  .replace("from './RuntimeCore'", "from './RuntimeCore.mts'")
  .replace('configureNativeRecovery, NativeRecoveryGate', 'configureNativeRecovery, type NativeRecoveryGate')
  .replace("from './RuntimeRecovery'", "from './RuntimeRecovery.mts'")
  .replace("from './OhosRecoveryStorage'", "from './OhosRecoveryStorage.mts'")
  .replace("from './NativeHost'", "from './NativeHost.mts'")
  .replace("from './PersistedRuntimeLog'", "from './PersistedRuntimeLog.mts'")
  .replace("from './RuntimePaths'", "from './RuntimePaths.mts'")
  .replace("RuntimeLifecycle, HostLifecycleAck", "RuntimeLifecycle, type HostLifecycleAck")
  .replace("from './RuntimeLifecycle'", "from './RuntimeLifecycle.mts'")
  .replace("from './TransientTaskOwner'", "from './TransientTaskOwner.mts'")
  .replace("from './OhosLifecycleTransport'", `from '${hostFixtureUrl}'`)
  .replace('LinuxControl, LinuxRunRequest', 'LinuxControl, type LinuxRunRequest')
  .replace("from './LinuxControl'", `from '${hostFixtureUrl}'`)
  .replace("from './BackgroundCompute'", `from '${hostFixtureUrl}'`)
  .replace("from './ManagedSkillService'", "from './ManagedSkillService.mts'")
  .replace("from './OhosRuntimeStorage'", "from './OhosRuntimeStorage.mts'");
let transientText = (await fs.readFile(path.join(source, 'TransientTaskOwner.ets'), 'utf8'))
  .replace("import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';", `import {backgroundTaskManager} from '${hostFixtureUrl}';`)
  .replace("import common from '@ohos.app.ability.common';\n", '')
  // Long background has its own tests; this channel runs as a listing build would, without the permission.
  .replace("import { ContinuousTaskOwner } from './ContinuousTaskOwner';",
    'class ContinuousTaskOwner { eligible() { return false; } request() { return false; } stop() {} active() { return false; } cleanupPending() { return false; } error() { return null; } }')
  .replace("import { NativeHostModule } from './NativeHost';", '')
  .replace("import { HostLifecycleAck } from './RuntimeLifecycle';", '');
await fs.writeFile(path.join(temp, 'TransientTaskOwner.mts'), transientText);
const controllerPath = path.join(temp, 'RuntimeController.mts');
await fs.writeFile(controllerPath, controllerText);
const { RuntimeController } = await import(pathToFileURL(controllerPath));
const { util: recoveryUtil } = await import(fixtureUrl);
recoveryUtil.generateRandomUUID = randomUUID;
let entryText = await fs.readFile(path.join(source, '../entryability/EntryAbility.ets'), 'utf8');
assertEntryAbilityImports(entryText);
entryText = entryText.replace(/^import .*;\n/gm, '');
await fs.writeFile(path.join(temp, 'EntryAbility.mts'),
  `import { RuntimeController } from './RuntimeController.mts';\nimport { FlutterAbility } from '${hostFixtureUrl}';\n` +
  `const OhosKeyboardLog = class { attach() {} detach() {} setForeground() {} };\n` +
  `const VoicePlugin = { onForeground() {}, onBackground() {} };\n` +
  `const SpeechPlugin = { onForeground() {}, onBackground() {} };\n` +
  `const CompanionVoicePlugin = { onForeground() {}, onBackground() {} };\n` +
  `const StreamingAsrPlugin = { onForeground() {}, onBackground() {} };\n` +
  `const MediaVideoPlugin = { onForeground() {}, onBackground() {}, onDestroy() {} };\n` +
  `const PictureShortcutPlugin = { onForeground() {}, onBackground() {} };\n` +
  `const AppLinksPlugin = { onForeground() {}, onBackground() {} };\n` +
  `const PastePlugin = { onForeground() {}, onBackground() {} };\n` +
  `const NativeFilesPlugin = { onForeground() {}, onBackground() {} };\n` +
  `const NativeMediaPlugin = { onForeground() {}, onBackground() {} };\n` +
  `const AuthorizedWorkspacesPlugin = { onForeground() {}, onBackground() {}, onDestroy() {} };\n` + entryText);
const { default: EntryAbility } = await import(pathToFileURL(path.join(temp, 'EntryAbility.mts')));
let phoneText = (await fs.readFile(path.join(source, '../phone/PhoneBridge.ets'), 'utf8'))
  .replace("import common from '@ohos.app.ability.common';", '')
  .replace("import cryptoFramework from '@ohos.security.cryptoFramework';", `import { phoneCrypto as cryptoFramework } from '${hostFixtureUrl}';`)
  .replace("import util from '@ohos.util';", `import { util } from '${fixtureUrl}';`)
  .replace("NativeHostModule, loadNativeHost", "type NativeHostModule, loadNativeHost")
  .replace("PhoneEffects, PhoneEffectDenied, PhoneEffectResult", "PhoneEffects, PhoneEffectDenied, type PhoneEffectResult")
  .replace("from '../runtime/NativeHost'", "from './NativeHost.mts'")
  .replace("from '../runtime/RuntimeCore'", "from './RuntimeCore.mts'")
  .replace("from './PhoneEffects'", `from '${hostFixtureUrl}'`);
await fs.writeFile(path.join(temp, 'PhoneBridge.mts'), phoneText);
let pluginText = await fs.readFile(path.join(source, 'RuntimePlugin.ets'), 'utf8');
pluginText = pluginText.replace("import { LinuxRunRequest } from './LinuxControl';", '');
pluginText = pluginText.replace("from '../phone/PhoneBridge'", "from './PhoneBridge.mts'").replace(/^import .* from '@ohos\/flutter_ohos[^\n]+\n/gm, '')
  .replace("import { BusinessError } from '@ohos.base';", '')
  .replace("import hilog from '@ohos.hilog';", 'const hilog = { info() {}, warn() {} };')
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
    await controller.recovery.pending;
  }
  controllers.length = 0;
  RuntimeController.foreground = false; RuntimeController.ability = null;
});
const files = {
  'node_modules/@deepseek-ai/dsh/lib/bin.js': 'console.log("fixture entry");',
  'runtime/ohos/preload.mjs': 'export const fixture = true;',
  'runtime/ohos/process/index.mjs': 'export function apply() {}',
  'runtime/ohos/process/sandbox.mjs': 'export function apply() {}',
  'runtime/ohos/lifecycle/index.mjs': 'export function apply() {}',
  'runtime/ohos/capabilities/index.mjs': 'export function apply() {}',
  'runtime/ohos/phone/index.mjs': 'export function apply() {}',
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
  // Files are written in several lanes, so the committed one need not be the first listed,
  // and a rename in another lane may land just before the stop.
  const committedFiles = [];
  for (const file of c.manifest.files) {
    const text = await fs.readFile(c.installer.root + '/' + file.path, 'utf8').catch(() => null);
    if (text !== null) { assert.equal(text, files[file.path]); committedFiles.push(file.path); }
  }
  assert(committedFiles.length >= 1 && committedFiles.length < c.manifest.files.length, committedFiles.join());
  const inflatedBefore = inflateActivity.initialized;
  await c.installer.install(c.manifest, () => {});
  assert(c.resources.reads.every(asset => asset === RUNTIME_ARCHIVE_ASSET));
  assert.equal(inflateActivity.initialized - inflatedBefore, Object.keys(files).length - committedFiles.length);
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
  // Another lane may already have committed the real file before the link stopped the install.
  await fs.rm(d, { force: true });
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

test('start参数拒绝暗中改变宿主配置，模式仅允许normal或safe且拒绝sdcard', () => {
  for (const key of ['NODE_OPTIONS', 'DSH_HOME', 'DSH_AGENTS_HOME', 'LD_PRELOAD', 'DSH_GO_OHOS_SIM', 'DSH_GO_OHOS_NATIVE_LIBRARY_DIR', 'NODE_PATH', 'HOME']) {
    assert.throws(() => core.validateEnvironment(new Map([[key, 'value']])), { code: 'ohos_invalid_env' });
  }
  assert.deepEqual(core.validateEnvironment(new Map([['DEEPSEEK_API_KEY', 'test-only']])), { DEEPSEEK_API_KEY: 'test-only' });
  assert.throws(() => core.validateStartOptions(true, null), { code: 'ohos_unsupported' });
  core.validateStartOptions(false, 'safe');
  assert.throws(() => core.validateStartOptions(false, 'arbitrary-profile'), { code: 'ohos_unsupported' });
  core.validateStartOptions(false, 'normal');
});

test('原生库目录从公开Context的根和相对分量拼接，只接受根下的绝对路径，不接受空、NUL或越界分量', () => {
  assert.equal(core.resolveNativeLibraryDir('/private/安装包/', 'libs/arm64/'), '/private/安装包/libs/arm64');
  assert.equal(core.resolveNativeLibraryDir('/app/code', 'libs/arm64'), '/app/code/libs/arm64');
  // What HarmonyOS 7.0.0.111 on a phone reports.
  assert.equal(core.resolveNativeLibraryDir('/data/storage/el1/bundle', '/data/storage/el1/bundle/libs/arm64'),
    '/data/storage/el1/bundle/libs/arm64');
  for (const absolute of ['/app/code/', '/app/code/../x', '/app/codex/libs', '/app/code//libs']) {
    assert.throws(() => core.resolveNativeLibraryDir('/app/code', absolute), { code: 'ohos_native_library_path' }, absolute);
  }
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
  const controller = RuntimeController.get(context); controllers.push(controller);
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
  const controller = RuntimeController.get(context); controllers.push(controller);
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
    await c.controller.stop(); c.controller.collect(); await c.controller.clearFailure();
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
    await c.controller.stop(); release(); await rejected;
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
  await c.controller.stop(); assert.equal(native.stops, 1); assert.equal(c.controller.snapshot().get('phase'), 'stopping');
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
  await c.controller.stop();
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
  assert.equal((await invoke('restoreLastKnownGood')).code, 'ohos_lkg_invalid');
  assert.equal((await invoke('storageStatus')).value.get('granted'), false);
  assert.equal((await invoke('networkMetered')).value, false);
  const diagnostic = await invoke('publishDiagnostics', {markdown: '# 测试\n'});
  assert.equal(diagnostic.kind, 'success'); assert.equal(diagnostic.value.get('bytes'), Buffer.byteLength('# 测试\n'));
  assert.equal((await invoke('publishDiagnostics', {markdown: ''})).value.get('bytes'), 0);
  for (const method of ['safePreflight', 'moveAside', 'setAutoSafe', 'setDirectEngine',
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
  assert.equal(options.linuxDirectory, c.dir + '/linux-tools');
  assert((await fs.stat(options.linuxDirectory)).isDirectory());
  for (const relative of ['root/.dsh', 'root/.agents', 'root/workspace/DSH-Go']) {
    assert((await fs.stat(root + '/' + relative)).isDirectory());
  }
  const instructions = await fs.readFile(root + '/root/.dsh/AGENTS.md', 'utf8');
  assert(instructions.includes(root + '/root/workspace/DSH-Go'));
  const diagnostic = await c.controller.publishDiagnostics('# 实际报告\n');
  assert.equal(diagnostic.get('path'), root + '/root/.dsh/dsh-app/diagnostics.md');
  assert.equal(await fs.readFile(diagnostic.get('path'), 'utf8'), '# 实际报告\n');
});

test('930 stop shares one Linux barrier and does not stop Node before it settles', async () => {
  const c = await controllerCase('linux-stop-barrier');
  await c.controller.install(false); await c.controller.start(null, false, null, true);
  Object.assign(native.state, {phase: 'running', baseUrl: 'http://127.0.0.1:3080', token: 'fixture-linux-control'});
  const gate = Promise.withResolvers(); let requests = 0;
  c.controller.linux = {async shutdown(url, token) {
    requests++; assert.equal(url, native.state.baseUrl); assert.equal(token, native.state.token);
    await gate.promise;
  }};
  const first = c.controller.stop(), second = c.controller.stop();
  assert.equal(first, second); assert.equal(requests, 1); assert.equal(native.stops, 0);
  assert.equal(c.controller.requestedStop, true);
  gate.resolve(); await first;
  assert.equal(native.stops, 1);
  await c.controller.stop(); assert.equal(native.stops, 1, 'already stopping does not reopen the HTTP control path');
});

test('930 unknown Linux retirement prevents Node stop and durable reset intent', async () => {
  const c = await controllerCase('linux-reset-unknown');
  await c.controller.install(false); await c.controller.start(null, false, null, true);
  Object.assign(native.state, {phase: 'running', baseUrl: 'http://127.0.0.1:3080', token: 'fixture-linux-control'});
  const sentinel = c.dir + '/linux-tools/user-data.txt'; await fs.writeFile(sentinel, 'must remain');
  c.controller.linux = {async shutdown() { throw new core.RuntimeChannelError('ohos_linux_shutdown_unconfirmed', 'fixture unknown'); }};
  await assert.rejects(c.controller.reset([], false), {code: 'ohos_linux_shutdown_unconfirmed'});
  assert.equal(native.stops, 0); assert.equal(native.state.phase, 'running');
  await assert.rejects(fs.access(c.dir + '/dsh-recovery/reset.json'), {code: 'ENOENT'});
  assert.equal(await fs.readFile(sentinel, 'utf8'), 'must remain');
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
    native.state.phase = 'running'; native.state.baseUrl = 'http://127.0.0.1:3080'; native.state.token = 'fixture-reopen-token';
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

test('930 Linux MethodChannel preserves request identity and uses only NativeHost endpoint', async () => {
  const c = await managedChannelCase('linux-channel-control');
  const calls = [];
  c.controller.linux = {
    async getStatus(url, token) { calls.push(['status', url, token]); return '{"fixture":"status"}'; },
    async setEnabled(url, token, enabled) { calls.push(['enable', url, token, enabled]); return '{"fixture":"accepted"}'; },
    async runPrivateGuest(url, token, request) { calls.push(['run', url, token, request]); return '{"fixture":"queued"}'; },
    async discardRetained(url, token) { calls.push(['discard', url, token]); return '{"fixture":"discarded"}'; },
  };
  c.controller.initialize = () => { throw Error('Linux controls must not run runtime installation or recovery'); };
  try {
    assert.equal(await c.invoke('getLinuxStatus', {baseUrl: 'http://untrusted.invalid', token: 'untrusted'}), '{"fixture":"status"}');
    assert.equal(await c.invoke('setLinuxEnabled', {enabled: false}), '{"fixture":"accepted"}');
    assert.equal((await c.invoke('setLinuxEnabled', {enabled: 'true'})).code, 'ohos_linux_arguments');
    const args = {instanceId: 'service-930', attemptId: 'attempt-930', requestId: 9,
      argv: ['python3', '-c', 'print("中文")'], cwd: '/workspace',
      env: new Map([['TEST_VALUE', 'a b'], ['__proto__', 'literal value'], ['constructor', 'kept'], ['toString', 'kept too']]), stdin: 'input\n'};
    assert.equal(await c.invoke('runLinuxPrivateGuest', args), '{"fixture":"queued"}');
    assert.deepEqual(calls.map(row => row.slice(1, 3)), Array(3).fill(['http://127.0.0.1:3080', 'fixture-managed-token']));
    assert.deepEqual(calls[2][3], {v: 1, instanceId: args.instanceId, attemptId: args.attemptId,
      action: 'runPrivateGuest', requestId: 9, argv: args.argv, cwd: '/workspace', env: Object.fromEntries(args.env), stdin: 'input\n'});
    assert.equal(Object.hasOwn(calls[2][3].env, '__proto__'), true);
    assert.deepEqual(Object.entries(JSON.parse(JSON.stringify(calls[2][3])).env), [...args.env]);
    assert.equal((await c.invoke('runLinuxPrivateGuest', {...args, env: new Map([['TEST_VALUE', 4]])})).code, 'ohos_linux_arguments');
    assert.equal(calls.length, 3);
    // 重新安装 Linux: no arguments reach Node; the endpoint is NativeHost's.
    assert.equal(await c.invoke('discardLinuxRetained', {baseUrl: 'http://untrusted.invalid', token: 'untrusted'}), '{"fixture":"discarded"}');
    assert.deepEqual(calls[3], ['discard', 'http://127.0.0.1:3080', 'fixture-managed-token']);
    c.controller.requestedStop = true;
    assert.equal((await c.invoke('discardLinuxRetained')).code, 'ohos_linux_stopping');
    assert.equal(calls.length, 4);
  } finally { c.close(); }
});

test('Linux proxy MethodChannel validates the codec map without starting installation', async () => {
  const c = await managedChannelCase('linux-channel-proxy');
  const calls = [];
  c.controller.linux = {
    async setProxy(url, token, proxy) { calls.push([url, token, proxy]); return '{"fixture":"proxy-accepted"}'; },
  };
  c.controller.initialize = () => { throw Error('proxy configuration must not initialize runtime'); };
  const proxy = new Map([['mode', 'manual'], ['httpProxy', 'http://127.0.0.1:3128'], ['noProxy', 'fixture.invalid']]);
  try {
    assert.equal(await c.invoke('setLinuxProxy', { proxy, baseUrl: 'http://untrusted.invalid', token: 'untrusted' }), '{"fixture":"proxy-accepted"}');
    assert.deepEqual(calls, [['http://127.0.0.1:3080', 'fixture-managed-token', Object.fromEntries(proxy)]]);
    for (const invalid of [null, {}, new Map([['mode', true]]), new Map([['mode', 'direct'], ['extra', 'ignored']]),
      new Map([['mode', 'manual'], ['httpProxy', 4]])]) {
      assert.equal((await c.invoke('setLinuxProxy', { proxy: invalid })).code, 'ohos_linux_arguments');
    }
    assert.equal(calls.length, 1);
    c.controller.requestedStop = true;
    assert.equal((await c.invoke('setLinuxProxy', { proxy: new Map([['mode', 'direct']]) })).code, 'ohos_linux_stopping');
    assert.equal(calls.length, 1);
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
  await nativeHostModule.loadNativeHost(); // Explicit native presence; independent of earlier tests.
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
    await c.controller.stop(); ability.onForeground(); c.controller.collect(); await Promise.resolve();
    assert.equal(lifecycleControl.sends.length, count);
  } finally { ability.onDestroy(); RuntimeController.shared = previous; }
});

test('生命周期同步失败通过现有Dart可读error和notice事件暴露，同类重试不反复弹提示且恢复会清除', async () => {
  const c = await controllerCase('lifecycle-visible-error');
  await nativeHostModule.loadNativeHost(); // Explicit native presence; independent of earlier tests.
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
    lifecycleControl.failure = null; c.controller.unsubscribe(sink); await c.controller.stop(); ability.onDestroy(); RuntimeController.shared = previous;
  }
});

test('真实Entry销毁只退休native owner，旧Ability销毁不撤新owner且不申请短时任务', async () => {
  const c = await controllerCase('transient-owner-destroy');
  await nativeHostModule.loadNativeHost(); // Explicit native presence; independent of earlier tests.
  const previous = RuntimeController.shared; RuntimeController.shared = c.controller;
  const old = new EntryAbility(), current = new EntryAbility();
  try {
    native.state.phase = 'running'; native.state.baseUrl = 'http://127.0.0.1:3080'; native.state.token = 'owner-fixture';
    old.onForeground(); const oldOwner = native.lifecycleWrites.findLast(row => row.operation === 'owner');
    assert(oldOwner, 'actual foreground callback binds native owner');
    current.onForeground(); const writes = native.lifecycleWrites.length;
    old.onBackground(); old.onDestroy();
    assert.equal(native.lifecycleWrites.length, writes, 'stale Ability cannot retire replacement');
    current.onDestroy();
    assert.equal(native.lifecycleWrites.at(-1).operation, 'retire');
    assert.equal(native.lifecycleWrites.some(row => row.operation === 'begin'), false);
    assert.equal(RuntimeController.ability, null);
  } finally { await c.controller.stop(); RuntimeController.shared = previous; }
});

// A synthetic process restart resets only the fixture's native singletons;
// durable product recovery records and the real installed filesystem remain.
async function reopenCase(c) {
  await c.controller.recovery.pending;
  if(c.controller.timer!==null){clearInterval(c.controller.timer);c.controller.timer=null;}
  nativeHostModule.resetNativeFixture();native.reset();RuntimeController.shared=null;
  const controller=RuntimeController.get(c.context);controllers.push(controller);
  await controller.initialize();return {...c,controller};
}
const recoveryReplies = [];
async function recordRecoveryReply(commitState, reply) {
  recoveryReplies.push({commitState, code:reply.code, message:reply.message});
  if(process.env.DSH_RECOVERY_DART_WIRE) await fs.writeFile(process.env.DSH_RECOVERY_DART_WIRE, JSON.stringify(recoveryReplies));
}
function resetPlugin(c) {
  RuntimeController.shared=c.controller;const plugin=new RuntimePlugin();
  const binding={getApplicationContext:()=>c.context,getBinaryMessenger:()=>({setMessageHandler(){}})};
  plugin.onAttachedToEngine(binding);
  return {call:(args)=>new Promise(resolve=>plugin.onMethodCall(new MethodCall('reset',new Map(Object.entries(args))),{
    success:value=>resolve({value}),error:(code,message)=>resolve({code,message}),notImplemented:()=>resolve({missing:true})})),close:()=>plugin.onDetachedFromEngine(binding)};
}

test('卸载后显式安装的载荷 I/O 失败可在同一 Controller 重试并恢复保留项', async () => {
  let c = await controllerCase('uninstall-install-retry');
  await c.controller.install(false);
  const kept = c.dir + '/runtime/rootfs/root/.dsh/.env';
  await fs.mkdir(path.dirname(kept), { recursive: true });
  await fs.writeFile(kept, 'kept-settings');
  const reset = resetPlugin(c);
  try {
    assert.equal((await reset.call({ keep: ['pluginsAndSettings'], reinstall: false })).code, 'ohos_reset_committed');
  } finally { reset.close(); }
  c = await reopenCase(c);
  assert.equal(c.controller.snapshot().get('waitingInstall'), true);
  const plugin = new RuntimePlugin();
  const binding = { getApplicationContext: () => c.context,
    getBinaryMessenger: () => ({ setMessageHandler() {} }) };
  plugin.onAttachedToEngine(binding);
  const invoke = method => new Promise(resolve => plugin.onMethodCall(new MethodCall(method, new Map()), {
    success: value => resolve({ value }), error: (code, message) => resolve({ code, message }),
    notImplemented: () => resolve({ missing: true })
  }));
  const install = () => invoke('install');
  const open = fileIo.open;
  let interrupted = false;
  fileIo.open = async (...args) => {
    if (!interrupted && String(args[0]).includes('/dsh-runtime/')) {
      interrupted = true;
      throw new Error('transient payload filesystem I/O');
    }
    return open(...args);
  };
  try {
    const first = await install();
    fileIo.open = open;
    assert.equal(interrupted, true);
    assert.equal(first.code, 'ohos_runtime_error');
    assert.match(c.controller.snapshot().get('error'), /请重试安装/);
    const record = JSON.parse(await fs.readFile(c.dir + '/dsh-recovery/reset.json', 'utf8'));
    assert.equal(record.stage, 'installing');
    assert.equal(c.controller.snapshot().get('resetPending'), true);
    assert.equal(nativeHostModule.nativeHostTouched(), false);
    const keptCopy = c.dir + '/dsh-recovery/keep-' + record.id + '/root/.dsh/.env';
    assert.equal(await fs.readFile(keptCopy, 'utf8'), 'kept-settings');
    fileIo.open = async (...args) => {
      if (String(args[0]).includes('/dsh-runtime/')) throw new Error('payload I/O still unavailable');
      return open(...args);
    };
    assert.equal((await install()).code, 'ohos_runtime_error');
    assert.equal(c.controller.snapshot().get('resetPending'), true);
    assert.equal(nativeHostModule.nativeHostTouched(), false);
    assert.equal(JSON.parse(await fs.readFile(c.dir + '/dsh-recovery/reset.json', 'utf8')).stage, 'installing');
    assert.equal(await fs.readFile(keptCopy, 'utf8'), 'kept-settings');
    fileIo.open = open;
    const recoveredStatus = await invoke('getStatus');
    assert.equal(recoveredStatus.code, undefined);
    assert.equal(recoveredStatus.value.get('phase'), 'installed');
    assert.equal(recoveredStatus.value.get('error'), null);
    assert.equal((await install()).code, undefined);
    assert.equal(c.controller.snapshot().get('phase'), 'installed');
    assert.equal(c.controller.snapshot().get('resetPending'), false);
    assert.equal(c.controller.snapshot().get('waitingInstall'), false);
    assert.equal(await fs.readFile(kept, 'utf8'), 'kept-settings');
    assert.equal(nativeHostModule.nativeHostTouched(), false);
    await assert.rejects(fs.access(c.dir + '/dsh-recovery/reset.json'), { code: 'ENOENT' });
  } finally { fileIo.open = open; plugin.onDetachedFromEngine(binding); }
});

test('恢复完成后最后一次启动记录读取失败不使两层初始化缓存失配', async () => {
  let c = await controllerCase('install-finished-boot-read');
  await c.controller.install(false);
  await assert.rejects(c.controller.reset([], false), { code: 'ohos_reset_committed' });
  c = await reopenCase(c);
  const readText = fileIo.readText;
  let interrupted = false;
  fileIo.readText = async (...args) => {
    if (!interrupted && args[0] === c.dir + '/dsh-recovery/boot.json') {
      const resetExists = await fs.access(c.dir + '/dsh-recovery/reset.json').then(() => true, () => false);
      if (!resetExists) { interrupted = true; throw new Error('final boot read interrupted'); }
    }
    return readText(...args);
  };
  try {
    await assert.rejects(c.controller.install(false), /final boot read interrupted/);
    assert.equal(interrupted, true);
    assert.equal(c.controller.snapshot().get('resetPending'), false);
    fileIo.readText = readText;
    await c.controller.install(false);
    await c.controller.start(null, false, null, false);
    assert.equal(native.starts.length, 1);
  } finally { fileIo.readText = readText; await c.controller.stop(); }
});

test('recovery: two unclean engine generations persist strikes/failure; clearing notice cannot reopen automatic-start budget',async()=>{
 let c=await controllerCase('rescue-two-exits');await c.controller.install(false);
 for(let i=0;i<2;i++){
  await c.controller.start(null,false,null,false);native.state.phase='exited';native.state.exitCode=23;native.state.token=null;c.controller.collect();await c.controller.recovery.pending;
  assert.equal(c.controller.snapshot().get('strikes'),i+1);c=await reopenCase(c);
 }
 const state=c.controller.snapshot();assert.equal(state.get('strikes'),2);assert.equal(state.get('failure').get('kind'),'killed');assert.equal(state.get('safeState'),'off');assert.equal(state.get('autoSafe'),false);
 await c.controller.clearFailure();assert.equal(c.controller.snapshot().get('failure'),null);assert.equal(c.controller.snapshot().get('strikes'),2);
});
for (const [permission, eligible] of [['granted', true], ['denied', false], ['unknown', false]]) {
  test(`long task eligibility reports ${permission} as ${eligible}, asked once, and only with an engine started`, async () => {
    lifecycleControl.permission = permission;
    try {
      const c = await controllerCase(`long-task-${permission}`);
      await c.controller.install(false);
      const queries = lifecycleControl.queries;
      assert.equal(c.controller.snapshot().get('longTaskEligible'), false);
      assert.equal(lifecycleControl.queries, queries, 'nothing started, nothing asked');
      await c.controller.start(null, false, null, false);
      assert.equal(c.controller.snapshot().get('longTaskEligible'), eligible);
      const asked = lifecycleControl.queries;
      assert.equal(c.controller.snapshot().get('longTaskEligible'), eligible);
      assert.equal(lifecycleControl.queries, asked);
    } finally { delete lifecycleControl.permission; }
  });
}
test('recovery: the failure says its cause is unknown; thirty seconds running clears the count, sooner does not',async()=>{
 let c=await controllerCase('rescue-healthy');await c.controller.install(false);
 await c.controller.start(null,false,null,false);c=await reopenCase(c);
 const failure=c.controller.snapshot().get('failure');assert.equal(failure.get('kind'),'killed');assert.equal(failure.get('causeUnknown'),true);assert.equal(c.controller.snapshot().get('strikes'),1);
 await c.controller.start(null,false,null,false);native.state.phase='running';native.state.baseUrl='http://127.0.0.1:3080';native.state.token='fixture-linux-control';
 const realNow=Date.now,start=realNow();
 try{
  Date.now=()=>start;c.controller.collect();Date.now=()=>start+29999;c.controller.collect();await c.controller.recovery.pending;
  assert.equal(c.controller.snapshot().get('strikes'),1);
  Date.now=()=>start+30000;c.controller.collect();await c.controller.recovery.pending;
  assert.equal(c.controller.snapshot().get('strikes'),0);assert.equal(c.controller.snapshot().get('failure'),null);
 }finally{Date.now=realNow;}
 c=await reopenCase(c);assert.equal(c.controller.snapshot().get('strikes'),1,'still unclean, once');
});
test('recovery: committed reset does not delete in old process; next process reinstalls and restores chosen bytes before native import',async()=>{
 let c=await controllerCase('rescue-reset-reinstall');await c.controller.install(false);
 const kept=c.dir+'/runtime/rootfs/root/.dsh/dsh-go/ui.json';await fs.mkdir(path.dirname(kept),{recursive:true});await fs.writeFile(kept,'user-ui');
 const plugin=resetPlugin(c);try{assert.equal((await plugin.call({keep:['uiAndSkills'],reinstall:true})).code,'ohos_reset_committed');}finally{plugin.close();}
 assert.equal(await fs.readFile(kept,'utf8'),'user-ui');await assert.rejects(nativeHostModule.loadNativeHost(),{code:'ohos_restart_required'});assert.equal(nativeHostModule.nativeHostTouched(),false);
 c=await reopenCase(c);assert.equal(c.controller.snapshot().get('phase'),'installed');assert.equal(await fs.readFile(kept,'utf8'),'user-ui');assert.equal(c.controller.snapshot().get('resetPending'),false);assert.equal(nativeHostModule.nativeHostTouched(),false);
});
test('recovery: legacy reset is uninstall, repeated reopen does not install, explicit install restores kept bytes',async()=>{
 let c=await controllerCase('rescue-uninstall');await c.controller.install(false);
 const kept=c.dir+'/runtime/rootfs/root/.dsh/.env';await fs.mkdir(path.dirname(kept),{recursive:true});await fs.writeFile(kept,'synthetic-config');
 const plugin=resetPlugin(c);try{assert.equal((await plugin.call({keep:['pluginsAndSettings']})).code,'ohos_reset_committed');}finally{plugin.close();}
 for(let i=0;i<2;i++){c=await reopenCase(c);assert.equal(c.controller.snapshot().get('phase'),'notInstalled');assert.equal(c.controller.snapshot().get('waitingInstall'),true);await assert.rejects(nativeHostModule.loadNativeHost(),{code:'ohos_install_required'});}
 await c.controller.install(false);assert.equal(c.controller.snapshot().get('phase'),'installed');assert.equal(await fs.readFile(kept,'utf8'),'synthetic-config');assert.equal(c.controller.snapshot().get('resetPending'),false);
});
test('recovery: damaged boot journal fails consumer admission; reset still commits without successful initialization',async()=>{
 let c=await controllerCase('rescue-corrupt');await fs.writeFile(c.dir+'/dsh-recovery/boot.json','{"broken":true}');
 nativeHostModule.resetNativeFixture();RuntimeController.shared=null;const controller=RuntimeController.get(c.context);controllers.push(controller);c={...c,controller};
 await assert.rejects(nativeHostModule.loadNativeHost());assert.equal(nativeHostModule.nativeHostTouched(),false);
 const plugin=resetPlugin(c);try{assert.equal((await plugin.call({keep:[],reinstall:true})).code,'ohos_reset_committed');}finally{plugin.close();}
 c=await reopenCase(c);assert.equal(c.controller.snapshot().get('phase'),'installed');assert.equal(c.controller.snapshot().get('strikes'),0);
});
test('recovery: actual reset rename acknowledgement loss reaches Plugin as unknown commit and stays closed',async()=>{
 const c=await controllerCase('rescue-commit-unknown');const plugin=resetPlugin(c);const rename=fileIo.rename;
 fileIo.rename=async(from,to)=>{await rename(from,to);if(to===c.dir+'/dsh-recovery/reset.json')throw new Error('synthetic lost rename acknowledgement');};
 try{
  const reply=await plugin.call({keep:[]});assert.equal(reply.code,'ohos_reset_commit_unknown');await recordRecoveryReply('unknown',reply);
  assert.equal(JSON.parse(await fs.readFile(c.dir+'/dsh-recovery/reset.json','utf8')).reinstall,false);
  assert.equal(c.controller.snapshot().get('resetPending'),true);await assert.rejects(nativeHostModule.loadNativeHost(),{code:'ohos_restart_required'});
 }finally{fileIo.rename=rename;plugin.close();}
});
test('recovery: status observer failure cannot downgrade a successful durable reset acknowledgement',async()=>{
 const c=await controllerCase('rescue-commit-status-sink');const plugin=resetPlugin(c);const sink=()=>{throw new Error('status observer failed');};
 c.controller.sinks.push(sink);
 try{const reply=await plugin.call({keep:[]});assert.equal(reply.code,'ohos_reset_committed');await fs.access(c.dir+'/dsh-recovery/reset.json');await recordRecoveryReply('committed',reply);}
 finally{c.controller.sinks=c.controller.sinks.filter(x=>x!==sink);plugin.close();}
});

test('recovery: rejected validation reports no submitted request and writes no reset marker',async()=>{
 const c=await controllerCase('rescue-not-committed');const plugin=resetPlugin(c);
 try{const reply=await plugin.call({keep:['../']});assert.equal(reply.code,'ohos_recovery_invalid');await assert.rejects(fs.access(c.dir+'/dsh-recovery/reset.json'));assert.equal(c.controller.snapshot().get('resetPending'),false);await recordRecoveryReply('notCommitted',reply);}
 finally{plugin.close();}
});

const installRecordReplies = [];
for (const [name, content] of [
  ['json', '{broken'],
  ['schema', '{"schema":0}'],
]) {
  test(`损坏安装记录 ${name}：状态和日志可读，安装保持拒绝，明确重置后恢复`, async () => {
    let c = await controllerCase('damaged-installed-' + name);
    await c.controller.install(false);
    const record = c.dir + '/dsh-runtime/installed.json';
    const unknown = c.dir + '/dsh-runtime/tree/unowned-user-file.txt';
    await fs.writeFile(record, content);
    await fs.writeFile(unknown, 'keep-until-explicit-reset');
    await c.controller.recovery.pending;
    nativeHostModule.resetNativeFixture(); native.reset(); RuntimeController.shared = null;
    const controller = RuntimeController.get(c.context); controllers.push(controller);
    c = { ...c, controller };
    const plugin = new RuntimePlugin();
    const binding = { getApplicationContext: () => c.context,
      getBinaryMessenger: () => ({ setMessageHandler() {} }) };
    plugin.onAttachedToEngine(binding);
    const invoke = (method, args = {}) => new Promise(resolve => plugin.onMethodCall(
      new MethodCall(method, new Map(Object.entries(args))), {
        success: value => resolve({ value }), error: (code, message) => resolve({ code, message }),
        notImplemented: () => resolve({ missing: true })
      }));
    try {
      const status = await invoke('getStatus');
      const install = await invoke('install');
      installRecordReplies.push({ name, status, install });
      if (process.env.OHOS_INSTALL_RECORD_WIRE) await fs.writeFile(process.env.OHOS_INSTALL_RECORD_WIRE,
        JSON.stringify(installRecordReplies, (_key, value) => value instanceof Map ? Object.fromEntries(value) : value));
      assert.equal(status.code, undefined, '损坏安装记录时 getStatus 仍须返回状态');
      assert.equal(status.value.get('phase'), 'error');
      assert.match(status.value.get('error'), /安装记录.*损坏.*重置运行环境/);
      assert.equal(status.value.get('installedVersion'), null);
      assert.equal(install.code, 'ohos_install_record_invalid');
      assert.match(install.message, /重置运行环境/);
      assert.equal((await invoke('start')).code, 'ohos_install_record_invalid');
      for (const method of ['getLogs', 'getLogSnapshot', 'failureLog']) {
        assert.equal((await invoke(method)).code, undefined, method);
      }
      assert.equal(await fs.readFile(record, 'utf8'), content);
      assert.equal(await fs.readFile(unknown, 'utf8'), 'keep-until-explicit-reset');
      assert.equal(nativeHostModule.nativeHostTouched(), false);
      assert.equal(native.starts.length, 0);
      assert.equal((await invoke('reset', { keep: [], reinstall: true })).code, 'ohos_reset_committed');
      assert.equal(await fs.readFile(unknown, 'utf8'), 'keep-until-explicit-reset');
    } finally { plugin.onDetachedFromEngine(binding); }
    c = await reopenCase(c);
    assert.equal(c.controller.snapshot().get('phase'), 'installed');
    assert.equal(c.controller.snapshot().get('error'), null);
    assert.equal(nativeHostModule.nativeHostTouched(), false);
  });
}

for (const operation of ['install','start']) for (const badFirst of [true,false]) test(`failed status delivery must not wedge ${operation} retries (badFirst=${badFirst})`, async () => {
 const c=await controllerCase('observer-retry-'+operation+'-'+badFirst);
 if(operation==='start') await c.controller.install(false);
 const sink=()=>{throw new Error('retired messenger');};
 const received=[]; const healthy=event=>received.push(event);
 c.controller.sinks.push(...(badFirst?[sink,healthy]:[healthy,sink]));
 try {
  await c.controller[operation](...(operation==='install'?[false]:[null,false,null,false]));
 } finally { c.controller.unsubscribe(sink); c.controller.unsubscribe(healthy); }
 assert.ok(received.some(event=>event.get('type')==='status'),'healthy observer receives status');
 assert.equal(c.controller.pending,null,'failed observer must not retain operation admission');
 if(operation==='install') await c.controller.install(false);
 else { await c.controller.start(null,false,null,false); assert.equal(native.starts.length,1); }
});

test('failed initial subscription settles without recursive rejection and later observer works', async()=>{
 const c=await controllerCase('observer-initial'); const seen=[];
 const bad=()=>{throw new Error('retired messenger');};
 const good=event=>seen.push(event);
 c.controller.subscribe(bad); c.controller.subscribe(good);
 await new Promise(resolve=>setImmediate(resolve));
 assert.ok(seen.some(event=>event.get('type')==='status'));
 c.controller.unsubscribe(bad); c.controller.unsubscribe(good);
 await c.controller.install(false);
 assert.equal(c.controller.snapshot().get('phase'),'installed');
});

// Observe the actual FS boundary; never replace the install algorithm.
async function observeInstallFs(work, failSync) {
  const original = { open: fileIo.open, close: fileIo.close, fsync: fileIo.fsync };
  const descriptors = new Map();
  const events = [];
  fileIo.open = async (name, flags) => {
    const file = await original.open(name, flags);
    descriptors.set(file.fd, { path: name, directory: (flags & fileIo.OpenMode.DIR) !== 0 });
    return file;
  };
  fileIo.close = async file => {
    await original.close(file);
    descriptors.delete(file.fd);
  };
  fileIo.fsync = async fd => {
    const entry = descriptors.get(fd);
    if (entry && failSync?.(entry)) throw new Error('injected directory fsync failure');
    await original.fsync(fd);
    if (entry) events.push({ ...entry });
  };
  try { return await work(events); }
  finally { Object.assign(fileIo, original); }
}

test('install install batches payload directory commit after every file data sync', async () => {
  const c = await makeCase('install-commit-order');
  await observeInstallFs(async events => {
    let start = 0;
    await c.installer.install(c.manifest, e => {
      if (e.step === 'extract' && e.done === 0) start = events.length;
    });
    const batch = events.slice(start);
    const data = batch.map((e, i) => !e.directory && e.path.startsWith(c.dir + '/runtime/staging/') ? i : -1).filter(i => i >= 0);
    const directories = batch.map((e, i) => e.directory && (e.path === c.installer.root || e.path.startsWith(c.installer.root + '/') || e.path === c.dir + '/runtime/staging') ? i : -1).filter(i => i >= 0);
    assert.equal(data.length, c.manifest.files.length, 'every payload inode retains its data fsync');
    assert(directories.length > 0, 'the batch must actually commit payload directories');
    assert(directories[0] > data.at(-1), 'payload directory commit must follow all payload data syncs');
    const names = directories.map(i => batch[i].path);
    assert.equal(new Set(names).size, names.length, 'each payload directory has one commit sync');
    assert(names.includes(c.dir + '/runtime/staging'), 'the rename source directory must be committed too');
  });
  assert.equal((await c.installer.installed()).runtimeVersion, 'v1');
  for (const [name, text] of Object.entries(files)) assert.equal(await fs.readFile(c.installer.root + '/' + name, 'utf8'), text);
});

test('install directory commit failure keeps journal and a fresh installer safely retries matching files', async () => {
  const c = await makeCase('install-flush-failure');
  let configuring = false;
  let failed = false;
  await observeInstallFs(async () => {
    await assert.rejects(c.installer.install(c.manifest, e => {
      if (e.step === 'configure' && e.done === 0) configuring = true;
    }), /injected directory fsync failure/);
  }, e => {
    if (configuring && !failed && e.directory && e.path === c.installer.root + '/runtime/ohos') {
      failed = true; return true;
    }
    return false;
  });
  assert.equal(failed, true);
  assert.equal(await c.installer.installed(), null);
  await fs.access(c.dir + '/runtime/installing.json');
  await assert.rejects(fs.access(c.dir + '/runtime/installed.json'));
  const storage = new OhosRuntimeStorage(c.resources, c.dir);
  const installer = new core.RuntimeInstaller(storage, c.dir + '/runtime');
  const inflatedBefore = inflateActivity.initialized;
  await observeInstallFs(async events => {
    await installer.install(c.manifest, () => {});
    assert(events.some(e => e.directory && e.path === installer.root + '/runtime/ohos'));
    assert(events.some(e => e.directory && e.path === c.dir + '/runtime/staging'));
  });
  assert.equal(inflateActivity.initialized, inflatedBefore, 'existing SHA-matching data are reused');
  assert.equal((await installer.installed()).runtimeVersion, 'v1');
  assert.deepEqual(await fs.readdir(c.dir + '/runtime/staging'), []);
});

test('install retry syncs the surviving parent of obsolete files already deleted before interruption', async () => {
  const c = await makeCase('install-obsolete-retry', { ...files, 'old/nested/obsolete.txt': 'owned' });
  await c.installer.install(c.manifest, () => {});
  await fs.writeFile(c.installer.root + '/old/foreign.txt', 'foreign');
  const next = await makePack(path.join(c.dir, 'next.hap'), files, 'v2');
  const first = new core.RuntimeInstaller(new OhosRuntimeStorage(next.resources, c.dir), c.dir + '/runtime');
  await assert.rejects(first.install(next.manifest, e => {
    if (e.step === 'verify') throw new Error('interrupt after removal');
  }), /interrupt after removal/);
  await assert.rejects(fs.access(c.installer.root + '/old/nested/obsolete.txt'));
  assert.equal(await first.installed(), null);
  const retry = new core.RuntimeInstaller(new OhosRuntimeStorage(next.resources, c.dir), c.dir + '/runtime');
  await observeInstallFs(async events => {
    await retry.install(next.manifest, () => {});
    assert(events.some(e => e.directory && e.path === retry.root + '/old'), 'old journal parent remains in the commit set');
  });
  assert.equal(await fs.readFile(retry.root + '/old/foreign.txt', 'utf8'), 'foreign');
  assert.equal((await retry.installed()).runtimeVersion, 'v2');
});

test('install metadata outside the payload retains immediate atomic durability', async () => {
  const c = await makeCase('install-metadata');
  await c.installer.install(c.manifest, () => {});
  await observeInstallFs(async events => {
    await c.storage.withInstallFiles(c.dir + '/runtime', c.manifest.files.map(f => f.path), async () => {
      const before = events.length;
      await c.storage.writeTextAtomic(c.dir + '/runtime/independent.json', '{"ok":true}');
      const written = events.slice(before);
      assert(written.some(e => !e.directory && e.path.endsWith('/independent.json.tmp')));
      assert(written.some(e => e.directory && e.path === c.dir + '/runtime'));
      assert.equal(await fs.readFile(c.dir + '/runtime/independent.json', 'utf8'), '{"ok":true}');
    });
  });
});

// A power cut keeps a file's bytes only once that file was fsynced, and a directory's
// entries only once that directory was. Replay every point of a real install against
// that rule and require the same two things of each: what the installer calls installed
// is whole, and the next install finishes the job.
async function powerCutPoints(root, work) {
  const original = {};
  for (const name of ['open', 'close', 'fsync', 'write', 'rename', 'unlink', 'mkdir', 'rmdir']) original[name] = fileIo[name];
  const list = async directory => {
    const entries = new Map();
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
      const stat = await fs.lstat(path.join(directory, entry.name));
      entries.set(entry.name, { directory: entry.isDirectory(), ino: stat.ino });
    }
    return entries;
  };
  const walk = async (root, dirs = new Map(), data = new Map()) => {
    const entries = await list(root);
    dirs.set(root, entries);
    for (const [name, entry] of entries) {
      if (entry.directory) await walk(path.join(root, name), dirs, data);
      else data.set(entry.ino, await fs.readFile(path.join(root, name)));
    }
    return { dirs, data };
  };
  const durable = await walk(root);
  const points = [];
  const descriptors = new Map();
  const mark = async () => {
    const live = await walk(root);
    points.push({ durableDirs: new Map(durable.dirs), durableData: new Map(durable.data), liveDirs: live.dirs, liveData: live.data });
  };
  // The installer writes in several lanes: one operation (and its snapshot) at a time keeps
  // every point a state the disk could really be in.
  let queue = Promise.resolve();
  const serial = run => { const next = queue.then(run); queue = next.catch(() => {}); return next; };
  fileIo.open = (name, flags) => serial(async () => {
    const file = await original.open(name, flags);
    descriptors.set(file.fd, { name, directory: (flags & fileIo.OpenMode.DIR) !== 0 });
    if ((flags & fileIo.OpenMode.CREATE) !== 0) await mark();
    return file;
  });
  fileIo.close = file => serial(async () => { await original.close(file); descriptors.delete(file.fd); });
  fileIo.fsync = fd => serial(async () => {
    await original.fsync(fd);
    const entry = descriptors.get(fd);
    if (entry.directory) durable.dirs.set(entry.name, await list(entry.name));
    else durable.data.set((await fs.lstat(entry.name)).ino, await fs.readFile(entry.name));
    await mark();
  });
  for (const name of ['write', 'rename', 'unlink', 'mkdir', 'rmdir']) {
    fileIo[name] = (...args) => serial(async () => { const result = await original[name](...args); await mark(); return result; });
  }
  try { await work(); }
  finally { Object.assign(fileIo, original); }
  return points;
}

async function materialize(point, root, skip, out, mode, random) {
  const build = async (from, to) => {
    await fs.mkdir(to, { recursive: true });
    const live = point.liveDirs.get(from) ?? new Map(), kept = point.durableDirs.get(from) ?? new Map();
    const entries = mode === 'process' || (mode === 'mixed' && random() < 0.5) ? live : kept;
    for (const [name, entry] of entries) {
      if (from === root && name === skip) continue;
      if (entry.directory) await build(path.join(from, name), path.join(to, name));
      else await fs.writeFile(path.join(to, name), (mode === 'process' ? point.liveData : point.durableData).get(entry.ino) ?? Buffer.alloc(0));
    }
  };
  await build(root, out);
}

async function whole(installer, payload, version) {
  const manifest = await installer.installed();
  if (manifest === null) return null;
  assert.equal(manifest.runtimeVersion, version);
  assert.deepEqual(manifest.files.map(file => file.path).sort(), Object.keys(payload).sort());
  for (const [name, text] of Object.entries(payload)) assert.equal(await fs.readFile(installer.root + '/' + name, 'utf8'), text);
  return manifest;
}

function seeded(seed) {
  let state = seed >>> 0;
  return () => { state = (Math.imul(state, 1664525) + 1013904223) >>> 0; return state / 4294967296; };
}

function dropPack(point, root) {
  const without = dirs => {
    const copy = new Map(dirs);
    const entries = new Map(copy.get(root));
    entries.delete('next.hap');
    copy.set(root, entries);
    return copy;
  };
  return { ...point, durableDirs: without(point.durableDirs), liveDirs: without(point.liveDirs) };
}

async function replayPowerCuts(label, c, points, resources, manifest, payload, version, older) {
  const random = seeded(points.length);
  let readyAt = 0, unready = 0;
  for (const [index, point] of points.entries()) {
    for (const mode of ['power', 'process', 'mixed']) {
      const out = path.join(temp, `${label}-${index}-${mode}`);
      await materialize(point, c.dir, 'payload.hap', out, mode, random);
      const storage = new OhosRuntimeStorage(resources, out);
      const installer = new core.RuntimeInstaller(storage, out + '/runtime');
      const at = `${label} point ${index} (${mode})`;
      let found = null;
      try {
        // Before the new journal is durable the previous install is still the good one.
        const current = await installer.installed();
        if (current !== null && older !== undefined && current.runtimeVersion === older.version) {
          await whole(installer, older.payload, older.version);
        } else {
          found = await whole(installer, payload, version);
        }
      } catch (error) { error.message = `${at}: ${error.message}`; throw error; }
      if (found === null) unready++; else readyAt = Math.max(readyAt, index);
      try {
        await new core.RuntimeInstaller(new OhosRuntimeStorage(resources, out), out + '/runtime').install(manifest, () => {});
        assert.notEqual(await whole(installer, payload, version), null);
      } catch (error) { error.message = `${at}, retry: ${error.message}`; throw error; }
      await fs.rm(out, { recursive: true, force: true });
    }
  }
  return { readyAt, unready, points: points.length };
}

test('a power cut at any point of a first install never reads as installed unless it is whole', async () => {
  const c = await makeCase('install-power-cut');
  const points = await powerCutPoints(c.dir, () => c.installer.install(c.manifest, () => {}));
  const seen = await replayPowerCuts('first', c, points, c.resources, c.manifest, files, 'v1');
  assert(seen.points > 40, `saw only ${seen.points} points`);
  assert(seen.unready > 0, 'an interrupted install must read as not installed');
  assert.equal(seen.readyAt, points.length - 1, 'the finished install reads as installed');
});

test('a power cut at any point of an update keeps the old install or a whole new one', async () => {
  const c = await makeCase('install-power-cut-update', { ...files, 'old/nested/obsolete.txt': 'owned' });
  const older = { payload: { ...files, 'old/nested/obsolete.txt': 'owned' }, version: 'v1' };
  await c.installer.install(c.manifest, () => {});
  const changed = { ...files, 'runtime/ohos/preload.mjs': 'changed preload' };
  const next = await makePack(path.join(c.dir, 'next.hap'), changed, 'v2');
  const storage = new OhosRuntimeStorage(next.resources, c.dir);
  const installer = new core.RuntimeInstaller(storage, c.dir + '/runtime');
  await fs.rm(path.join(c.dir, 'payload.hap'));
  const points = await powerCutPoints(c.dir, () => installer.install(next.manifest, () => {}));
  const seen = await replayPowerCuts('update', c, points.map(point => dropPack(point, c.dir)), next.resources, next.manifest, changed, 'v2', older);
  assert(seen.points > 20, `saw only ${seen.points} points`);
  assert(seen.unready > 0, 'an interrupted update must read as not the new install');
  assert.equal(seen.readyAt, points.length - 1, 'the finished update reads as installed');
});


test('reminder access answers through the real plugin, with nothing installed or started', async () => {
  const c = await controllerCase('reminder-access');
  const plugin = new RuntimePlugin();
  plugin.onAttachedToEngine({ getApplicationContext: () => c.context,
    getBinaryMessenger: () => ({ setMessageHandler() {} }) });
  const invoke = method => new Promise(resolve => plugin.onMethodCall(
    new MethodCall(method, new Map()), {
      success: value => resolve({kind: 'success', value}),
      error: (code, message) => resolve({kind: 'error', code, message}),
      notImplemented: () => resolve({kind: 'unknown'}),
    }));
  for (const answer of ['granted', 'denied', 'unsupported']) {
    lifecycleControl.reminders = answer;
    try { assert.deepEqual(await invoke('reminderAccess'), {kind: 'success', value: answer}); }
    finally { delete lifecycleControl.reminders; }
  }
});

test('public start selects the manual safe profile through actual Controller', async () => {
  const c = await controllerCase('manual-safe-public');
  const plugin = new RuntimePlugin();
  plugin.onAttachedToEngine({ getApplicationContext: () => c.context,
    getBinaryMessenger: () => ({ setMessageHandler() {} }) });
  const invoke = (method, args = {}) => new Promise(resolve => plugin.onMethodCall(
    new MethodCall(method, new Map(Object.entries(args))), {
      success: value => resolve({kind: 'success', value}),
      error: (code, message) => resolve({kind: 'error', code, message}),
      notImplemented: () => resolve({kind: 'unknown'}),
    }));
  assert.equal((await invoke('install')).kind, 'success');
  const started = await invoke('start', {mode: 'safe', env: new Map()});
  assert.equal(started.kind, 'success', JSON.stringify(started));
  assert.equal(native.starts.length, 1);
  assert.equal(native.starts[0].safeMode, true);
  assert.equal((await invoke('getStatus')).value.get('mode'), 'safe');
  await invoke('stop');
});


test('consumed host saves manual next mode before restart and new Controller reads it', async () => {
  const c = await controllerCase('manual-safe-reopen');
  await c.controller.install(false);
  await c.controller.start(null, false, 'normal', true);
  await c.controller.stop(); native.state.phase = 'exited'; c.controller.collect();
  await c.controller.recovery.pending;
  await assert.rejects(c.controller.start(null, false, 'safe', true), {code:'ohos_restart_required'});
  assert.equal(native.starts.length, 1, 'never starts a second embedded Node');
  assert.equal(c.controller.snapshot().get('mode'), 'normal', 'running/consumed mode is not relabelled');
  assert.equal(c.controller.snapshot().get('safeState'), 'on');
  assert.equal(JSON.parse(await fs.readFile(path.join(c.dir, 'dsh-recovery/mode.json'),'utf8')).mode, 'safe');
  native.reset(); nativeHostModule.resetNativeFixture(); RuntimeController.shared = null;
  const next = RuntimeController.get(c.context); controllers.push(next);
  await next.initialize(); await next.start(null, false, null, true);
  assert.equal(native.starts.length, 1); assert.equal(native.starts[0].safeMode, true);
  await assert.rejects(next.start(null, false, 'normal', true), {code:'ohos_restart_required'});
  assert.equal(native.starts.length, 1); assert.equal(next.snapshot().get('mode'), 'safe');
  assert.equal(next.snapshot().get('safeState'), 'off');
  next.stop();
});

test('failed durable mode commit cannot start Node or request a restart', async () => {
  const c = await controllerCase('manual-safe-write-failed'); await c.controller.install(false);
  const write = c.controller.recovery.storage.write.bind(c.controller.recovery.storage);
  let failed = true;
  c.controller.recovery.storage.write = async (file, text) => {
    await write(file, text);
    if (failed && file.endsWith('/mode.json')) { failed=false; throw Error('directory fsync outcome unknown'); }
  };
  await assert.rejects(c.controller.start(null, false, 'safe', true), /outcome unknown/);
  assert.equal(native.starts.length, 0);
  assert.equal(c.controller.snapshot().get('safeState'), 'off');
  await c.controller.start(null, false, 'safe', true);
  assert.equal(native.starts.length, 1); assert.equal(native.starts[0].safeMode, true);
  await c.controller.stop();
});

test('public normal healthy boot restores its launch profile through RuntimePlugin',async()=>{
 const c=await controllerCase('lkg-public');
 c.context.bundleCodeDir=path.join(c.dir,'hap');
 const nativeDir=path.join(c.context.bundleCodeDir,'libs/arm64');await fs.mkdir(nativeDir,{recursive:true});
 await fs.writeFile(path.join(nativeDir,'libnode.so'),'fixture-node');await fs.writeFile(path.join(nativeDir,'libdsh_host.so'),'fixture-host');
 const home=path.join(c.dir,'runtime/rootfs/root/.dsh/profiles/web');await fs.mkdir(home,{recursive:true});
 const packagePath=path.join(home,'package.json'),patchPath=path.join(home,'cordis.patch.yml');
 await fs.writeFile(packagePath,JSON.stringify({name:'web',other:123,dependencies:{},dsh:{profile:{bundles:['good']}}}));await fs.writeFile(patchPath,'started: true\n');
 const plugin=new RuntimePlugin();plugin.onAttachedToEngine({getApplicationContext:()=>c.context,getBinaryMessenger:()=>({setMessageHandler(){}})});
 const invoke=(method,args={})=>new Promise(resolve=>plugin.onMethodCall(new MethodCall(method,new Map(Object.entries(args))),{success:value=>resolve({kind:'success',value}),error:(code,message)=>resolve({kind:'error',code,message}),notImplemented:()=>resolve({kind:'unknown'})}));
 assert.equal((await invoke('install')).kind,'success');assert.equal((await invoke('start',{mode:'normal',env:new Map()})).kind,'success');
 native.state.phase='running';native.state.baseUrl='http://127.0.0.1:3080';native.state.token='fixture-linux-control';const realNow=Date.now,now=realNow();
 try{
  Date.now=()=>now;c.controller.collect();
  await fs.writeFile(packagePath,JSON.stringify({name:'web',other:123,dependencies:{},dsh:{profile:{bundles:['not-booted']}}}));await fs.writeFile(patchPath,'notBooted: true\n');
  Date.now=()=>now+119999;c.controller.collect();assert.equal(await fs.stat(path.join(c.dir,'dsh-recovery/lkg.json')).then(()=>true,()=>false),false);
  Date.now=()=>now+120000;c.controller.collect();await c.controller.lkgPin;
 }finally{Date.now=realNow;}
 await invoke('stop');native.state.phase='exited';native.state.exitCode=0;c.controller.collect();await c.controller.recovery.pending;
 const preview=await invoke('lastKnownGood');assert.equal(preview.kind,'success',JSON.stringify(preview));assert.equal(preview.value.get('available'),true);
 const restored=await invoke('restoreLastKnownGood');assert.equal(restored.kind,'success',JSON.stringify(restored));assert.deepEqual(JSON.parse(await fs.readFile(packagePath,'utf8')).dsh.profile.bundles,['good']);assert.equal(await fs.readFile(patchPath,'utf8'),'started: true\n');assert.equal(JSON.parse(await fs.readFile(packagePath,'utf8')).other,123);
});


test('active native cannot restore or import during pending restore',async()=>{
 const c=await controllerCase('lkg-admission');await c.controller.install(false);await c.controller.start(null,false,'safe',true);
 native.state.phase='running';native.state.baseUrl='http://127.0.0.1:3080';native.state.token='fixture-linux-control';await assert.rejects(c.controller.restoreLastKnownGood(),{code:'ohos_lkg_engine_active'});
 native.state.phase='stopping';await assert.rejects(c.controller.lastKnownGood(),{code:'ohos_lkg_engine_active'});
 c.controller.pending='restore';await assert.rejects(nativeHostModule.loadNativeHost(),{code:'ohos_lkg_pending'});await assert.rejects(c.controller.start(null,false,'normal',true),{code:'start_busy'});await assert.rejects(c.controller.install(false),{code:'install_busy'});await assert.rejects(c.controller.reset([],false),{code:'ohos_lkg_pending'});c.controller.pending=null;
 await c.controller.stop();native.state.phase='exited';c.controller.collect();await c.controller.recovery.pending;
});
for(const mode of ['safe','normal']) test(''+mode+' mode with first missing profile never pins after two minutes',async()=>{
  const c=await controllerCase('lkg-no-pin-'+mode);await c.controller.install(false);await c.controller.start(null,false,mode,true);native.state.phase='running';native.state.baseUrl='http://127.0.0.1:3080';native.state.token='fixture-linux-control';const realNow=Date.now,now=realNow();
  try{Date.now=()=>now;c.controller.collect();Date.now=()=>now+120001;c.controller.collect();await c.controller.lkgPin;}finally{Date.now=realNow;}
  assert.equal(await fs.stat(path.join(c.dir,'dsh-recovery/lkg.json')).then(()=>true,()=>false),false);await c.controller.stop();native.state.phase='exited';c.controller.collect();await c.controller.recovery.pending;
});


test('public safe-running preview is read-only; pending intent blocks and stopped restore replans',async()=>{
 let c=await controllerCase('lkg-safe-preview');c.context.bundleCodeDir=path.join(c.dir,'hap');
 const libs=path.join(c.context.bundleCodeDir,'libs/arm64');await fs.mkdir(libs,{recursive:true});
 await fs.writeFile(path.join(libs,'libnode.so'),'fixture-node');await fs.writeFile(path.join(libs,'libdsh_host.so'),'fixture-host');
 const home=path.join(c.dir,'runtime/rootfs/root/.dsh/profiles/web');await fs.mkdir(home,{recursive:true});
 const packagePath=path.join(home,'package.json'),patchPath=path.join(home,'cordis.patch.yml');
 await fs.writeFile(packagePath,JSON.stringify({name:'web',other:123,dependencies:{},dsh:{profile:{bundles:['good']}}}));await fs.writeFile(patchPath,'started: true\n');
 await c.controller.install(false);await c.controller.start(null,false,'normal',true);native.state.phase='running';native.state.baseUrl='http://127.0.0.1:3080';native.state.token='fixture-linux-control';
 const realNow=Date.now,now=realNow();try{Date.now=()=>now;c.controller.collect();Date.now=()=>now+120000;c.controller.collect();await c.controller.lkgPin;}finally{Date.now=realNow;}
 await c.controller.stop();native.state.phase='exited';native.state.exitCode=0;c.controller.collect();await c.controller.recovery.pending;
 await fs.writeFile(packagePath,JSON.stringify({name:'web',other:456,dependencies:{},dsh:{profile:{bundles:['broken']}}}));await fs.writeFile(patchPath,'later: true\n');
 c=await reopenCase(c);await c.controller.start(null,false,'safe',true);native.state.phase='running';native.state.baseUrl='http://127.0.0.1:3080';native.state.token='fixture-linux-control';
 const plugin=new RuntimePlugin();plugin.onAttachedToEngine({getApplicationContext:()=>c.context,getBinaryMessenger:()=>({setMessageHandler(){}})});
 const invoke=method=>new Promise(resolve=>plugin.onMethodCall(new MethodCall(method,new Map()),{success:value=>resolve({kind:'success',value}),error:(code,message)=>resolve({kind:'error',code,message}),notImplemented:()=>resolve({kind:'unknown'})}));
 const before=[await fs.readFile(packagePath,'utf8'),await fs.readFile(patchPath,'utf8')];
 let initCalls=0;const initialize=c.controller.initialize.bind(c.controller);c.controller.initialize=()=>{initCalls++;return initialize();};
 const preview=await invoke('lastKnownGood');assert.equal(preview.kind,'success',JSON.stringify(preview));assert.equal(preview.value.get('available'),true);assert.deepEqual(preview.value.get('disable'),['broken']);assert.equal(initCalls,0);
 assert.equal((await invoke('restoreLastKnownGood')).code,'ohos_lkg_engine_active');
 assert.deepEqual([await fs.readFile(packagePath,'utf8'),await fs.readFile(patchPath,'utf8')],before);
 const intent=path.join(c.dir,'dsh-recovery/lkg-restore.json');await fs.writeFile(intent,'{}');initCalls=0;
 assert.equal((await invoke('lastKnownGood')).code,'ohos_lkg_pending');assert.equal(initCalls,0);assert.equal(await fs.readFile(intent,'utf8'),'{}');
 assert.deepEqual([await fs.readFile(packagePath,'utf8'),await fs.readFile(patchPath,'utf8')],before);await fs.unlink(intent);
 c.controller.lastGood.pending=true;assert.equal((await invoke('lastKnownGood')).code,'ohos_lkg_pending');c.controller.lastGood.pending=false;
 await c.controller.stop();native.state.phase='exited';native.state.exitCode=0;c.controller.collect();await c.controller.recovery.pending;
 await fs.writeFile(packagePath,JSON.stringify({name:'web',other:789,dependencies:{},dsh:{profile:{bundles:['changed-after-preview']}}}));
 const restored=await invoke('restoreLastKnownGood');assert.equal(restored.kind,'success',JSON.stringify(restored));assert.deepEqual(restored.value.get('disable'),['changed-after-preview']);
 const actual=JSON.parse(await fs.readFile(packagePath,'utf8'));assert.deepEqual(actual.dsh.profile.bundles,['good']);assert.equal(actual.other,789);assert.equal(await fs.readFile(patchPath,'utf8'),'started: true\n');
});

test('cold public preview does not initiate initialization or replay',async()=>{
 native.reset();const c=await makeCase('lkg-cold-preview');const cacheDir=path.join(c.dir,'cache');await fs.mkdir(cacheDir);
 const context={filesDir:c.dir,cacheDir,resourceManager:c.resources,bundleCodeDir:'/private/hap',applicationInfo:{nativeLibraryPath:'libs/arm64/'}};
 const controller=RuntimeController.get(context);controllers.push(controller);let initCalls=0;const initialize=controller.initialize.bind(controller);controller.initialize=()=>{initCalls++;return initialize();};
 const plugin=new RuntimePlugin();plugin.onAttachedToEngine({getApplicationContext:()=>context,getBinaryMessenger:()=>({setMessageHandler(){}})});
 const invoke=method=>new Promise(resolve=>plugin.onMethodCall(new MethodCall(method,new Map()),{success:value=>resolve({kind:'success',value}),error:(code,message)=>resolve({kind:'error',code,message}),notImplemented:()=>resolve({kind:'unknown'})}));
 assert.equal((await invoke('lastKnownGood')).code,'ohos_lkg_pending');assert.equal(initCalls,0);assert.equal(controller.initialized,null);
 assert.equal((await invoke('getStatus')).kind,'success');assert.ok(initCalls>0);
 const preview=await invoke('lastKnownGood');assert.equal(preview.kind,'success',JSON.stringify(preview));assert.equal(preview.value.get('available'),false);
});

test('a restore cut short that cannot finish still lets a reset through, and the reset ends it', async () => {
  const c = await controllerCase('lkg-stuck-reset');
  c.context.bundleCodeDir = path.join(c.dir, 'hap');
  const libs = path.join(c.context.bundleCodeDir, 'libs/arm64');
  await fs.mkdir(libs, { recursive: true });
  await fs.writeFile(path.join(libs, 'libnode.so'), 'fixture-node');
  await fs.writeFile(path.join(libs, 'libdsh_host.so'), 'fixture-host');
  await c.controller.install(false);
  const text = JSON.stringify({ dsh: { profile: { bundles: [] } } });
  const intent = path.join(c.dir, 'dsh-recovery/lkg-restore.json');
  await fs.mkdir(path.dirname(intent), { recursive: true });
  await fs.writeFile(intent, JSON.stringify({ schema: 1, identity: 'another install',
    before: { packageText: text, patchText: null }, target: { packageText: text, patchText: null } }));
  native.reset(); nativeHostModule.resetNativeFixture(); RuntimeController.shared = null;
  const stuck = RuntimeController.get(c.context); controllers.push(stuck);
  await assert.rejects(stuck.initialize(), { code: 'ohos_lkg_invalid' });
  await assert.rejects(stuck.start(null, false, null, true));
  assert.equal(native.starts.length, 0);
  await assert.rejects(stuck.reset([], false), { code: 'ohos_reset_committed' });
  native.reset(); nativeHostModule.resetNativeFixture(); RuntimeController.shared = null;
  const next = RuntimeController.get(c.context); controllers.push(next);
  await next.initialize();
  await assert.rejects(fs.access(intent), { code: 'ENOENT' });
});

test('no restore starts once a reset has been committed', async () => {
  const c = await controllerCase('lkg-after-reset');
  await c.controller.install(false);
  await assert.rejects(c.controller.reset([], false), { code: 'ohos_reset_committed' });
  await assert.rejects(c.controller.restoreLastKnownGood(), { code: 'ohos_restart_required' });
});

// 813: observe one real, already-parsed record without replacing the comparison
// algorithm or a global built-in. Node can read this private field after type
// erasure; the probe only delegates the original data value and is restored.
const manifestCurrentObservations813 = [];
function manifestReadProbe813(controller) {
  const manifest = controller.manifest;
  assert(manifest !== null && manifest.files.length > 0);
  const file = manifest.files[0];
  const descriptor = Object.getOwnPropertyDescriptor(file, 'path');
  assert(descriptor && typeof descriptor.value === 'string' && descriptor.configurable);
  let reads = 0;
  Object.defineProperty(file, 'path', {
    configurable: descriptor.configurable, enumerable: descriptor.enumerable,
    get() { reads++; return descriptor.value; }
  });
  return { count: () => reads, restore: () => Object.defineProperty(file, 'path', descriptor) };
}
function snapshotPhases813(controller, count = 20) {
  return Array.from({ length: count }, () => controller.snapshot().get('phase'));
}
after(async () => {
  if (process.env.OHOS_MANIFEST_CURRENT_WIRE) {
    await fs.writeFile(process.env.OHOS_MANIFEST_CURRENT_WIRE,
      JSON.stringify({ boundary: 'Actual Controller/installer methods; explicit per-record read probe and SDK fixtures, not ArkTS/HBN',
        observations: manifestCurrentObservations813 }, null, 2) + '\n');
  }
});

test('813 current cache: repeated real snapshots reuse a matched object pair', async () => {
  const c = await controllerCase('current-cache-hot');
  await c.controller.install(false);
  assert.equal(c.controller.snapshot().get('phase'), 'installed');
  const probe = manifestReadProbe813(c.controller);
  try {
    const before = probe.count();
    const phases = snapshotPhases813(c.controller);
    const reads = probe.count() - before;
    manifestCurrentObservations813.push({ name: 'matched-hot', queries: phases.length, reads, phases,
      nativeStarts: native.starts.length });
    assert(phases.every(phase => phase === 'installed'));
    assert.equal(native.starts.length, 0);
    assert.equal(reads, 0, 'an unchanged parsed manifest pair must not be scanned for every snapshot');
  } finally { probe.restore(); }
});

test('813 current cache: actual start rereads same-version changed hashes and later repair', async () => {
  const c = await controllerCase('current-cache-reread');
  await c.controller.install(false);
  const record = c.dir + '/dsh-runtime/installed.json';
  const original = await fs.readFile(record, 'utf8');
  const installedBefore = c.controller.installed;
  const wrong = JSON.parse(original);
  const hash = wrong.files[0].sha256;
  wrong.files[0].sha256 = (hash[0] === '0' ? '1' : '0') + hash.slice(1);
  const probe = manifestReadProbe813(c.controller);
  try {
    await fs.writeFile(record, JSON.stringify(wrong));
    const beforeMismatch = probe.count();
    await assert.rejects(c.controller.start(null, false, null, false), { code: 'ohos_install_required' });
    const mismatchReads = probe.count() - beforeMismatch;
    const installedMismatch = c.controller.installed;
    assert.notEqual(installedMismatch, installedBefore, 'the actual installer returns a fresh parsed record');
    assert.equal(installedMismatch.runtimeVersion, installedBefore.runtimeVersion);
    assert.equal(native.starts.length, 0);
    assert(mismatchReads > 0, 'the changed object pair must be compared before refusing start');
    const beforeHot = probe.count();
    const phases = snapshotPhases813(c.controller);
    const negativeHotReads = probe.count() - beforeHot;
    assert(phases.every(phase => phase === 'error'));
    assert.equal(await c.controller.publishDiagnostics('# must remain unavailable'), null);
    await fs.writeFile(record, original);
    const beforeRepair = probe.count();
    await c.controller.start(null, false, null, false);
    const repairReads = probe.count() - beforeRepair;
    assert.notEqual(c.controller.installed, installedMismatch);
    assert.equal(native.starts.length, 1, 'restored data may start through the original native boundary');
    assert(repairReads > 0, 'repair must compare the newly parsed record rather than retain false');
    manifestCurrentObservations813.push({ name: 'same-version-reread', mismatchCode: 'ohos_install_required',
      sameVersion: true, mismatchReads, negativeHotQueries: phases.length, negativeHotReads,
      repairReads, nativeStarts: native.starts.length });
    assert.equal(negativeHotReads, 0, 'an unchanged mismatching object pair must also reuse its result');
  } finally { probe.restore(); c.controller.stop(); }
});

test('813 current cache: actual missing record and install journal override a former match', async () => {
  const c = await controllerCase('current-cache-null');
  await c.controller.install(false);
  assert.equal(c.controller.snapshot().get('phase'), 'installed');
  const record = c.dir + '/dsh-runtime/installed.json';
  const journal = c.dir + '/dsh-runtime/installing.json';
  const original = await fs.readFile(record, 'utf8');
  await fs.unlink(record);
  await assert.rejects(c.controller.start(null, false, null, false), { code: 'ohos_install_required' });
  assert.equal(c.controller.installed, null);
  assert.equal(await c.controller.publishDiagnostics('# missing record'), null);
  assert.equal(native.starts.length, 0);
  await fs.writeFile(record, original);
  const parsed = JSON.parse(original);
  await fs.writeFile(journal, JSON.stringify({ schema: 1, runtimeVersion: parsed.runtimeVersion,
    ownedPaths: parsed.files.map(file => file.path), stagingHashes: [...new Set(parsed.files.map(file => file.sha256))] }));
  await assert.rejects(c.controller.start(null, false, null, false), { code: 'ohos_install_required' });
  assert.equal(c.controller.installed, null);
  assert.equal(await c.controller.publishDiagnostics('# incomplete install'), null);
  assert.equal(native.starts.length, 0);
  await fs.unlink(journal);
  try {
    await c.controller.start(null, false, null, false);
    assert.equal(native.starts.length, 1);
    manifestCurrentObservations813.push({ name: 'real-null-boundaries', missingRecordCode: 'ohos_install_required',
      journalCode: 'ohos_install_required', diagnosticsDuringNull: null, repairedNativeStarts: native.starts.length });
  } finally { c.controller.stop(); }
});

test('813 current cache: failed real install clears the old match and the same Controller retries', async () => {
  const c = await controllerCase('current-cache-install-retry');
  await c.controller.install(false);
  assert.equal(c.controller.snapshot().get('phase'), 'installed');
  const installedBefore = c.controller.installed;
  const record = c.dir + '/dsh-runtime/installed.json';
  const journal = c.dir + '/dsh-runtime/installing.json';
  const open = fileIo.open;
  const failure = new Error('813 injected installed record open failure');
  let injected = false;
  fileIo.open = async (...args) => {
    if (!injected && String(args[0]) === record + '.tmp') { injected = true; throw failure; }
    return open(...args);
  };
  try {
    await assert.rejects(c.controller.install(false), error => error === failure);
  } finally { fileIo.open = open; }
  assert.equal(injected, true);
  assert.equal(c.controller.installed, null);
  assert.equal(c.controller.snapshot().get('phase'), 'error');
  assert.equal(await c.controller.publishDiagnostics('# incomplete installation'), null);
  await fs.access(record); await fs.access(journal);
  await c.controller.install(false);
  assert.notEqual(c.controller.installed, installedBefore);
  assert.equal(c.controller.snapshot().get('phase'), 'installed');
  assert.equal(c.controller.snapshot().get('error'), null);
  await assert.rejects(fs.access(journal), { code: 'ENOENT' });
  const published = await c.controller.publishDiagnostics('# retry completed');
  assert.equal(await fs.readFile(published.get('path'), 'utf8'), '# retry completed');
  assert.equal(native.starts.length, 0);
  manifestCurrentObservations813.push({ name: 'actual-install-retry', injected, originalErrorPreserved: true,
    diagnosticsDuringNull: null, repairedPhase: c.controller.snapshot().get('phase'), nativeStarts: native.starts.length });
});


// 942: ordinary optional diagnostics through the real RuntimePlugin. The clock
// fixture advances only the existing interval scheduler, not Date or product code.
const idleDiagnosticsObservations942 = [];
after(async () => {
  if (process.env.OHOS_IDLE_DIAGNOSTICS_WIRE) {
    await fs.writeFile(process.env.OHOS_IDLE_DIAGNOSTICS_WIRE, JSON.stringify({
      boundary: 'Actual Controller/Plugin bodies and existing SDK/Native fixtures; MockTimers dispatches the original 100 ms interval; no device cadence/CPU claim',
      observations: idleDiagnosticsObservations942,
    }, null, 2) + '\n');
  }
});
const idleCounterKeys942 = ['pollTicks', 'collectCalls', 'snapshotCalls', 'emitStatusCalls',
  'lifecycleRefreshRequests', 'manifestPairChecks'];
function idlePlain942(value) {
  if (value instanceof Map) return Object.fromEntries([...value].map(([key, item]) => [key, idlePlain942(item)]));
  return value;
}
function idleValue942(reply) {
  assert.equal(reply.kind, 'success', 'the actual RuntimePlugin must implement the diagnostics method');
  assert(reply.value instanceof Map);
  assert.deepEqual([...reply.value.keys()].sort(), ['schema', 'enabled', 'observedAtMs', 'window'].sort());
  const value = idlePlain942(reply.value);
  assert.equal(value.schema, 1); assert.equal(typeof value.enabled, 'boolean');
  assert(Number.isInteger(value.observedAtMs));
  if (value.window !== null) {
    assert.deepEqual(Object.keys(value.window).sort(), ['id', 'startedAtMs', 'stoppedAtMs', 'counters'].sort());
    assert.equal(typeof value.window.id, 'string'); assert(value.window.id.length > 0);
    assert(Number.isInteger(value.window.startedAtMs));
    assert(value.window.stoppedAtMs === null || Number.isInteger(value.window.stoppedAtMs));
    assert.deepEqual(Object.keys(value.window.counters).sort(), [...idleCounterKeys942].sort());
    for (const number of Object.values(value.window.counters)) assert(Number.isSafeInteger(number) && number >= 0);
  }
  return value;
}
function idleChannel942(context) {
  const binding = { getApplicationContext: () => context, getBinaryMessenger: () => ({ setMessageHandler() {} }) };
  const plugin = new RuntimePlugin(); plugin.onAttachedToEngine(binding);
  return {
    invoke: (method, args = {}) => new Promise(resolve => plugin.onMethodCall(
      new MethodCall(method, new Map(Object.entries(args))), {
        success: value => resolve({ kind: 'success', value }),
        error: (code, message) => resolve({ kind: 'error', code, message }),
        notImplemented: () => resolve({ kind: 'notImplemented' }),
      })),
    close: () => plugin.onDetachedFromEngine(binding),
  };
}
function idleZero942() { return Object.fromEntries(idleCounterKeys942.map(key => [key, 0])); }

test('942 idle diagnostics: cold channel keeps optional window transitions independent of initialization', async () => {
  native.reset();
  const c = await makeCase('idle-diagnostics-cold');
  const cacheDir = path.join(c.dir, 'cache'); await fs.mkdir(cacheDir);
  const context = { filesDir: c.dir, cacheDir, resourceManager: c.resources,
    bundleCodeDir: '/private/hap', applicationInfo: { nativeLibraryPath: 'libs/arm64/' } };
  const controller = RuntimeController.get(context); controllers.push(controller);
  const initialize = controller.initialize;
  let initializeCalls = 0;
  controller.initialize = function (...args) { initializeCalls++; return Reflect.apply(initialize, this, args); };
  const channel = idleChannel942(context);
  const before = { files: (await fs.readdir(c.dir, { recursive: true })).sort(), reads: c.resources.reads.length,
    nativeLoads: nativeModuleLoads, nativeStarts: native.starts.length };
  try {
    const reply = await channel.invoke('getIdleDiagnostics');
    idleDiagnosticsObservations942.push({ name: 'cold-entry', reply: idlePlain942(reply.value) ?? reply,
      initializeCalls, resourceReads: c.resources.reads.length - before.reads });
    const initial = idleValue942(reply);
    assert.equal(initial.enabled, false); assert.equal(initial.window, null);
    const stillOff = idleValue942(await channel.invoke('setIdleDiagnosticsEnabled', { enabled: false }));
    assert.equal(stillOff.enabled, false); assert.equal(stillOff.window, null);
    const opened = idleValue942(await channel.invoke('setIdleDiagnosticsEnabled', { enabled: true }));
    assert.equal(opened.enabled, true); assert.equal(opened.window.stoppedAtMs, null);
    assert.deepEqual(opened.window.counters, idleZero942());
    const repeated = idleValue942(await channel.invoke('setIdleDiagnosticsEnabled', { enabled: true }));
    assert.deepEqual(repeated.window, opened.window);
    const read = idleValue942(await channel.invoke('getIdleDiagnostics'));
    assert.deepEqual(read.window, opened.window);
    const stopped = idleValue942(await channel.invoke('setIdleDiagnosticsEnabled', { enabled: false }));
    assert.equal(stopped.enabled, false); assert(Number.isInteger(stopped.window.stoppedAtMs));
    assert.equal(stopped.window.id, opened.window.id);
    assert.equal(stopped.window.startedAtMs, opened.window.startedAtMs);
    assert.deepEqual(stopped.window.counters, idleZero942());
    const repeatedStop = idleValue942(await channel.invoke('setIdleDiagnosticsEnabled', { enabled: false }));
    assert.deepEqual(repeatedStop.window, stopped.window);
    const next = idleValue942(await channel.invoke('setIdleDiagnosticsEnabled', { enabled: true }));
    assert.equal(next.enabled, true); assert.notEqual(next.window.id, opened.window.id);
    assert.equal(next.window.stoppedAtMs, null); assert.deepEqual(next.window.counters, idleZero942());
    const invalid = await channel.invoke('setIdleDiagnosticsEnabled', { enabled: 'true' });
    assert.equal(invalid.kind, 'error'); assert.equal(invalid.code, 'ohos_idle_diagnostics_arguments');
    assert.deepEqual(idleValue942(await channel.invoke('getIdleDiagnostics')).window, next.window);
    await channel.invoke('setIdleDiagnosticsEnabled', { enabled: false });
    assert.equal(initializeCalls, 0); assert.equal(controller.initialized, null);
    assert.equal(controller.timer, null);
    assert.equal(c.resources.reads.length, before.reads); assert.equal(c.resources.opened.size, 0);
    assert.equal(nativeModuleLoads, before.nativeLoads); assert.equal(native.starts.length, before.nativeStarts);
    assert.deepEqual((await fs.readdir(c.dir, { recursive: true })).sort(), before.files);
    idleDiagnosticsObservations942.push({ name: 'cold-windows', initial, opened, repeated, stopped, repeatedStop, next,
      invalidCode: invalid.code, initializeCalls, resourceReads: 0, nativeLoads: 0, nativeStarts: 0, timer: controller.timer });
  } finally { controller.initialize = initialize; channel.close(); }
});

test('942 idle diagnostics: existing poll and collect paths count calls while enabled and freeze while disabled', async t => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const c = await controllerCase('idle-diagnostics-counts');
  await c.controller.install(false);
  const channel = idleChannel942(c.context);
  const oracle = { collectCalls: 0, snapshotCalls: 0, emitStatusCalls: 0, lifecycleRefreshRequests: 0 };
  const restore = [];
  for (const [object, key, count] of [[c.controller, 'collect', 'collectCalls'],
    [c.controller, 'snapshot', 'snapshotCalls'], [c.controller, 'emitStatus', 'emitStatusCalls'],
    [c.controller.lifecycle, 'refresh', 'lifecycleRefreshRequests']]) {
    const original = object[key];
    object[key] = function (...args) { oracle[count]++; return Reflect.apply(original, this, args); };
    restore.push(() => { object[key] = original; });
  }
  const probe = manifestReadProbe813(c.controller);
  let accepted = false;
  try {
    const reply = await channel.invoke('setIdleDiagnosticsEnabled', { enabled: true });
    idleDiagnosticsObservations942.push({ name: 'count-entry', reply: idlePlain942(reply.value) ?? reply });
    const opened = idleValue942(reply); accepted = true;
    assert.deepEqual(opened.window.counters, idleZero942());
    await c.controller.start(null, false, null, false);
    assert.equal(native.starts.length, 1); assert.notEqual(c.controller.timer, null);
    c.controller.snapshot();
    const beforeTicks = { ...oracle };
    t.mock.timers.tick(1000);
    await Promise.resolve(); await new Promise(setImmediate);
    assert.equal(oracle.collectCalls - beforeTicks.collectCalls, 10, 'ten deliveries of the original interval callback');
    const observed = idleValue942(await channel.invoke('getIdleDiagnostics'));
    const expected = { pollTicks: 10, ...oracle, manifestPairChecks: probe.count() };
    assert.equal(expected.manifestPairChecks, 1, 'normal start rereads a new parsed installed record once');
    assert.equal(expected.lifecycleRefreshRequests, 1, 'one request at the original ten-collect boundary');
    assert.deepEqual(observed.window.counters, expected);
    const reread = idleValue942(await channel.invoke('getIdleDiagnostics'));
    assert.deepEqual(reread.window, observed.window, 'diagnostic reads must not collect or take ordinary snapshots');
    const disabled = idleValue942(await channel.invoke('setIdleDiagnosticsEnabled', { enabled: false }));
    assert.equal(disabled.enabled, false); assert.deepEqual(disabled.window.counters, expected);
    c.controller.collect(); c.controller.snapshot(); c.controller.emitStatus(); c.controller.lifecycle.refresh();
    t.mock.timers.tick(100);
    await Promise.resolve(); await new Promise(setImmediate);
    const frozen = idleValue942(await channel.invoke('getIdleDiagnostics'));
    assert.deepEqual(frozen.window, disabled.window);
    assert(oracle.collectCalls > expected.collectCalls && oracle.snapshotCalls > expected.snapshotCalls);
    idleDiagnosticsObservations942.push({ name: 'actual-counts', opened, observed, expected, disabled, frozen,
      callbackDriver: { api: 'node:test MockTimers(setInterval)', firstAdvanceMs: 1000, firstCallbackCount: 10,
        disabledAdvanceMs: 100, DateMocked: false }, oracleAfterDisabled: { ...oracle } });
  } finally {
    if (accepted) await channel.invoke('setIdleDiagnosticsEnabled', { enabled: false });
    probe.restore();
    await c.controller.stop(); native.state.phase = 'idle'; c.controller.collect();
    for (const undo of restore) undo();
    channel.close(); t.mock.timers.reset();
  }
});

test('1200 background polling: an acknowledged idle minute suspends periodic collection and lifecycle refresh', async t => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const c = await controllerCase('background-idle-minute');
  await c.controller.install(false);
  await c.controller.start(null, false, null, false);
  native.state.phase = 'running'; native.state.baseUrl = 'http://127.0.0.1:3080';
  native.state.token = 'idle-poll-fixture-token';
  c.controller.collect(); await Promise.resolve(); await new Promise(setImmediate);
  c.controller.setIdleDiagnosticsEnabled(true);
  try {
    for (let second = 0; second < 60; second++) {
      t.mock.timers.tick(1000);
      await Promise.resolve(); await new Promise(setImmediate);
    }
    const counts = idlePlain942(c.controller.getIdleDiagnostics()).window.counters;
    assert.equal(counts.pollTicks, 0, 'a confirmed idle background owner needs no periodic collection');
    assert.equal(counts.collectCalls, 0);
    assert.equal(counts.lifecycleRefreshRequests, 0, 'idle/released admission does not spend an activity window');
    assert.equal(native.stops, 0, 'idle throttling does not stop the engine');
  } finally {
    await c.controller.stop(); native.state.phase = 'idle'; c.controller.collect(); t.mock.timers.reset();
  }
});

test('1200 background polling: real ability callbacks restore fast foreground collection and reject a stale background callback', async t => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const c = await controllerCase('background-idle-ability');
  await c.controller.install(false); await c.controller.start(null, false, null, false);
  native.state.phase = 'running'; native.state.baseUrl = 'http://127.0.0.1:3080';
  native.state.token = 'idle-ability-fixture-token';
  c.controller.collect(); await Promise.resolve();
  const previous = RuntimeController.shared; RuntimeController.shared = c.controller;
  const old = new EntryAbility(), current = new EntryAbility();
  c.controller.setIdleDiagnosticsEnabled(true);
  const ticks = () => idlePlain942(c.controller.getIdleDiagnostics()).window.counters.pollTicks;
  try {
    old.onForeground(); current.onForeground(); old.onBackground();
    await Promise.resolve();
    let before = ticks(); t.mock.timers.tick(1000); await Promise.resolve();
    assert.equal(ticks() - before, 10, 'current foreground owner retains 100 ms polling');
    current.onBackground(); await Promise.resolve();
    before = ticks(); t.mock.timers.tick(1000); await Promise.resolve();
    assert.equal(ticks() - before, 0, 'a matching idle ACK suspends the background interval');
    current.onForeground(); await Promise.resolve();
    native.events.push({ kind: 'log', stream: 'stdout', line: 'foreground output' });
    before = ticks(); t.mock.timers.tick(100); await Promise.resolve();
    assert.equal(ticks() - before, 1);
    assert(c.controller.recentLogs(10).some(line => line.includes('foreground output')));
    await c.controller.stop();
    before = ticks(); t.mock.timers.tick(100); await Promise.resolve();
    assert.equal(ticks() - before, 1, 'stopping retains its original 100 ms observation');
    native.state.phase = 'exited'; native.state.exitCode = 0;
    c.controller.collect(); await Promise.resolve();
    before = ticks(); t.mock.timers.tick(5000); await Promise.resolve();
    assert.equal(ticks(), before, 'a settled engine has no collection timer');
  } finally {
    current.onDestroy(); RuntimeController.shared = previous;
    native.state.phase = 'idle'; c.controller.collect(); t.mock.timers.reset();
  }
});
