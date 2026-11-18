// Actual FilesMediaPlugin + HmsPdfPages + PdfInput; only platform/Flutter boundaries
// are doubles. Linux descriptors and Poppler oracle bytes are real.
import assert from 'node:assert/strict';
import fsp from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';
import { pdfFixture, deferred, until, plain } from './pdf-fixture.mjs';

test('missing PDF module leaves file channel and close available and fails only the requested PDF operation', async t => {
  const f = await pdfFixture(t, { filesChannel: true, kitFailure: true }), c = f.createFilesPlugin();
  assert.equal(f.stats().kitLoads, 0);
  assert.deepEqual(await c.call('pdfClose'), { value: null }); assert.equal(f.stats().kitLoads, 0);
  assert.deepEqual(await c.call('unknown'), { missing: true });
  assert.equal((await c.call('pdfInfo', { path: f.source })).error, 'pdf_unavailable');
  assert.equal(f.stats().kitLoads, 1); assert.equal(f.docs.length, 0); assert.equal(f.fds.size, 0);
  f.change({ kitFailure: false });
  assert.deepEqual(plain((await c.call('pdfInfo', { path: f.source })).value), f.metadata.pages);
  assert.equal(f.stats().kitLoads, 2);
  assert.deepEqual(await c.call('pdfClose'), { value: null }); assert.equal(f.fds.size, 0);
});

test('late PDF module resolution after detach never opens a document or revives the retired owner', async t => {
  const gate = deferred(), f = await pdfFixture(t, { filesChannel: true, beforeKitLoad: () => gate.promise }), c = f.createFilesPlugin();
  const pending = c.call('pdfInfo', { path: f.source }); await until(() => f.stats().kitLoads === 1);
  c.plugin.onDetachedFromAbility(); gate.resolve();
  assert.equal((await pending).error, 'cancelled'); await until(() => f.fds.size === 0);
  assert.equal(f.docs.length, 0); assert(!f.events.includes('open-input'));
  assert.deepEqual(await c.call('pdfClose'), { value: null }); assert.equal(f.stats().kitLoads, 1);
});

test('channel passes real PDF metadata and PNG bytes and loads native only on use', async t => {
  const f=await pdfFixture(t,{filesChannel:true}),c=f.createFilesPlugin();
  assert.equal(f.stats().nativeLoads,0);assert.equal(f.docs.length,0);
  assert.deepEqual(await c.call('pdfClose'),{value:null});assert.equal(f.stats().nativeLoads,0);
  const info=await c.call('pdfInfo',{path:f.source});assert.deepEqual(plain(info.value),f.metadata.pages);
  assert.equal(f.stats().nativeLoads,1);assert.equal(f.docs.length,1);
  const page=await c.call('pdfPage',{path:f.source,page:0,width:100});assert(page.value instanceof Uint8Array);
  assert.deepEqual(Buffer.from(page.value),await fsp.readFile(join(process.env.OHOS_PDF_FIXTURES,'page-100x150.png')));
  assert.equal(f.docs.length,1);assert.equal(f.stats().nativeLoads,1);
  assert.deepEqual(await c.call('pdfClose'),{value:null});assert.equal(f.fds.size,0);assert(f.docs.every(d=>d.released));
});

test('channel keeps Android page=0 width=1080 defaults', async t => {
  const f=await pdfFixture(t,{filesChannel:true}),c=f.createFilesPlugin();
  const page=await c.call('pdfPage',{path:f.source});assert(page.value instanceof Uint8Array);
  assert.equal(f.pages[0].index,0);assert.equal(f.pages[0].render.width,1080);assert.equal(f.pages[0].render.height,1620);
  assert.deepEqual(await c.call('pdfClose'),{value:null});assert.equal(f.fds.size,0);
});

test('channel preserves PDF password, unavailable and invalid argument codes', async t => {
  const f=await pdfFixture(t,{filesChannel:true,parseResult:3}),c=f.createFilesPlugin();
  assert.equal((await c.call('pdfInfo',{path:f.source})).error,'pdf_password');assert.equal(f.fds.size,0);
  f.change({parseResult:0,constructFailure:true});
  assert.equal((await c.call('pdfInfo',{path:f.source})).error,'pdf_unavailable');assert.equal(f.fds.size,0);
  f.change({constructFailure:false});
  assert.equal((await c.call('pdfPage',{path:f.source,page:-1,width:100})).error,'invalid');
  assert.deepEqual(await c.call('pdfClose'),{value:null});assert.equal(f.fds.size,0);
});

