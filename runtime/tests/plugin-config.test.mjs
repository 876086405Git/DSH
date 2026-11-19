import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {once} from 'node:events';
import {apply} from '../bridge/dsh-go-bridge/lib/index.js';
import {withSources} from './plugin-config-source-fixture.mjs';
const root='/dsh-go/v1/plugin-config';
async function fixture(t,{connection=true,entries=[],addressable=entries}={}){
 const routes=[],dispose=[],hooks=new Map();let reads=0;
 const editor={canWrite:()=>true,entries:()=>addressable,configuration:()=>{reads++;return addressable.map(entry=>({entry,inherited:entry.options.config??{},override:entry.options.config??{}}));}};
 const ctx={logger:{warn(){}},get:n=>n==='loader'?{entries:()=>entries}:n==='configEditor'?editor:n==='connection'&&connection?{requestRejection:()=>undefined}:undefined,
 on(n,fn){const fns=hooks.get(n)??[];fns.push(fn);hooks.set(n,fns);},provide(){},effect(fn){const d=fn();if(typeof d==='function')dispose.push(d);},inject(_deps,fn){fn(ctx);},
 webServer:{tapIndex(){return ()=>{};},register(r){routes.push(r);return ()=>{};},registerUpgrade(){return ()=>{};}}};
 const source=withSources(ctx,entries);let resolutions=0;const resolve=source.internal.resolveSync;
 source.internal.resolveSync=function(...args){resolutions++;return resolve.apply(this,args);};
 apply(ctx,{persist:false,guardRoutes:false});
 const server=createServer((req,res)=>routes.find(r=>r.kind==='prefix'&&req.url.startsWith(r.path)).handler(req,res));
 server.listen(0,'127.0.0.1');await once(server,'listening');
 t.after(async()=>{dispose.reverse().forEach(d=>d());server.closeAllConnections();await new Promise(r=>server.close(r));});
 return {async get(path=root){const r=await fetch(`http://127.0.0.1:${server.address().port}${path}`);const text=await r.text();return {status:r.status,body:text.startsWith('{')?JSON.parse(text):text};},reads:()=>reads,resolutions:()=>resolutions};
}
function entry(id,graph,value={}){const schema=Object.assign(v=>v,{toJSON:()=>structuredClone(graph)});return {options:{id,name:'@scope/plugin',config:value},fiber:{uid:7,state:2,runtime:{Config:schema},config:value}};}
const simple={uid:1,refs:{1:{type:'object',meta:{},dict:{visible:2}},2:{type:'string',meta:{}}}};
// Same outer-role placement as the recorded Schemastery secret wrapper fixture.
const credentialPair={uid:1,refs:{1:{type:'object',dict:{apiKey:2,keyRef:4}},2:{type:'transform',inner:3,meta:{role:'secret'}},3:{type:'string'},4:{type:'string',meta:{role:'credential-ref',default:'DEFAULT_REF'}}}};
test('one secret and one credential-ref bind the running ref or its missing-value default',async t=>{
 const repeated=structuredClone(credentialPair);repeated.uid=5;repeated.refs[5]={type:'intersect',list:[1,1]};
 const configured=entry('configured',repeated,{apiKey:'SYNTHETIC_SECRET',keyRef:'RAW_REF'}),fallback=entry('default',credentialPair);
 configured.fiber.effectiveConfig={apiKey:'SYNTHETIC_SECRET',keyRef:'CONFIGURED_REF'};
 const f=await fixture(t,{entries:[configured,fallback]});
 for(const [id,ref,set]of [['configured','CONFIGURED_REF',true],['default','DEFAULT_REF',false]]){
  const {status,body}=await f.get(root+'/'+id);assert.equal(status,200);
  assert.deepEqual(body.secrets,[{path:['apiKey'],configured:set,writable:false,credentialRef:ref}]);
  assert(!JSON.stringify(body).includes('SYNTHETIC_SECRET'));
 }
});
test('multiple secret or credential-ref fields in one parent remain unbound',async t=>{
 const graph={uid:1,refs:{1:{type:'object',dict:{twoSecrets:2,twoRefs:3,composed:6}},2:{type:'object',dict:{first:4,second:4,ref:5}},3:{type:'object',dict:{secret:4,firstRef:5,secondRef:5}},4:{type:'string',meta:{role:'secret'}},5:{type:'string',meta:{role:'credential-ref',default:'DEFAULT_REF'}},6:{type:'intersect',list:[7,8]},7:{type:'object',dict:{first:4,firstRef:5}},8:{type:'object',dict:{second:4,secondRef:5}}}};
 const raw={twoSecrets:{first:'SYNTHETIC_SECRET',second:'SYNTHETIC_SECRET'},twoRefs:{secret:'SYNTHETIC_SECRET'},composed:{first:'SYNTHETIC_SECRET',second:'SYNTHETIC_SECRET'}};
 const f=await fixture(t,{entries:[entry('many',graph,raw)]}),{status,body}=await f.get(root+'/many');assert.equal(status,200);
 assert.deepEqual(body.secrets.map(x=>x.path.join('.')),['twoSecrets.first','twoSecrets.second','twoRefs.secret','composed.first','composed.second']);
 assert(body.secrets.every(x=>x.writable===false&&!('credentialRef'in x)));assert(!JSON.stringify(body).includes('SYNTHETIC_SECRET'));
});
test('empty credential ref stays unbound without falling back to a nonempty default',async t=>{
 const emptyDefault=structuredClone(credentialPair);emptyDefault.refs[4].meta.default='';
 const f=await fixture(t,{entries:[entry('explicit',credentialPair,{apiKey:'SYNTHETIC_SECRET',keyRef:''}),entry('default',emptyDefault,{apiKey:'SYNTHETIC_SECRET'})]});
 for(const id of ['explicit','default']){const {status,body}=await f.get(root+'/'+id);assert.equal(status,200);assert.deepEqual(body.secrets,[{path:['apiKey'],configured:true,writable:false}]);assert(!JSON.stringify(body).includes('SYNTHETIC_SECRET'));}
});
test('missing connection is 503 before both config reads',async t=>{const f=await fixture(t,{connection:false});for(const p of [root,root+'/one'])assert.equal((await f.get(p)).status,503);assert.equal(f.reads(),0);});
test('duplicate ids cannot select first entry',async t=>{const es=[entry('same',simple),entry('same',simple)],f=await fixture(t,{entries:es});const list=(await f.get()).body.entries;assert(list.every(e=>e.reason==='ambiguous-id'));assert.equal((await f.get(root+'/same')).status,403);});
test('nested Include not addressable',async t=>{const f=await fixture(t,{entries:[entry('nested',simple)],addressable:[]});assert.equal((await f.get()).body.entries[0].reason,'nested-include');assert.equal((await f.get(root+'/nested')).status,404);});
test('inactive failed and unsupported schema never disclose configuration',async t=>{const a=entry('inactive',simple),b=entry('failed',simple),c=entry('opaque',{uid:1,refs:{1:{type:'any',meta:{default:'SYNTHETIC_HIDDEN'}}}});a.fiber.state=0;b.fiber.state=3;const f=await fixture(t,{entries:[a,b,c]});const out=await f.get();assert.equal(out.body.entries[0].state,'inactive');assert.equal(out.body.entries[1].state,'failed');assert.equal(out.body.entries[2].reason,'unsupported-schema');for(const id of ['inactive','failed','opaque'])assert.equal((await f.get(root+'/'+id)).status,404);});
test('shared refs, secret const and ancestor defaults are redacted',async t=>{
 const graph={uid:1,refs:{1:{type:'object',meta:{default:{visible:'ok',parent:{secret:'SYNTHETIC_HIDDEN'}}},dict:{visible:2,parent:3,alias:4}},2:{type:'string',meta:{}},3:{type:'object',meta:{default:{secret:'SYNTHETIC_HIDDEN'},extra:{sample:'SYNTHETIC_HIDDEN'}},dict:{secret:4}},4:{type:'const',value:'SYNTHETIC_HIDDEN',meta:{role:'secret',default:'SYNTHETIC_HIDDEN',extra:{sample:'SYNTHETIC_HIDDEN'}}}}};
 const f=await fixture(t,{entries:[entry('one',graph,{visible:'ok',parent:{secret:'SYNTHETIC_HIDDEN'},alias:'SYNTHETIC_HIDDEN',unknown:'SYNTHETIC_HIDDEN'})]});const {body,status}=await f.get(root+'/one');assert.equal(status,200);assert(!JSON.stringify(body).includes('SYNTHETIC_HIDDEN'));assert.deepEqual(body.value,{visible:'ok',parent:{}});assert(body.secrets.every(s=>s.configured&&s.writable===false));
});
test('transform secret union branch cannot expose same scalar via ordinary branch',async t=>{
 const graph={uid:1,refs:{1:{type:'object',meta:{},dict:{field:2}},2:{type:'union',meta:{default:'SYNTHETIC_HIDDEN'},list:[3,5]},3:{type:'transform',meta:{},inner:4},4:{type:'string',meta:{role:'secret'}},5:{type:'string',meta:{}}}};
 const f=await fixture(t,{entries:[entry('one',graph,{field:'SYNTHETIC_HIDDEN'})]});const {body}=await f.get(root+'/one');assert(!JSON.stringify(body).includes('SYNTHETIC_HIDDEN'));assert.deepEqual(body.value,{});
});
test('secret change invalidates opaque revision even when visible values equal',async t=>{const graph={uid:1,refs:{1:{type:'object',dict:{secret:2}},2:{type:'string',meta:{role:'secret'}}}};const e=entry('one',graph,{secret:'SYNTHETIC_A'}),f=await fixture(t,{entries:[e]});const before=(await f.get(root+'/one')).body;e.options.config.secret='SYNTHETIC_B';const after=(await f.get(root+'/one')).body;assert.deepEqual(before.value,after.value);assert.notEqual(before.revision,after.revision);assert(!before.revision.includes('SYNTHETIC'));});

