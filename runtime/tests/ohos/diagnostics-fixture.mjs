// Actual ETS with real Linux file descriptors. OH system facts/Flutter are explicit doubles.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { createRequire } from 'node:module';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { promisify } from 'node:util';
import vm from 'node:vm';
import { createHash } from 'node:crypto';
import { zipBytes, nativeZlib } from '../../../tooling/ohos/tests/runtime-archive-fixture.mjs';

const repo = fileURLToPath(new URL('../../../', import.meta.url));
assert(process.env.OHOS_TYPESCRIPT_PREFIX);
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
export const deferred = () => Promise.withResolvers();
export const plain = value => value instanceof Map ? Object.fromEntries([...value].map(([k,v]) => [k,plain(v)])) :
  Array.isArray(value) ? Array.from(value,plain) : value;
export async function until(check, description = 'condition') {
  const end = Date.now() + 5000;
  while (!check()) { if (Date.now() > end) throw Error('timed out: ' + description); await new Promise(r => setImmediate(r)); }
}
export const manifestFixture = () => ({ schema:1, runtimeVersion:'fixture-runtime', dshVersion:'0.0.fixture', nodeVersion:'24.22.1',
  files: ['node_modules/@deepseek-ai/dsh/lib/bin.js', 'runtime/ohos/preload.mjs',
    'runtime/ohos/process/index.mjs', 'runtime/ohos/process/sandbox.mjs',
    'runtime/ohos/lifecycle/index.mjs', 'runtime/ohos/capabilities/index.mjs',
    'runtime/bridge/dsh-go-bridge/lib/index.js', 'runtime/ohos/process/child-process.mjs'].map((path,i) => ({path,size:i+11,
      sha256:createHash('sha256').update(Buffer.alloc(i+11, i+1)).digest('hex')})) });
function publicError(error) {
  if (typeof error.code === 'number') return error;
  // Only these two codes have product special cases. Other failures stay failures.
  const wrapped = Error(error.message, { cause:error });
  wrapped.code = ({ ENOENT:13900002, EEXIST:13900015 })[error.code] ?? 13900099;
  return wrapped;
}

