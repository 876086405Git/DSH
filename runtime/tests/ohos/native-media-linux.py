#!/usr/bin/env python3
"""Actual ETS + actual Linux FD and production safe opener; AVPlayer is an explicit stateful boundary double."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--node', required=True, type=Path)
p.add_argument('--node-headers', required=True, type=Path)
p.add_argument('--typescript-prefix', required=True, type=Path)
p.add_argument('--out', required=True, type=Path)
p.add_argument('--path-provider-source', required=True, type=Path)
p.add_argument('--cxx', default='clang++-18')
a = p.parse_args()
repo = Path(__file__).resolve().parents[3]
out = a.out.resolve(); out.mkdir(parents=True, exist_ok=True)
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
assert sha(a.path_provider_source) == '2f83e9198c035b9b3c9a1947fd759296e7445dc82d75d22065a2b99f8a74023d'
(out/'PathProviderPlugin.ets').write_bytes(a.path_provider_source.read_bytes())
commands = []
def run(name, argv, env=None):
    start = time.time()
    with (out / (name + '.log')).open('wb') as log:
        try:
            code = subprocess.run(argv, cwd=repo, env=dict(os.environ, **(env or {})), stdout=log,
                                  stderr=subprocess.STDOUT, timeout=120).returncode
        except subprocess.TimeoutExpired: code = 124
    commands.append({'name': name, 'argv': argv, 'environment': env or {}, 'exitCode': code, 'elapsedSeconds': time.time()-start})
    (out / 'commands.json').write_text(json.dumps(commands, indent=2)+'\n')
    return code
addon = out / 'user-file-access.node'
assert run('native-build', [a.cxx,'-std=c++17','-shared','-fPIC','-Wall','-Wextra','-Werror','-I',str(a.node_headers.resolve()),
                           str(repo/'runtime/tests/ohos/user-file-access-addon.cc'),'-o',str(addon)]) == 0
sources = [repo/'app/ohos/entry/src/main/ets/plugins'/name for name in ['NativeMediaPlugin.ets','NativeMediaPolicy.ets','OhosClipPlayer.ets']]
sources += [repo/'app/ohos/entry/src/main/cpp/file_access.h',repo/'runtime/tests/ohos/user-file-access-addon.cc',
            *sorted((repo/'runtime/tests/ohos').glob('native-media*'))]
for source in sources:
    target = out/'sources'/source.relative_to(repo);target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(source.read_bytes())
env = {'OHOS_TYPESCRIPT_PREFIX':str(a.typescript_prefix.resolve()),'OHOS_USER_FILE_ADDON':str(addon),
       'OHOS_PATH_PROVIDER_SOURCE':str(a.path_provider_source.resolve())}
code = run('logic',[str(a.node.resolve()),'--test','--test-isolation=none','--test-reporter=tap',str(repo/'runtime/tests/ohos/native-media.test.mjs')],env)
counts = {key:int(value) for key,value in re.findall(r'^# (tests|pass|fail|cancelled|skipped) (\d+)$',(out/'logic.log').read_text(),re.M)}
report = {'exitCode':code,'counts':counts,'nodeSha256':sha(a.node.resolve()),'addonSha256':sha(addon),
          'sources':{str(source.relative_to(repo)):sha(source) for source in sources},
          'scope':'Actual ETS, Linux FS/FD and production native safe opener; explicit AVPlayer/Flutter doubles; no real audio decode/output or target SDK/device claim'}
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'exitCode':code,'counts':counts,'report':str(out/'report.json')},indent=2))
raise SystemExit(code)
