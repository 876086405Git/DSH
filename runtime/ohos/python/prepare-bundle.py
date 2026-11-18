#!/usr/bin/env python3
"""Create a hash-manifested stdlib zip and CA/license data for the OH runtime payload."""
import argparse
import hashlib
import json
from pathlib import Path
import py_compile
import shutil
import sys
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--stdlib', type=Path, required=True)
parser.add_argument('--sysconfig', type=Path, required=True)
parser.add_argument('--version', required=True)
parser.add_argument('--ca-bundle', type=Path, required=True)
parser.add_argument('--licenses', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if args.version != '.'.join(map(str, sys.version_info[:3])):
    raise SystemExit('Build Python must exactly match the target Python version')
if args.output.exists():
    raise SystemExit('Output already exists; preserved')
args.output.parent.mkdir(parents=True, exist_ok=True)
staging = Path(tempfile.mkdtemp(prefix='.python-bundle-', dir=args.output.parent))
try:
    with zipfile.ZipFile(staging / 'stdlib.zip', 'w', compression=zipfile.ZIP_DEFLATED) as zipped, tempfile.TemporaryDirectory() as compile_dir:
        sources = [(p, p.relative_to(args.stdlib)) for p in args.stdlib.rglob('*') if p.is_file()]
        sources.append((args.sysconfig, Path(args.sysconfig.name)))
        names = set()
        for source, relative in sorted(sources):
            if source.is_symlink() or any(part in {'__pycache__', 'test', 'tests', 'idlelib', 'tkinter', 'turtledemo', 'site-packages'} for part in relative.parts):
                continue
            if source.suffix == '.py':
                name = relative.with_suffix('.pyc').as_posix()
                target = Path(compile_dir) / 'module.pyc'
                py_compile.compile(str(source), cfile=str(target), dfile=relative.as_posix(), doraise=True,
                                   invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH)
                data = target.read_bytes()
            elif source.suffix in {'.so', '.pyc', '.pyo', '.a', '.dll', '.dylib'}:
                continue
            else:
                name, data = relative.as_posix(), source.read_bytes()
            if name in names:
                raise ValueError('Duplicate stdlib member: ' + name)
            names.add(name)
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0)); info.compress_type = zipfile.ZIP_DEFLATED
            zipped.writestr(info, data)
    shutil.copyfile(args.ca_bundle, staging / 'ca.pem')
    if b'-----BEGIN CERTIFICATE-----' not in (staging / 'ca.pem').read_bytes():
        raise ValueError('CA bundle must contain PEM certificates')
    for label in ('CPython', 'OpenSSL', 'libffi', 'SQLite', 'zlib', 'CA'):
        source = args.licenses / (label + '.txt')
        shutil.copyfile(source, staging / (label + '-LICENSE.txt'))
    rows = [{'path': p.name, 'size': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
            for p in sorted(staging.iterdir())]
    (staging / 'manifest.json').write_text(json.dumps({'schema': 1, 'pythonVersion': args.version, 'files': rows}, indent=2) + '\n')
    staging.rename(args.output)
except BaseException:
    shutil.rmtree(staging)
    raise
