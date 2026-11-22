// Fixed-source control-flow oracle. Only the required pure functions execute.
// The formatter and tool-availability predicate are explicit fixture boundaries.
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const [spresetPath, toolCallingPath, openaiPath, destination] = process.argv.slice(2);
assert.ok(spresetPath && toolCallingPath && openaiPath && destination, 'Expected fixed SPreset, tool-calling, openai and destination paths');
function read(relative, expected) {
  const bytes = fs.readFileSync(relative);
  assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), expected);
  return bytes.toString('utf8');
}
const sp = read(spresetPath, '4858bcb57530e3ff6ef68f0c94a4d291e2914c766c274f888e9a2fdf8d0efb59');
const st = read(toolCallingPath, '934be74f6bd672a821e5f3e5dc34ad4548c1cac60ee41c48feaa630e6e2f7712');
const oa = read(openaiPath, '0b77c30282825540265d5a09e681e5ccacf6760b05111ec880ffe237a9250604');
function between(source, start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, 'Missing fixed source boundary: ' + start);
  return source.slice(a, b);
}
const provider = {adapter:'openrouter',source:'openrouter',model:'fixture'};
const context = vm.createContext({
  structuredClone, console,
  getSPresetCurrentProvider: () => provider,
  compileSPresetFunctionExpression: () => data => {
    context.seen.push(structuredClone(data));
    if (data.calls.some(call => call.id === 'fail')) throw Error('fixture formatter failure');
    return data.channel + '|' + data.calls.map(call => call.id + ':' + call.signature).join(',');
  },
  chat_completion_sources: Object.fromEntries(['CLAUDE','MAKERSUITE','VERTEXAI','COHERE','DEEPSEEK','XAI','OPENROUTER','CUSTOM','POLLINATIONS','AIMLAPI','MOONSHOT','COMETAPI','ELECTRONHUB','NANOGPT','ZAI','SILICONFLOW','CHUTES','WORKERS_AI','FIREWORKS','MISTRALAI'].map(key => [key,key.toLowerCase()])),
  oai_settings:{chat_completion_source:'openrouter',show_thoughts:true},
  isDataURL: value => typeof value === 'string' && value.startsWith('data:'),
});
vm.runInContext([
  between(sp, 'function cloneSPresetData(value)', 'const SPRESET_CHAT_SQUASH_DEFAULT'),
  between(sp, 'const SPRESET_OUTPUT_PREPROCESSING_DEFAULT', 'const SPRESET_FIXED_PRESET_NAME_DEFAULT'),
  between(sp, 'function isSPresetPlainObject(value)', 'function normalizeSPresetChatSquash('),
  between(sp, 'function normalizeSPresetOutputPreprocessing(', 'function normalizeSPresetFixedPresetName('),
  between(sp, 'const SPRESET_TOOL_ARGUMENT_TEXT_KEYS', 'function wrapSPresetOutputGenerator('),
  'class ToolManager { static #INPUT_DELTA_KEY = "fixtureInputDelta"; static isToolCallingSupported() { return true; }',
  between(st, '    static parseToolCalls(', '    /**\n     * Checks if tool calling is supported'),
  '}',
  between(oa, 'export function getStreamingReply(', '/**\n * parseChatCompletionLogprobs').replace('export function', 'function'),
].join('\n'), context);
const call = (id, extra = {}) => ({id,type:'function',function:{name:'lookup',arguments:'{"text":"ok"}'},...extra});
const response = (calls, extra = {}) => ({choices:[{index:0,message:{role:'assistant',content:'answer',tool_calls:calls},finish_reason:'tool_calls',...extra}],usage:{prompt_tokens:3}});
const nonstream = [
  {name:'signature wins camel and snake',input:response([call('call_a',{signature:'raw',thoughtSignature:'camel',thought_signature:'snake'})])},
  {name:'camel accepted snake ignored',input:response([call('call_b',{thoughtSignature:'camel'}),call('call_c',{thought_signature:'snake'})])},
  {name:'empty signature wins fallback',input:response([call('call_empty',{signature:'',thoughtSignature:'camel'})],{index:7})},
  {name:'missing index channel zero',input:response([call('call_noindex',{signature:'s'})],{index:undefined})},
  {name:'all choices observed before return',input:{choices:[...response([call('first',{signature:'a'})]).choices,...response([call('second',{signature:'b'})],{index:4}).choices]}},
  {name:'later failure rolls response back',input:{choices:[...response([call('first',{signature:'a'})]).choices,...response([call('fail',{signature:'b'})],{index:4}).choices]}},
  {name:'malformed structured arguments',input:response([call('bad',{function:{name:'lookup',arguments:'{"text":'}})])},
  {name:'legacy function call',input:{choices:[{message:{role:'assistant',content:'',function_call:{name:'legacy',arguments:'{"text":"legacy"}',signature:'legacy-s'}},finish_reason:'function_call'}]}},
  {name:'visible content parts preserve source extraction',input:{choices:[{index:0,message:{role:'assistant',content:[{type:'text',text:'before '},{type:'output_text',text:'after'}],tool_calls:[call('parts',{signature:'part-s'})]},finish_reason:'tool_calls'}]}},
];
const packet = (delta,index=0) => ({choices:[{index,delta}]});
const stream = [
  {name:'first identity and concatenated signatures',source:'openrouter',frames:[
    packet({tool_calls:[{index:0,id:'call_one',type:'function',function:{name:'lookup',arguments:'{"text":"'},signature:'A',thoughtSignature:'C'}]}),
    packet({tool_calls:[{index:0,id:'call_two',type:'function',function:{name:'ignored',arguments:'ok"}'},signature:'B',thoughtSignature:'D'}]}),
  ]},
  {name:'OpenRouter detail overrides only on a call delta',source:'openrouter',frames:[
    packet({tool_calls:[{index:0,...call('call_one',{signature:'raw'})}]}),
    packet({reasoning_details:[{type:'reasoning.encrypted',id:'call_one',data:'detail'}]}),
    packet({tool_calls:[{index:0,function:{arguments:''}}]}),
  ]},
  {name:'detail alone does not mutate prior tool',source:'openrouter',frames:[
    packet({tool_calls:[{index:0,...call('call_one',{signature:'raw'})}]}),
    packet({reasoning_details:[{type:'reasoning.encrypted',id:'call_one',data:'late'}]}),
  ]},
  {name:'all choice calls use main channel',source:'custom',frames:[
    packet({tool_calls:[{index:0,...call('call_one',{signature:'a'})}]}),
    packet({tool_calls:[{index:2,...call('call_two',{thoughtSignature:'b'})}]},2),
  ]},
  {name:'missing choice index does not collect',source:'custom',frames:[{choices:[{delta:{tool_calls:[{index:0,...call('ignored')}]}}]}]},
];
(async () => {
  const output = {sources:{spreset:'53bd585da14248ba10baaede7fc7ed0cebe1eeeb',st:'7e8663cd9c184a550b37238218bdd32c6efc68e9'},fixtureBoundaries:['known formatter output/error','tool availability true','JSON frames already dispatched'],nonstream:[],stream:[]};
  context.settings = {toolCallFormatter:{enabled:true,script:'fixture'}};
  for (const entry of nonstream) {
    context.seen = []; context.input = structuredClone(entry.input);
    let result, failed = false;
    try { result = await vm.runInContext('consumeSPresetToolCallsFromResponse(input,settings)',context); }
    catch { result = structuredClone(entry.input); failed = true; }
    assert.deepEqual(context.input, entry.input);
    output.nonstream.push({...entry,failed,formatter:context.seen,result});
  }
  for (const entry of stream) {
    context.seen = []; context.calls = []; context.state = {reasoning:'',images:[],signature:'',toolSignatures:{}};
    context.oai_settings.chat_completion_source = entry.source;
    provider.source = entry.source;
    provider.adapter = entry.source === 'openrouter' ? 'openrouter' : 'openai';
    for (const frame of entry.frames) {
      context.frame = structuredClone(frame);
      vm.runInContext('getStreamingReply(frame,state); ToolManager.parseToolCalls(calls,frame,state.toolSignatures)',context);
    }
    let result = null;
    if (context.calls.length) result = await vm.runInContext('formatSPresetToolCalls(calls,settings,{stream:true,channel:"main"})',context);
    output.stream.push({...entry,folded:context.calls,state:context.state,formatter:context.seen,result});
  }
  fs.writeFileSync(destination, JSON.stringify(output,null,2)+'\n');
  console.log(JSON.stringify({nonstream:output.nonstream.length,stream:output.stream.length,destination}));
})().catch(error => {console.error(error);process.exitCode=1;});
