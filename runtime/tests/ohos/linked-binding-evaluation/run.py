#!/usr/bin/env python3
"""Fixed Node public linked-binding evaluation; never modifies the product host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import sys
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--node-root',required=True,type=Path)
parser.add_argument('--host-source',required=True,type=Path,help='exact reviewed 39 runtime/ohos/host')
parser.add_argument('--dsh-prefix',required=True,type=Path)
parser.add_argument('--output',required=True,type=Path)
parser.add_argument('--build-output',required=True,type=Path,help='fresh build directory; keep binaries outside text evidence')
a=parser.parse_args()
here=Path(__file__).resolve().parent
host=a.host_source.resolve();runtime=host.parent
node=a.node_root.resolve()/'bin/node';headers=a.node_root.resolve()/'include/node'
output=a.output.resolve();assert not output.exists();output.mkdir(parents=True)
build=a.build_output.resolve();assert not build.exists();build.mkdir(parents=True)
sha=lambda b:hashlib.sha256(b).hexdigest()
fixed={
 'host/node_runner.cpp':'993b923df7999c23f3cb1d5efa9e300a37d85ad88f1b9f14e8a5ddb8caff27ae',
 'host/publication_binding.cc':'902ce0e57fc90ee8c8f801ab64cdd646ffdbfc87f185d5b2df760ddd2907091a',
 'node-version.json':'abbea973e37761623fc80fe12da17d79df3db932b66169da3fa1e45f552192c4',
 'preload.mjs':'791a559daa988dbf2f54ae8f08a7212db63ed1fdb773f8524dd4513153ca3274',
}
for name,identity in fixed.items():assert sha((runtime/name).read_bytes())==identity,(name,'wrong reviewed input')
input_pins=json.loads((here/'input-pins.json').read_text())
assert sha(node.read_bytes())==input_pins['nodeBinarySHA256']
for name,identity in input_pins['nodeHeaders'].items():assert sha((headers/name).read_bytes())==identity,(name,'wrong Node header')
assert json.loads((runtime/'node-version.json').read_text())=='24.22.1'
dsh_bin=a.dsh_prefix.resolve()/'node_modules/@deepseek-ai/dsh/lib/bin.js'
assert dsh_bin.is_file()
initial_inputs={str(p.relative_to(runtime)):sha(p.read_bytes()) for p in sorted(runtime.rglob('*')) if p.is_file()}
compiler=shutil.which('g++');assert compiler
build_records=[]
def compile_run(label,command):
 r=subprocess.run(command,capture_output=True,text=True)
 (output/(label+'.stdout')).write_text(r.stdout);(output/(label+'.stderr')).write_text(r.stderr)
 build_records.append({'label':label,'argv':list(map(str,command)),'returncode':r.returncode})
 (output/'build-records.json').write_text(json.dumps(build_records,indent=2)+'\n')
 assert r.returncode==0,(label,'see saved compiler stderr')
compile_run('version-header',[sys.executable,str(host/'generate-node-version.py'),'--pin',str(runtime/'node-version.json'),'--output',str(build/'dsh_node_version.h')])
flags=['-std=c++20','-O2','-g0','-fPIC','-shared','-pthread','-fvisibility=hidden','-ffunction-sections','-fdata-sections','-Wl,--gc-sections','-DNAPI_VERSION=8','-I',str(headers),'-I',str(host),'-I',str(build)]
addon=build/'registration.node'
compile_run('compile-registration',[compiler,*flags,str(here/'registration.cc'),'-o',str(addon)])
null_lib=build/'null-environment.so'
compile_run('compile-null',[compiler,*flags,str(here/'null-environment.cc'),'-o',str(null_lib)])
# The reviewed Linux test shim delegates real main -> exact dsh_node_start -> node::Start.
shim=runtime.parent/'tests/ohos/host-startup-linux.cc'
assert shim.is_file()
host_lib=build/'reviewed-host-test.so'
compile_run('compile-host',[compiler,*flags,str(host/'node_runner.cpp'),str(host/'publication_binding.cc'),str(shim),'-ldl','-o',str(host_lib)])
dynamic_host=build/'dynamic-host-test.so'
compile_run('compile-dynamic-host',[compiler,*flags,str(host/'node_runner.cpp'),str(here/'no-prestart-registration.cc'),str(shim),'-ldl','-o',str(dynamic_host)])
symbols=subprocess.check_output(['nm','-D','-C',str(addon)],text=True)
(output/'addon-dynamic-symbols.txt').write_text(symbols)
assert 'node::AddLinkedBinding' in symbols and 'node::GetCurrentEnvironment' in symbols
cases=[]
base_env={**os.environ,'NODE_OPTIONS':'','DSH_M6_TEST_ADDON':str(addon)}
base_env.pop('LD_PRELOAD',None)
for key in ['DSH_GO_OHOS_SIM','DSH_GO_OHOS_SIM_PLATFORM','DSH_GO_OHOS_SIM_ADDONS']:
 base_env.pop(key,None)
def disable_core():resource.setrlimit(resource.RLIMIT_CORE,(0,0))
def run_case(name,args,env,wanted=0,contains=None,sentinel_absent=None,expect_sim=None):
 start=time.monotonic()
 r=subprocess.run([str(node),*map(str,args)],env=env,capture_output=True,text=True,
                  timeout=30,preexec_fn=disable_core,start_new_session=True)
 (output/(name+'.stdout')).write_text(r.stdout);(output/(name+'.stderr')).write_text(r.stderr)
 assertions={'exitCode':r.returncode==wanted}
 if env.get('LD_PRELOAD') in {str(host_lib),str(dynamic_host)}:
  assertions['realDshNodeStartEntered']='M6_TEST_ENTER_DSH_NODE_START' in r.stderr
 if env.get('LD_PRELOAD')==str(dynamic_host):
  assertions['oldStaticRegistrationExplicitlyDisabled']='M6_TEST_STATIC_REGISTRATION_DISABLED' in r.stderr
 if contains is not None:assertions['diagnosticCode']=contains in r.stderr
 if sentinel_absent is not None:assertions['bootstrapNotExecuted']=not sentinel_absent.exists()
 value=None
 if r.returncode==0 and wanted==0:
  try:
   value=json.loads(r.stdout.strip().splitlines()[-1])
   assertions['jsonObservation']=True
   if expect_sim is not None:
    assertions['simMarker']=value.get('sim')==expect_sim
    if expect_sim:assertions['wasmAbsent']=value.get('wasmAbsent') is True
  except (ValueError,IndexError):assertions['jsonObservation']=False
 record={'name':name,'argv':[str(node),*map(str,args)],'env':{k:env[k] for k in ['NODE_OPTIONS','LD_PRELOAD','DSH_M6_TEST_ADDON','DSH_GO_OHOS_SIM','DSH_GO_OHOS_SIM_PLATFORM','DSH_GO_OHOS_SIM_ADDONS','DSH_HOME','DSH_M6_BOOTSTRAP_SENTINEL','DSH_M6_TEST_RUNTIME','DSH_M6_TEST_FIXTURES','DSH_M6_TEST_REGISTER'] if k in env},'returncode':r.returncode,'expectedReturncode':wanted,'assertions':assertions,'result':value,'elapsedSeconds':time.monotonic()-start,'pass':all(assertions.values())}
 cases.append(record)
 print(json.dumps({'name':name,'returncode':r.returncode,'pass':record['pass']}),flush=True)
 return record
sim=runtime/'sim/preload.mjs'
strict={**base_env,'DSH_GO_OHOS_SIM':'1','DSH_GO_OHOS_SIM_PLATFORM':'openharmony','DSH_GO_OHOS_SIM_ADDONS':json.dumps([str(addon)])}
for mode,flags_for_node,env in [('jit',[],base_env),('strict',['--jitless','--import',sim],strict)]:
 for scenario in ['main','inherit','late-parent','worker-local','legacy-late','publication']:
  run_case(mode+'-'+scenario,[*flags_for_node,here/'main.mjs',scenario],env,expect_sim=(mode=='strict'))
run_case('null-environment-before-start',['--version'],{**base_env,'LD_PRELOAD':str(null_lib)},wanted=-signal.SIGABRT)
run_case('reviewed-host-modern-main',['--jitless','--import',runtime/'preload.mjs',here/'main.mjs','main'],{**base_env,'LD_PRELOAD':str(host_lib)},expect_sim=False)
blocked_sentinel=output/'host-extra-bootstrap-sentinel'
run_case('reviewed-host-rejects-extra-bootstrap',['--jitless','--import',runtime/'preload.mjs','--import',here/'bootstrap.mjs',dsh_bin],{**base_env,'LD_PRELOAD':str(host_lib),'DSH_M6_BOOTSTRAP_SENTINEL':str(blocked_sentinel)},wanted=64,contains='ERR_OHOS_HOST_ARGV',sentinel_absent=blocked_sentinel)
for phase in ['before','after']:
 home=output/('app-data-'+phase);home.mkdir(mode=0o700)
 sentinel=output/('bootstrap-'+phase+'.sentinel')
 env={**strict,'DSH_HOME':str(home),'DSH_M6_BOOTSTRAP_SENTINEL':str(sentinel)}
 parts=[here/'bootstrap.mjs',runtime/'preload.mjs'] if phase=='before' else [runtime/'preload.mjs',here/'bootstrap.mjs']
 cli=['--jitless','--import',sim]
 for part in parts:cli+=['--import',part]
 cli+=['--import',here/'observe-wrapper.mjs',dsh_bin]
 run_case('instrumented-bootstrap-'+phase+'-wrapper',cli,env,wanted=0 if phase=='before' else 1,
          contains=None if phase=='before' else 'ERR_OHOS_PUBLICATION_BINDING_MISSING',
          sentinel_absent=None if phase=='before' else sentinel)
# Preserve the exact runner and one CLI import. Only the old registration is
# linked to an explicit test no-op, and the imported wrapper is a marked fixture.
# Thus this is a feasible experiment, not the unchanged product or a HAP test.
candidate=build/'single-import/runtime/ohos/preload.mjs'
candidate.parent.mkdir(parents=True)
shutil.copy2(here/'single-import-wrapper.mjs',candidate)
for name,enabled,equal_form in [('dynamic-single-import-split',True,False),('dynamic-single-import-equals',True,True),('missing-single-import',False,False)]:
 home=output/('app-data-'+name);home.mkdir(mode=0o700)
 sentinel=output/(name+'.sentinel')
 env={**strict,'LD_PRELOAD':str(dynamic_host),'DSH_HOME':str(home),
      'DSH_M6_BOOTSTRAP_SENTINEL':str(sentinel),'DSH_M6_TEST_RUNTIME':str(runtime),
      'DSH_M6_TEST_FIXTURES':str(here),'DSH_M6_TEST_REGISTER':'modern' if enabled else 'missing'}
 cli=['--jitless']+(['--import='+str(candidate)] if equal_form else ['--import',candidate])+[dsh_bin]
 run_case(name,cli,env,wanted=0 if enabled else 1,
          contains=None if enabled else 'ERR_OHOS_PUBLICATION_BINDING_MISSING',
          sentinel_absent=None if enabled else sentinel)
# Keep the whole observation matrix even if one assertion failed.
inputs_after={str(p.relative_to(runtime)):sha(p.read_bytes()) for p in sorted(runtime.rglob('*')) if p.is_file()}
report={'scope':'M6-5 experimental public API and timing only; production sources unchanged',
 'nodeVersion':subprocess.check_output([str(node),'--version'],text=True).strip(),'nodeSHA256':sha(node.read_bytes()),
 'nodeHeaderSHA256':input_pins['nodeHeaders'],
 'compiler':{'path':compiler,'version':subprocess.check_output([compiler,'--version'],text=True).splitlines()[0]},
 'fixedProductInputs':fixed,'runtimeSourceFiles':initial_inputs,'runtimeSourceUnchanged':initial_inputs==inputs_after,
 'experimentSources':{str(p.relative_to(here)):sha(p.read_bytes()) for p in sorted(here.rglob('*')) if p.is_file()},
 'builds':build_records,'artifacts':{str(p.relative_to(build)):{'sha256':sha(p.read_bytes()),'bytes':p.stat().st_size} for p in build.rglob('*') if p.is_file()},
 'cases':cases,'passed':sum(c['pass'] for c in cases),'total':len(cases),
 'targetSDKABIArkHapDevice':'NOT_RUN','fullEmbeddingLifecycleReplacement':'NOT_IMPLEMENTED','fullDSHAppRound':'NOT_RUN'}
(output/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'passed':report['passed'],'total':report['total'],'productUnchanged':report['runtimeSourceUnchanged']}))
sys.exit(0 if report['passed']==report['total'] and report['runtimeSourceUnchanged'] else 1)
