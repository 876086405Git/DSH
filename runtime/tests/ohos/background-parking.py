#!/usr/bin/env python3
"""Run the OH parking fixtures against real LifecycleState and selected ETS."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys


TESTS = ['background-idle.test.mjs', 'background-foreground.test.mjs',
         'background-parking-boundaries.test.mjs']
FIXTURES = ['background-idle-fixture.mjs', 'background-idle-native.cc']
ETS = ['RuntimeCore', 'RuntimePaths', 'RuntimeRecovery', 'RuntimeLastKnownGood',
       'RuntimeLifecycle', 'ContinuousTaskOwner', 'TransientTaskOwner', 'RuntimeController']


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['source', 'node', 'node-headers', 'cxx', 'esbuild-prefix', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--mode', choices=['plain', 'jitless'], required=True)
    args = parser.parse_args()
    source, out = args.source.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    tests = source / 'runtime/tests/ohos'
    runtime = source / 'app/ohos/entry/src/main/ets/runtime'
    node, cxx = args.node.resolve(), args.cxx.resolve()
    headers, prefix = args.node_headers.resolve(), args.esbuild_prefix.resolve()
    report = {'schema': 1, 'status': 'RUNNING', 'startedUTC': utc(), 'mode': args.mode,
              'source': str(source), 'commands': [],
              'scope': 'Real product LifecycleState and selected ETS method bodies; imports-only platform adapters, deterministic clock/timers and explicit OS/HTTP/ready boundaries. No SDK, device, Host, actual HTTP or CPU/PSS claim.'}

    def save():
        (out / 'RUN.json').write_text(json.dumps(report, indent=2) + '\n')

    environment = {key: value for key, value in os.environ.items()
                   if key not in {'NODE_OPTIONS', 'NODE_PATH', 'LD_PRELOAD', 'ESBUILD_BINARY_PATH'}
                   and not key.startswith(('DSH_', 'OHOS_'))}
    temporary = out / 'tmp'
    temporary.mkdir()
    environment.update(TMPDIR=str(temporary), PYTHONDONTWRITEBYTECODE='1')

    def command(label, argv, extra=None, timeout=60):
        argv = list(map(str, argv))
        row = {'name': label, 'argv': argv, 'cwd': str(out), 'startedUTC': utc(),
               'timeoutSeconds': timeout, 'environmentOverrides': extra or {}}
        report['commands'].append(row)
        save()
        child = subprocess.Popen(argv, cwd=out, env={**environment, **(extra or {})},
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, start_new_session=True)
        try:
            stdout, stderr = child.communicate(timeout=timeout)
            row['timedOut'] = False
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            stdout, stderr = child.communicate()
            row['timedOut'] = True
        (out / (label + '.stdout.log')).write_bytes(stdout)
        (out / (label + '.stderr.log')).write_bytes(stderr)
        row.update(exitCode=child.returncode, endedUTC=utc(),
                   stdoutSHA256=hashlib.sha256(stdout).hexdigest(),
                   stderrSHA256=hashlib.sha256(stderr).hexdigest())
        if label == 'node-tests':
            (out / 'test.log').write_bytes(stdout)
        save()
        if child.returncode != 0 or row['timedOut']:
            raise RuntimeError(label + ' failed; see original command/logs')
        return stdout

    watched = {}
    save()
    try:
        inputs = [Path(__file__).resolve(), node, cxx]
        inputs += [tests / name for name in TESTS + FIXTURES]
        inputs += [runtime / (name + '.ets') for name in ETS]
        inputs += [source / 'app/ohos/entry/src/main/cpp/lifecycle_state.h',
                   source / 'runtime/ohos/host/lifecycle_snapshot.h',
                   source / 'runtime/ohos/node/build-tools/package-lock.json',
                   prefix / 'package.json', prefix / 'package-lock.json']
        inputs += [path for path in headers.rglob('*') if path.is_file()]
        for package in [prefix / 'node_modules/esbuild', prefix / 'node_modules/@esbuild']:
            inputs += [path for path in package.rglob('*') if path.is_file()]
        watched = {str(path): sha(path) for path in sorted(set(inputs))}
        report['inputsBefore'] = watched
        report['nodeHeaders'] = str(headers)
        report['esbuildPrefix'] = str(prefix)
        report['environmentRemoved'] = ['NODE_OPTIONS', 'NODE_PATH', 'LD_PRELOAD',
                                        'ESBUILD_BINARY_PATH', 'DSH_*', 'OHOS_*']
        save()
        command('node-version', [node, '--version'])
        command('cxx-version', [cxx, '--version'])
        addon = out / 'background-idle-native.node'
        command('build-native', [cxx, '-std=c++17', '-shared', '-fPIC', '-pthread',
                '-Wall', '-Wextra', '-Werror', '-isystem', headers,
                '-I', source / 'app/ohos/entry/src/main/cpp',
                tests / 'background-idle-native.cc', '-o', addon])
        addon_before = sha(addon)
        argv = [node, '--unhandled-rejections=strict']
        if args.mode == 'jitless':
            argv.append('--jitless')
        argv += ['--test', '--test-concurrency=1', '--test-reporter=tap']
        argv += [tests / name for name in TESTS]
        stdout = command('node-tests', argv, {
            'DSH_BACKGROUND_SOURCE': str(source), 'DSH_BACKGROUND_NATIVE': str(addon),
            'DSH_BACKGROUND_RECORDS': str(out / 'cases'),
            'DSH_BACKGROUND_BUILD_TOOLS': str(prefix)})
        totals = {}
        for name in ['tests', 'pass', 'fail', 'cancelled', 'skipped', 'todo']:
            values = re.findall(r'^# ' + name + r' (\d+)$', stdout.decode(), re.M)
            if len(values) != 1:
                raise ValueError('Missing/ambiguous original TAP total: ' + name)
            totals[name] = int(values[0])
        report['totals'] = totals
        if totals != {'tests': 19, 'pass': 19, 'fail': 0, 'cancelled': 0, 'skipped': 0, 'todo': 0}:
            raise ValueError('The 19 assertions did not all complete')
        cases = sorted((out / 'cases').glob('*.json'))
        if len(cases) != 19:
            raise ValueError('Expected 19 per-case records')
        for case in cases:
            modules = json.loads(case.read_text())['modules']
            if sorted(row['name'] for row in modules) != sorted(ETS):
                raise ValueError('Case does not bind all eight selected ETS modules')
            for row in modules:
                path = str(runtime / (row['name'] + '.ets'))
                if row['source'] != path or row['sourceSha256'] != watched[path]:
                    raise ValueError('Case ETS source identity mismatch')
        report['cases'] = {path.name: sha(path) for path in cases}
        report['addonSHA256'] = {'beforeTests': addon_before, 'afterTests': sha(addon)}
        if addon_before != sha(addon):
            raise ValueError('Native test addon changed during tests')
        report['status'] = 'PASS_SCOPED_BACKGROUND_PARKING'
    except Exception as error:
        report.update(status='FAIL', error=repr(error))
    finally:
        if watched:
            try:
                report['inputsAfter'] = {path: sha(path) for path in watched}
                report['inputsUnchanged'] = report['inputsAfter'] == watched
                if not report['inputsUnchanged']:
                    report.update(status='FAIL', inputError='Input content changed')
            except Exception as error:
                report.update(status='FAIL', inputError=repr(error))
        report['endedUTC'] = utc()
        save()
    if (out / 'test.log').exists():
        print((out / 'test.log').read_text(), end='')
    print(json.dumps({'status': report['status'], 'mode': args.mode, 'out': str(out)}))
    return 0 if report['status'] == 'PASS_SCOPED_BACKGROUND_PARKING' else 1


if __name__ == '__main__':
    sys.exit(main())
