#!/usr/bin/env python3
"""Two sequential real Node/VM lifetimes sharing one retained target; no HAP/full gate."""
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
parser.add_argument('--node', type=Path, required=True)
parser.add_argument('--dsh-prefix', type=Path, required=True)
parser.add_argument('--native-library-dir', type=Path, required=True)
parser.add_argument('--publication-fixture', type=Path, required=True)
parser.add_argument('--assets', type=Path, required=True)
parser.add_argument('--archive', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)


def identity(path):
    info = path.stat()
    with path.open('rb') as stream:
        sha = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {'sha256': sha, 'bytes': info.st_size, 'mode': oct(stat.S_IMODE(info.st_mode))}


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def source_identity():
    return {str(path.relative_to(output)): identity(path) for path in sorted((output / 'source').rglob('*')) if path.is_file()}


assets = args.assets.resolve()
manifest = json.loads((assets / 'install-manifest.json').read_text())
names = {'bios': 'bbl64.bin', 'kernel': 'kernel-riscv64.bin', 'tools': 'tools.block',
         'bootstrap': 'bootstrap.ext4.gz', 'empty': 'empty.ext4.gz'}
assert {path.name for path in assets.iterdir()} == {'install-manifest.json', *names.values()}
for key, name in names.items():
    assert manifest[key]['path'] == name and not (assets / name).is_symlink()
    actual = identity(assets / name)
    assert actual['bytes'] == manifest[key]['bytes'] and actual['sha256'] == manifest[key]['sha256']
archive = args.archive.resolve()
archive_identity = identity(archive)
assert archive_identity['bytes'] == manifest['archive']['bytes'] and archive_identity['sha256'] == manifest['archive']['sha256']
native = args.native_library_dir.resolve() / 'libdsh_linux.so'
publication = args.publication_fixture.resolve()
assert native.read_bytes()[:4] == publication.read_bytes()[:4] == b'\x7fELF'
node = args.node.resolve()

for directory in ['linux', 'net', 'sim']:
    destination = output / 'source/runtime/ohos' / directory
    destination.mkdir(parents=True)
    for path in sorted((ROOT / 'runtime/ohos' / directory).glob('*.mjs')):
        shutil.copy2(path, destination / path.name)
(output / 'node_modules').symlink_to(args.dsh_prefix.resolve() / 'node_modules', target_is_directory=True)
for name in ['guest-resume.mjs', 'guest-witness.mjs', 'guest-witness.test.mjs']:
    shutil.copy2(HERE / name, output / name)
auth_path = args.dsh_prefix.resolve() / 'node_modules/@deepseek-ai/dsh-client-connection/lib/index.js'
auth_source = auth_path.read_text()
assert 'from "./' not in auth_source and "from './" not in auth_source
(output / 'actual-browser-auth.mjs').write_text(auth_source + '\nexport { BrowserAuth };\n')
# The production guest protocol inherits scrubbed parent environment values.
# Research wire logs must therefore originate from an explicit non-secret
# environment, never a filtered copy of the coordinator's environment.
child_home, child_tmp = output / 'child-home', output / 'child-tmp'
for directory in [child_home, child_tmp]:
    directory.mkdir(mode=0o700)
    directory.chmod(0o700)
