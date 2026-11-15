import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { dirname,join } from 'node:path';
import { pdfFixture,plain,deferred,until } from './pdf-fixture.mjs';

test('actual document bytes copied with native fd; real PDF geometry consumed and every page released',async t=>{
 const f=await pdfFixture(t,{maxRead:17,maxWrite:7});const info=plain(await f.service.info(f.source));
 assert.deepEqual(info,f.metadata.pages);assert.deepEqual(f.docs[0].bytes,await fs.readFile(f.source));assert(f.docs[0].path.startsWith(f.context.cacheDir+'/dsh-pdf/'));
 assert(f.pages.every(p=>p.released));assert.equal(f.fds.size,0);assert(f.stats().reads>1&&f.stats().writes>1);
 await f.service.info(f.source);assert.equal(f.docs.length,1);await f.service.close();assert(f.docs[0].released);await assert.rejects(fs.stat(f.docs[0].path));
});

test('actual PNG from independent Poppler render passes exact colour/options/size and release chain',async t=>{
 const f=await pdfFixture(t);const bytes=await f.service.render(f.source,0,100);const png=Buffer.from(bytes);
 assert.equal(png.readUInt32BE(16),100);assert.equal(png.readUInt32BE(20),150);
 assert.deepEqual(png,await fs.readFile(join(process.env.OHOS_PDF_FIXTURES,'page-100x150.png')));
 assert.deepEqual(f.pages[0].render,{matrix:{x:0,y:0,width:100,height:150,rotate:0},width:100,height:150,options:{isGray:false,drawAnnotations:true,isTransparent:false}});
 assert(f.packers[0].released&&f.pixels[0].released&&f.pages[0].released);
 assert(f.events.indexOf('packer.release')<f.events.indexOf('pixel.release'));assert(f.events.indexOf('pixel.release')<f.events.indexOf('page.release'));
 if(process.env.OHOS_PDF_RENDER_OUTPUT)await fs.writeFile(process.env.OHOS_PDF_RENDER_OUTPUT,bytes);await f.service.close();
});

test('width clamps match actual Dart/Android contract; encoded sizes must remain correct',async t=>{
 const f=await pdfFixture(t);const low=await f.service.render(f.source,0,-10);assert.equal(new DataView(low.buffer).getUint32(16,false),64);
 const high=await f.service.render(f.source,0,99999);assert.equal(new DataView(high.buffer).getUint32(16,false),2400);await f.service.close();
});

test('kit unavailable, encrypted/invalid parse, impossible count leave no native resources or files',async t=>{
 for(const opt of [{constructFailure:true},{parseResult:3},{parseResult:2},{loadFailure:true},{pageCount:1001},{pageCount:0}]){
  const f=await pdfFixture(t,opt);await assert.rejects(f.service.info(f.source));assert.equal(f.fds.size,0);
  assert.equal((await fs.readdir(f.context.cacheDir+'/dsh-pdf')).length,0);assert(f.docs.every(d=>d.released||opt.constructFailure));
 }
});

test('raw external URI, private home, traversal and source symlinks never reach PDF parser',async t=>{
 const f=await pdfFixture(t);const home=join(f.root,'files/runtime/rootfs/root/.dsh');await fs.mkdir(home);const secret=join(home,'secret.pdf');await fs.copyFile(f.source,secret);
 const link=join(f.workspace,'link.pdf');await fs.symlink(secret,link);
 for(const path of ['file://docs/document/x',secret,link,f.workspace+'/../.dsh/secret.pdf'])await assert.rejects(f.service.info(path));
 assert.equal(f.docs.length,0);assert.equal(f.fds.size,0);await f.service.close();
});

test('size cap rejects sparse 64MiB+1 source before reading/allocating PDF snapshot',async t=>{
 const f=await pdfFixture(t);const path=join(f.workspace,'large.pdf'),file=await fs.open(path,'w');await file.truncate(64*1024*1024+1);await file.close();
 await assert.rejects(f.service.info(path),e=>e.code==='pdf_size');assert.equal(f.stats().reads,0);assert.equal(f.docs.length,0);assert.equal(f.fds.size,0);
});

