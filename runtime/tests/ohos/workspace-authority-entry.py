#!/usr/bin/env python3
"""Actual assembled DSH entry + sole product preload + public shell factory.

The SDK/chooser and native-retirement confirmation fault are explicit fixtures.
No full gate, OH SDK, device, Linux guest, or complete user-session claim.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[2]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def record(path):
    path = Path(path)
    st = path.stat()
    return dict(path=str(path), bytes=st.st_size, sha256=sha(path), mode=oct(st.st_mode & 0o777))


def write_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('node', 'assembled-payload', 'typescript-prefix', 'publication-fixture', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--native-directory', type=Path)
    parser.add_argument('--round-native-directory', type=Path)
    parser.add_argument('--node-headers', type=Path)
    parser.add_argument('--cxx', default='c++')
    args = parser.parse_args()
    output = args.out.absolute()
    output.mkdir(parents=True, exist_ok=False)
    payload = args.assembled_payload.resolve(strict=True)
    manifest = payload.parent / 'manifest.json'
    manifest_rows = {row['path']: row for row in json.loads(manifest.read_text())['files']}
    identities = {}
    for relative in ('runtime/ohos/preload.mjs', 'runtime/ohos/process/runtime.mjs',
                     'runtime/ohos/process/worker.mjs', 'runtime/ohos/process/files/process-authority.mjs'):
        item = payload / relative
        assert sha(item) == manifest_rows[relative]['sha256'] == sha(SOURCE / relative), relative
        assert item.stat().st_size == manifest_rows[relative]['size']
        identities[relative] = record(item)
    native = args.native_directory.resolve(strict=True) if args.native_directory else output / 'native'
    builds = []
    if not args.native_directory:
        if args.node_headers is None or args.round_native_directory is None:
            parser.error('building real fixtures requires --node-headers and --round-native-directory')
        native.mkdir()
        common = [args.cxx, '-std=c++17', '-pthread', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror']
        commands = [
            ('host', common + [SOURCE / 'app/ohos/entry/src/main/cpp/workspace_grants.cpp', '-o', native / 'libdsh_host.so']),
            ('consumer', common + ['-I', args.node_headers, SOURCE / 'runtime/ohos/process/files/addon.cc', '-ldl', '-o', native / 'libdsh_workspace_grants.so']),
            ('publisher', common + ['-I', args.node_headers, HERE / 'workspace-grants-addon.cc', '-L', native,
                                   '-ldsh_host', '-Wl,-rpath,' + str(native), '-o', native / 'workspace-publisher.node']),
        ]
        for name, command in commands:
            argv = list(map(str, command))
            started = time.monotonic()
            result = subprocess.run(argv, capture_output=True, timeout=90,
                                    env={'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'})
            (output / (name + '.stdout')).write_bytes(result.stdout)
            (output / (name + '.stderr')).write_bytes(result.stderr)
            builds.append(dict(name=name, argv=argv, exitCode=result.returncode, seconds=time.monotonic() - started))
            write_json(output / 'BUILD.json', builds)
            result.check_returncode()
        for name in ('libdsh_flock.so', 'libdsh_require_builtin.so'):
            shutil.copy2(args.round_native_directory / name, native / name)
    native_sources = ['app/ohos/entry/src/main/cpp/' + name for name in
                      ('workspace_grants.cpp', 'workspace_grants.h', 'workspace_grants_abi.h', 'workspace_fids.h', 'workspace_fids_abi.h')]
    native_sources += ['runtime/ohos/process/files/addon.cc', 'runtime/tests/ohos/workspace-grants-addon.cc']
    inputs = {'source': str(SOURCE), 'payloadManifest': record(manifest), 'productFiles': identities,
              'nativeSources': [record(SOURCE / name) for name in native_sources],
              'libraries': [record(native / name) for name in ('libdsh_host.so', 'libdsh_workspace_grants.so',
                            'workspace-publisher.node', 'libdsh_flock.so', 'libdsh_require_builtin.so')],
              'publication': record(args.publication_fixture), 'node': record(args.node),
              'fixtures': [record(HERE / name) for name in ('workspace-authority-entry.py', 'workspace-authority-entry.mjs',
                           'workspace-authority-instrumentation.mjs', 'workspace-authority-owner-probe.mjs',
                           'authorized-workspaces-fixture.mjs', 'entry-ability-fixture.mjs', 'workspace-grants-addon.cc')],
              'ets': [record(SOURCE / 'app/ohos/entry/src/main/ets' / name) for name in
                      ('entryability/EntryAbility.ets', 'plugins/AuthorizedWorkspacesPlugin.ets', 'plugins/NativeFilePolicy.ets')]}
    write_json(output / 'INPUTS.json', inputs)
    rounds = []
    for mode in ('jit', 'jitless'):
        for scenario in ('normal', 'retirement-fault', 'late-host'):
            destination = output / (mode + '-' + scenario)
            destination.mkdir()
            for name in ('home', 'tmp', 'physical', 'temporary', 'linux-tools'):
                (destination / name).mkdir(mode=0o700)
            config = {name: str(destination / name) for name in ('physical', 'temporary')}
            config.update(payload=str(payload), nativeDirectory=str(native), scenario=scenario,
                          result=str(destination / 'REPORT.json'))
            write_json(destination / 'CONFIG.json', config)
            env = {'PATH': '/usr/bin:/bin', 'HOME': str(destination / 'home'), 'TMPDIR': str(destination / 'tmp'),
                   'LANG': 'C.UTF-8', 'LD_PRELOAD': str(native / 'libdsh_host.so') + ':' + str(args.publication_fixture.resolve()),
                   'DSH_HOME': str(destination / 'home'), 'NARB_DISABLE_NATIVE_CACHE': '1',
                   'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(native), 'DSH_GO_OHOS_LINUX_DIRECTORY': str(destination / 'linux-tools'),
                   'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony', 'OHOS_932_CONFIG': str(destination / 'CONFIG.json'),
                   'OHOS_TYPESCRIPT_PREFIX': str(args.typescript_prefix.resolve()),
                   'OHOS_WORKSPACE_GRANTS_ADDON': str(native / 'workspace-publisher.node')}
            if scenario == 'late-host':
                # ETS loads the real publisher/host only after the sole preload
                # has attempted initialization. No startup retry may bind it.
                env['LD_PRELOAD'] = str(args.publication_fixture.resolve())
            argv = [str(args.node), *(['--jitless'] if mode == 'jitless' else []), '--max-old-space-size=256',
                    '--import', str(HERE / 'workspace-authority-instrumentation.mjs'),
                    '--import', str(payload / 'runtime/ohos/preload.mjs'),
                    '--import', str(HERE / 'workspace-authority-entry.mjs'),
                    str(payload / 'node_modules/@deepseek-ai/dsh/lib/bin.js'), '--profile', 'web', '--dump-config']
            write_json(destination / 'COMMAND.json', {'argv': argv, 'environment': env, 'cwd': str(destination)})
            started = time.monotonic()
            try:
                result = subprocess.run(argv, env=env, cwd=destination, capture_output=True, timeout=90)
                code, stdout, stderr = result.returncode, result.stdout, result.stderr
            except subprocess.TimeoutExpired as error:
                code, stdout, stderr = 124, error.stdout or b'', error.stderr or b''
            (destination / 'stdout').write_bytes(stdout)
            (destination / 'stderr').write_bytes(stderr)
            report_path = destination / 'REPORT.json'
            report = json.loads(report_path.read_text()) if report_path.exists() else {}
            rows = dict(mode=mode, scenario=scenario, exitCode=code, seconds=time.monotonic() - started,
                        cases=len(report.get('cases', [])), pass_=code == 0 and report.get('pass') is True,
                        report=record(report_path) if report_path.exists() else None,
                        stdout=record(destination / 'stdout'), stderr=record(destination / 'stderr'))
            rounds.append(rows)
            write_json(destination / 'RESULT.json', rows)
    passed = all(row['pass_'] for row in rounds)
    write_json(output / 'RESULT.json', {'pass': passed, 'rounds': rounds,
               'scope': 'Actual public factory and native FD ownership; explicit SDK and confirmation fault fixtures; not OH SDK/device/Linux/full user session'})
    print(json.dumps({'pass': passed, 'rounds': [{key: row[key] for key in ('mode', 'scenario', 'exitCode', 'cases', 'pass_')} for row in rounds]}))
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__':
    main()
