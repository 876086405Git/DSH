// Runs the production ETS control chain; SDK/Ability are explicit Linux doubles.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import vm from 'node:vm';
import test from 'node:test';
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
const source = new URL('../../../app/ohos/entry/src/main/ets/phone/PhoneEffects.ets', import.meta.url);
const compiled = ts.transpileModule(readFileSync(source, 'utf8'), { compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
} }).outputText;
const clone = x => JSON.parse(JSON.stringify(x));
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => { resolve=a; reject=b; }); return {promise,resolve,reject}; };
function fixture(hooks = {}) {
  const calls = [], payloads = [];
  const effect = async (name, value) => { calls.push(name); payloads.push(clone(value)); return await hooks.effect?.(name,value); };
  const context = {
    abilityInfo:{bundleName:'com.example.dsh'},
    openLink: link => { if (hooks.syncLinkError) throw new Error('sync SDK error'); return effect('link',link); }, startAbility: want => effect('app',want),
    startAbilityByType: (kind,params,cb) => effect('navigation',{kind,params}),
  };
  const api = {
    '@ohos.notificationManager': { default: {
      SlotType:{SERVICE_INFORMATION:2}, SlotLevel:{LEVEL_NONE:0}, ContentType:{NOTIFICATION_CONTENT_BASIC_TEXT:0},
      async isNotificationEnabled(){calls.push('permission');await hooks.permission?.();return hooks.enabled !== false;},
      async getSlot(){calls.push('slot');await hooks.slot?.();return hooks.disabledSlot ? {enabled:false} : null;},
      publish: request => effect('publish',request),
      openNotificationSettings: actual => {assert.equal(actual,context);return effect('notificationSettings',{});},
    }},
    '@ohos.settings':{default:Object.fromEntries(['MobileNetwork','Display','Sound','Nfc'].map(name=>['open'+name+'SettingsPage',actual=>{assert.equal(actual,context);if(hooks.settingsError)throw new Error('settings error');calls.push('settings:'+name);}] ))},
    '@ohos.pasteboard':{default:{createPlainTextData:text=>({text}),getSystemPasteboard:()=>({setData:data=>effect('clipboard',data)})}},
    '@ohos.telephony.call':{default:{makeCall:(actual,number)=>{assert.equal(actual,context);return effect('dial',number);}}},
    '@ohos.calendarManager':{default:{EventType:{NORMAL:0},getCalendarManager:actual=>{
      assert.equal(actual,context);return {editEvent:async event=>{await effect('calendar',event);return hooks.calendarResult ?? 7;}};
    }}},
    '../plugins/HmsKits':{async loadShareKit(){calls.push('kit');await hooks.kit?.();return {
      createData:record=>record,createController:data=>({show:(actual,options)=>{assert.equal(actual,context);return effect('share',{data,options});}}),single:1,preview:0,
    };}},
  };
  const module = {exports:{}};
  vm.runInNewContext(compiled,{module,exports:module.exports,require:name=>{
    // Calendars never reach the reminder module; its import only has to resolve.
    if(name==='./PhoneReminders') return {PhoneReminders:{},PhoneReminderDenied:class extends Error{},PhoneReminderRefused:class extends Error{}};
    assert(name in api, name);return api[name];
  }});
  const executor = new module.exports.PhoneEffects(context);
  let guards=0;
  const guard = () => {guards++;calls.push('guard');hooks.guard?.(module.exports.PhoneEffectDenied);};
  const run = (tool,args={}) => executor.execute('mcp__phone__'+tool,new Map(Object.entries(args)),guard);
  return {run,calls,payloads,get guards(){return guards;}};
}
test('451 date-only opens one all-day calendar date without an extra end day',async()=>{
 const f=fixture();const r=await f.run('intent',{kind:'calendar',title:'全天事项',begin:'2026-10-24',location:'真实地点',description:'真实备注'});
 assert.equal(r.effect,'opened_ui');assert.equal(r.evidence,'opened_ui');assert.equal(r.dispatched,true);
 assert.deepEqual(f.calls,['guard','calendar']);assert.equal(f.guards,1);
 const e=f.payloads[0];assert.equal(e.isAllDay,true);assert.equal(e.startTime,new Date(2026,9,24).getTime());
 assert.equal(e.endTime,new Date(2026,9,25).getTime()-1);assert.equal(Object.hasOwn(e,'timeZone'),false);
 assert.equal(e.title,'全天事项');assert.equal(e.description,'真实备注');assert.deepEqual(e.location,{location:'真实地点'});
});
test('451 explicit exclusive midnight end covers only preceding dates across month and year',async()=>{
 for(const [begin,end,y,m,d] of [['2026-10-30','2026-11-02',2026,10,2],['2026-12-31','2027-01-02',2027,0,2],['2028-02-28','2028-03-01',2028,2,1]]){
  const f=fixture();const r=await f.run('intent',{kind:'calendar',title:'跨天',begin,end});assert.equal(r.effect,'opened_ui');
  assert.equal(f.payloads[0].endTime,new Date(y,m,d).getTime()-1);assert.equal(f.payloads[0].isAllDay,true);
 }
});
test('451 explicit all_day false retains date-only midnight plus one timed hour',async()=>{
 const f=fixture();await f.run('intent',{kind:'calendar',title:'定时',begin:'2026-10-24',all_day:false});
 assert.equal(f.payloads[0].isAllDay,false);assert.equal(f.payloads[0].startTime,new Date(2026,9,24).getTime());assert.equal(f.payloads[0].endTime-f.payloads[0].startTime,3600000);
});
test('451 explicit offset is interpreted as an instant then phone-local calendar date',async()=>{
 const f=fixture();const r=await f.run('intent',{kind:'calendar',title:'时区',begin:'2026-10-24T23:30:00-05:00',end:'2026-10-26T00:00:00+08:00',all_day:true});
 assert.equal(r.effect,'opened_ui');const local=new Date(Date.parse('2026-10-24T23:30:00-05:00'));local.setHours(0,0,0,0);
 assert.equal(f.payloads[0].startTime,local.getTime());assert.equal(f.payloads[0].endTime,Date.parse('2026-10-26T00:00:00+08:00')-1);
});
test('451 default all-day end uses the next civil day through both DST transitions',async()=>{
 // Runner supplies America/New_York; Date itself is real, never replaced by a mock.
 assert.equal(process.env.TZ,'America/New_York');
 for(const [begin,y,m,d,hours] of [['2026-03-08',2026,2,8,23],['2026-11-01',2026,10,1,25]]){
  const f=fixture();const r=await f.run('intent',{kind:'calendar',title:'DST',begin});assert.equal(r.effect,'opened_ui');
  const e=f.payloads[0];assert.equal(e.startTime,new Date(y,m,d).getTime());assert.equal(e.endTime,new Date(y,m,d+1).getTime()-1);
  assert.equal(e.endTime+1-e.startTime,hours*3600000);
 }
});
test('451 invalid date and empty or reversed all-day ranges never consume permit',async()=>{
 for(const args of [{begin:'2026-02-30'},{begin:'2026-13-01'},{begin:'2026-10-24',end:'2026-10-24'},{begin:'2026-10-24',end:'2026-10-23'}]){
  const f=fixture();const r=await f.run('intent',{kind:'calendar',title:'invalid',...args});assert.equal(r.code,'invalid_arguments');assert.equal(r.dispatched,false);assert.equal(f.guards,0);assert.deepEqual(f.calls,[]);
 }
});
test('451 all-day cancellation and SDK failure retain the existing effect evidence boundary',async()=>{
 const c=fixture({calendarResult:-1});assert.equal((await c.run('intent',{kind:'calendar',title:'x',begin:'2026-10-24'})).status,'cancelled');
 const u=fixture({calendarResult:0});assert.equal((await u.run('intent',{kind:'calendar',title:'x',begin:'2026-10-24'})).status,'unknown');
 const x=fixture({effect:()=>{throw new Error('SDK details');}});const r=await x.run('intent',{kind:'calendar',title:'x',begin:'2026-10-24'});assert.equal(r.status,'unknown');assert.equal(r.dispatched,true);assert(!r.message.includes('SDK details'));
});
test('451 all-day request still honors the immediate native permit',async()=>{
 const f=fixture({guard:E=>{throw new E('cancelled','取消');}});const r=await f.run('intent',{kind:'calendar',title:'x',begin:'2026-10-24'});assert.equal(r.status,'cancelled');assert.equal(r.dispatched,false);assert.equal(f.guards,1);assert.deepEqual(f.calls,['guard']);
});
