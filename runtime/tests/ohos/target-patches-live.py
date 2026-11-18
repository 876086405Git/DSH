#!/usr/bin/env python3
"""Compare actual DSH trees produced by the pre-OHOS and selected patch chains.

Uses an already installed pristine prefix. No npm installation, network access,
or DSH execution occurs. Full regular-file bytes, modes, symlinks and path sets
are compared; hard-linked copies are safe because rtbuild replaces written files.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys


HERE = Path(__file__).resolve().parent


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def tree_manifest(root):
    manifest = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in sorted(dirs + files):
            path = Path(directory) / name
            rel = path.relative_to(root).as_posix()
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                manifest[rel] = {'type': 'symlink', 'target': os.readlink(path)}
            elif stat.S_ISDIR(info.st_mode):
                manifest[rel] = {'type': 'directory', 'mode': stat.S_IMODE(info.st_mode)}
            elif stat.S_ISREG(info.st_mode):
                manifest[rel] = {'type': 'file', 'mode': stat.S_IMODE(info.st_mode),
                                 'bytes': info.st_size, 'sha256': digest(path)}
            else:
                raise AssertionError(f'Unexpected special prefix entry: {rel}')
    return manifest


def manifest_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def compare_files(left, right):
    with left.open('rb') as a, right.open('rb') as b:
        while True:
            x, y = a.read(1024 * 1024), b.read(1024 * 1024)
            if x != y:
                return False
            if not x:
                return True


def compare_trees(left, right, a, b):
    changed = []
    for rel in sorted(set(a) | set(b)):
        same = a.get(rel) == b.get(rel)
        if same and a[rel]['type'] == 'file':
            same = compare_files(left / rel, right / rel)
        if not same:
            changed.append({'path': rel, 'before': a.get(rel), 'after': b.get(rel)})
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pristine-prefix', required=True, type=Path)
    parser.add_argument('--before-ohos-root', required=True, type=Path,
                        help='Verified afb5cdd source tree, including its original patcher and companion module')
    parser.add_argument('--candidate-root', type=Path, default=HERE.parents[2])
    parser.add_argument('--legacy-ohos-root', type=Path,
                        help='Optional pre-selection catalog: reproduces Android drift and proves OHOS final hashes unchanged')
    parser.add_argument('--work', required=True, type=Path)
    parser.add_argument('--keep-prefixes', action='store_true')
    args = parser.parse_args()
    pristine, baseline, candidate, work = (p.resolve() for p in
        (args.pristine_prefix, args.before_ohos_root, args.candidate_root, args.work))
    legacy = args.legacy_ohos_root.resolve() if args.legacy_ohos_root else None
    if not pristine.is_dir() or work.exists():
        parser.error('--pristine-prefix must exist and --work must be fresh')
    identity = json.loads((HERE / 'android-before-ohos.json').read_text())
    for rel, expected in identity['files'].items():
        actual = digest(baseline / rel)
        if actual != expected:
            parser.error(f'Pre-OHOS baseline source drift: {rel}: {actual} != {expected}')
    work.mkdir(parents=True)
    report = {'scope': 'actual installed DSH tree bytes; no Android APK/HAP/device build',
              'baseline': identity, 'candidateRoot': str(candidate), 'runs': [], 'status': 'RUNNING'}
    owned = []
    initial = tree_manifest(pristine)

    def save_manifest(label, value):
        (work / (label + '.json')).write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')
        return {'path': label + '.json', 'sha256': manifest_hash(value), 'entries': len(value),
                'regularFiles': sum(item['type'] == 'file' for item in value.values())}

    def clone(label):
        path = work / label
        # Do not silently fall back to another full installation/copy when disk
        # layout makes hard-link sharing unavailable.
        shutil.copytree(pristine, path, symlinks=True, copy_function=os.link)
        owned.append(path)
        return path

    def run(label, repo, prefix, target=None, expected=0):
        command = [sys.executable, '-I', '-B', str(repo / 'runtime/lib/rtbuild.py'),
                   'patch-dsh', '--prefix', str(prefix), '--patches', str(repo / 'runtime/patches'),
                   '--dsh-version', identity['dshVersion'], '--out', str(work / (label + '-patches.json'))]
        if target:
            command += ['--target', target, '--target-report', str(work / (label + '-target.json'))]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (work / (label + '.log')).write_text(result.stdout)
        item = {'label': label, 'command': command, 'exitCode': result.returncode, 'expectedExitCode': expected}
        report['runs'].append(item)
        if expected == 'nonzero':
            assert result.returncode != 0, item
        else:
            assert result.returncode == expected, (item, result.stdout)

    try:
        before = clone('baseline-prefix')
        run('baseline-android', baseline, before)
        baseline_tree = tree_manifest(before)
        report['baselineTree'] = save_manifest('baseline-tree', baseline_tree)
        legacy_tree = None
        if legacy:
            old = clone('legacy-prefix')
            run('legacy-all-patches', legacy, old)
            legacy_tree = tree_manifest(old)
            report['legacyTree'] = save_manifest('legacy-tree', legacy_tree)
            changed = compare_trees(before, old, baseline_tree, legacy_tree)
            assert changed, 'The pre-selection Android byte drift was not reproduced'
            report['beforeFixAndroidDifferences'] = changed
            shutil.rmtree(old)
            owned.remove(old)
        after = clone('candidate-prefix')
        run('candidate-android', candidate, after, 'android')
        android_tree = tree_manifest(after)
        differences = compare_trees(before, after, baseline_tree, android_tree)
        report['androidDifferences'] = differences
        assert differences == [], differences
        report['androidTree'] = save_manifest('android-tree', android_tree)
        original_names = json.loads((work / 'baseline-android-patches.json').read_text())
        selected_names = json.loads((work / 'candidate-android-patches.json').read_text())
        assert selected_names == original_names
        run('candidate-android-again', candidate, after, 'android')
        assert tree_manifest(after) == android_tree
        run('candidate-ohos-from-android', candidate, after, 'ohos')
        ohos_tree = tree_manifest(after)
        report['ohosTree'] = save_manifest('ohos-tree', ohos_tree)
        if legacy_tree is not None:
            assert ohos_tree == legacy_tree, 'OHOS target final bytes unexpectedly changed during separation'
            report['ohosFinalMatchesLegacy'] = True
        run('candidate-ohos-again', candidate, after, 'ohos')
        assert tree_manifest(after) == ohos_tree
        run('refuse-ohos-as-android', candidate, after, 'android', expected='nonzero')
        assert tree_manifest(after) == ohos_tree, 'Rejection must not partly rewrite the prefix'
        assert tree_manifest(pristine) == initial, 'Hard-linked pristine input was changed in place'
        report['pristineTree'] = {'unchanged': True, 'sha256': manifest_hash(initial), 'entries': len(initial)}
        report['status'] = 'AUTHOR_TREE_COMPARISON_PASSED'
    finally:
        if not args.keep_prefixes:
            for path in owned:
                shutil.rmtree(path)
        (work / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ['status', 'baselineTree', 'androidTree', 'ohosTree',
                                                 'androidDifferences', 'pristineTree']}, indent=2))


if __name__ == '__main__':
    main()
