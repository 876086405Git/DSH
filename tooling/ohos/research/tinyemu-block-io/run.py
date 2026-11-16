#!/usr/bin/env python3
"""Production block/virtio code with real regular-file I/O; no VM or SDK."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
NATIVE = ROOT / 'runtime/ohos/linux/native'
p = argparse.ArgumentParser()
p.add_argument('--source-archive', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--cc', required=True)
a = p.parse_args()
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=False)
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
lock = json.loads((NATIVE / 'source-lock.json').read_text())
assert sha(a.source_archive) == lock['archiveSha256']
for name, digest in lock['files'].items():
    assert sha(NATIVE / name) == digest, name
commands = []


def run(argv, label):
    argv = list(map(str, argv))
    result = subprocess.run(argv, capture_output=True, timeout=60)
    (out / (label + '.stdout')).write_bytes(result.stdout)
    (out / (label + '.stderr')).write_bytes(result.stderr)
    commands.append({'label': label, 'argv': argv, 'exitCode': result.returncode})
    (out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
    return result


with tarfile.open(a.source_archive) as archive:
    archive.extractall(out, filter='data')
source = out / 'tinyemu-2019-12-21'
for patch in sorted((NATIVE / 'patches').glob('*.patch')):
    assert run(['patch', '-d', source, '-p1', '-i', patch], patch.stem).returncode == 0
flags = ['-O2', '-w', '-D_FILE_OFFSET_BITS=64', '-D_LARGEFILE_SOURCE', '-D_GNU_SOURCE',
         '-DCONFIG_VERSION="2019-12-21"', '-DCONFIG_SLIRP', '-DCONFIG_RISCV_MAX_XLEN=64',
         '-DTEMU_EMBED', '-ffunction-sections', '-fdata-sections', '-I', NATIVE, '-I', source]
assert run([a.cc, *flags, HERE / 'block-io.c', source / 'cutils.c', '-Wl,--gc-sections',
            '-lm', '-o', out / 'block-io'], 'compile').returncode == 0
checks = []
for name in ['normal', 'efbig', 'short-write', 'buffered-flush', 'seek-error', 'readonly', 'virtio-ok', 'virtio-efbig']:
    result = run([out / 'block-io', name, out / (name + '.bin')], name)
    checks.append({'case': name, 'exitCode': result.returncode,
                   'observation': json.loads(result.stdout) if result.stdout else None})
passed = all(row['exitCode'] == 0 and row['observation']['passed'] for row in checks)
identity = {str(path.relative_to(ROOT)): sha(path) for path in
            [NATIVE / 'source-lock.json', *sorted((NATIVE / 'patches').glob('*.patch')), HERE / 'run.py', HERE / 'block-io.c']}
(out / 'RESULT.json').write_text(json.dumps({
    'scope': 'Complete production temu.c/virtio.c; actual ordinary-file I/O and RLIMIT_FSIZE errors; bounded RAM/IRQ fixture; no CPU/guest/SDK/device',
    'passed': passed, 'checks': checks, 'sourceArchiveSha256': sha(a.source_archive),
    'sources': identity, 'patchedSources': {name: sha(source / name) for name in ['temu.c', 'virtio.c']},
    'binarySha256': sha(out / 'block-io'), 'commands': commands,
}, indent=2) + '\n')
print(json.dumps({'passed': passed, 'checks': len(checks), 'passCount': sum(row['exitCode'] == 0 for row in checks)}))
sys.exit(0 if passed else 1)
