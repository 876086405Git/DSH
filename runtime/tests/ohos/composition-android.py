#!/usr/bin/env python3
"""Compare Android source/recipe and execute both real patchers on all vendor inputs.

To avoid duplicating a large npm tree, the real target patchers receive private
copies of every file mentioned by either target's pins. Unaffected files keep
their original complete-prefix inventory. This is an exact logical tree proof,
not a claim that a new Android image or a second full npm tree was built.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[3]

# Exact reviewed main/tip/OH plumbing differences, never a directory exemption.
APPROVED_SOURCE_DIFFERENCES = {'app/pubspec.yaml': {'main': {'mode': 420,
                               'kind': 'file',
                               'bytes': 9357,
                               'sha256': '1a248aa49073f9428bca75681d910f3a5a9affd7efb0fe825620c0b44279a221'},
                      'tipSHA256': '709f42d5afbb7c5f0a5a94086cd13d567d2c02a5f39e6b357326d7f7fdb053b7',
                      'candidate': {'mode': 420,
                                    'kind': 'file',
                                    'bytes': 9357,
                                    'sha256': '709f42d5afbb7c5f0a5a94086cd13d567d2c02a5f39e6b357326d7f7fdb053b7'}},
 'runtime/build-runtime.sh': {'main': {'mode': 493,
                                       'kind': 'file',
                                       'bytes': 30570,
                                       'sha256': '71918e114d6f9a80392cc63410b4b65751c6f815d741d48066b2e401aff83bd4'},
                              'tipSHA256': 'beab81526f3a3a7a3f291b585d4ebd7e8d7ad343f4d456371c6d8b20be82efd0',
                              'candidate': {'mode': 493,
                                            'kind': 'file',
                                            'bytes': 30619,
                                            'sha256': 'beab81526f3a3a7a3f291b585d4ebd7e8d7ad343f4d456371c6d8b20be82efd0'}},
 'runtime/lib/rtbuild.py': {'main': {'mode': 420,
                                     'kind': 'file',
                                     'bytes': 85020,
                                     'sha256': '904e61535a38a9a4464ab56f9ae444af538b91251f06bc73280fa35481bb972e'},
                            'tipSHA256': '3b31f7d71574300ac8984597d264cc98ad65a345621cf6119bb326a536212917',
                            'candidate': {'mode': 420,
                                          'kind': 'file',
                                          'bytes': 91043,
                                          'sha256': '3b31f7d71574300ac8984597d264cc98ad65a345621cf6119bb326a536212917'}},
 'runtime/lib/android_recipe.py': {'main': None,
                                   'tipSHA256': '4246d329dfbafc92906a5aa4dac3efa2d0f2bd4af43b15506d6f81597ada5d46',
                                   'candidate': {'mode': 420,
                                                 'kind': 'file',
                                                 'bytes': 3797,
                                                 'sha256': '4246d329dfbafc92906a5aa4dac3efa2d0f2bd4af43b15506d6f81597ada5d46'}},
 'runtime/locks/android-recipe-compat.json': {'main': None,
                                              'tipSHA256': '6800505351990003a26525c16cbf492ade72d883da89cea48c050691eb8144ae',
                                              'candidate': {'mode': 420,
                                                            'kind': 'file',
                                                            'bytes': 1170,
                                                            'sha256': '6800505351990003a26525c16cbf492ade72d883da89cea48c050691eb8144ae'}},
 'runtime/session-deletion/generate.py': {'main': {'mode': 420,
                                                   'kind': 'file',
                                                   'bytes': 14969,
                                                   'sha256': '44aab75244ef5035d58ba2e03f4976fee514bf531bf7ca5abe5f854f889991a7'},
                                          'tipSHA256': '3464c520c643eba3ae5fb88ceac803b8b5852ee4ba40c5bb1333d35ccd8a62b1',
                                          'candidate': {'mode': 420,
                                                        'kind': 'file',
                                                        'bytes': 15066,
                                                        'sha256': '3464c520c643eba3ae5fb88ceac803b8b5852ee4ba40c5bb1333d35ccd8a62b1'}}}


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n')


def inventory(root):
    result = {}
    for parent, directories, files in os.walk(root, followlinks=False):
        for name in sorted(directories + files):
            path = Path(parent) / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            item = {'mode': stat.S_IMODE(info.st_mode)}
            if path.is_symlink():
                item.update(kind='symlink', target=os.readlink(path))
            elif path.is_dir():
                item['kind'] = 'directory'
            else:
                assert path.is_file()
                data = path.read_bytes()
                item.update(kind='file', bytes=len(data), sha256=sha(data))
            result[relative] = item
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('baseline', 'unpatched-prefix', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    baseline, prefix, out = args.baseline.resolve(), args.unpatched_prefix.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    protected = ['app/android', 'runtime/bridge', 'runtime/boot', 'runtime/direct', 'runtime/session-deletion', 'runtime/locks']
    sources = []
    observed_differences = {}
    def check_sources(scope, before, after):
        for rel in sorted(set(before) | set(after)):
            if before.get(rel) == after.get(rel):
                continue
            full = scope + '/' + rel if scope else rel
            approved = APPROVED_SOURCE_DIFFERENCES.get(full)
            assert approved is not None, 'Unreviewed protected source change: ' + full
            assert before.get(rel) == approved['main'] and after.get(rel) == approved['candidate'], 'Reviewed source identity drift: ' + full
            observed_differences[full] = approved
    for name in protected:
        before, after = inventory(baseline / name), inventory(ROOT / name)
        check_sources(name, before, after)
        sources.append({'path': name, 'baselineEntries': len(before), 'candidateEntries': len(after),
                        'baselineInventorySha256': sha(json.dumps(before, sort_keys=True).encode()),
                        'candidateInventorySha256': sha(json.dumps(after, sort_keys=True).encode())})
    def file_item(path):
        try:
            info = path.lstat()
        except FileNotFoundError:
            return None
        if stat.S_ISLNK(info.st_mode):
            return {'kind': 'symlink', 'mode': stat.S_IMODE(info.st_mode), 'target': os.readlink(path)}
        assert stat.S_ISREG(info.st_mode), 'Protected source must be a regular file: ' + str(path)
        data = path.read_bytes()
        return {'kind': 'file', 'mode': stat.S_IMODE(info.st_mode), 'bytes': len(data), 'sha256': sha(data)}
    for name in ['app/pubspec.yaml', 'runtime/build-runtime.sh', 'runtime/lib/rtbuild.py', 'runtime/lib/android_recipe.py']:
        before, after = file_item(baseline / name), file_item(ROOT / name)
        check_sources('', {name: before}, {name: after})
        sources.append({'path': name, 'baseline': before, 'candidate': after})
    # A later authoritative baseline may already contain all reviewed plumbing.
    assert not observed_differences or set(observed_differences) == set(APPROVED_SOURCE_DIFFERENCES), 'Reviewed difference set changed'
    save(out / 'protected-source.json', sources)
    save(out / 'approved-source-differences.json', observed_differences)

    adapter = load('real_android_target_adapter', ROOT / 'runtime/tests/ohos/current-android-targets.py')
    selected = {}
    paths = set()
    commands = []
    targets = {}
    for name, tree in [('before', baseline), ('after', ROOT)]:
        pins, names, selected[name], identity, legacy = adapter.android_inputs(tree)
        if name == 'after': assert not legacy
        for patch in pins['patches'].values():
            paths.update(patch['0.2.2-rc.1'])
        targets[name] = {'tree': tree, 'identity': identity, 'legacy': legacy, 'names': names}
    assert selected['before'] == selected['after'], 'Android target inputs changed'
    assert sha((prefix / 'package-lock.json').read_bytes()) == sha((ROOT / 'runtime/locks/dsh-0.2.2-rc.1/package-lock.json').read_bytes())
    original = inventory(prefix)
    save(out / 'original-full-tree.json', original)
    logical_trees = {}
    for name, target in targets.items():
        sparse = out / (name + '-vendor-inputs')
        sparse.mkdir()
        for relative in sorted(paths):
            file = sparse / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(prefix / relative, file)
        argv, legacy = adapter.patch_argv(target['tree'], sparse, 'android',
                                          out / (name + '-patches.json'), out / (name + '-target.json'))
        result = subprocess.run(argv, capture_output=True, text=True)
        (out / (name + '.stdout.log')).write_text(result.stdout)
        (out / (name + '.stderr.log')).write_text(result.stderr)
        commands.append({'argv': argv, 'exitCode': result.returncode})
        save(out / 'commands.json', commands)
        result.check_returncode()
        changed = {path: item for path, item in inventory(sparse).items() if item['kind'] != 'directory'}
        logical_trees[name] = {**original, **changed}
        save(out / (name + '-actual-patched-files.json'), changed)
        assert json.loads((out / (name + '-patches.json')).read_text()) == target['names']
        if not legacy:
            assert json.loads((out / (name + '-target.json')).read_text())['inputSha256'] == target['identity']
    assert logical_trees['before'] == logical_trees['after'], 'Android target logical trees differ'
    save(out / 'logical-target-tree.json', logical_trees['after'])

    recipe = load('actual_shell_recipe', ROOT / 'runtime/tests/ohos/android-recipe-compat.test.py')
    fixtures = out / 'identical-external-fixtures'
    fixtures.mkdir()
    for name in ('base', 'node', 'python', 'proot', 'talloc', 'shmem', 'extra1', 'extra2'):
        (fixtures / name).write_text('identical external fixture ' + name + '\n')
    cases = []
    for abi in ('x86_64', 'arm64-v8a'):
        before = recipe.run_recipe(baseline / 'runtime', fixtures, abi, stream=True)
        after = recipe.run_recipe(ROOT / 'runtime', fixtures, abi, stream=True)
        old_suffix = recipe.run_recipe(baseline / 'runtime', fixtures, abi)
        new_suffix = recipe.run_recipe(ROOT / 'runtime', fixtures, abi)
        assert all(value.returncode == 0 for value in [before, after, old_suffix, new_suffix])
        assert before.stdout == after.stdout and old_suffix.stdout == new_suffix.stdout
        assert new_suffix.stdout.decode().strip() == sha(after.stdout)[:12]
        (out / (abi + '-recipe-inputs.txt')).write_bytes(after.stdout)
        cases.append({'abi': abi, 'inputBytes': len(after.stdout), 'inputSha256': sha(after.stdout),
                      'versionSuffix': new_suffix.stdout.decode().strip()})
    assert inventory(prefix) == original, 'Read-only pristine source changed'
    save(out / 'report.json', {'scope': __doc__, 'passed': True, 'protectedSourceUnchangedExceptReviewed': True,
        'approvedSourceDifferences': sorted(observed_differences), 'baselineLegacySchema1': targets['before']['legacy'],
        'androidTargetInputSha256': targets['after']['identity'], 'actualVendorInputFiles': len(paths),
        'logicalTargetTreeEntries': len(logical_trees['after']),
        'logicalTargetTreeSha256': sha((out / 'logical-target-tree.json').read_bytes()),
        'recipeExternalInputs': 'same synthetic archive bytes for both real shell recipe executions; no APK/rootfs build',
        'recipe': cases})
    print(json.dumps({'passed': True, 'vendorInputs': len(paths), 'recipe': cases}))


if __name__ == '__main__':
    main()
