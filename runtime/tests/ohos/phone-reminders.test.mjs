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
test('public alarm schedules a real SDK request instead of claiming an opened UI',async()=>{
 const f=fixture();const r=await f.run('intent',{kind:'alarm',hour:8,minute:15,days:[7,1,1],message:'exact label'});
 assert.equal(r.status,'succeeded');assert.equal(r.effect,'reminder_scheduled');assert.equal(r.evidence,'unknown');assert.equal(r.dispatched,true);
 assert.deepEqual(f.calls,['reminderPermission','permission','slot','listReminders','guard','reminder']);assert.equal(f.guards,1);
 const q=f.payloads[0];assert.equal(q.reminderType,2);assert.equal(q.hour,8);assert.equal(q.minute,15);assert.deepEqual(q.daysOfWeek,[1,7]);assert.equal(q.content,'exact label');assert(Number.isInteger(q.notificationId));assert.equal(q.slotType,2);assert.deepEqual(q.actionButton,[{title:'Localized close',type:0}]);
 assert.equal(Object.hasOwn(q,'maxScreenWantAgent'),false);assert.equal(Object.hasOwn(q,'wantAgent'),false);
});
test('omitted alarm minute preserves Android default of zero',async()=>{
 const f=fixture();const r=await f.run('intent',{kind:'alarm',hour:8});assert.equal(r.effect,'reminder_scheduled');assert.equal(f.payloads[0].minute,0);assert.deepEqual(f.payloads[0].daysOfWeek,[]);
});
test('timer seconds and empty label are preserved without an engine wake claim',async()=>{
 const f=fixture();const r=await f.run('intent',{kind:'timer',seconds:86400,message:''});
 assert.equal(r.effect,'reminder_scheduled');assert.equal(f.payloads[0].triggerTimeInSeconds,86400);assert.equal(f.payloads[0].content,'');assert.equal(f.payloads[0].reminderType,0);
 assert.match(r.message,/不代表引擎任务会自动运行/);assert(!f.calls.includes('app'));
});
test('unsupported capability and denied permission or slot dispatch nothing',async()=>{
 for(const hooks of [{supported:false},{grant:false},{enabled:false},{disabledSlot:true}]){
  const f=fixture(hooks);const r=await f.run('intent',{kind:'timer',seconds:10});assert.equal(r.status,'failed');assert.equal(r.dispatched,false);assert.equal(f.guards,0);assert(!f.calls.includes('reminder'));
  assert.equal(r.code,hooks.supported===false?'unsupported':'permission_denied');
 }
});
test('original permit is rechecked after asynchronous reminder preparation',async()=>{
 const wait=deferred(),started=deferred();let cancelled=false;
 const f=fixture({list:()=>{started.resolve();return wait.promise;},guard:E=>{if(cancelled)throw new E('cancelled','取消');}});
 const pending=f.run('intent',{kind:'timer',seconds:10});await started.promise;assert.equal(f.guards,0);cancelled=true;wait.resolve();
 const r=await pending;assert.equal(r.status,'cancelled');assert.equal(r.dispatched,false);assert.equal(f.guards,1);assert(!f.calls.includes('reminder'));
});
test('invalid alarm and timer arguments never request a native permit',async()=>{
 for(const args of [{kind:'alarm',hour:24,minute:0},{kind:'alarm',hour:8,minute:60},{kind:'alarm',hour:8,minute:0,days:[0]},{kind:'timer',seconds:0},{kind:'timer',seconds:86401},{kind:'timer',seconds:1.5}]){
  const f=fixture();const r=await f.run('intent',args);assert.equal(r.code,'invalid_arguments');assert.equal(r.dispatched,false);assert.equal(f.guards,0);assert.deepEqual(f.calls,[]);
 }
});
test('occupied reminder notification IDs and concurrent publications do not overwrite',async()=>{
 const gate=deferred(),started=deferred();let publishes=0;
 const f=fixture({existing:[{reminderId:4,reminderReq:{notificationId:1500000000}}],effect:async name=>{if(name==='reminder'&&++publishes===1){started.resolve();await gate.promise;}}});
 const a=f.run('intent',{kind:'timer',seconds:5});await started.promise;const second=f.run('intent',{kind:'alarm',hour:9,minute:0});await Promise.resolve();assert.equal(publishes,1);
 gate.resolve();assert.equal((await a).effect,'reminder_scheduled');assert.equal((await second).effect,'reminder_scheduled');assert.equal(f.payloads.length,2);
 assert.notEqual(f.payloads[0].notificationId,1500000000);assert.notEqual(f.payloads[0].notificationId,f.payloads[1].notificationId);
});
test('publish rejection stays unknown and is never retried or cancelled implicitly',async()=>{
 let count=0;const f=fixture({effect:()=>{count++;throw new Error('private SDK failure');}});
 const r=await f.run('intent',{kind:'timer',seconds:10});assert.equal(r.status,'unknown');assert.equal(r.dispatched,true);assert.equal(r.effect,'none');assert.equal(count,1);assert(!r.message.includes('private'));
});
test('the service refusing a reminder says so: nothing scheduled, not an unknown outcome',async()=>{
 for(const code of [201,1700001,1700002]){
  let count=0;const f=fixture({effect:()=>{count++;throw Object.assign(new Error('refused'),{code});}});
  const r=await f.run('intent',{kind:'timer',seconds:10});
  assert.equal(r.status,'failed');assert.equal(r.code,'reminder_refused');assert.equal(r.dispatched,true);assert.equal(r.effect,'none');assert.equal(count,1);
 }
});
test('a rejected publication releases serialization for the next explicit request',async()=>{
 let count=0;const f=fixture({effect:()=>{if(++count===1)throw new Error('SDK');}});
 assert.equal((await f.run('intent',{kind:'timer',seconds:10})).status,'unknown');assert.equal((await f.run('intent',{kind:'timer',seconds:20})).effect,'reminder_scheduled');assert.equal(count,2);
});
