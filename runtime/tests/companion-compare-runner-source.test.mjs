// Actual source/Domain/JSON/anchored FS/loopback; model output is a labelled controlled peer.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,writeFile,readdir,rename,unlink,utimes} from 'node:fs/promises';
import {join} from 'node:path';
import {compareFixture,completeCompare,comparison,openCompare,operation,agreement,oldText,newText}
  from './fixtures/companion-compare-runner-fixture.mjs';
import {putDraft,until} from './fixtures/companion-find-runner-fixture.mjs';

test('I SOURCE_HTTP two explicitly bound originals produce real paragraph facts and one separate suggested ordering',async t=>{
  let checkReads;
  const f=await compareFixture(t,{sandboxed:true,model:{prepare({observer}) {
    const read=t.mock.method(f.store,'read');
    try { observer.guard(); checkReads=read.mock.callCount(); } finally { read.mock.restore(); }
  }}});
  await putDraft(f.root,'third-secret.md','This third file must never be read.');
  assert.equal(f.counters.reads.length,0,'binding performs metadata IO only');
  const {response,snapshot}=await completeCompare(f),report=comparison(snapshot);
  assert.equal(checkReads,0,'the model check only reads control fields');
  assert.equal(snapshot.state,'done');assert.equal(report.published,true);
  assert.equal(report.coverage.comparisonComplete,true);assert.equal(report.coverage.totalChangeGroups,2);
  assert.equal(report.coverage.displayedChangeGroups,2);assert.equal(report.identical,false);
  assert.equal(report.selection,'model');assert.equal(report.suggestions.status,'available');
  assert.deepEqual(report.differences.map(d=>d.a.paragraphs),[{from:3,to:3},{from:1,to:1}]);
  assert.deepEqual(report.differences.map(d=>d.b.paragraphs),[{from:3,to:3},{from:1,to:1}]);
  assert.deepEqual(report.differences.map(d=>d.id),report.suggestions.items.map(s=>s.differenceId));
  for(const side of ['a','b'])for(const difference of report.differences)for(const quote of difference[side].excerpts)
    assert.equal(f.texts[side].slice(quote.from,quote.to),quote.text);
  assert(report.sources.every(s=>s.readComplete&&s.verifiedAtPublish&&s.reason===null));
  assert.deepEqual(report.sources.map(s=>s.sourceRef),[f.inputs.a.sourceRef,f.inputs.b.sourceRef]);
  assert.equal(f.model.modelCalls,1);assert.equal(f.model.opened,1);assert.equal(f.counters.lists,0);
  assert.deepEqual(f.counters.reads,[f.names.a,f.names.b,f.names.a,f.names.b]);
  const request=f.model.requests[0],input=JSON.parse(request.messages[0].content[0].text);
  assert.equal(input.a.text,oldText);assert.equal(input.b.text,newText);assert.equal(input.changes.length,2);
  assert.deepEqual(Object.keys(input).sort(),['a','b','changes']);assert.equal(request.max_tokens,4000);
  assert.deepEqual(snapshot.steps.map(s=>s.stepKey),['readInputs','model','report']);
  assert.equal(snapshot.notes,undefined);assert.equal(snapshot.execution,undefined);assert.deepEqual(snapshot.artifacts,[]);
  assert.equal(await readFile(join(f.root,'notes',f.names.a),'utf8'),oldText);
  assert.equal(await readFile(join(f.root,'notes',f.names.b),'utf8'),newText);
  assert.deepEqual((await readdir(join(f.root,'notes'))).sort(),[f.names.a,f.names.b,'third-secret.md'].sort());
  const cap=(await f.request('/capabilities')).body;assert.deepEqual(cap.kinds,['host.compare_drafts']);
  const counts={reads:f.counters.reads.length,calls:f.model.modelCalls,seq:snapshot.runnerReceiptSeq};
  assert.deepEqual((await f.request(`/${f.body.taskId}?hostStoreId=${f.store.hostStoreId}`)).body,snapshot);
  assert.equal((await f.request('',f.body)).status,200);await f.settled();
  assert.equal(f.counters.reads.length,counts.reads);assert.equal(f.model.modelCalls,counts.calls);
  assert.equal(f.store.read(f.body.taskId).runnerReceiptSeq,counts.seq);
  const opened=await f.request(`/${f.body.taskId}/sources/${f.inputs.a.sourceRef}?hostStoreId=${f.store.hostStoreId}&hostExecutionId=${snapshot.hostExecutionId}`);
  assert.equal(opened.status,404,'I input refs are not H source-opening authority');
  assert.equal(f.counters.reads.length,counts.reads);
  if(process.env.I_COMPARE_WIRE_FIXTURE)await writeFile(process.env.I_COMPARE_WIRE_FIXTURE,JSON.stringify({
    scope:'ACTUAL_PINNED_SOURCE_LOOPBACK_SYNTHETIC_IO_CONTROLLED_MODEL',originals:f.texts,
    capabilities:cap,folder:f.folder,inputs:f.inputs,create:f.body,createReply:response.body,
    complete:snapshot,outboundModel:request},null,2)+'\n');
});

