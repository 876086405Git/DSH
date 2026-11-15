#!/usr/bin/env python3
"""Generate a test-only iOS override tree without changing the installed prefix."""
import importlib.util
import json
from pathlib import Path
import shutil
import sys

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[3]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def generate(prefix, out):
    prefix = prefix.resolve(strict=True)
    report = json.loads((prefix / 'target-report.json').read_text())
    if report['target'] != 'ohos' or report['dshVersion'] != '0.2.2-rc.1':
        raise ValueError('Requires an isolated, repository-patched DSH 0.2.2-rc.1 prefix')
    out.mkdir()  # Refuse an existing output, including a symlink.
    guest = module('guest_specialization', REPO / 'tooling/ios/guest-specialization.py')
    ios = module('ios_specialization', REPO / 'tooling/ios/specialize-runtime.py')
    packages = {Path(name).parts[1:3] for name in guest.EDITS if name.startswith('node_modules/@')}
    dependencies = out / 'node_modules'
    dependencies.mkdir()
    for entry in (prefix / 'node_modules').iterdir():
        if entry.name.startswith('@'):
            scope = dependencies / entry.name
            scope.mkdir()
            for package in entry.iterdir():
                destination = scope / package.name
                if (entry.name, package.name) in packages:
                    shutil.copytree(package, destination)
                else:
                    destination.symlink_to(package, target_is_directory=True)
        else:
            (dependencies / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    for name in ('runtime/ohos', 'runtime/ios'):
        shutil.copytree(REPO / name, out / name, ignore=shutil.ignore_patterns('node_modules', 'build', '__pycache__'))
    process = out / 'runtime/ohos/process'
    (process / 'node_modules').symlink_to(REPO / 'runtime/ohos/process/node_modules', target_is_directory=True)
    (process / 'build').symlink_to(REPO / 'runtime/ohos/process/build', target_is_directory=True)
    mapping = {}
    for name in guest.EDITS:
        source = out / name
        data = source.read_bytes()
        if name in ios.DIAGNOSTIC_EDITS:
            data = ios.diagnostics_for_ios(name, data)
        destination = 'runtime/ios/guest/overrides/' + name
        target = out / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(guest.specialize(name, data))
        mapping[name] = destination
    (out / 'runtime/ios/guest/overrides.json').write_text(json.dumps(mapping))
    shutil.copyfile(REPO / 'runtime/tests/fixtures/ios-guest-runtime.mjs', out / 'fixture.test.mjs')
    shutil.copyfile(REPO / 'runtime/tests/fixtures/ios-root-grants-channel.mjs', out / 'root-grants-channel.test.mjs')


if __name__ == '__main__':
    generate(Path(sys.argv[1]), Path(sys.argv[2]))