test('array union removes secret paths even when ordinary branch comes first',async t=>{
 const graph={uid:1,refs:{1:{type:'object',dict:{rows:2}},2:{type:'union',list:[3,4]},3:{type:'array',inner:5},4:{type:'array',inner:6},5:{type:'object',dict:{secret:7,visible:7}},6:{type:'object',dict:{secret:8,visible:7}},7:{type:'string'},8:{type:'string',meta:{role:'secret'}}}};
 const f=await fixture(t,{entries:[entry('one',graph,{rows:[{secret:'SYNTHETIC_HIDDEN',visible:'ok'}]})]});const {body}=await f.get(root+'/one');assert(!JSON.stringify(body).includes('SYNTHETIC_HIDDEN'));assert.deepEqual(body.value,{rows:[{visible:'ok'}]});
});


test('detail serializes only the requested schema', async t => {
 const counts=Array(200).fill(0);
 const entries=counts.map((_,i)=>{
  const e=entry(`item-${i}`,simple,{visible:`value-${i}`});
  e.fiber.runtime.Config.toJSON=()=>{counts[i]++;return structuredClone(simple);};
  return e;
 });
 const f=await fixture(t,{entries});
 const result=await f.get(root+'/item-123');
 assert.equal(result.status,200);assert.deepEqual(result.body.value,{visible:'value-123'});
 assert.equal(f.resolutions(),201,"all 200 entries and the trusted core declaration still resolve");
 t.diagnostic(`detail entries=200 schemaSerializations=${counts.reduce((a,b)=>a+b,0)} sourceResolutions=${f.resolutions()}`);
 assert.deepEqual(counts,counts.map((_,i)=>i===123?1:0));
});

