#!/usr/bin/env python3
"""Linux actual-addon checks for the HAP filename adapter, not an OHOS ABI test."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('prefix', 'node', 'headers', 'loader-addon', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--compiler', default='clang-18')
    args = parser.parse_args()
    prefix, node, headers, loader, out = (p.resolve() for p in (
        args.prefix, args.node, args.headers, args.loader_addon, args.out))
    assert subprocess.check_output([str(node), '--version'], text=True).strip() == 'v24.22.1'
    source = prefix / 'node_modules/@deepseek-ai/node-addon-system/src/flock.c'
    assert digest(source) == 'c1aa773c7a62b03ce3973156b928f41773fef9407afd79d71b2f625b5616421f'
    out.mkdir(parents=True, exist_ok=False)
    libraries = out / 'libs'
    libraries.mkdir()
    build = [args.compiler, '-std=c11', '-O2', '-fPIC', '-shared', '-DNAPI_VERSION=8',
             '-I', str(headers), str(source), '-o', str(libraries / 'libdsh_flock.so')]
    result = subprocess.run(build, capture_output=True, text=True, timeout=60)
    (out / 'build.stdout').write_text(result.stdout)
    (out / 'build.stderr').write_text(result.stderr)
    assert result.returncode == 0, result.stderr
    shutil.copyfile(loader, libraries / 'libdsh_require_builtin.so')
    identities = {p.name: digest(p) for p in libraries.iterdir()}
    empty = out / 'empty'
    empty.mkdir()
    linked = out / 'linked'
    linked.mkdir()
    (linked / 'libdsh_require_builtin.so').symlink_to(libraries / 'libdsh_require_builtin.so')
    here = Path(__file__).resolve().parent
    sim = here.parents[1] / 'ohos/sim/preload.mjs'
    base_env = {'PATH': os.environ['PATH'], 'LANG': 'C.UTF-8',
                'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony', 'NARB_DISABLE_NATIVE_CACHE': '1',
                'DSH_GO_OHOS_SIM_ADDONS': json.dumps([str(p) for p in libraries.iterdir()])}
    native_key = 'DSH_GO_OHOS_NATIVE_LIBRARY_DIR'
    cases = [
        ('valid', {native_key: str(libraries)}, None),
        ('missing-directory', {}, 'ERR_OHOS_NATIVE_LIBRARY_DIRECTORY'),
        ('relative-directory', {native_key: '../libs'}, 'ERR_OHOS_NATIVE_LIBRARY_DIRECTORY'),
        ('missing-library', {native_key: str(empty)}, 'ERR_OHOS_NATIVE_LIBRARY_PATH'),
        ('linked-library', {native_key: str(linked)}, 'ERR_OHOS_NATIVE_LIBRARY_PATH'),
        ('no-allowlist', {native_key: str(libraries), 'DSH_GO_OHOS_SIM_ADDONS': '[]'}, 'ERR_OHOS_SIM_DLOPEN'),
        ('nodeabi', {native_key: str(libraries), 'NARB_BACKEND': 'nodeabi'}, 'ERR_OHOS_NATIVE_BACKEND'),
    ]
    rows = []
    for name, env, expected in cases:
        command = [str(node), '--jitless', '--import', str(sim), str(here / 'hap-native-paths.cjs'),
                   str(prefix), str(out / name)]
        if expected:
            command.append(expected)
        result = subprocess.run(command, env={**base_env, **env}, capture_output=True, text=True, timeout=30)
        rows.append({'case': name, 'command': command, 'exit': result.returncode,
                     'stdout': result.stdout, 'stderr': result.stderr})
    normal = [str(node), '--jitless', '-e',
              "const a=require(process.argv[1]+'/node_modules/node-addon-require-builtin');"
              "const i=a.getBindingInfo();require('node:assert/strict').notEqual(i.bindingSource,'ohos-hap-libs');"
              "console.log(JSON.stringify(i));", str(prefix)]
    result = subprocess.run(normal, env={'PATH': os.environ['PATH'], 'LANG': 'C.UTF-8'},
                            capture_output=True, text=True, timeout=30)
    rows.append({'case': 'unchanged-linux-route', 'command': normal, 'exit': result.returncode,
                 'stdout': result.stdout, 'stderr': result.stderr})
    report = {'scope': 'Linux original-NAPI actual addons; HAP packaging and renamed OHOS ABI NOT_RUN',
              'node': str(node), 'nodeSha256': digest(node), 'flockSourceSha256': digest(source),
              'buildCommand': build, 'libraries': identities, 'rows': rows,
              'passed': sum(row['exit'] == 0 for row in rows), 'total': len(rows)}
    (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ('scope', 'passed', 'total')}))
    assert report['passed'] == report['total']


if __name__ == '__main__':
    main()
