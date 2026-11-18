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
    abilityInfo:{bundleName:'com.example.dsh'},applicationInfo:{accessTokenId:123},
    resourceManager:{async getStringByName(name){assert.equal(name,'phone_reminder_close');return 'Localized close';}},
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
    '@ohos.abilityAccessCtrl': {default:{GrantStatus:{PERMISSION_GRANTED:0},createAtManager:()=>({
      async checkAccessToken(token,permission){assert.equal(token,123);assert.equal(permission,'ohos.permission.PUBLISH_AGENT_REMINDER');calls.push('reminderPermission');await hooks.reminderPermission?.();return hooks.grant === false ? -1 : 0;}
    })}},
    '@ohos.reminderAgentManager': {default:{ReminderType:{REMINDER_TYPE_ALARM:2,REMINDER_TYPE_TIMER:0},ActionButtonType:{ACTION_BUTTON_TYPE_CLOSE:0},
      async getAllValidReminders(){calls.push('listReminders');await hooks.list?.();return hooks.existing ?? [];},
      async publishReminder(request){await effect('reminder',request);return hooks.reminderId ?? 0;}
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
  let reminderModule;
  const requireApi = name => {
    if(name === './PhoneReminders') {
      if(!reminderModule) {
        reminderModule={exports:{}};
        const js=ts.transpileModule(readFileSync(new URL('PhoneReminders.ets',source),'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
        vm.runInNewContext(js,{module:reminderModule,exports:reminderModule.exports,require:requireApi,canIUse:cap=>{assert.equal(cap,'SystemCapability.Notification.ReminderAgent');return hooks.supported !== false;}});
      }
      return reminderModule.exports;
    }
    assert(name in api,name);return api[name];
  };
  const module = {exports:{}};
  vm.runInNewContext(compiled,{module,exports:module.exports,require:requireApi});
  const executor = new module.exports.PhoneEffects(context);
  let guards=0;
  const guard = () => {guards++;calls.push('guard');hooks.guard?.(module.exports.PhoneEffectDenied);};
  const run = (tool,args={}) => executor.execute('mcp__phone__'+tool,new Map(Object.entries(args)),guard);
  return {run,calls,payloads,get guards(){return guards;}};
}
test('permission await then revoked permit never publishes',async()=>{
  const wait=deferred();let cancelled=false;
  const f=fixture({permission:()=>wait.promise,guard:E=>{if(cancelled)throw new E('cancelled','已取消');}});
  const work=f.run('notify',{title:'真实标题',text:'真实正文'});assert.deepEqual(f.calls,['permission']);
  cancelled=true;wait.resolve();const r=await work;
  assert.equal(r.status,'cancelled');assert.equal(r.dispatched,false);assert(!f.calls.includes('publish'));assert.equal(f.guards,1);
});
test('slot await also precedes permit; real content survives publication',async()=>{
  const wait=deferred();const f=fixture({slot:()=>wait.promise});
  const work=f.run('notify',{title:'private-title',text:'完整正文'});await Promise.resolve();await Promise.resolve();
  assert.equal(f.guards,0);wait.resolve();const r=await work;
  assert.equal(r.effect,'notification_published');assert.equal(r.evidence,'unknown');
  assert.deepEqual(f.calls,['permission','slot','guard','publish']);
  assert.equal(f.payloads[0].content.normal.title,'private-title');assert.equal(f.payloads[0].content.normal.text,'完整正文');
});
test('disabled permission or slot never consumes permit or publishes',async()=>{
  for(const hooks of [{enabled:false},{disabledSlot:true}]){const f=fixture(hooks);const r=await f.run('notify',{title:'x',text:'y'});assert.equal(r.status,'failed');assert.equal(r.dispatched,false);assert.equal(f.guards,0);}
});
test('late ShareKit preparation cannot cross revoked permit',async()=>{
  const wait=deferred();const f=fixture({kit:()=>wait.promise,guard:E=>{throw new E('deadline_expired','超时');}});
  const work=f.run('intent',{kind:'share',text:'消息'});assert.deepEqual(f.calls,['kit']);wait.resolve();const r=await work;
  assert.equal(r.status,'timed_out');assert.equal(r.dispatched,false);assert.deepEqual(f.calls,['kit','guard']);
});
test('open package delegates HOME resolution; never guesses an ability',async()=>{
  const f=fixture();const r=await f.run('open',{app:' com.example.app '});assert.equal(r.effect,'opened_ui');
  assert.deepEqual(f.payloads[0],{bundleName:'com.example.app',action:'ohos.want.action.home',entities:['entity.system.home']});
  assert.deepEqual(f.calls,['guard','app']);
});
test('open links preserve target; invalid combinations and unsupported background/name dispatch nothing',async()=>{
  const f=fixture();assert.equal((await f.run('open',{url:' https://example.org/a?b=1 '})).status,'succeeded');assert.equal(f.payloads[0],'https://example.org/a?b=1');
  for(const args of [{app:'名称'},{app:'a.b',url:'https://x'},{url:'https://x',background:true},{}]){const z=fixture();assert.notEqual((await z.run('open',args)).status,'succeeded');assert.equal(z.guards,0);}
});
test('clipboard writes empty content, never reads',async()=>{
  const f=fixture();const r=await f.run('clipboard',{set:''});assert.equal(r.effect,'clipboard_written');assert.deepEqual(f.payloads,[{text:''}]);assert.deepEqual(f.calls,['guard','clipboard']);
  for(const args of [{get:true},{set:'x',get:true},{}]){const z=fixture();assert.equal((await z.run('clipboard',args)).dispatched,false);assert.equal(z.guards,0);}
});
test('dial opens dialer, share opens panel with exact text',async()=>{
  const f=fixture();assert.equal((await f.run('intent',{kind:'dial',number:'+1 234-567'})).effect,'opened_ui');assert.equal(f.payloads[0],'+1234-567');
  const s=fixture();assert.equal((await s.run('intent',{kind:'share',text:'exact text'})).evidence,'opened_ui');assert.equal(s.payloads[0].data.content,'exact text');assert.deepEqual(s.calls,['kit','guard','share']);
  const bad=fixture();assert.equal((await bad.run('intent',{kind:'dial',number:'*123#'})).dispatched,false);
});
test('SDK rejection after guard is uncertain and not claimed un-dispatched',async()=>{
  for(const [tool,args] of [['open',{url:'https://x'}],['notify',{title:'x',text:'y'}],['clipboard',{set:'x'}],['intent',{kind:'dial',number:'123'}],['intent',{kind:'share',text:'x'}]]){
    const f=fixture({effect:()=>{throw new Error('sensitive SDK details');}});const r=await f.run(tool,args);
    assert.equal(r.status,'unknown');assert.equal(r.dispatched,true);assert.equal(r.effect,'none');assert.equal(r.evidence,'unknown');assert(!r.message.includes('sensitive'));assert.equal(f.guards,1);
  }
});
test('unsupported transactions and targets do not silently substitute another action',async()=>{
  for(const args of [{kind:'sms_draft',text:'x'},{kind:'settings',page:'wifi'},{kind:'share',text:'x',app:'com.example'},{kind:'navigate',destination:'北京'},{kind:'navigate',lat:1,lng:2,map:'amap'}]){
    const f=fixture();const r=await f.run('intent',args);assert.equal(r.code,'unsupported');assert.equal(r.dispatched,false);assert.equal(f.guards,0);
  }
  const f=fixture();assert.equal((await f.run('handoff',{reason:'登录'})).dispatched,false);assert.equal(f.guards,0);
});
test('coordinate navigation preserves all four travel modes and GCJ-02 values',async()=>{
  for(const [mode,vehicleType] of [['drive',0],['walk',1],['ride',2],['transit',3]]){
    const f=fixture();const r=await f.run('intent',{kind:'navigate',lat:31.2,lng:121.5,destination:'目的地',mode});
    assert.equal(r.effect,'opened_ui');assert.deepEqual(f.payloads[0],{kind:'navigation',params:{sceneType:1,destinationLatitude:31.2,destinationLongitude:121.5,destinationName:'目的地',vehicleType}});assert.deepEqual(f.calls,['guard','navigation']);
  }
});
test('calendar dates validate before dispatch and only claim opened UI',async()=>{
  const f=fixture();const r=await f.run('intent',{kind:'calendar',title:'事件',begin:'2026-10-24T19:00:00+08:00',location:'地点',description:'备注'});
  assert.equal(r.evidence,'opened_ui');assert.equal(f.payloads[0].startTime,Date.parse('2026-10-24T19:00:00+08:00'));assert.equal(f.payloads[0].endTime-f.payloads[0].startTime,3600000);assert.deepEqual(f.payloads[0].location,{location:'地点'});assert.equal(f.payloads[0].description,'备注');
  for(const begin of ['2026-02-30T12:00','2026-13-01','2026-01-01T25:00','not-a-date']){const z=fixture();assert.equal((await z.run('intent',{kind:'calendar',title:'x',begin})).dispatched,false);assert.equal(z.guards,0);}
  const c=fixture({calendarResult:-1});assert.equal((await c.run('intent',{kind:'calendar',title:'x',begin:'2026-10-24T19:00'})).status,'cancelled');
});

test('content whitespace is retained; preparatory and synchronous SDK errors preserve dispatch boundary',async()=>{
  const f=fixture();await f.run('notify',{title:' 标题 ',text:'\n正文\n'});assert.equal(f.payloads[0].content.normal.title,' 标题 ');assert.equal(f.payloads[0].content.normal.text,'\n正文\n');
  const s=fixture();await s.run('intent',{kind:'share',text:' text '});assert.equal(s.payloads[0].data.content,' text ');
  const bad=fixture({permission:()=>{throw new Error('preparation');}});const r=await bad.run('notify',{title:'x',text:'y'});assert.equal(r.dispatched,false);assert.equal(bad.guards,0);
});
test('calendar local timezone and all-day mapping are explicit',async()=>{
  const f=fixture();await f.run('intent',{kind:'calendar',title:'x',begin:'2026-10-24 19:00'});assert.equal(f.payloads[0].startTime,new Date(2026,9,24,19,0).getTime());
  for(const args of [{begin:'2026-10-24'},{begin:'2026-10-24T19:00',all_day:true}]){const z=fixture();const r=await z.run('intent',{kind:'calendar',title:'x',...args});assert.equal(r.effect,'opened_ui');assert.equal(z.payloads[0].isAllDay,true);assert.equal(z.guards,1);}
});

test('synchronous SDK throw follows the same consumed boundary',async()=>{
  const f=fixture({syncLinkError:true});const r=await f.run('open',{url:'https://example.org'});
  assert.equal(r.dispatched,true);assert.equal(r.status,'unknown');assert.deepEqual(f.calls,['guard']);
});
test('all immediate SDK effects honor refusal without a native call',async()=>{
  for(const [tool,args] of [['open',{url:'https://x'}],['open',{app:'com.example'}],['clipboard',{set:'x'}],['intent',{kind:'dial',number:'123'}],['intent',{kind:'calendar',title:'x',begin:'2026-10-24T19:00'}],['intent',{kind:'navigate',lat:1,lng:2}]]){
    const f=fixture({guard:E=>{throw new E('cancelled','已取消');}});const r=await f.run(tool,args);
    assert.equal(r.status,'cancelled');assert.equal(r.dispatched,false);assert.equal(f.guards,1);assert.deepEqual(f.calls,['guard']);
  }
});

test('public settings pages map exactly, guard immediately before synchronous call',async()=>{
  for(const [page,sdk] of [['mobile_network','MobileNetwork'],['display','Display'],['sound','Sound'],['nfc','Nfc']]){
    const f=fixture();const r=await f.run('intent',{kind:'settings',page});assert.equal(r.status,'succeeded');assert.equal(r.effect,'opened_ui');assert.deepEqual(f.calls,['guard','settings:'+sdk]);
    const denied=fixture({guard:E=>{throw new E('cancelled','取消');}});assert.equal((await denied.run('intent',{kind:'settings',page})).dispatched,false);assert.deepEqual(denied.calls,['guard']);
    const failed=fixture({settingsError:true});assert.equal((await failed.run('intent',{kind:'settings',page})).status,'unknown');
  }
});
test('notification settings only accepts exact own bundle and does not redirect other apps',async()=>{
  const f=fixture();const r=await f.run('intent',{kind:'settings',page:'app_notifications',app:'com.example.dsh'});assert.equal(r.effect,'opened_ui');assert.deepEqual(f.calls,['guard','notificationSettings']);
  for(const app of ['other.app','显示名称']){const z=fixture();assert.equal((await z.run('intent',{kind:'settings',page:'app_notifications',app})).code,'unsupported');assert.equal(z.guards,0);}
});

test('notification request uses current manager content discriminator',async()=>{
 const f=fixture();await f.run('notify',{title:'title',text:'body'});
 assert.equal(f.payloads[0].content.notificationContentType,0);
 assert.equal(Object.hasOwn(f.payloads[0].content,'contentType'),false);
});
