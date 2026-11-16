#!/usr/bin/env python3
"""Run the O4b Git suites in a fresh host process; this is not an OHOS build."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--node', required=True)
parser.add_argument('--linked', required=True)
parser.add_argument('--prefix', required=True, help='Private, OHOS-patched DSH prefix')
parser.add_argument('--suite', choices=['client', 'oracle', 'semantics', 'worker'], required=True)
parser.add_argument('--mode', choices=['jit', 'strict'], required=True)
parser.add_argument('--record-native', action='store_true')
parser.add_argument('--output', required=True)
args = parser.parse_args()
if args.record_native and (args.suite not in ['oracle', 'semantics'] or args.mode != 'jit'):
    parser.error('--record-native requires --suite oracle/semantics --mode jit')

root = Path(__file__).resolve().parents[3]
output = Path(args.output).resolve()
output.mkdir(parents=True, exist_ok=False)
node, linked, prefix = (Path(value).resolve() for value in (args.node, args.linked, args.prefix))
test = root / 'runtime/tests/ohos' / {
    'client': 'git-owned-client.test.mjs',
    'oracle': 'git.test.mjs',
    'semantics': 'git-selection.test.mjs',
    'worker': 'process-git-integration.test.mjs',
}[args.suite]
sha = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
now = lambda: datetime.datetime.now(datetime.timezone.utc).isoformat()
home = Path(tempfile.mkdtemp(prefix='dsh-o4b-git-home-'))
overrides = {
    'NODE_OPTIONS': '', 'LD_PRELOAD': str(linked), 'DSH_HOME': str(home),
    'DSH_TEST_PREFIX': str(prefix), 'OHOS_TEST_GIT_PREFIX': str(prefix),
    'DSH_O4B_EXPECT_STRICT': '1' if args.mode == 'strict' else '0',
}
removed = ['DSH_GO_OHOS_SIM', 'DSH_O4B_PARENT_ROOT', 'DSH_O4B_GIT_ROOT',
           'DSH_GIT_ORACLE', 'DSH_GO_OHOS_SIM_PLATFORM', 'DSH_GO_OHOS_SIM_ADDONS']
argv = [str(node)]
if args.mode == 'strict':
    overrides.update(DSH_GO_OHOS_SIM_PLATFORM='openharmony', DSH_GO_OHOS_SIM_ADDONS='[]')
    argv += ['--jitless', '--import', str(root / 'runtime/ohos/sim/preload.mjs')]
else:
    argv += ['--import', str(root / 'runtime/ohos/sim/marker.mjs')]
if args.suite == 'worker':
    argv += ['--import', str(root / 'runtime/ohos/net/preload.mjs')]
if args.record_native:
    overrides['DSH_GIT_ORACLE'] = 'record'
argv += ['--test', '--test-reporter=tap', str(test)]
if args.mode == 'strict':
    argv = [sys.executable, str(root / 'runtime/tests/ohos/process-link-fixture.py'),
            '--evidence', str(output / 'host-link-fixture.json'), '--', *argv]
env = {key: value for key, value in os.environ.items() if key not in removed}
if args.mode == 'strict':
    overrides['OHOS_TEST_LINK_LD_PRELOAD'] = overrides.pop('LD_PRELOAD')
env.update(overrides)
sources = [path for directory in ['runtime/ohos/process', 'runtime/ohos/publication']
           for path in sorted((root / directory).glob('*.mjs'))]
record = {
    'scope': 'AUTHOR_RUN Linux real Node/files/ledger/Worker; OHOS target NOT_RUN',
    'suite': args.suite, 'mode': args.mode, 'nativeOracleRecorded': args.record_native,
    'startedUTC': now(), 'argv': argv, 'cwd': str(root),
    'environmentOverrides': overrides, 'environmentRemoved': removed,
    'inputHashes': {str(path): sha(path) for path in [node, linked, test]},
    'sourceHashes': {str(path.relative_to(root)): sha(path) for path in sources},
}
try:
    try:
        result = subprocess.run(argv, cwd=root, env=env, capture_output=True,
                                text=True, timeout=240)
        stdout, stderr, code = result.stdout, result.stderr, result.returncode
    except subprocess.TimeoutExpired as error:
        decode = lambda value: value.decode() if isinstance(value, bytes) else value or ''
        stdout, stderr = decode(error.stdout), decode(error.stderr)
        stderr += '\nTEST DRIVER TIMEOUT: process killed by subprocess.run\n'
        code = 124
    (output / 'stdout.log').write_text(stdout)
    (output / 'stderr.log').write_text(stderr)
    record.update(finishedUTC=now(), exitCode=code,
                  summary=re.findall(r'^# (?:tests|pass|fail|cancelled|skipped|todo) .*$', stdout, re.M),
                  stdoutSHA256=sha(output / 'stdout.log'), stderrSHA256=sha(output / 'stderr.log'))
    (output / 'report.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'output': str(output), 'exitCode': code, 'summary': record['summary']}, ensure_ascii=False))
finally:
    shutil.rmtree(home)
raise SystemExit(code)