test('I SOURCE_HTTP identical originals finish without a model request or invented changes',async t=>{
  const f=await compareFixture(t,{a:'同一份。\r\n\r\n末段😀',b:'同一份。\r\n\r\n末段😀'});
  const {snapshot}=await completeCompare(f),report=comparison(snapshot);
  assert.equal(snapshot.state,'done');assert.equal(report.identical,true);
  assert.deepEqual(report.differences,[]);assert.equal(report.coverage.totalChangeGroups,0);
  assert.equal(report.suggestions.status,'not_needed');assert.equal(f.model.opened,0);assert.equal(f.model.modelCalls,0);
  assert.deepEqual(snapshot.steps.map(s=>s.stepKey),['readInputs','report']);
});

test('I SOURCE_HTTP absent configured model still publishes verified deterministic facts as partial',async t=>{
  const f=await compareFixture(t,{modelUnavailable:true});
  const {snapshot}=await completeCompare(f),report=comparison(snapshot);
  assert.equal(snapshot.state,'partial');assert.equal(report.published,true);
  assert.equal(report.coverage.comparisonComplete,true);assert.equal(report.differences.length,2);
  assert.equal(report.selection,'source_order');assert.equal(report.suggestions.status,'unavailable');
  assert.equal(report.suggestions.reason,'model_unavailable');assert.equal(f.model.modelCalls,0);
  assert(report.sources.every(s=>s.verifiedAtPublish));
});

for(const proposal of [{suggestions:[]},{suggestions:[{differenceId:'invented-third-file',practice:'Invented suggestion'}]}])
test('I SOURCE_HTTP rejected model proposal keeps its failure and still publishes original facts: '+JSON.stringify(proposal),async t=>{
  const f=await compareFixture(t,{proposal});
  const {snapshot}=await completeCompare(f),report=comparison(snapshot);
  assert.equal(snapshot.state,'partial');assert(report,'the failed model cannot erase the already-read comparison');
  assert.equal(report.published,true);assert.equal(report.selection,'source_order');assert.equal(report.differences.length,2);
  assert.equal(report.suggestions.status,'unavailable');assert.deepEqual(report.suggestions.items,[]);
  const model=snapshot.steps.find(s=>s.stepKey==='model');assert.equal(model.state,'failed');
  assert(model.result.observations.some(event=>event.type==='dispatch'));
  assert(model.result.observations.some(event=>event.type==='usage'));
  assert.equal(f.model.modelCalls,1);await f.request('',f.body);await f.settled();assert.equal(f.model.modelCalls,1);
});

test('I SOURCE_HTTP original disappearance after binding reports incomplete input and preserves the other complete original',async t=>{
  const f=await compareFixture(t);await unlink(join(f.root,'notes',f.names.a));
  const {snapshot}=await completeCompare(f),report=comparison(snapshot);
  assert.equal(snapshot.state,'partial');assert(report,'partial input facts require a public report');
  assert.equal(report.coverage.comparisonComplete,false);assert.equal(report.identical,null);
  assert.equal(report.sources[0].readComplete,false);assert.equal(report.sources[0].reason,'original_missing');
  assert.equal(report.sources[1].readComplete,true);assert.equal(report.sources[1].verifiedAtPublish,true);
  assert.deepEqual(report.differences,[]);assert.equal(f.model.modelCalls,0);
});