test('zero read/write and source growth reject snapshots; descriptors always close',async t=>{
 for(const opt of [{zeroRead:true},{zeroWrite:true}]){const f=await pdfFixture(t,opt);await assert.rejects(f.service.info(f.source));assert.equal(f.fds.size,0);assert.equal(f.docs.length,0);}
 const f=await pdfFixture(t);f.change({beforeRead:async({reads})=>{if(reads===1)await fs.appendFile(f.source,'extra');}});
 await assert.rejects(f.service.info(f.source),e=>e.code==='pdf_changed');assert.equal(f.fds.size,0);assert.equal(f.docs.length,0);
});

test('asynchronous native opener returning after retirement still closes its owned fd',async t=>{
 const gate=deferred(),f=await pdfFixture(t,{opener:()=>gate.promise});const first=f.service.info(f.source);first.catch(()=>{});
 await until(()=>f.events.includes('opener'));const retired=f.service.retire();const next=f.newService();gate.resolve();
 await assert.rejects(first,e=>e.code==='cancelled');await retired;assert.equal(f.fds.size,0);assert.equal(f.docs.length,0);
 f.change({opener:undefined});assert.deepEqual(plain(await next.info(f.source)),f.metadata.pages);await next.close();
});

test('retirement during pack cannot send PNG to new owner or release handles while pack is pending',async t=>{
 const gate=deferred(),f=await pdfFixture(t,{pack:()=>gate.promise});const first=f.service.render(f.source,0,100);first.catch(()=>{});
 await until(()=>f.events.includes('pack'));const next=f.newService();const second=next.info(f.source);assert.equal(f.docs.length,1);
 assert.equal(f.pixels[0].released,false);gate.resolve();await assert.rejects(first,e=>e.code==='cancelled');await second;
 assert(f.docs[0].released&&f.pages[0].released&&f.pixels[0].released&&f.packers[0].released);assert.equal(f.docs.length,2);await next.close();
});

test('failed native release keeps physical owner and retries before opening another document',async t=>{
 const f=await pdfFixture(t);await f.service.info(f.source);f.change({documentReleaseFailure:true});
 await assert.rejects(f.service.close());const next=f.newService();await assert.rejects(next.info(f.source));assert.equal(f.docs.length,1);
 f.change({documentReleaseFailure:false});await next.info(f.source);assert.equal(f.docs.length,2);assert(f.docs[0].released);await next.close();
});

test('packer/pixel/page cleanup failures retain remaining handles and close can retry',async t=>{
 for(const key of ['packerReleaseFailure','pixelReleaseFailure','pageReleaseFailure']){
  const f=await pdfFixture(t,{[key]:true});await assert.rejects(f.service.render(f.source,0,100));f.change({[key]:false});await f.service.close();
  assert(f.docs[0].released&&f.pages[0].released&&f.pixels[0].released&&f.packers[0].released);
 }
});

test('invalid page/dimensions and wrong native bitmap/PNG sizes never become a successful page',async t=>{
 const f=await pdfFixture(t);for(const [page,width] of [[-1,100],[2,100],[NaN,100],[0,NaN]])await assert.rejects(f.service.render(f.source,page,width));await f.service.close();
 for(const opt of [{pageWidth:0},{pageHeight:Infinity},{pixelWidth:101},{invalidPng:true}]){
  const x=await pdfFixture(t,opt);await assert.rejects(x.service.render(x.source,0,100));await x.service.close();assert(x.pages.every(p=>p.released));assert(x.pixels.every(p=>p.released));
 }
});

test('close is serialized after in-flight page; a later render reopens a fresh document',async t=>{
 const gate=deferred(),f=await pdfFixture(t,{pack:()=>gate.promise});const first=f.service.render(f.source,0,100);
 await until(()=>f.events.includes('pack'));const close=f.service.close();assert(!f.docs[0].released);gate.resolve();await first;await close;
 await f.service.info(f.source);assert.equal(f.docs.length,2);await f.service.close();
});

test('ordinary queued page budget is finite while the physical renderer is pending',async t=>{
 const gate=deferred(),f=await pdfFixture(t,{pack:()=>gate.promise});const first=f.service.render(f.source,0,100);await until(()=>f.events.includes('pack'));
 const queued=[];for(let i=0;i<31;i++){const p=f.service.info(f.source);p.catch(()=>{});queued.push(p);}
 await assert.rejects(f.service.info(f.source),e=>e.code==='busy');const retired=f.service.retire();gate.resolve();await assert.rejects(first);
 await Promise.all(queued.map(p=>assert.rejects(p)));await retired;assert.equal(f.fds.size,0);
});

