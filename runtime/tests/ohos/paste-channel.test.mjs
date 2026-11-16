// Actual plugin code, real codec-shaped args. UI/security and pasteboard are
// controlled platform boundaries: these tests do NOT grant device authorization.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import vm from 'node:vm';
import test from 'node:test';
import { promptFixture } from './paste-prompt-fixture.mjs';
const prefix = process.env.OHOS_TYPESCRIPT_PREFIX;
assert(prefix, 'OHOS_TYPESCRIPT_PREFIX must point at the locked TypeScript prefix');
const ts = createRequire(resolve(prefix, 'package.json'))('typescript');
const source = process.env.OHOS_PASTE_SOURCE || new URL('../../../app/ohos/entry/src/main/ets/plugins/PastePlugin.ets', import.meta.url);
const compiled = ts.transpileModule(readFileSync(source, 'utf8'), { compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
} });
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => { resolve=a; reject=b; }); return { promise, resolve, reject }; };
const flush = async () => { for(let i=0;i<12;i++) await Promise.resolve(); };
function fixture(hooks={}) {
  const channels=[], prompts=[], reads=[], replies=[];
  const realPrompt = hooks.realPrompt ? promptFixture(ts, hooks.realPrompt) : null;
  class Channel { constructor(_m,name) { assert.equal(name,'dsh/paste'); channels.push(this); } setMethodCallHandler(h){this.handler=h;} }
  class Prompt {
    constructor(cancel){this.cancel=cancel;this.feedbacks=[];this.closeCalls=0;prompts.push(this);}
    async open(context,click){assert.equal(context,'ability-context');this.click=click;await hooks.open?.();}
    feedback(resource){this.feedbacks.push(resource);return hooks.shown===true;}
    async close(){this.closeCalls++;await hooks.close?.(this.closeCalls);this.closed=true;}
  }
  const module={exports:{}};
  vm.runInNewContext(compiled.outputText, {module,exports:module.exports,$r:key=>key,
    require(name){
      if(name==='@ohos/flutter_ohos')return{MethodChannel:Channel};
      if(name==='./PastePrompt')return{PastePrompt:realPrompt?.PastePrompt ?? Prompt};
      if(name==='@ohos.pasteboard')return{default:{getSystemPasteboard:()=>({getData:async()=>{
        reads.push('getData');const text=hooks.read?await hooks.read():'中文🔐\nsecret+/%';return{getPrimaryText:()=>text};
      }})}};
      throw Error('unmapped '+name);
    },
  });
  const Plugin=module.exports.default;
  function attach(){const plugin=new Plugin(), engine={getBinaryMessenger:()=>({})}, ability={context:'ability-context'};plugin.onAttachedToEngine(engine);plugin.onAttachedToAbility({getAbility:()=>ability});Plugin.onForeground?.(ability);return{plugin,engine,ability,channel:channels.at(-1)};}
  const first=attach();
  function call(method='readText',id='a',instance=first){const result=deferred();let count=0;instance.channel.handler.onMethodCall({method,argument:key=>key==='requestId'?id:null},{success:value=>{count++;const out=value?.entries?Object.fromEntries(value):value;replies.push(out);result.resolve(out);},notImplemented:()=>result.reject(Error('notImplemented'))});return{result:result.promise,count:()=>count};}
  return{...first,attach,call,prompts,reads,replies,prompt:realPrompt,foreground:ability=>Plugin.onForeground(ability),background:ability=>Plugin.onBackground(ability)};
}
test('request opens security UI but never reads before actual success callback',async()=>{
 const f=fixture(),r=f.call();await flush();assert.equal(f.prompts.length,1);assert.deepEqual(f.reads,[]);
 f.prompts[0].click(true);assert.deepEqual(f.reads,['getData']);assert.deepEqual(await r.result,{status:'text',text:'中文🔐\nsecret+/%'});await flush();assert.equal(f.prompts[0].closed,true);assert.equal(r.count(),1);
});
test('authorization denied never reads and produces native feedback',async()=>{const f=fixture(),r=f.call();await flush();f.prompts[0].click(false);assert.deepEqual(await r.result,{status:'denied'});assert.deepEqual(f.reads,[]);assert.deepEqual(f.prompts[0].feedbacks,['app.string.dsh_paste_denied']);});
test('empty clipboard is explicit with visible native feedback',async()=>{const f=fixture({read:async()=>''}),r=f.call();await flush();f.prompts[0].click(true);assert.deepEqual(await r.result,{status:'empty'});assert.deepEqual(f.prompts[0].feedbacks,['app.string.dsh_paste_empty']);});
test('permission and concurrent-read errors do not expose exception contents or retry',async()=>{
 for(const code of [201,27787277]){const f=fixture({read:async()=>{throw Object.assign(Error('private clipboard'),{code});}}),r=f.call();await flush();f.prompts[0].click(true);assert.deepEqual(await r.result,{status:'readFailed'});assert.equal(f.reads.length,1);assert.deepEqual(f.prompts[0].feedbacks,['app.string.dsh_paste_failed']);}
});
test('a toast that went up is reported, so the Dart side does not say it again',async()=>{
 const f=fixture({shown:true}),r=f.call();await flush();f.prompts[0].click(false);assert.deepEqual(await r.result,{status:'denied',shown:true});
 const g=fixture({shown:false}),q=g.call();await flush();g.prompts[0].click(false);assert.deepEqual(await q.result,{status:'denied'});
 const c=fixture({shown:true}),t=c.call();await flush();c.prompts[0].cancel();assert.deepEqual(await t.result,{status:'cancelled'});
});
test('cancel before authorization gives one cancellation, no read',async()=>{const f=fixture(),r=f.call();await flush();f.prompts[0].cancel();assert.deepEqual(await r.result,{status:'cancelled'});f.prompts[0].click(true);assert.equal(f.reads.length,0);assert.equal(r.count(),1);});
test('wrong request cannot cancel another target; exact cancel settles',async()=>{const f=fixture(),r=f.call();await flush();assert.equal(await f.call('cancel','wrong').result,false);assert.equal(r.count(),0);assert.equal(await f.call('cancel').result,true);assert.deepEqual(await r.result,{status:'cancelled'});});
test('detach while reading drops the late sensitive reply',async()=>{const read=deferred(),f=fixture({read:()=>read.promise}),r=f.call();await flush();f.prompts[0].click(true);f.plugin.onDetachedFromEngine(f.engine);assert.deepEqual(await r.result,{status:'cancelled'});read.resolve('late-private-key');await flush();assert.equal(r.count(),1);assert(!JSON.stringify(f.replies).includes('late-private'));});
test('ability detach cancels and refuses new requests until attached',async()=>{const f=fixture(),r=f.call();await flush();f.plugin.onDetachedFromAbility();assert.deepEqual(await r.result,{status:'cancelled'});assert.deepEqual(await f.call().result,{status:'unavailable'});});
test('duplicate success callbacks read only once',async()=>{const read=deferred(),f=fixture({read:()=>read.promise}),r=f.call();await flush();f.prompts[0].click(true);f.prompts[0].click(true);assert.equal(f.reads.length,1);read.resolve('once');assert.deepEqual(await r.result,{status:'text',text:'once'});});
test('other engine is busy while exact old owner closes',async()=>{const close=deferred(),f=fixture({close:()=>close.promise}),r=f.call();await flush();f.prompts[0].cancel();await r.result;const second=f.attach();assert.deepEqual(await f.call('readText','b',second).result,{status:'busy'});close.resolve();await flush();const next=f.call('readText','b',second);await flush();assert.equal(f.prompts.length,2);f.prompts[0].cancel();assert.equal(next.count(),0);f.prompts[1].cancel();assert.deepEqual(await next.result,{status:'cancelled'});});
test('failed close retains owner; exact explicit cancel retries before new admission',async()=>{const f=fixture({close:async n=>{if(n===1)throw Error('close failed');}}),r=f.call();await flush();f.prompts[0].cancel();await r.result;await flush();assert.equal(f.prompts[0].closed,undefined);assert.equal(f.prompts.length,1);assert.equal(await f.call('cancel','a').result,true);await flush();const next=f.call('readText','b');await flush();assert.equal(f.prompts.length,2);f.prompts[1].cancel();await next.result;});
test('cancel during opening keeps slot until open and close settle',async()=>{const opening=deferred(),f=fixture({open:()=>opening.promise,close:()=>opening.promise}),r=f.call();await flush();assert.equal(await f.call('cancel').result,true);assert.deepEqual(await r.result,{status:'cancelled'});assert.deepEqual(await f.call('readText','b').result,{status:'busy'});opening.resolve();await flush();assert.equal(f.prompts[0].closed,true);});
test('open error returns unavailable; no clipboard access',async()=>{const f=fixture({open:async()=>{throw Error('no window');}}),r=f.call();assert.deepEqual(await r.result,{status:'unavailable'});assert.equal(f.reads.length,0);});

