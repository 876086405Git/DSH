// Standalone fd ownership smoke; Simulator shares this Mac's filesystem.
// Build with build-fd.sh, then pass the already prepared f9d0bd3+ frameworks.
import {spawn} from 'node:child_process';
import {mkdirSync,writeFileSync,realpathSync} from 'node:fs';
import {resolve,join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
const {values}=parseArgs({options:Object.fromEntries(
 ['simulator','smoke','frameworks','work','runs','linux-preload','library','native-dir'].map(k=>[k,{type:'string'}]))});
for(const k of ['smoke','work'])if(!values[k])throw new Error(`--${k} required`);
if(!values['linux-preload']&&(!values.simulator||!values.frameworks))throw new Error('--simulator and --frameworks required');
if(values['linux-preload']&&!values.library)throw new Error('--library required for Linux verification');
const runs=Number(values.runs??5);
if(!Number.isInteger(runs)||runs<1||runs>20)throw new Error('--runs must be 1..20');
const work=resolve(values.work);mkdirSync(work,{mode:0o700});
const root=realpathSync(work),preload=join(root,'runtime/ohos/preload.mjs');
mkdirSync(join(root,'runtime/ohos'),{recursive:true,mode:0o700});
writeFileSync(preload,'// Empty diagnostic preload; preserves the product runner path contract.\n',{mode:0o600});
const library=values.library?resolve(values.library):join(resolve(values.frameworks),'DshNodeHost.framework/DshNodeHost');
const argv=[library,join(root,'fixture'),preload,fileURLToPath(new URL('./fd-main.mjs',import.meta.url)),String(runs)];
const nativeDirectory=resolve(values['native-dir']??values.frameworks??dirname(library));
const env={...process.env,DSH_GO_OHOS_NATIVE_LIBRARY_DIR:nativeDirectory,SIMCTL_CHILD_DSH_GO_OHOS_NATIVE_LIBRARY_DIR:nativeDirectory};
for(const k of ['NODE_OPTIONS','DSH_IOS_SMOKE_PATCH','DSH_IOS_SMOKE_IMPORT']){delete env[k];delete env['SIMCTL_CHILD_'+k];}
let command,args;
if(values['linux-preload']) {command=resolve(values.smoke);args=argv;env.LD_PRELOAD=resolve(values['linux-preload']);}
else {command='xcrun';args=['simctl','spawn',values.simulator,resolve(values.smoke),...argv];}
const report={status:'BLOCKED',scope:values['linux-preload']?'Linux official Node embedder; NOT NodeMobile':'iOS Simulator real prepared framework',expected:'f9d0bd3 raw-fd retention; host fd preservation',command:[command,...args],nativeDirectory,runs,rows:[],errors:[],exit:null};
const child=spawn(command,args,{env,stdio:['ignore','pipe','pipe']});
let stdout='',stderr='';
const deadline=setTimeout(()=>{report.errors.push('simctl/observer deadline');child.kill('SIGKILL');},(120*runs+60)*1000);
child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);
await new Promise(done=>{child.once('error',e=>{report.errors.push(e.message);done();});child.once('exit',(code,signal)=>{report.exit={code,signal};done();});});
clearTimeout(deadline);
for(const line of stdout.split('\n').filter(Boolean)) {
 try{report.rows.push(JSON.parse(line));}catch{report.errors.push('unexpected non-JSON stdout');}
}
const control=report.rows.filter(r=>r.control==='occupied-target');
const rounds=report.rows.filter(r=>Number.isInteger(r.run));
const valid=report.exit?.code===0&&report.errors.length===0&&control.length===1&&control[0].checkedAbsent===true&&control[0].prepared===false&&control[0].ownerPreserved===true&&control[0].pass===true&&rounds.length===runs&&new Set(rounds.map(r=>r.pid)).size===1&&rounds.every((r,i)=>r.run===i+1&&r.pid>0&&r.prepared&&r.stopRequested===1&&r.engineCode===0&&r.ownedClosed===2&&r.ownedStillOpen===16&&r.ownedNumberReused===0&&r.sentinels===8&&r.sentinelsLost===0&&r.hostSourceAlive&&r.rawOpenTotal===16*(i+1)&&r.rawStillOpen===16&&r.fileHandleClosed===2&&r.fileHandleStillOpen===0&&r.pass===true);
if(valid)report.status='PASS';
writeFileSync(join(root,'stdout.log'),stdout);writeFileSync(join(root,'stderr.log'),stderr);
writeFileSync(join(root,'report.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({status:report.status,exit:report.exit,runs:rounds,errors:report.errors},null,2));
process.exitCode=valid?0:1;
