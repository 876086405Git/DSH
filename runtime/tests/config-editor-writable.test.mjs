// Actual rc4 ConfigEditor.canWrite and app-boot composition, private temporary files.
// Calls the pure method directly; this is not the separate HTTP Host measurement.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
const prefix=resolve(process.env.DSH_PREFIX),base=join(prefix,'node_modules/@deepseek-ai');
const {ConfigEditor}=await import(pathToFileURL(join(base,'dsh-config-editor/lib/index.js')));
const {loadProfileDirectory}=await import(pathToFileURL(join(base,'dsh-app-boot/lib/index.js')));
function fixture(t,{profileRows,homeRows,overlays=[],bundles=[]}={}){
 const root=mkdtempSync(join(tmpdir(),'r6-writable-'));t.after(()=>rmSync(root,{recursive:true,force:true}));const home=join(root,'home'),dir=join(home,'profiles/web');mkdirSync(dir,{recursive:true});
 const manifest=join(dir,'package.json'),patchPath=join(dir,'cordis.patch.yml');writeFileSync(manifest,JSON.stringify({name:'own-profile',dsh:{profile:{bundles}}}));
 writeFileSync(patchPath,JSON.stringify(profileRows??[{insert:[{id:'fixture',name:'own-plugin',config:{count:1}}]}]));
 if(homeRows!==undefined)writeFileSync(join(home,'cordis.patch.yml'),typeof homeRows==='string'?homeRows:JSON.stringify(homeRows));
 const profile={dir,home,installAnchor:join(base,'dsh/package.json'),patchPath,overlays,telemetryDisabledEnv:'1'};
 const entry={options:{id:'fixture',name:'own-plugin',config:{count:1}}},editor=Object.create(ConfigEditor.prototype);Object.assign(editor,{ownerContext:{profileContext:profile},entries:()=>[entry]});
 return {root,manifest,patchPath,profile,editor,entry,read:()=>readFileSync(manifest,'utf8'),writable:()=>editor.canWrite(entry)};
}
test('ordinary profile config is controllable and method writes no file',t=>{const f=fixture(t),before=f.read();assert.equal(f.writable(),true);assert.equal(f.read(),before);});
for(const source of ['home','cli'])for(const value of [1,2])test(`${source} complete config, including equal value ${value}, is read-only`,t=>{const patches=[{id:'fixture',config:{count:value}}],f=fixture(t,source==='home'?{homeRows:patches}:{overlays:patches});assert.equal(f.writable(),false);});
for(const source of ['home','cli'])test(`${source} later insert cannot be edited by earlier profile patch`,t=>{const rows=[{insert:[{id:'fixture',name:'own-plugin',config:{count:1}}]}],f=fixture(t,{profileRows:[],...(source==='home'?{homeRows:rows}:{overlays:rows})});assert.equal(f.writable(),false);});
test('higher disabled flag and unrelated config do not claim this config',t=>{const f=fixture(t,{homeRows:[{id:'fixture',disabled:false},{id:'different',config:{count:2}}]});assert.equal(f.writable(),true);});
test('malformed higher layer is conservatively read-only',t=>{assert.equal(fixture(t,{homeRows:'[invalid yaml'}).writable(),false);});
test('unreadable/skipped bundle is conservatively read-only',t=>{assert.equal(fixture(t,{bundles:['own-missing-bundle']}).writable(),false);});
test('readOnly normalizes retired bundles in memory; default loader retains legacy cleanup',t=>{
 const f=fixture(t,{bundles:['@deepseek-ai/dsh-experimental-schedule-bundle']}),before=f.read();
 assert.equal(f.writable(),true);assert.equal(f.read(),before);f.editor.configuration();assert.equal(f.read(),before);
 const loaded=loadProfileDirectory('dsh',f.profile.dir,f.profile.installAnchor,{readOnly:true});assert.equal(loaded.layers.length,0);assert.equal(f.read(),before);
 loadProfileDirectory('dsh',f.profile.dir,f.profile.installAnchor);assert.notEqual(f.read(),before);assert.deepEqual(JSON.parse(f.read()).dsh.profile.bundles,[]);
});

test('配置行按需克隆显式空对象，缺省的两列各自独立', t => {
  const f = fixture(t, { profileRows: [{ insert: [
    { id: 'missing', name: 'sample' },
    { id: 'nil', name: 'sample', config: null },
    { id: 'explicit', name: 'sample', config: {} },
  ] }] });
  f.editor.entries = () => ['missing', 'nil', 'explicit'].map(id => ({ options: { id } }));
  const clone = globalThis.structuredClone;
  let emptyClones = 0;
  t.mock.method(globalThis, 'structuredClone', function (value, ...rest) {
    if (value != null && Object.getPrototypeOf(value) === Object.prototype && !Reflect.ownKeys(value).length) emptyClones++;
    return clone.call(this, value, ...rest);
  });
  const rows = f.editor.configuration();
  assert.equal(emptyClones, 1, '只有显式提供的空 config 进入深克隆');
  const columns = rows.flatMap(row => [row.inherited, row.override]);
  assert.equal(new Set(columns).size, 6);
  columns[0].changed = true;
  for (const other of columns.slice(1)) assert.deepEqual(other, {});
});
