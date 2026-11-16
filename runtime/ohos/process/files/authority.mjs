import {isMainThread} from 'node:worker_threads';
import {randomBytes} from 'node:crypto';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
export function loadGrantBinding(){return require('@dsh-go/ohos-native').load('workspace-grants').binding;}
const fail=code=>Object.assign(new Error(code),{code});
// Fixed main preload must call this before any plugin or user Worker admission.
// Native owner is permanent for this process and cannot be re-bound after death.
export function createGrantAuthority({hostLibrary,binding=loadGrantBinding()}={}){
 if(!isMainThread)throw fail('ERR_WORKSPACE_OWNER');binding.bindOwner(hostLibrary);
 let closed=false;const active=new Set();
 return Object.freeze({
  snapshot(){
   if(closed)throw fail('ERR_WORKSPACE_OWNER');
   const seen=new Set();const rows=binding.snapshot();
   if(!Array.isArray(rows)||rows.length>128)throw fail('ERR_WORKSPACE_SNAPSHOT');
   return Object.freeze(rows.map(row=>{
    const match=typeof row.id==='string'&&row.id.length<=128&&row.id.match(/^.+:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/);
    if(!match||row.id.includes('\0')||!Number.isSafeInteger(row.generation)||row.generation<=0||typeof row.writable!=='boolean')throw fail('ERR_WORKSPACE_SNAPSHOT');
    const mountPoint='/workspaces/'+match[1];if(seen.has(mountPoint))throw fail('ERR_WORKSPACE_SNAPSHOT');seen.add(mountPoint);
    return Object.freeze({id:row.id,generation:row.generation,writable:row.writable,mountPoint});
   }));
  },
  issue(grants,{readOnly=false,workspaceRoot}={}){
   if(closed)throw fail('ERR_WORKSPACE_OWNER');
   if(!Array.isArray(grants)||grants.length!==1||workspaceRoot!==grants[0]?.mountPoint)throw fail('ERR_WORKSPACE_SCOPE_UNSUPPORTED');
   const records=[];
   try{for(const grant of grants){
    if(!/^\/workspaces\/[0-9a-f-]{36}$/.test(grant.mountPoint)||typeof grant.id!=='string'||!Number.isSafeInteger(grant.generation)||grant.generation<=0)throw fail('ERR_WORKSPACE_MOUNT');
    const ticket=randomBytes(32).toString('hex');binding.issue(ticket,grant.id,grant.generation,!readOnly&&grant.writable===true);
    records.push(Object.freeze({mountPoint:grant.mountPoint,ticket}));
   }}catch(error){for(const record of records)binding.retire(record.ticket);throw error;}
   let finished=false;
   const job=Object.freeze({mounts:Object.freeze(records),
    retire(){let drained=true;for(const record of records)drained=binding.retire(record.ticket)===1&&drained;
      if(drained){finished=true;active.delete(job);}return drained;},
    get drained(){return finished;},
   });active.add(job);return job;
  },
  close(){closed=true;let drained=true;for(const job of [...active])drained=job.retire()&&drained;return drained;},
 });
}
