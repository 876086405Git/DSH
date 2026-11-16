import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {VirtualSubprocessRuntime} from '../../ohos/process/runtime.mjs';
let root,work,runtime;
const input='甲🙂e\u0301\t乙\n'; // 15 UTF-8 bytes, 7 code points, 1 newline, 2 words.
before(async()=>{root=await mkdtemp(join(tmpdir(),'ohos-wc-'));work=join(root,'work');const temp=join(root,'temp');await mkdir(work);await mkdir(temp);await writeFile(join(work,'input.txt'),input);await writeFile(join(work,'second.txt'),'x\n');await writeFile(join(work,'empty.txt'),'');runtime=new VirtualSubprocessRuntime({workspaceRoots:[work],temporaryRoot:temp});});
after(async()=>{await runtime?.dispose();await rm(root,{recursive:true,force:true});});
async function run(command){
 const h=runtime.spawn({argv:['bash','-c',command],cwd:work,env:{LC_ALL:'C.UTF-8',LANG:'C.UTF-8'},graceMs:100,stdio:{stdin:'ignore',stdout:{maxBytes:65536},stderr:{maxBytes:65536}}});
 const result=await h.done;assert.equal(result.exitCode,0);assert.equal(result.signal,null);assert.equal(h.collected.stderr.readFrom(0).text,'');assert(await h.waitForExit());return h.collected.stdout.readFrom(0).text;
}
const lines=text=>text.trim().split('\n').map(line=>line.trim().split(/\s+/u));
test('wc combines separate character and byte columns on stdin in fixed order',async()=>{
 for(const flags of ['-cm','-mc','--chars --bytes','-c -m -c'])assert.deepEqual(lines(await run(`wc ${flags} < input.txt`)),[['7','15']],flags);
});
test('wc combined line and word options retain both Unicode counts',async()=>{
 assert.deepEqual(lines(await run('wc -lcm < input.txt')),[['1','7','15']]);assert.deepEqual(lines(await run('wc -mclw < input.txt')),[['1','2','7','15']]);
});
test('wc default and single-selection behavior retain bytes and Unicode code points',async()=>{
 for(const [flags,expected] of [['',['1','2','15']],['-c',['15']],['-m',['7']],['-l',['1']],['-w',['2']],['-lc',['1','15']],['-lm',['1','7']]])assert.deepEqual(lines(await run(`wc ${flags} < input.txt`)),[expected],flags);
});
test('wc files and total keep independent byte and character sums and aligned columns',async()=>{
 const text=await run('wc -cm input.txt second.txt');assert.deepEqual(lines(text),[['7','15','input.txt'],['2','2','second.txt'],['9','17','total']]);
 const rows=text.trimEnd().split('\n');assert.equal(rows[0].indexOf('input.txt'),rows[1].indexOf('second.txt'));assert.equal(rows[0].indexOf('input.txt'),rows[2].indexOf('total'));
 assert.deepEqual(lines(await run('wc -mclw input.txt second.txt')),[['1','2','7','15','input.txt'],['1','1','2','2','second.txt'],['2','3','9','17','total']]);
});
test('wc byte/character counts survive a real virtual pipeline',async()=>{assert.deepEqual(lines(await run('cat input.txt | wc -mc')),[['7','15']]);});
test('wc empty input retains both zero columns',async()=>{assert.deepEqual(lines(await run('wc -cm < empty.txt')),[['0','0']]);});
