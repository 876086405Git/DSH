#!/usr/bin/env python3
"""Compile unchanged Android catalog sources and compare their exact JSON bytes."""
import argparse
import hashlib
import pathlib
import subprocess
import tempfile
p = argparse.ArgumentParser()
p.add_argument('--repo', type=pathlib.Path, default=pathlib.Path.cwd())
p.add_argument('--kotlinc', default='kotlinc')
p.add_argument('--java', default='java')
a = p.parse_args()
root = a.repo.resolve()
android = root / 'app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/phone'
with tempfile.TemporaryDirectory(prefix='ios-phone-catalog-') as directory:
    jar = str(pathlib.Path(directory) / 'catalog.jar')
    subprocess.run([a.kotlinc, str(android / 'PhoneToolCatalog.kt'), str(android / 'Json.kt'),
                    str(root / 'tooling/ios/phone/export-catalog.kt'), '-include-runtime', '-d', jar], check=True)
    data = subprocess.check_output([a.java, '-jar', jar])
    expected = (root / 'runtime/ios/phone/catalog.json').read_bytes()
    if data != expected:
        raise SystemExit('FAIL: Android JVM catalog differs from iOS exact bytes')
    print('PASS: exact Android JVM JSON bytes', len(data), 'SHA256', hashlib.sha256(data).hexdigest())
