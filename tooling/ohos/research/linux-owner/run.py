#!/usr/bin/env python3
import argparse,hashlib,json,os,pathlib,shutil,subprocess
P=pathlib.Path;HERE=P(__file__).resolve().parent;ROOT=HERE.parents[3]
p=argparse.ArgumentParser();p.add_argument('--node',required=True);p.add_argument('--dsh-prefix',type=P,required=True);p.add_argument('--native-library-dir',type=P,required=True);p.add_argument('--publication-fixture',type=P,required=True);p.add_argument('--assets',type=P,required=True);p.add_argument('--archive',type=P,required=True);p.add_argument('--output',type=P,required=True);a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
def sha(path):
 with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
source=out/'source/runtime/ohos/linux';source.mkdir(parents=True)
for name in ['owner.mjs','instance.mjs','host-paths.mjs','base-download.mjs','prepare-images.mjs','backend.mjs','controller.mjs','streams.mjs','native-session.mjs']:shutil.copy2(ROOT/'runtime/ohos/linux'/name,source/name)
shutil.copytree(ROOT/'runtime/ohos/net',out/'source/runtime/ohos/net')
for name in ['dsh-subprocess-local','dsh-subprocess','dsh-http-proxy','cordis','cosmokit']:shutil.copytree(a.dsh_prefix/'node_modules/@deepseek-ai'/name,out/'source/runtime/ohos/process/node_modules/@deepseek-ai'/name,symlinks=True)
shutil.copy2(HERE/'owner-test.mjs',out/'owner-test.mjs')
assets=a.assets.resolve();manifest=json.loads((assets/'install-manifest.json').read_text());inputs={'source':{p.name:sha(p) for p in source.iterdir()},'native':sha(a.native_library_dir/'libdsh_linux.so'),'publicationFixture':sha(a.publication_fixture),'manifest':sha(assets/'install-manifest.json'),'assets':{k:sha(assets/v['path']) for k,v in manifest.items() if isinstance(v,dict) and 'path'in v},'archive':sha(a.archive),'networkScope':'Explicit fetch fixture streams actual pinned archive; not Huawei network availability'};(out/'INPUTS.json').write_text(json.dumps(inputs,indent=2)+'\n')
commands=[];checks=0
for mode in ['cancel-download','cancel-prepare','unknown-retire','cancel-boot','normal']:
 argv=[a.node,'--jitless','--import',str(ROOT/'runtime/ohos/sim/preload.mjs'),str(out/'owner-test.mjs'),str(a.native_library_dir.resolve()),str(assets/'install-manifest.json'),str(a.archive.resolve()),str(out/mode),mode]
 env={**os.environ,'LD_PRELOAD':str(a.publication_fixture.resolve()),'DSH_GO_OHOS_SIM_ADDONS':json.dumps([str(a.native_library_dir.resolve()/'libdsh_linux.so')])}
 result=subprocess.run(argv,capture_output=True,env=env,timeout=210);(out/(mode+'.stdout')).write_bytes(result.stdout);(out/(mode+'.stderr')).write_bytes(result.stderr);commands.append({'mode':mode,'argv':argv,'exitCode':result.returncode});(out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n');assert result.returncode==0,(mode,result.stderr.decode(errors='replace'))
 summary=json.loads(result.stdout.decode().splitlines()[-1]);assert summary['pass'];checks+=summary['checks'];print(mode,summary['checks'],'PASS',flush=True)
(out/'RESULT.json').write_text(json.dumps({'passed':True,'checks':checks,'scope':'Host actual Node NAPI/TinyEMU + production owner, explicit archive transport fixture; no HAP/device or Huawei HTTP assertion'},indent=2)+'\n')
