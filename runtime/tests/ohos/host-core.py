#!/usr/bin/env python3
"""Build/run platform-neutral host with a deliberately fake Node entry."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--ios', action='store_true', help="the iOS app's addon layout (frameworks)")
    args = parser.parse_args()
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    core = ROOT / 'app/ohos/entry/src/main/cpp'
    command = [os.environ.get('CXX', 'clang++'), '-std=c++17', '-Wall', '-Wextra', '-Werror',
               '-I', str(core), str(core / 'host_core.cpp'), str(ROOT / 'runtime/tests/ohos/host-core.cc'),
               '-pthread', '-o', str(args.out / 'host-core')]
    if args.ios:
        command.insert(1, '-DDSH_IOS_HOST')
    build = subprocess.run(command, text=True, capture_output=True)
    (args.out / 'build.json').write_text(json.dumps({'command': command, 'code': build.returncode,
                                                  'stdout': build.stdout, 'stderr': build.stderr}, indent=2))
    build.check_returncode()
    rows = []
    for name in ['normal', 'large', 'multiline-secret', 'stop-running', 'stop-race', 'no-roots', 'filesystem-root',
                 'missing-home', 'protected-env', 'inherited-node-options', 'runtime-symlink',
                 'native-relative', 'native-root', 'native-missing-dir', 'native-nul',
                 'native-missing-file', 'native-not-regular', 'native-file-symlink', 'native-env-override',
                 'layout-no-guest', 'layout-relative-guest', 'layout-root-guest', 'layout-missing-guest',
                 'layout-wrong-home', 'layout-wrong-workspace', 'layout-many-roots', 'layout-missing-agents',
                 'layout-agents-link', 'layout-workspace-link', 'layout-env-agents']:
        case = args.out / name
        env = {k: v for k, v in os.environ.items() if k in ['PATH', 'LANG', 'LC_ALL']}
        result = subprocess.run([str(args.out / 'host-core'), name, str(case)], env=env,
                                capture_output=True, text=True, timeout=15)
        passed = result.returncode == 0 and f'PASS {name}' in result.stdout
        guest = case / '中文 guest"root/runtime/rootfs'
        profile = guest / 'root/.dsh/ohos-host.patch.json'
        if profile.exists():
            config = json.loads(profile.read_text())
            roots = config[-1]['insert'][0]['config']['workspaceRoots']
            assert roots == [str(guest / 'root/workspace')]
            assert config[2]['config']['defaultDirectory'] == roots[0]
            assert config[3]['config'] == {'mode': 'workspace-write', 'workspaceRoot': roots[0]}
            assert config[0] == {'id': 'subprocess', 'disabled': True}
            assert config[1] == {'id': 'sandbox', 'disabled': True}
        rows.append({'case': name, 'passed': passed, 'code': result.returncode,
                     'stdout': result.stdout, 'stderr': result.stderr})
        print(name, 'PASS' if passed else 'FAIL', flush=True)
    inputs = [core / 'host_core.cpp', core / 'host_core.h', ROOT / 'runtime/tests/ohos/host-core.cc']
    (args.out / 'report.json').write_text(json.dumps({'scope': 'desktop fake runner; not real DSH or OHOS',
        'inputs': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}, 'rows': rows}, indent=2))
    assert all(row['passed'] for row in rows)


if __name__ == '__main__':
    main()
