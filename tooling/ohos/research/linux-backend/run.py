#!/usr/bin/env python3
"""Actual production JS backend: bounded protocol tests and real private guests."""
import argparse,hashlib,json,os,pathlib,shutil,subprocess
P=pathlib.Path;HERE=P(__file__).resolve().parent;ROOT=HERE.parents[3]
p=argparse.ArgumentParser();p.add_argument('--node',required=True);p.add_argument('--dsh-prefix',type=P,required=True);p.add_argument('--native-library-dir',type=P,required=True);p.add_argument('--guest-config',type=P,required=True);p.add_argument('--output',type=P,required=True);a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
def sha(path):
 with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
package=a.dsh_prefix.resolve()/'node_modules/@deepseek-ai/dsh-subprocess-local';metadata=json.loads((package/'package.json').read_text());assert metadata['name']=='@deepseek-ai/dsh-subprocess-local'
source=out/'source/runtime/ohos/linux';source.mkdir(parents=True)
for name in ['backend.mjs','controller.mjs','streams.mjs','native-session.mjs']:shutil.copy2(ROOT/'runtime/ohos/linux'/name,source/name)
for name in ['dsh-subprocess-local','dsh-subprocess','dsh-http-proxy','cordis','cosmokit']:
 shutil.copytree(package.parent/name,out/'source/runtime/ohos/process/node_modules/@deepseek-ai'/name,symlinks=True)
for name in ['protocol.test.mjs','clean-close.test.mjs','guest-test.mjs']:shutil.copy2(HERE/name,out/name)
inputs={'source':{p.name:sha(p) for p in source.iterdir()},'collector':{'version':metadata['version'],'packageSha256':sha(package/'package.json'),'outputSha256':sha(package/'lib/output.js')},'nativeLibrarySha256':sha(a.native_library_dir/'libdsh_linux.so'),'guestConfigSha256':sha(a.guest_config)}
commands=[]
def execute(argv,label,env=None):
 r=subprocess.run(list(map(str,argv)),capture_output=True,env=env,timeout=210);(out/(label+'.stdout')).write_bytes(r.stdout);(out/(label+'.stderr')).write_bytes(r.stderr);commands.append({'label':label,'argv':list(map(str,argv)),'exitCode':r.returncode});(out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n');assert r.returncode==0,(label,r.stderr.decode(errors='replace'))
for mode in ['jit','strict']:
 execute([a.node,*(['--jitless','--import',ROOT/'runtime/ohos/sim/preload.mjs'] if mode=='strict' else []),'--test',out/'protocol.test.mjs',out/'clean-close.test.mjs'],'protocol-'+mode)
config_path=a.guest_config.resolve();original=json.loads(config_path.read_text());inputs['guestFiles']={}
for key,value in original.items():
 if key in ['bios','kernel','initrd']:
  path=(config_path.parent/value).resolve();original[key]=str(path);inputs['guestFiles'][key]=sha(path)
 if key.startswith('drive') and isinstance(value,dict):
  path=(config_path.parent/value['file']).resolve();original[key]={**value,'file':str(path)};inputs['guestFiles'][key]=sha(path)
(out/'INPUTS.json').write_text(json.dumps(inputs,indent=2)+'\n')
for mode in ['normal','disconnect']:
 case=out/mode;case.mkdir();(case/'spill').mkdir();config=json.loads(json.dumps(original))
 for key,value in config.items():
  if key.startswith('drive') and isinstance(value,dict) and value.get('readOnly') is not True:
   target=case/(key+'.img');shutil.copyfile(value['file'],target);value['file']=str(target)
 path=case/'guest.cfg';path.write_text(json.dumps(config)+'\n')
 env={**os.environ,'DSH_GO_OHOS_SIM_ADDONS':json.dumps([str(a.native_library_dir.resolve()/'libdsh_linux.so')])}
 execute([a.node,'--jitless','--import',ROOT/'runtime/ohos/sim/preload.mjs',out/'guest-test.mjs',a.native_library_dir.resolve(),path,case/'spill',mode],'guest-'+mode,env)
 facts=[json.loads(line) for line in (out/('guest-'+mode+'.stdout')).read_text().splitlines()];assert facts[-1]['pass'] and facts[-1]['state']==('closed' if mode=='normal' else 'quarantined')
(out/'RESULT.json').write_text(json.dumps({'passed':True,'scope':'Real production LinuxRuntimeBackend via 912 Node NAPI + independent writable guest disks; no HAP/device or authorized 9P','protocolModes':['jit','strict'],'guestModes':['normal','disconnect']},indent=2)+'\n')
