#!/usr/bin/env python3
"""HAP-build-time bootstrap/empty ext4 assets and a three-drive install fixture."""
import argparse,gzip,hashlib,json,os,pathlib,shutil,subprocess,tarfile
P=pathlib.Path
p=argparse.ArgumentParser();p.add_argument('--diskimage',type=P,required=True);p.add_argument('--alpine',type=P,required=True);p.add_argument('--output',type=P,required=True);p.add_argument('--readonly-probe',action='store_true');a=p.parse_args()
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
assert sha(a.diskimage)=='808ecc1b32efdd76103172129b77b46002a616dff2270664207c291e4fde9e14'
assert sha(a.alpine)=='010683db6c73b3ad1c334fc8f93f64ae748ef67ae6d69e964929aeaf8517bff3'
out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);root=out/'build-root';root.mkdir();image=out/'image';image.mkdir()
# Only the HAP build machine extracts a root tree. The application downloads a
# single archive, then the guest does all link-creating extraction inside ext4.
with tarfile.open(a.alpine) as t:t.extractall(root,filter='tar')
with tarfile.open(a.diskimage) as t:
 for name in ['bbl64.bin','kernel-riscv64.bin']:(image/name).write_bytes(t.extractfile('diskimage-linux-riscv-2018-09-23/'+name).read())
(root/'target').mkdir()
script='''#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
failed() { echo __906_INSTALL_FAILED__; while :; do sleep 3600; done; }
# Only a disposable copied archive is probed, never the fixed source input.
if dd if=/dev/zero of=/dev/vdb bs=512 count=1 2>/dev/null; then
  echo __906_READONLY_FAILED__
  while :; do sleep 3600; done
fi
echo __906_READONLY_ENFORCED__
mount -t ext4 /dev/vdc /target || failed
echo __906_EXTRACT_BEGIN__
tar xzf /dev/vdb -C /target || failed
chroot /target /bin/sh -c 'cat /etc/alpine-release; readlink /bin/sh' || failed
sync
umount /target || failed
echo __906_INSTALLED__
while :; do sleep 3600; done
'''
if not a.readonly_probe:
 start=script.index('# Only a disposable copied archive')
 end=script.index('mount -t ext4 /dev/vdc /target')
 script=script[:start]+script[end:]
(root/'sbin/dsh-init').write_text(script);(root/'sbin/dsh-init').chmod(0o755)
commands=[]
for name,tree in [('bootstrap.ext4',root),('empty.ext4',None)]:
 target=image/name
 with target.open('wb') as f:f.truncate(128*1024*1024)
 cmd=['mke2fs','-q','-t','ext4','-O','^metadata_csum_seed,^orphan_file']+(['-d',str(tree)] if tree else [])+[str(target)]
 r=subprocess.run(cmd,capture_output=True);commands.append({'argv':cmd,'exitCode':r.returncode});(out/(name+'.stdout')).write_bytes(r.stdout);(out/(name+'.stderr')).write_bytes(r.stderr);assert r.returncode==0
 with target.open('rb') as inp,(image/(name+'.gz')).open('wb') as raw:
  with gzip.GzipFile(filename='',fileobj=raw,mode='wb',mtime=0) as z:shutil.copyfileobj(inp,z)
# Device equivalents require only ordinary-file gzip expansion and copy/truncate.
for variant in ['baseline','candidate']:
 v=out/variant;v.mkdir();shutil.copyfile(image/'empty.ext4',v/'target.ext4');shutil.copyfile(a.alpine,v/'download.block')
 with (v/'download.block').open('r+b') as f:f.truncate((a.alpine.stat().st_size+511)//512*512)
 (v/'install.cfg').write_text(json.dumps({'version':1,'machine':'riscv64','memory_size':256,'bios':str(image/'bbl64.bin'),'kernel':str(image/'kernel-riscv64.bin'),'cmdline':'console=hvc0 root=/dev/vda ro init=/sbin/dsh-init','drive0':{'file':str(image/'bootstrap.ext4'),'readOnly':True},'drive1':{'file':str(v/'download.block'),'readOnly':True},'drive2':{'file':str(v/'target.ext4')}})+'\n')
(out/'BUILD.json').write_text(json.dumps({'commands':commands,'builderUid':os.geteuid(),'readonlyProbe':a.readonly_probe,'scope':'HAP-build-time image assets and disposable install fixture, not production READY','archiveOriginalBytes':a.alpine.stat().st_size,'archiveSha256':sha(a.alpine),'assets':{f.name:{'sha256':sha(f),'bytes':f.stat().st_size} for f in image.iterdir()}},indent=2)+'\n')
