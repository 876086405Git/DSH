const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const quiet = {log() {},info() {},warn() {},error() {},debug() {}};
const page = vm.createContext({console:quiet});
vm.runInContext(fs.readFileSync('assets/spreset_page_runtime.js','utf8'),page);
const runtime = page.DshSPresetPageRuntime;
const action = `async function () {
  this.count = (this.count || 0) + 1;
  return {count:this.count,formatted:this.formatted,own:Object.keys(this).sort(),
    extra:this.extra ?? null,displayName:this.displayName,stealth:this.stealth,
    constructor:this.constructor.name,registered:await this.shouldRegister(),
    function:this.toFunctionOpenAI().function,html:this.toFunctionOpenAI().toString()};
}`;
const formatter = `function () { this.formatted = (this.formatted || 0) + 1; return this.displayName + ':' + this.formatted; }`;
const bindings = ['a','b','c'].map(name => ({identifier:name,uuid:name,code:`return {
  name:${JSON.stringify(name)},displayName:${JSON.stringify('Name '+name)},description:'Description',parameters:{},extra:100,
  action:${action}${name==='c'?'':`,formatMessage:${formatter}`}};`}));
let serial=0;
const request = (kind,extra={}) => ({requestId:String(++serial),chatId:'chat',generationId:'g',
  sessionId:'g:registry',stage:'ToolBindings',source:'',kind,arguments:[],...extra});
function fixedOracle(spPath,stPath) {
  const sp=fs.readFileSync(spPath,'utf8'),st=fs.readFileSync(stPath,'utf8');
  const definition=st.slice(st.indexOf('class ToolDefinition {'),st.indexOf('export class ToolManager {'));
  const wrapper=sp.slice(sp.indexOf('function wrapSPresetScriptFunction('),sp.indexOf('function finishSPresetScriptGeneration()'));
  assert.ok(definition.includes('class ToolDefinition'));assert.ok(wrapper.includes('processor.apply(this, args)'));
  const context=vm.createContext({console:quiet,ensureSPresetScriptTrace:()=>({}),recordSPresetScriptDiagnostic(){}});
  vm.runInContext(`let spresetScriptExecutionSequence=0;\n${definition}\n${wrapper}\nglobalThis.TD=ToolDefinition;`,context);
  return bindings.map(binding=>{
    context.code=binding.code;
    const definition=vm.runInContext("Function('console',code)(console)",context);
    return new context.TD(definition.name,definition.displayName||definition.name,definition.description,definition.parameters,
      context.wrapSPresetScriptFunction(definition.action,'tool',{dynamic:true}),
      typeof definition.formatMessage==='function'?context.wrapSPresetScriptFunction(definition.formatMessage,'format',{dynamic:true}):definition.formatMessage,
      ()=>true,definition.stealth??false);
  });
}
(async()=>{
  const registry=await runtime.evaluate(request('toolRegistry',{arguments:[{bindings,activeIdentifiers:['a','b','c']}]}));
  const oracle=process.argv[2]&&process.argv[3]?fixedOracle(process.argv[2],process.argv[3]):null;
  const counts=[];
  for(const index of [0,1,0,2]) {
    const tool=registry.value.tools[index];
    const extra={sessionId:`g:${tool.sessionId}`,arguments:[{}]};
    const format=await runtime.evaluate(request('toolFormatMessage',extra));
    const invoked=await runtime.evaluate(request('toolAction',extra));
    const actual=JSON.parse(JSON.stringify(invoked.value));
    if(oracle) {
      assert.equal(format.value,await oracle[index].formatMessage({}));
      assert.deepEqual(actual,JSON.parse(JSON.stringify(await oracle[index].invoke({}))));
    }
    assert.equal(actual.extra,null);
    assert.equal(actual.constructor,'ToolDefinition');
    assert.equal(actual.registered,true);
    assert.equal(actual.function.name,bindings[index].identifier);
    counts.push(actual.count);
    if(index===2) assert.equal(format.value,'Invoking tool: Name c');
  }
  assert.deepEqual(counts,[1,1,2,1]);
  console.log(`SPreset receiver: independent per-registration this, shared action/formatter receiver, default formatting, getters, shouldRegister and OpenAI descriptor passed${oracle?' against fixed ST ToolDefinition and SPreset wrapper':''}. Node VM evidence only.`);
})().catch(error=>{console.error(error);process.exitCode=1;});
