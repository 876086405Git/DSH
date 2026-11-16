import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {once} from 'node:events';
import {join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {bootstrapDshNetwork} from '../../ohos/net/bootstrap.mjs';
const prefix=resolve(process.env.OHOS_TEST_DSH_PREFIX);
bootstrapDshNetwork(join(prefix,'node_modules/@deepseek-ai/dsh/lib/bin.js'));
const undici=await import(pathToFileURL(join(prefix,'node_modules/undici/index.js')));
const {installProxyFromEnvironment}=await import(pathToFileURL(join(prefix,'node_modules/@deepseek-ai/dsh-http-proxy/lib/index.js')));
const bytes=Uint8Array.from([66,0,255,128,195,169,17,22]);
const cases=[
 ['Uint8Array',()=>new Uint8Array(bytes),Buffer.from(bytes)],
 ['Uint8Array subarray',()=>new Uint8Array(bytes).subarray(2,6),Buffer.from(bytes.subarray(2,6))],
 ['Int16Array offset view',()=>new Int16Array(new Uint8Array(bytes).buffer,2,2),Buffer.from(bytes.subarray(2,6))],
 ['DataView offset view',()=>new DataView(new Uint8Array(bytes).buffer,1,5),Buffer.from(bytes.subarray(1,6))],
 ['ArrayBuffer',()=>new Uint8Array(bytes).buffer,Buffer.from(bytes)],
 ['empty offset view',()=>new Uint8Array(bytes).subarray(3,3),Buffer.alloc(0)],
 ['Buffer',()=>Buffer.from(bytes),Buffer.from(bytes)],
 ['string',()=>'中文',Buffer.from('中文')],
 ['iterable chunks',()=>[Buffer.from(bytes.subarray(0,3)),Buffer.from(bytes.subarray(3))],Buffer.from(bytes)],
];
for(const [name,body,expected] of cases)test(`real DSH policy and Undici request preserve ${name} body bytes`,async t=>{
 const server=http.createServer(async(req,res)=>{try{const chunks=[];for await(const chunk of req)chunks.push(chunk);res.end(Buffer.concat(chunks));}catch{res.destroy();}});
 server.listen(0,'127.0.0.1');await once(server,'listening');
 t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
 const dispose=await installProxyFromEnvironment(new Map(),()=>{});t.after(dispose);
 const response=await undici.request(`http://127.0.0.1:${server.address().port}`,{method:'POST',body:body(),headers:{'content-length':String(expected.length)}});
 assert.equal(response.statusCode,200);assert.deepEqual(Buffer.from(await response.body.arrayBuffer()),expected);
});
test('native fetch wraps Uint8Array before the same real DSH transport',async t=>{
 const server=http.createServer(async(req,res)=>{const chunks=[];for await(const chunk of req)chunks.push(chunk);res.end(Buffer.concat(chunks));});
 server.listen(0,'127.0.0.1');await once(server,'listening');
 t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
 const dispose=await installProxyFromEnvironment(new Map(),()=>{});t.after(dispose);
 const response=await fetch(`http://127.0.0.1:${server.address().port}`,{method:'POST',body:new Uint8Array(bytes).subarray(2,6)});
 assert.deepEqual(Buffer.from(await response.arrayBuffer()),Buffer.from(bytes.subarray(2,6)));
});
