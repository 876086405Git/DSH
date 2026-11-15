#!/usr/bin/env python3
"""Replay the actual old/new shell recipe blocks and mutate their real inputs.

External archives are identical small fixtures, not Android image downloads.
The baseline must be the verified origin/main f3875f2 runtime directory.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def sha(data):
    return hashlib.sha256(data).hexdigest()


@contextmanager
def edited(path, data):
    old = path.read_bytes() if path.exists() else None
    path.write_bytes(data)
    try:
        yield
    finally:
        if old is None:
            path.unlink()
        else:
            path.write_bytes(old)


def run_recipe(runtime, fixtures, abi, stream=False, revision='r14'):
    source = (runtime / "build-runtime.sh").read_text()
    start = source.index('  inputs_sha="$( {\n')
    end = source.index('  local runtime_version=', start)
    block = source[start:end]
    if stream:
        opening = '  inputs_sha="$( {\n'
        closing = '    } | sha256sum | cut -c1-12 )"\n'
        assert block.startswith(opening) and block.endswith(closing)
        block = block[len(opening):-len(closing)]
    else:
        block += 'printf "%s\\n" "$inputs_sha"\n'
    shell = '\n'.join([
        'set -euo pipefail', 'function recipe() {',
        'HERE="$1"; work="$2"; abi="$3"',
        'RUNTIME_REVISION="$4"; DSH_VERSION=0.2.1-rc.4; NODE_VERSION=24.22.1; PNPM_VERSION=11.28.5',
        'UBUNTU_VERSION=24.04.5; COMPRESS=xz; XZ_PRESET=6; PRUNE_DEV_METADATA=1; SOURCE_DATE_EPOCH=1767225600',
        'base="$work/base"; node="$work/node"; python="$work/python"',
        'proot_deb="$work/proot"; talloc_deb="$work/talloc"; shmem_deb="$work/shmem"',
        'extra_debs=("$work/extra1" "$work/extra2")',
        'lockfile="$HERE/locks/dsh-$DSH_VERSION/package-lock.json"',
        'pnpm_lockfile="$HERE/locks/pnpm-$PNPM_VERSION/package-lock.json"',
        'sha256() { sha256sum "$1" | cut -d\' \' -f1; }',
        block, '}', 'recipe "$@"',
    ])
    return subprocess.run(['bash', '-c', shell, 'recipe', str(runtime), str(fixtures), abi, revision],
                          capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    baseline = args.baseline.resolve()
    for name, expected in {
        'build-runtime.sh': 'a3a4d9e73ec60b24b502ac094cb44dbb528ec492daea18331291d7bce95ae326',
        'lib/rtbuild.py': '235370e7cfd7173a34cd71a348a909b083cc49d118e5ac8ed27a298d6aa821aa',
        'patches/pins.json': '5a9c275e416a5187f186c4cb9682cd57be2c0215966d80e6c5cbdc5eb2bcfabe',
    }.items():
        assert sha((baseline / name).read_bytes()) == expected, 'not the f3875f2 baseline: ' + name
    cases = []
    with tempfile.TemporaryDirectory(prefix='android-recipe-contract-') as temporary:
        root = Path(temporary)
        runtime = root / 'runtime'
        runtime.mkdir()
        for name in ('build-runtime.sh', 'lib', 'patches', 'bridge', 'boot', 'direct',
                     'locks', 'session-deletion'):
            source = args.runtime / name
            if source.is_dir():
                shutil.copytree(source, runtime / name, symlinks=True,
                                ignore=shutil.ignore_patterns('node_modules', '__pycache__'))
            else:
                shutil.copy2(source, runtime / name)
        fixtures = root / 'fixtures'
        fixtures.mkdir()
        for name in ('base', 'node', 'python', 'proot', 'talloc', 'shmem', 'extra1', 'extra2'):
            (fixtures / name).write_bytes(('identical external fixture ' + name + '\n').encode())
        references = {}
        for abi in ('x86_64', 'arm64-v8a'):
            old = run_recipe(baseline, fixtures, abi, stream=True)
            new = run_recipe(runtime, fixtures, abi, stream=True)
            old_hash = run_recipe(baseline, fixtures, abi)
            new_hash = run_recipe(runtime, fixtures, abi)
            okay = (all(p.returncode == 0 for p in (old, new, old_hash, new_hash))
                    and old.stdout == new.stdout
                    and old_hash.stdout == new_hash.stdout
                    and new_hash.stdout.decode().strip() == sha(new.stdout)[:12])
            cases.append({'name': 'actual-shell-and-full-stream-' + abi, 'pass': okay,
                          'oldSuffix': old_hash.stdout.decode().strip(),
                          'newSuffix': new_hash.stdout.decode().strip(),
                          'inputBytes': len(new.stdout), 'inputSha256': sha(new.stdout),
                          'stderr': new.stderr.decode()})
            references[abi] = old.stdout
        reference = references['x86_64']

        def check(name, same=True, failure=False, revision='r14'):
            result = run_recipe(runtime, fixtures, 'x86_64', stream=True, revision=revision)
            okay = result.returncode != 0 if failure else (
                result.returncode == 0 and (result.stdout == reference) == same)
            cases.append({'name': name, 'pass': okay, 'exit': result.returncode,
                          'inputSha256': sha(result.stdout), 'stderr': result.stderr.decode()})

        for name in ('patches/ohos-network-transport.diff', 'patches/TARGETS.md'):
            path = runtime / name
            with edited(path, path.read_bytes() + b'\n# OHOS-only edit\n'):
                check('excluded-' + name)
        pins_path = runtime / 'patches/pins.json'
        pins = json.loads(pins_path.read_text())

        def changed_pins(value):
            return edited(pins_path, (json.dumps(value, indent=2, sort_keys=True) + '\n').encode())

        with changed_pins(pins):
            check('pins-order-and-format-irrelevant')
        changed = json.loads(pins_path.read_text())
        original = next(iter(changed['patches']['ohos-network-transport.diff']['0.2.1-rc.4'].values()))
        original['after'] = '0' * 64
        with changed_pins(changed):
            check('excluded-ohos-pins')
        changed = json.loads(pins_path.read_text())
        original = next(iter(changed['patches']['fs-create-exclusive.diff']['0.2.1-rc.2'].values()))
        original['after'] = '0' * 64
        with changed_pins(changed):
            check('inactive-dsh-version-pins')
        changed = json.loads(pins_path.read_text())
        name = 'ohos-recipe-fixture.diff'
        changed['targetSets']['ohos'].append(name)
        changed['patches'][name] = {'0.2.1-rc.4': {}}
        with edited(runtime / 'patches' / name, b'# no-op OHOS fixture\n'), changed_pins(changed):
            check('new-registered-ohos-patch')
        changed = json.loads(pins_path.read_text())
        original = next(iter(changed['patches']['fs-create-exclusive.diff']['0.2.1-rc.4'].values()))
        original['after'] = '0' * 64
        with changed_pins(changed):
            check('active-android-pin-changes', same=False)
        changed = json.loads(pins_path.read_text())
        changed['targetSets']['android'].append('ohos-attachment-publication.diff')
        with changed_pins(changed):
            check('android-selected-set-changes', same=False)
        for name in ('patches/fs-create-exclusive.diff', 'build-runtime.sh', 'lib/rtbuild.py',
                     'lib/android_recipe.py', 'session-deletion/core.mjs',
                     'bridge/dsh-go-bridge/package.json', 'boot/boot-cache.mjs', 'direct/paths.mjs',
                     'locks/dsh-0.2.1-rc.4/package-lock.json', 'locks/pnpm-11.28.5/package-lock.json'):
            path = runtime / name
            suffix = b'\n# digest sensitivity fixture\n' if name.endswith(('.py', '.sh')) else b'\n'
            with edited(path, path.read_bytes() + suffix):
                check('changed-' + name, same=False)
        path = fixtures / 'node'
        with edited(path, path.read_bytes() + b'changed archive'):
            check('changed-external-node-archive', same=False)
        check('changed-recipe-revision', same=False, revision='r15')
        compatibility_path = runtime / 'locks/android-recipe-compat.json'
        compatibility = json.loads(compatibility_path.read_text())
        for key in ('sha256', 'legacySha256'):
            changed = json.loads(json.dumps(compatibility))
            changed['sources']['build-runtime.sh'][key] = '0' * 64
            with edited(compatibility_path, json.dumps(changed).encode()):
                check('changed-source-mapping-' + key, same=False)
        for key in ('helperSha256', 'pinsCanonicalSha256', 'pinsLegacySha256', 'companionSha256'):
            changed = dict(compatibility)
            changed[key] = '0' * 64
            with edited(compatibility_path, json.dumps(changed).encode()):
                check('changed-mapping-' + key, same=False)
        with edited(runtime / 'patches/unregistered.diff', b'# unregistered\n'):
            check('unregistered-patch-refused', failure=True)
        changed = json.loads(pins_path.read_text())
        changed['targetSets']['android'].append(changed['targetSets']['android'][0])
        with changed_pins(changed):
            check('duplicate-selected-patch-refused', failure=True)
        check('restored-inputs-still-identical')
    report = {'scope': 'Linux actual shell recipe, actual source/lock files, synthetic external archives; no APK/rootfs build',
              'passed': sum(case['pass'] for case in cases), 'total': len(cases), 'cases': cases}
    args.out.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': report['passed'], 'total': report['total'], 'out': str(args.out)}))
    if report['passed'] != report['total']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
