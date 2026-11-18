import fs from 'node:fs/promises';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
import {prepareArchiveModules, makeArchive, observation} from './runtime-archive-fixture.mjs';

const [repo,before,output]=process.argv.slice(2);
await fs.mkdir(output,{recursive:true});
const actual=await prepareArchiveModules(repo,path.join(output,'after-modules'));
const old=await prepareArchiveModules(repo,path.join(output,'before-modules'));
const source=await fs.readFile(path.join(before,'app/ohos/entry/src/main/ets/runtime/OhosRuntimeStorage.ets'),'utf8');
const fixture=new URL('./runtime-archive-fixture.mjs',import.meta.url).href;
const ts=createRequire(path.join(process.env.OHOS_TYPESCRIPT_PREFIX,'package.json'))('typescript');
let text=source.replace("import fs from '@ohos.file.fs';",`import {fileIo as fs} from '${fixture}';`)
  .replace("import fileHash from '@ohos.file.hash';",`import {fileHash} from '${fixture}';`)
  .replace("import util from '@ohos.util';",`import {util} from '${fixture}';`)
  .replace("import resourceManager from '@ohos.resourceManager';",'')
  .replace("import { BusinessError } from '@ohos.base';",'')
  .replace("from './RuntimeCore'","from './RuntimeCore.mjs'");
text=ts.transpileModule(text,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText;
const oldPath=path.join(output,'before-modules/OriginalOhosRuntimeStorage.mjs');await fs.writeFile(oldPath,text);
const {OhosRuntimeStorage:OriginalStorage}=await import(pathToFileURL(oldPath));
const directory=path.join(output,'application');await fs.mkdir(directory);
const pack=await makeArchive(path.join(output,'runtime.hap'),{
  'node_modules/@deepseek-ai/dsh/lib/bin.js':'bin','runtime/ohos/preload.mjs':'preload',
  'runtime/ohos/process/index.mjs':'process','runtime/ohos/process/sandbox.mjs':'sandbox',
  'runtime/ohos/capabilities/index.mjs':'capabilities','runtime/ohos/lifecycle/index.mjs':'lifecycle',
  'runtime/bridge/dsh-go-bridge/lib/index.js':'bridge',
  'runtime/ohos/process/child-process.mjs':'child-process',
});
const original=new old.RuntimeInstaller(new OriginalStorage(pack.resources,directory),directory+'/runtime');
let failure;
try {await original.install(pack.manifest,()=>{});} catch(error){failure=String(error);}
assert.match(failure,/unexpected rawfile: dsh-runtime\/files\//);
assert.equal(await original.installed(),null);
const storage=new actual.OhosRuntimeStorage(pack.resources,directory);
const installer=new actual.RuntimeInstaller(storage,directory+'/runtime');
await storage.withBundledRuntime(async()=>installer.install(await storage.readBundledManifest(),()=>{}));
assert.equal((await installer.installed()).runtimeVersion,pack.manifest.runtimeVersion);
assert.equal(observation.fd.size,0);
await fs.writeFile(path.join(output,'report.json'),JSON.stringify({beforeSource:before,
  beforeStorageSHA256:createHash('sha256').update(source).digest('hex'),beforeError:failure,
  beforeInstalled:false,afterInstalled:true,afterVersion:pack.manifest.runtimeVersion,
  scope:'actual original/new Storage+RuntimeInstaller methods on actual ZIP/FS; ResourceManager/zlib are explicit platform test boundaries'},null,2)+'\n');
console.log('original loose-rawfile installer failed; archive installer resumed same journal and completed');
