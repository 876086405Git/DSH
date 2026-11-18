import { createFetch } from '../../ohos/net/fetch.mjs';
import { createHttpDispatcher } from '../../ohos/net/dispatcher.mjs';
const imageFetch = createFetch(createHttpDispatcher());
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { downloadLinuxBase } from '../../ohos/linux/base-download.mjs';

const bytes = Buffer.from('fixed guest image bytes\0\xff');
const sha256 = createHash('sha256').update(bytes).digest('hex');
const artifact = { url: 'https://mirrors.huaweicloud.com/dsh-test/fixed-image.bin', bytes: bytes.length, sha256 };
async function fixture(fn) {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-linux-download-'));
  try { await fn(directory); } finally { await rm(directory, { recursive: true, force: true }); }
}
const transport = body => ({ fetch: async () => new Response(body) });

test('downloads exact bytes, reports progress, and only publishes verified base', () => fixture(async directory => {
  const events=[];
  const result=await downloadLinuxBase({ directory, artifact, onProgress: event => events.push(event) },transport(bytes));
  assert.deepEqual(await readFile(result.path),bytes);
  assert.equal(result.state,'verified-base');
  assert.equal(events.at(-1).stage,'verified');
  assert.equal(events.at(-1).done,bytes.length);
  assert.deepEqual(await readdir(directory),[sha256]);
}));
test('bad digest and overlong/short body leave no published or temporary files', () => fixture(async directory => {
  for(const body of [Buffer.alloc(bytes.length),bytes.subarray(1),Buffer.concat([bytes,Buffer.of(1)])]) {
    await assert.rejects(downloadLinuxBase({directory,artifact},transport(body)),{code:'ERR_OHOS_LINUX_IMAGE_INTEGRITY'});
    assert.deepEqual(await readdir(directory),[]);
  }
}));
test('cancel after final chunk prevents publication and cleans staging', () => fixture(async directory => {
  const controller=new AbortController();
  await assert.rejects(downloadLinuxBase({directory,artifact,signal:controller.signal,onProgress: event => {
    if(event.stage==='download' && event.done===bytes.length) controller.abort();
  }},transport(bytes)),{name:'AbortError'});
  assert.deepEqual(await readdir(directory),[]);
}));
test('HTTP failure cleans staging, does not fabricate completion', () => fixture(async directory => {
  const events=[];
  await assert.rejects(downloadLinuxBase({directory,artifact,onProgress:e=>events.push(e)}, {fetch:async()=>new Response('failure',{status:503})}),{code:'ERR_OHOS_LINUX_DOWNLOAD'});
  assert.deepEqual(await readdir(directory),[]); assert.ok(!events.some(e=>e.stage==='verified'));
}));
test('cached image is rechecked and corruption is explicit', () => fixture(async directory => {
  const result=await downloadLinuxBase({directory,artifact},transport(bytes));
  await writeFile(result.path,Buffer.alloc(bytes.length));
  await assert.rejects(downloadLinuxBase({directory,artifact}, {fetch:()=>assert.fail('must not download over corrupt cache')}),{code:'ERR_OHOS_LINUX_IMAGE_INTEGRITY'});
}));
test('production transport cancels an actual HTTP body via injected URL mapping', () => fixture(async directory => {
  const server=createServer((_req,res)=>{res.writeHead(200); res.write(bytes.subarray(0,2));});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const controller=new AbortController();
  try {
    await assert.rejects(downloadLinuxBase({directory,artifact,signal:controller.signal,onProgress:e=>{
      if(e.stage==='download'&&e.done===2) controller.abort();
    }},{fetch:(_url,options)=>imageFetch(`http://127.0.0.1:${server.address().port}/image`,options)}),{name:'AbortError'});
    assert.deepEqual(await readdir(directory),[]);
  } finally {server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
}));
test('rejects non-HTTPS and credential-bearing source before download', () => fixture(async directory => {
  for(const url of ['http://mirrors.huaweicloud.com/image','https://user:secret@mirrors.huaweicloud.com/image']) {
    await assert.rejects(downloadLinuxBase({directory,artifact:{...artifact,url}},{fetch:()=>assert.fail('invalid input')}),{code:'ERR_OHOS_LINUX_IMAGE_MANIFEST'});
  }
}));

test('progress callback failure cancels body and cleans owned staging', () => fixture(async directory => {
  let cancelled=false;
  const body=new ReadableStream({pull(c){c.enqueue(bytes.subarray(0,2));},cancel(){cancelled=true;}});
  const error=new Error('observer failed');
  await assert.rejects(downloadLinuxBase({directory,artifact,onProgress(){throw error;}},transport(body)),error);
  assert.equal(cancelled,true); assert.deepEqual(await readdir(directory),[]);
}));
