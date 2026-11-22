// Actual pinned Domain/JSON and FS bodies on Linux; no engine or device claim.
// Only JSON's supported-statfs branch is supplied on the CI overlay filesystem.
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,rm,writeFile,utimes} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createServer} from 'node:http';
import {setTimeout as delay} from 'node:timers/promises';
import {notesProviders,notesSourceRoot} from './companion-notes-files-source.mjs';

assert(process.env.COMPANION_TASK_HARNESS,'Prepare exact task source; missing is NOT_RUN, never skip');
export const load=path=>import(pathToFileURL(resolve(process.env.COMPANION_TASK_HARNESS,path)).href);
const {JsonStorageBackend}=await load('node_modules/@deepseek-ai/dsh-storage-json/index.js');
const {DomainFacility}=await load('node_modules/@deepseek-ai/dsh-storage-domain/index.js');
const {BackendRegistry}=await load('node_modules/@deepseek-ai/dsh-storage/index.js');
const {openCompanionTaskStore}=await load('companion/task-store.js');
const {createFindDraftRunner}=await load('companion/find-draft.js');
const {createCompanionRoutes}=await load('companion/routes.js');
const providers=await notesProviders(notesSourceRoot());

export async function until(check,label,ms=6000){
 const end=Date.now()+ms;
 while(!await check()){if(Date.now()>end)throw new Error('Timed out: '+label);await delay(5);}
}
export async function putDraft(root,name,text='原稿',at=Date.parse('2026-11-20T12:00:00Z')){
 const path=join(root,'notes',name);await writeFile(path,text);await utimes(path,new Date(at),new Date(at));return path;
}
export async function openFind(root,options={}){
 const backend=new JsonStorageBackend(join(root,'storage'));backend.dshGoCompanionStatfs=async()=>({type:0xef53n});
 const registry=new BackendRegistry();registry.register('actual',backend);
 const facility=new DomainFacility({storage:{backend:registry},emit(){},logger:{warn(){},error(){}},fiber:{assertActive(){}}},{backend:'actual'});
 const fsCtx={sandboxPolicy:{defaultMode:'read-only',resolve:()=>({mode:'read-only',workspaceRoot:join(root,'notes')})}};
 const fs=new (options.sandboxed?providers.SandboxedFileSystem:providers.LocalFileSystem)(fsCtx,{cwd:root,diffBasisMaxBytes:10485760});
 const counters={lists:0,reads:[],otherServices:0};
 const list=fs.dshGoListDrafts.bind(fs),read=fs.dshGoReadNote.bind(fs);
 fs.dshGoListDrafts=async(...args)=>{counters.lists++;return options.list?options.list(args,()=>list(...args)):list(...args);};
 fs.dshGoReadNote=async(...args)=>{counters.reads.push(args[1].name);return options.read?options.read(args,()=>read(...args)):read(...args);};
 let store;
 if(options.mountService){
  const {mountCompanionTasks}=await load('companion/task-service.js');
  const mounted={fs,storageDomain:facility};
  const context={get:key=>{if(!Object.hasOwn(mounted,key)){counters.otherServices++;assert.fail('unexpected task model service: '+key);}return mounted[key];},
   inject(_names,job){return job(context);},fiber:{assertActive(){}},effect(){},provide(key,value){mounted[key]=value;},
   logger:{warn(message){assert.fail(message);}}};
  await mountCompanionTasks(context);store=mounted.dshGoCompanionTasks;assert(store);
 } else store=await openCompanionTaskStore({facility,fs,...options.now?{now:options.now}:{}});
 let runner=null;
 const start=()=>{
  assert.equal(runner,null);runner=createFindDraftRunner({store,ctx:{get:key=>{
   if(key!=='fs'){counters.otherServices++;assert.fail('find requested a model/Agent/Session service: '+key);}return fs;
  }}});
  store.attachRunner({...runner,kinds:['host.find_draft']});
  for(const id of store.runnable())store.wake(id);
  return runner;
 };
 const values={dshGoCompanionTasks:store,connection:{admit:req=>req.headers.authorization==='owner'?{peer:{principal:{kind:'owner'}}}:{rejection:403}}};
 const route=createCompanionRoutes({ctx:{get:key=>values[key]},send:(res,status,body)=>{res.writeHead(status,{'content-type':'application/json'});res.end(JSON.stringify(body));}});
 const server=createServer((req,res)=>route.handle(req,res,new URL(req.url,'http://local').pathname).catch(error=>{res.statusCode=500;res.end(String(error));}));
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const base=`http://127.0.0.1:${server.address().port}/dsh-go/v1/companion/tasks`;
 const request=async(path='',body,headers={})=>{
  const response=await fetch(base+path,{method:body===undefined?'GET':'POST',headers:{authorization:'owner',...(body===undefined?{}:{'content-type':'application/json'}),...headers},...(body===undefined?{}:{body:typeof body==='string'?body:JSON.stringify(body)})});
  return {status:response.status,body:await response.json()};
 };
 let closing;
 return {root,store,fs,backend,counters,start,request,values,base,
  close(){return closing??=(async()=>{route.dispose();await new Promise(resolve=>server.close(resolve));await store.close();await backend.close();})();}};
}
export async function findFixture(t,options={}){
 const root=await mkdtemp(join(process.cwd(),'find-source-'));await mkdir(join(root,'notes'));await mkdir(join(root,'storage'));
 const f=await openFind(root,options);
 const folder=(await f.request('/folders',{v:1,hostStoreId:f.store.hostStoreId,path:join(root,'notes')})).body;
 const body={v:1,hostStoreId:f.store.hostStoreId,taskId:'find-one',taskRev:1,kind:'host.find_draft',
  origin:{sourceSessionId:'light:original-room',messageId:'original-message',itemNo:0},hostSessionId:null,
  args:{folderRef:folder.folderRef,scope:'currentLevel',localDate:'2026-11-20',timeZone:'UTC',dateBy:'modified',extensions:['md','txt']},
  deadlineAtMs:null,afterExit:'continue',allowQueue:true};
 t.after(async()=>{await f.close();await rm(root,{recursive:true,force:true});});
 return {...f,folder,body};
}
export const completion=snapshot=>snapshot.steps.findLast(step=>step.taskRev===snapshot.taskRev&&step.stepKey==='readInputs')?.result?.completion;
export async function completeFind(f,body=f.body){
 if(!f.store.runner)f.start();const response=await f.request('',body);assert.equal(response.status,201);
 await until(()=>['done','partial','failed','unknown','cancelled','waiting'].includes(f.store.read(body.taskId).state),'find settlement');
 return {response,snapshot:(await f.request(`/${body.taskId}?hostStoreId=${f.store.hostStoreId}`)).body};
}
export const sourcePath=(f,sourceRef,execution=f.store.read(f.body.taskId).hostExecutionId)=>
 `/${f.body.taskId}/sources/${sourceRef}?hostStoreId=${f.store.hostStoreId}&hostExecutionId=${execution}`;