test('I SOURCE_HTTP equal-size and mtime replacement before report verification cannot produce a current complete result',async t=>{
  let f;f=await compareFixture(t,{beforeFinish:async()=>{
    const source=f.store.input(f.body.args.a),time=Date.parse('2026-11-20T12:00:00Z');
    await rename(join(f.root,'notes',f.names.a),join(f.root,'original-A'));
    const path=await putDraft(f.root,f.names.a,oldText.replaceAll('原','改'),time);
    await utimes(path,new Date(time),new Date(time));
    assert.equal((await f.fs.lstat(path)).size,source.entry.size);
  }});
  const {snapshot}=await completeCompare(f),report=comparison(snapshot);
  assert.equal(snapshot.state,'partial');assert.equal(report.coverage.comparisonComplete,true);
  assert.equal(report.sources[0].verifiedAtPublish,false);assert.equal(report.sources[0].reason,'original_changed');
  assert.equal(report.sources[1].verifiedAtPublish,true);assert.equal(f.model.modelCalls,1);
  assert(report.coverage.gaps.some(g=>g.side==='a'&&g.reason==='original_changed'));
});

test('I SOURCE_RESTART a persisted report claim interrupted before its commit recovers the same facts without another model',async t=>{
  const f=await compareFixture(t);
  t.mock.method(f.store,'finishCompare',async()=>{throw new Error('Controlled process-loss boundary before report commit');});
  await f.request('',f.body);await f.settled();
  const before=f.store.read(f.body.taskId),claim=before.steps.find(s=>s.stepKey==='report');
  assert.equal(claim.finishedAtMs,null);assert.equal(f.model.modelCalls,1);
  assert(before.notes['1'].inputs.comparison);assert(before.notes['1'].candidate);
  const held=before.budget.heldMs;assert(held>0);
  await f.close();
  const next=await openCompare(f.root);t.after(()=>next.close());next.start();await next.settled();
  const after=(await next.request(`/${f.body.taskId}?hostStoreId=${next.store.hostStoreId}`)).body,report=comparison(after);
  assert.equal(after.state,'done');assert(report?.published,'a claim is not a published report');
  assert.equal(after.hostExecutionId,before.hostExecutionId);assert.equal(report.differences.length,2);
  assert.equal(next.model.modelCalls,0);assert.deepEqual(next.counters.reads,[f.names.a,f.names.b]);
  assert.equal(after.budget.heldMs,held,'the interrupted original time reservation is not refunded');
  assert.equal(after.budget.limitMs,300000);assert(after.budget.spentMs>=before.budget.spentMs);
});

test('I SOURCE_RESTART stopping the owner after reading A preserves partial facts for original-store recovery',async t=>{
  let enter,release;const entered=new Promise(resolve=>{enter=resolve;}),gate=new Promise(resolve=>{release=resolve;});
  const f=await compareFixture(t,{read:async(args,actual)=>{
    if(args[1].name==='B新稿.txt'){enter();await gate;}return actual();
  }});
  await f.request('',f.body);await entered;
  const stopping=f.store.stop();release();await stopping;await f.close();
  const next=await openCompare(f.root);t.after(()=>next.close());next.start();await next.settled();
  const after=(await next.request(`/${f.body.taskId}?hostStoreId=${next.store.hostStoreId}`)).body,report=comparison(after);
  assert.equal(after.state,'partial');assert(report?.published,'owner loss is not an explicit cancellation');
  assert.equal(report.sources[0].readComplete,true);assert.equal(report.sources[0].verifiedAtPublish,true);
  assert.equal(report.sources[1].readComplete,false);assert.equal(report.coverage.comparisonComplete,false);
  assert.equal(next.model.modelCalls,0);assert.deepEqual(next.counters.reads,[f.names.a]);
  assert.equal(after.cancelRequested,false);assert.equal(after.taskRev,1);
});

test('I SOURCE_HTTP initial model window refusal retains original facts without entering the request stream',async t=>{
  const f=await compareFixture(t,{model:{window:1}});
  const {snapshot}=await completeCompare(f),report=comparison(snapshot);
  assert.equal(snapshot.state,'partial');assert.equal(report.selection,'source_order');assert.equal(report.differences.length,2);
  assert.equal(report.suggestions.status,'unavailable');assert.equal(report.suggestions.reason,'model_input_limit');
  assert.equal(f.model.modelCalls,0);assert(report.sources.every(s=>s.verifiedAtPublish));
  const finish=snapshot.steps.find(s=>s.stepKey==='model').result.observations.find(e=>e.type==='model-finish');
  assert.equal(finish.dispatched,false);assert.equal(finish.inputBudget,null);
  assert.equal(f.model.streams,0);
});

test('I SOURCE_HTTP actual invalid UTF8 input is not truncated into a complete comparison',async t=>{
  const f=await compareFixture(t,{a:Buffer.from([0xc3,0x28])});
  const {snapshot}=await completeCompare(f),report=comparison(snapshot);
  assert.equal(snapshot.state,'partial');assert.equal(report.sources[0].readComplete,false);
  assert.equal(report.sources[0].reason,'original_not_text');assert.equal(report.sources[1].verifiedAtPublish,true);
  assert.equal(report.coverage.totalChangeGroups,null);assert.equal(report.identical,null);assert.equal(f.model.modelCalls,0);
});

