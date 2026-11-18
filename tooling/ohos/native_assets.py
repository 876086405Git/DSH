#!/usr/bin/env python3
"""Which of the AOT's native assets go into a HAP, and from where.

Dart build hooks run on the Actions host and fetch or build for the wrong libc: the
sqlite3 package's hook bundles a glibc libsqlite3.so, which HarmonyOS (musl) cannot load.
So every native asset the AOT carries is packaged from an OH build of the same name in the
native input directory, and an asset with no known OH build is refused, never copied.
"""
import argparse
import json
from pathlib import Path
import shutil
import sys

ASSETS = 'native_assets/libs/arm64-v8a'
MANIFEST = 'flutter_assets/NativeAssetsManifest.json'
# AOT asset file -> what builds its OH replacement.
REBUILT = {'libsqlite3.so': 'runtime/ohos/native/build-sqlite.py'}


def plan(aot, native):
    """({asset: its OH build in native}, problems) for the native assets the AOT carries."""
    folder = aot / ASSETS
    entries = sorted(folder.iterdir()) if folder.is_dir() else []
    sources, problems = {}, []
    for path in entries:
        name = path.name
        if not path.is_file() or path.is_symlink():
            problems.append(f'{ASSETS}/{name} is not a regular file')
        elif name not in REBUILT:
            problems.append(f'{ASSETS}/{name} has no known OH build; the hook built it for another libc, '
                            'so it is refused rather than packaged')
        elif not (native / name).is_file():
            problems.append(f'the AOT needs {name}: build it with {REBUILT[name]} into {native}; '
                            "the AOT's own copy is the hook's glibc binary and never goes into a HAP")
        else:
            sources[name] = native / name
    # A bundled ("absolute") asset the Dart side dlopens by name has to be among them.
    manifest = aot / MANIFEST
    if manifest.is_file():
        mapping = json.loads(manifest.read_text()).get('native-assets', {}).get('ohos_arm64', {})
        bundled = {entry.name for entry in entries}
        for asset, (kind, *where) in sorted(mapping.items()):
            if kind == 'absolute' and (len(where) != 1 or where[0] not in bundled):
                problems.append(f'{MANIFEST} maps {asset} to {where}, which {ASSETS} does not hold')
    return sources, problems


def packaged_problems(sources, aot, packaged):
    """Each planned asset, as packaged (name -> bytes), must be its OH build byte for byte."""
    problems = []
    for name, source in sorted(sources.items()):
        data = packaged.get(name)
        if data is None or data == source.read_bytes():
            continue
        hook = aot / ASSETS / name
        if hook.is_file() and data == hook.read_bytes():
            problems.append(f"{name} is the AOT's hook binary, not the OH build {source}")
        else:
            problems.append(f'{name} differs from its OH build {source}')
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--aot', required=True, type=Path, help='The ohos-aot-<sha> Actions artifact')
    parser.add_argument('--native', required=True, type=Path, help='The HAP native input directory')
    parser.add_argument('--copy-to', type=Path, help="Copy the OH builds into this libs/arm64-v8a directory")
    args = parser.parse_args()
    sources, problems = plan(args.aot, args.native)
    for problem in problems:
        print(f'native-assets: {problem}', file=sys.stderr)
    if problems:
        sys.exit(2)
    for name, source in sorted(sources.items()):
        if args.copy_to:
            shutil.copyfile(source, args.copy_to / name)
        print(f'native-assets: {name} from {source}')


if __name__ == '__main__':
    main()
