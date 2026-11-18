#!/usr/bin/env python3
"""Download request and verified-cache checks; real local production HTTPS chain."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
from unittest.mock import patch
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
PREPARE = ROOT / 'tooling/ohos/research/linux-job/prepare-inputs.py'
p = argparse.ArgumentParser()
p.add_argument('--inputs', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--node', required=True)
p.add_argument('--openssl', default='openssl')
a = p.parse_args()
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=False)
checks, commands = [], []


def invoke(directory):
    with patch.object(sys, 'argv', [str(PREPARE), '--out', str(directory),
                                  '--alpine-mirror', 'https://repo.huaweicloud.com/alpine']):
        runpy.run_path(str(PREPARE), run_name='__main__')


def run(argv, label, env=None):
    argv = list(map(str, argv))
    result = subprocess.run(argv, cwd=ROOT, capture_output=True, env=env, timeout=120)
    (out / (label + '.stdout')).write_bytes(result.stdout)
    (out / (label + '.stderr')).write_bytes(result.stderr)
    commands.append({'label': label, 'argv': argv, 'exitCode': result.returncode})
    (out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
    return result


class CapturedRequest(Exception):
    pass


observed = []


def capture(request, **options):
    observed.append({'url': request.full_url if isinstance(request, urllib.request.Request) else request,
                     'userAgent': request.get_header('User-agent') if isinstance(request, urllib.request.Request) else None,
                     'timeout': options.get('timeout')})
    raise CapturedRequest()


with patch.object(urllib.request, 'urlopen', capture):
    try:
        invoke(out / 'first-request')
    except CapturedRequest:
        pass
checks.append({'case': 'Python constructs an explicit product UA',
               'pass': len(observed) == 1 and observed[0]['userAgent'] == 'dsh-go-ohos-linux/1',
               'observation': observed})

# Existing pinned inputs are read only: do not redownload, copy or modify them.
lock = json.loads((PREPARE.parent / 'packages.lock.json').read_text())
paths = ['diskimage-linux-riscv-2018-09-23.tar.gz', 'alpine-minirootfs-3.24.4-riscv64.tar.gz']
paths += ['apks/' + row['filename'] for row in lock]
inputs = {}
for name in paths:
    path = a.inputs / name
    inputs[name] = {'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
with patch.object(urllib.request, 'urlopen', side_effect=AssertionError('verified cache must not download')):
    invoke(a.inputs.resolve())
checks.append({'case': 'all 33 real pre-placed pinned files verified without network', 'pass': True, 'inputs': inputs})

corrupt = out / 'corrupt-cache'
corrupt.mkdir()
(corrupt / paths[0]).write_bytes(b'corrupt fixed input')
rejected = False
with patch.object(urllib.request, 'urlopen', side_effect=AssertionError('corrupt cache must not download')):
    try:
        invoke(corrupt)
    except ValueError as error:
        rejected = str(error).startswith('existing input hash mismatch:')
checks.append({'case': 'corrupt pre-placed input is rejected without replacement', 'pass': rejected and
               (corrupt / paths[0]).read_bytes() == b'corrupt fixed input' and not list(corrupt.glob('*.part'))})

cert, key = out / 'local-ca.pem', out / 'local-key.pem'
try:
    result = run([a.openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                  '-subj', '/CN=localhost', '-addext', 'subjectAltName=IP:127.0.0.1',
                  '-keyout', key, '-out', cert], 'tls-fixture')
    assert result.returncode == 0
    env = {**os.environ, 'OHOS_LINUX_UA_TLS_CERT': str(cert), 'OHOS_LINUX_UA_TLS_KEY': str(key)}
    assert env.get('NODE_TLS_REJECT_UNAUTHORIZED') != '0'
    for mode in ['plain', 'strict']:
        flags = ['--jitless', '--import', ROOT / 'runtime/ohos/sim/preload.mjs'] if mode == 'strict' else []
        result = run([a.node, *flags, '--test', '--test-reporter=tap',
                      ROOT / 'runtime/tests/ohos/linux-base-user-agent.test.mjs'], 'https-' + mode, env)
        checks.append({'case': 'actual production HTTPS/TLS/UA ' + mode, 'pass': result.returncode == 0})
finally:
    key.unlink(missing_ok=True)  # Test-only private key is not an evidence artifact.

passed = all(row['pass'] for row in checks)
source_paths = [PREPARE, ROOT / 'runtime/ohos/linux/base-download.mjs', Path(__file__),
                ROOT / 'runtime/tests/ohos/linux-base-user-agent.test.mjs',
                ROOT / 'runtime/ohos/net/fetch.mjs', ROOT / 'runtime/ohos/net/dispatcher.mjs']
(out / 'RESULT.json').write_text(json.dumps({
    'scope': 'Python request-construction spy and real pinned cache; actual local HTTPS with production fetch/dispatcher and explicit local CA; no Huawei availability or device claim',
    'passed': passed, 'checks': checks, 'commands': commands,
    'sources': {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in source_paths},
    'localPrivateKeyRetained': key.exists(),
}, indent=2) + '\n')
print(json.dumps({'passed': passed, 'checks': len(checks), 'passCount': sum(row['pass'] for row in checks)}))
sys.exit(0 if passed else 1)