test('I SOURCE_HTTP a prepared model with no context window is not sent the originals',async t=>{
  const f=await compareFixture(t,{model:{window:null}});const {snapshot}=await completeCompare(f),report=comparison(snapshot);
  assert.equal(snapshot.state,'partial');assert.equal(report.suggestions.reason,'model_context_window_unknown');
  assert.equal(f.model.streams,0);assert.equal(f.model.modelCalls,0);assert(report.sources.every(s=>s.verifiedAtPublish));
});

test('I SOURCE_HTTP original input authority rejects a third path, forged version, foreign store and oversized bind before content IO',async t=>{
  const f=await compareFixture(t);
  for(const args of [{...f.body.args,path:'third.md'},
    {...f.body.args,a:{sourceRef:f.inputs.a.sourceRef,version:'invented'}},
    {...f.body.args,b:{sourceRef:'invented-input',version:f.inputs.b.version}},
    {...f.body.args,maxHighlights:4}])
    assert.equal((await f.request('',{...f.body,args})).status,400);
  for(const name of ['../third.md','folder/third.md','folder\\third.md','third.pdf'])
    assert.equal((await f.request('/inputs',{v:1,hostStoreId:f.store.hostStoreId,folderRef:f.folder.folderRef,name})).status,400);
  assert.equal((await f.request('/inputs',{v:1,hostStoreId:'other-store',folderRef:f.folder.folderRef,name:f.names.a})).status,409);
  await putDraft(f.root,'too-big.md','a'.repeat(65537));
  assert.equal((await f.request('/inputs',{v:1,hostStoreId:f.store.hostStoreId,folderRef:f.folder.folderRef,name:'too-big.md'})).status,400);
  assert.equal(f.counters.reads.length,0);assert.equal(f.model.modelCalls,0);assert.equal(f.counters.lists,0);
});

test('I SOURCE_HTTP cancel after model dispatch retains observations and never publishes a current completion',async t=>{
  let entered=false,release;const gate=new Promise(resolve=>{release=resolve;});
  const f=await compareFixture(t,{beforeFinish:async()=>{entered=true;await gate;}});
  try {
    await f.request('',f.body);await until(()=>entered,'held model result');
    const cancelled=await f.request(`/${f.body.taskId}/cancel`,operation(f));assert.equal(cancelled.status,200);
    release();await f.settled();
    const snapshot=f.store.snapshot(f.body.taskId);assert.equal(snapshot.state,'cancelled');assert.equal(snapshot.taskRev,2);
    assert.equal(comparison(snapshot),undefined);assert.equal(f.model.modelCalls,1);
    const model=snapshot.steps.find(s=>s.stepKey==='model');assert(model.result.observations.some(e=>e.type==='dispatch'));
    await f.request('',f.body);await f.settled();assert.equal(f.model.modelCalls,1);
  } finally {release();}
});

test('I SOURCE_HTTP cancellation during final original verification retains only an unpublished historical report',async t=>{
  let reads=0,entered=false,release;const gate=new Promise(resolve=>{release=resolve;});
  const f=await compareFixture(t,{read:async(_args,actual)=>{if(++reads===4){entered=true;await gate;}return actual();}});
  try {
    await f.request('',f.body);await until(()=>entered,'held final original verification');
    await f.request(`/${f.body.taskId}/cancel`,operation(f));release();await f.settled();
    const snapshot=f.store.snapshot(f.body.taskId),report=snapshot.steps.find(s=>s.taskRev===1&&s.stepKey==='report').result.completion;
    assert.equal(snapshot.state,'cancelled');assert.equal(snapshot.taskRev,2);assert.equal(report.published,false);
    assert.equal(comparison(snapshot),undefined);assert.equal(report.differences.length,2);assert.equal(f.model.modelCalls,1);
    assert.equal(snapshot.steps.find(s=>s.stepKey==='report').state,'partial');
    if(process.env.I_COMPARE_WIRE_FIXTURE)await writeFile(process.env.I_COMPARE_WIRE_FIXTURE+'.cancelled.json',JSON.stringify({
      scope:'ACTUAL_PINNED_SOURCE_LOOPBACK_SYNTHETIC_IO_CONTROLLED_MODEL_AND_READ_GATE',create:f.body,inputs:f.inputs,complete:snapshot},null,2)+'\n');
  } finally {release();}
});