test('many empty owner replacements do not consume rendering queue or touch file/native services',async t=>{
 const f=await pdfFixture(t);let service=f.service;for(let i=0;i<100;i++){service=f.newService();service.close();}
 assert.equal(f.events.length,0);await service.info(f.source);await service.close();assert.equal(f.docs.length,1);
});

test('repeated close coalesces without dropping a close after an intervening info request',async t=>{
 const gate=deferred(),f=await pdfFixture(t,{pack:()=>gate.promise});const render=f.service.render(f.source,0,100);await until(()=>f.events.includes('pack'));
 const first=f.service.close();for(let i=0;i<100;i++)assert.equal(f.service.close(),first);
 const info=f.service.info(f.source);const last=f.service.close();assert.notEqual(first,last);
 gate.resolve();await render;await first;await info;await last;assert.equal(f.docs.length,2);assert(f.docs.every(d=>d.released));
});

test('failed document close cannot reuse the potentially invalid same-owner cached document',async t=>{
 const f=await pdfFixture(t);await f.service.info(f.source);f.change({documentReleaseFailure:true});await assert.rejects(f.service.close());
 const n=f.pages.length;await assert.rejects(f.service.info(f.source));assert.equal(f.pages.length,n);
 f.change({documentReleaseFailure:false});await f.service.info(f.source);assert.equal(f.docs.length,2);await f.service.close();
});

test('validated page count is the bound used by info and render, not a second unchecked query',async t=>{
 const f=await pdfFixture(t,{pageCounts:[2,100000]});assert.deepEqual(plain(await f.service.info(f.source)),f.metadata.pages);
 await assert.rejects(f.service.render(f.source,2,100));assert.equal(f.pages.length,2);await f.service.close();
});

test('system-cleared private document or complete slot does not trap a resource-free physical owner',async t=>{
 for(const mode of ['file','slot']){
  const f=await pdfFixture(t);await f.service.info(f.source);const path=f.docs[0].path;
  if(mode==='file')await fs.unlink(path);else await fs.rm(dirname(path),{recursive:true});
  await f.service.close();await f.service.close();assert(f.docs[0].released);assert.equal(f.fds.size,0);assert((await fs.stat(f.source)).isFile());
  const next=f.newService();assert.deepEqual(plain(await next.info(f.source)),f.metadata.pages);await next.info(f.source);assert.equal(f.docs.length,2);await next.close();
 }
});

test('owned slot disappearing between lstat/listFile or listFile/rmdir is also already cleaned',async t=>{
 for(const phase of ['listFile','rmdir']){
  const f=await pdfFixture(t);await f.service.info(f.source);
  f.change({[phase]:async path=>{await fs.rmdir(path);}});await f.service.close();assert.equal(f.fds.size,0);assert(f.docs[0].released);
  f.change({[phase]:undefined});const next=f.newService();await next.info(f.source);await next.close();
 }
});

test('cleanup permission failure and unexpected slot content retain ownership rather than masquerading as eviction',async t=>{
 for(const phase of ['unlinkFailure','lstatFailure']){
  const f=await pdfFixture(t);await f.service.info(f.source);f.change({[phase]:true});await assert.rejects(f.service.close(),e=>e.code===13900012);
  const next=f.newService();await assert.rejects(next.info(f.source));assert.equal(f.docs.length,1);f.change({[phase]:false});await next.info(f.source);await next.close();
 }
 const f=await pdfFixture(t);await f.service.info(f.source);const other=join(dirname(f.docs[0].path),'not-owned');await fs.writeFile(other,'keep');
 await assert.rejects(f.service.close(),e=>e.code==='pdf_cache');assert.equal(await fs.readFile(other,'utf8'),'keep');await fs.unlink(other);await f.service.close();
});

test('missing cache never bypasses a failed native document release',async t=>{
 const f=await pdfFixture(t);await f.service.info(f.source);await fs.unlink(f.docs[0].path);f.change({documentReleaseFailure:true});
 await assert.rejects(f.service.close());const next=f.newService();await assert.rejects(next.info(f.source));assert.equal(f.docs.length,1);assert.equal(f.docs[0].released,false);
 f.change({documentReleaseFailure:false});await next.info(f.source);assert(f.docs[0].released);await next.close();
});
