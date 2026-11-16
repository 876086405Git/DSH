#!/usr/bin/env python3
"""Reproducible *host-only* guest test fixture; never run archive scripts."""
import argparse, hashlib, io, json, os, pathlib, shutil, stat, subprocess, tarfile, time, zlib
P = pathlib.Path
p=argparse.ArgumentParser();p.add_argument('--inputs',type=P,required=True);p.add_argument('--agent',type=P,required=True);p.add_argument('--output',type=P,required=True);a=p.parse_args()
out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);root=out/'root';root.mkdir();image=out/'image';image.mkdir()
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def extract(t):
    links=[]
    for m in t:
        name=pathlib.PurePosixPath(m.name)
        if name.is_absolute() or '..' in name.parts: raise ValueError('archive path escape')
        dst=root.joinpath(*name.parts)
        if dst==root: continue
        cur=root
        for part in name.parts[:-1]:
            cur=cur/part
            if cur.is_symlink(): raise ValueError('symlink archive parent: '+str(cur))
            cur.mkdir(exist_ok=True)
        if m.isdir():
            if dst.is_symlink(): raise ValueError('directory replaces symlink')
            dst.mkdir(exist_ok=True)
        elif m.isfile():
            if dst.exists() or dst.is_symlink(): dst.unlink()
            with t.extractfile(m) as source, dst.open('xb') as target: shutil.copyfileobj(source,target)
        elif m.issym():
            if dst.exists() or dst.is_symlink(): dst.unlink()
            dst.symlink_to(m.linkname)
        elif m.islnk(): links.append((dst,m.linkname));continue
        else: raise ValueError('unexpected archive node: '+m.name)
        if not m.issym(): dst.chmod(m.mode & 0o777)
    for dst,target in links:
        src=root/target
        if not src.resolve().is_relative_to(root) or not src.is_file(): raise ValueError('hard link escape')
        if dst.exists() or dst.is_symlink():dst.unlink()
        os.link(src,dst)
alpine=a.inputs/'alpine-minirootfs-3.24.4-riscv64.tar.gz';disk=a.inputs/'diskimage-linux-riscv-2018-09-23.tar.gz'
assert sha(alpine)=='010683db6c73b3ad1c334fc8f93f64ae748ef67ae6d69e964929aeaf8517bff3'
assert sha(disk)=='808ecc1b32efdd76103172129b77b46002a616dff2270664207c291e4fde9e14'
with tarfile.open(alpine) as t:extract(t)
lock=json.loads((P(__file__).resolve().parent/'packages.lock.json').read_text())
for entry in lock:
    path=a.inputs/'apks'/entry['filename'];assert sha(path)==entry['sha256']
    rest=path.read_bytes();members=[]
    while rest:
        dec=zlib.decompressobj(31);members.append(dec.decompress(rest)+dec.flush());rest=dec.unused_data
    assert len(members)==3
    with tarfile.open(fileobj=io.BytesIO(members[2])) as t:extract(t)
with tarfile.open(disk) as t:
    for name in ('bbl64.bin','kernel-riscv64.bin'):(image/name).write_bytes(t.extractfile('diskimage-linux-riscv-2018-09-23/'+name).read())
(root/'usr/local/lib/dsh').mkdir(parents=True)
shutil.copyfile(a.agent,root/'usr/local/lib/dsh/guest-agent.py')
(root/'workspace').mkdir();(root/'workspace').chmod(0o777)
(root/'workspace/needle.txt').write_text('alpha\nbeta needle\ngamma\n')
(root/'etc/resolv.conf').write_text('nameserver 10.0.2.3\n')
(root/'sbin/dsh-init').write_text('''#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /tmp
chmod 1777 /tmp
ip link set lo up
ip link set eth0 up
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2
hostname dsh-guest
'''+'date -u -s @'+str(int(time.time()))+''' >/dev/null
exec /usr/bin/python3 -u /usr/local/lib/dsh/guest-agent.py --epoch '''+'01'*32+'\n')
(root/'sbin/dsh-init').chmod(0o755)
with (image/'rootfs.ext4').open('wb') as f:f.truncate(512*1024*1024)
command=['mke2fs','-q','-t','ext4','-O','^metadata_csum_seed,^orphan_file','-d',str(root),str(image/'rootfs.ext4')]
r=subprocess.run(command,capture_output=True);(out/'mke2fs.stdout').write_bytes(r.stdout);(out/'mke2fs.stderr').write_bytes(r.stderr);assert r.returncode==0,r.stderr
(image/'alpine.cfg').write_text(json.dumps({'version':1,'machine':'riscv64','memory_size':512,'bios':'bbl64.bin','kernel':'kernel-riscv64.bin','cmdline':'console=hvc0 root=/dev/vda rw init=/sbin/dsh-init','drive0':{'file':'rootfs.ext4'},'eth0':{'driver':'user'}})+'\n')
(out/'BUILD.json').write_text(json.dumps({'argv':command,'builderUid':os.geteuid(),'hostOnly':True,'source':{'alpine':sha(alpine),'disk':sha(disk),'agent':sha(a.agent)},'packages':lock},indent=2)+'\n')
print(image/'alpine.cfg')
