const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const local = new Map([['owner-setting', 'same-page']]);
const context = vm.createContext({ console: { log() {}, info() {}, warn() {}, error() {}, debug() {} },
  localStorage: { getItem: key => local.get(key) ?? null, setItem: (key, value) => local.set(key, String(value)) },
});
vm.runInContext(fs.readFileSync('assets/spreset_page_runtime.js', 'utf8'), context);
const runtime = context.DshSPresetPageRuntime;
let serial = 0;
function request(source, extra = {}) {
  return { requestId: String(++serial), chatId: 'chat', generationId: 'generation',
    sessionId: 'session', stage: 'FinalRequestProcessing', source, kind: 'functionExpression', captureLogs: true, arguments: [], ...extra };
}
(async () => {
  const changed = await runtime.evaluate(request('async ({request}) => { request.model = localStorage.getItem("owner-setting"); }',
    { arguments: [{request: {model: 'before'}}] }));
  assert.equal(changed.isUndefined, true);
  assert.equal(changed.arguments[0].request.model, 'same-page');
  await assert.rejects(runtime.evaluate(request('({})', {kind: 'validateFunctionExpression'})), /must evaluate/);
  const script = '({chunk,state}) => { state.n = (state.n || 0) + 1; state.self = state; state.fn = () => 1; console.info("chunk", chunk); return {output: chunk + state.n, state}; }';
  const first = await runtime.evaluate(request(script, {stage: 'OutputPreprocessing', arguments: [{chunk: 'a', state: {}}]}));
  const second = await runtime.evaluate(request(script, {stage: 'OutputPreprocessing', arguments: [{chunk: 'b', state: {}}]}));
  assert.equal(first.value.output, 'a1');
  assert.equal(second.value.output, 'b2');
  assert.equal(second.arguments[0].state, undefined);
  assert.deepEqual(Array.from(first.scriptLogs, log => Array.from(log.values)), [['chunk', 'a']]);
  assert.deepEqual(Array.from(second.scriptLogs, log => Array.from(log.values)), [['chunk', 'b']]);
  const reset = await runtime.evaluate(request(script, {stage: 'OutputPreprocessing', reset: true, arguments: [{chunk: 'c', state: {}}]}));
  assert.equal(reset.value.output, 'c1');
  const definition = 'let n = 0; return {name:"fixture", description:"test", parameters:{type:"object"}, action:async ({value})=>{ console.info("action", value); return {text:value, n:++n}; }, formatMessage:({value})=>"Show "+value};';
  const tool = await runtime.evaluate(request(definition, {kind: 'toolDefinition', cacheKey: 'stable-tool', sessionId: 'one'}));
  assert.equal(tool.value.hasAction, true);
  assert.equal(tool.value.hasFormatMessage, true);
  const one = await runtime.evaluate(request(definition, {kind: 'toolAction', cacheKey: 'stable-tool', arguments: [{value:'x'}]}));
  assert.equal(one.value.n, 1);
  runtime.releaseSession('one');
  await runtime.evaluate(request(definition, {kind: 'toolDefinition', cacheKey: 'stable-tool', sessionId: 'two'}));
  const two = await runtime.evaluate(request(definition, {kind: 'toolAction', cacheKey: 'stable-tool', arguments: [{value:'y'}]}));
  assert.equal(two.value.n, 2);
  assert.deepEqual(Array.from(one.scriptLogs, log => Array.from(log.values)), [['action', 'x']]);
  assert.deepEqual(Array.from(two.scriptLogs, log => Array.from(log.values)), [['action', 'y']]);
  const asyncPost = 'async target => { target[0].content = "synchronous mutation"; await Promise.resolve(); return [{role:"user", content:"awaited replacement"}]; }';
  const sync = await runtime.evaluate(request(asyncPost, {stage: 'ChatSquash',
    kind: 'syncFunctionExpression', arguments: [[{role:'user',content:'original'}]]}));
  assert.equal(Array.isArray(sync.value), false);
  assert.equal(sync.arguments[0][0].content, 'synchronous mutation');
  const statements = await runtime.evaluate(request('const prefix = "ok:"; value => prefix + value;',
    {kind:'syncFunctionExpression',stage:'ChatSquash',reset:true,arguments:['text']}));
  assert.equal(statements.value, 'ok:text');
  const disabled = await runtime.evaluate(request('() => { console.warn("visible console"); return 1; }', {captureLogs: false}));
  assert.equal(disabled.scriptLogs.length, 0);
  assert.equal(disabled.scriptLogsDropped, 0);
  const bounded = await runtime.evaluate(request('() => { for(let i=0;i<600;i++) console.info("event", i); return 600; }'));
  assert.equal(bounded.value, 600);
  assert.equal(bounded.scriptLogs.length, 500);
  assert.equal(bounded.scriptLogsDropped, 100);
  const large = await runtime.evaluate(request('() => { let reads=0; const x={get value(){reads++;return "secret";}}; x.self=x; for(let i=0;i<200;i++) console.info("x".repeat(8000),x); return reads; }'));
  assert.equal(large.value, 0);
  assert.ok(large.scriptLogsDropped > 0);
  assert.ok(large.scriptLogs.reduce((n, item) => n + JSON.stringify(item).length, 0) <= 512 * 1024);
  assert.ok(JSON.stringify(large.scriptLogs).includes('[Accessor]'));
  const oversized = await runtime.evaluate(request('() => { console.info(JSON.stringify({authToken:"CUT_SECRET_"+"x".repeat(10000)})); return 1; }'));
  assert.ok(!JSON.stringify(oversized.scriptLogs).includes('CUT_SECRET_'));
  assert.ok(JSON.stringify(oversized.scriptLogs).includes('[OMITTED string:'));
  const functionText = await runtime.evaluate(request('() => { console.info(Function("/*"+"x".repeat(9000)+"*/")); return 1; }'));
  assert.ok(JSON.stringify(functionText.scriptLogs).includes('[OMITTED string:'));
  await assert.rejects(runtime.evaluate(request('() => 1'), {aborted:true}), /cancelled/);
  let resume;
  context.pending = new Promise(resolve => { resume=resolve; });
  const signal = {aborted:false};
  const late = runtime.evaluate(request('async () => { await pending; localStorage.setItem("late-effect", "yes"); return 1; }'), signal);
  signal.aborted=true;
  resume();
  const lateResult=await late;
  assert.equal(lateResult.committed, undefined);
  assert.equal(local.get('late-effect'), 'yes');
  // The App, not this function, immediately settles its cancelled RPC as
  // unknown. AbortSignal cannot stop arbitrary user JS or establish no effect.
  await assert.rejects(runtime.evaluate(request('function declared(value) { return value; }',
    {kind:'syncFunctionExpression',stage:'ChatSquash',reset:true,arguments:['text']})), /must evaluate/);
  // Optional differential against the fixed original function only. Do not
  // execute the external runtime, its imports, DOM hooks or any user presets.
  if (process.argv[2]) {
    const source = fs.readFileSync(process.argv[2], 'utf8');
    const start = source.indexOf('  function runPostScript(target, messageArrayMode = false) {');
    const end = source.indexOf('  function postProcessOriginalMessages(messages) {', start);
    assert.ok(start >= 0 && end > start);
    const oracle = vm.createContext({
      SPresetSettings: {ChatSquash: {squashed_post_script_enable: true, squashed_post_script: asyncPost}},
      createSPresetScriptConsole: () => ({warn() {}}),
      cloneSPresetData: value => JSON.parse(JSON.stringify(value)),
      wrapSPresetScriptFunction: fn => fn,
      recordSPresetScriptDiagnostic() {},
    });
    vm.runInContext(source.slice(start, end) + '\nglobalThis.runPostScript = runPostScript;', oracle);
    const input = [{role:'user',content:'original'}];
    const actual = oracle.runPostScript(input, true);
    assert.equal(actual, input);
    assert.deepEqual(JSON.parse(JSON.stringify(actual)), [{role:'user',content:'original'}]);
    oracle.SPresetSettings.ChatSquash.squashed_post_script = 'const prefix = "ok:"; value => prefix + value;';
    assert.equal(oracle.runPostScript('text', false), statements.value);
    oracle.SPresetSettings.ChatSquash.squashed_post_script = 'function declared(value) { return value; }';
    assert.equal(oracle.runPostScript('text', false), 'text');
    console.log('Fixed upstream runPostScript differential: Promise return is not awaited and array backup is restored.');
  }
  runtime.resetPreset();
  await assert.rejects(runtime.evaluate(request(definition, {kind: 'toolAction', cacheKey: 'stable-tool', arguments: [{}]})), /unavailable/);
  console.log('SPreset page evaluator: synthetic page localStorage, async mutation, synchronous ChatSquash, opaque JS state, per-call console, retained tools and preset reset passed. This is a Node VM boundary test, not a WebView test.');
})().catch(error => { console.error(error); process.exitCode = 1; });
