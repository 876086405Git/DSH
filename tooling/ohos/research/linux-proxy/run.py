#!/usr/bin/env python3
"""Actual guest proxy transports with privacy-minimized evidence; no full gate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, default=ROOT)
parser.add_argument('--node', type=Path, required=True)
parser.add_argument('--dsh-prefix', type=Path, required=True)
parser.add_argument('--native-library-dir', type=Path, required=True)
parser.add_argument('--publication-fixture', type=Path, required=True)
parser.add_argument('--assets', type=Path, required=True)
parser.add_argument('--archive', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--baseline-control', type=Path)
parser.add_argument('--baseline-sha256')
parser.add_argument('--existing-private', type=Path)
args = parser.parse_args()
output = args.output.resolve()
budget = os.statvfs(output.parent)
free = budget.f_bavail * budget.f_frsize
required = 128000000 if args.existing_private else 1850000000
assert free >= required, 'Insufficient fixed budget for the selected fresh-install/resume-only scope; no VM started'
output.mkdir(parents=True, exist_ok=False)


def identity(path):
    info = path.stat()
    with path.open('rb') as stream:
        sha = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {'sha256': sha, 'bytes': info.st_size, 'mode': oct(stat.S_IMODE(info.st_mode))}


def save(name, value):
    path = output / name
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    path.chmod(0o600)


source = args.source.resolve()
retained = None
if args.existing_private:
    assert not args.baseline_control and not args.baseline_sha256
    existing = args.existing_private.resolve()
    records = list(existing.glob('*/instance.json'))
    assert len(records) == 1 and existing.is_dir() and not args.existing_private.is_symlink()
    record = json.loads(records[0].read_text())
    assert record['state'] == 'clean' and record['target']['name'] == 'target.ext4'
    target = records[0].parent / 'target.ext4'
    info = target.stat()
    retained = {'directory': str(existing), 'checkpoint': record, 'checkpointIdentity': identity(records[0]),
                'target': {'dev': str(info.st_dev), 'ino': str(info.st_ino), 'bytes': info.st_size}}
    save('RETAINED-BEFORE.json', retained)
assets = args.assets.resolve()
manifest = json.loads((assets / 'install-manifest.json').read_text())
names = {'bios': 'bbl64.bin', 'kernel': 'kernel-riscv64.bin', 'tools': 'tools.block',
         'bootstrap': 'bootstrap.ext4.gz', 'empty': 'empty.ext4.gz'}
assert {path.name for path in assets.iterdir()} == {'install-manifest.json', *names.values()}
for role, name in names.items():
    assert manifest[role]['path'] == name and not (assets / name).is_symlink()
    item = identity(assets / name)
    assert item['bytes'] == manifest[role]['bytes'] and item['sha256'] == manifest[role]['sha256']
archive = args.archive.resolve()
assert all(identity(archive)[key] == manifest['archive'][key] for key in ['bytes', 'sha256'])
native = args.native_library_dir.resolve() / 'libdsh_linux.so'
publication = args.publication_fixture.resolve()
assert native.read_bytes()[:4] == publication.read_bytes()[:4] == b'\x7fELF'
node = args.node.resolve()
originals = {}
for directory in ['linux', 'net', 'sim']:
    destination = output / 'source/runtime/ohos' / directory
    destination.mkdir(parents=True)
    for path in sorted((source / 'runtime/ohos' / directory).glob('*.mjs')):
        shutil.copy2(path, destination / path.name)
        originals[str(path.relative_to(source))] = identity(path)
programs = ['guest-proxy.mjs', 'proxy-pair.mjs', 'proxy-fixture.mjs', 'proxy-fixture.test.mjs']
for name in programs:
    shutil.copy2(HERE / name, output / name)
shutil.copy2(Path(__file__), output / 'run.py')
(output / 'node_modules').symlink_to(args.dsh_prefix.resolve() / 'node_modules', target_is_directory=True)
auth_path = args.dsh_prefix.resolve() / 'node_modules/@deepseek-ai/dsh-client-connection/lib/index.js'
auth = auth_path.read_text()
assert 'from "./' not in auth and "from './" not in auth
(output / 'actual-browser-auth.mjs').write_text(auth + '\nexport { BrowserAuth };\n')
baseline = None
if args.baseline_control:
    baseline = identity(args.baseline_control)
    assert args.baseline_sha256 and baseline['sha256'] == args.baseline_sha256
    shutil.copy2(args.baseline_control, output / 'source/runtime/ohos/linux/control-baseline.mjs')
else:
    assert args.baseline_sha256 is None
for name in ['child-home', 'child-tmp']:
    (output / name).mkdir(mode=0o700)
    (output / name).chmod(0o700)
environment = {'PATH': str(node.parent) + ':/usr/bin:/bin', 'HOME': str(output / 'child-home'),
               'TMPDIR': str(output / 'child-tmp'), 'LANG': 'C.UTF-8'}
input_catalog = {
    'node': {'path': str(node), **identity(node)}, 'sourceRoot': str(source), 'originalSource': originals,
    'source': {str(path.relative_to(output)): identity(path) for path in sorted((output / 'source').rglob('*')) if path.is_file()},
    'programs': {name: identity(output / name) for name in programs + ['run.py', 'actual-browser-auth.mjs']},
    'actualBrowserAuth': identity(auth_path), 'lock': identity(args.dsh_prefix / 'package-lock.json'),
    'native': {'path': str(native), **identity(native)},
    'publicationFixture': {'path': str(publication), **identity(publication)},
    'manifest': {'path': str(assets / 'install-manifest.json'), **identity(assets / 'install-manifest.json')},
    'assets': {name: identity(assets / name) for name in names.values()},
    'archive': {'path': str(archive), **identity(archive)},
    'baselineControl': baseline, 'parentEnvironment': environment,
    'openssl': {'path': '/usr/bin/openssl', **identity(Path('/usr/bin/openssl'))},
    'spaceBefore': {'availableBytes': free, 'requiredBytes': required,
                   'plannedNewDataBytesUpperBound': 16000000 if retained else 1350000000,
                   'reservedSharedBuildBytes': 112000000 if retained else 500000000},
    'retainedBefore': retained,
    'evidencePolicy': 'Anonymous stdin pipe carries fixture proxy endpoints/password. No pipe payload, raw HTTP/wire, arbitrary stdout/stderr or generated TLS private key is exported. Parent/child startup environments are explicit non-secret dictionaries.',
}
save('INPUTS.json', input_catalog)
checks = []
for name in programs:
    argv = [str(node), '--check', str(output / name)]
    result = subprocess.run(argv, env=environment, capture_output=True, timeout=30)
    checks.append({'argv': argv, 'exitCode': result.returncode})
    assert result.returncode == 0, ('syntax', name)
save('SYNTAX.json', checks)
argv = [str(node), '--test', '--test-reporter=tap', str(output / 'proxy-fixture.test.mjs')]
preflight = subprocess.run(argv, env=environment, capture_output=True, timeout=45)
# This preflight's only assertions have fixed labels/booleans and known public
# nonce/certificate facts. It never prints settings, random Basic auth or keys.
(output / 'preflight.stdout.log').write_bytes(preflight.stdout)
(output / 'preflight.stderr.log').write_bytes(preflight.stderr)
save('PREFLIGHT.json', {'argv': argv, 'exitCode': preflight.returncode})
assert preflight.returncode == 0, 'fixture preflight; no VM started'
argv = [str(node), str(output / 'proxy-pair.mjs'), str(output), str(node),
        str(args.native_library_dir.resolve()), str(assets), str(archive), str(publication), 'yes' if baseline else 'no']
if retained:
    argv.append(retained['directory'])
start = time.monotonic_ns()
try:
    process = subprocess.run(argv, env=environment, capture_output=True, timeout=900)
    exit_code, stdout_bytes, stderr_bytes = process.returncode, len(process.stdout), len(process.stderr)
except subprocess.TimeoutExpired as error:
    exit_code, stdout_bytes, stderr_bytes = 124, len(error.stdout or b''), len(error.stderr or b'')
save('COORDINATOR.json', {'argv': argv, 'environment': environment, 'exitCode': exit_code,
    'startNs': str(start), 'endNs': str(time.monotonic_ns()),
    'stdoutBytesDiscarded': stdout_bytes, 'stderrBytesDiscarded': stderr_bytes,
    'scope': 'Uncertain timeout/termination is never a retirement ACK; target is not deleted or replaced.'})
source_unchanged = all(identity(source / name) == value for name, value in originals.items())
copies_unchanged = all(identity(output / name) == value for name, value in input_catalog['source'].items())
programs_unchanged = all(identity(output / name) == value for name, value in input_catalog['programs'].items())
save('SOURCE-AFTER.json', {'sourceUnchanged': source_unchanged, 'copiesUnchanged': copies_unchanged, 'programsUnchanged': programs_unchanged})
assert source_unchanged and copies_unchanged and programs_unchanged, 'Frozen execution input changed'
print(json.dumps({'output': str(output), 'exitCode': exit_code, 'sourceUnchanged': True}))
raise SystemExit(exit_code)
