// Actual loopback HTTP -> production companion route -> actual Domain/JSON.
// Authentication, fixed runner wake and FS result observers are explicit peers;
// this does not claim a full engine run, actual directory policy or model IO.
import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';

assert.ok(process.env.COMPANION_TASK_HARNESS,'Prepare exact source modules; missing is NOT_RUN, never skip');
const load=path=>import(pathToFileURL(resolve(process.env.COMPANION_TASK_HARNESS,path)).href);
const {createCompanionRoutes}=await load('companion/routes.js');
const {openCompanionTaskStore}=await load('companion/task-store.js');
const {JsonStorageBackend}=await load('node_modules/@deepseek-ai/dsh-storage-json/index.js');
const {DomainFacility}=await load('node_modules/@deepseek-ai/dsh-storage-domain/index.js');
const {BackendRegistry}=await load('node_modules/@deepseek-ai/dsh-storage/index.js');

async function fixture(t){
 const root=await mkdtemp(join(tmpdir(),'task-http-')),backend=new JsonStorageBackend(root);
 backend.dshGoCompanionStatfs=async()=>({type:0xef53n});
 const registry=new BackendRegistry();registry.register('actual',backend);
 const facility=new DomainFacility({storage:{backend:registry},emit(){},logger:{warn(){},error(){}},fiber:{assertActive(){}}},{backend:'actual'});
 let content='已写好的原件';
 const fs={resolve:async path=>({targetKey:path,displayPath:path}),dshGoBindNotesDirectory:async target=>({target,identity:'1:2'}),
  dshGoReadNotesArtifact:async()=>{if(content instanceof Error)throw content;return {text:content};}};
 const store=await openCompanionTaskStore({facility,fs});let wakes=0;
 store.attachRunner({wake(){wakes++;},async stop(){}});
 const values={dshGoCompanionTasks:store,connection:{admit:req=>req.headers.authorization==='owner'
   ?{peer:{principal:{kind:'owner'}}}:{rejection:403}}};
 const ctx={get:key=>values[key]};
 const send=(res,status,body)=>{res.writeHead(status,{'content-type':'application/json; charset=utf-8'});res.end(JSON.stringify(body));};
 const route=createCompanionRoutes({ctx,send});
 const server=createServer((req,res)=>route.handle(req,res,new URL(req.url,'http://local').pathname).catch(error=>{res.statusCode=500;res.end(String(error));}));
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const base=`http://127.0.0.1:${server.address().port}/dsh-go/v1/companion/tasks`;
 t.after(async()=>{route.dispose();await new Promise(resolve=>server.close(resolve));await store.close();await backend.close();await rm(root,{recursive:true,force:true});});
 const request=async(path='',body,headers={})=>{const response=await fetch(base+path,{method:body===undefined?'GET':'POST',headers:{authorization:'owner',...body===undefined?{}:{'content-type':'application/json'},...headers},...body===undefined?{}:{body:typeof body==='string'?body:JSON.stringify(body)}});return {status:response.status,body:await response.json()};};
 const cap=(await request('/capabilities')).body;
 const folder=(await request('/folders',{v:1,hostStoreId:cap.hostStoreId,path:'/chosen'})).body;
 const create={v:1,hostStoreId:cap.hostStoreId,taskId:'task-1',taskRev:1,kind:'host.notes_to_todo',
   origin:{sourceSessionId:'full:phone-room',messageId:'message-1',itemNo:0},hostSessionId:'real-session',
   deadlineAtMs:null,afterExit:'continue',allowQueue:false,args:{folderRef:folder.folderRef,outputDirRef:folder.folderRef,
   localDate:'2026-11-20',timeZone:'Asia/Shanghai',dateBy:'modified',outputName:'今日待办.md',writeMode:'createNew'}};
 return {store,request,create,cap,folder,values,wakes:()=>wakes,setContent:value=>{content=value;}};
}
test('wire returns real persisted capability and bound folder, owner admission rejects non-owner',async t=>{
 const f=await fixture(t);assert.equal(f.cap.hostStoreId,f.store.hostStoreId);assert.deepEqual(f.cap.kinds,['host.notes_to_todo']);
 assert.equal(f.folder.displayPath,'/chosen');assert.equal(f.store.folder(f.folder.folderRef).identity,'1:2');
 const rejected=await f.request('/capabilities',undefined,{authorization:'other'});
 assert.equal(rejected.status,403);assert.equal(rejected.body.error.code,'companion/task-forbidden');
});
test('actual create 201 and lost-response replay 200 keep same execution and sequence',async t=>{
 const f=await fixture(t);const one=await f.request('',f.create),two=await f.request('',f.create);
 assert.equal(one.status,201);assert.equal(two.status,200);assert.deepEqual(two.body,one.body);
 assert.equal(one.body.origin.sourceSessionId,'full:phone-room');assert.equal(one.body.hostSessionId,'real-session');
 assert.equal(one.body.runnerReceiptSeq,1);assert.equal(f.wakes(),2);
});
test('actual pre-create cancel and late create expose originalCreatePresent without rev1 wake',async t=>{
 const f=await fixture(t);const fence=await f.request('/task-1/cancel',{v:1,hostStoreId:f.cap.hostStoreId,operationId:'op-2',expectedTaskRev:1,taskRev:2});
 assert.equal(fence.body.originalCreatePresent,false);assert.equal(fence.body.state,'cancelled');
 const late=await f.request('',f.create);assert.equal(late.status,200);assert.equal(late.body.hostExecutionId,fence.body.hostExecutionId);
 assert.equal(late.body.state,'cancelled');assert.equal(late.body.taskRev,2);assert.deepEqual(f.store.runnable(),[]);
});
test('wire distinguishes same-store absent from original-store mismatch',async t=>{
 const f=await fixture(t);const absent=await f.request(`/absent?hostStoreId=${f.cap.hostStoreId}`),other=await f.request('/absent?hostStoreId=other');
 assert.equal(absent.status,404);assert.equal(absent.body.error.code,'companion/task-not-found');
 assert.equal(other.status,409);assert.equal(other.body.error.code,'companion/task-store-mismatch');
});
test('actual conflict response retains current snapshot and previous identity',async t=>{
 const f=await fixture(t);const first=await f.request('',f.create);
 const changed=await f.request('',{...f.create,args:{...f.create.args,outputName:'different.md'}});
 assert.equal(changed.status,409);assert.equal(changed.body.error.code,'companion/task-conflict');
 assert.equal(changed.body.snapshot.hostExecutionId,first.body.hostExecutionId);
});
test('duplicate CAS keys, unknown request fields and path-like output names reject before acceptance',async t=>{
 const f=await fixture(t);
 for(const body of [JSON.stringify(f.create).replace('"taskRev":1','"taskRev":1,"taskRev":2'),{...f.create,secret:'not-accepted'},
  {...f.create,args:{...f.create.args,outputName:'../outside.md'}}]){
   const response=await f.request('',body);assert.equal(response.status,400);assert.equal(f.store.table.size,0);
 }
});
test('list summaries are not whole private inputs; single GET retains complete historical effect',async t=>{
 const f=await fixture(t);await f.request('',f.create);
 const model=await f.store.claimStep('task-1',1,'model',{reserveMs:100});
 await f.store.saveCandidate(model,{content:'私有候选',mediaType:'text/markdown',sourceCount:1,usage:null});
 await f.store.finishStep(model,{state:'done',reason:null,result:null,elapsedMs:1});
 const write=await f.store.claimStep('task-1',1,'writePage',{reserveMs:100});
 await f.store.savePublishIntent(write,{directory:f.store.folder(f.folder.folderRef),outputName:'今日待办.md'});
 const result=await f.store.publish(write,async()=>({artifact:{relativePath:'今日待办.md',mediaType:'text/markdown',size:12,
  sha256:'a'.repeat(64),identity:'1:3',verifiedAtMs:1,sourceCount:1},elapsedMs:1,state:'done',reason:null}));
 const listed=await f.request(`?hostStoreId=${f.cap.hostStoreId}`);assert.equal(listed.body.tasks.length,1);
 assert.equal('steps' in listed.body.tasks[0],false);assert.equal(JSON.stringify(listed.body).includes('私有候选'),false);
 const got=await f.request(`/task-1?hostStoreId=${f.cap.hostStoreId}`);assert.deepEqual(got.body.artifacts,result.artifacts);
 assert.equal(got.body.runnerReceiptSeq,result.runnerReceiptSeq);assert.equal(JSON.stringify(got.body).includes('私有候选'),false);
 const id=result.artifacts[0].artifactId,path=`/task-1/artifacts/${id}?hostStoreId=${f.cap.hostStoreId}`;
 assert.equal((await f.request(path)).body.content,'已写好的原件');
 f.setContent(Object.assign(new Error('changed'),{code:'FS_STALE_VERSION'}));assert.equal((await f.request(path)).body.status,'changed');
 f.setContent(Object.assign(new Error('missing'),{code:'FS_NOT_FOUND'}));assert.equal((await f.request(path)).body.status,'missing');
 assert.equal((await f.request(`/task-1/artifacts/other?hostStoreId=${f.cap.hostStoreId}`)).body.error.code,'companion/task-artifact-not-found');
});
test('missing actual task service keeps ordinary bridge available and advertises no task kind',async t=>{
 const f=await fixture(t);delete f.values.dshGoCompanionTasks;
 const cap=await f.request('/capabilities');assert.equal(cap.status,200);assert.equal(cap.body.durableAcceptance,false);assert.deepEqual(cap.body.kinds,[]);
 const create=await f.request('',f.create);assert.equal(create.status,503);assert.equal(create.body.error.code,'companion/task-unavailable');
});
