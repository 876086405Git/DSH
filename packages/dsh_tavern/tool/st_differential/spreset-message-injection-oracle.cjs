// Extract only the pinned public pure functions; never execute the full runtime.
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const [sourcePath, destination] = process.argv.slice(2);
assert.ok(sourcePath && destination, 'Expected fixed inject.js and output JSON paths');
const bytes = fs.readFileSync(sourcePath);
assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),
  '4858bcb57530e3ff6ef68f0c94a4d291e2914c766c274f888e9a2fdf8d0efb59',
  'Source must be the pinned SPreset inject.js');
const source = bytes.toString('utf8');
function between(start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, `Missing fixed-source boundary ${start}`);
  return source.slice(a, b);
}
const context = vm.createContext({});
vm.runInContext([
  between('function cloneSPresetData(value)', 'const SPRESET_CHAT_SQUASH_DEFAULT'),
  source.match(/^const SPRESET_EMPTY_MESSAGE_PLACEHOLDER = .*;$/m)[0],
  between('function validateSPresetMessageInjection(data)', 'function getSPresetFlattenedMessageSources('),
].join('\n'), context);
const base = {role:'system',content:'fixture'};
const binding = (call, result) => ({enabled:true,reasoning:'',signature:'',toolCalls:[call],toolResults:result?[result]:[]});
const cases = [];
for (const adapter of ['openai','deepseek','openrouter','gemini','claude']) {
  cases.push({name:`empty primary aliases (${adapter})`,provider:{adapter,source:adapter==='gemini'?'makersuite':adapter,model:'fixture'},
    binding:binding({id:'call',name:'',function:{name:'lookup',arguments:'{"q":1}'}},
      {toolCallId:'',tool_call_id:'call',content:{ok:true}})});
}
for (const value of [false,0]) {
  cases.push({name:`falsy name/result aliases ${value}`,provider:{adapter:'openai'},
    binding:binding({id:'call',name:value,function:{name:'lookup'}},{toolCallId:value,tool_call_id:'call'})});
}
for (const value of [false,0,'',null]) {
  cases.push({name:`invalid falsy call id ${JSON.stringify(value)}`,provider:{adapter:'openai'},
    binding:binding({id:value,name:'lookup'})});
}
cases.push({name:'both name aliases falsy',provider:{adapter:'openai'},
  binding:binding({id:'call',name:false,function:{name:0}})});
cases.push({name:'both result id aliases falsy',provider:{adapter:'openai'},
  binding:binding({id:'call',name:'lookup'},{toolCallId:false,tool_call_id:0})});
cases.push({name:'truthy non-string id follows source String',provider:{adapter:'openai'},
  binding:binding({id:true,name:'lookup'})});
const vectors = cases.map(entry => {
  context.binding=entry.binding; context.base=base; context.provider=entry.provider;
  const valid=vm.runInContext('validateSPresetMessageInjection(binding).valid',context);
  const expected=valid?vm.runInContext('applySPresetMessageInjection(base,normalizeSPresetMessageInjection(binding),provider)',context):null;
  return {...entry,base,valid,expected};
});
fs.writeFileSync(destination,JSON.stringify({source:{commit:'53bd585da14248ba10baaede7fc7ed0cebe1eeeb',sha256:crypto.createHash('sha256').update(bytes).digest('hex')},vectors},null,2)+'\n');
console.log(`Fixed SPreset message injection source: ${vectors.length} alias/validation vectors captured.`);
