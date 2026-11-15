#!/usr/bin/env python3
"""Production ETS, real Linux file descriptors, explicit OH picker/Flutter boundary doubles."""
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
p.add_argument('--typescript-prefix', required=True, type=Path)
p.add_argument('--out', required=True, type=Path)
a = p.parse_args()
repo = Path(__file__).resolve().parents[3]
out = a.out.resolve(); out.mkdir(parents=True, exist_ok=True)
sources = [repo / 'app/ohos/entry/src/main/ets/plugins/NativeFilesPlugin.ets',
           repo / 'app/ohos/entry/src/main/ets/plugins/NativeFilePolicy.ets',
           *sorted((repo / 'runtime/tests/ohos').glob('native-files*'))]
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
for source in sources:
    target = out / 'sources' / source.relative_to(repo)
    target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(source.read_bytes())
argv = [str(a.node.resolve()), '--test', '--test-isolation=none', '--test-reporter=tap',
        str(repo / 'runtime/tests/ohos/native-files.test.mjs')]
fifo = out / 'test.fifo'
if fifo.exists(): fifo.unlink()
os.mkfifo(fifo)
env = {'OHOS_TYPESCRIPT_PREFIX': str(a.typescript_prefix.resolve()), 'OHOS_NATIVE_FIFO': str(fifo)}
start = time.time()
with (out / 'logic.log').open('wb') as log:
    try:
        code = subprocess.run(argv, cwd=repo, env=dict(os.environ, **env), stdout=log,
                              stderr=subprocess.STDOUT, timeout=120).returncode
    except subprocess.TimeoutExpired:
        code = 124
fifo.unlink()
counts = {key: int(value) for key, value in re.findall(r'^# (tests|pass|fail|cancelled|skipped) (\d+)$',
                                                    (out / 'logic.log').read_text(), re.M)}
report = {'argv': argv, 'environment': env, 'exitCode': code, 'counts': counts,
          'elapsedSeconds': time.time() - start, 'nodeSha256': sha(a.node.resolve()),
          'sources': {str(source.relative_to(repo)): sha(source) for source in sources},
          'scope': 'Actual ETS + actual Linux FS; OH chooser, URI grant, lifecycle and Flutter explicitly adapted; NOT target SDK compilation or device verification'}
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({'exitCode': code, 'counts': counts, 'report': str(out / 'report.json')}, indent=2))
raise SystemExit(code)
