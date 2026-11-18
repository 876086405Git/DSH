// Two distinct Node processes execute the actual ETS store against the same files.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {join} from 'node:path';
import {diagnosticsFixture} from './diagnostics-fixture.mjs';

const [mode, root] = process.argv.slice(2), cleanup = [];
assert(['write','read'].includes(mode)); assert(root);
const f = await diagnosticsFixture({after:callback=>cleanup.push(callback)}, {persistRoot:root});
const path = '/data/storage/el2/log/hiappevent/APP_CRASH_500_9.log';
if(mode==='write') {
  await fs.mkdir(f.faultDirectory); await fs.writeFile(join(f.faultDirectory,'APP_CRASH_500_9.log'),'synthetic unexported trace');
  f.change({unlink:()=>{throw Error('synthetic interrupted cleanup');}});
  for(let at=1000;at<1008;at++)f.faults.queue.push({domain:'OS',name:'APP_CRASH',eventType:1,params:{time:at,crash_type:'NativeCrash'}});
  f.faults.queue.push({domain:'OS',name:'APP_CRASH',eventType:1,params:{time:500,crash_type:'NativeCrash',external_log:[path]}});
}
const i = f.attach();
if(mode==='write') {
  assert.deepEqual(await f.call(i,'recordAppError',{source:'flutter',errorType:'StateError',stack:'package:dsh_app/main.dart:1:2'}).done,{value:null});
  assert.deepEqual(await f.call(i,'recordVoiceStage',{stage:'failed',backend:'system',code:7}).done,{value:null});
}
const result = await f.call(i,'info').done, evidence = result.value.evidence;
assert.equal(evidence.appErrors.length,1);assert.equal(evidence.voiceStages.length,1);assert.equal(evidence.processExits.length,8);
assert.deepEqual(evidence.processExits.map(row=>row.at),[1000,1001,1002,1003,1004,1005,1006,1007]);
assert.equal(evidence.availability.processExits,mode==='write'?'unavailable':'available');
const stored=await fs.readFile(join(f.app.filesDir,'diagnostic-evidence','processExits.json'),'utf8');
assert(Buffer.byteLength(stored)<=8*1024);assert.equal(JSON.parse(stored).length,mode==='write'?9:8);
if(mode==='write')assert(stored.includes(path),'late cleanup debt survives the actual process exit');
if(mode==='read') {
  await assert.rejects(fs.stat(join(f.faultDirectory,'APP_CRASH_500_9.log')),{code:'ENOENT'});
  assert(!(await fs.readFile(join(f.app.filesDir,'diagnostic-evidence','processExits.json'),'utf8')).includes(path));
}
assert(!JSON.stringify(evidence).includes(path));assert.equal(f.fds.size,0);i.detach();
for(const callback of cleanup)await callback();
console.log('PASS cold '+mode+': actual ETS records, eight newer metadata rows and one older bounded cleanup journal');