test('new user request can clean a retired failed-close owner but remains busy itself',async()=>{
 const f=fixture({close:async n=>{if(n===1)throw Error('close failed');}}),r=f.call();await flush();f.prompts[0].cancel();await r.result;await flush();
 const second=f.attach();assert.deepEqual(await f.call('readText','b',second).result,{status:'busy'});await flush();assert.equal(f.prompts[0].closeCalls,2);assert.equal(f.prompts.length,1);assert.equal(f.reads.length,0);
 const next=f.call('readText','c',second);await flush();assert.equal(f.prompts.length,2);f.prompts[0].cancel();assert.equal(next.count(),0);f.prompts[1].cancel();await next.result;
});

test('inactive window during native dialog opening keeps user paste pending',async(t)=>{
 const opening=deferred(),f=fixture({realPrompt:{open:()=>opening.promise,openEvent:'WINDOW_INACTIVE'}}),r=f.call();
 t.after(async()=>{opening.resolve();await flush();});
 await flush();assert.equal(f.prompt.opens.length,1);assert.equal(r.count(),0);assert.deepEqual(f.reads,[]);
 assert.equal(f.prompt.opens[0].options.showInSubWindow,false);
 opening.resolve();await flush();f.prompt.contents[0].actions.click(true);
 assert.deepEqual(await r.result,{status:'text',text:'中文🔐\nsecret+/%'});await flush();
 assert.equal(f.reads.length,1);assert.equal(f.prompt.closes.length,1);assert.equal(f.prompt.contents[0].disposed,true);assert.equal(f.prompt.listeners.size,0);
});

