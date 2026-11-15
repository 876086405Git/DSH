// Actual pinned HAR methods. Permission/pasteboard/StyledString/ArrayList are explicit boundaries.
import assert from 'node:assert/strict';
import { test,after } from 'node:test';
import { readFileSync,writeFileSync } from 'node:fs';
import { resolve,dirname } from 'node:path';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import vm from 'node:vm';
import { setImmediate as nextTurn } from 'node:timers/promises';

const [embeddingValue,manifestValue,outputValue]=process.argv.slice(2);
assert(embeddingValue && manifestValue && outputValue && process.env.OHOS_TYPESCRIPT_PREFIX);
const embedding=resolve(embeddingValue),manifest=JSON.parse(readFileSync(manifestValue,'utf8'));
const ts=createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX,'package.json'))('typescript');
const observations=[],hashes={},compiled=new Map();
const inPackage=name=>resolve(embedding,name.slice('package/'.length));
const hashOf=path=>createHash('sha256').update(readFileSync(path)).digest('hex');
const helperPath=resolve(embedding,'src/main/ets/util/PasteboardUtils.ets');
const helperHash=hashOf(helperPath);
for(const fix of manifest.fixes)assert([fix.beforeSha256,fix.afterSha256].includes(hashOf(inPackage(fix.target))),'unknown source '+fix.target);
for(const [name,expected]of Object.entries(manifest.consumers))assert.equal(hashOf(inPackage(name)),expected,name);
const plain=value=>JSON.parse(JSON.stringify(value));
const defaults=value=>({__esModule:true,default:value});

function fixture(options={}){
  const state={requests:0,reads:0,conversions:0,logs:[]},modules=new Map();
  const log={e:(...args)=>state.logs.push(args),w:(...args)=>state.logs.push(args),i(){},d(){},v(){}};
  const permission={createAtManager(){
    if(options.createThrow)throw Error('fixture manager throw');
    return{requestPermissionsFromUser(context,names){
      state.requests++;assert.deepEqual(Array.from(names),['ohos.permission.READ_PASTEBOARD']);
      if(options.requestThrow)throw Error('fixture request throw');
      return options.requestReject?Promise.reject(Error('fixture request reject')):
        Promise.resolve({authResults:options.emptyAuth?[]:[options.auth??0]});
    }};
  }};
  const plainRecord=text=>({mimeType:'text/plain',plainText:text});
  let records=options.records??[plainRecord(options.text??'粘贴💡')];
  if(options.legacyHtml)records=[{mimeType:'text/html',htmlText:'<b>fixture-html</b>'}];
  if(options.modern)records=[{getValidTypes(){if(options.typesThrow)throw Error('fixture types throw');return ['text/plain','text/html'];},
    getData(type){if(options.recordReject)return Promise.reject(Error('fixture record reject'));return Promise.resolve(type==='text/plain'?'': '<b>fixture-html</b>');}}];
  const pasteboard={MIMETYPE_TEXT_PLAIN:'text/plain',MIMETYPE_TEXT_HTML:'text/html',getSystemPasteboard(){
    if(options.systemThrow)throw Error('fixture pasteboard throw');
    return {getData(){state.reads++;if(options.readThrow)throw Error('fixture read throw');
      if(options.readReject)return Promise.reject(Error('fixture read reject'));
      return Promise.resolve({getRecordCount(){if(options.countThrow)throw Error('fixture count throw');return records.length;},
        getRecord(index){if(options.recordThrow)throw Error('fixture record throw');return records[index];}});
    }};
  }};
  class ArrayList extends Array {add(value){this.push(value);return true;}clear(){this.length=0;}remove(value){const i=this.indexOf(value);if(i<0)return false;this.splice(i,1);return true;}}
  // Fixed public @ohos.inputMethod.d.ts, API 10+, not invented ordinal values.
  const inputMethod={ExtendAction:{SELECT_ALL:0,CUT:3,COPY:4,PASTE:5}};
  const boundaries={
    '@kit.BasicServicesKit':{pasteboard},'@kit.AbilityKit':{abilityAccessCtrl:permission},
    '@ohos.abilityAccessCtrl':defaults(permission),'@ohos.pasteboard':defaults(pasteboard),
    '@ohos.inputMethod':defaults(inputMethod),'@ohos.util.ArrayList':defaults(ArrayList),
    '@kit.InputKit':{KeyCode:{}},
  };
  function load(path){
    if(modules.has(path))return modules.get(path).exports;
    const module={exports:{}};modules.set(path,module);
    if(!compiled.has(path)){
      const bytes=readFileSync(path);hashes[path]=createHash('sha256').update(bytes).digest('hex');
      compiled.set(path,ts.transpileModule(bytes.toString('utf8'),{fileName:path.replace(/\.ets$/,'.ts'),compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS,esModuleInterop:true}}).outputText);
    }
    function boundary(name){
      if(name in boundaries)return boundaries[name];
      if(name.endsWith('/Log'))return defaults(log);
      if(name.endsWith('/FlutterManager'))return defaults({getInstance:()=>({getUIAbility:()=>({context:{}})})});
      if(name.endsWith('/PasteboardUtils')||name==='./TextEditingDelta')return load(resolve(dirname(path),name+'.ets'));
      // These other imported dependencies are not exercised by PASTE. Fail if one is used.
      return new Proxy({}, {get(_target,key){if(key==='__esModule')return true;throw Error('unadapted boundary '+name+':'+String(key));}});
    }
    vm.runInNewContext(compiled.get(path),{module,exports:module.exports,require:boundary,Map,Set,Promise,Error,
      StyledString:class {static async fromHtml(html){state.conversions++;assert.equal(html,'<b>fixture-html</b>');
        if(options.convertReject)throw Error('fixture conversion reject');return {getString:()=> 'fixture-html'};}}
    },{filename:path});return module.exports;
  }
  const helper=load(helperPath).PasteboardUtils;
  const Editing=load(resolve(embedding,'src/main/ets/plugin/editing/ListenableEditingState.ets')).ListenableEditingState;
  const Platform=load(resolve(embedding,'src/main/ets/plugin/PlatformPlugin.ets')).PlatformPluginCallback;
  return {helper,Editing,Platform,state,inputMethod};
}
async function turns(){for(let i=0;i<3;i++)await nextTurn();}
async function observeCase(name,options,expected,rejected=false){
  const f=fixture(options);let settled=0,value,error;
  f.helper.getPasteDataAsync().then(v=>{settled++;value=v;},e=>{settled++;error=String(e);});await turns();
  const edits=[],editing=new f.Editing(null,1);
  editing.setStringCache('left SELECT right');editing.setSelectionStart(options.reverse?11:5);editing.setSelectionEnd(options.reverse?5:11);
  editing.addEditingStateListener({didChangeEditingState:(...args)=>edits.push(args)});
  const before=plain(editing.captureEditingSnapshot());
  editing.handleExtendActionEvent(f.inputMethod.ExtendAction.PASTE);await turns();
  const afterState=plain(editing.captureEditingSnapshot());
  const observed={name,settled,value,error,before,after:afterState,edits:plain(edits),state:plain(f.state)};
  observations.push(observed);
  assert.equal(settled,1,name+' must settle after all injected platform promises completed');
  if(rejected){assert(error?.includes('fixture'));assert.equal(value,undefined);}else{assert.equal(error,undefined);assert.equal(value,expected);}
  if(expected && !rejected){assert.equal(afterState.text,'left '+expected+' right');assert.equal(afterState.selectionStart,5+expected.length);assert.equal(afterState.selectionEnd,5+expected.length);assert.equal(edits.length,1);
    const deltas=editing.extractBatchTextEditingDeltas();assert.equal(deltas.length,1);assert.equal(deltas[0].toJSON().deltaText,expected);
  }else{assert.deepEqual(afterState,before,'empty/error paste must not delete selection');assert.equal(edits.length,0);assert.equal(editing.extractBatchTextEditingDeltas().length,0);}
  return observed;
}

