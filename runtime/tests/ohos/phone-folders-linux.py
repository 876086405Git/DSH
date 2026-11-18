#!/usr/bin/env python3
"""Phone folder protocol through the actual composed Node file provider."""
from pathlib import Path
import argparse, hashlib, json, os, subprocess, time

p=argparse.ArgumentParser(description=__doc__)
for name in ['source','payload','manifest','node','typescript-prefix','native-directory','publication-fixture','out']:
    p.add_argument('--'+name,type=Path,required=True)
p.add_argument('--jitless',action='store_true')
a=p.parse_args()
source,payload,manifest,node,typescript,native,publication,out=[x.resolve()for x in [a.source,a.payload,a.manifest,a.node,a.typescript_prefix,a.native_directory,a.publication_fixture,a.out]]
out.mkdir(parents=True,exist_ok=False)
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
def save(name,value):(out/name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
rows={r['path']:r for r in json.loads(manifest.read_text())['files']}
runtime=['runtime/ohos/preload.mjs']
runtime+=['runtime/ohos/process/files/'+name for name in ['authority.mjs','process-authority.mjs','grant-fs.mjs','workspace-paths.mjs','workspace-edit.mjs']]
modules=['node_modules/@deepseek-ai/'+name+'/lib/index.js' for name in ['cordis','dsh-session-projection','dsh-sandbox-policy','dsh-fs-sandbox','dsh-fs-local']]
for name in runtime+modules+['node_modules/@deepseek-ai/dsh/lib/bin.js']:
    assert sha(payload/name)==rows[name]['sha256'],name
for name in runtime:assert sha(source/name)==sha(payload/name),name
version=json.loads((typescript/'node_modules/typescript/package.json').read_text())['version']
assert version.startswith('5.9.'),'TypeScript 5.9 series required'
tests=['phone-folders-linux.py','phone-folders-entry.mjs','phone-folders-instrumentation.mjs','authorized-workspaces-fixture.mjs','entry-ability-fixture.mjs']
products=['app/ohos/entry/src/main/module.json5','app/ohos/entry/src/main/ets/plugins/AuthorizedWorkspacesPlugin.ets','app/ohos/entry/src/main/ets/plugins/NativeFilePolicy.ets','app/ohos/entry/src/main/ets/entryability/EntryAbility.ets']
products+=['app/ohos/entry/src/main/cpp/'+name for name in ['workspace_grants.cpp','workspace_grants.h','workspace_grants_abi.h','workspace_fids.h','workspace_fids_abi.h']]
products+=['runtime/ohos/process/files/addon.cc','runtime/tests/ohos/workspace-grants-addon.cc','tooling/ohos/run-gates.py']
paths=[source/n for n in products]+[source/'runtime/tests/ohos'/n for n in tests]+[payload/n for n in runtime+modules+['node_modules/@deepseek-ai/dsh/lib/bin.js']]
paths += [native/n for n in ['libdsh_host.so','libdsh_workspace_grants.so','workspace-publisher.node','libdsh_flock.so','libdsh_require_builtin.so']]
paths += [node,manifest,publication,typescript/'node_modules/typescript/lib/typescript.js']
snapshot=lambda:{str(path):{'bytes':path.stat().st_size,'sha256':sha(path)}for path in paths}
before=snapshot();save('INPUTS.json',before)
for name in ['home','tmp','linux-tools']:(out/name).mkdir(mode=0o700)
config={'source':str(source),'payload':str(payload),'nativeDirectory':str(native),'result':str(out/'REPORT.json')}
save('CONFIG.json',config)
environment={'PATH':str(node.parent)+os.pathsep+os.defpath,'HOME':str(out/'home'),'TMPDIR':str(out/'tmp'),'LANG':'C.UTF-8',
 'LD_PRELOAD':str(native/'libdsh_host.so')+':'+str(publication),'DSH_HOME':str(out/'home'),'NARB_DISABLE_NATIVE_CACHE':'1',
 'DSH_GO_OHOS_NATIVE_LIBRARY_DIR':str(native),'DSH_GO_OHOS_LINUX_DIRECTORY':str(out/'linux-tools'),
 'DSH_GO_OHOS_SIM_PLATFORM':'openharmony','OHOS_PHONE_FOLDER_CONFIG':str(out/'CONFIG.json'),
 'OHOS_TYPESCRIPT_PREFIX':str(typescript),'OHOS_WORKSPACE_GRANTS_ADDON':str(native/'workspace-publisher.node')}
here=source/'runtime/tests/ohos'
command=[str(node),*(['--jitless']if a.jitless else []),'--max-old-space-size=256',
 '--import',str(here/'phone-folders-instrumentation.mjs'),'--import',str(payload/'runtime/ohos/preload.mjs'),
 '--import',str(here/'phone-folders-entry.mjs'),str(payload/'node_modules/@deepseek-ai/dsh/lib/bin.js'),'--profile','web','--dump-config']
save('COMMAND.json',{'argv':command,'environment':environment,'cwd':str(out)})
start=time.monotonic()
with(out/'stdout').open('wb')as stdout,(out/'stderr').open('wb')as stderr:
    try:code=subprocess.run(command,cwd=out,env=environment,stdout=stdout,stderr=stderr,timeout=90).returncode
    except subprocess.TimeoutExpired:code=124
after=snapshot();save('SOURCE-AFTER.json',after)
report=json.loads((out/'REPORT.json').read_text())if(out/'REPORT.json').is_file()else{}
save('wire.json',report.get('wire',[]))
result={'status':'PASS_SCOPED'if code==0 and report.get('pass')and before==after else'FAIL',
 'exitCode':code,'seconds':time.monotonic()-start,'inputsUnchanged':before==after,'cases':len(report.get('cases',[])),
 'passedCases':sum(row.get('pass')is True for row in report.get('cases',[])),
 'scope':'Actual composed DSH preload and public Node read/write over real FD leases; explicit OS grant/picker boundaries; no SDK/HAP/device claim',
 'typescriptVersion':version,'stdoutSha256':sha(out/'stdout'),'stderrSha256':sha(out/'stderr')}
save('RESULT.json',result);print(json.dumps(result,ensure_ascii=False));raise SystemExit(0 if result['status']=='PASS_SCOPED'else 1)
