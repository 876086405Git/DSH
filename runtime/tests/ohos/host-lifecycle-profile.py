#!/usr/bin/env python3
"""Exercise the production Host profile and preflight using its C++ driver.

The callback only records arguments; this fixture does not execute an engine.
The full engine check additionally uses host-layout.py and the O8 HTTP observer.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--repo', type=Path, default=ROOT)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    core = args.repo.resolve() / 'app/ohos/entry/src/main/cpp'
    source = args.repo.resolve() / 'runtime/tests/ohos/host-profile.cc'
    driver = out / 'host-profile'
    command = [os.environ.get('CXX', 'clang++'), '-std=c++17', '-Wall', '-Wextra', '-Werror',
               '-I', str(core), str(core / 'host_core.cpp'), str(source), '-pthread', '-o', str(driver)]
    built = subprocess.run(command, capture_output=True, text=True)
    (out / 'build.json').write_text(json.dumps({'command': command, 'exitCode': built.returncode,
        'stdout': built.stdout, 'stderr': built.stderr}, indent=2) + '\n')
    built.check_returncode()
    runtime = out / 'runtime'
    guest = out / '中文 guest/runtime/rootfs'
    dsh = guest / 'root/.dsh'
    workspace = guest / 'root/workspace'
    cache = out / 'cache'
    native = out / 'libs'
    for path in [dsh, workspace, guest / 'root/.agents', cache, native]:
        path.mkdir(parents=True)
    for name in ['runtime/ohos/preload.mjs', 'node_modules/@deepseek-ai/dsh/lib/bin.js',
                 'runtime/ohos/process/index.mjs', 'runtime/ohos/process/sandbox.mjs',
                 'runtime/ohos/lifecycle/index.mjs','runtime/ohos/phone/index.mjs', 'runtime/ohos/capabilities/index.mjs',
                 'runtime/bridge/dsh-go-bridge/lib/index.js', 'runtime/ohos/process/child-process.mjs']:
        path = runtime / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('// Only a filesystem preflight fixture.\n')
    for name in ['libdsh_flock.so', 'libdsh_require_builtin.so']:
        (native / name).write_text('Path fixture, not a native binary.\n')
    environment = {key: os.environ[key] for key in ['PATH', 'LANG', 'LC_ALL'] if key in os.environ}
    rows = []
    services = [('lifecycle', 'ohos-lifecycle', 'runtime/ohos/lifecycle/index.mjs'),
                ('phone', 'ohos-phone', 'runtime/ohos/phone/index.mjs'),
                ('capabilities', 'ohos-capabilities', 'runtime/ohos/capabilities/index.mjs'),
                ('bridge', 'dsh-go-bridge', 'runtime/bridge/dsh-go-bridge/lib/index.js')]
    guard = runtime / 'runtime/ohos/process/child-process.mjs'
    for name in ['default-profile', 'missing-lifecycle', 'missing-phone', 'missing-capabilities', 'missing-bridge', 'missing-child-process']:
        if name == 'missing-child-process':
            guard.unlink()
        else:
            guard.write_text('// Only a filesystem preflight fixture.\n')
        for module, _identifier, relative in services:
            path = runtime / relative
            if name == 'missing-' + module:
                path.unlink()
            else:
                path.write_text('// Only a filesystem preflight fixture.\n')
        argv_path = out / (name + '-argv.json')
        command = [str(p) for p in [driver, runtime, guest, dsh, workspace, cache, native, argv_path]]
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=15)
        row = {'case': name, 'command': command, 'exitCode': result.returncode,
               'stdout': result.stdout, 'stderr': result.stderr}
        if name == 'default-profile':
            config = json.loads((dsh / 'ohos-host.patch.json').read_text())
            entries = [entry for item in config for entry in item.get('insert', [])
                       if entry.get('id') in [identifier for _, identifier, _ in services]]
            row['serviceEntries'] = entries
            expected = [{'id': identifier, 'name': str(runtime / relative)}
                        for _, identifier, relative in services]
            row['passed'] = result.returncode == 0 and entries == expected
            argv = json.loads(argv_path.read_text())
            row['singleImport'] = argv.count('--import') == 1 and len(argv) == 13
            row['passed'] = row['passed'] and row['singleImport']
        else:
            row['runnerEntered'] = argv_path.exists()
            row['passed'] = result.returncode != 0 and not row['runnerEntered'] and 'ERR_OHOS_HOST_RUNTIME_FILE' in result.stderr
        rows.append(row)
        print(name, 'PASS' if row['passed'] else 'FAIL', flush=True)
    files = [core / 'host_core.cpp', core / 'host_core.h', source, Path(__file__)]
    report = {'scope': 'Linux production C++ preflight/profile, recording callback only; no SDK/device claim',
              'inputs': {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}, 'rows': rows}
    (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    raise SystemExit(0 if all(row['passed'] for row in rows) else 1)


if __name__ == '__main__':
    main()
