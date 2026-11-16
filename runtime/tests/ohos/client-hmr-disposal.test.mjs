// Regression: a real pending HTTP guard resumes after only the HMR plugin retires.
// The sole controlled subsystem is the interval clock; source modules are unmodified.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { createRequire } from 'node:module';
import { connect } from 'node:net';
import { once } from 'node:events';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';
const prefix=resolve(process.env.DSH_TEST_PREFIX);
const require=createRequire(join(prefix,'package.json'));
const load=name=>import(pathToFileURL(require.resolve('@deepseek-ai/'+name)));
const [{Context},{WebServer},{ClientModuleRegistry},hmr]=await Promise.all([
 load('cordis'),load('dsh-host-webserver'),load('dsh-client-modules'),load('dsh-client-hmr')
]);
async function until(predicate,message){
 const deadline=performance.now()+2000;
 while(!predicate()){
  if(performance.now()>=deadline)throw new Error(message);
  await new Promise(r=>setTimeout(r,5));
 }
}
test('a request admitted after HMR-only disposal must not recreate the poll timer',{timeout:5000},async t=>{
 const root=await fs.mkdtemp(join(tmpdir(),'review-hmr-disposal-'));
 const ctx=new Context();let socket,response;
 const intervals=new Set();let fired=0;
 t.mock.timers.enable({apis:['setInterval']});
 const set=globalThis.setInterval,clear=globalThis.clearInterval;
 t.mock.method(globalThis,'setInterval',(callback,ms,...args)=>{
  const timer=set(()=>{if(ms===500)fired++;callback(...args);},ms);
  if(ms===500)intervals.add(timer);
  return timer;
 });
 t.mock.method(globalThis,'clearInterval',timer=>{intervals.delete(timer);return clear(timer);});
 t.after(async()=>{
  socket?.destroy();
  try{await ctx.fiber.dispose();}
  finally{t.mock.restoreAll();t.mock.timers.reset();await fs.rm(root,{recursive:true,force:true});}
 });
 await fs.writeFile(join(root,'package.json'),JSON.stringify({name:'review-hmr-disposal',dsh:{client:{platform:'web'}},exports:{'./client':'./client.js'}}));
 await fs.writeFile(join(root,'index.js'),'');
 await fs.writeFile(join(root,'client.js'),'globalThis.__reviewHmrDisposal=true;');
 const entry={options:{name:pathToFileURL(join(root,'index.js')).href},fiber:{},parent:{tree:{ctx:{baseUrl:pathToFileURL(root+'/').href}}}};
 ctx.provide('loader',{entries:()=>[entry]});
 // Connection is intentionally not yet available, as in the existing closed-response test.
 await ctx.plugin(WebServer,{host:'127.0.0.1',port:0,compression:'none'}).await();
 await ctx.plugin(ClientModuleRegistry).await();
 const hmrFiber=ctx.plugin(hmr,{pollIntervalMs:500});await hmrFiber.await();
 ctx.webServer.server.prependListener('request',(_req,res)=>{response=res;});
 const arrived=once(ctx.webServer.server,'request');
 socket=connect(ctx.webServer.port,'127.0.0.1');socket.on('error',()=>{});
 await once(socket,'connect');socket.write(`GET ${hmr.EVENTS_ENDPOINT} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n`);
 await arrived;
 assert.equal(response.headersSent,false);
 const beforeDispose=intervals.size;
 await hmrFiber.dispose();
 assert.equal(intervals.size,0,'the normal HMR cleanup did retire its existing timer');
 assert.equal(response.destroyed,false,'the pending response is outside the former subscriber collection');
 const routeRemoved=ctx.webServer.match(hmr.EVENTS_ENDPOINT)?.path!==hmr.EVENTS_ENDPOINT;
 ctx.provide('connection',{requestRejection(){}});
 await until(()=>response.headersSent||response.destroyed,'pending route never resumed');
 const afterLateDispatch=intervals.size;
 t.mock.timers.tick(5000);
 console.log(JSON.stringify({scope:'real Host web route, plugin-only disposal, pending Connection guard; fake interval clock',beforeDispose,routeRemoved,hmrFiberUid:hmrFiber.uid,headersSent:response.headersSent,responseDestroyed:response.destroyed,afterLateDispatch,pollCallbacksAfterDispose:fired}));
 assert.equal(afterLateDispatch,0,'late handler must not recreate a polling timer after plugin cleanup');
 assert.equal(fired,0,'disposed HMR must not wake later');
 assert.equal(routeRemoved,true);
 assert.equal(response.statusCode,503,'late request must receive an explicit unavailable response');
 assert.equal(response.writableEnded,true,'late response must finish, not remain pending');
});
