#!/usr/bin/env python3
"""Real product Host/reader DSOs on Linux; explicit runner/hilog/deviceinfo substitutes, not target SDK."""
from pathlib import Path
import argparse,importlib.util,subprocess,os,json,hashlib,time
def replace_one(source,marker,replacement):
    if source.count(marker)!=1:
        raise RuntimeError('Native DSO test fixture marker must occur exactly once: '+marker)
    return source.replace(marker,replacement,1)
R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__)
for name in ['node-root','ohos-headers','prefix','optional-node-modules','out']:p.add_argument('--'+name,required=True,type=Path)
a=p.parse_args();N=a.node_root.resolve();H=a.ohos_headers.resolve();O=a.out.resolve();O.mkdir(parents=True,exist_ok=False)
C=R/'app/ohos/entry/src/main/cpp';P=R/'runtime/ohos/host'
spec=importlib.util.spec_from_file_location('adapter',Path(__file__).with_name('host-adapter.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
(O/'libs').mkdir();(O/'stub.cc').write_text(m.STUB)
(O/'device.cc').write_text('extern "C" { const char* OH_GetOSFullName(){return "test";} const char* OH_GetDisplayVersion(){return "test";} const char* OH_GetIncrementalVersion(){return "test";} const char* OH_GetSecurityPatchTag(){return "test";} }')
version=json.loads((R/'runtime/ohos/node-version.json').read_text());parts=version.split('.')
(O/'dsh_node_version.h').write_text('#pragma once\n#define DSH_NODE_VERSION_STRING "'+version+'"\n'+''.join(f'#define DSH_NODE_VERSION_{key} {value}\n' for key,value in zip(['MAJOR','MINOR','PATCH'],parts)))
rows=[]
def run(argv,env=None):
 t=time.time();p=subprocess.run(argv,capture_output=True,text=True,env=env,timeout=60);rows.append(dict(command=argv,exit=p.returncode,seconds=time.time()-t,stdout=p.stdout,stderr=p.stderr));(O/'report.json').write_text(json.dumps(rows,indent=2));print(p.stdout,p.stderr[-3000:]);p.check_returncode()
(O/'libnode.cc').write_text('extern \"C\" int dsh_host_adapter_fixture_libnode() { return 0; }\n')
run([os.environ.get('CXX','g++'),'-shared','-fPIC','-Wl,-soname,libnode.so',str(O/'libnode.cc'),'-o',str(O/'libs/libnode.so')])
run([os.environ.get('CXX','g++'),'-std=c++17','-shared','-fPIC','-pthread','-Wall','-Wextra','-Werror','-Wno-format','-I',str(H),'-isystem',str(N/'include/node'),str(C/'host_core.cpp'),str(C/'napi_host.cpp'),str(C/'workspace_grants.cpp'),str(O/'stub.cc'),'-Wl,--no-as-needed','-L',str(O/'libs'),'-l:libnode.so','-Wl,-rpath,'+str(O/'libs'),'-o',str(O/'libs/libdsh_host.so')])
run([os.environ.get('CXX','g++'),'-std=c++20','-shared','-fPIC','-pthread','-Wall','-Wextra','-Werror','-Wno-deprecated-declarations','-DDSH_PUBLICATION_TEST_PRELOAD','-isystem',str(N/'include/node'),'-I',str(O),'-I',str(R/'runtime/tests/ohos/publication-deviceinfo-fixture'),str(P/'publication_binding.cc'),str(O/'device.cc'),'-o',str(O/'reader.so'),'-ldl'])
s=replace_one(m.SCRIPT,'const host = require(process.argv[2]);','const loaded={exports:{}};process.dlopen(loaded,process.argv[2]);const host=loaded.exports;')
s=replace_one(s,"nativeLibraryDir:path.join(base,'libs')",'nativeLibraryDir:process.env.DSH_GO_OHOS_NATIVE_LIBRARY_DIR')
needle='  const events=host.drainEvents();host.stop();'
s=replace_one(s,needle,Path(__file__).with_name('phone-native-dso-cases.cjs').read_text()+'\n'+needle);(O/'run.cjs').write_text(s)
e=os.environ.copy();e.update(LD_PRELOAD=str(O/'reader.so'),DSH_GO_OHOS_NATIVE_LIBRARY_DIR=str(O/'libs'),DSH_LIFECYCLE_TEST_PREFIX=str(a.prefix.resolve()),NODE_PATH=str(a.optional_node_modules.resolve()),DSH_BACKGROUND_SOURCE=str(R))
run([str(N/'bin/node'),'--jitless',str(O/'run.cjs'),str(O/'libs/libdsh_host.so'),str(O/'fixture'),'normal'],e)
inputs=[Path(__file__).with_name('host-adapter.py'),O/'run.cjs',C/'host_core.cpp',C/'host_core.h',C/'napi_host.cpp',C/'workspace_grants.cpp',C/'workspace_grants.h',C/'workspace_grants_abi.h',C/'lifecycle_state.h',C/'phone_state.h',P/'phone_contract.h',P/'publication_binding.cc',P/'lifecycle_snapshot.h',Path(__file__),Path(__file__).with_name('phone-native-dso-cases.cjs'),Path(__file__).with_name('lifecycle-engine-fixture.mjs'),R/'runtime/ohos/lifecycle/coordinator.mjs',a.prefix.resolve()/'node_modules/@deepseek-ai/dsh-agent-loop/lib/index.js']
(O/'identity.json').write_text(json.dumps({'scope':__doc__,'sources':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},'binaries':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [O/'reader.so',O/'libs/libdsh_host.so',O/'libs/libnode.so']},'environment':{key:e[key] for key in ['LD_PRELOAD','DSH_GO_OHOS_NATIVE_LIBRARY_DIR','DSH_LIFECYCLE_TEST_PREFIX','NODE_PATH','DSH_BACKGROUND_SOURCE']}},indent=2))
