#!/usr/bin/env python3
"""Pin and verify a Linux installer-produced tree for a read-only Host gate.

Hardlinks are a Linux measurement fixture only, never an OH application API or
product install strategy. The output's manifest is the actual installed record.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(256 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tree', type=Path, required=True)
    parser.add_argument('--installed', type=Path, required=True)
    parser.add_argument('--expected', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    raw = args.installed.read_bytes()
    manifest = json.loads(raw)
    if manifest != json.loads(args.expected.read_bytes()):
        raise ValueError('actual installed manifest differs from the expected logical payload')
    spec = importlib.util.spec_from_file_location('runtime_archive_audit',
            Path(__file__).resolve().parents[1] / 'runtime_archive_audit.py')
    audit = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(audit)
    expected = {item['path']: item for item in manifest['files']}
    if len(expected) != len(manifest['files']):
        raise ValueError('duplicate installed path')
    for name in expected:
        audit.safe_path(name)
    observed = set()
    for directory, directories, files in os.walk(args.tree, followlinks=False):
        for name in directories:
            if (Path(directory) / name).is_symlink():
                raise ValueError('source contains a directory symlink')
        for name in files:
            observed.add((Path(directory) / name).relative_to(args.tree).as_posix())
    if observed != set(expected):
        raise ValueError('source tree has missing or unlisted files')
    args.output.mkdir()
    target = args.output / 'files'
    target.mkdir()
    # The measurement's one-file upgrade changes only this path by rename.
    # Pin its old inode first; every copied inode is verified independently.
    ordered = sorted(expected, key=lambda name: (name != 'runtime/ohos/preload.mjs', name))
    for name in ordered:
        source = args.tree / name
        if not stat.S_ISREG(source.lstat().st_mode):
            raise ValueError('source payload member is not a regular file: ' + name)
        destination = target / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        os.link(source, destination, follow_symlinks=False)
    for name, item in expected.items():
        destination = target / name
        metadata = destination.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size != item['size'] or digest(destination) != item['sha256']:
            raise ValueError('pinned installer output differs from its installed SHA256: ' + name)
    (args.output / 'manifest.json').write_bytes(raw)
    report = {'sourceTree': str(args.tree), 'sourceInstalled': str(args.installed),
              'sourceInstalledSHA256': hashlib.sha256(raw).hexdigest(),
              'expectedManifest': str(args.expected), 'expectedManifestSHA256': digest(args.expected),
              'runtimeVersion': manifest['runtimeVersion'], 'files': len(expected),
              'payloadBytes': sum(item['size'] for item in expected.values()),
              'missing': 0, 'extra': 0, 'wrong': 0,
              'scope': 'Linux hardlink snapshot of actual installer output; fully checked against actual installed record; not an OH hardlink implementation'}
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
