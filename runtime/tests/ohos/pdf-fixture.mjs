// Real ETS/FS/native opener. HMS PDF, ImagePacker and pixel handles are explicit doubles.
// Page geometry and selected output PNGs come from a real Poppler parse/render in pdf-linux.py.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { createRequire } from 'node:module';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { promisify } from 'node:util';
import vm from 'node:vm';
const repo=fileURLToPath(new URL('../../../',import.meta.url));
assert(process.env.OHOS_PDF_FIXTURES&&process.env.OHOS_TYPESCRIPT_PREFIX&&process.env.OHOS_USER_FILE_ADDON);
const fixtures=resolve(process.env.OHOS_PDF_FIXTURES),metadata=JSON.parse(fs.readFileSync(join(fixtures,'pdf.json')));
const ts=createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX,'package.json'))('typescript');
const native=createRequire(import.meta.url)(resolve(process.env.OHOS_USER_FILE_ADDON));
export const deferred=()=>Promise.withResolvers();
export async function until(check){const end=Date.now()+5000;while(!check()){if(Date.now()>end)throw Error('timed out');await new Promise(r=>setImmediate(r));}}
export const plain=values=>Array.from(values,m=>Object.fromEntries(m));
export async function pdfFixture(t,options={}){
 let opt=options,reads=0,writes=0;const events=[],fds=new Set(),docs=[],pages=[],pixels=[],packers=[],cache=new Map();
 const root=await fsp.mkdtemp(join(tmpdir(),'dsh-pdf-'));t.after(()=>fsp.rm(root,{recursive:true,force:true}));
 const workspace=join(root,'files/runtime/rootfs/root/workspace'),context={filesDir:join(root,'files'),cacheDir:join(root,'cache'),tempDir:join(root,'temp')};
 for(const p of [workspace,context.cacheDir,context.tempDir])await fsp.mkdir(p,{recursive:true});
 const source=join(workspace,'彩色文档.pdf');await fsp.copyFile(join(fixtures,'sample.pdf'),source);
 const stat=s=>({size:s.size,isFile:()=>s.isFile(),isDirectory:()=>s.isDirectory(),isSymbolicLink:()=>s.isSymbolicLink()});
 // Preserve actual Linux errors, translating only the documented OH BusinessError
 // code for ENOENT at the public API boundary. Product code never sees Node strings.
 const ohError=e=>{if(e.code==='ENOENT')e.code=13900002;throw e;};
 const api={OpenMode:{CREATE:fs.constants.O_CREAT,READ_WRITE:fs.constants.O_RDWR,NOFOLLOW:fs.constants.O_NOFOLLOW},
  mkdir:async p=>{try{await fsp.mkdir(p);}catch(e){if(e.code==='EEXIST')e.code=13900015;throw e;}},
  lstat:async p=>{if(opt.lstatFailure)throw Object.assign(Error('permission denied'),{code:13900012});return stat(await fsp.lstat(p).catch(ohError));},stat:async fd=>stat(await promisify(fs.fstat)(fd)),
  mkdtemp:template=>fsp.mkdtemp(template.slice(0,-6)),listFile:async p=>{if(opt.listFile)await opt.listFile(p);return fsp.readdir(p).catch(ohError);},
  async open(path,flags){const fd=await promisify(fs.open)(path,flags,0o600);fds.add(fd);events.push('open-output');return{fd};},
  async close(fd){events.push('close-fd');if(opt.closeFailure)throw Error('close failed');await promisify(fs.close)(fd);fds.delete(fd);},
  async read(fd,buffer,opts){reads++;if(opt.beforeRead)await opt.beforeRead({fd,reads});if(opt.zeroRead)return 0;
   return(await promisify(fs.read)(fd,Buffer.from(buffer),0,Math.min(opts.length,opt.maxRead??Infinity),opts.offset)).bytesRead;},
  async write(fd,buffer,opts){writes++;if(opt.beforeWrite)await opt.beforeWrite({fd,writes});if(opt.zeroWrite)return 0;
   return(await promisify(fs.write)(fd,Buffer.from(buffer),0,Math.min(buffer.byteLength,opt.maxWrite??Infinity),opts.offset)).bytesWritten;},
  fsync:fd=>promisify(fs.fsync)(fd),unlink:async p=>{if(opt.unlinkFailure)throw Object.assign(Error('unlink failed'),{code:13900012});await fsp.unlink(p).catch(ohError);},
  rmdir:async p=>{if(opt.rmdir)await opt.rmdir(p);return fsp.rmdir(p).catch(ohError);}
 };
 async function opener(path){events.push('opener');if(opt.opener)await opt.opener(path);let fd;
  for(const allowed of [workspace,context.cacheDir,context.tempDir])if(path.startsWith(allowed+'/')){fd=native.openUserFile(allowed,path.slice(allowed.length+1));break;}
  if(fd===undefined)throw Error('outside authorized roots');fds.add(fd);events.push('open-input');return fd;
 }
 class Pixel{constructor(width,height){this.width=width;this.height=height;this.released=false;pixels.push(this);}
  async getImageInfo(){if(opt.pixelInfo)await opt.pixelInfo(this);return{size:{width:opt.pixelWidth??this.width,height:this.height}};}
  async release(){events.push('pixel.release');if(opt.pixelReleaseFailure)throw Error('pixel release failed');this.released=true;}
 }
 class Page{constructor(index){this.index=index;this.released=false;pages.push(this);}
  getWidth(){return opt.pageWidth??metadata.pages[this.index].width;}getHeight(){return opt.pageHeight??metadata.pages[this.index].height;}
  getAreaPixelMapWithOptions(matrix,w,h,opts){events.push('render');this.render={matrix:{...matrix},width:w,height:h,options:{...opts}};
   if(opt.renderFailure)throw Error('native render failed');return new Pixel(w,h);}
  release(){events.push('page.release');if(opt.pageReleaseFailure)throw Error('page release failed');this.released=true;}
 }
 class Document{constructor(){events.push('doc.create');this.released=false;this.loads=0;docs.push(this);if(opt.constructFailure)throw Error('unavailable kit');}
  loadDocument(path){this.loads++;assert.equal(this.loads,1,'never reload the same document object');this.path=path;this.bytes=fs.readFileSync(path);
   if(opt.loadFailure)throw Error('load failed');return opt.parseResult??0;}
  getPageCount(){return opt.pageCounts?.shift()??opt.pageCount??metadata.pages.length;}getPage(index){if(opt.getPageFailure)throw Error('page failed');return new Page(index);}
  releaseDocument(){events.push('doc.release');if(opt.documentReleaseFailure)throw Error('document release failed');this.released=true;}
 }
 const kit={PdfDocument:Document,PdfMatrix:class{constructor(){this.x=0;this.y=0;this.width=0;this.height=0;this.rotate=99;}},
  PixelOptions:class{constructor(){this.isGray=true;this.drawAnnotations=true;this.isTransparent=true;}},ParseResult:{PARSE_SUCCESS:0,PARSE_ERROR_PASSWORD:3}};
 const image={createImagePacker(){const packer={released:false,async packToData(pixel,opts){events.push('pack');assert.equal(opts.format,'image/png');assert.equal(opts.quality,100);
   if(opt.pack)await opt.pack(pixel);if(opt.invalidPng)return new ArrayBuffer(24);
   const bytes=await fsp.readFile(join(fixtures,`page-${pixel.width}x${pixel.height}.png`));return bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.length);},
  async release(){events.push('packer.release');if(opt.packerReleaseFailure)throw Error('packer release failed');this.released=true;}};packers.push(packer);return packer;}};
 const channels=[],warnings=[];let nativeLoads=0,kitLoads=0;
 class Channel{constructor(_messenger,name){this.name=name;channels.push(this);}setMethodCallHandler(handler){this.handler=handler;}}
 function load(path){if(cache.has(path))return cache.get(path).exports;const module={exports:{}};cache.set(path,module);
  const compiled=ts.transpileModule(fs.readFileSync(path,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  try { vm.runInNewContext(compiled,{module,exports:module.exports,Map,Set,ArrayBuffer,Uint8Array,DataView,Promise,Error,setTimeout,
   require(name){
    if(name==='../runtime/NativeHost')return{async loadNativeHost(){nativeLoads++;if(opt.nativeLoad)await opt.nativeLoad();return{openUserFile(allowed,relative){const fd=native.openUserFile(allowed,relative);fds.add(fd);events.push('open-input');return fd;}};}};
    if(name==='../runtime/RuntimeController')return{RuntimeController:{get(actual){assert.equal(actual,context);const {RuntimePaths}=load(resolve(repo,'app/ohos/entry/src/main/ets/runtime/RuntimePaths.ets'));return{paths:new RuntimePaths(actual.filesDir)};}}};
    if(name==='./HmsPdfKit'){kitLoads++;return Promise.resolve(opt.beforeKitLoad?.()).then(()=>load(resolve(dirname(path),name+'.ets')));}
    if(name.startsWith('.'))return load(resolve(dirname(path),name+'.ets'));
    if(name==='@kit.PDFKit'){if(opt.kitFailure)throw Error('controlled unavailable PDF Kit');return{pdfService:kit};}
    if(name==='@ohos.file.fs')return{default:api};if(name==='@ohos.multimedia.image')return{default:image};
    if(name==='@ohos/flutter_ohos')return{MethodChannel:Channel};
    if(name==='@ohos.util')return{default:{TextEncoder:class{encodeInto(text){return new TextEncoder().encode(text);}}}};
    if(name==='@ohos.hilog')return{default:{warn:(...args)=>warnings.push(args)}};
    if(['@ohos.file.picker','@ohos.file.fileuri','@ohos.file.photoAccessHelper','@ohos.app.ability.wantConstant','@ohos.security.cryptoFramework'].includes(name))return{default:{}};
    throw Error('unadapted import '+name);}
  },{filename:path}); } catch(error) {cache.delete(path);throw error;} return module.exports;}
 const Service=load(resolve(repo,'app/ohos/entry/src/main/ets/plugins/HmsPdfPages.ets')).HmsPdfPages;
 const service=opt.filesChannel?undefined:new Service(context,opener);
 function createFilesPlugin(abilityContext=context){
  const Plugin=load(resolve(process.env.OHOS_FILES_MEDIA_SOURCE??resolve(repo,'app/ohos/entry/src/main/ets/plugins/FilesMediaPlugin.ets'))).default;
  const plugin=new Plugin(),engine={getApplicationContext:()=>context,getBinaryMessenger:()=>({})};
  const start=channels.length;plugin.onAttachedToEngine(engine);
  const binding={getAbility:()=>({context:abilityContext})};plugin.onAttachedToAbility(binding);
  const handler=channels.slice(start).find(c=>c.name==='dsh/files').handler;
  const call=(method,args={})=>new Promise(resolve=>handler.onMethodCall({method,argument:name=>args[name]},
   {success:value=>resolve({value}),error:(error,message)=>resolve({error,message}),notImplemented:()=>resolve({missing:true})}));
  return{plugin,engine,binding,handler,call};
 }
 return{service,source,workspace,context,root,events,fds,docs,pages,pixels,packers,metadata,channels,warnings,createFilesPlugin,
  newService:()=>new Service(context,opener),change:next=>{opt={...opt,...next};},stats:()=>({reads,writes,nativeLoads,kitLoads})};
}
