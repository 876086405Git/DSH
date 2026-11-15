// Diagnostic only: leave owned fds for Environment teardown; never use application files.
import fs from 'node:fs';
import { open as openHandle } from 'node:fs/promises';
import { promisify } from 'node:util';
import { join } from 'node:path';
const root=process.argv[2];
if (!root?.startsWith('/')) throw new Error('absolute probe directory required');
const round=fs.readFileSync(join(root,'round.txt'),'utf8').trim();
const rows=[]; const handles=[];
const record=(kind,fd)=>{const s=fs.fstatSync(fd,{bigint:true});rows.push(`OPEN ${kind} ${fd} ${s.dev} ${s.ino}`)};
for(let i=0;i<8;i++) {
 const path=join(root,`held-sync-${round}-${i}`);fs.writeFileSync(path,'probe');record('sync',fs.openSync(path,'r'));
}
for(let i=0;i<8;i++) {
 const path=join(root,`held-async-${round}-${i}`);fs.writeFileSync(path,'probe');record('async',await promisify(fs.open)(path,'r'));
}
for(let i=0;i<2;i++) {
 const path=join(root,`held-handle-${round}-${i}`);fs.writeFileSync(path,'probe');const h=await openHandle(path,'r');handles.push(h);record('handle',h.fd);
}
const closed=[];
for(let i=0;i<8;i++) {const path=join(root,`closed-${round}-${i}`);fs.writeFileSync(path,'probe');closed.push(fs.openSync(path,'r'));}
for(const fd of closed){fs.closeSync(fd);rows.push(`CLOSED raw ${fd} 0 0`);}
// After this atomic ready publication JS performs no more file opens/closes.
fs.writeFileSync(join(root,'ready.tmp'),rows.join('\n')+'\n');
fs.renameSync(join(root,'ready.tmp'),join(root,'ready.txt'));
globalThis.__fdProbeKeepHandles=handles;
setInterval(()=>{},1000);