test('late native import cannot open a descriptor after Ability detach', async t => {
  const gate=deferred(),f=await pdfFixture(t,{filesChannel:true,nativeLoad:()=>gate.promise}),c=f.createFilesPlugin();
  const pending=c.call('pdfInfo',{path:f.source});await until(()=>f.stats().nativeLoads===1);
  c.plugin.onDetachedFromAbility();gate.resolve();
  assert.equal((await pending).error,'cancelled');await until(()=>f.fds.size===0);
  assert.equal(f.docs.length,0);assert(!f.events.includes('open-input'));
});

test('late pixel packing cannot deliver bytes after Ability detach', async t => {
  const gate=deferred(),f=await pdfFixture(t,{filesChannel:true,pack:()=>gate.promise}),c=f.createFilesPlugin();
  const pending=c.call('pdfPage',{path:f.source,page:0,width:100});await until(()=>f.packers.length===1);
  c.plugin.onDetachedFromAbility();gate.resolve();assert.equal((await pending).error,'cancelled');
  await until(()=>f.docs.every(d=>d.released)&&f.fds.size===0);
  assert(f.pages.every(p=>p.released));assert(f.pixels.every(p=>p.released));assert(f.packers.every(p=>p.released));
});

test('new Ability gets a new PDF owner and stale engine handler stays cancelled', async t => {
  const f=await pdfFixture(t,{filesChannel:true}),c=f.createFilesPlugin();
  assert.equal((await c.call('pdfInfo',{path:f.source})).error,undefined);
  const binding={getAbility:()=>({context:{...f.context}})};
  c.plugin.onAttachedToAbility(binding);
  assert.equal((await c.call('pdfInfo',{path:f.source})).error,undefined);
  assert.equal(f.docs.length,2);assert.equal(f.docs[0].released,true);
  c.plugin.onDetachedFromEngine(c.engine);assert.equal((await c.call('pdfInfo',{path:f.source})).error,'cancelled');
  const next=f.createFilesPlugin();assert.equal((await next.call('pdfInfo',{path:f.source})).error,undefined);
  assert.deepEqual(await next.call('pdfClose'),{value:null});assert.equal(f.fds.size,0);assert(f.docs.every(d=>d.released));
});

test('failed old cleanup blocks new native document, then new owner retries', async t => {
  const f=await pdfFixture(t,{filesChannel:true}),c=f.createFilesPlugin();
  assert.equal((await c.call('pdfInfo',{path:f.source})).error,undefined);
  f.change({documentReleaseFailure:true});c.plugin.onDetachedFromEngine(c.engine);
  await until(()=>f.warnings.length>0);
  const next=f.createFilesPlugin();assert.equal((await next.call('pdfInfo',{path:f.source})).error,'failed');
  assert.equal(f.docs.length,1);assert.equal(f.docs[0].released,false);
  f.change({documentReleaseFailure:false});
  assert.equal((await next.call('pdfInfo',{path:f.source})).error,undefined);
  assert.equal(f.docs[0].released,true);assert.equal(f.docs.length,2);
  assert.deepEqual(await next.call('pdfClose'),{value:null});assert.equal(f.fds.size,0);
});

test('PDF channel cannot read an external file or workspace symlink', async t => {
  const f=await pdfFixture(t,{filesChannel:true}),c=f.createFilesPlugin();
  const outside=join(f.root,'outside.pdf');await fsp.copyFile(f.source,outside);
  const link=join(f.workspace,'linked.pdf');await fsp.symlink(outside,link);
  for(const path of [outside,link])assert.equal((await c.call('pdfInfo',{path})).error,'pdf_unavailable');
  assert.equal(f.docs.length,0);assert.equal(f.fds.size,0);
  assert.deepEqual(await c.call('pdfClose'),{value:null});
});

test('PathProvider Ability cache remains readable when application cache differs', async t => {
  const f=await pdfFixture(t,{filesChannel:true});
  const ability={...f.context,cacheDir:join(f.root,'ability-cache'),tempDir:join(f.root,'ability-temp')};
  await fsp.mkdir(ability.cacheDir);await fsp.mkdir(ability.tempDir);
  const downloaded=join(ability.cacheDir,'下载文档.pdf');await fsp.copyFile(f.source,downloaded);
  const c=f.createFilesPlugin(ability),info=await c.call('pdfInfo',{path:downloaded});
  assert.deepEqual(plain(info.value),f.metadata.pages);
  assert.deepEqual(await c.call('pdfClose'),{value:null});assert.equal(f.fds.size,0);
});
