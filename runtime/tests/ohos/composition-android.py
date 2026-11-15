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
    for name in protected:
        before, after = inventory(baseline / name), inventory(ROOT / name)
        assert before == after, 'Protected source changed: ' + name
        sources.append({'path': name, 'entries': len(before),
                        'inventorySha256': sha(json.dumps(before, sort_keys=True).encode())})
    for name in ['app/pubspec.yaml', 'runtime/build-runtime.sh', 'runtime/lib/rtbuild.py', 'runtime/lib/android_recipe.py']:
        assert (baseline / name).read_bytes() == (ROOT / name).read_bytes(), 'Protected source changed: ' + name
        sources.append({'path': name, 'sha256': sha((ROOT / name).read_bytes())})
    save(out / 'protected-source.json', sources)

    selected = {}
    paths = set()
    commands = []
    targets = {}
    for name, tree in [('before', baseline), ('after', ROOT)]:
        runtime = tree / 'runtime'
        module = load('rtbuild_' + name, runtime / 'lib/rtbuild.py')
        pins = json.loads((runtime / 'patches/pins.json').read_text())
        names, _ = module.select_dsh_patches(pins, str(runtime / 'patches'), 'android')
        selected[name], identity = module.dsh_patch_inputs(pins, str(runtime / 'patches'), names, 'android', '0.2.1-rc.4')
        for patch in pins['patches'].values():
            paths.update(patch['0.2.1-rc.4'])
        targets[name] = {'tree': tree, 'identity': identity}
    assert selected['before'] == selected['after'], 'Android target inputs changed'
    assert sha((prefix / 'package-lock.json').read_bytes()) == sha((ROOT / 'runtime/locks/dsh-0.2.1-rc.4/package-lock.json').read_bytes())
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
        argv = ['python3', '-I', '-B', str(target['tree'] / 'runtime/lib/rtbuild.py'), 'patch-dsh',
                '--prefix', str(sparse), '--dsh-version', '0.2.1-rc.4', '--target', 'android',
                '--target-report', str(out / (name + '-target.json'))]
        result = subprocess.run(argv, capture_output=True, text=True)
        (out / (name + '.stdout.log')).write_text(result.stdout)
        (out / (name + '.stderr.log')).write_text(result.stderr)
        commands.append({'argv': argv, 'exitCode': result.returncode})
        save(out / 'commands.json', commands)
        result.check_returncode()
        changed = {path: item for path, item in inventory(sparse).items() if item['kind'] != 'directory'}
        logical_trees[name] = {**original, **changed}
        save(out / (name + '-actual-patched-files.json'), changed)
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
    save(out / 'report.json', {'scope': __doc__, 'passed': True, 'protectedSourceUnchanged': True,
        'androidTargetInputSha256': targets['after']['identity'], 'actualVendorInputFiles': len(paths),
        'logicalTargetTreeEntries': len(logical_trees['after']),
        'logicalTargetTreeSha256': sha((out / 'logical-target-tree.json').read_bytes()),
        'recipeExternalInputs': 'same synthetic archive bytes for both real shell recipe executions; no APK/rootfs build',
        'recipe': cases})
    print(json.dumps({'passed': True, 'vendorInputs': len(paths), 'recipe': cases}))


if __name__ == '__main__':
    main()
