// Read-only extraction of fixed ST functions/classes. No application, network,
// private preset or product Dart is executed. See explicit boundaries below.
const fs = require('node:fs'), vm = require('node:vm');
const crypto = require('node:crypto'), assert = require('node:assert/strict');
// Usage: node tool/st_differential/tool-reasoning-oracle.cjs OPENAI_JS PROMPT_MANAGER_JS REASONING_JS
const sourceFiles = process.argv.slice(2);
assert.equal(sourceFiles.length, 3, 'Supply the three exact ST 1.19.0 source files.');
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const pins = {
  openai: ['research/st/public/scripts/openai.js', '0b77c30282825540265d5a09e681e5ccacf6760b05111ec880ffe237a9250604'],
  prompt: ['research/st/PromptManager.js', 'b0054793b763d92b265f5f487645b68b4eca0867cb5ad6b5deb1034004b2c1cc'],
  reasoning: ['research/st/public/scripts/reasoning.js', 'c489812f2598d1a4879b1a7287abde092741adafdf67f5b15cf18f2dd71d82d1'],
};
const sources = {}, extracted = [];
for (const [index, [name, [file, sha]]] of Object.entries(pins).entries()) {
  const bytes = fs.readFileSync(sourceFiles[index]);
  assert.equal(digest(bytes), sha, file);
  sources[name] = bytes.toString('utf8');
}
function block(name, marker, ending = /^}\s*$/m) {
  const source = sources[name], start = source.indexOf(marker);
  assert.ok(start >= 0, marker);
  const end = ending.exec(source.slice(start));
  assert.ok(end, marker);
  const original = source.slice(start, start + end.index + end[0].length);
  extracted.push({file: pins[name][0], marker, sha256: digest(original)});
  return original.replace(/^export /, '');
}
const code = [
  block('openai', 'export const tool_reasoning_modes = {', /^};\s*$/m),
  block('openai', 'const interleaved_reasoning_providers = [', /^];\s*$/m),
  block('openai', 'const character_names_behavior = {', /^};\s*$/m),
  block('openai', 'function getToolReasoningMode('),
  block('openai', 'function getEffectiveToolReasoningMode('),
  block('openai', 'export function isReasoningSignatureSupported('),
  block('openai', 'function setOpenAIMessages('),
  block('openai', 'async function populateChatHistory('),
  block('openai', 'class IdentifierNotFoundError '),
  block('openai', 'class TokenBudgetExceededError '),
  block('openai', 'class InvalidCharacterNameError '),
  block('openai', 'class Message {'),
  block('openai', 'class MessageCollection {'),
  block('openai', 'export class ChatCompletion {'),
  block('prompt', 'class Prompt {'),
  block('prompt', 'export class PromptCollection {'),
  block('reasoning', 'export class PromptReasoning {'),
  'Object.assign(globalThis,{getToolReasoningMode,getEffectiveToolReasoningMode,setOpenAIMessages,populateChatHistory,Prompt,PromptCollection,ChatCompletion,PromptReasoning,Message});',
].join('\n');
const plain = value => JSON.parse(JSON.stringify(value));
const call = (id = 'c', reasoning) => ({id, name: 'echo', parameters: '{}', result: 'ok', ...(reasoning === undefined ? {} : {reasoning})});
const user = {role: 'user', content: 'U'};
const assistant = (content = 'A', reasoning = 'R') => ({role: 'assistant', content, reasoning});
const invocation = (id = 'c', reasoning) => ({role: 'assistant', content: 'tool transcript', invocations: [call(id, reasoning)]});

