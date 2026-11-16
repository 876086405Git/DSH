#!/usr/bin/env python3
"""The production fs_export.c against guest escape attempts, on the real host filesystem.

Compiles fs_export.c with the pinned TinyEMU headers and drives its FSDevice
operations as the 9P server would: names with "..", a link to a host path made
by the guest, a stale fid under a directory replaced by such a link, a FIFO.
No VM or guest kernel is involved.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

HERE = Path(__file__).resolve().parent
NATIVE = HERE.parents[2] / 'runtime/ohos/linux/native'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-archive', type=Path, required=True)
parser.add_argument('--cc', required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
lock = json.loads((NATIVE / 'source-lock.json').read_text())
assert sha(args.source_archive) == lock['archiveSha256']
for name, digest in lock['files'].items():
    assert sha(NATIVE / name) == digest, name
with tarfile.open(args.source_archive) as archive:
    archive.extractall(out, filter='data')
source = out / 'tinyemu-2019-12-21'
for patch in sorted((NATIVE / 'patches').glob('*.patch')):
    subprocess.run(['patch', '-s', '-d', source, '-p1', '-i', patch], check=True)
binary = out / 'fs-export'
compile_argv = [args.cc, '-O2', '-std=c11', '-Wall', '-Wextra', '-Wno-unused-parameter', '-Werror', '-D_GNU_SOURCE',
                '-D_FILE_OFFSET_BITS=64', '-DTEMU_EMBED', '-DDSH_FS_EXPORT', '-I', str(NATIVE), '-I', str(source),
                str(HERE / 'linux-fs-export.c'), str(NATIVE / 'fs_export.c'), str(source / 'cutils.c'), '-o', str(binary)]
subprocess.run(compile_argv, check=True)
root, outside = out / 'export', out / 'outside'
root.mkdir()
(outside / 'b').mkdir(parents=True)
(outside / 'secret').write_text('host only\n')
(outside / 'secret').chmod(0o600)
run = subprocess.run([str(binary), str(root), str(outside)], capture_output=True, text=True, timeout=30)
(out / 'driver.stderr').write_text(run.stderr)
checks = [json.loads(line) for line in run.stdout.splitlines()]
escaped = sorted(str(path.relative_to(outside)) for path in outside.rglob('*'))
checks.append({'case': 'outside-tree-unchanged', 'pass': escaped == ['b', 'secret'], 'observed': escaped})
passed = run.returncode == 0 and all(row['pass'] for row in checks) and len(checks) > 20
(out / 'RESULT.json').write_text(json.dumps({'passed': passed, 'exitCode': run.returncode, 'checks': checks,
    'compile': compile_argv, 'fsExportSha256': sha(NATIVE / 'fs_export.c'), 'scope': __doc__}, indent=2) + '\n')
print(json.dumps({'passed': passed, 'checks': len(checks), 'failed': [row['case'] for row in checks if not row['pass']]}))
raise SystemExit(0 if passed else 1)
