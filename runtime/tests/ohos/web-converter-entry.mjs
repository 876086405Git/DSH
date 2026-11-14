// Actual public Cordis/WebRuntime/ToolRuntime; local HTTP provider only.
// The optional load hook observes real Turndown code and injects named faults.
import assert from 'node:assert/strict';
import http from 'node:http';
import { createRequire, registerHooks } from 'node:module';
import { readFileSync } from 'node:fs';
import { readFile, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { performance } from 'node:perf_hooks';

const prefix=resolve(process.env.DSH_PREFIX),out=resolve(process.env.OHOS_WEB_CONVERTER_OUT);
const mode=process.env.OHOS_WEB_CONVERTER_MODE??'cold';
const timing=mode==='timing',fault=mode.startsWith('fault-')?mode.slice(6):null;
const require=createRequire(join(prefix,'package.json'));
const state={constructs:0,conversions:0,customRuleAttempts:0,faults:0,loads:[],phase:'setup'};
globalThis[Symbol.for('dsh.test.web.converter')]=state;
const report={schema:1,status:'SETUP',node:process.version,mode,hostPlatform:process.platform,
  scope:'Real Cordis public tool registration/execution and local HTTP; optional instrumented real converter, no device/full-host claim',state,checkpoints:[],outputs:[]};
const converterFile=require.resolve('turndown');
const gfmFile=require.resolve('@joplin/turndown-plugin-gfm');
const converterURL=pathToFileURL(converterFile).href;
if(!timing)registerHooks({load(url,context,next){
  const result=next(url,context);
  if(url.includes('/node_modules/turndown/')||url.includes('/node_modules/@joplin/turndown-plugin-gfm/')||url.includes('/node_modules/@mixmark-io/domino/'))state.loads.push({url,phase:state.phase});
  if(url!==converterURL)return result;
  let text=result.source==null?readFileSync(fileURLToPath(url),'utf8'):Buffer.from(result.source).toString();
  const insert=(needle,addition)=>{assert.equal(text.split(needle).length-1,1,needle);text=text.replace(needle,needle+addition);};
  const counter='globalThis[Symbol.for("dsh.test.web.converter")]';
  insert('function TurndownService(options) {',`\n  ${counter}.constructs++;${fault==='constructor'?`if (${counter}.faults++ === 0) throw new Error("explicit constructor fault");`:''}`);
  insert('  turndown: function (input) {',`\n    ${counter}.conversions++;${fault==='conversion'?`if (${counter}.faults++ === 0) throw new Error("explicit conversion fault");`:''}`);
  insert('  addRule: function (key, rule) {',`\n    if(key === "tableRowWithoutSpanExpansion") {${counter}.customRuleAttempts++;${fault==='rule'?`if (${counter}.faults++ === 0) throw new Error("explicit final rule fault");`:''}}`);
  return {...result,source:text};
}});
const observed=()=>({loaded:state.loads.length,constructs:state.constructs,conversions:state.conversions,ruleAttempts:state.customRuleAttempts});
const checkpoint=phase=>{state.phase=phase;report.checkpoints.push({phase,...observed()});};
const load=name=>import(pathToFileURL(require.resolve('@deepseek-ai/'+name)));
const fixtures={
 text:{type:'text/plain',body:'Plain 中文🙂 <b>literal</b>.'},
 deep:{type:'text/html',body:'<div>'.repeat(513)+'secret<script>never expose</script>'+'</div>'.repeat(513)},
 first:{type:'text/html',body:'<h1>标题🙂</h1><p>Visible <strong>bold</strong> <del>old</del> <a href="https://example.test/a">link</a>.</p><script>SECRET_SCRIPT</script><span hidden>SECRET_HIDDEN</span><p style="display:none !important">SECRET_STYLE</p><pre><code>line1\nline2</code></pre>'},
 table:{type:'text/html',body:'<table><thead><tr><th align="left">A|B</th><th style="text-align:right">C</th></tr></thead><tbody><tr><td rowspan="999999">一<br>二</td><td colspan="999999"><del>x</del></td></tr></tbody></table>'},
 malformed:{type:'text/html',body:'<ul><li>one<li>two</ul><p><em>open &amp; 中文🙂'},
 empty:{type:'text/html',body:''},
 unicode:{type:'text/html',body:'<p>'+'a'.repeat(4090)+'🙂tail</p>'},
};
let ctx,plugin,server,origin,failure;
const requests=[];report.publicCallTimings=[];let activeRequests=0,maxInFlight=0;
try {
 assert.equal(process.version,'v24.22.1');
 const began=performance.now();
 const [{Context},{SystemPrompt},{ToolRuntime},native,{WebRuntime},provider,tool]=await Promise.all(['cordis','dsh-system-prompt','dsh-tools','dsh-tool-executor-native','dsh-web','dsh-web-fetch-http','dsh-tool-web'].map(load));
 report.importMs=performance.now()-began;checkpoint('after-import');
 server=http.createServer((req,res)=>{
  const name=new URL(req.url,'http://fixture.invalid').pathname.slice(1),f=fixtures[name];
  const request={name,time:performance.now()};requests.push(request);activeRequests++;maxInFlight=Math.max(maxInFlight,activeRequests);res.once('finish',()=>{request.finished=performance.now();activeRequests--;});
  if(!f){res.writeHead(404);res.end();return;}
  // Two requests deliberately overlap before returning to the synchronous renderer.
  const send=()=>{res.writeHead(200,{'content-type':f.type+'; charset=utf-8'});res.end(f.body);};
  if(name==='first'||name==='table')setTimeout(send,10);else send();
 });await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin=`http://127.0.0.1:${server.address().port}`;
 const canonical=value=>JSON.parse(JSON.stringify(value).replaceAll(origin,'http://fixture.invalid'));
 ctx=new Context();await ctx.plugin(SystemPrompt,{});await ctx.plugin(ToolRuntime,{});await ctx.plugin(native);await ctx.plugin(WebRuntime,{});await ctx.plugin(provider,{maxBodyChars:10000});
 plugin=await ctx.plugin(tool,{fetchMaxOutputChars:4096});
 for(const name of ['web_search','web_fetch']){const t=ctx.tools.get(name);assert(t,name);report[name]={name:t.name,description:t.description,parameters:t.parameters,timeoutMs:t.timeoutMs};}
 checkpoint('after-registration');
 async function execute(name){
  const began=performance.now();
  const signal=new AbortController().signal;
  const toolSet=await ctx.tools.resolve({agent:undefined,modelSelection:{provider:'local-fixture',model:'fixture'},signal});
  try {const batch=await ctx.tools.execute({calls:[{id:'fetch-'+name,name:'web_fetch',arguments:JSON.stringify({url:origin+'/'+name})}],toolSet,signal});const result=batch.results[0].result;assert.equal(result.isError,false,JSON.stringify(result));return canonical(result);}finally{toolSet.dispose();report.publicCallTimings.push({name,durationMs:performance.now()-began});}
 }
 report.outputs.push({case:'text',value:await execute('text')});checkpoint('after-text');
 report.outputs.push({case:'deep',value:await execute('deep')});checkpoint('after-depth-rejection');
 assert(report.outputs[1].value.content[0].text.includes('[HTML content omitted: unable to convert safely.]'));
 if(!timing&&mode!=='oracle')assert.equal(state.loads.length,0,'HTML_CONVERTER_LOADED_BEFORE_HTML');
 if(fault){
  const first=await execute('first');assert(first.content[0].text.includes('[HTML content omitted: unable to convert safely.]'));assert(!first.content[0].text.includes('SECRET_SCRIPT'));
  report.firstFaultState=observed();assert.equal(state.constructs,1,'render/presentationMeta must not retry a failed frozen result');
  assert.equal(state.conversions,fault==='conversion'?1:0);
  const second=await execute('first');assert(second.content[0].text.includes('# 标题🙂'));assert(!second.content[0].text.includes('SECRET_SCRIPT'));
  assert.equal(state.constructs,fault==='conversion'?1:2);assert.equal(state.customRuleAttempts,fault==='constructor'?1:fault==='rule'?2:1);
  report.outputs.push({case:'injected-failure',value:first},{case:'recovered-new-result',value:second});
  report.recovered=true;checkpoint('after-fault-recovery');
 } else {
  const firstStart=performance.now();
  const values=await Promise.all([execute('first'),execute('table')]);
  report.firstHTMLPairMs=performance.now()-firstStart;report.firstHTMLCallMs=report.publicCallTimings.find(row=>row.name==='first').durationMs;assert.equal(maxInFlight,2,'both real provider requests must overlap before conversion');
  report.outputs.push({case:'first',value:values[0]},{case:'table',value:values[1]});
  assert(values[0].content[0].text.includes('# 标题🙂'));assert(!/SECRET_SCRIPT|SECRET_HIDDEN|SECRET_STYLE/.test(values[0].content[0].text));assert(values[1].content[0].text.includes('\\|'));
  if(!timing){assert.equal(state.constructs,1);assert.equal(state.customRuleAttempts,1);assert.equal(state.conversions,2);}
  checkpoint('after-first-html-pair');
  const again=performance.now();report.outputs.push({case:'first-repeat',value:await execute('first')});report.repeatedHTMLMs=performance.now()-again;
  for(const name of ['malformed','empty','unicode'])report.outputs.push({case:name,value:await execute(name)});
  const frozen=Object.freeze({url:'http://fixture.invalid/cache',statusCode:200,body:Object.freeze({kind:'html',content:'<h2>cache🙂</h2><p>same frozen result</p>'}),truncated:false});
  const before=state.conversions;const text=tool.formatFetchOutput(frozen,4096);const meta=tool.fetchMetaFromValue(frozen,4096);assert.equal(tool.formatFetchOutput(frozen,4096),text);assert.equal(meta.truncated,false);
  if(!timing)assert.equal(state.conversions,before+1,'render plus presentationMeta must reuse the original WeakMap result');
  report.cache={text,meta,conversions:timing?null:state.conversions-before};
  checkpoint('after-cache-check');
  if(mode!=='oracle'){const golden=JSON.parse(await readFile(new URL('./web-converter-golden.json',import.meta.url),'utf8'));assert.deepEqual(report.outputs,golden.outputs);assert.deepEqual({web_search:report.web_search,web_fetch:report.web_fetch},golden.registration);assert.deepEqual({text:report.cache.text,meta:report.cache.meta},golden.cache);report.matchesBaselineGolden=true;}
 }
 await plugin.dispose();plugin=undefined;assert.equal(ctx.tools.get('web_fetch'),undefined);assert.equal(ctx.tools.get('web_search'),undefined);report.unregistered=true;
 report.requests=requests.map(({name})=>name);report.httpTrace=requests;report.maxInFlight=maxInFlight;assert.equal(activeRequests,0);report.converter={path:converterFile,gfm:gfmFile};report.status='PASS_SCOPED_WEB_CONVERTER';
} catch(error){failure=error;report.status='FAILED';report.error={name:error.name,code:error.code,message:error.message,stack:error.stack};}
finally{
 if(ctx)await ctx.fiber.dispose();
 if(server){server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
 await writeFile(join(out,'REPORT.json'),JSON.stringify(report,null,2)+'\n');
 console.log(JSON.stringify({status:report.status,mode,constructs:state.constructs,conversions:state.conversions,importMs:report.importMs,firstHTMLPairMs:report.firstHTMLPairMs,error:report.error?.message}));
 if(failure)process.exitCode=1;
}