for(const event of ['WINDOW_HIDDEN','WINDOW_DESTROYED'])test('actual prompt '+event+' cancels before clipboard access',async()=>{
 const f=fixture({realPrompt:{}}),r=f.call();await flush();f.prompt.emit(f.prompt.events[event]);
 assert.deepEqual(await r.result,{status:'cancelled'});f.prompt.contents[0].actions.click(true);await flush();
 assert.deepEqual(f.reads,[]);assert.equal(r.count(),1);assert.equal(f.prompt.closes.length,1);assert.equal(f.prompt.listeners.size,0);
});

test('actual Ability background retires the read and rejects late private text',async()=>{
 const reading=deferred(),f=fixture({realPrompt:{},read:()=>reading.promise}),r=f.call();await flush();
 f.prompt.contents[0].actions.click(true);assert.equal(f.reads.length,1);f.background(f.ability);
 assert.deepEqual(await r.result,{status:'cancelled'});reading.resolve('late-private-key');await flush();
 assert.equal(r.count(),1);assert(!JSON.stringify(f.replies).includes('late-private'));
 assert.deepEqual(await f.call('readText','b').result,{status:'unavailable'});assert.equal(f.prompt.opens.length,1);
});

test('an old Ability background cannot cancel another foreground owner',async()=>{
 const f=fixture({realPrompt:{}}),first=f.call();await flush();f.prompt.contents[0].actions.cancel();await first.result;await flush();
 const second=f.attach(),next=f.call('readText','b',second);await flush();f.background(f.ability);
 assert.equal(next.count(),0);assert.deepEqual(f.reads,[]);f.background(second.ability);
 assert.deepEqual(await next.result,{status:'cancelled'});await flush();assert.equal(f.prompt.listeners.size,0);
});

test('background before getLastWindow returns cannot open a retired dialog',async()=>{
 const windowReady=deferred(),f=fixture({realPrompt:{window:()=>windowReady.promise}}),r=f.call();await flush();
 f.background(f.ability);assert.deepEqual(await r.result,{status:'cancelled'});windowReady.resolve();await flush();
 assert.equal(f.prompt.opens.length,0);assert.equal(f.prompt.contents.length,0);assert.deepEqual(f.reads,[]);
 f.foreground(f.ability);const next=f.call('readText','b');await flush();assert.equal(f.prompt.opens.length,1);
 f.prompt.contents[0].actions.cancel();assert.deepEqual(await next.result,{status:'cancelled'});
});
