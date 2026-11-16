#!/usr/bin/env python3
"""Build-machine-only image assembler. No extraction/mke2fs inside the App."""
import argparse,gzip,hashlib,importlib.util,json,os,pathlib,shutil,subprocess,tarfile
P=pathlib.Path;ROOT=P(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--diskimage',type=P,required=True);p.add_argument('--alpine',type=P,required=True);p.add_argument('--tools-root',type=P,required=True);p.add_argument('--agent',type=P,required=True);p.add_argument('--output',type=P,required=True);a=p.parse_args()
def sha(f):
 with f.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
assert sha(a.diskimage)=='808ecc1b32efdd76103172129b77b46002a616dff2270664207c291e4fde9e14'
assert sha(a.alpine)=='010683db6c73b3ad1c334fc8f93f64ae748ef67ae6d69e964929aeaf8517bff3'
assert sha(a.agent)=='e8069c237ef2960c2b5558d610210355375109a7f3bc866c1303d3bf1cffb9a0'
out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);root=out/'build-root';root.mkdir();image=out/'image';image.mkdir()
with tarfile.open(a.alpine) as t:t.extractall(root,filter='tar')
(root/'target').mkdir();shutil.copy2(ROOT/'runtime/ohos/linux/guest/install-init.sh',root/'sbin/dsh-init');(root/'sbin/dsh-init').chmod(0o755)
with tarfile.open(a.diskimage) as t:
 for name in ['bbl64.bin','kernel-riscv64.bin']:(image/name).write_bytes(t.extractfile('diskimage-linux-riscv-2018-09-23/'+name).read())
commands=[]
for name,tree in [('bootstrap.ext4',root),('empty.ext4',None)]:
 target=image/name
 with target.open('wb') as f:f.truncate(512*1024*1024)
 argv=['mke2fs','-q','-t','ext4','-O','^metadata_csum_seed,^orphan_file']+(['-d',str(tree)] if tree else [])+[str(target)]
 r=subprocess.run(argv,capture_output=True);commands.append({'argv':argv,'exitCode':r.returncode});(out/(name+'.stderr')).write_bytes(r.stderr);assert r.returncode==0
 with target.open('rb') as src,(image/(name+'.gz')).open('wb') as dst:
  with gzip.GzipFile(fileobj=dst,filename='',mtime=0,mode='wb') as z:shutil.copyfileobj(src,z)
# Guest system files belong to root whatever account runs this build.
def rooted(info):info.uid=info.gid=0;info.uname=info.gname='root';return info
with tarfile.open(image/'tools.block','w:gz',dereference=False) as t:
 for f in sorted(a.tools_root.iterdir()):t.add(f,arcname=f.name,filter=rooted)
 t.add(a.agent,arcname='usr/local/lib/dsh/guest-agent.py',filter=rooted)
 info=rooted(t.gettarinfo(str(ROOT/'runtime/ohos/linux/guest/agent-init.sh'),arcname='sbin/dsh-init'));info.mode=0o755
 with (ROOT/'runtime/ohos/linux/guest/agent-init.sh').open('rb') as f:t.addfile(info,f)
with (image/'tools.block').open('r+b') as f:f.truncate(((image/'tools.block').stat().st_size+511)//512*512)
def asset(path):return {'path':str(path),'bytes':path.stat().st_size,'sha256':sha(path)}
manifest={key:asset(image/name) for key,name in [('bios','bbl64.bin'),('kernel','kernel-riscv64.bin'),('tools','tools.block'),('bootstrap','bootstrap.ext4.gz'),('empty','empty.ext4.gz')]}
for key,name in [('bootstrap','bootstrap.ext4'),('empty','empty.ext4')]:manifest[key].update(expandedBytes=(image/name).stat().st_size,expandedSha256=sha(image/name))
manifest['archive']={'url':'https://repo.huaweicloud.com/alpine/v3.24/releases/riscv64/alpine-minirootfs-3.24.4-riscv64.tar.gz','bytes':a.alpine.stat().st_size,'sha256':sha(a.alpine)}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(out/'BUILD.json').write_text(json.dumps({'commands':commands,'agentSha256':sha(a.agent),'toolsRoot':str(a.tools_root.resolve()),'scope':'Host image assembly with supplied tools root; not independently reproducible package acquisition or HAP/device build'},indent=2)+'\n')

portable=json.loads(json.dumps(manifest))
for name in ['bios','kernel','tools','bootstrap','empty']:portable[name]['path']=P(portable[name]['path']).name
(image/'install-manifest.json').write_text(json.dumps(portable,indent=2)+'\n')
spec=importlib.util.spec_from_file_location('linux_assets',ROOT/'runtime/ohos/package/linux-assets.py')
assets=importlib.util.module_from_spec(spec);spec.loader.exec_module(assets)
published=assets.publish_assets(image,out/'assets')
build=json.loads((out/'BUILD.json').read_text());build['publishedAssets']=published
(out/'BUILD.json').write_text(json.dumps(build,indent=2)+'\n')
