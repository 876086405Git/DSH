import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { createHash, randomBytes } from 'node:crypto';
import vm from 'node:vm';
const ts=createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX,'package.json'))('typescript');
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
const source=new URL('../../../app/ohos/entry/src/main/ets/',import.meta.url);
function load(name,dependencies){const module={exports:{}};const js=ts.transpileModule(readFileSync(new URL(name+'.ets',source),'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;vm.runInNewContext(js,{module,exports:module.exports,require:key=>dependencies[key]??{},console});return module.exports;}
class ChannelError extends Error {constructor(code,message){super(message);this.code=code;}}
function fixture(hooks={}){
 let context={},generation=0,attached=0,revoked=false,consumed=false,finished=null,published=0,now=100;
 const life={available:1,foreground:1,engineGeneration:1,ownerGeneration:1};
 const request={engineId:'engine',bridgeGeneration:1,requestId:'request',tool:'mcp__phone__notify',args:{title:'original',text:'body'}};
 const key={engineId:'engine',bridgeGeneration:1,requestId:'request',executionNonce:'nonce'};
 const host={getState:()=>({baseUrl:'http://127.0.0.1:3080'}),lifecycleSnapshot:()=>({...life}),phoneSnapshot:()=>({available:generation>0&&!revoked,engineId:'engine',bridgeGeneration:generation,ownerHash:host.hash}),
 phoneAttach(hash,engine,owner){assert.equal(engine,life.engineGeneration);assert.equal(owner,life.ownerGeneration);host.hash=hash;attached++;revoked=false;return ++generation;},
 phoneRetire(g){if(g===generation)revoked=true;return true;},
 phoneOperation(op,k,result){assert.equal(k.requestId,'request');
  if(op==='inspect')return !revoked&&!consumed&&life.foreground?JSON.stringify(request):null;
  if(op==='consume'){if(revoked||consumed||!life.foreground||now>=1000)return false;consumed=true;return true;}
  if(op==='consumed')return consumed;
  if(op==='finish'){finished=JSON.parse(result);return true;}
  if(op==='revoke'){revoked=true;return consumed;}
  if(op==='check')return JSON.stringify({pending:!revoked&&!consumed&&now<1000,foreground:!!life.foreground,nowMs:now,deadlineMs:1000});
  throw new Error(op);
 }};
 const crypto={default:{createRandom:()=>({async generateRandom(){await hooks.random?.();return {data:randomBytes(32)};}}),createMd:()=>{const hash=createHash('sha256');return {async update(value){hash.update(value.data);},async digest(){return {data:hash.digest()};}};}}};
 const effects=load('phone/PhoneEffects',{'./PhoneReminders':load('phone/PhoneReminders',{}),'@ohos.notificationManager':{default:{SlotType:{SERVICE_INFORMATION:2},ContentType:{NOTIFICATION_CONTENT_BASIC_TEXT:0},async isNotificationEnabled(){await hooks.permission?.();return true;},async getSlot(){return null;},async publish(value){assert.equal(value.content.normal.title,'original');published++;await hooks.effect?.();}}}});
 const bridgeModule=load('phone/PhoneBridge',{'./PhoneEffects':effects,'../runtime/NativeHost':{loadNativeHost:async()=>host},'../runtime/RuntimeCore':{RuntimeChannelError:ChannelError},'@ohos.security.cryptoFramework':crypto,'@ohos.util':{default:{TextEncoder:class{encodeInto(value){return new TextEncoder().encode(value);}}}}});
 const pluginModule=load('runtime/RuntimePlugin',{'../phone/PhoneBridge':bridgeModule});const plugin=new pluginModule.RuntimePlugin();plugin.ability={};
 const bridge=new bridgeModule.PhoneBridge(()=>plugin.ability===null?null:context);plugin.phone=bridge;
 return {bridge,plugin,host,key,request,life,get published(){return published;},get consumed(){return consumed;},get revoked(){return revoked;},get finished(){return finished;},get attached(){return attached;},set now(v){now=v;}};
}
test('explicit enable creates random owner only in bootstrap and repeats idempotently',async()=>{
 const f=fixture();await assert.rejects(f.bridge.attach(false),e=>e.code==='ohos_phone_disabled');assert.equal(f.attached,0);
 const a=await f.bridge.attach(true),b=await f.bridge.attach(true);assert.equal(a.get('owner'),b.get('owner'));assert.match(a.get('owner'),/^[a-f0-9]{64}$/);assert.equal(f.host.hash,createHash('sha256').update(a.get('owner')).digest('hex'));assert.equal(f.attached,1);
});
test('late async random result after detach cannot install owner',async()=>{
 const wait=deferred(),started=deferred(),f=fixture({random:()=>{started.resolve();return wait.promise;}});const task=f.bridge.attach(true);await started.promise;f.plugin.onDetachedFromAbility();wait.resolve();await assert.rejects(task,e=>e.code==='ohos_phone_retired');assert.equal(f.attached,0);
});
test('actual plugin detach during real effects permission await never consumes or publishes',async()=>{
 const wait=deferred(),f=fixture({permission:()=>wait.promise});await f.bridge.attach(true);const task=f.bridge.execute(f.key);f.plugin.onDetachedFromAbility();wait.resolve();const result=await task;assert.equal(f.published,0);assert.equal(f.consumed,false);assert.equal(f.revoked,true);assert.equal(result.get('dispatched'),false);
});
test('native registered args are authoritative and trusted finished result follows SDK settlement',async()=>{
 const wait=deferred(),started=deferred(),f=fixture({effect:()=>{started.resolve();return wait.promise;}});await f.bridge.attach(true);const task=f.bridge.execute({...f.key,args:{title:'tampered'}});await started.promise;assert.equal(f.published,1);assert.equal(f.finished,null);wait.resolve();const result=await task;assert.equal(result.get('status'),'succeeded');assert.equal(f.finished.dispatched,true);
});
test('pending handoff stays pending in background but final continue is foreground gated',async()=>{
 const f=fixture();await f.bridge.attach(true);f.request.tool='mcp__phone__handoff';f.life.foreground=0;
 assert.equal(f.bridge.check(f.key).get('pending'),true);assert.equal(f.bridge.check(f.key).get('foreground'),false);assert.throws(()=>f.bridge.handoffContinue(f.key));assert.equal(f.consumed,false);
 f.life.foreground=1;const result=f.bridge.handoffContinue(f.key);assert.equal(result.get('evidence'),'user_confirmed');assert.equal(f.consumed,true);
});
test('BOOTTIME expiry closes pending button and consume, without wall clock',async()=>{
 const f=fixture();await f.bridge.attach(true);f.request.tool='mcp__phone__handoff';f.now=1000;assert.equal(f.bridge.check(f.key).get('pending'),false);assert.throws(()=>f.bridge.handoffContinue(f.key),e=>e.code==='ohos_phone_stale');assert.equal(f.consumed,false);
});
test('old scoped retire cannot remove new owner, cancel reports native consumed evidence',async()=>{
 const f=fixture();await f.bridge.attach(true);f.bridge.retireScope('engine',99);assert.equal(f.revoked,false);assert.equal(f.bridge.cancel(f.key).get('dispatched'),false);assert.equal(f.revoked,true);
});