test('I SOURCE_HTTP deadline crossing during the last original verification cannot publish current done',async t=>{
  let now=Date.now(),reads=0;const deadline=now+10000;
  const f=await compareFixture(t,{now:()=>now,read:async(_args,actual)=>{
    const result=await actual();if(++reads===4)now=deadline;return result;
  }});
  const {snapshot}=await completeCompare(f,{...f.body,deadlineAtMs:deadline}),report=comparison(snapshot);
  assert.equal(snapshot.state,'failed');assert.equal(report.published,false);
  assert.equal(snapshot.steps.find(s=>s.stepKey==='report').state,'partial');assert.equal(f.model.modelCalls,1);
  assert.equal(report.coverage.comparisonComplete,true);assert.equal(snapshot.budget.limitMs,300000);
});

test('I SOURCE_HTTP explicit amendment preserves the old report and cumulative budget without a second model attempt',async t=>{
  const f=await compareFixture(t);const {snapshot:one}=await completeCompare(f),first=comparison(one);
  const amended=await f.request(`/${f.body.taskId}/amend`,{...operation(f),changes:agreement(f.body)});
  assert.equal(amended.status,200);await f.settled();
  const two=f.store.snapshot(f.body.taskId),second=comparison(two);
  assert.equal(two.taskRev,2);assert.equal(two.state,'partial');assert.equal(second.published,true);
  assert.equal(second.suggestions.status,'unavailable');assert.equal(second.suggestions.reason,'model_attempt_used');
  assert.equal(second.selection,'source_order');assert.equal(f.model.modelCalls,1);
  assert.equal(two.steps.filter(s=>s.stepKey==='model').length,1);
  assert.deepEqual(two.steps.find(s=>s.taskRev===1&&s.stepKey==='report').result.completion,first);
  assert(two.budget.spentMs>=one.budget.spentMs);assert.equal(two.budget.limitMs,one.budget.limitMs);
  assert.deepEqual(f.counters.reads,[f.names.a,f.names.b,f.names.a,f.names.b,f.names.a,f.names.b,f.names.a,f.names.b]);
});

for(const atRead of [3,4])test(`I SOURCE_RESTART owner stopping during original verification read ${atRead} resumes the same report without repeating the model`,async t=>{
  let reads=0,enter,release;
  const entered=new Promise(resolve=>{enter=resolve;}),gate=new Promise(resolve=>{release=resolve;});
  const f=await compareFixture(t,{read:async(_args,actual)=>{
    if(++reads===atRead){enter();await gate;}return actual();
  }});
  await f.request('',f.body);await entered;
  const stopping=f.store.stop();release();await stopping;
  const before=f.store.snapshot(f.body.taskId),original=comparison(before);
  assert.equal(original.published,false);assert.equal(f.model.modelCalls,1);
  await f.close();
  const next=await openCompare(f.root);t.after(()=>next.close());next.start();await next.settled();
  const after=next.store.snapshot(f.body.taskId),current=comparison(after);
  assert.equal(after.state,'done',JSON.stringify({before:before.state,beforeReason:before.waitReason,after:after.state}));
  assert.equal(after.hostStoreId,before.hostStoreId);assert.equal(after.hostExecutionId,before.hostExecutionId);
  assert.equal(after.taskRev,before.taskRev);assert.equal(current.published,true);
  assert.equal(next.model.opened,0);assert.equal(next.model.modelCalls,0);
  assert.deepEqual(next.counters.reads,[f.names.a,f.names.b]);
  const reports=after.steps.filter(s=>s.stepKey==='report');assert.equal(reports.length,2);
  assert.deepEqual(reports[0].result.completion,original,'the old unpublished observation stays immutable');
  assert(after.budget.spentMs>=before.budget.spentMs);assert.equal(after.budget.limitMs,300000);
  if(process.env.I_COMPARE_WIRE_FIXTURE)await writeFile(process.env.I_COMPARE_WIRE_FIXTURE+`.owner-stop-${atRead}.json`,JSON.stringify({
    scope:'ACTUAL_PINNED_SOURCE_LOOPBACK_OWNER_STOP_AND_DOMAIN_REOPEN_WITH_CONTROLLED_MODEL',
    create:f.body,inputs:f.inputs,originals:f.texts,before,complete:after},null,2)+'\n');
});