export async function diagnosticsFixture(t, options = {}) {
  let opt = options, modules = new Map(), activeIO = 0, maxActiveIO = 0;
  const operations = [], channels = [], fds = new Set(), timers = new Set();
  const native = { state: { phase:'idle', consumed:false, baseUrl:null, token:null, exitCode:null, errorCode:null, errorMessage:null }, events:[], loads:0 };
  const nativeModule = { getState:() => ({...native.state}), drainEvents:() => native.events.splice(0) };
  const root = opt.persistRoot ?? await fsp.mkdtemp(join(process.env.DIAGNOSTICS_TMP_PARENT ?? tmpdir(), 'dsh-diagnostics-'));
  let rawHandle = null, rawSequence = 0;
  const app = { filesDir:join(root,'files'), applicationInfo:{accessTokenId:42}, resourceManager:{
    async getRawFd(name) {
      operations.push({op:'resource',name}); assert.equal(name,'dsh-runtime/runtime.zip');
      assert.equal(rawHandle,null,'one live resource descriptor');
      if (opt.manifestHook) await opt.manifestHook();
      const manifest=opt.manifest ?? manifestFixture();
      const members=(Array.isArray(manifest.files) ? manifest.files : []).map((file,i) => ({
        name:'files/'+file.path,
        bytes:Buffer.alloc(Number.isSafeInteger(file.size) && file.size>=0 && file.size<1024 ? file.size : 1, i+1), method:8
      }));
      const inner=zipBytes([{name:'manifest.json',bytes:opt.manifestBytes ?? Buffer.from(JSON.stringify(manifest)),method:0},...members]);
      const outer=zipBytes([{name:'prefix.txt',bytes:Buffer.from('descriptor offset fixture'),method:0},
        {name:'resources/rawfile/dsh-runtime/runtime.zip',bytes:inner.bytes,method:0}]);
      const path=join(root,'manifest-fixture-'+(rawSequence++)+'.hap');
      await fsp.writeFile(path,outer.bytes); rawHandle=await fsp.open(path,'r');fds.add(rawHandle.fd);
      operations.push({op:'raw-open',fd:rawHandle.fd});
      return {fd:rawHandle.fd,offset:outer.rows[1].dataOffset,length:outer.rows[1].size};
    },
    async closeRawFd(name) {
      assert.equal(name,'dsh-runtime/runtime.zip');assert(rawHandle);
      const fd=rawHandle.fd;await rawHandle.close();fds.delete(fd);rawHandle=null;
      operations.push({op:'raw-close',fd});
    }
  } };
  await fsp.mkdir(app.filesDir, {recursive:opt.persistRoot !== undefined});
  t.after(async () => { for (const fd of fds) { try { await promisify(fs.close)(fd); } catch {} }
    if(opt.persistRoot === undefined)await fsp.rm(root,{recursive:true,force:true}); });
  async function io(name, args, operation) {
    operations.push({op:name,...args}); activeIO++; maxActiveIO = Math.max(maxActiveIO,activeIO);
    try { if (opt[name]) await opt[name](args); return await operation(); }
    catch (error) { throw publicError(error); } finally { activeIO--; }
  }
  const api = {
    OpenMode:{ READ_ONLY:fs.constants.O_RDONLY, READ_WRITE:fs.constants.O_RDWR, CREATE:fs.constants.O_CREAT,
      APPEND:fs.constants.O_APPEND, NOFOLLOW:fs.constants.O_NOFOLLOW, NONBLOCK:fs.constants.O_NONBLOCK },
    mkdir:path => io('mkdir',{path},() => fsp.mkdir(path)),
    lstat:path => io('lstat',{path},() => fsp.lstat(path)),
    open:(path,flags) => io('open',{path,flags},async () => {
      const fd = await promisify(fs.open)(path,flags,0o600); fds.add(fd); return {fd};
    }),
    stat:fd => io('stat',{fd},() => promisify(fs.fstat)(fd)),
    read:(fd,buffer,args) => io(rawHandle?.fd===fd ? 'raw-read' : 'read',{fd,length:args.length,offset:args.offset},async () => {
      assert(buffer instanceof ArrayBuffer); const size = Math.min(args.length ?? buffer.byteLength,opt.maxRead ?? Infinity);
      return (await promisify(fs.read)(fd,Buffer.from(buffer),0,size,args.offset)).bytesRead;
    }),
    write:(fd,buffer) => io('write',{fd,length:buffer.byteLength},async () => {
      assert(buffer instanceof ArrayBuffer); const size = Math.min(buffer.byteLength,opt.maxWrite ?? Infinity);
      return (await promisify(fs.write)(fd,Buffer.from(buffer),0,size,null)).bytesWritten;
    }),
    fsync:fd => io('fsync',{fd},() => promisify(fs.fsync)(fd)),
    truncate:(fd,length) => io('truncate',{fd,length},() => promisify(fs.ftruncate)(fd,length)),
    close:file => io('close',{fd:typeof file === 'number' ? file : file.fd},async () => {
      const fd = typeof file === 'number' ? file : file.fd;
      await promisify(fs.close)(fd); fds.delete(fd);
    }),
    unlink:path => io('unlink',{path},() => fsp.unlink(path)),
    rename:(from,to) => io('rename',{from,to},() => fsp.rename(from,to))
  };
  class MethodChannel { constructor(messenger,name) { this.name=name; channels.push(this); } setMethodCallHandler(value) { this.handler=value; } }
  const boundaries = {
    '@ohos.file.fs':{default:api},
    '@ohos.zlib':{default:nativeZlib},
    '@ohos.file.hash':{default:{hash(){throw Error('hash outside diagnostics test scope');}}},
    '@ohos.net.connection':{default:{getDefaultNet(){throw Error('network outside diagnostics test scope');}}},
    '@ohos.util':{default:{TextEncoder:class {encodeInto(value){return new TextEncoder().encode(value);}},
      TextDecoder:{create:(label,options) => ({decodeToString:bytes => new TextDecoder(label,options).decode(bytes)})}}},
    '@ohos.hidebug':{default:{getSystemMemInfo(){operations.push({op:'memory'});if(opt.memoryError)throw Error('memory');return {totalMem:opt.memoryKb ?? 8n*1024n*1024n};}}},
    '@ohos.deviceInfo':{default:{manufacture:'fixture maker',brand:'fixture brand',productModel:'fixture model',
      osFullName:'OpenHarmony fixture',sdkApiVersion:26,abiList:'arm64-v8a,x86_64'}},
    '@ohos.display':{default:{getDefaultDisplaySync(){operations.push({op:'display'});if(opt.displayError)throw Error('display');
      return {width:1080,height:2400,densityPixels:3,densityDPI:480};}}},
    '@ohos.bundle.bundleManager':{default:{BundleFlag:{GET_BUNDLE_INFO_DEFAULT:0},async getBundleInfoForSelf(flag){
      operations.push({op:'bundle',flag});assert.equal(flag,0);if(opt.bundle)await opt.bundle();return {versionName:'1.2.fixture',versionCode:42};}}},
    '@ohos.file.statvfs':{default:{async getFreeSize(path){operations.push({op:'free',path});assert.equal(path,app.filesDir);
      if(opt.free)await opt.free();return opt.freeBytes ?? 3*1024*1024*1024;}}},
    '@ohos/flutter_ohos':{MethodChannel}
  };
  function load(path) {
    if (modules.has(path)) return modules.get(path).exports;
    const module={exports:{}}; modules.set(path,module);
    const source=ts.transpileModule(fs.readFileSync(path,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
    vm.runInNewContext(source,{module,exports:module.exports,Map,Set,ArrayBuffer,Uint8Array,Promise,Error,console,
      setInterval:callback => { const timer={callback};timers.add(timer);return timer; },clearInterval:timer => timers.delete(timer),
      canIUse:cap => !(opt.missingCaps ?? []).includes(cap),
      require(name){if(name==='./NativeHost')return {nativeHostState:()=>({...native.state}),peekNativeHost:()=>nativeModule,loadNativeHost:()=>{native.loads++;throw Error('native load forbidden');}};
        // Lifecycle transport has its own real-socket suite. Keep this log test
        // local while executing the actual lifecycle model and Controller.
        if(name==='./OhosLifecycleTransport')return {OhosLifecycleTransport:class {cancel(){} async send(){}}};
        if(name==='./BackgroundCompute')return {backgroundComputePermission:()=> 'unknown'};
        if(name.startsWith('.'))return load(resolve(dirname(path),name+'.ets'));
        assert(name in boundaries,'unadapted/forbidden import '+name);return boundaries[name];}
    },{filename:path}); return module.exports;
  }
  function runtime() {
    const Plugin=load(resolve(repo,'app/ohos/entry/src/main/ets/plugins/DiagnosticsPlugin.ets')).default;
    const Store=load(resolve(repo,'app/ohos/entry/src/main/ets/runtime/PersistedRuntimeLog.ets')).PersistedRuntimeLog;
    const Core=load(resolve(repo,'app/ohos/entry/src/main/ets/runtime/RuntimeCore.ets'));
    return {Plugin,Store,Core,store:Store.get(app.filesDir),logs:new Core.RuntimeLogs()};
  }
  function attach(Plugin, plugin=new Plugin()) {
    const engine={getApplicationContext:() => app,getBinaryMessenger:() => ({})};
    const ability={getAbility:() => ({context:{config:{fontSizeScale:1.25}}})};
    plugin.onAttachedToEngine(engine); plugin.onAttachedToAbility(ability);
    return {plugin,engine,ability,methods:channels.at(-1),detach:() => plugin.onDetachedFromEngine(engine)};
  }
  function call(instance,method,args={}) {
    const wait=deferred(),replies=[];
    const reply=value => {replies.push(value);wait.resolve(value);if(opt.replyError)throw Error('retired transport');};
    instance.methods.handler.onMethodCall({method,argument:key => args[key]},
      {success:value => reply({value:plain(value)}),error:(error,message) => reply({error,message}),notImplemented:() => reply({missing:true})});
    return {done:wait.promise,replies};
  }
  const current=runtime();
  const controller=() => { const Controller=load(resolve(repo,'app/ohos/entry/src/main/ets/runtime/RuntimeController.ets')).RuntimeController;return new Controller(app); };
  return {...current,root,app,operations,fds,api,native,timers,controller,attach:plugin => attach(current.Plugin,plugin),call,
    path:join(app.filesDir,'dsh-runtime','engine.log'),directory:join(app.filesDir,'dsh-runtime'),
    reload:() => {modules=new Map();return runtime();},
    change:next => {opt={...opt,...next};},maxConcurrentIO:() => maxActiveIO,
    append:lines => {const entries=lines.map(line => current.logs.append(line,'stdout'));current.store.append(entries);return entries;},
    disk:async () => {try{return await fsp.readFile(join(app.filesDir,'dsh-runtime','engine.log'),'utf8');}catch(error){if(error.code==='ENOENT')return '';throw error;}}
  };
}