test('list still inspects every schema and preserves entry order', async t => {
 let count=0;
 const entries=Array.from({length:200},(_,i)=>{
  const e=entry(`item-${i}`,simple);
  e.fiber.runtime.Config.toJSON=()=>{count++;return structuredClone(simple);};
  return e;
 });
 const f=await fixture(t,{entries});const result=await f.get();
 assert.equal(result.status,200);
 assert.deepEqual(result.body.entries.map(e=>e.entryId),entries.map(e=>e.options.id));
 assert.ok(result.body.entries.every(e=>e.configurable));
 assert.equal(f.resolutions(),201);
 t.diagnostic(`list entries=200 schemaSerializations=${count} sourceResolutions=${f.resolutions()}`);
 assert.equal(count,200);
});

test('detail recomputes target schema and revision after live schema changes', async t => {
 const e=entry('one',simple,{visible:'public'}),f=await fixture(t,{entries:[e]});
 const first=await f.get(root+'/one');assert.equal(first.status,200);assert.deepEqual(first.body.value,{visible:'public'});
 const hidden=structuredClone(simple);hidden.refs[2].meta={role:'secret'};
 e.fiber.runtime.Config.toJSON=()=>structuredClone(hidden);
 const second=await f.get(root+'/one');assert.equal(second.status,200);
 assert.deepEqual(second.body.value,{});assert.notEqual(second.body.revision,first.body.revision);
 assert.equal(JSON.stringify(second.body).includes('public'),false);
});


test('an unrelated unsupported schema remains isolated from target detail', async t => {
 const target=entry('one',simple,{visible:'target'}),other=entry('other',simple);
 other.fiber.runtime.Config.toJSON=()=>{throw Error('SYNTHETIC_SCHEMA_ERROR');};
 const f=await fixture(t,{entries:[target,other]});
 const detail=await f.get(root+'/one');assert.equal(detail.status,200);assert.deepEqual(detail.body.value,{visible:'target'});
 const list=await f.get();assert.equal(list.status,200);
 assert.equal(list.body.entries[1].reason,'unsupported-schema');
 assert.equal((await f.get(root+'/other')).status,404);
});
