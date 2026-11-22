// Complete profile Config forms. No npm dependencies: the bridge can be loaded by file path.
import {createHmac, randomBytes} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {isDeepStrictEqual} from 'node:util';
const BASE='/dsh-go/v1/plugin-config';
const BAD=new Set(['__proto__','prototype','constructor','__jsExpr']);
const TYPES=new Set(['object','dict','array','string','number','boolean','const','union','intersect','transform']);
const VOLATILE=Symbol.for('cosmokit.volatile.write');
// Cordis exports symbols.original; ctx.get creates a fresh traceable Proxy.
const serviceIdentity=value=>value?.[Symbol.for('cordis.original')]??value;
const own=(o,k)=>o!=null&&Object.hasOwn(o,k);
const record=v=>v!==null&&typeof v==='object'&&!Array.isArray(v);
const MESSAGES=Object.freeze({
 'invalid-operation':'此配置操作无效，或字段不允许通过此接口修改。',
 'entry-unavailable':'此插件配置当前不可用，或不属于此接口的可访问范围。',
 conflict:'配置已发生变化，请刷新后重试。',
 overridden:'此配置由主机或命令行覆盖层控制，无法在插件表单中修改。',
 'apply-failed':'新配置未能应用，已恢复原配置。',
 'invalid-config':'提交的配置不符合字段要求，请检查对应操作。',
 'host-unavailable':'主机配置服务暂不可用，请稍后重试。',
 'recovery-failed':'配置应用失败，恢复状态也未能确认，请重新读取并检查主机状态。',
});
const FAULTS=new WeakSet();
function fault(status,code,path){const error=Object.assign(new Error(code),{status,code,...path?{path}:{}});FAULTS.add(error);return error;}
function publicPath(path){return Array.isArray(path)&&path.length>0&&path.length<=32&&path.every(k=>typeof k==='string'&&k.length<=256&&!BAD.has(k))?[...path]:undefined;}
function validationPath(error,ops){
 if(!error?.[Symbol.for('ValidationError')]||!Array.isArray(error.options?.path))return;
 const parts=error.options.path.map(x=>Number.isSafeInteger(x)&&x>=0?String(x):x),path=publicPath(parts);if(!path)return;
 // A plugin can manufacture ValidationError paths. Return only a submitted,
 // already accepted operation path, never text or arbitrary descendant keys.
 for(const op of ops){const known=publicPath(op.path);if(known&&known.slice(0,Math.min(known.length,path.length)).every((x,i)=>x===path[i]))return known;}
}
export function pluginConfigUnavailable(req){
 let path;try{path=new URL(req.url??'/', 'http://dsh-go.invalid').pathname;}catch{return;}
 if(path===BASE||path.startsWith(BASE+'/'))return {v:1,error:{code:'host-unavailable',message:MESSAGES['host-unavailable']}};
}
function labelOf(title,entry){
 try{
  const valid=x=>typeof x==='string'&&x.trim().length>0&&x.length<=4096;
  if(valid(title))return title;
  if(record(title)){const fields=Object.entries(title).filter(([k,v])=>k.length<=64&&!BAD.has(k)&&valid(v));if(fields.length&&fields.length<=64)return Object.fromEntries(fields);}
 }catch{}
 return entry.options.id;
}
function safeData(v,depth=0){
 if(depth>64)throw fault(400,'invalid-operation');
 if(v===null||['string','boolean'].includes(typeof v))return v;
 if(typeof v==='number'&&Number.isFinite(v))return v;
 if(Array.isArray(v))return v.map(x=>safeData(x,depth+1));
 if(record(v)){const out={};for(const [k,x]of Object.entries(v)){if(BAD.has(k))throw fault(400,'invalid-operation');out[k]=safeData(x,depth+1);}return out;}
 throw fault(400,'invalid-operation');
}
function plain(v,depth=0){
 if(depth>64)throw fault(404,'entry-unavailable');
 if(v&&typeof v==='object'&&VOLATILE in v)return plain(v.get(),depth+1);
 if(Array.isArray(v))return v.map(x=>plain(x,depth+1));
 if(record(v))return Object.fromEntries(Object.entries(v).filter(([k])=>!BAD.has(k)).map(([k,x])=>[k,plain(x,depth+1)]));
 return v;
}
function graphOf(schema){
 const graph=schema.toJSON();if(!record(graph.refs)||!own(graph.refs,graph.uid))throw Error('unsupported-schema');
 const nodes=graph.refs, visiting=new Set(),visited=new Set();
 const check=(id,secret=false)=>{const n=nodes[id];if(!n)throw Error('unsupported-schema');
  const hidden=secret||n.meta?.role==='secret',key=String(id)+':'+hidden;
  if(visiting.has(id))throw Error('unsupported-schema');if(visited.has(key))return;
  if(!TYPES.has(n.type)&&!(n.type==='any'&&hidden))throw Error('unsupported-schema');visiting.add(id);
  for(const k of Object.keys(n.dict??{}))if(BAD.has(k))throw Error('unsupported-schema');
  for(const child of [...Object.values(n.dict??{}),...(n.list??[]),...(n.inner===undefined?[]:[n.inner])])check(child,hidden);
  visiting.delete(id);visited.add(key);
 };check(graph.uid);return graph;
}
function children(n){return [...Object.values(n.dict??{}),...(n.list??[]),...(n.inner===undefined?[]:[n.inner])];}
function secretTree(g,id){const n=g.refs[id];return n.meta?.role==='secret'||children(n).some(x=>secretTree(g,x));}
function project(g,id,value,path=[],secrets){
 const n=g.refs[id];
 if(n.meta?.role==='secret'){secrets?.push({path,configured:value!==undefined,writable:false});return undefined;}
 if(value===undefined)return undefined;
 if(record(value)&&own(value,'__jsExpr'))return undefined;
 if(n.type==='const')return safeData(value);
 if(n.type==='transform')return project(g,n.inner,value,path,secrets);
 if(n.type==='union'||n.type==='intersect'){
  // A secret branch hides the whole position; never reveal through another branch.
  if(n.list.some(x=>g.refs[x].meta?.role==='secret')){secrets?.push({path,configured:value!==undefined,writable:false});return undefined;}
  const hidden=[];const values=n.list.map(x=>project(g,x,value,path,hidden));
  secrets?.push(...hidden);if(hidden.some(x=>x.path.length===path.length))return undefined;
  const out=record(value)?Object.assign({},...values.filter(record)):values.find(x=>x!==undefined);
  return maskValue(out,schemaMasks(g).intrinsic.get(String(id)));
 }
 if(n.type==='object'){
  if(!record(value))return undefined;const out={};
  for(const [k,id]of Object.entries(n.dict??{})){const v=project(g,id,own(value,k)?value[k]:undefined,[...path,k],secrets);if(v!==undefined)out[k]=v;}return out;
 }
 if(n.type==='array')return Array.isArray(value)?value.map((v,i)=>project(g,n.inner,v,[...path,String(i)],secrets)??null):undefined;
 if(n.type==='dict'){
  if(!record(value))return undefined;const out={};for(const [k,v]of Object.entries(value)){if(BAD.has(k))continue;const x=project(g,n.inner,v,[...path,k],secrets);if(x!==undefined)out[k]=x;}return out;
 }
 if(value===null||['string','number','boolean'].includes(typeof value))return value;
 return undefined;
}
// Secret positions are a schema property, independent of a particular runtime value.
// Object keys/dictionary wildcards and array elements occupy separate domains.
// Literal "*" is never a wildcard. Only canonical array-index keys may also
// mask that array position; object keys retain their original string identity. Immutable masks let
// cross-branch and shared-ref contexts can be merged without changing other paths.
function mergeMask(a,b){
 if(!a)return b;if(!b)return a;if(a.hide||b.hide)return {hide:true};
 let object,array;
 if(a.object||b.object){
  const keys={...a.object?.keys};for(const [k,v]of Object.entries(b.object?.keys??{}))keys[k]=mergeMask(keys[k],v);
  object={keys,each:mergeMask(a.object?.each,b.object?.each)};
 }
 if(a.array||b.array)array={each:mergeMask(a.array?.each,b.array?.each)};
 return {object,array};
}
const arrayIndexKey=key=>/^(0|[1-9]\d*)$/.test(key)&&Number(key)<4294967295;
const masksCache=new WeakMap();
function schemaMasks(g){
 if(masksCache.has(g))return masksCache.get(g);
 const intrinsic=new Map(),contexts=new Map();
 const local=id=>{
  id=String(id);if(intrinsic.has(id))return intrinsic.get(id);const n=g.refs[id];let mask;
  if(n.meta?.role==='secret')mask={hide:true};
  else if(n.type==='union'||n.type==='intersect')for(const child of n.list)mask=mergeMask(mask,local(child));
  else if(n.type==='transform')mask=local(n.inner);
  else if(n.type==='array'){const child=local(n.inner);if(child)mask={array:{each:child}};}
  else if(n.type==='dict'){const child=local(n.inner);if(child)mask={object:{each:child}};}
  else if(n.type==='object')for(const [k,child]of Object.entries(n.dict??{})){const hidden=local(child);if(hidden)mask=mergeMask(mask,{object:{keys:{[k]:hidden}}});}
  intrinsic.set(id,mask);return mask;
 };
 const visit=(id,inherited)=>{
  id=String(id);const n=g.refs[id],mask=mergeMask(contexts.get(id),mergeMask(local(id),inherited));
  if(contexts.has(id)&&isDeepStrictEqual(contexts.get(id),mask))return;
  contexts.set(id,mask);
  if(mask?.hide){for(const child of children(n))visit(child,mask);return;}
  if(n.type==='union'||n.type==='intersect')for(const child of n.list)visit(child,mask);
  else if(n.type==='transform')visit(n.inner,mask);
  else if(n.type==='array'){
   // Preserve the existing conservative same-path rule for canonical indices;
   // do not coerce object keys such as 01, -1, 1e0 or * into array positions.
   let element=mask?.array?.each;
   for(const [key,fixed]of Object.entries(mask?.object?.keys??{}))if(arrayIndexKey(key))element=mergeMask(element,fixed);
   visit(n.inner,element);
  }
  else if(n.type==='dict'){
   // Every concrete dictionary key uses the same element ref. Its metadata must
   // obey both wildcard and fixed-key contexts collected from sibling branches.
   let element=mask?.object?.each;
   for(const fixed of Object.values(mask?.object?.keys??{}))element=mergeMask(element,fixed);
   visit(n.inner,element);
  }else if(n.type==='object')for(const [k,child]of Object.entries(n.dict??{}))visit(child,mergeMask(mask?.object?.keys?.[k],mask?.object?.each));
 };
 visit(g.uid);for(const id of Object.keys(g.refs))if(!contexts.has(id))visit(id);const result={intrinsic,contexts};masksCache.set(g,result);return result;
}
function maskValue(value,mask){
 if(mask?.hide)return undefined;if(value===undefined||!mask)return value;
 if(Array.isArray(value))return value.map((v,i)=>maskValue(v,mergeMask(mask.array?.each,mask.object?.keys?.[String(i)]))??null);
 if(record(value)){
  const result={};for(const [k,v]of Object.entries(value)){const stripped=maskValue(v,mergeMask(mask.object?.each,mask.object?.keys?.[k]));if(stripped!==undefined)result[k]=stripped;}return result;
 }
 return value;
}
// Display/validation metadata does not contain a configuration sample. Unknown
// metadata on a sensitive node is withheld, while ordinary nodes retain it.
const DISPLAY_META=new Set(['role','description','comment','link','required','disabled','collapse','hidden','loose','volatile','group','order','i18n','label','title']);
const VALUE_META=new Set(['default','const','value','example']);
const VALUES_META=new Set(['examples','enum']);
function cleanSchema(g){
 const out=structuredClone(g),{contexts}=schemaMasks(g);
 for(const [id,n]of Object.entries(out.refs)){
  const mask=contexts.get(id);
  // A sensitive callback can serialize source or a custom producer payload.
  // Partial masks count too; ordinary nodes have an undefined context value.
  if(mask)delete n.callback;
  // An admitted any is opaque below a secret boundary; its implementation
  // metadata is not a user-visible form description. Preserve the boundary.
  if(n.type==='any'&&mask?.hide&&n.meta?.role!=='secret'){n.meta={};delete n.value;continue;}
  if(own(n,'value')){const v=maskValue(n.value,mask);if(v===undefined)delete n.value;else n.value=v;}
  for(const [key,value]of Object.entries(n.meta??{})){
   if(VALUE_META.has(key)){
    const v=maskValue(project(g,id,value),mask);if(v===undefined)delete n.meta[key];else n.meta[key]=v;
   }else if(VALUES_META.has(key)){
    if(mask?.hide)delete n.meta[key];
    else if(Array.isArray(value))n.meta[key]=value.map(v=>maskValue(project(g,id,v),mask)).filter(v=>v!==undefined);
    else if(mask)delete n.meta[key];
   }else if(mask&&!DISPLAY_META.has(key)&&!( !mask.hide&&['min','max','step','pattern'].includes(key)))delete n.meta[key];
  }
 }
 return out;
}
function pathNodes(g,id,path){
 const n=g.refs[id];if(n.meta?.role==='secret')throw fault(400,'invalid-operation');
 if(n.type==='transform')return pathNodes(g,n.inner,path);
 if(n.type==='union'||n.type==='intersect'){
  // Missing fields in another branch do not create a writable field; secret branches still reject.
  return n.list.flatMap(x=>pathNodes(g,x,path));
 }
 if(!path.length){if(secretTree(g,id))throw fault(400,'invalid-operation');return [id];}
 const [k,...rest]=path;let child;
 if(n.type==='object')child=own(n.dict??{},k)?n.dict[k]:undefined;
 if(n.type==='array'&&/^(0|[1-9]\d*)$/.test(k))child=n.inner;
 if(n.type==='dict')child=n.inner;
 if(child===undefined)return [];return pathNodes(g,child,rest);
}
function member(root,path){for(const key of path){if(!own(root,key))return undefined;root=root[key];}return root;}
function operations(g,raw,base,ops,resolved){
 const next=structuredClone(raw);
 for(const op of ops){
  try{
  if(!record(op)||!['set','unset'].includes(op.op)||Object.keys(op).some(k=>!['op','path','value'].includes(k))||!Array.isArray(op.path)||!op.path.length||op.path.length>32||op.path.some(k=>typeof k!=='string'||BAD.has(k)||k.length>256)|| (op.op==='set')!==own(op,'value'))throw fault(400,'invalid-operation');
  const targets=pathNodes(g,g.uid,op.path);if(!targets.length)throw fault(400,'invalid-operation');
  if(op.op==='set'){const value=safeData(op.value);for(const target of targets)if(!isDeepStrictEqual(project(g,target,value),value))throw fault(400,'invalid-operation');}
  let parent=next;const route=op.path.slice(0,-1);
  for(const [index,k] of route.entries()){if(!record(parent)&&!Array.isArray(parent))throw fault(400,'invalid-operation');if(!own(parent,k)){if(Array.isArray(parent))throw fault(400,'invalid-operation');const current=member(resolved,route.slice(0,index+1));parent[k]=Array.isArray(current)?structuredClone(current):{};}parent=parent[k];if(record(parent)&&own(parent,'__jsExpr'))throw fault(400,'invalid-operation');}
  const k=op.path.at(-1);if(!record(parent)&&!Array.isArray(parent))throw fault(400,'invalid-operation');
  if(Array.isArray(parent)&&(!/^(0|[1-9]\d*)$/.test(k)||Number(k)>=parent.length))throw fault(400,'invalid-operation');
  if(op.op==='set')parent[k]=safeData(op.value);
  else if(Array.isArray(parent))parent.splice(Number(k),1);
  else {const inherited=member(base,op.path);if(inherited===undefined)delete parent[k];else parent[k]=structuredClone(inherited);}
  }catch(error){const path=publicPath(op?.path);if(FAULTS.has(error)&&error.code==='invalid-operation'&&path)error.path=path;throw error;}
 }
 return next;
}
function fileBytes(path){try{return readFileSync(path);}catch(e){if(e.code==='ENOENT')return Buffer.from('[]\n');throw e;}}
function secretFacts(g,raw,value){
 const facts=new Map(),parents=new Map();
 const visit=(id,input,resolved,path,known)=>{
  const n=g.refs[id];known=known&&!n.meta?.loose&&!(record(input)&&own(input,'__jsExpr'));
  const parent=path.length?parents.get(JSON.stringify(path.slice(0,-1))):undefined,field=path.at(-1);
  if(n.meta?.role==='secret'){
   parent?.secrets.add(field);
   const key=JSON.stringify(path),configured=known&&(typeof input==='string'&&input.length>0||typeof input==='boolean'||typeof input==='number'&&Number.isFinite(input)),prior=facts.get(key);
   facts.set(key,{path,configured:configured&&(prior?.configured??true),writable:false});return;
  }
  if(n.meta?.role==='credential-ref'&&parent){
   const ref=resolved===undefined?n.meta.default:resolved;
   parent.refs.set(field,parent.refs.has(field)&&parent.refs.get(field)!==ref?undefined:ref);
  }
  if(n.type==='transform'){visit(n.inner,input,resolved,path,false);return;}
  if(n.type==='union'||n.type==='intersect'){for(const child of n.list)visit(child,input,resolved,path,known);return;}
  if(n.type==='object'){
   // Branches at the same concrete parent share one set of distinct fields.
   const key=JSON.stringify(path);if(!parents.has(key))parents.set(key,{path,secrets:new Set(),refs:new Map()});
   for(const [key,child]of Object.entries(n.dict??{}))visit(child,record(input)&&own(input,key)?input[key]:undefined,record(resolved)?resolved[key]:undefined,[...path,key],known&&record(input));
  }
  else if(n.type==='array'&&Array.isArray(resolved))resolved.forEach((v,i)=>visit(n.inner,Array.isArray(input)&&own(input,i)?input[i]:undefined,v,[...path,String(i)],known&&Array.isArray(input)));
  else if(n.type==='dict'&&record(resolved))for(const [key,v]of Object.entries(resolved))if(!BAD.has(key))visit(n.inner,record(input)&&own(input,key)?input[key]:undefined,v,[...path,key],known&&record(input));
 };
 visit(g.uid,raw,value,[],true);
 for(const {path,secrets,refs}of parents.values())if(secrets.size===1&&refs.size===1){
  const [[field,ref]]=refs,refPath=[...path,field],hidden=facts.has('[]')||refPath.some((_,i)=>facts.has(JSON.stringify(refPath.slice(0,i+1))));
  // A same-path or ancestor secret in another branch still hides this value.
  if(!hidden&&typeof ref==='string'&&ref.length>0)facts.get(JSON.stringify([...path,...secrets])).credentialRef=ref;
 }
 return [...facts.values()];
}
export function createPluginConfig(ctx,{readBody,send}){
 const key=randomBytes(32),ids=new WeakMap(),generations=new WeakMap();let seq=0;
 const identity=o=>{if(!o||typeof o!=='object'&&typeof o!=='function')return null;if(!ids.has(o))ids.set(o,++seq);return ids.get(o);};
 const statusChanged=fiber=>{if(fiber&&typeof fiber==='object')generations.set(fiber,(generations.get(fiber)??0)+1);};
 const service=()=>{const editor=ctx.get('configEditor');if(!editor)throw fault(503,'host-unavailable');return editor;};
 function inspect(entry,addressable,origin){
  let reason,state='active',graph,schema=entry.fiber?.runtime?.Config;
  if(!origin.allowed)reason='entry-unavailable';
  else if(!addressable)reason='nested-include';
  else if(entry.disabled||entry.fiber?.state!==2){state=entry.fiber?.state===3?'failed':'inactive';reason='not-active';}
  else if(!schema||typeof schema.toJSON!=='function')reason='no-schema';
  else if(record(entry.options.config)&&own(entry.options.config,'__jsExpr'))reason='unsupported-schema';
  else try{graph=graphOf(schema);}catch{reason='unsupported-schema';}
  if(reason&&state==='active')state='unsupported';
  let writable=false;if(!reason&&origin.kind==='plugin')try{writable=service().dshGoAsyncChange===true&&service().canWrite?.(entry)===true;}catch{}
  return {summary:{entryId:entry.options.id,package:origin.package,owner:origin.owner,bundle:origin.bundle,kind:origin.kind,source:origin.source,label:labelOf(origin.label,entry),state,configurable:!reason,writable,...reason?{reason}:!writable?{reason:service().dshGoAsyncChange===true?'overridden':'host-unavailable'}:{}},schema,graph,origin};
 }
 async function rows(targetId){
  const {bundleEntrySources}=await import('./config-source.js');
  const editor=service(),manager=ctx.get('pluginManager');if(typeof manager?.listBundles!=='function')throw fault(503,'host-unavailable');
  const bundles=await manager.listBundles();if(serviceIdentity(ctx.get('pluginManager'))!==serviceIdentity(manager)||serviceIdentity(service())!==serviceIdentity(editor))throw fault(409,'conflict');
  const all=[...ctx.get('loader').entries()].filter(e=>typeof e.options.id==='string'),address=new Set(editor.entries()),sources=bundleEntrySources(ctx,all,bundles);const count=new Map();for(const e of all)count.set(e.options.id,(count.get(e.options.id)??0)+1);
  // Source ownership and duplicate IDs still depend on the full current entry set.
  // A detail request only needs to serialize/validate its own schema.
  return all.flatMap((entry,index)=>{if(targetId!==undefined&&entry.options.id!==targetId)return [];const item=inspect(entry,address.has(entry),sources[index]);if(count.get(entry.options.id)>1){item.summary={...item.summary,state:'unsupported',configurable:false,writable:false,reason:'ambiguous-id'};}return {entry,...item};});
 }
 async function locate(id){const row=(await rows(id)).find(x=>x.summary.entryId===id);if(row&&!row.origin.allowed)throw fault(403,'entry-unavailable');if(!row?.summary.configurable)throw fault(404,'entry-unavailable');return row;}
 function token(row,layer){const e=row.entry;return createHmac('sha256',key).update(JSON.stringify([identity(e),identity(e.fiber),identity(e.fiber?.runtime),generations.get(e.fiber)??0,row.origin.proof,row.graph,e.options.config??{},layer.inherited,layer.override,row.summary.writable])).digest('base64url');}
 async function snapshot(id){const row=await locate(id),layer=service().configuration().find(x=>x.entry===row.entry);if(!layer)throw fault(404,'entry-unavailable');
  let inherited=layer.inherited;try{inherited=row.schema(inherited);}catch{}
  // Cordis 4.1 retains raw input in config; effectiveConfig is the running value.
  const fiber=row.entry.fiber,resolved=plain('effectiveConfig'in fiber?fiber.effectiveConfig:fiber.config),value=project(row.graph,row.graph.uid,resolved)??{};
  return {row,layer,body:{v:1,entryId:id,kind:'plugin',owner:row.origin.owner,bundle:row.origin.bundle,source:row.origin.source,revision:token(row,layer),schema:cleanSchema(row.graph),value,base:project(row.graph,row.graph.uid,plain(inherited))??{},user:project(row.graph,row.graph.uid,plain(layer.override))??{},secrets:secretFacts(row.graph,row.entry.options.config,resolved),writable:row.summary.writable}};
 }
 async function update(id,input){
  if(!record(input)||Object.keys(input).some(k=>!['revision','ops'].includes(k))||typeof input.revision!=='string'||input.revision.length>256||!Array.isArray(input.ops)||!input.ops.length||input.ops.length>128)throw fault(400,'invalid-operation');
  const before=await snapshot(id),editor=service();let changed=false,bytes,oldRaw;
  if(editor.dshGoAsyncChange!==true)throw fault(503,'host-unavailable');
  if(!before.body.writable)throw fault(409,'overridden');
  try{await editor.edit(before.row.entry,async(raw,inherited)=>{
   const current=await snapshot(id);if(!current.body.writable)throw fault(409,'overridden');if(current.row.entry!==before.row.entry||current.body.revision!==input.revision)throw fault(409,'conflict');
   const next=operations(current.row.graph,raw,inherited,input.ops,current.body.value);
   try{current.row.schema(next);}catch(error){throw fault(422,'invalid-config',validationPath(error,input.ops));}
   try{bytes=fileBytes(editor.documentPath);oldRaw=structuredClone(raw);}catch{throw fault(503,'host-unavailable');}
   changed=true;return next;
  });}catch(error){
   if(FAULTS.has(error))throw error;
   if(String(error?.message).includes('overridden by a home patch or command-line overlay'))throw fault(409,'overridden');
   if(!changed){
    if(error?.code==='ENOSPC'||error?.code==='EFBIG')throw fault(503,'host-unavailable');
    throw fault(409,'conflict');
   }
   let restoredBytes;
   try{restoredBytes=fileBytes(editor.documentPath);}catch{throw fault(500,'recovery-failed');}
   const restored=restoredBytes.equals(bytes)&&before.row.entry.fiber?.state===2&&isDeepStrictEqual(before.row.entry.options.config??{},oldRaw);
   throw fault(restored?409:500,restored?'apply-failed':'recovery-failed');
  }
  return (await snapshot(id)).body;
 }
 return {statusChanged,async handle(req,res,path){
  if(path!==BASE&&!path.startsWith(BASE+'/'))return false;
  try{
   if(path===BASE){if(req.method!=='GET')send(res,405,{v:1,error:{code:'invalid-operation',message:'此接口不支持该请求方法。'}});else send(res,200,{v:1,entries:(await rows()).map(x=>x.summary)});return true;}
   let id;try{id=decodeURIComponent(path.slice(BASE.length+1));}catch{throw fault(400,'invalid-operation');}
   if(!id||id.length>512)throw fault(404,'entry-unavailable');
   if(req.method==='GET')send(res,200,(await snapshot(id)).body);
   else if(req.method==='POST'){
    // Refuse protected/unverified targets before parsing a client operation;
    // update() checks again, including inside ConfigEditor's exclusive edit.
    const row=await locate(id);if(service().dshGoAsyncChange!==true)throw fault(503,'host-unavailable');if(!row.summary.writable)throw fault(409,'overridden');
    if(String(req.headers['content-type']).split(';')[0].trim().toLowerCase()!=='application/json'){req.resume();throw fault(400,'invalid-operation');}
    let input;try{input=JSON.parse((await readBody(req,512*1024)).toString('utf8'));}catch{throw fault(400,'invalid-operation');}
    send(res,200,await update(id,input));
   }else send(res,405,{v:1,error:{code:'invalid-operation',message:'此接口不支持该请求方法。'}});
  }catch(error){const known=FAULTS.has(error),code=known?error.code:'host-unavailable',path=known?publicPath(error.path):undefined;send(res,known?error.status:503,{v:1,error:{code,message:MESSAGES[code],...path?{path}:{}}});}
  return true;
 }};
}