function context(test = {}) {
  const countCalls = [], toolProjections = [];
  const settings = {chat_completion_source: test.source || 'openrouter', show_thoughts: test.show ?? true,
    new_chat_prompt: '', new_group_chat_prompt: '', send_if_empty: '', names_behavior: -1,
    openrouter_model: test.currentModel || 'fixture-model', ...(Object.hasOwn(test,'mode') ? {tool_reasoning_mode: test.mode} : {})};
  const ctx = {oai_settings: settings, DEFAULT_ORDER: 100, structuredClone,
    chat_completion_sources: {OPENROUTER: 'openrouter', CUSTOM: 'custom', MAKERSUITE: 'makersuite', VERTEXAI: 'vertexai'},
    console: {log() {}, warn() {}, error() {}}, selected_group: test.group || false,
    name1: 'User', name2: 'Guide', IGNORE_SYMBOL: Symbol('ignore'), system_message_types: {NARRATOR: 'narrator'},
    getChatCompletionModel: () => test.currentModel || 'fixture-model', getMediaDisplay: () => null, getMediaIndex: () => null,
    isImageInliningSupported: () => false, isVideoInliningSupported: () => false, isAudioInliningSupported: () => false,
    ToolManager: {isToolCallingSupported: () => test.tools !== false},
    promptManager: {preparePrompt: value => value, serviceSettings: {names_behavior: -1}},
    substituteParams: value => value,
    power_user: {reasoning: {add_to_prompts: test.add !== false, max_additions: 10, prefix: '<think>', suffix: '</think>', separator: '\n'}},
    tokenHandler: {countAsync: async message => {countCalls.push(plain(message)); return JSON.stringify(message).length;}},
  };
  vm.createContext(ctx); vm.runInContext(code, ctx);
  const actualSetToolCalls = ctx.Message.prototype.setToolCalls;
  ctx.Message.prototype.setToolCalls = async function(invocations, includeSignature, includeReasoning) {
    toolProjections.push({invocations:plain(invocations), includeSignature, includeReasoning});
    return actualSetToolCalls.call(this, invocations, includeSignature, includeReasoning);
  };
  return {ctx, countCalls, toolProjections};
}
const vectors = [
  {id:'missing-default', rows:[user,invocation('c','OWN')], want:[null]},
  {id:'invalid-default', mode:'typo', rows:[user,invocation('c','OWN')], want:[null]},
  {id:'disabled-own-reasoning-removed', mode:'disabled', rows:[user,assistant(),invocation('c','OWN')], want:[null]},
  {id:'show-off', mode:'active_chain', show:false, rows:[user,invocation('c','OWN')], want:[null]},
  {id:'openai-provider', mode:'active_chain', source:'openai', rows:[user,invocation('c','OWN')], want:[null]},
  {id:'deepseek-provider', mode:'active_chain', source:'deepseek', rows:[user,invocation('c','OWN')], want:[null]},
  {id:'custom-provider', mode:'active_chain', source:'custom', rows:[user,invocation('c','OWN')], want:['OWN']},
  {id:'tools-not-supported', mode:'active_chain', tools:false, rows:[user,invocation('c','OWN')], want:[]},
  {id:'active-adjacent-fallback', mode:'active_chain', rows:[user,assistant(),invocation()], want:['R']},
  {id:'since-adjacent-fallback', mode:'since_last_user', rows:[user,assistant(),invocation()], want:['R']},
  {id:'active-own-wins', mode:'active_chain', rows:[user,assistant(),invocation('c','OWN')], want:['OWN']},
  {id:'active-chain-skips-tool-and-invocations', mode:'active_chain', rows:[user,assistant(),invocation('first'),{role:'tool',content:'prior tool'},invocation('second')], want:['R','R']},
  {id:'active-empty-invocations-array-is-skipped', mode:'active_chain', rows:[user,assistant(),{role:'assistant',content:'interim',invocations:[]},invocation()], want:[null,'R']},
  {id:'active-empty-assistant-stops', mode:'active_chain', rows:[user,assistant(),assistant('','EMPTY'),invocation()], want:[null]},
  {id:'since-empty-assistant-skipped', mode:'since_last_user', rows:[user,assistant(),assistant('','EMPTY'),invocation()], want:['R']},
  {id:'active-text-without-reasoning-stops', mode:'active_chain', rows:[user,assistant(),assistant('B',''),invocation()], want:[null]},
  {id:'since-text-without-reasoning-skipped', mode:'since_last_user', rows:[user,assistant(),assistant('B',''),invocation()], want:['R']},
  {id:'active-system-stops', mode:'active_chain', rows:[user,assistant(),{role:'system',content:'boundary'},invocation()], want:[null]},
  {id:'since-system-skipped', mode:'since_last_user', rows:[user,assistant(),{role:'system',content:'boundary'},invocation()], want:['R']},
  {id:'active-array-assistant-stops', mode:'active_chain', rows:[user,assistant(),assistant([{type:'text',text:'B'}],'ARRAY'),invocation()], want:[null]},
  {id:'last-user-boundary', mode:'since_last_user', rows:[user,invocation('old','OLD'),assistant(),{role:'user',content:'U2'},invocation('new')], want:[null,null]},
  {id:'no-user-boundary', mode:'active_chain', rows:[assistant(),invocation()], want:['R']},
  {id:'first-nonempty-invocation-reasoning', mode:'active_chain', rows:[user,{role:'assistant',content:'tool transcript',invocations:[call('a',''),call('b','B'),call('c','C')]}], want:['B']},
  {id:'js-string-mode-coercion', mode:['active_chain'], rows:[user,invocation('c','OWN')], want:['OWN']},
  {id:'js-truthy-show-string', mode:'active_chain', show:'false', rows:[user,invocation('c','OWN')], want:['OWN']},
  {id:'js-trim-keeps-nel-boundary', mode:'active_chain', rows:[user,assistant('\u0085','NEL'),invocation()], want:['NEL']},
  {id:'truthy-nonstring-own-blocks-fallback', mode:'active_chain', rows:[user,assistant(),invocation('c',3)], want:[null]},
  {id:'falsey-number-own-uses-fallback', mode:'active_chain', rows:[user,assistant(),invocation('c',0)], want:['R']},
  {id:'own-whitespace-is-nonempty', mode:'active_chain', rows:[user,invocation('c',' ')], want:[' ']},
];

