#!/usr/bin/env python3
"""Run only the actual Linux guest job matrix against the controlled TinyEMU ABI."""
import argparse,json,pathlib,subprocess,sys
P=pathlib.Path;here=P(__file__).resolve().parent;repo=here.parents[3]
p=argparse.ArgumentParser();p.add_argument('--inputs',type=P,required=True);p.add_argument('--library',type=P,required=True);p.add_argument('--output',type=P,required=True);p.add_argument('--cc',default='cc');a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
commands=[]
def run(label,argv,timeout=360):
 r=subprocess.run(list(map(str,argv)),capture_output=True,timeout=timeout)
 (out/(label+'.stdout')).write_bytes(r.stdout);(out/(label+'.stderr')).write_bytes(r.stderr)
 commands.append({'label':label,'argv':list(map(str,argv)),'exitCode':r.returncode});(out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
 if r.returncode:raise RuntimeError(label+' failed; see '+str(out))
run('driver',[a.cc,'-std=c11','-Wall','-Wextra','-Werror','-shared','-fPIC','-I',here.parent/'tinyemu-stop',here/'vm-driver.c','-ldl','-o',out/'driver.so'])
run('image',[sys.executable,'-I','-B',here/'build-image.py','--inputs',a.inputs.resolve(),'--agent',repo/'runtime/ohos/linux/guest-agent.py','--output',out/'guest'])
run('guest',[sys.executable,'-I','-B','-u',here/'run-test.py','--driver',out/'driver.so','--library',a.library.resolve(),'--config',out/'guest/image/alpine.cfg','--output',out/'run'])
checks=json.loads((out/'run/checks.json').read_text());assert checks and all(c['pass'] for c in checks)
print(json.dumps({'scope':'real TinyEMU guest job transport; no host workspace leases or HAP','passed':len(checks)}))