for(const [name,options]of [
  ['denied',{auth:-1}],['invalid',{auth:2}],['unknown-result',{auth:17}],['empty-results',{emptyAuth:true}],
  ['permission-promise-reject',{requestReject:true}],['read-promise-reject',{readReject:true}],
  ['legacy-html-conversion-reject',{legacyHtml:true,convertReject:true}],['modern-type-query-throw',{modern:true,typesThrow:true}],
  ['record-count-throw',{countThrow:true}],['record-access-throw',{recordThrow:true}],
  ['system-pasteboard-throw',{systemThrow:true}],['read-synchronous-throw',{readThrow:true}],
  ['modern-record-getData-reject-control',{modern:true,recordReject:true}],
  ['modern-conversion-reject-control',{modern:true,convertReject:true}],
  ['empty-content-control',{records:[]}],['unsupported-mime-control',{records:[{mimeType:'application/octet-stream'}]}],
  ['reverse-selection-denial',{auth:-1,reverse:true}],
])test(name,()=>observeCase(name,options,''));
test('synchronous setup rejection remains handled by the actual consumer',()=>observeCase('sync-create',{createThrow:true},'',true));
test('synchronous permission call rejection remains handled by the actual consumer',()=>observeCase('sync-request',{requestThrow:true},'',true));
test('plain-text success still replaces exactly the selected range',()=>observeCase('plain-success',{},'粘贴💡'));
test('HTML success still uses the existing conversion and insertion',()=>observeCase('html-success',{legacyHtml:true},'fixture-html'));
test('modern fallback conversion remains available',()=>observeCase('modern-success',{modern:true},'fixture-html'));
test('multiple records still concatenate in source order',()=>observeCase('multi-success',{records:[{mimeType:'text/plain',plainText:'a'},{mimeType:'text/plain',plainText:'b'}]},'ab'));
test('reverse selection success retains the real consumer range handling',()=>observeCase('reverse-success',{reverse:true},'粘贴💡'));
test('unchanged flutter/platform INVALID_REQ still returns exactly one null without reading',async()=>{
  const f=fixture({auth:2}),callback=Object.create(f.Platform.prototype);callback.uiAbilityContext={};const replies=[];
  callback.getClipboardData({success:value=>replies.push({value}),error:(...error)=>replies.push({error})});await turns();
  assert.deepEqual(replies,[{value:null}]);assert.equal(f.state.reads,0);observations.push({name:'unchanged-platform-null',replies,state:plain(f.state)});
});
after(()=>writeFileSync(outputValue,JSON.stringify({compiler:ts.version,node:process.version,helperHash,sourceHashes:hashes,observations,
  scope:'Actual pinned HAR helper, PlatformPluginCallback, ListenableEditingState and TextEditingDelta. Permission, pasteboard, HTML converter, ArrayList and FlutterManager are explicit boundaries; no device permission/clipboard access.'},null,2)+'\n'));
