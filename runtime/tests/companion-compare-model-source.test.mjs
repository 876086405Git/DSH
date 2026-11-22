// Real I runner + task execution model owner + pinned LlmRuntime/DeepSeek bodies.
// Cordis service identity and loopback SSE output are explicit controlled seams.
import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {chatSourceFixture} from './fixtures/companion-chat-usage-source.mjs';
import {compareFixture,completeCompare,comparison,oldText,newText} from './fixtures/companion-compare-runner-fixture.mjs';
import {load} from './fixtures/companion-find-runner-fixture.mjs';

const {createNotesExecutionOwner}=await load('companion/task-execution.js');
const {compareInputEstimate}=await load('companion/compare-drafts.js');
const {FULL_PRESET}=await load('companion/prompt-context.js');
const modelRoot=join(process.env.COMPANION_TASK_HARNESS,'model-source');
const finalUsage={output_tokens:13,cache_read_input_tokens:7,vendor_field:'I-actual-final-omits-input'};

async function source(t,options={}) {
  const requests=[];
  const server=createServer(async(req,res)=>{
    const chunks=[];for await(const chunk of req)chunks.push(chunk);
    const body=JSON.parse(Buffer.concat(chunks));
    requests.push({url:req.url,headers:req.headers,body});
    const input=JSON.parse(body.messages[0].content[0].text);
    const proposal={suggestions:input.changes.slice().reverse().slice(0,3).map(change=>({
      differenceId:change.id,practice:'建议按这一处的真实新句重新排练。'}))};
    const events=[
      {type:'message_start',message:{usage:{input_tokens:17,cache_read_input_tokens:3}}},
      {type:'content_block_start',index:0,content_block:{type:'text',text:''}},
      {type:'content_block_delta',index:0,delta:{type:'text_delta',text:JSON.stringify(proposal)}},
      {type:'content_block_stop',index:0},
      {type:'message_delta',delta:{stop_reason:'end_turn'},usage:finalUsage},
      {type:'message_stop'},
    ];
    res.writeHead(200,{'content-type':'text/event-stream'});
    res.end(events.map(event=>`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(''));
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  t.after(async()=>{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));});
  const model=await chatSourceFixture(modelRoot,{lookupWindow:true,extensionFields:options.extensionFields,
    transport(url,init){assert.equal(new URL(url).hostname,'127.0.0.1');return fetch(url,init);}});
  t.after(()=>model.dispose());
  model.connection.baseURL=`http://127.0.0.1:${server.address().port}/anthropic`;
  model.connection.models[0].contextWindow=options.unknownWindow?undefined:options.window??64000;
  if(options.unknownWindow)model.connection.defaultContextWindow=undefined;
  const preparationErrors=[],actualPrepare=model.llm.prepareCompanionAuxiliaryCall.bind(model.llm);
  model.llm.prepareCompanionAuxiliaryCall=async(...args)=>{
    try{return await actualPrepare(...args);}catch(error){
      preparationErrors.push({code:error.code,message:error.message});throw error;
    }
  };
  let execution,opened,selected=structuredClone(model.config),policy='read-only',ctx,values,origin;
  const accesses=[],live=new Map(),forbidden=[];
  const blocked=name=>(..._args)=>{forbidden.push(name);throw new Error('I must not invoke '+name);};
  const f=await compareFixture(t,{hostSessionId:options.full?'source-session':undefined,
    executionFactory(actual){
      values={fs:actual.fs,llm:model.llm,agentDefaultModel:{currentSelection:()=>structuredClone(selected)},
        sandboxPolicy:{resolve:()=>({mode:policy,workspaceRoot:join(actual.root,'notes')})},
        approval:{config:{policy:'ask'},effectivePolicy:()=> 'ask'},
        agentPresets:{presetForSession:()=>FULL_PRESET},
        agents:{get:id=>live.get(id),create:blocked('agents.create'),resume:blocked('agents.resume')},
        sessions:{flush:blocked('sessions.flush')},sessionPersistence:{stat:blocked('sessionPersistence.stat')}};
      ctx={get:key=>{accesses.push(key);assert(Object.hasOwn(values,key),'unexpected service '+key);return values[key];}};
      origin={id:'source-session',session:{id:'source-session'},model:{current:()=>structuredClone(selected)},loopCtx:ctx};
      if(options.full)live.set(origin.id,origin);
      values.sessionController={resolveAgent:async id=>({agent:live.get(id)})};
      execution=createNotesExecutionOwner(ctx,actual.store);
      return {async openModel(record){opened=await execution.openModel(record);return opened;}};
    }});
  t.after(()=>execution.close());
  return {...f,modelSource:model,requests,forbidden,accesses,values,live,origin,preparationErrors,
    get opened(){return opened;},get executionOwner(){return execution;},
    setSelection:value=>{selected=value;},setPolicy:value=>{policy=value;}};
}

for(const full of [false,true])test(`I SOURCE_HTTP_IO actual ${full?'full original session':'light default'} model owner reaches the selected adapter without creating a chat or task Agent`,async t=>{
  const f=await source(t,{full});const {snapshot}=await completeCompare(f),report=comparison(snapshot);
  assert.equal(snapshot.state,'done');assert.equal(report.published,true);assert.equal(f.requests.length,1);
  assert.equal(f.modelSource.requests.length,1);assert.equal(f.store.read(f.body.taskId).execution,null);
  assert.deepEqual(f.forbidden,[]);assert(!f.accesses.includes('sessions'));assert(!f.accesses.includes('sessionPersistence'));
  assert.equal(f.opened.origin,full?f.origin:null);assert.equal(f.opened.llm,f.modelSource.llm);
  const {body,url,headers}=f.requests[0],input=JSON.parse(body.messages[0].content[0].text);
  assert.equal(url,'/anthropic/v1/messages');assert.equal(body.model,'chosen-model');
  assert.equal(body.max_tokens,4000);assert.equal(body.stream,true);assert.deepEqual(body.thinking,{type:'disabled'});
  assert.equal(body.messages.length,1);assert.equal(body.messages[0].role,'user');
  assert.equal(input.a.text,oldText);assert.equal(input.b.text,newText);assert.equal(input.changes.length,2);
  assert.deepEqual(Object.keys(input).sort(),['a','b','changes']);
  assert(!Object.hasOwn(body,'tools'));assert(!Object.hasOwn(body,'tool_choice'));
  assert.equal(headers['x-deepseek-harness-session-id'],undefined);
  assert(!JSON.stringify(body).includes('SYNTHETIC_PHONE_HUMAN'));
  const completion=snapshot.steps.find(s=>s.stepKey==='model').result.completion;
  assert.deepEqual(completion.inputBudget,{...compareInputEstimate(JSON.stringify(body),64000),boundary:'provider-request'});
  assert.deepEqual(completion.usage.final_usage,finalUsage);assert.equal(completion.usage.start_usage.input_tokens,17);
  assert.equal(completion.usage.input_uncached,null,'final omissions are not filled using start counters');
  assert.equal(completion.usage.output_tokens,13);assert.equal(report.differences.length,2);
  assert.deepEqual(report.differences.map(d=>d.a.paragraphs),[{from:3,to:3},{from:1,to:1}]);
  assert.deepEqual(snapshot.artifacts,[]);assert.equal(f.counters.lists,0);
  if(process.env.I_COMPARE_WIRE_FIXTURE)await writeFile(process.env.I_COMPARE_WIRE_FIXTURE+`.model-${full?'full':'light'}.json`,JSON.stringify({
    scope:'ACTUAL_TASK_EXECUTION_MODEL_OWNER_PINNED_ADAPTER_SOURCE_LOOPBACK_SYNTHETIC_SSE',
    originals:f.texts,inputs:f.inputs,create:f.body,complete:snapshot,outboundModel:body},null,2)+'\n');
  const oldSelection=structuredClone(f.opened.selected);
  f.setSelection({...oldSelection,model:'another-model'});assert.throws(f.opened.guard,/changed/);
  f.setSelection(oldSelection);f.opened.guard();
  const oldLlm=f.values.llm;f.values.llm={};assert.throws(f.opened.guard,/changed/);f.values.llm=oldLlm;
  if(full){f.live.delete(f.origin.id);assert.throws(f.opened.guard,/changed/);f.live.set(f.origin.id,f.origin);}
  await f.executionOwner.close();assert.throws(f.opened.guard,/changed/);
  assert.equal(f.requests.length,1);assert.deepEqual(f.forbidden,[]);
});

test('I SOURCE_HTTP_IO final serialized adapter body is rejected before dispatch while retaining the exact provider-boundary estimate',async t=>{
  // Observe an actual complete request first; auxiliary calls deliberately skip extensions.
  const baseline=await source(t);await completeCompare(baseline);
  assert.equal(baseline.requests.length,1);
  const body=baseline.requests[0].body,preliminary=JSON.stringify({system:body.system,messages:body.messages});
  const initial=compareInputEstimate(preliminary),window=initial.estimatedTokens+4000;
  assert.equal(compareInputEstimate(preliminary,window).accepted,true);
  assert.equal(compareInputEstimate(JSON.stringify(body),window).accepted,false);
  const f=await source(t,{window});
  const {snapshot}=await completeCompare(f),report=comparison(snapshot);
  assert.equal(snapshot.state,'partial');assert.equal(report.published,true);assert.equal(report.differences.length,2);
  assert.equal(report.suggestions.reason,'model_input_limit');assert.equal(report.selection,'source_order');
  assert.equal(f.requests.length,0);assert.equal(f.modelSource.requests.length,0);
  const step=snapshot.steps.find(s=>s.stepKey==='model');
  const observed=step.result.observations.find(event=>event.type==='model-finish');
  assert.equal(observed.dispatched,false);assert.equal(observed.inputBudget.accepted,false);
  assert.equal(observed.inputBudget.boundary,'provider-request');assert.equal(observed.inputBudget.contextWindow,window);
  assert(observed.inputBudget.estimatedTokens>initial.estimatedTokens);
  assert(!step.result.observations.some(event=>['dispatch','handoff','http','usage'].includes(event.type)));
  assert.deepEqual(f.forbidden,[]);
});

test('I SOURCE_HTTP_IO invalid actual adapter context metadata preserves verified facts and sends no request',async t=>{
  const f=await source(t,{unknownWindow:true});const {snapshot}=await completeCompare(f),report=comparison(snapshot);
  assert.equal(snapshot.state,'partial');assert.equal(report.suggestions.reason,'model_preflight_unavailable');
  assert.equal(f.preparationErrors.length,1);assert.equal(f.preparationErrors[0].code,'INVALID_MODEL_CONTEXT');
  assert.equal(report.selection,'source_order');assert(report.sources.every(s=>s.verifiedAtPublish));
  assert.equal(f.requests.length,0);assert.equal(f.modelSource.requests.length,0);
  const observed=snapshot.steps.find(s=>s.stepKey==='model').result.observations.find(e=>e.type==='model-finish');
  assert.equal(observed.dispatched,false);assert.equal(observed.inputBudget,null);assert.deepEqual(f.forbidden,[]);
});

test('I SOURCE_HTTP_IO actual auxiliary entry still rejects invalid or greater-than-4000 output controls before any dispatch',async t=>{
  const f=await source(t),observer={guard(){},observe(){assert.fail('invalid controls cannot emit transport observations');}};
  for(const maxTokens of [0,-1,1.5,4001])await assert.rejects(
    f.modelSource.llm.prepareCompanionAuxiliaryCall({...f.modelSource.config,maxTokens},new AbortController().signal,observer),
    {code:'INVALID_PREPARED_CALL'});
  assert.equal(f.requests.length,0);assert.equal(f.modelSource.requests.length,0);assert.equal(f.counters.reads.length,0);
});
