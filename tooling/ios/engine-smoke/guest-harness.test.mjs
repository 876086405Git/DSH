// Tests the test-driver's strict oracle/model parser, never replaces production approval.
// Keep the pure diagnostics suite in the workflow's existing explicit entrypoint.
import './guest-diagnostics.test.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import {startGuestModel} from './guest-model.mjs';
import {verifyApproval,verifyAudit} from './guest-assertions.mjs';
test('approval oracle refuses wrong agent, tool, call and missing expected identity',()=>{
 const good={agentId:'session',request:{toolName:'bash',callId:'call'}};
 verifyApproval(good,'session','call');
 for(const value of [{...good,agentId:'other'},{...good,request:{toolName:'write',callId:'call'}},{...good,request:{toolName:'bash',callId:'other'}}])assert.throws(()=>verifyApproval(value,'session','call'));
 assert.throws(()=>verifyApproval(good,'session',undefined));
});
test('audit oracle requires one matching pair inside one persisted turn',()=>{
 const rows=[{type:'turn/start'},{type:'approval/asked',data:{id:'a',callId:'c'}},{type:'approval/decided',data:{id:'a',outcome:'allowed-once'}},{type:'turn/end'}];
 verifyAudit(rows,'c','allowed-once');
 assert.throws(()=>verifyAudit(rows,'different','allowed-once'));
 assert.throws(()=>verifyAudit(rows,'c','rejected'));
 assert.throws(()=>verifyAudit([rows[0],rows[1],rows[3],rows[0],rows[2],rows[3]],'c','allowed-once'));
 assert.throws(()=>verifyAudit([...rows,rows[1]],'c','allowed-once'));
});
test('SSE peer emits only deterministic bash tool calls, never approval decisions',async()=>{
 const model=await startGuestModel('/synthetic');
 try {
  for(const mode of ['deny','identity','osrelease','apkpath','pipeline','full','rootreadonly','rootdeny','rootallow','rootafter','exit','cancel','after']){
   const messages=[{role:'user',content:`[DSH_IOS_SMOKE:${mode}]`}];
   const call=async msgs=>{const r=await fetch(model.baseURL+'/chat/completions',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({stream:true,messages:msgs,tools:[{function:{name:'bash'}}]})});assert.equal(r.status,200);return (await r.text()).split('\n').filter(l=>l.startsWith('data: {')).map(l=>JSON.parse(l.slice(6)));};
   const frames=await call(messages),parts=frames.flatMap(f=>f.choices[0].delta.tool_calls??[]);
   assert.equal(parts[0].function.name,'bash');assert.equal(parts[0].id,model.calls.get(mode));
   const args=JSON.parse(parts.map(p=>p.function.arguments??'').join(''));
   assert.equal(args.sandbox_permissions,mode==='full'?'danger-full-access':'workspace-write');
   assert.equal(Object.hasOwn(args,'linux_root_write'),mode==='rootdeny'||mode==='rootallow');
   const probes={osrelease:'cat /etc/os-release',apkpath:'command -v apk',pipeline:"cat /etc/os-release | grep '^ID='",full:'apk --version'};
   if(Object.hasOwn(probes,mode))assert.equal(args.command,probes[mode]);
   else assert.ok(args.command.startsWith('/bin/sh -c'));
   assert.equal(JSON.stringify(args).includes('allowed-once'),false);
   const done=await call([...messages,{role:'tool',content:'real tool result',tool_call_id:parts[0].id}]);
   assert.equal(done.some(f=>f.choices[0].delta.tool_calls),false);
  }
 }finally{await model.close();}
});
test('audit oracle requires independent ordered workspace and root decisions',()=>{
 const begin={type:'turn/start'},end={type:'turn/end'};
 const ask=id=>({type:'approval/asked',data:{id,callId:'c'}});
 const decide=(id,outcome)=>({type:'approval/decided',data:{id,outcome}});
 const workspace=ask('workspace'),root=ask('root');
 const workspaceAllowed=decide('workspace','allowed-once'),rootRejected=decide('root','rejected');
 const rows=[begin,workspace,workspaceAllowed,root,rootRejected,end];
 verifyAudit(rows,'c',['allowed-once','rejected']);
 assert.throws(()=>verifyAudit(rows,'c',['allowed-once','allowed-once']));
 assert.throws(()=>verifyAudit(rows,'c',['allowed-once']));
 assert.throws(()=>verifyAudit([begin,workspace,root,workspaceAllowed,rootRejected,end],'c',['allowed-once','rejected']));
 assert.throws(()=>verifyAudit([begin,workspace,workspaceAllowed,end,begin,root,rootRejected,end],'c',['allowed-once','rejected']));
});
