import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { loadLinuxNative } from '../../../../runtime/ohos/linux/native-session.mjs';
const [directory,config,mode]=process.argv.slice(2);const native=loadLinuxNative({nativeLibraryDirectory:directory});
const vm=native.create(config);vm.socket.on('error',()=>{});await delay(30);vm.requestStop();
if(mode==='1')assert.throws(()=>vm.join(),{code:'ERR_OHOS_LINUX_JOIN'});
const promise=vm.join();assert.equal(vm.join(),promise);const result=await promise;
if(mode==='1'){assert.equal(result.joined,true);assert.equal(result.apiResult,-4);}
else{assert.equal(result.joined,false);assert.equal(result.apiResult,null);assert.equal(result.fatalReason,null);assert.equal(result.retirementError,null);}
assert.equal(result.ownerQuarantined,true);assert.throws(()=>native.create(config),{code:'ERR_OHOS_LINUX_OWNER_QUARANTINED'});
vm.socket.destroy();console.log(JSON.stringify({faultMode:mode,...result}));
