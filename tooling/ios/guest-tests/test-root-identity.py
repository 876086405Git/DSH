#!/usr/bin/env python3
"""Production N-API Owner FD lifecycle, Linux Node matching headers only.

Kernel functions are a synthetic initialize barrier. No downloads or iSH/Apple
execution. Worker raw-fd tracking is explicitly disabled to match the Host.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

here = pathlib.Path(__file__).resolve().parent
root = here.parents[2]
if len(sys.argv) != 2 or not (pathlib.Path(sys.argv[1]) / 'node_api.h').is_file():
    raise SystemExit('supply an existing matching Node include/node directory')
headers = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='guest-root-identity-') as directory:
    directory = pathlib.Path(directory)
    obj, addon = directory / 'backend.o', directory / 'identity.node'
    subprocess.run([shutil.which('cc') or 'cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-fPIC', '-c', str(here / 'root-identity-backend.c'), '-o', str(obj)], check=True)
    subprocess.run([shutil.which('c++') or 'c++', '-std=c++20', '-O2', '-fPIC',
                    '-fvisibility=hidden', '-DNAPI_VERSION=8', '-DNODE_GYP_MODULE_NAME=dsh_guest_bridge',
                    '-I' + str(headers), '-shared', str(root / 'runtime/ios/guest/native/guest_addon.cc'),
                    str(obj), '-pthread', '-ldl', '-o', str(addon)], check=True)
    subprocess.run([shutil.which('node') or 'node', str(here / 'root-identity.cjs'), str(addon)],
                   check=True, timeout=20)
