#!/usr/bin/env python3
"""Compile the production N-API adapter with a rejection-only synthetic backend.

Usage: python3 test-crash-addon.py /absolute/path/to/matching/include/node
Requires Linux cc/c++, Node and its matching headers; never downloads tools.
This does not run iSH, NodeMobile, or an Apple SDK.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
if len(sys.argv) != 2 or not (pathlib.Path(sys.argv[1]) / 'node_api.h').is_file():
    raise SystemExit('supply an existing Node include/node directory')
headers = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='guest-crash-addon-') as folder:
    folder = pathlib.Path(folder)
    obj = folder / 'backend.o'
    addon = folder / 'crash.node'
    subprocess.run([shutil.which('cc') or 'cc', '-std=c11', '-Wall', '-Wextra',
                    '-Werror', '-fPIC', '-c', str(HERE / 'crash-addon-backend.c'),
                    '-o', str(obj)], check=True)
    subprocess.run([shutil.which('c++') or 'c++', '-std=c++20', '-O2', '-fPIC',
                    '-fvisibility=hidden', '-DNAPI_VERSION=8',
                    '-DNODE_GYP_MODULE_NAME=dsh_guest_bridge', '-I' + str(headers),
                    '-shared', str(ROOT / 'runtime/ios/guest/native/guest_addon.cc'),
                    str(obj), '-pthread', '-ldl', '-o', str(addon)], check=True)
    subprocess.run([shutil.which('node') or 'node', str(HERE / 'crash-addon.cjs'),
                    str(addon)], check=True, timeout=20)
