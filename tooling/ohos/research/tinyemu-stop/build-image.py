#!/usr/bin/env python3
"""Build the fixed Linux boot fixture as an ext4 file; never mount it."""
import argparse, hashlib, json, os, pathlib, subprocess, tarfile
P=pathlib.Path
p=argparse.ArgumentParser();p.add_argument('--diskimage',type=P,required=True);p.add_argument('--alpine',type=P,required=True);p.add_argument('--output',type=P,required=True);a=p.parse_args()
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
assert sha(a.diskimage)=='808ecc1b32efdd76103172129b77b46002a616dff2270664207c291e4fde9e14'
assert sha(a.alpine)=='010683db6c73b3ad1c334fc8f93f64ae748ef67ae6d69e964929aeaf8517bff3'
out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);root=out/'root';root.mkdir();image=out/'image';image.mkdir()
with tarfile.open(a.alpine) as t:t.extractall(root,filter='tar')
with tarfile.open(a.diskimage) as t:
    for name in ['bbl64.bin','kernel-riscv64.bin']:
        (image/name).write_bytes(t.extractfile('diskimage-linux-riscv-2018-09-23/'+name).read())
(root/'sbin/dsh-init').write_text('''#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /tmp
uname -a
printf '__904_LINUX_BOOTED__\\n'
while :; do sleep 3600; done
''');(root/'sbin/dsh-init').chmod(0o755)
with (image/'rootfs.ext4').open('wb') as f:f.truncate(128*1024*1024)
command=['mke2fs','-q','-t','ext4','-O','^metadata_csum_seed,^orphan_file','-d',str(root),str(image/'rootfs.ext4')]
r=subprocess.run(command,capture_output=True);(out/'mke2fs.stdout').write_bytes(r.stdout);(out/'mke2fs.stderr').write_bytes(r.stderr);assert r.returncode==0
(image/'alpine.cfg').write_text(json.dumps({'version':1,'machine':'riscv64','memory_size':256,'bios':'bbl64.bin','kernel':'kernel-riscv64.bin','cmdline':'console=hvc0 root=/dev/vda rw init=/sbin/dsh-init','drive0':{'file':'rootfs.ext4'}})+'\n')
(out/'BUILD.json').write_text(json.dumps({'argv':command,'scope':'Fixed boot fixture; no installed git/gh/python/rg or production job agent','builderUid':os.geteuid(),'ownershipScope':'Boot fixture only; non-root builds retain builder ownership and are not distributable production images','inputs':{'diskimage':sha(a.diskimage),'alpine':sha(a.alpine)},'files':{f.name:sha(f) for f in image.iterdir()}},indent=2)+'\n')
print(image/'alpine.cfg')
