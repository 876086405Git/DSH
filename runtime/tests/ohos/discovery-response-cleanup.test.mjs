// Supplementary adapter-region regression. The public Dart lifecycle oracle is
// exercised separately against an actual composed payload; this is not it.
import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import {resolve, join} from 'node:path';
import http from 'node:http';
import {createHttpDispatcher} from '../../ohos/net/dispatcher.mjs';
import {createFetch} from '../../ohos/net/fetch.mjs';

assert(process.env.DSH_DISCOVERY_PREFIX, 'DSH_DISCOVERY_PREFIX must identify actual locked DSH input');
const prefix = resolve(process.env.DSH_DISCOVERY_PREFIX);
const source = await readFile(join(prefix, 'node_modules/@deepseek-ai/dsh-llm-pi-ai/lib/index.js'), 'utf8');
const digest = createHash('sha256').update(source).digest('hex');
// Upstream, the common chain (main's piai-discovery-response-cancel.diff now carries
// the cleanup), the reviewed OH attachment follow-up, and the OH empty-models
// collection change, plus OH text-only pre-abort. Both leave this discovery
// region byte-identical; their complete adapter bytes are admitted explicitly.
assert(['1a3ae58f9b4493e15459cc5000ec80f21b5d3f4a9dea6ffb6bc28e5b8817ae8a',
        '71bef2194ebc72d9d86a0ce3a0fe24345b808208a4752fb077f71cf6603b04aa',
        '083ff174256a8166633c1f655720aaab897368ea5e1a553cdcec7b0fa329202a',
        '25f7f6eb315754950170bd26ef0710fce3cf48d3046647c8eed9f64e7a72ab0b',
        '762e49300daac811c36184c9cb8ba44460de7fb5bacca06bc0c1b377cb192be1'].includes(digest), 'unreviewed adapter bytes');
const require = createRequire(join(prefix, 'package.json'));
const {LlmError} = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-llm')).href);
const begin = 'const LISTABLE_PROTOCOLS = new Set([';
const end = '\n//#endregion\n//#region lib/types/login.js';
assert.equal(source.split(begin).length, 2);
assert.equal(source.split(end).length, 2);
const region = source.slice(source.indexOf(begin), source.indexOf(end));
// Preserve the real function bytes. Scope only its fetch dependency; no global
// fetch mutation. Drafts omit provider/key so catalog/credential paths stay out.
const factory = new Function('fetch', 'LlmError', 'attributionHeaders', region + '\nreturn discoverModels;');
const load = fetchImpl => factory(fetchImpl, LlmError, () => ({}));
const request = {baseURL:'http://127.0.0.1/draft/v1', api:'openai-completions'};
const rejection = (status, url=request.baseURL+'/models') => error => {
  assert(error instanceof LlmError);
  assert.equal(error.code, 'DISCOVERY_FAILED');
  assert.equal(error.message, `${url} answered ${status}${status===401||status===403?'; check the API key':''}`);
  return true;
};

for (const status of [401,403,500]) test(`rejected native Response ${status} cancels body and preserves original error`, async () => {
  let cancelled = 0;
  const response = new Response(new ReadableStream({cancel(){cancelled++;}}), {status});
  await assert.rejects(load(async()=>response)(request), rejection(status));
  assert.equal(cancelled, 1);
});

test('cancel rejection does not replace HTTP failure or escape as unhandled rejection', async () => {
  let cancelled = 0;
  const response = new Response(new ReadableStream({cancel(){cancelled++;throw Error('cleanup refused');}}), {status:401});
  await assert.rejects(load(async()=>response)(request), rejection(401));
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(cancelled, 1);
});

test('empty error body retains original HTTP failure', async () => {
  await assert.rejects(load(async()=>new Response(null,{status:403}))(request), rejection(403));
});

test('successful native Response is consumed and parsed before cleanup', async () => {
  const response = new Response(JSON.stringify({data:[{id:'model-a'},{id:'model-b'}]}));
  const models = await load(async()=>response)(request);
  assert.deepEqual(models.map(model=>model.id), ['model-a','model-b']);
  assert.equal(response.bodyUsed, true);
});

async function fixture(status, body) {
  let response, clean = false, closeInfo;
  const requests=[];
  let notifyClose;
  const closed=new Promise(resolve=>notifyClose=resolve);
  const server=http.createServer((req,res)=>{
    requests.push({method:req.method,url:req.url});response=res;
    res.on('close',()=>{closeInfo={beforeCleanup:!clean,ended:res.writableEnded};notifyClose(closeInfo);});
    res.writeHead(status,{'content-type':'application/json'});res.write(body);
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  return {url:`http://127.0.0.1:${server.address().port}/v1`,requests,closed,
    async close(){clean=true;server.closeAllConnections();await new Promise(resolve=>server.close(resolve));},
    info(){return {closeInfo,ended:response?.writableEnded};}};
}
async function within(promise, milliseconds) {
  let timer;
  try{return await Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('response did not close in existing ten-second observation bound')),milliseconds);})]);}
  finally{clearTimeout(timer);}
}

test('real HTTP 401 held body closes before fixture cleanup with original error intact', {timeout:15000}, async () => {
  const server=await fixture(401, 'x'.repeat(65536));
  const dispatcher=createHttpDispatcher();
  try {
    await assert.rejects(load(createFetch(dispatcher))({...request,baseURL:server.url}), rejection(401,server.url+'/models'));
    assert.deepEqual(await within(server.closed,10000),{beforeCleanup:true,ended:false});
    assert.deepEqual(server.requests,[{method:'GET',url:'/v1/models'}]);
  } finally {await server.close();await dispatcher.close();}
});

test('caller abort before fetch remains ABORTED', async () => {
  const dispatcher=createHttpDispatcher(),controller=new AbortController();controller.abort();
  try {await assert.rejects(load(createFetch(dispatcher))({...request,signal:controller.signal}),error=>error instanceof LlmError&&error.code==='ABORTED');}
  finally {await dispatcher.close();}
});

test('caller abort after successful headers keeps the existing ABORTED read result', {timeout:15000}, async () => {
  const server=await fixture(200,'{"data":['),dispatcher=createHttpDispatcher(),controller=new AbortController();
  const transport=createFetch(dispatcher);
  try {
    const discover=load(async(...args)=>{const response=await transport(...args);controller.abort();return response;});
    await assert.rejects(discover({...request,baseURL:server.url,signal:controller.signal}),error=>error instanceof LlmError&&error.code==='ABORTED');
    assert.deepEqual(await within(server.closed,10000),{beforeCleanup:true,ended:false});
  } finally {await server.close();await dispatcher.close();}
});

test('HTTP 401 already received retains its status error when caller aborts at headers', {timeout:15000}, async () => {
  const server=await fixture(401,'rejected'),dispatcher=createHttpDispatcher(),controller=new AbortController();
  const transport=createFetch(dispatcher);
  try {
    const discover=load(async(...args)=>{const response=await transport(...args);controller.abort();return response;});
    await assert.rejects(discover({...request,baseURL:server.url,signal:controller.signal}),rejection(401,server.url+'/models'));
    assert.deepEqual(await within(server.closed,10000),{beforeCleanup:true,ended:false});
  } finally {await server.close();await dispatcher.close();}
});
