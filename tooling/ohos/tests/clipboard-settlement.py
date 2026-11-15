#!/usr/bin/env python3
"""Reproduce the pinned helper and haptic failures, prepare a private HAR, test the same assertions.

All source/consumer code comes from the verified HAR. The test never requests OS
permission, accesses the user's clipboard or vibrates. Node runs node:test in-process.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import time

p = argparse.ArgumentParser()
p.add_argument('--input-har', required=True, type=Path)
p.add_argument('--node', required=True, type=Path)
p.add_argument('--typescript-prefix', required=True, type=Path)
p.add_argument('--output', required=True, type=Path)
a = p.parse_args()
repo = Path(__file__).resolve().parents[3]
manifest_path = repo / 'tooling/ohos/embedding-fixes/pasteboard-settlement.json'
manifest = json.loads(manifest_path.read_text())
archive = a.input_har.read_bytes()
assert hashlib.sha256(archive).hexdigest() == manifest['upstream']['harSha256'], 'original pinned HAR required'
targets = sorted(fix['target'] for fix in manifest['fixes'])
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=False)
before = out / 'before'
before.mkdir()
with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
    tar.extractall(before, filter='data')
env = dict(os.environ, OHOS_TYPESCRIPT_PREFIX=str(a.typescript_prefix.resolve()))
commands = []

def run(argv, label):
    start = time.monotonic()
    result = subprocess.run(argv, cwd=repo, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / (label + '.log')).write_bytes(result.stdout)
    commands.append({'argv': argv, 'cwd': str(repo), 'exit': result.returncode,
                     'seconds': time.monotonic() - start})
    (out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
    print(label + ': exit ' + str(result.returncode))
    return result

node = str(a.node.resolve())
test = str(repo / 'tooling/ohos/tests/clipboard-settlement.mjs')
haptics = str(repo / 'tooling/ohos/tests/haptic-presets.mjs')
baseline = run([node, test, str(before / 'package'), str(manifest_path), str(out / 'before-observations.json')], 'before')
assert baseline.returncode == 1, 'the pinned original must fail the unchanged settlement assertions'
haptics_before = run([node, haptics, str(before / 'package')], 'haptics-before')
assert haptics_before.returncode == 1, 'the pinned original must fail the unchanged haptic assertions'
patched = out / 'prepared'
command = ['python3', str(repo / 'tooling/ohos/prepare-pasteboard.py'), '--input-har', str(a.input_har.resolve()), '--output', str(patched)]
prepared = run(command, 'prepare')
assert prepared.returncode == 0, prepared.stdout.decode()
after = run([node, test, str(patched / 'package'), str(manifest_path), str(out / 'after-observations.json')], 'after')
print(after.stdout.decode('utf-8', errors='replace'))
assert after.returncode == 0, 'patched actual helper/consumer assertions must pass'
haptics_after = run([node, haptics, str(patched / 'package')], 'haptics-after')
print(haptics_after.stdout.decode('utf-8', errors='replace'))
assert haptics_after.returncode == 0, 'patched actual haptic assertions must pass'

# Preparation gates: output immutability, unknown input and archive/extracted parity.
existing = run(command, 'reject-existing-output')
assert existing.returncode != 0
bad = out / 'wrong-input.har'
bad.write_bytes(archive + b'changed')
bad_output = out / 'must-not-exist'
rejected = run(['python3', str(repo / 'tooling/ohos/prepare-pasteboard.py'), '--input-har', str(bad), '--output', str(bad_output)], 'reject-unknown-har')
assert rejected.returncode != 0 and not bad_output.exists()
preparation = json.loads((patched / 'report.json').read_text())
repeat = out / 'prepared-again'
repeated = run(['python3', str(repo / 'tooling/ohos/prepare-pasteboard.py'), '--input-har', str(a.input_har.resolve()), '--output', str(repeat)], 'repeat-prepare')
assert repeated.returncode == 0
assert (repeat / 'flutter_embedding_release.har').read_bytes() == (patched / 'flutter_embedding_release.har').read_bytes()
assert sorted(preparation['changedFiles']) == targets
assert hashlib.sha256(a.input_har.read_bytes()).hexdigest() == manifest['upstream']['harSha256']
with tarfile.open(patched / 'flutter_embedding_release.har', mode='r:gz') as tar:
    archived = {m.name: hashlib.sha256(tar.extractfile(m).read()).hexdigest() for m in tar.getmembers() if m.isfile()}
assert archived == preparation['after']
assert archived == {name: hashlib.sha256((patched / name).read_bytes()).hexdigest() for name in archived}
assert all(preparation['before'][name] == value for name, value in archived.items() if name not in targets)
for name, expected in manifest['licenses'].items():
    assert hashlib.sha256((patched / 'licenses' / name).read_bytes()).hexdigest() == expected
report = {'beforeExit': baseline.returncode, 'afterExit': after.returncode,
          'hapticsBeforeExit': haptics_before.returncode, 'hapticsAfterExit': haptics_after.returncode,
          'nodeSha256': hashlib.sha256(a.node.read_bytes()).hexdigest(),
          'testSha256': hashlib.sha256(Path(test).read_bytes()).hexdigest(),
          'manifestSha256': hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
          'sourceHarSha256': manifest['upstream']['harSha256'],
          'patchedHarSha256': preparation['outputHarSha256'],
          'gate': 'existing output refused; unknown HAR refused without output; repeat HAR identical; all archive/package files equal; only the fixed files changed; notices preserved',
          'scope': 'Actual ETS method bodies and actual consumer state with explicit public-boundary doubles; not ArkTS or device permission/clipboard/motor verification'}
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
