#!/usr/bin/env python3
"""Host-only 912/914 four-drive guest fixture with the fixed test epoch.

Derived from the verified 909 fixture. Not a production App image builder.
Build --tools-root with linux-job/build-image.py and the current guest agent.
"""
import argparse,gzip,hashlib,json,os,pathlib,shutil,subprocess,tarfile
P=pathlib.Path;ROOT=P(__file__).resolve().parents[4]
p=argparse.ArgumentParser();p.add_argument('--diskimage',type=P,required=True);p.add_argument('--alpine',type=P,required=True);p.add_argument('--output',type=P,required=True);p.add_argument('--tools-root',type=P,required=True);a=p.parse_args()
def sha(f):
 with f.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
assert sha(a.diskimage)=='808ecc1b32efdd76103172129b77b46002a616dff2270664207c291e4fde9e14'
assert sha(a.alpine)=='010683db6c73b3ad1c334fc8f93f64ae748ef67ae6d69e964929aeaf8517bff3'
agent=ROOT/'runtime/ohos/linux/guest-agent.py';lock=ROOT/'tooling/ohos/research/linux-job/packages.lock.json'
tools_build=json.loads((a.tools_root.parent/'BUILD.json').read_text())
assert tools_build['source']=={'alpine':sha(a.alpine),'disk':sha(a.diskimage),'agent':sha(agent)}, 'tools root source identity mismatch'
assert tools_build['packages']==json.loads(lock.read_text()), 'tools root package lock mismatch'
assert (a.tools_root/'sbin/dsh-init').read_text().rstrip().endswith('exec /usr/bin/python3 -u /usr/local/lib/dsh/guest-agent.py --epoch '+'01'*32), 'tools root must use the fixed host-test epoch'
assert (a.tools_root/'workspace/needle.txt').is_file(), 'tools root must be the linux-job test fixture'
out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);root=out/'build-root';root.mkdir();image=out/'image';image.mkdir()
# Host-only historical handoff fixture; production assets use build-linux-assets.py.
with tarfile.open(a.alpine) as t:t.extractall(root,filter='tar')
with tarfile.open(a.diskimage) as t:
 for name in ['bbl64.bin','kernel-riscv64.bin']:(image/name).write_bytes(t.extractfile('diskimage-linux-riscv-2018-09-23/'+name).read())
(root/'target').mkdir()
script='''#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
failed() { echo __906_INSTALL_FAILED__; while :; do sleep 3600; done; }
mount -t ext4 /dev/vdc /target || failed
echo __906_EXTRACT_BEGIN__
tar xzf /dev/vdb -C /target || failed
tar -xzf /dev/vdd -C /target || failed
mkdir -p /target/oldroot
mount --move /dev /target/dev || failed
umount /proc || failed
umount /sys || failed
cd /target || failed
pivot_root . oldroot || failed
exec /bin/sh -c 'umount /oldroot || { echo __909_OLDROOT_BUSY__; while :; do sleep 3600; done; }; echo __909_HANDOFF__; exec /sbin/dsh-init'
'''
(root/'sbin/dsh-init').write_text(script);(root/'sbin/dsh-init').chmod(0o755)
commands=[]
for name,tree in [('bootstrap.ext4',root),('empty.ext4',None)]:
 target=image/name
 with target.open('wb') as f:f.truncate(512*1024*1024)
 cmd=['mke2fs','-q','-t','ext4','-O','^metadata_csum_seed,^orphan_file']+(['-d',str(tree)] if tree else [])+[str(target)]
 r=subprocess.run(cmd,capture_output=True);commands.append({'argv':cmd,'exitCode':r.returncode});(out/(name+'.stdout')).write_bytes(r.stdout);(out/(name+'.stderr')).write_bytes(r.stderr);assert r.returncode==0
 with target.open('rb') as inp,(image/(name+'.gz')).open('wb') as raw:
  with gzip.GzipFile(filename='',fileobj=raw,mode='wb',mtime=0) as z:shutil.copyfileobj(inp,z)
# Host-only tools fixture; source tree is not modified and links not dereferenced.
with tarfile.open(image/'tools.block','w:gz',dereference=False) as t:
    for f in sorted(a.tools_root.iterdir()):t.add(f,arcname=f.name,recursive=True)
    t.add(ROOT/'runtime/ohos/linux/guest-agent.py',arcname='usr/local/lib/dsh/guest-agent.py')
with (image/'tools.block').open('r+b') as f:f.truncate(((image/'tools.block').stat().st_size+511)//512*512)
# Writable fixture files are fresh copies; the pinned source archive stays untouched.
v=out/'candidate';v.mkdir();shutil.copyfile(image/'empty.ext4',v/'target.ext4');shutil.copyfile(a.alpine,v/'download.block')
with (v/'download.block').open('r+b') as f:f.truncate((a.alpine.stat().st_size+511)//512*512)
(v/'install.cfg').write_text(json.dumps({'version':1,'machine':'riscv64','memory_size':512,'bios':str(image/'bbl64.bin'),'kernel':str(image/'kernel-riscv64.bin'),'cmdline':'console=hvc0 root=/dev/vda ro init=/sbin/dsh-init','drive0':{'file':str(image/'bootstrap.ext4'),'readOnly':True},'drive1':{'file':str(v/'download.block'),'readOnly':True},'drive2':{'file':str(v/'target.ext4')},'drive3':{'file':str(image/'tools.block'),'readOnly':True},'eth0':{'driver':'user'}})+'\n')
(out/'BUILD.json').write_text(json.dumps({'commands':commands,'builderUid':os.geteuid(),'scope':'HOST_TEST_ONLY: four-drive handoff, fixed 01 epoch; no HAP/device claim','agentSha256':sha(agent),'packagesLockSha256':sha(lock),'toolsInitSha256':sha(a.tools_root/'sbin/dsh-init'),'archiveOriginalBytes':a.alpine.stat().st_size,'archiveSha256':sha(a.alpine),'assets':{f.name:{'sha256':sha(f),'bytes':f.stat().st_size} for f in [image/name for name in ['bbl64.bin','kernel-riscv64.bin','bootstrap.ext4','empty.ext4','bootstrap.ext4.gz','empty.ext4.gz','tools.block']]}},indent=2)+'\n')
