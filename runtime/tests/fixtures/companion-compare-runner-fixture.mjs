// Actual pinned Domain/JSON/FS and loopback routes; only the model owner/stream is supplied.
import assert from 'node:assert/strict';
import {findFixture,openFind,putDraft,until,load} from './companion-find-runner-fixture.mjs';
import {modelPeer} from './companion-notes-runner-fixture.mjs';

const {createCompareDraftRunner}=await load('companion/compare-drafts.js');
export const oldText='开场原句。\n\n共同一段。\n\n结尾原句。\n';
export const newText='开场新句。\n\n共同一段。\n\n结尾新句。\n';
export const comparison=snapshot=>snapshot.steps.findLast(step=>
  step.taskRev===snapshot.taskRev&&step.stepKey==='report')?.result?.completion;
export const agreement=body=>({args:body.args,deadlineAtMs:body.deadlineAtMs,afterExit:body.afterExit,allowQueue:body.allowQueue});
export const operation=(f,rev=1,id='compare-op-2')=>({v:1,hostStoreId:f.store.hostStoreId,
  kind:'host.compare_drafts',operationId:id,expectedTaskRev:rev,taskRev:rev+1});

function compareHost(f,options={}) {
  const model={opened:0,prepared:0,streams:0,modelCalls:0,requests:[]};
  let work;
  const stream=async function*({request,observer}) {
    const input=JSON.parse(request.input);
    const result=options.proposal??{suggestions:input.changes.slice().reverse().slice(0,3)
      .map(change=>({differenceId:change.id,practice:'建议按这一处的实际新句重新排练。'}))};
    yield {type:'text-delta',text:JSON.stringify(result)};
    await options.beforeFinish?.();
    observer.observe({type:'usage',event:'message_delta',raw:{output_tokens:13}});
    observer.observe({type:'stop',stopReason:'end_turn'});
    observer.observe({type:'complete'});
    yield {type:'finish',reason:{kind:'stop'}};
  };
  const execution=options.executionFactory?.(f)??{async openModel(record) {
    model.opened++;
    assert.equal(record.kind,'host.compare_drafts');
    assert.equal(record.hostSessionId,null);
    if(options.modelUnavailable)throw new Error('Controlled absent configured model');
    return {selected:options.selected??{provider:'fixture',model:'fixture-compare'},
      llm:options.llm??modelPeer(model,{stream,...options.model}),guard(){options.guard?.();}};
  }};
  const start=()=>{
    assert.equal(f.store.runner,null);
    const runner=createCompareDraftRunner({store:f.store,ctx:{get:key=>{
      assert.equal(key,'fs','comparison runner must not request an Agent/Session');return f.fs;
    }},execution});
    f.store.attachRunner({...runner,kinds:['host.compare_drafts'],wake(id){
      work=runner.wake(id);return work;
    }});
    for(const id of f.store.runnable())f.store.wake(id);
    return runner;
  };
  return {...f,model,start,settled:()=>work};
}

export async function openCompare(root,options={}) {
  return compareHost(await openFind(root,options),options);
}

export async function compareFixture(t,options={}) {
  const f=compareHost(await findFixture(t,options),options);
  f.start();
  const names={a:options.aName??'A旧稿.md',b:options.bName??'B新稿.txt'};
  const texts={a:options.a??oldText,b:options.b??newText},inputs={};
  for(const side of ['a','b']) {
    await putDraft(f.root,names[side],texts[side]);
    const response=await f.request('/inputs',{v:1,hostStoreId:f.store.hostStoreId,
      folderRef:f.folder.folderRef,name:names[side]});
    assert.equal(response.status,201,JSON.stringify(response.body));
    inputs[side]=response.body;
  }
  const body={...f.body,taskId:'compare-one',kind:'host.compare_drafts',
    ...(options.hostSessionId?{hostSessionId:options.hostSessionId,origin:{...f.body.origin,sourceSessionId:'full:original-room'}}:{}),args:{
    a:{sourceRef:inputs.a.sourceRef,version:inputs.a.version},
    b:{sourceRef:inputs.b.sourceRef,version:inputs.b.version},maxHighlights:3}};
  return {...f,body,inputs,names,texts};
}

export async function completeCompare(f,body=f.body) {
  if(!f.store.runner)f.start();
  const response=await f.request('',body);
  assert.equal(response.status,201,JSON.stringify(response.body));
  await f.settled(); // Observe the production wake caused by the actual POST; do not issue another wake.
  return {response,snapshot:(await f.request(`/${body.taskId}?hostStoreId=${f.store.hostStoreId}`)).body};
}
