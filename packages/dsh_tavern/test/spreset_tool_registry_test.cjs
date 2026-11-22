const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
let now = 0;
const quiet = {log() {}, info() {}, warn() {}, error() {}, debug() {}};
function realm() { return vm.createContext({console: quiet, Date: {now: () => now}}); }
const page = realm();
vm.runInContext(fs.readFileSync('assets/spreset_page_runtime.js', 'utf8'), page);
const runtime = page.DshSPresetPageRuntime;
let serial = 0;
function request(kind, extra = {}) {
  return {requestId: String(++serial), chatId: 'chat', generationId: 'g', sessionId: 'registry',
    stage: 'ToolBindings', source: '', kind, arguments: [], ...extra};
}
function code(name, marker = '') {
  return `globalThis.evaluated = (globalThis.evaluated || 0) + 1; let count = 0;
    return {name:${JSON.stringify(name)}, description:${JSON.stringify(marker)}, parameters:{}, action:()=>++count};`;
}
function oracleFromSource(path) {
  const source = fs.readFileSync(path, 'utf8');
  function between(start, end) {
    const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
    assert.ok(a >= 0 && b > a); return source.slice(a, b);
  }
  const registered = new Map();
  const ctx = {chatCompletionSettings: {prompt_order: []}};
  const context = realm();
  Object.assign(context, {
    ctx, SPresetSettings: {ToolBindings: {}},
    SillyTavern: {getContext: () => ({registerFunctionTool: tool => registered.set(tool.name, tool),
      unregisterFunctionTool: name => registered.delete(name)})},
    createSPresetScriptConsole: () => quiet,
    recordSPresetScriptDiagnostic() {},
    wrapSPresetScriptFunction: fn => fn,
    applySPresetEntryDecisions: order => order,
  });
  const pieces = [
    "const SPRESET_TOOL_REQUIRED_KEYS = ['name','description','parameters','action']; const spresetToolEvaluationCache = new Map(); const spresetToolDefinitionCache = new Map(); const spresetRegisteredTools = new Map();",
    between('function evaluateSPresetToolCode(code, options = {}) {', '/**\n * 验证工具代码'),
    between("function executeSPresetToolCode(code, identifier = '') {", 'function extractSPresetFunctionBody(fn) {'),
    between('function getActiveEntryIdentifiers() {', '/**\n * 注销所有已注册的'),
    between('function unregisterAllSPresetTools() {', '/**\n * 根据 ToolBindings'),
    between('function syncSPresetToolRegistrations() {', 'function getPrompt(identifier) {'),
  ];
  vm.runInContext(pieces.join('\n'), context);
  return {context, registered, ctx};
}
const same = code('same');
const loose = code('loose');
const scenarios = [
  {at: 0, bindings: [{identifier:'left',uuid:'shared',code:same}, {identifier:'right',uuid:'shared',code:same}], actions:['same']},
  {at: 1500, bindings: [{identifier:'left',uuid:'shared',code:same}], actions:['same']},
  {at: 1600, bindings: [], actions:[]},
  {at: 1700, bindings: [{identifier:'left',uuid:'shared',code:same}], actions:['same']},
  {at: 3000, bindings: [{identifier:'loose',code:loose}], actions:['loose']},
  {at: 3500, bindings: [{identifier:'loose',code:loose}], actions:['loose']},
  {at: 4001, bindings: [{identifier:'loose',code:loose}], actions:['loose']},
  {at: 4050, bindings: [], actions:[]},
  {at: 4100, bindings: [{identifier:'loose',code:loose}], actions:['loose']},
  // A changed source with the same uuid/name updates the definition cache but
  // not the existing registration. This subtle upstream behavior is retained.
  {at: 5000, bindings: [{identifier:'fixed',uuid:'fixed',code:code('fixed','old')}], actions:['fixed']},
  {at: 6001, bindings: [{identifier:'fixed',uuid:'fixed',code:code('fixed','new')}], actions:['fixed']},
  {at: 6200, bindings: [], actions:[]},
  {at: 6300, bindings: [{identifier:'fixed',uuid:'fixed',code:code('fixed','new')}], actions:['fixed']},
];
(async () => {
  const oracle = process.argv[2] ? oracleFromSource(process.argv[2]) : null;
  const observed = [];
  for (let index = 0; index < scenarios.length; index++) {
    const item = scenarios[index]; now = item.at;
    const generationId = `g${index}`;
    const activeIdentifiers = item.bindings.map(binding => binding.identifier);
    const result = await runtime.evaluate(request('toolRegistry', {generationId,
      arguments: [{bindings:item.bindings,activeIdentifiers}]}));
    const tools = result.value.tools;
    const actions = [];
    for (const name of item.actions) {
      const tool = tools.find(tool => tool.definition.name === name);
      const action = await runtime.evaluate(request('toolAction', {generationId,
        sessionId: `${generationId}:${tool.sessionId}`, source:tool.code, arguments:[{}]}));
      actions.push(action.value);
    }
    const actual = {evaluated:page.evaluated, descriptions:tools.map(tool => tool.definition.description), actions};
    observed.push(JSON.parse(JSON.stringify(actual)));
    if (oracle) {
      oracle.context.SPresetSettings.ToolBindings = Object.fromEntries(item.bindings.map(binding =>
        [binding.identifier,{enabled:true,valid:true,code:binding.code,uuid:binding.uuid}]));
      oracle.ctx.chatCompletionSettings.prompt_order = [{character_id:100001,order:activeIdentifiers.map(identifier => ({identifier,enabled:true}))}];
      oracle.context.syncSPresetToolRegistrations();
      const definitions = [...oracle.registered.values()].filter(tool => tool.shouldRegister());
      const expected = {evaluated:oracle.context.evaluated,
        descriptions:definitions.map(tool => tool.description),
        actions:await Promise.all(item.actions.map(name => oracle.registered.get(name).action({})))};
      assert.deepEqual(JSON.parse(JSON.stringify(actual)), JSON.parse(JSON.stringify(expected)), `source differential at scenario ${index}`);
    }
    for (const tool of tools) runtime.releaseSession(`${generationId}:${tool.sessionId}`);
  }
  assert.deepEqual(observed.map(row => row.evaluated), [1,1,1,2,3,3,4,4,4,5,6,6,6]);
  assert.deepEqual(observed.map(row => row.actions), [[1],[2],[],[1],[1],[2],[3],[],[1],[1],[2],[],[1]]);
  assert.equal(observed[10].descriptions[0], 'old');
  assert.equal(observed[12].descriptions[0], 'new');
  console.log(`SPreset tool registry: ${scenarios.length} synthetic cache/lifecycle scenarios passed${oracle ? ' against extracted fixed upstream functions' : ''}. Node VM evidence only.`);
})().catch(error => {console.error(error);process.exitCode=1;});