test('I SOURCE_RESTART an observed dispatched model with an unknown outcome is never retried after reopen or explicit amendment',async t=>{
  const f=await compareFixture(t,{model:{stream:async function*(){
    yield {type:'text-delta',text:'{"suggestions":'};
    throw new Error('Controlled loss after dispatch before any terminal response');
  }}});
  const {snapshot:before}=await completeCompare(f),report=comparison(before);
  assert.equal(before.state,'partial');assert.equal(report.published,true);
  assert.equal(report.suggestions.status,'unknown');assert.equal(report.selection,'source_order');
  const step=before.steps.find(s=>s.stepKey==='model');assert.equal(step.state,'unknown');
  const observed=step.result.observations.find(e=>e.type==='model-finish');
  assert.equal(observed.dispatched,true);assert.equal(observed.usage.final_usage,null);
  assert.equal(f.model.modelCalls,1);await f.close();
  const next=await openCompare(f.root);t.after(()=>next.close());next.start();await next.settled();
  assert.deepEqual(next.store.snapshot(f.body.taskId),before);assert.equal(next.counters.reads.length,0);
  const change={...operation({...f,store:next.store}),changes:agreement(f.body)};
  assert.equal((await next.request(`/${f.body.taskId}/amend`,change)).status,200);await next.settled();
  const after=next.store.snapshot(f.body.taskId);
  assert.equal(after.state,'partial');assert.equal(after.taskRev,2);
  assert.equal(comparison(after).suggestions.reason,'model_attempt_used');
  assert.equal(next.model.opened,0);assert.equal(next.model.modelCalls,0);
  assert.equal(after.steps.filter(s=>s.stepKey==='model').length,1);
  assert.deepEqual(after.steps.find(s=>s.stepKey==='model'),step);
  assert(after.budget.spentMs>=before.budget.spentMs);assert.equal(after.budget.limitMs,300000);
});

test('I SOURCE_RESTART unknown report claims retain their reservations and stop further IO at the same cumulative budget',async t=>{
  const f=await compareFixture(t);let current=f,previousHeld=0,firstExecution;
  const history=[];
  for(let attempt=0;attempt<5;attempt++){
    if(attempt){current=await openCompare(f.root);t.after(()=>current.close());}
    t.mock.method(current.store,'finishCompare',async()=>{throw new Error('Controlled loss before this report commit');});
    if(attempt===0){await current.request('',f.body);await current.settled();}
    else{current.start();await current.settled();}
    const snapshot=current.store.snapshot(f.body.taskId),record=current.store.read(f.body.taskId);
    firstExecution??=snapshot.hostExecutionId;assert.equal(snapshot.hostExecutionId,firstExecution);
    assert.equal(snapshot.taskRev,1);assert.equal(snapshot.budget.limitMs,300000);
    assert(snapshot.budget.heldMs>previousHeld);previousHeld=snapshot.budget.heldMs;
    assert(snapshot.budget.spentMs+snapshot.budget.heldMs<=300000);
    assert.equal(record.steps.filter(s=>s.stepKey==='report').length,attempt+1);
    assert(record.notes['1'].inputs.comparison);assert(record.notes['1'].candidate);
    assert.equal(current.model.modelCalls,attempt===0?1:0);
    history.push({budget:snapshot.budget,claims:record.steps.filter(s=>s.stepKey==='report').map(s=>s.reserveMs)});
    await current.close();
  }
  const next=await openCompare(f.root);t.after(()=>next.close());next.start();await next.settled();
  const exhausted=next.store.snapshot(f.body.taskId),stored=next.store.read(f.body.taskId);
  assert.equal(exhausted.state,'failed');assert.equal(exhausted.waitReason,'execution_budget_exhausted');
  assert.equal(exhausted.budget.spentMs+exhausted.budget.heldMs,300000);
  assert.equal(next.counters.reads.length,0);assert.equal(next.model.opened,0);assert.equal(next.model.modelCalls,0);
  assert.equal(exhausted.steps.filter(s=>s.stepKey==='report').length,5);
  assert(exhausted.steps.filter(s=>s.stepKey==='report').every(s=>s.state==='unknown'&&s.reason==='report_interrupted'));
  assert(stored.notes['1'].inputs.comparison);assert(stored.notes['1'].candidate);
  await next.request('',f.body);await next.settled();
  assert.deepEqual(next.store.snapshot(f.body.taskId),exhausted);assert.equal(next.counters.reads.length,0);
  assert(history.at(-1).claims.at(-1)<60000,'last claim is clamped to the true remaining budget');
});
