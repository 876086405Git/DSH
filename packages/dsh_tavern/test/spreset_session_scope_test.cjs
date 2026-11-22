const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const context = vm.createContext({console:{log(){},info(){},warn(){},error(){},debug(){}}});
vm.runInContext(fs.readFileSync('assets/spreset_page_runtime.js', 'utf8'), context);
const runtime = context.DshSPresetPageRuntime;
let sequence = 0;
function request(scope, session, extra = {}) {
  return {requestId:`${scope}:eval:${++sequence}`, chatId:'chat',generationId:'reused',
    sessionScope:scope,sessionId:`${scope}:${session}`,stage:'OutputPreprocessing',
    kind:'functionExpression',source:'({state})=>{state.n=(state.n||0)+1;return {output:String(state.n),state};}',
    arguments:[{chunk:'x',state:{}}],...extra};
}
async function output(scope) { return runtime.evaluate(request(scope, 'output:1')); }
(async () => {
  assert.equal((await output('old-run')).value.output, '1');
  assert.equal((await output('new-run')).value.output, '1');
  runtime.releaseSession('old-run:output:1');
  assert.equal((await output('new-run')).value.output, '2');

  const code = 'let n=0;return {name:"counter",description:"scope",parameters:{},action:()=>++n,formatMessage:()=>"counter"};';
  async function registry(scope, legacy = false) {
    const input = request(scope,'registry',{kind:'toolRegistry',stage:'ToolBindings',source:'',arguments:[{
      bindings:[{identifier:'tool',uuid:'stable',code}],activeIdentifiers:['tool'],
    }]});
    if (legacy) delete input.sessionScope;
    const result = await runtime.evaluate(input);
    assert.equal(result.requestId, input.requestId);
    return result.value.tools[0].sessionId;
  }
  const oldTool = await registry('old-run');
  const newTool = await registry('new-run');
  async function action(scope, tool) {
    return runtime.evaluate(request(scope,tool,{kind:'toolAction',stage:'ToolBindings',source:code,arguments:[{}]}));
  }
  assert.equal((await action('old-run',oldTool)).value, 1);
  runtime.releaseSession(`old-run:${oldTool}`);
  assert.equal((await action('new-run',newTool)).value, 2);
  const message = await runtime.evaluate(request('new-run',newTool,
    {kind:'toolFormatMessage',stage:'ToolBindings',source:code,arguments:[{}]}));
  assert.equal(message.value, 'counter');
  await assert.rejects(action('old-run',oldTool), /unavailable/);

  // Direct older callers omit sessionScope: their original generation prefix
  // remains accepted. The engine never omits the new private scope.
  const legacyTool = await registry('unused-legacy-scope', true);
  assert.equal((await action('reused',legacyTool)).value, 3);
  console.log('SPreset session scopes: late release isolation, UUID closure reuse, tool registry/callback agreement and legacy requests passed. Actual adapter in Node VM; no WebView claim.');
})().catch(error => {console.error(error);process.exitCode=1;});
