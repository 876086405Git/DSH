import fs from 'node:fs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { keyboardFixture, info } from './keyboard-geometry-fixture.mjs';

test('the actual diagnostics plugin provides collectSystemIme and cancelSystemIme for own-window geometry', async () => {
  const f=keyboardFixture();
  const result=await f.invoke('collectSystemIme');
  assert.equal(result.missing,undefined,'OH_KEYBOARD_COLLECTION_MISSING');
  assert.equal(result.value.source,'ohosWindowGeometry');
  assert.equal(result.value.code,'unavailable');
  assert.deepEqual(await f.invoke('cancelSystemIme'),{value:null});
});

function active(options) { const f=keyboardFixture(options);const w=f.window();f.log.setForeground(true);f.log.attach(w.stage);return {...f,w}; }
const area=()=>({leftRect:{left:0,top:0,width:0,height:0},topRect:{left:0,top:0,width:0,height:0},rightRect:{left:0,top:0,width:0,height:0},bottomRect:{left:0,top:1500,width:1080,height:900}});

test('fixed own-window geometry crosses the actual plugin codec boundary without unrelated IO',async()=>{
 const f=active();f.w.listeners.get('keyboardWillShow')(info());f.w.listeners.get('keyboardHeightChange')(900);f.w.listeners.get('avoidAreaChange')({type:3,area:area()});
 const {value}=await f.invoke('collectSystemIme',{maxEvents:100000,includeContent:true});
 assert.equal(value.source,'ohosWindowGeometry');assert.equal(value.code,'ok');assert.equal(value.capturedAt,f.now());assert.equal(value.events.length,3);
 assert.deepEqual(value.events[0],{timestamp:f.now(),event:'willShow',origin:'ohosWindow',fromUser:null,reason:'unknown',geometry:{begin:[0,2400,1080,0],end:[0,1500,1080,900],animated:true,curve:2,durationMs:250,curveParams:[0.2,0,0.2,1]}});
 if(process.env.OHOS_KEYBOARD_CONSUMER_INPUT)fs.writeFileSync(process.env.OHOS_KEYBOARD_CONSUMER_INPUT,JSON.stringify({now:f.now(),reply:value}));
 assert.deepEqual(value.events[1].geometry,{height:900});assert.deepEqual(value.events[2].geometry.bottom,[0,1500,1080,900]);
});

test('unknown fields and mutated SDK buffers cannot leak through exported geometry or hilog',async()=>{
 const f=active(),raw=info();raw.text='SECRET';raw.beginRect.private='SECRET';raw.config.extra='SECRET';
 f.w.listeners.get('keyboardDidShow')(raw);raw.endRect.height=1;raw.config.param[0]=99;
 const first=(await f.invoke('collectSystemIme')).value;assert(!JSON.stringify([first,f.lines]).includes('SECRET'));assert.equal(first.events[0].geometry.end[3],900);assert.equal(first.events[0].geometry.curveParams[0],0.2);
 first.events[0].geometry.end[3]=7;const next=(await f.invoke('collectSystemIme')).value;assert.equal(next.events[0].geometry.end[3],900);
});

test('ring retains the most recent 64 callback arrivals with stable ties',async()=>{
 const f=active();for(let i=0;i<100;i++)f.w.listeners.get('keyboardHeightChange')(i);
 const rows=(await f.invoke('collectSystemIme')).value.events;assert.equal(rows.length,64);assert.deepEqual(rows.map(x=>x.geometry.height),Array.from({length:64},(_,i)=>i+36));
});

test('120-second interval is inclusive and wall-clock rollback discards future timestamps',async()=>{
 const f=active();f.w.listeners.get('keyboardHeightChange')(1);f.advance(120000);assert.equal((await f.invoke('collectSystemIme')).value.events.length,1);
 f.advance(1);assert.equal((await f.invoke('collectSystemIme')).value.code,'noEvents');f.w.listeners.get('keyboardHeightChange')(2);f.advance(-1);assert.equal((await f.invoke('collectSystemIme')).value.code,'noEvents');
});

test('background clears records and declines export; foreground begins a fresh ring',async()=>{
 const f=active();f.w.listeners.get('keyboardHeightChange')(3);f.log.setForeground(false);f.w.listeners.get('keyboardHeightChange')(4);
 assert.equal((await f.invoke('collectSystemIme')).value.code,'cancelled');f.log.setForeground(true);assert.equal((await f.invoke('collectSystemIme')).value.code,'noEvents');
 f.w.listeners.get('keyboardHeightChange')(5);assert.equal((await f.invoke('collectSystemIme')).value.events[0].geometry.height,5);
});

test('late callbacks after detach cannot survive a reattach of the same window',async()=>{
 const f=active({refuseOff:true});const stale=f.w.listeners.get('keyboardWillShow');f.log.attach(f.w.stage);stale(info());
 assert.equal((await f.invoke('collectSystemIme')).value.code,'noEvents');f.w.listeners.get('keyboardWillShow')(info());assert.equal((await f.invoke('collectSystemIme')).value.events.length,1);
 f.log.detach();stale(info());assert.equal((await f.invoke('collectSystemIme')).value.code,'unavailable');
});

