#!/usr/bin/env python3
"""Build the Node-API CPython host against a previously built static-extension libpython."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser()
for name in ('sdk-native', 'python-source', 'python-build', 'libnode', 'node-headers', 'output'):
    parser.add_argument('--' + name, type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
llvm = args.sdk_native / 'llvm/bin'
readelf = llvm / 'llvm-readelf'
lib = args.python_build / 'libpython3.14.so'
text = subprocess.check_output([str(readelf), '-dWs', str(lib)], text=True)
needed = re.findall(r'\(NEEDED\).*\[(.*?)\]', text)
if any(name != 'libz.so' and re.match(r'lib(?:ssl|crypto|ffi|sqlite3|z)\.', name) for name in needed):
    raise SystemExit('Python extension dependencies must be static in libpython')
if '(RUNPATH)' in text or '(RPATH)' in text or 'Library soname: [libpython3.14.so]' not in text:
    raise SystemExit('Python must have unversioned SONAME and no runtime search path')
for module in ('_ssl', '_hashlib', '_sqlite3', '_ctypes', 'zlib'):
    if not re.search(r'\bPyInit_' + module + r'\b', text):
        raise SystemExit('Missing mandatory builtin extension: ' + module)
if args.output.exists():
    raise SystemExit('Output exists; preserved')
args.output.mkdir(parents=True)
addon = args.output / 'libdsh_python.so'
command = [str(llvm / 'aarch64-unknown-linux-ohos-clang'), '-shared', '-fPIC', '-O2', '-std=c11',
           '-DDSH_PYTHON_SSL_CERT_DIR="/etc/security/certificates"',
           '-D_POSIX_C_SOURCE=200809L', '-include', str(repo / 'runtime/ohos/node/napi-rename.h'),
           '-I' + str(args.node_headers), '-I' + str(args.python_source / 'Include'),
           '-I' + str(args.python_build), str(Path(__file__).with_name('host.c')),
           str(lib), str(args.libnode), '-Wl,-z,defs', '-Wl,-soname,libdsh_python.so', '-o', str(addon)]
subprocess.run(command, check=True)
shutil.copyfile(lib, args.output / lib.name)
subprocess.run([sys.executable, str(repo / 'runtime/ohos/host/napi_isolation.py'),
                '--node-headers', str(args.node_headers), '--rename-header', str(repo / 'runtime/ohos/node/napi-rename.h'),
                '--libnode', str(args.libnode), '--readelf', str(readelf), '--consumer', str(addon),
                '--role', 'addon', '--report', str(args.output / 'napi-isolation.json')], check=True)
(args.output / 'build.json').write_text(json.dumps({'command': command, 'pythonNeeded': needed,
    'files': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (addon, args.output / lib.name)},
    'device': 'NOT_RUN'}, indent=2) + '\n')
