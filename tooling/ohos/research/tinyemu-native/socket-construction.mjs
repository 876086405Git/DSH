import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, readdir, readlink, rm } from 'node:fs/promises';
import { closeSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [directory,config,closeFailure,sourceOverride]=process.argv.slice(2);
async function sockets(){const result=new Set();for(const fd of await readdir('/proc/self/fd')){try{if((await readlink(`/proc/self/fd/${fd}`)).startsWith('socket:'))result.add(Number(fd));}catch{}}return result;}
const temp=await mkdtemp(join(tmpdir(),'linux-adoption-'));let remaining=[];
try {
 const source=await readFile(sourceOverride ?? new URL('../../../../runtime/ohos/linux/native-session.mjs',import.meta.url),'utf8');
 assert.ok(source.includes("import { Socket } from 'node:net';"));
 let isolated=source.replace("import { Socket } from 'node:net';","import { Socket } from './net-fixture.mjs';");
 if(closeFailure==='yes')isolated=isolated.replace("import { closeSync } from 'node:fs';","import { closeSync } from './close-fixture.mjs';");
 await writeFile(join(temp,'native-session.mjs'),isolated);
 await writeFile(join(temp,'net-fixture.mjs'),'export class Socket { constructor() { throw Object.assign(new Error("test adoption failure"),{code:"TEST_ADOPTION"}); } }');
 await writeFile(join(temp,'close-fixture.mjs'),'export function closeSync() { throw Object.assign(new Error("test close failure"),{code:"TEST_CLOSE"}); }');
 const {loadLinuxNative}=await import(pathToFileURL(join(temp,'native-session.mjs')));
 const native=loadLinuxNative({nativeLibraryDirectory:directory});const before=await sockets();let caught;
 try{native.create(config);}catch(error){caught=error;}
 assert.equal(caught?.code,'TEST_ADOPTION');assert.ok(caught.linuxJoin instanceof Promise);
 const result=await caught.linuxJoin;assert.equal(result.joined,true);assert.equal(result.ownerQuarantined,true);
 remaining=[...await sockets()].filter(fd=>!before.has(fd));assert.equal(remaining.length,closeFailure==='yes'?1:0);
 if(closeFailure==='yes'){assert.equal(caught.linuxFdCloseError.code,'TEST_CLOSE');assert.equal(caught.linuxUnsettledFd,remaining[0]);}
 console.log(JSON.stringify({adoptionFailed:true,closeFailure,joinStillObserved:true,remainingCallerSockets:remaining.length,...result}));
} finally {for(const fd of remaining)closeSync(fd);await rm(temp,{recursive:true,force:true});}
