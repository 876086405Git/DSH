#!/usr/bin/env python3
"""Fetch fixed public test inputs, verifying bytes before publishing each file."""
import argparse,hashlib,json,pathlib,urllib.request
P=pathlib.Path;here=P(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--out',type=P,required=True);p.add_argument('--alpine-mirror',default='https://dl-cdn.alpinelinux.org/alpine');a=p.parse_args()
if not a.alpine_mirror.startswith('https://'):p.error('mirror must use HTTPS')
a.out.mkdir(parents=True,exist_ok=True);(a.out/'apks').mkdir(exist_ok=True)
items=[{'filename':'diskimage-linux-riscv-2018-09-23.tar.gz','url':'https://bellard.org/tinyemu/diskimage-linux-riscv-2018-09-23.tar.gz','sha256':'808ecc1b32efdd76103172129b77b46002a616dff2270664207c291e4fde9e14'}, {'filename':'alpine-minirootfs-3.24.4-riscv64.tar.gz','url':a.alpine_mirror.rstrip('/')+'/v3.24/releases/riscv64/alpine-minirootfs-3.24.4-riscv64.tar.gz','sha256':'010683db6c73b3ad1c334fc8f93f64ae748ef67ae6d69e964929aeaf8517bff3'}]
for row in json.loads((here/'packages.lock.json').read_text()):items.append({**row,'filename':'apks/'+row['filename'],'url':a.alpine_mirror.rstrip('/')+'/v3.24/'+row['repository']+'/riscv64/'+row['filename']})
for item in items:
 target=a.out/item['filename'];part=target.with_name(target.name+'.part')
 if target.exists():
  if hashlib.sha256(target.read_bytes()).hexdigest()!=item['sha256']:raise ValueError('existing input hash mismatch: '+str(target))
  continue
 try:
  with urllib.request.urlopen(urllib.request.Request(item['url'],headers={'User-Agent':'dsh-go-ohos-linux/1'}),timeout=45) as source,part.open('xb') as sink:
   h=hashlib.sha256();count=0
   while raw:=source.read(65536):
    count+=len(raw)
    if count>64*1024*1024:raise ValueError('fixed input too large')
    sink.write(raw);h.update(raw)
  if h.hexdigest()!=item['sha256']:raise ValueError('download hash mismatch: '+item['filename'])
  part.rename(target);print(item['filename'],count,h.hexdigest(),flush=True)
 finally:part.unlink(missing_ok=True)
