import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readdir, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { prepareLinuxImages } from '../../ohos/linux/prepare-images.mjs';
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
async function fixture(fn) {
 const home=await mkdtemp(join(tmpdir(),'ohos-images-'));
 try {
  const compressed=gzipSync(Buffer.from('fixed seed'));
  const path=join(home,'seed.gz');await writeFile(path,compressed);
  const asset={path,bytes:compressed.length,sha256:sha(compressed),expandedBytes:10,expandedSha256:sha(Buffer.from('fixed seed'))};
  const data=Buffer.from('verified archive bytes');const basePath=join(home,'base');await writeFile(basePath,data);
  await fn({directory:join(home,'prepared'),bootstrap:asset,empty:asset,archive:{path:basePath,bytes:data.length,sha256:sha(data)}},data);
 }finally{await rm(home,{recursive:true,force:true});}
}
test('prepares ordinary files, verifies both gzip identities, pads only archive copy',()=>fixture(async(options,data)=>{
 const result=await prepareLinuxImages(options);
 assert.equal(result.state,'prepared-images');
 assert.equal((await readFile(result.bootstrap)).toString(),'fixed seed');
 assert.equal((await readFile(result.target)).toString(),'fixed seed');
 const block=await readFile(result.archive);assert.equal(block.length,512);assert.deepEqual(block.subarray(0,data.length),data);assert.ok(block.subarray(data.length).every(b=>b===0));
 assert.deepEqual(await readFile(options.archive.path),data);
 assert.deepEqual((await readdir(result.directory)).sort(),['archive.block','bootstrap.ext4','target.ext4']);
}));
test('cancelled expansion removes only owned staging',()=>fixture(async options=>{
 const controller=new AbortController();
 await assert.rejects(prepareLinuxImages({...options,signal:controller.signal,onProgress:e=>{if(e.done)controller.abort();}}),{name:'AbortError'});
 assert.deepEqual(await readdir(options.directory),[]);
}));
test('modified compressed or expanded identity and archive leave no preparation',()=>fixture(async options=>{
 for(const change of [{bootstrap:{...options.bootstrap,sha256:'0'.repeat(64)}},{bootstrap:{...options.bootstrap,expandedSha256:'0'.repeat(64)}},{bootstrap:{...options.bootstrap,expandedBytes:1}},{archive:{...options.archive,sha256:'0'.repeat(64)}}]) {
  await assert.rejects(prepareLinuxImages({...options,...change}),{code:'ERR_OHOS_LINUX_IMAGE_INTEGRITY'});
  assert.deepEqual(await readdir(options.directory),[]);
 }
}));
