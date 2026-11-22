// Independent fixed-source probe: execute extracted upstream functions only.
import fs from 'node:fs';
import vm from 'node:vm';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
const [sourcePath, destination] = process.argv.slice(2);
assert.ok(sourcePath && destination, 'Expected fixed inject.js and output JSON paths');
const bytes = fs.readFileSync(sourcePath);
assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),
  '4858bcb57530e3ff6ef68f0c94a4d291e2914c766c274f888e9a2fdf8d0efb59',
  'Source must be the original pinned SPreset bytes');
const source = bytes.toString('utf8');
function declaration(name, next) {
  const start = source.indexOf(`  function ${name}(`);
  const end = source.indexOf(`\n  function ${next}(`, start);
  if (start < 0 || end < 0) throw new Error(`Missing ${name}`);
  return source.slice(start, end);
}
const postStart = source.indexOf('  function postProcess(prompt) {');
const postEnd = source.indexOf('\n\n  return loadSettingsToForm;', postStart);
const stopStart = source.indexOf('  ctx.eventSource.on(ctx.eventTypes.CHAT_COMPLETION_SETTINGS_READY, data => {\n    if (SPresetSettings.ChatSquash.enable_stop_string');
const stopEnd = source.indexOf('\n\n  // 在生成前同步工具注册', stopStart);
if ([postStart,postEnd,stopStart,stopEnd].some(x => x < 0)) throw new Error('Missing source boundary');
let stop;
let diagnostics = [];
const context = vm.createContext({
  SPresetSettings: { ChatSquash: {} },
  ctx: { substituteParams: x => x, eventTypes: { CHAT_COMPLETION_SETTINGS_READY: 'settings' },
    eventSource: { on(_name,fn) { stop=fn; } } },
  createSPresetScriptConsole: () => ({warn(){},debug(){}}),
  wrapSPresetScriptFunction: fn => fn,
  recordSPresetScriptDiagnostic: (...args) => diagnostics.push(args[1]),
  cloneSPresetData: structuredClone,
});
vm.runInContext([
  declaration('runPostScript','postProcessOriginalMessages'),
  declaration('postProcessOriginalMessages','squashPrompts'),
  declaration('squashPrompts','restoreAttachments'),
  declaration('restoreAttachments','postProcess'),
  source.slice(postStart,postEnd),
  source.slice(stopStart,stopEnd),
].join('\n'),context);
const defaults = { enabled:true, parse_clewd:false, role:'assistant',
  user_prefix:'U:',user_suffix:'',char_prefix:'A:',char_suffix:'',prefix_system:'S:',suffix_system:'',
  squashed_post_script_enable:true, re_split:false };
function describe(value) {
  if (value === undefined) return {kind:'undefined'};
  if (value === null) return {kind:'null'};
  if (typeof value?.then === 'function') return {kind:'Promise',json:JSON.stringify(value)};
  return {kind:Array.isArray(value)?'array':typeof value,value};
}
const returned = [
 ['string','() => "U:NEW"'], ['undefined','() => undefined'], ['null','() => null'],
 ['false','() => false'], ['zero','() => 0'], ['number','() => 3'],
 ['object','() => ({x:1})'], ['emptyArray','() => []'], ['array','() => ["A"]'],
 ['Promise','() => Promise.resolve("U:ASYNC")'],
];
const squashed=[];
for(const reSplit of [false,true]) for(const [label,script] of returned) {
 context.SPresetSettings.ChatSquash={...defaults,re_split:reSplit,squashed_post_script:script};
 diagnostics=[];
 const messages=[{role:'user',content:'ORIGINAL'}];
 try {
  const result=context.squashPrompts(messages);
  squashed.push({reSplit,returned:label,outcome:'return',messages:result.map(m=>({role:m.role,content:describe(m.content)})),wireJson:JSON.stringify(result),diagnostics:diagnostics.length});
 }catch(error){ squashed.push({reSplit,returned:label,outcome:'throw',error:error.name,message:error.message,mutatedMessages:messages,diagnostics:diagnostics.length}); }
}
const arrayMode=[];
for(const [label,script] of returned) {
 context.SPresetSettings.ChatSquash={...defaults,squashed_post_script:script};diagnostics=[];
 const target=[{role:'user',content:'ORIGINAL'}];
 const result=context.postProcessOriginalMessages(target);
 arrayMode.push({returned:label,result,sameReference:result===target,diagnostics:diagnostics.length});
}
const stopping=[];
for(const stopString of ['"ABA"','""','null','{}','3','false','["A","B"]','User:']) {
 for(const shape of ['absent','empty','nonempty']) {
  const data=shape==='absent'?{}:{stop:shape==='empty'?[]:['AB','A','old']};
  context.SPresetSettings.ChatSquash={enabled:true,enable_stop_string:true,stop_string:stopString};
  try {stop(data);stopping.push({stopString,shape,outcome:'return',data});}
  catch(error){stopping.push({stopString,shape,outcome:'throw',error:error.name,message:error.message,data});}
 }
}
const result={sourceCommit:'53bd585da14248ba10baaede7fc7ed0cebe1eeeb',sourceSha256:crypto.createHash('sha256').update(source).digest('hex'),squashed,arrayMode,stopping};
fs.writeFileSync(destination,JSON.stringify(result,null,2)+'\n');
console.log(JSON.stringify(result));
