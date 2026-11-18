#!/usr/bin/env python3
"""Compare current Android outputs; each target starts from an independent prefix.

This calls the real patcher and compares every installed path, mode and byte.
The old target-patches-live helpers supply only filesystem comparison, not its
historical afb baseline or Android-to-OH transition assumptions.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()



def android_inputs(root):
    """Read the real baseline's catalog, including legacy schema1 main."""
    runtime = root / 'runtime'
    pins = json.loads((runtime / 'patches/pins.json').read_text())
    present = {path.name for path in (runtime / 'patches').glob('*.diff')}
    series = runtime / 'patches/series'
    # Main applies patches in its series order (filename order before series existed).
    order = ([line.strip() for line in series.read_text().splitlines()
              if line.strip() and not line.lstrip().startswith('#')] if series.exists() else sorted(present))
    assert sorted(order) == sorted(present), 'series must list every diff once'
    legacy = pins.get('schema') == 1
    if legacy:
        assert present == set(pins['patches']), 'Legacy patch catalog mismatch'
        names = order
    else:
        assert pins.get('schema') == 2
        android = pins['targetSets']['android']
        assert len(android) == len(set(android)) and set(android) <= present
        names = [name for name in order if name in set(android)]
    inputs = {'schema': 1, 'target': 'android', 'dshVersion': '0.2.2-rc.1', 'patches': []}
    for name in names:
        inputs['patches'].append({'name': name, 'sha256': sha(runtime / 'patches' / name),
                                 'pins': pins['patches'][name]['0.2.2-rc.1']})
    if 'zzzzzz-session-deletion.diff' in names:
        inputs['companionSha256'] = sha(runtime / 'session-deletion/core.mjs')
    identity = hashlib.sha256(json.dumps(inputs, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return pins, names, inputs, identity, legacy


def patch_argv(root, prefix, target, patches_out, target_out):
    legacy = json.loads((root / 'runtime/patches/pins.json').read_text()).get('schema') == 1
    assert not legacy or target == 'android', 'Legacy baseline is Android only'
    argv = [sys.executable, '-I', '-B', str(root / 'runtime/lib/rtbuild.py'),
            'patch-dsh', '--prefix', str(prefix), '--patches', str(root / 'runtime/patches'),
            '--dsh-version', '0.2.2-rc.1', '--out', str(patches_out)]
    if not legacy:
        argv += ['--target', target, '--target-report', str(target_out)]
    return argv, legacy


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline', type=Path, required=True)
    ap.add_argument('--candidate', type=Path, required=True)
    ap.add_argument('--pristine-prefix', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    base, candidate, pristine, out = [x.resolve() for x in
                                    (a.baseline, a.candidate, a.pristine_prefix, a.out)]
    out.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('target_tree_helpers',
        candidate / 'runtime/tests/ohos/target-patches-live.py')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    report = {'schema': 1, 'startedUTC': utc(), 'status': 'RUNNING', 'commands': [],
              'scope': 'Installed Linux prefix Android bytes/modes/links and target selection; no APK or device.',
              'baseline': str(base), 'candidate': str(candidate), 'pristine': str(pristine)}

    def save(name, value):
        (out / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

    def run(label, root, prefix, target, expected=0):
        argv, legacy = patch_argv(root, prefix, target, out / (label + '-patches.json'),
                                  out / (label + '-target.json'))
        row = {'label': label, 'argv': argv, 'cwd': str(root), 'startedUTC': utc(), 'expected': expected}
        with (out / (label + '.stdout')).open('xb') as stdout, (out / (label + '.stderr')).open('xb') as stderr:
            result = subprocess.run(argv, cwd=root, stdout=stdout, stderr=stderr, timeout=180)
        row.update(exitCode=result.returncode, endedUTC=utc())
        report['commands'].append(row)
        save('report.json', report)
        assert (result.returncode == 0 if expected == 0 else result.returncode != 0), row
        if expected == 0 and target == 'android':
            _, names, _, identity, _ = android_inputs(root)
            assert json.loads((out / (label + '-patches.json')).read_text()) == names
            if not legacy:
                assert json.loads((out / (label + '-target.json')).read_text())['inputSha256'] == identity

    try:
        for name in ('package.json', 'package-lock.json'):
            assert (pristine / name).read_bytes() == (candidate / 'runtime/locks/dsh-0.2.2-rc.1' / name).read_bytes()
            assert (pristine / name).read_bytes() == (base / 'runtime/locks/dsh-0.2.2-rc.1' / name).read_bytes()
        base_catalog, candidate_catalog = android_inputs(base), android_inputs(candidate)
        assert candidate_catalog[4] is False, 'Candidate must retain explicit schema2 target selection'
        assert base_catalog[1] == candidate_catalog[1]
        assert base_catalog[2] == candidate_catalog[2], 'Actual Android diff/pin/companion inputs differ'
        report['selectedAndroid'] = base_catalog[1]
        report['baselineLegacySchema1'] = base_catalog[4]
        spec = importlib.util.spec_from_file_location('actual_recipe_contract',
            candidate / 'runtime/tests/ohos/android-recipe-compat.test.py')
        recipe = importlib.util.module_from_spec(spec); spec.loader.exec_module(recipe)
        fixtures = out / 'recipe-fixtures'; fixtures.mkdir()
        for name in ('base', 'node', 'python', 'proot', 'talloc', 'shmem', 'extra1', 'extra2'):
            (fixtures / name).write_bytes(('identical external fixture ' + name + '\n').encode())
        report['recipes'] = []
        for abi in ('x86_64', 'arm64-v8a'):
            results = {}
            for label, root in [('base', base), ('candidate', candidate)]:
                for stream in (True, False):
                    proc = recipe.run_recipe(root / 'runtime', fixtures, abi, stream=stream)
                    kind = 'stream' if stream else 'suffix'
                    (out / (label + '-' + abi + '-' + kind + '.stdout')).write_bytes(proc.stdout)
                    (out / (label + '-' + abi + '-' + kind + '.stderr')).write_bytes(proc.stderr)
                    report['commands'].append({'label': label + '-recipe-' + abi + '-' + kind,
                                               'runner': 'actual shell recipe block', 'exitCode': proc.returncode})
                    proc.check_returncode(); results[label, stream] = proc.stdout
            assert results['base', True] == results['candidate', True]
            assert results['base', False] == results['candidate', False]
            digest = hashlib.sha256(results['candidate', True]).hexdigest()
            assert results['candidate', False].decode().strip() == digest[:12]
            report['recipes'].append({'abi': abi, 'inputSHA256': digest})
        report['recipeSha256'] = report['recipes'][0]['inputSHA256']
        initial = helper.tree_manifest(pristine)
        save('pristine-before.json', initial)
        trees = {}
        report['temporaryCopies'] = []
        def clone(label, source):
            prefix = out / (label + '-prefix')
            assert not prefix.exists()
            shutil.copytree(source, prefix, symlinks=True, copy_function=shutil.copy2)
            report['temporaryCopies'].append({'action': 'independent-copy', 'path': str(prefix),
                                              'source': str(source), 'timeUTC': utc()})
            save('report.json', report)
            return prefix
        def retire(label):
            prefix = out / (label + '-prefix')
            assert label in ('base', 'upgraded') and prefix.parent == out and not prefix.is_symlink()
            assert (out / (label + '-tree.json')).is_file(), 'Save full manifest before retirement'
            shutil.rmtree(prefix)
            report['temporaryCopies'].append({'action': 'remove-completed-copy', 'path': str(prefix),
                                              'manifestSHA256': sha(out / (label + '-tree.json')), 'timeUTC': utc()})
            save('report.json', report)
        # First keep both independent Android trees for the original byte-by-byte comparison.
        for label, root in [('base', base), ('candidate', candidate)]:
            prefix = clone(label, pristine)
            assert helper.tree_manifest(prefix) == initial
            run(label, root, prefix, 'android')
            trees[label] = helper.tree_manifest(prefix)
            save(label + '-tree.json', trees[label])
            run(label + '-again', root, prefix, 'android')
            assert helper.tree_manifest(prefix) == trees[label], 'idempotence changed bytes'
        changes = helper.compare_trees(out / 'base-prefix', out / 'candidate-prefix', trees['base'], trees['candidate'])
        report['androidDifferences'] = changes
        assert not changes, changes
        retire('base')
        # Upgrade an independent candidate copy, save its whole-tree evidence, then release it.
        upgraded = clone('upgraded', out / 'candidate-prefix')
        assert helper.tree_manifest(upgraded) == trees['candidate']
        run('candidate-upgraded', candidate, upgraded, 'ohos')
        trees['upgraded'] = helper.tree_manifest(upgraded)
        save('upgraded-tree.json', trees['upgraded'])
        retire('upgraded')
        # Fresh OH is separately copied from pristine; keep it and Android for downstream full gates.
        prefix = clone('ohos', pristine)
        assert helper.tree_manifest(prefix) == initial
        run('ohos', candidate, prefix, 'ohos')
        trees['ohos'] = helper.tree_manifest(prefix)
        save('ohos-tree.json', trees['ohos'])
        run('ohos-again', candidate, prefix, 'ohos')
        assert helper.tree_manifest(prefix) == trees['ohos'], 'idempotence changed bytes'
        run('ohos-wrong-target', candidate, prefix, 'android', expected=1)
        assert helper.tree_manifest(prefix) == trees['ohos']
        assert not (out / 'ohos-wrong-target-target.json').exists()
        assert trees['upgraded'] == trees['ohos'], 'upgrade differs from a fresh OHOS tree'
        assert helper.tree_manifest(pristine) == initial
        report.update(status='PASS', endedUTC=utc(), actualAndroidEntries=len(trees['base']),
                      actualOhosEntries=len(trees['ohos']), pristineUnchanged=True,
                      ohosRejectedForAndroidWithoutWrites=True, androidUpgradesToOhos=True, idempotent=True)
        save('report.json', report)
        print(json.dumps({k: report[k] for k in ('status', 'actualAndroidEntries', 'actualOhosEntries', 'recipeSha256')}))
    except BaseException as error:
        report.update(status='FAIL', endedUTC=utc(), error=repr(error))
        save('report.json', report)
        raise


if __name__ == '__main__':
    main()
