#!/usr/bin/env python3
"""Observe only the attachment module's real fs.readFile allocation boundary.

The image/native/publication components are the already admitted host carriers.
Only one local fs import is instrumented; built-in exports and constructors are
unchanged. The observer retains buffers for identity checks, so this is not a
resident-memory or target-SDK benchmark.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def record(path):
    content = path.read_bytes()
    return {'path': str(path), 'bytes': len(content),
            'sha256': hashlib.sha256(content).hexdigest()}


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser()
    for name in ('source', 'prefix', 'native-library-dir', 'publication-fixture', 'node', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--jitless', action='store_true')
    args = parser.parse_args()
    source, prefix, out = args.source.resolve(), args.prefix.resolve(), args.out.resolve()
    native, publication, node = args.native_library_dir.resolve(), args.publication_fixture.resolve(), args.node.resolve()
    out.mkdir(parents=True, exist_ok=False)
    tests = source / 'runtime/tests/ohos'
    actor = tests / 'image-file-storage-native.mjs'
    observer = tests / 'image-file-storage-observer.mjs'
    oracle = tests / 'image-attachment-oracle.json'
    module = prefix / 'node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js'
    package_json = module.parent.parent / 'package.json'
    pins = source / 'runtime/patches/pins.json'
    expected = json.loads(pins.read_text())['patches']['ohos-image-codec.diff']['0.2.2-rc.1']
    assert record(module)['sha256'] == expected['node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js']['after']
    assert (source / 'runtime/ohos/image/preload.mjs').read_bytes() == (prefix / 'runtime/ohos/image/preload.mjs').read_bytes()
    assert shutil.which('mkfifo'), 'The host filesystem boundary requires the actual mkfifo utility'
    inputs = [Path(__file__).resolve(), actor, observer, oracle, module, package_json, pins, node,
              source / 'runtime/patches/ohos-image-codec.diff', publication,
              native / 'libdsh_image_codec.so', prefix / 'runtime/ohos/image/preload.mjs',
              prefix / 'runtime/ohos/publication/preload.mjs', prefix / 'runtime/ohos/sim/marker.mjs']
    before = [record(path) for path in inputs]
    save(out / 'INPUTS-BEFORE.json', before)
    shutil.copy2(actor, out / 'ACTOR-INPUT.mjs')
    shutil.copy2(observer, out / 'OBSERVER-INPUT.mjs')

    # A private package owns the single changed import. All other dependencies
    # resolve to the existing exact prefix; nothing in that prefix is edited.
    view = out / 'view'
    modules = view / 'node_modules'
    modules.mkdir(parents=True)
    for item in (prefix / 'node_modules').iterdir():
        if item.name != '@deepseek-ai':
            (modules / item.name).symlink_to(item.resolve(), target_is_directory=item.is_dir())
    scope = modules / '@deepseek-ai'
    scope.mkdir()
    for item in (prefix / 'node_modules/@deepseek-ai').iterdir():
        if item.name != 'dsh-attachment-local':
            (scope / item.name).symlink_to(item.resolve(), target_is_directory=item.is_dir())
    package = scope / 'dsh-attachment-local'
    (package / 'lib').mkdir(parents=True)
    shutil.copy2(package_json, package / 'package.json')
    shutil.copy2(observer, package / 'lib/fs-observer.mjs')
    body = module.read_text()
    needle = 'import { chmod, link, mkdir, open, readFile, rename, rm, unlink, writeFile } from "node:fs/promises";'
    assert body.count(needle) == 1
    instrumented = body.replace(needle, needle.replace('"node:fs/promises"', '"./fs-observer.mjs"'))
    (package / 'lib/index.js').write_text(instrumented)
    save(out / 'MODULE-IDENTITY.json', {
        'product': record(module), 'instrumented': record(package / 'lib/index.js'),
        'observer': record(observer),
        'onlyObservationChange': 'One local import forwards actual fs.readFile without changing the returned object; no built-in export or global constructor replacement',
        'residentMemoryMeasurement': False,
    })
    (out / 'home').mkdir()
    save(out / 'CONFIG.json', {'prefix': str(prefix), 'view': str(view), 'out': str(out),
                             'home': str(out / 'home'), 'oracle': str(oracle)})
    environment = {key: value for key, value in os.environ.items()
                   if key not in ('NODE_OPTIONS', 'NODE_PATH', 'LD_PRELOAD')
                   and not key.startswith(('DSH_', 'OHOS_'))}
    delta = {'DSH_IMAGE_FILE_STORAGE_CONFIG': str(out / 'CONFIG.json'), 'DSH_HOME': str(out / 'home'), 'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(native),
             'DSH_IMAGE_TEST_TRACE': str(out / 'SDK-TRACE.jsonl'), 'LD_PRELOAD': str(publication)}
    argv = [str(node), *(['--jitless'] if args.jitless else []), '--test', '--test-reporter=tap', str(actor)]
    save(out / 'COMMAND.json', {'argv': argv, 'environment': delta, 'timeoutSeconds': 30})
    with (out / 'test.log').open('wb') as log:
        code = subprocess.run(argv, cwd=source, env=environment | delta, stdout=log,
                              stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=30).returncode
    counts = {key: int(value) for key, value in re.findall(
        r'^# (tests|pass|fail|cancelled|skipped|todo) (\d+)$', (out / 'test.log').read_text(), re.M)}
    after = [record(path) for path in inputs]
    assert before == after
    save(out / 'INPUTS-AFTER.json', after)
    good = code == 0 and counts == {'tests': 1, 'pass': 1, 'fail': 0, 'cancelled': 0, 'skipped': 0, 'todo': 0}
    save(out / 'RESULT.json', {'status': 'PASS_SCOPED' if good else 'FAIL', 'exitCode': code,
                             'counts': counts, 'inputsStable': True,
                             'scope': 'Explicit fs-to-public-Uint8Array copy identity and real filesystem controls, actual image chain with prior host SDK fixture; no RSS/PSS/CPU/device claim'})
    return 0 if good else 1


if __name__ == '__main__':
    raise SystemExit(main())
