// Invoked twice by Python as separate OS processes, with the same private test directory.
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve,join } from 'node:path';
import { diagnosticsFixture } from './diagnostics-fixture.mjs';
const [mode,rootValue,outputValue]=process.argv.slice(2);
assert(['write','read'].includes(mode));assert(rootValue && outputValue);
const root=resolve(rootValue),output=resolve(outputValue),cleanup=[];
const f=await diagnosticsFixture({after:fn=>cleanup.push(fn)},{persistRoot:root});
const expected=['survives real process exit','known [REDACTED]','http://localhost/?token=[REDACTED]'];
if(mode==='write'){
  f.logs.rememberSecret('synthetic-survive-token');
  f.append(['survives real process exit','known synthetic-survive-token','http://localhost/?token=synthetic-url-token']);
  await f.store.flush();
}else{
  assert.equal(f.logs.snapshot(2000).entries.length,0);
  const before=JSON.parse(await readFile(join(output,'cold-write.json'),'utf8'));
  assert.notEqual(process.pid,before.pid,'actual separate processes');
}
const lines=Array.from(await f.store.tail(512*1024));assert.deepEqual(lines,expected);assert.equal(f.fds.size,0);
const bytes=await readFile(f.path,'utf8');assert(!bytes.includes('synthetic-survive-token')&&!bytes.includes('synthetic-url-token'));
await writeFile(join(output,'cold-'+mode+'.json'),JSON.stringify({mode,pid:process.pid,lines,fdAfter:f.fds.size,
  diskBytes:Buffer.byteLength(bytes),memoryLogEntries:f.logs.snapshot(2000).entries.length,
  scope:'Actual OS process exit/restart with actual Linux files. OH API adapter; not an OH device restart.'},null,2)+'\n');
for(const fn of cleanup)await fn();
console.log('PASS actual separate-process persisted log '+mode);
