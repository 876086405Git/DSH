import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { performanceFixture } from './performance-fixture.mjs';
const consumer=[];
const fixture=(t,opt={})=>{const f=performanceFixture(opt);t.after(()=>f.dispose());return f;};
const snapshot=(f,p)=>f.invoke(p).value;
function sample(name,wire,light,tier){consumer.push({name,wire,light,tier});}
after(()=>{if(process.env.OHOS_PERFORMANCE_CASES)writeFileSync(process.env.OHOS_PERFORMANCE_CASES,JSON.stringify(consumer,null,2)+'\n');});

test('attach is inert; first snapshot reads public memory and one shared thermal registration only',t=>{
 const f=fixture(t),p=f.attach();assert.deepEqual(f.calls,[]);const value=snapshot(f,p);
 assert.equal(value.device.totalMemoryBytes,8*1024**3);assert.equal(value.device.tier,'medium');assert.equal(value.device.apiVersion,26);
 assert(!('sdkInt' in value.device));assert.equal(value.device.cpuCores,null);assert.equal(value.device.mediaPerformanceClass,null);
 snapshot(f,p);assert.equal(f.calls.filter(x=>x==='memory').length,1);assert.equal(f.calls.filter(x=>x==='register').length,1);
 sample('eight-gib-no-android-mpc',value,false,'medium');
});
test('actual KB conversion uses existing five GiB policy and never guesses high from API 26',t=>{
 const f=fixture(t,{memoryKb:4n*1024n*1024n}),p=f.attach(),value=snapshot(f,p);
 assert.equal(value.device.totalMemoryBytes,4*1024**3);assert.equal(value.device.tier,'low');sample('four-gib',value,true,'low');
 const f2=fixture(t,{memoryKb:5n*1024n*1024n}),p2=f2.attach();assert.equal(snapshot(f2,p2).device.tier,'medium');
});
test('unavailable, zero and unsafe memory values stay unknown without high/low claims',t=>{
 for(const opt of [{memoryError:true},{memoryKb:0n},{memoryKb:BigInt(Number.MAX_SAFE_INTEGER)}]){
  const f=fixture(t,opt),p=f.attach(),value=snapshot(f,p);assert.equal(value.device.totalMemoryBytes,null);assert.equal(value.device.tier,'medium');
  sample('unknown-memory-'+consumer.length,value,false,'medium');
 }
});
test('OH WARM through ESCAPE all force lightweight, preserving the seventh public level',t=>{
 const f=fixture(t),p=f.attach();snapshot(f,p);p.listen();
 for(let n=2;n<=7;n++){f.level(n);const value=p.events.at(-1);assert.equal(value.thermal.lightweight,true);assert.equal(value.thermal.status,n);}
 assert.equal(p.events.at(-1).thermal.level,'escape');sample('escape',p.events.at(-1),true,'medium');
});
test('cooling needs thirty active seconds and rechecks a fresh level at the deadline',t=>{
 const f=fixture(t,{level:3}),p=f.attach();snapshot(f,p);p.listen();f.level(0);assert.equal(f.timers.size,1);
 f.advance(29999);assert.equal(p.events.at(-1).thermal.lightweight,true);f.advance(1);
 assert.equal(p.events.at(-1).thermal.lightweight,false);assert.equal(f.timers.size,0);sample('cooled',p.events.at(-1),false,'medium');
});
test('repeated cool samples do not postpone the product recovery deadline',t=>{
 const f=fixture(t,{level:2}),p=f.attach();snapshot(f,p);p.listen();f.level(1);const since=p.events.at(-1).thermal.coolSinceUptimeMs;
 f.advance(15000);f.level(0);assert.equal(p.events.at(-1).thermal.coolSinceUptimeMs,since);f.advance(15000);
 assert.equal(p.events.at(-1).thermal.lightweight,false);
});
test('a hot level at recovery time prevents stale cool recovery without waiting for a callback',t=>{
 const f=fixture(t,{level:3}),p=f.attach();snapshot(f,p);p.listen();f.level(0);f.setLevel(7);f.advance(30000);
 assert.equal(p.events.at(-1).thermal.lightweight,true);assert.equal(p.events.at(-1).thermal.level,'escape');assert.equal(f.timers.size,0);
});
test('unknown or failed current level is not cooling evidence',t=>{
 const f=fixture(t,{level:3}),p=f.attach();snapshot(f,p);p.listen();f.level(0);f.setLevel(88);f.advance(30000);
 assert.equal(p.events.at(-1).thermal.status,null);assert.equal(p.events.at(-1).thermal.lightweight,true);assert.equal(f.timers.size,0);
 f.level(0);f.change({levelError:true});f.advance(30000);assert.equal(p.events.at(-1).thermal.lightweight,true);assert.equal(f.timers.size,0);
});
test('wall clock jumps and active-clock failures cannot prematurely cool',t=>{
 const f=fixture(t,{level:3}),p=f.attach();snapshot(f,p);p.listen();f.setWall(1);f.level(0);f.advance(10000);f.setWall(10**15);
 assert.equal(snapshot(f,p).thermal.lightweight,true);f.change({clockError:true});f.level(0);assert.equal(f.timers.size,0);
 f.change({clockError:false});f.level(0);f.advance(29999);assert.equal(snapshot(f,p).thermal.lightweight,true);f.advance(1);assert.equal(snapshot(f,p).thermal.lightweight,false);
});
test('pure policy restarts cooling after an unexpected backward active clock',t=>{
 const f=fixture(t),p=new f.Policy();p.update(3,1000);p.update(0,1000);p.update(0,900);
 assert.equal(p.coolSince,900);p.update(0,30899);assert.equal(p.lightweight,true);p.update(0,30900);assert.equal(p.lightweight,false);
});
test('two engines share one physical callback and old detach cannot remove the other observer',t=>{
 const f=fixture(t),a=f.attach(),b=f.attach();snapshot(f,a);snapshot(f,b);a.listen();b.listen();
 assert.equal(f.calls.filter(x=>x==='register').length,1);a.detach();assert.equal(f.calls.filter(x=>x==='unregister').length,0);
 f.level(3);assert.equal(b.events.at(-1).thermal.lightweight,true);b.detach();assert.equal(f.calls.filter(x=>x==='unregister').length,1);assert.equal(f.timers.size,0);
});
test('listen delivers the latest sequence after the method/listener handoff race',t=>{
 const f=fixture(t),p=f.attach(),initial=snapshot(f,p);f.level(3);p.listen();const latest=p.events.at(-1);
 assert(latest.sequence>initial.sequence);assert.equal(latest.thermal.lightweight,true);sample('handoff-hot',latest,true,'medium');
});
test('late old-engine detach, stream cancel and native callback do not affect reattached engine',t=>{
 const f=fixture(t),old=f.attach();snapshot(f,old);old.listen();const callback=f.callbacks[0];
 const next=f.attach(old.plugin);snapshot(f,next);next.listen();old.detach();old.cancel();const count=next.events.length;
 callback(7);assert.equal(next.events.length,count);f.level(2);assert.equal(next.events.at(-1).thermal.status,2);
});
test('failed registration and unsupported syscap report availability truthfully without invented thermal values',t=>{
 const f=fixture(t,{registerError:true,level:2}),p=f.attach(),value=snapshot(f,p);
 assert.equal(value.thermal.listening,false);assert.equal(value.thermal.listenerError,'register_failed');assert.equal(value.thermal.lightweight,true);
 const other=fixture(t,{missingCaps:['SystemCapability.PowerManager.ThermalManager','SystemCapability.HiviewDFX.HiProfiler.HiDebug']}),q=other.attach(),v=snapshot(other,q);
 assert.equal(v.thermal.supported,false);assert.equal(v.thermal.status,null);assert.equal(v.device.totalMemoryBytes,null);assert.equal(other.calls.length,0);
});
test('unregister rejection retains one reusable registration without retaining old engine observers',t=>{
 const f=fixture(t,{unregisterError:true}),a=f.attach();snapshot(f,a);a.listen();a.detach();const count=a.events.length;
 f.level(3);assert.equal(a.events.length,count);const b=f.attach();snapshot(f,b);b.listen();f.level(7);
 assert.equal(f.calls.filter(x=>x==='register').length,1);assert.equal(b.events.at(-1).thermal.status,7);f.change({unregisterError:false});b.detach();
});
test('thermal observation gap never counts as verified cool recovery',t=>{
 const f=fixture(t,{level:3}),a=f.attach();snapshot(f,a);a.listen();f.level(0);f.advance(10000);a.detach();assert.equal(f.timers.size,0);f.advance(60000);
 const b=f.attach(),value=snapshot(f,b);assert.equal(value.thermal.lightweight,true);b.listen();f.advance(30000);assert.equal(b.events.at(-1).thermal.lightweight,false);
});
test('setFrameCache reaches every view and only what is boolean counts',t=>{
 const f=fixture(t),p=f.attach(),a=f.addView('a'),b=f.addView('b');
 assert.deepEqual(f.invoke(p,'setFrameCache',{enabled:false}),{value:null});
 assert.deepEqual(a.frameCache,[false]);assert.deepEqual(b.frameCache,[false]);
 assert.deepEqual(f.invoke(p,'setFrameCache',{enabled:true}),{value:null});
 assert.deepEqual(a.frameCache,[false,true]);
 assert.equal(f.invoke(p,'setFrameCache',{enabled:'no'}).error,'bad_args');assert.equal(f.invoke(p,'setFrameCache').error,'bad_args');
 assert.deepEqual(a.frameCache,[false,true]);
});
test('a frame cache chosen before the window exists reaches the view created later',t=>{
 const f=fixture(t),p=f.attach();
 assert.deepEqual(f.invoke(p,'setFrameCache',{enabled:false}),{value:null});
 const late=f.addView('late');assert.deepEqual(late.frameCache,[]);
 f.Plugin.applyFrameCache();assert.deepEqual(late.frameCache,[false]);
});
test('with no choice made the views keep the engine default',t=>{
 const f=fixture(t),view=f.addView('a');f.attach();f.Plugin.applyFrameCache();assert.deepEqual(view.frameCache,[]);
});
test('a view that refuses is a channel error, not a crash; a retired binding is refused',t=>{
 const f=fixture(t,{viewError:true}),p=f.attach();f.addView('a');
 assert.equal(f.invoke(p,'setFrameCache',{enabled:false}).error,'frame_cache');
 f.change({viewError:false});const handler=p.methods.handler,replies=[];p.detach();
 handler.onMethodCall({method:'setFrameCache',argument:()=>false},{error:code=>replies.push(code)});assert.deepEqual(replies,['detached']);
});
const device=(t,opt)=>{const f=fixture(t,opt);return snapshot(f,f.attach()).device;};
test('at most two cores is low, as on Android, whatever the memory',t=>{
 const f=fixture(t,{cores:2,refreshRates:[60,120]}),value=snapshot(f,f.attach());
 assert.equal(value.device.tier,'low');assert.deepEqual([...value.device.reasons],['at_most_two_cores']);assert.equal(value.device.cpuCores,2);
 sample('two-cores',value,true,'low');
 assert.equal(device(t,{cores:1}).tier,'low');
 assert.deepEqual([...device(t,{cores:2,memoryKb:4n*1024n*1024n}).reasons],['memory_below_5_gib','at_most_two_cores']);
});
test('high takes the same memory and cores as Android, with the panel in place of its media class',t=>{
 const f=fixture(t,{cores:8,refreshRates:[60,90,120]}),value=snapshot(f,f.attach());
 assert.equal(value.device.tier,'high');assert.deepEqual([...value.device.reasons],['declared_refresh_with_capacity']);
 assert.deepEqual([...value.device.supportedRefreshRates],[60,90,120]);assert.equal(value.device.mediaPerformanceClass,null);
 sample('high',value,false,'high');
 assert.equal(device(t,{cores:4,refreshRates:[90]}).tier,'high');
 for(const opt of [{cores:8,refreshRates:[60]},{cores:8,refreshRates:[]},{cores:8},{cores:3,refreshRates:[120]},{refreshRates:[120]},
  {cores:8,refreshRates:[120],memoryError:true},{cores:8,displayError:true}]){
  const facts=device(t,opt);assert.equal(facts.tier,'medium',JSON.stringify(opt));assert.deepEqual([...facts.reasons],['no_low_tier_evidence']);
 }
 assert.equal(device(t,{cores:8,refreshRates:[120],memoryKb:4n*1024n*1024n}).tier,'low');
});
test('cpu counts come from the system\'s own sysconf names and anything odd stays unknown',t=>{
 const f=fixture(t,{cores:8,online:6,refreshRates:[120]}),value=snapshot(f,f.attach());
 assert.equal(value.device.cpuCores,8);assert.equal(value.device.availableProcessors,6);
 assert(f.reads.includes('sysconf 83'));assert(f.reads.includes('sysconf 84'));
 for(const cores of [0,-1,129,1.5,NaN]){const facts=device(t,{cores});assert.equal(facts.cpuCores,null,String(cores));assert.equal(facts.tier,'medium');}
 const failed=device(t,{sysconfError:true});assert.equal(failed.cpuCores,null);assert.equal(failed.availableProcessors,null);assert.equal(failed.tier,'medium');
});
test('refresh rates that are missing or not numbers count for nothing',t=>{
 const f=fixture(t,{cores:8,refreshRates:[0,-90,NaN]}),value=snapshot(f,f.attach());
 assert.deepEqual([...value.device.supportedRefreshRates],[]);assert.equal(value.device.tier,'medium');
 assert.deepEqual([...device(t,{cores:8,displayError:true}).supportedRefreshRates],[]);
 assert.deepEqual([...device(t,{cores:8}).supportedRefreshRates],[]);
});

