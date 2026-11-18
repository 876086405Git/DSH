import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { loadLinuxNative } from '../../../../runtime/ohos/linux/native-session.mjs';
const [directory,config]=process.argv.slice(2);
const native=loadLinuxNative({nativeLibraryDirectory:directory});const vm=native.create(config);
let buffer='',seq=0,raw='';const events=[],waiting=[];const epoch='01'.repeat(32);
vm.socket.on('error',e=>{while(waiting.length)waiting.shift().reject(e);});
vm.socket.on('data',chunk=>{raw+=chunk.toString();buffer+=chunk.toString();for(;;){let end=buffer.indexOf('\n');if(end<0)break;const line=buffer.slice(0,end).trimEnd();buffer=buffer.slice(end+1);if(!line.startsWith('DSHG1 '))continue;const ev=JSON.parse(line.slice(6));assert.equal(ev.epoch,epoch);assert.equal(ev.seq,++seq);if(waiting.length)waiting.shift().resolve(ev);else events.push(ev);}});
function next(){if(events.length)return Promise.resolve(events.shift());return new Promise((resolve,reject)=>waiting.push({resolve,reject}));}
function send(op,rest={}){vm.socket.write(JSON.stringify({v:1,epoch,op,...rest})+'\n');}
const deadline=setTimeout(()=>{vm.requestStop();vm.socket.destroy(Error('guest deadline'));},120000);
try {
 assert.equal((await next()).kind,'opened');
 assert.ok(raw.includes('__909_HANDOFF__'));
 let job=0;
 for(const argv of [['python3','-c','print(1)'],['gh','--version'],['git','--version'],['rg','needle','/workspace/needle.txt']]){
  job++;send('start',{job,argv,cwd:'/workspace',env:{PATH:'/usr/bin:/bin',HOME:'/workspace',LANG:'C.UTF-8'}});send('stdin-end',{job});
  const outputs={stdout:[],stderr:[]},eofs=new Set();
  for(;;){const ev=await next();if(ev.kind==='data'){const bytes=Buffer.from(ev.data,'base64');outputs[ev.stream].push(bytes);send('ack',{job,stream:ev.stream,through:String(BigInt(ev.offset)+BigInt(bytes.length))});}
   if(ev.kind==='eof')eofs.add(ev.stream);
   assert.notEqual(ev.kind,'failed');
   if(ev.kind==='complete'){assert.equal(ev.exitCode,0);assert.deepEqual([...eofs].sort(),['stderr','stdout']);break;}}
  console.log(JSON.stringify({tool:argv[0],stdout:Buffer.concat(outputs.stdout).toString(),stderr:Buffer.concat(outputs.stderr).toString(),eof:true}));
 }
 send('close');assert.equal((await next()).kind,'closed');
} finally {clearTimeout(deadline);vm.requestStop();const result=await vm.join();assert.equal(result.joined,true);assert.equal(result.apiResult,-4);vm.socket.destroy();console.log(JSON.stringify({nodeNativeGuest:true,...result}));}
