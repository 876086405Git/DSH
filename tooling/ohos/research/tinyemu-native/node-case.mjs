import assert from 'node:assert/strict';
import { readFile, readdir, readlink } from 'node:fs/promises';
import { openSync, closeSync } from 'node:fs';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { loadLinuxNative } from '../../../../runtime/ohos/linux/native-session.mjs';
const [directory,config,mode]=process.argv.slice(2);
const native=loadLinuxNative({nativeLibraryDirectory:directory});
const module={exports:{}};process.dlopen(module,`${directory}/libdsh_linux.so`);
if(mode==='construct-failure') {
 const held=[];try{for(;;)held.push(openSync('/dev/null','r'));}catch(e){assert.equal(e.code,'EMFILE');}
 assert.throws(()=>module.exports.create(config),{code:'ERR_OHOS_LINUX_CREATE'});
 for(const fd of held)closeSync(fd);
}
assert.throws(()=>module.exports.create('relative'),{code:'ERR_OHOS_LINUX_CONFIG'});
assert.throws(()=>module.exports.create('/bad\0path'),{code:'ERR_OHOS_LINUX_CONFIG'});
const session=native.create(config);let bytes=0,output='';let error;
session.socket.on('error',e=>{error=e;});
if(mode!=='unread-output')session.socket.on('data',b=>{bytes+=b.length;output+=b.toString();});
assert.throws(()=>session.join(),{code:'ERR_OHOS_LINUX_STOP_REQUIRED'});
// With UV_THREADPOOL_SIZE=1 this completes while the VM remains live.
await Promise.race([readFile(config),delay(2000).then(()=>{throw Error('VM occupies libuv worker');})]);
if(mode==='normal'||mode==='construct-failure') {
 const deadline=Date.now()+3000;while(!output.includes('900-BEFORE-POWEROFF')&&Date.now()<deadline)await delay(5);
 assert.match(output,/900-BEFORE-POWEROFF/);
} else if(mode==='fatal') {
 const deadline=Date.now()+5000;while(!session.socket.destroyed&&Date.now()<deadline)await delay(5);
 assert.equal(session.socket.destroyed,true);
} else await delay(100);
const started=Date.now();session.requestStop();const joined=session.join();assert.equal(session.join(),joined);
const result=await Promise.race([joined,delay(3000).then(()=>{throw Error('explicit join timeout');})]);
assert.equal(result.joined,true);assert.equal(result.ownerQuarantined,true);
assert.equal(result.retirementError,false);
if(mode==='fatal'){assert.equal(result.apiResult,-9);assert.equal(result.fatalReason,1);}
else assert.equal(result.apiResult,-4);
assert.throws(()=>native.create(config),{code:'ERR_OHOS_LINUX_OWNER_QUARANTINED'});
session.socket.destroy();
await delay(10);
const fds=[];for(const fd of await readdir('/proc/self/fd')){try{const path=await readlink(`/proc/self/fd/${fd}`);if(path.endsWith('/disk.raw'))fds.push({fd,path});}catch{}}
assert.deepEqual(fds,[]);
assert.equal(error,undefined);
console.log(JSON.stringify({hostSurvived:true,mode,bytes,joinMs:Date.now()-started,...result}));