(async () => {
  const history = [];
  for (const test of vectors) {
    const {ctx,countCalls,toolProjections} = context(test);
    const completion = new ctx.ChatCompletion(); completion.setTokenBudget(1000000,0);
    const prompts = new ctx.PromptCollection(new ctx.Prompt({identifier:'chatHistory',role:'system',content:''}));
    const input = plain(test.rows), before = JSON.stringify(input);
    await ctx.populateChatHistory(input,prompts,completion);
    const wire = plain(completion.getChat());
    const got = wire.filter(message => Array.isArray(message.tool_calls)).map(message => message.reasoning ?? null);
    assert.deepEqual(got,test.want,test.id);
    assert.equal(JSON.stringify(input),before,test.id+' input mutation');
    history.push({id:test.id, source:test.source||'openrouter', mode:test.mode??null, effectiveMode:ctx.getEffectiveToolReasoningMode(), show:test.show??true, toolsSupported:test.tools!==false,
      input:test.rows, wire, toolMessageReasoning:got, countCalls, toolProjections});
  }
  const provenance = [];
  for (const test of [
    {id:'same-api-model', api:'openrouter', model:'fixture-model', name:'Guide', wantOwn:'OWN', wantPlain:'R'},
    {id:'different-api', api:'custom', model:'fixture-model', name:'Guide', wantOwn:null, wantPlain:''},
    {id:'different-model', api:'openrouter', model:'other', name:'Guide', wantOwn:null, wantPlain:''},
    {id:'other-group-member', api:'openrouter', model:'fixture-model', name:'Other', group:true, wantOwn:'OWN', wantPlain:''},
    {id:'different-model-keeps-both-falsey-metadata', api:'openrouter', model:'other', name:'Guide', invocations:[{...call('c',false),signature:0}], wantOwn:false, wantPlain:''},
    {id:'different-model-truthy-signature-removes-both', api:'openrouter', model:'other', name:'Guide', invocations:[{...call('c',false),signature:'SIG'}], wantOwn:null, wantPlain:''},
    {id:'different-model-truthy-reasoning-removes-both', api:'openrouter', model:'other', name:'Guide', invocations:[{...call('c','OWN'),signature:false}], wantOwn:null, wantPlain:''},
    {id:'other-group-keeps-invocation-signature', api:'openrouter', model:'fixture-model', name:'Other', group:true, invocations:[{...call('c','OWN'),signature:'SIG'}], wantOwn:'OWN', wantPlain:''},
  ]) {
    const {ctx} = context(test);
    const chat=[{is_user:false,mes:'A',name:test.name,extra:{api:test.api,model:test.model,reasoning:'R',tool_invocations:test.invocations??[call('c','OWN')]}}];
    const before=JSON.stringify(chat), result=plain(ctx.setOpenAIMessages(chat));
    assert.equal(result[0].invocations[0].reasoning??null,test.wantOwn,test.id);
    assert.equal(result[0].reasoning,test.wantPlain,test.id);
    assert.equal(JSON.stringify(chat),before,test.id+' input mutation');
    provenance.push({id:test.id, source:'openrouter', model:'fixture-model', group:test.group||false, characterName:'Guide', input:chat, result});
  }
  const modeSettings=[];
  for (const test of [
    {id:'missing-show-is-falsey',settings:{tool_reasoning_mode:'active_chain'}},
    {id:'null-show-is-falsey',settings:{tool_reasoning_mode:'active_chain',show_thoughts:null}},
  ]) {
    const {ctx}=context();
    ctx.oai_settings=plain(test.settings);
    const expectedMode=ctx.getEffectiveToolReasoningMode();
    assert.equal(expectedMode,'disabled',test.id);
    modeSettings.push({...test,expectedMode});
  }
  const ordinary=[];
  for(const mode of ['disabled','active_chain']) for(const add of [false,true]) {
    const {ctx}=context({mode,add});
    const result=new ctx.PromptReasoning().addToMessage('BODY','ORDINARY',false,null);
    assert.equal(result,add?'<think>ORDINARY</think>\nBODY':'BODY');
    ordinary.push({mode,addToPrompts:add,result});
  }
  process.stdout.write(JSON.stringify({commit:'7e8663cd9c184a550b37238218bdd32c6efc68e9',pins,extracted,
    boundaries:['Actual populateChatHistory/getToolReasoningMode/getEffectiveToolReasoningMode/Message/MessageCollection/ChatCompletion/Prompt/PromptCollection/setOpenAIMessages/PromptReasoning.',
      'Tool support is an explicit true/false boundary, not a revalidation of the 103 catalog vectors; all images disabled.',
      'preparePrompt and substituteParams are identity boundaries for these macro-free fixtures; token counter returns JSON length, not tokenizer/cost evidence.',
      'No stream decoder, tool execution, browser/App or current Dart product is executed; upstream stream/nonstream invocation recording is separately source-read.',
      'The actual Message.setToolCalls is wrapped only to record its invocation arguments, then invoked unchanged.',
      'P1 consumes selector/provenance outputs only. The four PromptReasoning cases are unchanged ordinary-content controls, not a new PromptReasoning implementation.',
      'The first 25 history, first four provenance and all four ordinary cases retain the prior 33-vector audit; four history, four provenance and two direct missing/null show controls are appended.'],
    history,provenance,modeSettings,ordinaryReasoning:ordinary},null,2)+'\n');
})().catch(error=>{console.error(error);process.exitCode=1;});