environment = {
    'PATH': str(node.parent) + ':/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
    'HOME': str(child_home), 'TMPDIR': str(child_tmp), 'LANG': 'C.UTF-8',
    'LD_PRELOAD': str(publication), 'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony',
    'DSH_GO_OHOS_SIM_ADDONS': json.dumps([str(native)]),
}
environment_sha256 = hashlib.sha256(json.dumps(environment, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
inputs = {
    'node': {'path': str(node), **identity(node)}, 'source': source_identity(),
    'native': {'path': str(native), **identity(native)},
    'publicationFixture': {'path': str(publication), **identity(publication)},
    'manifest': {'path': str(assets / 'install-manifest.json'), **identity(assets / 'install-manifest.json')},
    'assets': {name: identity(assets / name) for name in names.values()},
    'archive': {'path': str(archive), **archive_identity},
    'lock': identity(args.dsh_prefix / 'package-lock.json'),
    'programs': {name: identity(output / name) for name in ['guest-resume.mjs', 'guest-witness.mjs', 'guest-witness.test.mjs', 'actual-browser-auth.mjs']},
    'actualBrowserAuth': identity(auth_path), 'coordinator': identity(Path(__file__)),
    'childEnvironment': environment, 'childEnvironmentSha256': environment_sha256,
    'scope': 'Same actual supplied asset generation, not a hardcoded historical asset SHA. Only pinned archive download transport is replaced. Actual linked flock and corrected native library must be supplied; no HAP/phone/network/account or power-loss assertion.',
}
write_json(output / 'INPUTS.json', inputs)
commands = []


def run(label, argv, timeout, target):
    start = time.monotonic_ns()
    with (target / 'stdout.log').open('wb') as stdout, (target / 'stderr.log').open('wb') as stderr:
        try:
            result = subprocess.run(argv, env=environment, stdout=stdout, stderr=stderr, timeout=timeout)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code = 124
    row = {'label': label, 'argv': [str(value) for value in argv], 'exitCode': code,
           'startMonotonicNs': str(start), 'endMonotonicNs': str(time.monotonic_ns()),
           'environment': environment, 'environmentSha256': environment_sha256,
           'stdout': identity(target / 'stdout.log'), 'stderr': identity(target / 'stderr.log')}
    commands.append(row)
    write_json(output / 'COMMANDS.json', commands)
    assert code == 0, (label, code, str(target / 'stderr.log'), 'A killed/timed-out child is not proof of retirement; disks remain untouched.')
    assert source_identity() == inputs['source'], 'Frozen source changed during a child lifetime'
    for name, expected in inputs['programs'].items():
        assert identity(output / name) == expected, ('Frozen program changed', name)


preflight = output / 'preflight'
preflight.mkdir()
run('witness-validator-no-vm', [node, '--test', output / 'guest-witness.test.mjs'], 30, preflight)
private = output / 'private-linux'
results = []
prepared_before_resume = None
for phase in ['write', 'read']:
    target = output / phase
    target.mkdir()
    argv = [node, '--jitless', '--import', output / 'source/runtime/ohos/sim/preload.mjs',
            output / 'guest-resume.mjs', args.native_library_dir.resolve(), assets, archive, private, target, phase]
    run(phase, argv, 360, target)
    result = json.loads((target / 'RESULT.json').read_text())
    assert result['passed'] and all(check['pass'] for check in result['checks'])
    assert result['shutdown']['shutdownComplete'] and result['shutdown']['retirement']['cleanCheckpoint']
    assert result['dataDescriptorsBeforeCleanup'] == []
    results.append(result)
    instance = Path(result['active']['directory'])
    prepared = {str(path.relative_to(instance)): {'ino': path.stat().st_ino, 'bytes': path.stat().st_size,
                'mtimeNs': str(path.stat().st_mtime_ns)}
                for folder in instance.glob('.prepare-*') for path in sorted(folder.rglob('*')) if path.is_file()}
    if phase == 'write':
        prepared_before_resume = prepared
        write_json(output / 'PREPARED-BEFORE-RESUME.json', prepared)
    else:
        assert prepared == prepared_before_resume, 'A resumed lifecycle changed/replaced initial prepared inputs'
        write_json(output / 'PREPARED-AFTER-RESUME.json', prepared)
    print(json.dumps({'phase': phase, 'pid': result['pid'], 'checks': len(result['checks']),
                      'cleanCheckpoint': True, 'downloads': result['downloads']}, ensure_ascii=False), flush=True)

first, second = results
assert first['pid'] != second['pid']
assert int(commands[2]['startMonotonicNs']) > int(commands[1]['endMonotonicNs']), 'Second child started before first process exited'
assert first['active']['persistentInstanceId'] == second['active']['persistentInstanceId']
assert first['active']['target'] == second['active']['target']
assert first['active']['epoch'] != second['active']['epoch']
assert first['opened']['instanceId'] != second['opened']['instanceId']
assert first['opened']['attemptId'] != second['opened']['attemptId']
assert first['targetInfo'] == second['targetInfo'] and first['lockInfo'] == second['lockInfo']
assert first['guestConfigSha256'] == second['guestConfigSha256']
assert first['downloads'] == 1 and second['downloads'] == 0
compare = output / 'compare'
compare.mkdir()
program = "import {readFile,writeFile} from 'node:fs/promises';import {compareWitnessResults} from './guest-witness.mjs';const [a,b,c]=process.argv.slice(1);const value=compareWitnessResults(JSON.parse(await readFile(a)),JSON.parse(await readFile(b)));await writeFile(c,JSON.stringify(value,null,2)+'\\n');"
argv = [node, '--input-type=module', '-e', program, output / 'write/WITNESS.json', output / 'read/WITNESS.json', output / 'WITNESS-COMPARISON.json']
# Resolve the comparison helper relative to this fixed output, not the repo.
prior = Path.cwd()
try:
    os.chdir(output)
    run('witness-comparison-no-vm', argv, 30, compare)
finally:
    os.chdir(prior)
comparison = json.loads((output / 'WITNESS-COMPARISON.json').read_text())
summary = {'passed': True, 'lifetimes': [{'phase': value['phase'], 'pid': value['pid'], 'epoch': value['active']['epoch'],
            'checks': len(value['checks']), 'cleanCheckpoint': value['shutdown']['retirement']['cleanCheckpoint']} for value in results],
           'samePersistentInstance': True, 'sameTargetIdentity': True, 'sameFixedLockInode': True,
           'freshEpochAndControlIdentities': True, 'noResumeDownload': True, 'initialPreparedInputsUnmodified': True,
           'witness': comparison, 'sourceUnchanged': True,
           'scope': inputs['scope']}
write_json(output / 'RESULT.json', summary)
print(json.dumps(summary, ensure_ascii=False), flush=True)