test('partial unsupported APIs preserve remaining callbacks; all unsupported is explicit',async()=>{
 const partial=active({refuse:['keyboardWillShow']});partial.w.listeners.get('keyboardHeightChange')(7);assert.equal((await partial.invoke('collectSystemIme')).value.code,'ok');
 const all=active({refuse:['keyboardWillShow','keyboardWillHide','keyboardDidShow','keyboardDidHide','keyboardHeightChange','avoidAreaChange']});assert.equal((await all.invoke('collectSystemIme')).value.code,'unsupported');
});

const registrationEvents=['keyboardWillShow','keyboardWillHide','keyboardDidShow','keyboardDidHide','keyboardHeightChange','avoidAreaChange'];
for(const [name,error] of [
 ['window state',Object.assign(Error('Window state abnormal'),{code:1300002})],
 ['unknown code',Object.assign(Error('Unexpected registration failure'),{code:999})],
 ['message-only 801',Error('801')],
]) {
 test('registration failure '+name+' is unavailable rather than unsupported',async()=>{
  const f=active({failures:new Map(registrationEvents.map(event=>[event,error]))});
  const reply=(await f.invoke('collectSystemIme')).value;
  assert.equal(reply.source,'ohosWindowGeometry');assert.equal(reply.code,'unavailable');assert.equal(reply.ok,false);assert.deepEqual(reply.events,[]);
 });
}

test('mixed registration errors remain unavailable and reattach clears old failure state',async()=>{
 const failures=new Map(registrationEvents.map(event=>[event,Object.assign(Error('Unsupported'),{code:801})]));
 failures.set('keyboardWillShow',Object.assign(Error('Window state abnormal'),{code:1300002}));
 const f=active({failures,refuseOff:true});assert.equal((await f.invoke('collectSystemIme')).value.code,'unavailable');
 failures.set('keyboardWillShow',Object.assign(Error('Unsupported'),{code:801}));f.log.attach(f.w.stage);
 assert.equal((await f.invoke('collectSystemIme')).value.code,'unsupported');
 failures.clear();f.log.attach(f.w.stage);assert.equal((await f.invoke('collectSystemIme')).value.code,'noEvents');
});

test('partial registration failure preserves successfully registered geometry callbacks',async()=>{
 const f=active({failures:new Map([['keyboardWillShow',Object.assign(Error('Window state abnormal'),{code:1300002})]])});
 f.w.listeners.get('keyboardHeightChange')(42);const reply=(await f.invoke('collectSystemIme')).value;
 assert.equal(reply.code,'ok');assert.equal(reply.events[0].geometry.height,42);
});

test('ability or old engine may not export; immediate cancel does not mutate retained evidence',async()=>{
 const f=active();f.w.listeners.get('keyboardHeightChange')(9);assert.deepEqual(await f.invoke('cancelSystemIme'),{value:null});assert.equal((await f.invoke('collectSystemIme')).value.events.length,1);
 f.plugin.onDetachedFromAbility();assert.equal((await f.invoke('collectSystemIme')).value.code,'unavailable');f.plugin.onAttachedToAbility(f.ability);
 const handler=f.channel.handler;f.plugin.onDetachedFromEngine(f.binding);const reply=await new Promise(resolve=>handler.onMethodCall({method:'collectSystemIme'},{success:value=>resolve({value}),error:error=>resolve({error})}));assert.equal(reply.error,'detached');
});

test('only keyboard avoid area and finite nonnegative dimensions are retained',async()=>{
 const f=active();f.w.listeners.get('avoidAreaChange')({type:0,area:area()});for(const height of [NaN,Infinity,-1])f.w.listeners.get('keyboardHeightChange')(height);
 const malformed=info();malformed.endRect.width=-1;f.w.listeners.get('keyboardDidShow')(malformed);assert.equal((await f.invoke('collectSystemIme')).value.code,'noEvents');
 f.w.listeners.get('keyboardHeightChange')(0);const raw=info();raw.beginRect.left=-20;delete raw.animated;delete raw.config;f.w.listeners.get('keyboardDidHide')(raw);
 const rows=(await f.invoke('collectSystemIme')).value.events;assert.equal(rows.length,2);assert.equal(rows[0].geometry.height,0);assert.equal(rows[1].geometry.begin[0],-20);assert.deepEqual(Object.keys(rows[1].geometry),['begin','end']);
});


test('real EntryAbility injects its own window and forwards foreground/background/destroy',async()=>{
 const f=keyboardFixture(),entry=f.entry(),w=f.window();entry.instance.onWindowStageCreate(w.stage);
 assert.equal((await entry.invoke('collectSystemIme')).value.code,'cancelled');entry.instance.onForeground();
 w.listeners.get('keyboardHeightChange')(333);assert.equal((await entry.invoke('collectSystemIme')).value.events[0].geometry.height,333);
 entry.instance.onBackground();assert.equal((await entry.invoke('collectSystemIme')).value.code,'cancelled');entry.instance.onForeground();assert.equal((await entry.invoke('collectSystemIme')).value.code,'noEvents');
 entry.instance.onWindowStageDestroy();assert.equal((await entry.invoke('collectSystemIme')).value.code,'unavailable');entry.instance.onDestroy();assert.equal(w.listeners.size,0);
});
