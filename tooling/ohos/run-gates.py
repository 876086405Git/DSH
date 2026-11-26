#!/usr/bin/env python3
"""One-command Linux OHOS regression matrix; commands belong to this repository.

Configuration supplies input paths, never commands. Each child keeps its own
scope (Linux/ETS doubles, real Dart, ordinary SDK with UNCOMPILED_HMS). Missing
inputs are BLOCKED_NOT_RUN, not skips. Any blocked/failed group makes exit 1.
"""
import argparse
import datetime
import fnmatch
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import tarfile
import sys
import time
from urllib.parse import unquote, urljoin, urlparse

REPOSITORY = Path(__file__).resolve().parents[2]
IGNORED = {'.git', 'node_modules', '.dart_tool', '__pycache__', '.cache', '.vendor', 'build'}
FLUTTER_ENV = {'PUB_CACHE', 'FLUTTER_ROOT', 'FLUTTER_SUPPRESS_ANALYTICS', 'CI',
               'DSH_LINUX_FLUTTER_TESTS', 'XDG_CONFIG_HOME', 'DSH_TEST_FONT_DIR'}
FLUTTER_L10N_OUTPUTS = {
    'app/lib/l10n/app_en.arb', 'app/lib/l10n/app_zh.arb',
    'app/lib/l10n/gen/app_localizations.dart',
    'app/lib/l10n/gen/app_localizations_en.dart',
    'app/lib/l10n/gen/app_localizations_zh.dart',
}
# These existing controllers hide node:test output in their declared files.
# Inspect only this explicit contract, never unrelated logs under the output.
WRAPPED_TEST_LOGS = {
    'background-parking-*': ['{name}/test.log'],
    'session-resource-cleanup': ['session-resource-cleanup/test.log'],
    'linux-creation-retirement': ['linux-creation-retirement/test.log'],
    'tinyemu-event-wake': ['tinyemu-event-wake/test.log'],
    'linux-startup-close': ['linux-startup-close/test.log'],
    'speech-channel-*': ['{name}/test.log'],
    'picture-shortcut-*': ['{name}/test.log'],
    'media-video-*': ['{name}/test.log'],
    'call-capture-*': ['{name}/test.log'],
    'system-tts-*': ['{name}/test.log'],
    'companion-widget-*': ['{name}/test.log'],
    'git-*': ['{name}/stdout.log'], 'owned-*': ['{name}/stdout.log'],
    'native-files': ['native-files/logic.log'], 'pdf': ['pdf/logic.log'],
    'hms-share': ['hms-share/logic.log'], 'native-media': ['native-media/logic.log'],
    'voice': ['voice/test.log'],
    'system-asr-native': ['system-asr-native/plain.log', 'system-asr-native/jitless.log'],
    'performance-dart': ['performance-dart/logic.log'],
    'diagnostics-dart': ['diagnostics-dart/node-test.log'],
    'keyboard-geometry': ['keyboard-geometry/plain.log', 'keyboard-geometry/jitless.log'],
    'composition-process-matrix': ['composition-process-matrix/jit.log', 'composition-process-matrix/strict.log'],
    'pcm-stream-native': ['pcm-stream-native/plain.log', 'pcm-stream-native/jitless.log'],
    'attachment-cache-proof-native-*': ['{name}/test.log'],
    'image-file-storage-native-*': ['{name}/test.log'],
    'image-cancel-cache-miss-native-*': ['{name}/test.log'],
}


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def source_files(root, ignored=IGNORED):
    result = {}
    for current, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in ignored)
        for name in sorted(files + [d for d in dirs if (Path(current) / d).is_symlink()]):
            # os.walk moves a directory symlink into files when its target disappears.
            if name in ignored:
                continue
            p = Path(current) / name
            rel = p.relative_to(root).as_posix()
            if p.is_symlink():
                result[rel] = {'type': 'symlink', 'target': os.readlink(p)}
            else:
                result[rel] = {'type': 'file', 'bytes': p.stat().st_size,
                               'mode': p.stat().st_mode & 0o777, 'sha256': sha(p)}
    return result


def flutter_inputs(root):
    # app/pubspec.yaml is the one protected input outside the trees below: read
    # that record directly (source_files()'s fields) instead of hashing the whole
    # repository to find it. A symlinked app/ is not descended, as in the walk;
    # a symlinked pubspec is still recorded and refused by `links` below.
    pubspec = root / 'app/pubspec.yaml'
    selected = {}
    if not (root / 'app').is_symlink() and (pubspec.is_symlink() or pubspec.is_file()):
        if pubspec.is_symlink():
            selected['app/pubspec.yaml'] = {'type': 'symlink', 'target': os.readlink(pubspec)}
        else:
            stat = pubspec.stat()
            selected['app/pubspec.yaml'] = {'type': 'file', 'bytes': stat.st_size,
                                            'mode': stat.st_mode & 0o777, 'sha256': sha(pubspec)}
    for directory in ('app/lib', 'app/test', 'packages'):
        path = root / directory
        if path.is_symlink():
            selected[directory] = {'type': 'symlink', 'target': os.readlink(path)}
        else:
            # A source subdirectory named build/node_modules is still source.
            selected.update({directory + '/' + name: value for name, value in source_files(path, ignored=()).items()})
    links = [path for path, value in selected.items() if value['type'] == 'symlink']
    if links:
        raise ValueError('Flutter protected input symlink is not frozen: ' + ', '.join(links))
    return selected


def verify_flutter_inputs(root, expected):
    actual = flutter_inputs(root)
    regenerated = {path: actual[path] for path in FLUTTER_L10N_OUTPUTS
                   if path in actual and actual[path]['type'] == 'file'
                   and actual[path] != expected.get(path)}
    changed = [path for path, value in expected.items()
               if actual.get(path) != value and path not in regenerated]
    added = {path: value for path, value in actual.items() if path not in expected}
    new_code = [path for path in added if path not in regenerated
                and (path.endswith(('.dart', '.arb')) or Path(path).name == 'pubspec.yaml')]
    if changed or new_code:
        raise ValueError('Flutter candidate inputs changed: ' + ', '.join(changed + new_code))
    return {'originalInputFilesUnchanged': len(expected) - len(set(expected) & set(regenerated)),
            'generatedFiles': {**added, **regenerated}}


def verify_flutter_packages(root):
    root = root.resolve()
    config = root / 'app/.dart_tool/package_config.json'
    packages = json.loads(config.read_text())['packages']
    expected = {'dsh_app': root / 'app', 'dsh_client': root / 'packages/dsh_client',
                'dsh_remote': root / 'packages/dsh_remote'}
    selected = {}
    for name, wanted in expected.items():
        matches = [entry for entry in packages if entry['name'] == name]
        if len(matches) != 1:
            raise ValueError('Expected exactly one local package resolver: ' + name)
        uri = urlparse(urljoin(config.as_uri(), matches[0]['rootUri']))
        if uri.scheme != 'file' or uri.netloc not in ('', 'localhost') or uri.query or uri.fragment:
            raise ValueError('Local candidate package has a nonlocal URI: ' + name)
        actual = Path(unquote(uri.path)).resolve()
        if not wanted.is_dir() or wanted.resolve() != wanted or actual != wanted:
            raise ValueError('Candidate package resolver escaped Flutter copy: ' + name + ': ' + str(actual))
        library = wanted / 'lib'
        if not library.is_dir() or library.resolve() != library:
            raise ValueError('Candidate private lib is missing or redirected: ' + name)
        package_uri = urlparse(urljoin(actual.as_uri() + '/', matches[0].get('packageUri', '')))
        if (package_uri.scheme != 'file' or package_uri.netloc not in ('', 'localhost')
                or package_uri.query or package_uri.fragment
                or Path(unquote(package_uri.path)).resolve() != library):
            raise ValueError('Candidate packageUri does not select private lib: ' + name)
        selected[name] = {'root': str(actual), 'lib': str(library)}
    return selected


class Blocked(Exception):
    pass


def verify_proc_mapping():
    try:
        process_pid = os.getpid()
        procfs_pid = int(os.readlink('/proc/self'))
        if procfs_pid <= 0:
            raise ValueError('invalid procfs PID')

        def identity(directory):
            fields = dict(line.split(':', 1) for line in (directory / 'status').read_text().splitlines() if ':' in line)
            nspids = [int(value) for value in fields['NSpid'].split()]
            stat = (directory / 'stat').read_text()
            started = int(stat.rsplit(')', 1)[1].split()[19])
            namespace = os.readlink(directory / 'ns/pid')
            if (int(fields['Pid']) != procfs_pid or int(stat.split(' ', 1)[0]) != procfs_pid
                    or not nspids or any(pid <= 0 for pid in nspids) or nspids[-1] != process_pid
                    or started <= 0 or not re.fullmatch(r'pid:\[\d+\]', namespace)):
                raise ValueError('procfs identity does not match this process')
            return {'namespacePids': nspids, 'pidNamespace': namespace, 'starttime': started}

        observed = identity(Path('/proc/self'))
        if identity(Path('/proc') / str(procfs_pid)) != observed or identity(Path('/proc/self')) != observed:
            raise ValueError('procfs identity changed while verifying')
        return {'processPid': process_pid, 'procSelfPid': procfs_pid, **observed}
    except (OSError, ValueError, KeyError, IndexError) as error:
        raise Blocked('cannot verify parent procfs identity: ' + str(error)) from error


def verify_install_record_wire(path):
    if not path.is_file():
        raise Blocked('missing actual install-record wire; apply 300 and run ets-runtime-tooling')
    records = json.loads(path.read_text())
    if not isinstance(records, list) or len(records) != 2:
        raise ValueError('install-record wire must contain both actual producer cases')
    if {row.get('name') for row in records if isinstance(row, dict)} != {'json', 'schema'}:
        raise ValueError('install-record wire producer cases differ')
    for row in records:
        status, install = row.get('status', {}), row.get('install', {})
        value = status.get('value', {})
        if ('code' in status or value.get('phase') != 'error' or
                'installedVersion' not in value or value['installedVersion'] is not None or
                not isinstance(value.get('error'), str) or
                install.get('code') != 'ohos_install_record_invalid' or
                not isinstance(install.get('message'), str)):
            raise ValueError('install-record wire status/error contract differs')
    return {'sha256': sha(path), 'cases': [row['name'] for row in records],
            'producer': 'ets-runtime-tooling/runtime-channel.test.mjs; actual ETS with explicit OS fixtures'}


def verify_dart_consumers(output):
    diagnostics = output / 'diagnostics-dart'
    commands = json.loads((diagnostics / 'commands.json').read_text())
    driver = str(diagnostics / 'consumer.dart')
    consumers = [row for row in commands if driver in row['argv']]
    if len(consumers) != 1 or consumers[0]['exit'] != 0:
        raise ValueError('diagnostics must execute its actual Dart consumer exactly once')
    performance = json.loads((output / 'performance-dart/report.json').read_text())
    if performance.get('consumerExitCode') != 0:
        raise ValueError('performance Dart consumer did not execute successfully')
    files = [diagnostics / name for name in ('consumer.dart', 'consumer-input.json', 'dart-inputs.json', 'dart-consumer.log')]
    files += [output / 'performance-dart/consumer-probe.dart']
    return {str(path.relative_to(output)): sha(path) for path in files}


class Gates:
    def __init__(self, args):
        self.args = args
        self.out = args.out.resolve()
        self.out.mkdir(parents=True, exist_ok=False)
        self.config = json.loads(args.config.read_text())
        if self.config.get('schema') != 1:
            raise ValueError('configuration schema must be 1')
        self.config_root = args.config.resolve().parent
        self.paths = {}
        for name, value in self.config.get('paths', {}).items():
            if not isinstance(value, str):
                raise ValueError('path value must be a string: ' + name)
            p = Path(value).expanduser()
            self.paths[name] = p.resolve() if p.is_absolute() else (self.config_root / p).resolve()
        supplied_env = self.config.get('flutterEnvironment', {})
        if set(supplied_env) - FLUTTER_ENV:
            raise ValueError('unsupported Flutter environment key')
        self.flutter_env = dict(supplied_env, FLUTTER_SUPPRESS_ANALYTICS='true', CI='true')
        self.source = self.out / 'source'
        self.original = source_files(REPOSITORY)
        save(self.out / 'source-before.json', self.original)
        shutil.copytree(REPOSITORY, self.source, symlinks=True,
                        ignore=shutil.ignore_patterns(*IGNORED))
        if source_files(self.source) != self.original:
            raise ValueError('private source copy differs')
        # Flutter generates Android registrants and local.properties even on
        # Linux. Keep them out of the native/Android identity comparison tree.
        self.flutter_source = self.out / 'flutter-source'
        shutil.copytree(REPOSITORY, self.flutter_source, symlinks=True,
                        ignore=shutil.ignore_patterns(*IGNORED))
        if source_files(self.flutter_source) != self.original:
            raise ValueError('Flutter source copy differs from frozen candidate')
        self.flutter_original_inputs = flutter_inputs(REPOSITORY)
        if flutter_inputs(self.flutter_source) != self.flutter_original_inputs:
            raise ValueError('Flutter protected input copy differs from frozen candidate')
        save(self.out / 'flutter-inputs-before.json', self.flutter_original_inputs)
        self.rows = []
        self.results = {}
        self.covered = set()
        self.coverage = json.loads((REPOSITORY / 'tooling/ohos/gate-coverage.json').read_text())
        self.plan = []
        self.started = utc()
        # Test fixtures may select source files through these variables. Never
        # inherit a path to an older good tree; this invocation supplies inputs.
        self.base_env = {k: v for k, v in os.environ.items()
                         if k not in {'NODE_OPTIONS', 'NODE_PATH', 'LD_PRELOAD', 'PNPM_BIN'}
                         and not k.startswith(('OHOS_', 'DSH_', 'M3_', 'M4_', 'M6_', 'P1_', 'DIAGNOSTICS_'))}
        self.base_env.update(PYTHONDONTWRITEBYTECODE='1', LANG='C.UTF-8', LC_ALL='C.UTF-8', TZ='UTC')

    def path(self, name, suffix=None):
        p = self.paths.get(name)
        if p is None:
            raise Blocked('missing config paths.' + name)
        if suffix:
            p = p / suffix
        if not p.exists():
            raise Blocked('missing input ' + name + ': ' + str(p))
        return p

    def run(self, name, argv, *, needs=(), env=None, cwd=None, timeout=180,
            tests=(), scope='Existing repository test', required=()):
        tests = list(tests)
        for pattern, entries in self.coverage['wrappers'].items():
            if fnmatch.fnmatchcase(name, pattern):
                tests += entries
        tests = sorted(set(tests))
        self.plan.append({'name': name, 'needs': list(needs), 'tests': list(tests), 'scope': scope})
        self.covered.update(tests)
        directory = self.out / 'groups' / name
        directory.mkdir(parents=True)
        row = {'name': name, 'scope': scope, 'status': 'RUNNING', 'startedUTC': utc(),
               'dependencies': list(needs), 'tests': list(tests)}
        try:
            failed = [n for n in needs if self.results.get(n) != 'PASS']
            if failed:
                raise Blocked('prerequisite groups did not pass: ' + ', '.join(failed))
            for key in required:
                self.path(key)
            command = [str(x) for x in (argv() if callable(argv) else argv)]
            overrides = env() if callable(env) else (env or {})
            work = cwd() if callable(cwd) else (cwd or self.source)
            home = directory / 'home'; home.mkdir()
            temporary = directory / 'tmp'; temporary.mkdir()
            if name == 'publication-native-boundaries': temporary.chmod(0o1777)
            environment = dict(self.base_env, HOME=str(home), TMPDIR=str(temporary))
            environment.update({k: str(v) for k, v in overrides.items()})
            if 'DSH_HOME' in overrides: Path(overrides['DSH_HOME']).mkdir(parents=True, exist_ok=True)
            environment['PATH'] = str(self.path('node_root', 'bin')) + os.pathsep + environment.get('PATH', '')
            environment['CXX'] = str(self.path('cxx'))
            row.update(argv=command, cwd=str(work), environmentOverrides={**overrides, 'HOME': str(home),
                       'TMPDIR': str(temporary), 'CXX': environment['CXX']}, timeoutSeconds=timeout)
            save(directory / 'command-start.json', row)
            print('RUN ' + name, flush=True)
            with (directory / 'stdout.log').open('wb') as stdout, (directory / 'stderr.log').open('wb') as stderr:
                child = subprocess.Popen(command, cwd=work, env=environment, stdin=subprocess.DEVNULL,
                                         stdout=stdout, stderr=stderr, start_new_session=True)
                row['pid'] = child.pid
                try:
                    code = child.wait(timeout=timeout)
                    row['timedOut'] = False
                except subprocess.TimeoutExpired:
                    row['timedOut'] = True
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait()
                    code = 124
                row.update(exitCode=code, status='PASS' if code == 0 else 'FAIL')
            for stream in ('stdout', 'stderr'):
                p = directory / (stream + '.log')
                row[stream] = {'bytes': p.stat().st_size, 'sha256': sha(p)}
            text = (directory / 'stdout.log').read_text(errors='replace')
            row['reportedTestTotals'] = re.findall(r'^(?:#|ℹ) (?:tests|pass|fail|cancelled|skipped|todo) \d+$', text, re.M)
            incomplete = re.findall(r'^(?:#|ℹ) (?:skipped|todo) ([1-9]\d*)$|OK \(skipped=([1-9]\d*)\)', text + (directory / 'stderr.log').read_text(errors='replace'), re.M)
            if code == 0 and name == 'dart-bridge-inventory':
                inventory = json.loads((self.out / 'dart-bridge-inventory.json').read_text())
                row['inventoryStatus'] = {key: inventory[key] for key in ('gateStatus', 'fullInventoryStatus')}
                if inventory['gateStatus'] != 'PASS_SCOPED':
                    raise ValueError('Required bridge scope did not pass')
                if inventory['fullInventoryStatus'] != 'LITERAL_DISPATCHES_MATCHED':
                    incomplete.append('Full bridge inventory remains incomplete')
            if code == 0 and name in ('flutter-consumers', 'system-asr-dart'):
                events = [json.loads(line) for line in text.splitlines() if line.startswith('{')]
                done = [event for event in events if event.get('type') == 'done']
                tests_done = [event for event in events if event.get('type') == 'testDone' and not event.get('hidden', False)]
                if len(done) != 1 or done[0].get('success') is not True or not tests_done:
                    raise ValueError('Flutter JSON reporter lacks successful completion and actual tests')
                skipped = sum(event.get('skipped') is True for event in tests_done)
                failed = sum(event.get('result') != 'success' for event in tests_done)
                row['flutterTotals'] = {'tests': len(tests_done), 'skipped': skipped, 'failed': failed}
                if failed: raise ValueError('Flutter exited zero despite failed child tests')
                if skipped: incomplete.append('Flutter JSON testDone.skipped')
            if code == 0 and '--test' in command and not re.search(r'^(?:#|ℹ) tests [1-9]\d*$', text, re.M):
                raise ValueError('Direct node:test invocation did not report executed assertions')
            row['wrappedTestLogs'] = []
            if code == 0:
                for pattern, paths in WRAPPED_TEST_LOGS.items():
                    if not fnmatch.fnmatchcase(name, pattern): continue
                    for relative in paths:
                        path = self.out / relative.format(name=name)
                        content = path.read_text(errors='replace')
                        totals = re.findall(r'^(?:#|ℹ) (tests|pass|fail|cancelled|skipped|todo) (\d+)$', content, re.M)
                        if not any(key == 'tests' and int(value) > 0 for key, value in totals):
                            raise ValueError('Missing actual test totals in wrapper log: ' + str(path))
                        row['wrappedTestLogs'].append({'path': str(path.relative_to(self.out)), 'sha256': sha(path), 'totals': totals})
                        if any(key in ('skipped', 'todo') and int(value) for key, value in totals):
                            incomplete.append(str(path))
                        if any(key in ('fail', 'cancelled') and int(value) for key, value in totals):
                            raise ValueError('Wrapper exited zero despite failed/cancelled child tests: ' + str(path))
            if code == 0 and incomplete:
                row.update(status='INCOMPLETE', reason='Child reported skipped/todo assertions or incomplete inventory; see raw output')
        except Blocked as error:
            row.update(status='BLOCKED_NOT_RUN', reason=str(error), exitCode=None)
        except Exception as error:
            row.update(status='FAIL', error=repr(error), exitCode=None)
        row['endedUTC'] = utc()
        save(directory / 'result.json', row)
        self.rows.append(row); self.results[name] = row['status']
        save(self.out / 'progress.json', self.rows)
        print(row['status'] + ' ' + name, flush=True)
        return row['status'] == 'PASS'

    def internal(self, name, action, *, needs=(), scope='Input preparation'):
        self.plan.append({'name': name, 'needs': list(needs), 'tests': [], 'scope': scope})
        directory = self.out / 'groups' / name; directory.mkdir(parents=True)
        row = {'name': name, 'scope': scope, 'startedUTC': utc(), 'dependencies': list(needs)}
        try:
            failed = [n for n in needs if self.results.get(n) != 'PASS']
            if failed:
                raise Blocked('prerequisite groups did not pass: ' + ', '.join(failed))
            row['details'] = action(directory)
            row['status'] = 'PASS'
        except Blocked as error:
            row.update(status='BLOCKED_NOT_RUN', reason=str(error))
        except Exception as error:
            row.update(status='FAIL', error=repr(error))
        row['endedUTC'] = utc(); save(directory / 'result.json', row)
        self.rows.append(row); self.results[name] = row['status']; save(self.out / 'progress.json', self.rows)
        print(row['status'] + ' ' + name, flush=True)

    def py(self, script, *args):
        return [sys.executable, '-I', '-B', self.source / script, *args]

    def node(self, *args):
        return [self.path('node_root', 'bin/node'), *args]

    def flutter(self, *args):
        return [self.path('flutter'), '--suppress-analytics', '--no-version-check', *args]

    def common(self):
        prepared = self.path('prepared')
        return {'OHOS_TYPESCRIPT_PREFIX': str(self.path('typescript_prefix')),
                'OHOS_TEST_PROCESS_PREFIX': str(self.out / 'targets/ohos-prefix'),
                'OHOS_TEST_DSH_PREFIX': str(self.out / 'targets/ohos-prefix'),
                'OHOS_TEST_BASE_PREFIX': str(self.path('android_pristine')),
                'DSH_TEST_PREFIX': str(self.out / 'targets/ohos-prefix'),
                'DSH_LIFECYCLE_TEST_PREFIX': str(self.out / 'targets/ohos-prefix'),
                'OHOS_SIM_PRELOAD': str(self.source / 'runtime/ohos/sim/preload.mjs'),
                'OHOS_ESBUILD_PREFIX': str(self.path('esbuild_prefix')),
                'NODE': str(self.path('node_root', 'bin/node'))}

    def node_tests(self, label, tests, *, mode='plain', extra=None, imports=(), needs=(), timeout=180, host_links=False):
        def argv():
            flags = []
            if mode == 'strict':
                flags = ['--jitless', '--import', self.source / 'runtime/ohos/sim/preload.mjs']
            elif mode == 'sim':
                flags = ['--import', self.source / 'runtime/ohos/sim/preload.mjs']
            elif mode == 'marker':
                flags = ['--import', self.source / 'runtime/ohos/sim/marker.mjs']
            elif mode == 'jitless':
                flags = ['--jitless']
            for entry in imports: flags += ['--import', self.source / entry]
            command = self.node(*flags, '--experimental-import-meta-resolve', '--test', '--test-isolation=none', '--test-reporter=tap',
                                *[self.source / p for p in tests])
            if host_links and mode in ('strict', 'sim'):
                return self.py('runtime/tests/ohos/process-link-fixture.py', '--evidence', self.out / (label + '-host-links.json'), '--', *command)
            return command
        def env():
            value = self.common()
            if mode in ('strict', 'sim'):
                value.update(DSH_GO_OHOS_SIM_PLATFORM='openharmony', DSH_GO_OHOS_SIM_ADDONS='[]')
            value.update(extra() if callable(extra) else (extra or {}))
            if host_links and mode in ('strict', 'sim') and 'LD_PRELOAD' in value:
                value['OHOS_TEST_LINK_LD_PRELOAD'] = value.pop('LD_PRELOAD')
            return value
        self.run(label, argv, env=env, needs=needs, timeout=timeout, tests=tests)

    def finish(self):
        current = source_files(REPOSITORY)
        private = source_files(self.source)
        unchanged = current == self.original
        # Tests may prepare documented generated inputs but must not edit source.
        changed = [p for p in self.original if private.get(p) != self.original[p]]
        failures = [r['name'] for r in self.rows if r['status'] != 'PASS']
        inventory = {p.relative_to(REPOSITORY).as_posix()
                     for folder in ('runtime/tests/ohos', 'tooling/ohos/tests')
                     for p in (REPOSITORY / folder).rglob('*')
                     if p.is_file() and re.search(r'\.test\.(mjs|py)$', p.name)}
        excluded = self.coverage['historicalOrResearchOnly']
        unmapped = sorted(inventory - self.covered - set(excluded))
        coverage = {'inventory': sorted(inventory), 'invokedTests': sorted(self.covered),
                    'historicalOrResearchOnly': excluded, 'unmapped': unmapped}
        save(self.out / 'coverage.json', coverage)
        report = {'schema': 1, 'startedUTC': self.started, 'endedUTC': utc(),
                  'status': 'PASS_SCOPED_LINUX_MATRIX' if not failures and unchanged and not changed and not unmapped else 'FAIL',
                  'scope': 'Linux OHOS regression matrix, real Dart consumers, ordinary ArkTS with nonofficial HMS stubs; no device, official HMS or Android APK claim.',
                  'hms': 'UNCOMPILED_HMS', 'device': 'NOT_RUN', 'rows': self.rows,
                  'counts': {v: sum(r['status'] == v for r in self.rows) for v in ('PASS', 'FAIL', 'INCOMPLETE', 'BLOCKED_NOT_RUN')},
                  'sourceUnchanged': unchanged, 'privateTrackedSourceChanges': changed,
                  'sourceIndexSha256': sha(self.out / 'source-before.json'),
                  'failedOrBlockedGroups': failures, 'unmappedTests': unmapped}
        save(self.out / 'plan.json', self.plan)
        save(self.out / 'source-after.json', current)
        save(self.out / 'summary.json', report)
        lines = ['# OHOS gate results', '', '| Group | Status | Exit |', '|---|---|---|']
        lines += ['| ' + r['name'] + ' | ' + r['status'] + ' | ' + str(r.get('exitCode', '—')) + ' |' for r in self.rows]
        lines += ['', report['scope'], '', 'HMS: UNCOMPILED_HMS; device: NOT_RUN.', '',
                  'Original repository unchanged: ' + str(unchanged), '']
        (self.out / 'SUMMARY.md').write_text('\n'.join(lines))
        print(json.dumps({'status': report['status'], 'counts': report['counts'], 'summary': str(self.out / 'summary.json')}))
        return 0 if report['status'] == 'PASS_SCOPED_LINUX_MATRIX' else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--config', type=Path, required=True, help='schema1 tool/input paths, relative to this JSON')
    ap.add_argument('--out', type=Path, required=True, help='new output directory outside the repository')
    a = ap.parse_args()
    if a.out.resolve().is_relative_to(REPOSITORY):
        ap.error('--out must be outside the source tree')
    g = Gates(a); s = g.source; o = g.out
    rt = 'runtime/tests/ohos/'; tools = 'tooling/ohos/tests/'
    def p(name): return g.path(name)
    def node(): return p('node_root') / 'bin/node'
    def headers(): return p('node_root') / 'include/node'
    def prefix(): return o / 'targets/ohos-prefix'
    def native(): return o / 'native'
    def payload(): return o / 'composed/expanded/dsh-runtime/files'
    def free_port():
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); return str(sock.getsockname()[1])
    def owned_http_host(value):
        if not value or value in ('0.0.0.0', '::'):
            raise Blocked('ownedHttpHost must identify an explicitly owned non-loopback interface')
        return value
    def linked_env(): return {'LD_PRELOAD': str(native() / 'libpublication-test-linked.so')}
    def toolchain(_):
        result = {}
        expected = json.loads((s / 'runtime/ohos/node-version.json').read_text())
        version = subprocess.check_output([str(node()), '--version'], text=True).strip()
        wanted = expected['version'] if isinstance(expected, dict) else expected
        if not wanted.startswith('v'): wanted = 'v' + wanted
        if version != wanted: raise ValueError('Node version mismatch: ' + version)
        for name, command in [('node', [node(), '--version']), ('cxx', [p('cxx'), '--version'])]:
            env = dict(g.base_env, **g.flutter_env)
            proc = subprocess.run([str(x) for x in command], capture_output=True, text=True, env=env, timeout=60)
            result[name] = {'argv': list(map(str, command)), 'exitCode': proc.returncode,
                            'stdout': proc.stdout, 'stderr': proc.stderr, 'sha256': sha(command[0])}
            proc.check_returncode()
        for name in ('git', 'openssl', 'pdfinfo', 'pdftoppm'):
            if not shutil.which(name): raise Blocked('missing executable ' + name)
        return result
    g.internal('tools', toolchain)
    def pnpm_inputs(_):
        installed = p('pnpm_prefix')
        build = (s / 'runtime/build-runtime.sh').read_text()
        version_match = re.search(r'^PNPM_VERSION="\$\{PNPM_VERSION:-([^}]+)\}"$', build, re.M)
        integrity_match = re.search(r'^PNPM_INTEGRITY="\$\{PNPM_INTEGRITY:-([^}]+)\}"$', build, re.M)
        if not version_match or not integrity_match:
            raise ValueError('Cannot identify the original pnpm version/integrity pins')
        version, integrity = version_match[1], integrity_match[1]
        lockdir = s / ('runtime/locks/pnpm-' + version)
        for name in ('package.json', 'package-lock.json'):
            if (installed / name).read_bytes() != (lockdir / name).read_bytes():
                raise ValueError('pnpm installed prefix differs from original lock: ' + name)
        package = json.loads((installed / 'package.json').read_text())
        lock = json.loads((installed / 'package-lock.json').read_text())
        pinned = lock['packages']['node_modules/pnpm']
        if package['dependencies']['pnpm'] != version or pinned['version'] != version or pinned['integrity'] != integrity:
            raise ValueError('pnpm original lock and build pins disagree')
        hidden = json.loads((installed / 'node_modules/.package-lock.json').read_text())['packages']['node_modules/pnpm']
        if any(hidden.get(key) != pinned[key] for key in ('version', 'resolved', 'integrity')):
            raise ValueError('pnpm npm-ci installed lock does not match the original lock')
        actual = json.loads((installed / 'node_modules/pnpm/package.json').read_text())
        binary = installed / 'node_modules/pnpm/bin/pnpm.mjs'
        if actual.get('name') != 'pnpm' or actual.get('version') != version:
            raise ValueError('pnpm installed package version mismatch')
        if binary.is_symlink() or not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError('pnpm executable must be an executable regular installed file')
        # Include node_modules: the default source exclusions would omit the tool.
        identity = source_files(installed, ignored=set())
        save(o / 'pnpm-inputs.json', {'prefix': str(installed), 'version': version,
            'integrity': integrity, 'files': identity})
        return {'prefix': str(installed), 'version': version, 'integrity': integrity,
                'bin': str(binary), 'binSha256': sha(binary),
                'identitySha256': sha(o / 'pnpm-inputs.json'), 'fileCount': len(identity),
                'packageSha256': sha(lockdir / 'package.json'),
                'lockSha256': sha(lockdir / 'package-lock.json')}
    g.internal('pnpm-inputs', pnpm_inputs, needs=('tools',),
               scope='Original locked pnpm input for both complete shared suites; no install')
    def native_tools(_):
        header = g.path('node_root', 'include/node/node_api.h')
        return {'nodeApiHeaderSha256': sha(header)}
    g.internal('native-tools', native_tools, needs=('tools',))
    # Finite image host components. Real attachment integration is a separate gate.
    g.run('image-container-facts', lambda: g.py(rt + 'image-host-components.py', '--source', s, '--out', o / 'image-container-facts', '--suite', 'container', '--cc', p('cc')), needs=('tools',), timeout=120, tests=[rt + 'image-host-components.py', rt + 'image-container-facts.c'], scope='Original 28 bounded container assertions; no pixel decode or device')
    g.run('image-encoding-ladder', lambda: g.py(rt + 'image-host-components.py', '--source', s, '--out', o / 'image-encoding-ladder', '--suite', 'ladder', '--cc', p('cc')), needs=('tools',), timeout=120, tests=[rt + 'image-host-components.py', rt + 'image-encoding-ladder.c'], scope='Original 13 finite encoding-ladder cases with fake packer; no real codec')
    g.run('image-ndk-fake-sdk', lambda: g.py(rt + 'image-host-components.py', '--source', s, '--out', o / 'image-ndk-fake-sdk', '--suite', 'ndk', '--cc', p('cc')), needs=('tools',), timeout=300, tests=[rt + 'image-host-components.py', rt + 'image-ndk-contract.c', rt + 'image-ndk-sdk-fake.c', rt + 'image-ndk-inputs.c'], scope='Real codec_ndk source with original SDK headers and explicit fake SDK; two compile policies, 32 case executions, no real SDK ownership claim')
    for image_mode in ('plain', 'jitless'):
        g.run('image-codec-bridge-' + image_mode, lambda m=image_mode: g.py(rt + 'image-host-components.py', '--source', s, '--out', o / ('image-codec-bridge-' + m), '--suite', 'bridge', '--cc', p('cc'), '--cxx', p('cxx'), '--node', node(), '--node-headers', headers(), *(['--jitless'] if m == 'jitless' else [])), needs=('native-tools',), timeout=210, tests=[rt + 'image-host-components.py', rt + 'image-codec-bridge.test.mjs', rt + 'image-codec-fake.c'], scope='Original four Node lifecycle cases, current bridge plus fixture-only backend; ordinary host API, no OH SDK or attachment chain')
    g.run('tinyemu-poweroff', lambda: g.py('tooling/ohos/research/tinyemu-poweroff/run.py', '--source-archive', p('tinyemu_source_archive'), '--output', o / 'tinyemu-poweroff', '--cc', p('cc')), needs=('tools',), timeout=600, tests=['tooling/ohos/research/tinyemu-poweroff/run.py', 'tooling/ohos/research/tinyemu-poweroff/semantic-core.c', 'tooling/ohos/research/tinyemu-poweroff/clock-cpu.c'], scope='Real TinyEMU BIOS poweroff return; no device release, Linux guest, HAP or device')
    g.internal('proc-mapping-tools', lambda _: verify_proc_mapping(), needs=('tools',))
    def permission_tools(_):
        code = 'import os; os.setgroups([]); os.setgid(65534); os.setuid(65534); print(os.getuid())'
        if os.geteuid() != 0: return {'uid': os.geteuid(), 'dropRequired': False}
        probe = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True)
        if probe.returncode:
            raise Blocked('permission negative controls require uid drop: ' + probe.stderr.strip())
        return {'uid': int(probe.stdout), 'dropRequired': True}
    g.internal('permission-tools', permission_tools, needs=('tools',))
    def network_interface_tools(_):
        probe = subprocess.run([str(node()), '-e',
            "const a=Object.values(require('node:os').networkInterfaces()).flat().filter(v=>v.family==='IPv4'&&!v.internal); if(!a.length) process.exit(2); console.log(a.length)"],
            capture_output=True, text=True)
        if probe.returncode:
            raise Blocked('real non-loopback interface enumeration unavailable: ' + probe.stderr.strip())
        return {'nonLoopbackIpv4Count': int(probe.stdout)}
    g.internal('network-interface-tools', network_interface_tools, needs=('tools',))
    def language_tool(name):
        tool = p(name)
        command = g.flutter('--version') if name == 'flutter' else [tool, '--version']
        result = subprocess.run(list(map(str, command)), capture_output=True, text=True,
                                env={**g.base_env, **g.flutter_env}, timeout=60)
        result.check_returncode()
        return {'argv': list(map(str, command)), 'sha256': sha(tool), 'exitCode': result.returncode,
                'stdout': result.stdout, 'stderr': result.stderr}
    g.internal('dart-tools', lambda _: language_tool('dart'))
    g.internal('flutter-tools', lambda _: language_tool('flutter'))
    def inputs(_):
        prepared = p('prepared')
        spec = importlib.util.spec_from_file_location('gate_prepared_inputs', s / 'runtime/ohos/package/prepare-inputs.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        config = json.loads((s / 'runtime/ohos/package/composition.json').read_text())
        receipt = module.verify_inputs(prepared / 'prepared-inputs.json', config, prepared / 'dsh', prepared / 'process')
        original = prepared
        prepared = o / 'installed-inputs'
        prepared.mkdir()
        for part in ('dsh', 'process'):
            shutil.copytree(original / part, prepared / part, symlinks=True, copy_function=shutil.copy2)
        for name in ('prepared-inputs.json', 'target-report.json', 'patch-results.json'):
            shutil.copy2(original / name, prepared / name)
        assert module.verify_inputs(prepared / 'prepared-inputs.json', config, prepared / 'dsh', prepared / 'process') == receipt
        g.paths['prepared'] = prepared
        for dest, target in [(s / 'node_modules', prepared / 'dsh/node_modules'),
                             (s / 'runtime/ohos/process/node_modules', prepared / 'process/node_modules')]:
            if dest.exists() or dest.is_symlink(): raise ValueError('unexpected input link ' + str(dest))
            dest.symlink_to(target, target_is_directory=True)
        return {'receiptSha256': receipt, 'targetReportSha256': sha(prepared / 'target-report.json'),
                'dshLockSha256': sha(prepared / 'dsh/package-lock.json'),
                'processLockSha256': sha(prepared / 'process/package-lock.json')}
    g.internal('prepared-inputs', inputs, needs=('tools',))
    g.run('android-targets', lambda: g.py(rt + 'current-android-targets.py', '--baseline', p('android_baseline'), '--candidate', s, '--pristine-prefix', p('android_pristine'), '--out', o / 'targets'), needs=('tools',), timeout=600)
    def native_helpers(_):
        helper = prefix() / 'node_modules/@dsh-go/ohos-native'
        helper.mkdir(parents=True, exist_ok=True)
        (s / 'node_modules').unlink()
        (s / 'node_modules').symlink_to(prefix() / 'node_modules', target_is_directory=True)
        for filename in ('index.cjs', 'package.json'):
            shutil.copy2(s / 'runtime/ohos/native/hap-loader' / filename, helper / filename)
        shutil.copy2(s / 'LICENSE', helper / 'LICENSE')
        return {'scope': 'Derived full-optional Linux test prefix after Android identity comparison',
                'files': {name: sha(helper / name) for name in ('index.cjs', 'package.json', 'LICENSE')}}
    g.internal('ohos-test-helpers', native_helpers, needs=('android-targets',))
    g.run('android-version-tree', lambda: g.py(rt + 'composition-android.py', '--baseline', p('android_baseline'), '--unpatched-prefix', p('android_pristine'), '--out', o / 'android-version-tree'), needs=('tools',), timeout=600)
    g.run('gate-runner-contract', lambda: g.py(tools + 'run-gates.test.py'), needs=('tools',), tests=[tools + 'run-gates.test.py'])
    def native_static(_):
        # The snapshot omits binary assets used by two existing real HTTP tests.
        # Generate explicit private fixtures, without changing their assertions.
        import struct, zlib
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
        data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
        data += chunk(b'IDAT', zlib.compress(b'\x00' * 4, 9)) + chunk(b'IEND', b'')
        assert hashlib.sha256(data).hexdigest() == '1280e8de649805526731cc11672b0479f5ca25d9bd7ebf7a3375f8a9c966205e'
        result = {}
        for relative in ('runtime/tests/fixtures/native-static/assets/img/dot.png',
                         'runtime/tests/ohos/host-bridge-fixture/proof.png'):
            path = s / relative
            generated = not path.exists()
            if generated:
                path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
            result[relative] = {'generatedFixture': generated, 'bytes': path.stat().st_size, 'sha256': sha(path)}
        return result
    g.internal('native-static-resources', native_static, needs=('tools',))
    g.run('native-publication-build', lambda: ['bash', s / (rt + 'build-publication-native.sh'), p('node_root'), native()], needs=('native-tools',))
    g.run('tinyemu-native', lambda: g.py('tooling/ohos/research/tinyemu-native/run.py', '--source-archive', p('tinyemu_source_archive'), '--node-headers', headers(), '--output', o / 'tinyemu-native', '--cc', p('cc'), '--node', node(), '--guest-config', p('tinyemu_guest_config')), needs=('native-tools',), timeout=600, tests=['tooling/ohos/research/tinyemu-native/' + name for name in ['run.py', 'node-case.mjs', 'guest-case.mjs', 'build-guest-fixture.py', 'baseline-entry.c', 'fatal-call.c', 'network-call.c', 'join-fault.c', 'join-fault.mjs', 'socket-construction.mjs', 'semantic-core.c', 'clock-cpu.c']], scope='Real host Node NAPI + TinyEMU fatal/FD/join and provided private guest fixture; fatal baseline uses explicit legacy-entry bridge after omitting dependent event-wait layer; no SDK/HAP/device')
    g.run('tinyemu-ram-retirement', lambda: g.py('tooling/ohos/research/tinyemu-ram-retire/run.py', '--source-archive', p('tinyemu_source_archive'), '--node-headers', headers(), '--out', o / 'tinyemu-ram-retirement', '--cc', p('cc'), '--node', node()), needs=('native-tools',), timeout=240, tests=['tooling/ohos/research/tinyemu-ram-retire/' + name for name in ['run.py', 'monitor.c', 'node-case.mjs']], scope='Actual product Node async join and TinyEMU main RAM; test-only host page touch and fault observers, mincore before/after assertions; no guest workload, SDK/device or PSS claim')
    g.run('hap-linux-stage', lambda: g.py('tooling/ohos/research/tinyemu-native/hap-stage.py', '--source', s, '--expect-linux'), needs=('tools',), tests=['tooling/ohos/research/tinyemu-native/hap-stage.py'], scope='Actual pre-SDK staging and cleanup; not HAP build')
    g.run('tinyemu-block-io', lambda: g.py('tooling/ohos/research/tinyemu-block-io/run.py', '--source-archive', p('tinyemu_source_archive'), '--output', o / 'tinyemu-block-io', '--cc', p('cc')), needs=('tools',), timeout=120, tests=['tooling/ohos/research/tinyemu-block-io/run.py', 'tooling/ohos/research/tinyemu-block-io/block-io.c'], scope='Actual regular-file write/seek/flush errors through production TinyEMU and virtio status; bounded RAM/IRQ fixture, no guest/SDK/device')
    g.run('linux-device-measure', lambda: g.node('--test', s / (tools + 'linux-device-measure.test.mjs')), needs=('tools',), timeout=60, tests=[tools + 'linux-device-measure.test.mjs'], scope='Host measurement CLI over actual loopback HTTP with explicit control/guest fixtures; no VM, SDK, device or account assertion')
    g.run('native-zlib-build', lambda: [p('cxx'), '-std=c++17', '-shared', '-fPIC', '-I', headers(), s / (tools + 'runtime-zip-zlib.cc'), '-lz', '-o', o / 'zlib.node'], needs=('native-tools',))
    g.run('native-opener-build', lambda: [p('cxx'), '-std=c++17', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', '-I', headers(), s / (rt + 'user-file-access-addon.cc'), '-o', o / 'user-file-access.node'], needs=('native-tools',))
    g.run('workspace-grants-build', lambda: [p('cxx'), '-std=c++17', '-pthread', '-Wall', '-Wextra', '-Werror', '-Wl,--wrap=pread', s / (rt + 'workspace-grants.cc'), s / 'app/ohos/entry/src/main/cpp/workspace_grants.cpp', '-o', o / 'workspace-grants-test'], needs=('tools',))
    g.run('workspace-grants', lambda: [o / 'workspace-grants-test', o / 'workspace-grants-fixture'], needs=('workspace-grants-build',))
    g.run('workspace-grants-addon', lambda: [p('cxx'), '-std=c++17', '-pthread', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', '-I', headers(), s / (rt + 'workspace-grants-addon.cc'), s / 'app/ohos/entry/src/main/cpp/workspace_grants.cpp', '-o', o / 'workspace-grants.node'], needs=('native-tools',))
    g.node_tests('authorized-workspaces', [rt + 'authorized-workspaces.test.mjs', rt + 'entry-ability-fixture.test.mjs'], needs=('workspace-grants-addon',), extra=lambda: {'OHOS_TYPESCRIPT_PREFIX': str(p('typescript_prefix')), 'OHOS_WORKSPACE_GRANTS_ADDON': str(o / 'workspace-grants.node'), 'OHOS_WORKSPACE_CASES': str(o / 'workspace-cases.json')})
    g.run('authorized-workspaces-dart', lambda: [p('dart'), s / (rt + 'authorized-workspaces-consumer.dart'), o / 'workspace-cases.json'], needs=('authorized-workspaces', 'dart-tools'))
    g.run('authorized-workspaces-channel', lambda: g.py(rt + 'authorized-workspaces-channel.test.py', '--dart', p('dart'), '--output', o / 'authorized-workspaces-channel'), needs=('tools', 'dart-tools'), tests=[rt + 'authorized-workspaces-channel.test.py'], scope='Actual Dart MethodChannel switch and decoder; Flutter transport double only, no device claim')
    g.node_tests('phone-folder-permission', [rt + 'phone-folders.test.mjs'], needs=('tools',), extra=lambda: {'OHOS_TYPESCRIPT_PREFIX': str(p('typescript_prefix'))})
    g.run('linux-runtime-dart', lambda: g.py(rt + 'linux-runtime-dart.py', '--dart', p('dart'), '--out', o / 'linux-runtime-dart'), needs=('tools', 'dart-tools'), tests=[rt + 'linux-runtime-dart.py', rt + 'linux-runtime-probe.dart'], scope='Actual OH Linux Dart protocol and channel consumer; explicit Flutter transport boundary, not device')
    g.run('file-access-build', lambda: [p('cxx'), '-std=c++17', '-pthread', '-Wall', '-Wextra', '-Werror', '-I', s / 'app/ohos/entry/src/main/cpp', s / (rt + 'user-file-access.cc'), '-o', o / 'user-file-access-test'], needs=('tools',))
    g.run('file-access', lambda: [o / 'user-file-access-test', o / 'user-file-access-fixture'], needs=('file-access-build',))
    g.run('napi-isolation', lambda: g.py(rt + 'napi-isolation.py', '--node-headers', headers(), '--node-executable', node(), '--compiler', p('cxx'), '--out', o / 'napi-isolation'), needs=('native-tools',), timeout=240)
    g.run('host-embedded', lambda: g.py(rt + 'host-embedded.py', '--node', node(), '--headers', headers(), '--out', o / 'host-embedded'), needs=('native-tools',), timeout=240)
    g.run('tinyemu-stop-boot', lambda: g.py('tooling/ohos/research/tinyemu-stop/run.py', '--source-archive', p('tinyemu_source_archive'), '--diskimage', p('tinyemu_diskimage_archive'), '--alpine', p('tinyemu_alpine_archive'), '--output', o / 'tinyemu-stop-boot', '--cc', p('cc')), needs=('tools',), timeout=600, tests=['tooling/ohos/research/tinyemu-stop/run.py', 'tooling/ohos/research/tinyemu-stop/build-image.py', 'tooling/ohos/research/tinyemu-stop/stop-call.c', 'tooling/ohos/research/tinyemu-stop/boot-call.c', 'tooling/ohos/research/tinyemu-stop/semantic-core.c', 'tooling/ohos/research/tinyemu-stop/clock-cpu.c'], scope='Actual TinyEMU saturated/closed socket stop/join and fixed Linux boot; VM devices retained; no HAP/device')
    g.run('linux-guest-jobs', lambda: g.py('tooling/ohos/research/linux-job/run.py', '--inputs', p('linux_job_inputs'), '--library', o / 'tinyemu-stop-boot/candidate/libtemu.so', '--cc', p('cc'), '--output', o / 'linux-guest-jobs'), needs=('tinyemu-stop-boot',), timeout=420, tests=['runtime/ohos/linux/guest-agent.py', 'tooling/ohos/research/linux-job/run-test.py'], scope='Actual guest argv/stdin/ACK/tree cancellation and git clone; no host workspace leases, HAP or device')
    g.run('linux-guest-clean-close', lambda: g.py(tools + 'guest-clean-close.test.py', '--source', s / 'runtime/ohos/linux/guest-agent.py', '--output', o / 'linux-guest-clean-close'), needs=('tools',), timeout=90, tests=[tools + 'guest-clean-close.test.py'], scope='Actual Python Agent close over pipes and host root syncfs; explicit syscall/FD fault cases, no VM or device durability claim')
    g.run('linux-guest-mounts', lambda: g.py(tools + 'guest-mounts.test.py', '--source', s / 'runtime/ohos/linux/guest-agent.py', '--output', o / 'linux-guest-mounts'), needs=('tools',), timeout=90, tests=[tools + 'guest-mounts.test.py'], scope='Actual agent mount validation and per-job namespace/bind/read-only views on the host kernel in an unprivileged user namespace; tmpfs stands in for 9P, no VM')
    g.run('linux-fs-export', lambda: g.py(tools + 'linux-fs-export.test.py', '--source-archive', p('tinyemu_source_archive'), '--cc', p('cc'), '--output', o / 'linux-fs-export'), needs=('tools',), timeout=120, tests=[tools + 'linux-fs-export.test.py', tools + 'linux-fs-export.c'], scope='Production fs_export.c FSDevice ops on the host filesystem against guest escape attempts (dot-dot, guest links, stale fids, FIFO); no VM')
    g.run('host-startup', lambda: g.py(rt + 'host-startup.py', '--node-root', p('node_root'), '--dsh-prefix', prefix(), '--out', o / 'host-startup'), needs=('prepared-inputs',), timeout=240)
    g.run('publication-system-build', lambda: g.py(rt + 'publication-system-build.py', '--node-root', p('node_root'), '--out', o / 'publication-system-build'), needs=('native-tools',), timeout=240)
    g.run('patcher-contract', lambda: [sys.executable, '-I', '-B', '-m', 'unittest', 'discover', '-s', str(s / 'runtime/tests'), '-p', 'test_patch_dsh.py', '-v'], needs=('tools',), env=lambda: {'DSH_FS_LOCAL_ORIGINAL_JS': str(p('android_pristine') / 'node_modules/@deepseek-ai/dsh-fs-local/lib/index.js')}, tests=['runtime/tests/test_patch_dsh.py'])
    g.node_tests('sim-contract', [rt + 'sim.test.mjs'], needs=('tools',))
    g.node_tests('measurement-helpers', [rt + 'measurement-loader.test.mjs', rt + 'measurement-publication-fixture.test.mjs'], needs=('prepared-inputs',))
    for mode in ('plain', 'jitless'):
        g.node_tests('plugin-graph-' + mode, [rt + 'plugin-graph.test.mjs'], mode=mode, needs=('prepared-inputs',))
    g.run('bash-producer-contract', lambda: g.py(rt + 'build-just-bash.test.py', '--package', p('prepared') / 'process/node_modules/just-bash', '--out', o / 'bash-producer-contract'), needs=('prepared-inputs',), timeout=180, tests=[rt + 'build-just-bash.test.py'])
    g.run('licenses-registration', lambda: g.py(rt + 'licenses-registration.py', '--registration-root', s, '--process-prefix', p('prepared') / 'process', '--esbuild-prefix', p('esbuild_prefix')), needs=('prepared-inputs',), timeout=180)
    g.node_tests('output-utf8', [rt + 'output-utf8.test.mjs'], needs=('prepared-inputs',), extra=lambda: {'DSH_OUTPUT_COLLECTOR_TEST_MODULE': str(prefix() / 'node_modules/@deepseek-ai/dsh-subprocess-local/lib/output.js'), 'DSH_OUTPUT_COLLECTOR_TEST_SHA256': sha(prefix() / 'node_modules/@deepseek-ai/dsh-subprocess-local/lib/output.js')})
    g.run('build-bash', lambda: g.py('runtime/ohos/process/build-just-bash.py'), needs=('prepared-inputs',), env=g.common)
    g.run('workspace-fid-identity-barrier', lambda: g.py(rt + 'workspace-fids.test.py'), needs=('native-tools',), env=lambda: {'CXX': str(p('cxx'))}, tests=[rt + 'workspace-fids.test.py', rt + 'workspace-fids.cpp', rt + 'workspace-fids-barrier.cpp'], scope='Real native workspace FD identity and cancellation barrier; no SDK or device assertion')
    g.run('workspace-shell-host', lambda: [p('cxx'), '-std=c++17', '-pthread', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', s / 'app/ohos/entry/src/main/cpp/workspace_grants.cpp', '-o', o / 'libdsh_host.so'], needs=('native-tools',))
    g.run('workspace-shell-addon', lambda: [p('cxx'), '-std=c++17', '-pthread', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', '-I', headers(), s / 'runtime/ohos/process/files/addon.cc', '-ldl', '-o', o / 'workspace-shell.node'], needs=('native-tools',))
    g.run('workspace-shell-publisher', lambda: [p('cxx'), '-std=c++17', '-pthread', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', '-I', headers(), s / (rt + 'workspace-grants-addon.cc'), '-L', o, '-ldsh_host', '-Wl,-rpath,' + str(o), '-o', o / 'workspace-publisher.node'], needs=('workspace-shell-host',))
    g.node_tests('workspace-native-snapshot', [rt + 'workspace-snapshot.test.mjs'], needs=('workspace-shell-publisher', 'workspace-shell-addon'), extra=lambda: {'OHOS_GRANT_ADDON': str(o / 'workspace-shell.node'), 'OHOS_GRANT_PUBLISHER': str(o / 'workspace-publisher.node'), 'OHOS_GRANT_HOST': str(o / 'libdsh_host.so')})
    for workspace_mode in ('plain', 'jitless'):
        g.node_tests('workspace-shell-' + workspace_mode, [rt + 'workspace-shell.test.mjs'], mode=workspace_mode, needs=('workspace-shell-publisher', 'workspace-shell-addon', 'build-bash'), extra=lambda: {'OHOS_GRANT_ADDON': str(o / 'workspace-shell.node'), 'OHOS_GRANT_PUBLISHER': str(o / 'workspace-publisher.node'), 'OHOS_GRANT_HOST': str(o / 'libdsh_host.so')})
    for cp_mode in ('plain', 'jitless'):
        g.node_tests('workspace-cp-private-' + cp_mode, [rt + 'workspace-cp-private.test.mjs'], mode=cp_mode, timeout=45, needs=('workspace-shell-publisher', 'workspace-shell-addon', 'build-bash'), extra=lambda: {'OHOS_GRANT_ADDON': str(o / 'workspace-shell.node'), 'OHOS_GRANT_PUBLISHER': str(o / 'workspace-publisher.node'), 'OHOS_GRANT_HOST': str(o / 'libdsh_host.so')})
    g.run('build-regex', lambda: g.node(s / 'runtime/ohos/process/build-rg-regex.mjs', p('esbuild_prefix')), needs=('prepared-inputs',), env=g.common)
    def rg_inputs(_):
        rg = p('android_pristine') / 'node_modules/@vscode/ripgrep-linux-x64/bin/rg'
        expected = '193906679498de4d939345b937fa24e0e69a03c244bd70c859f5e41232713f21'
        if not rg.is_file(): raise Blocked('missing pinned native ripgrep 15.0.0')
        if sha(rg) != expected: raise ValueError('native ripgrep bytes differ from fixed oracle binary')
        patch = 'zzzzzzzzzzz-ohos-search-ignore-description.diff'
        relative = 'node_modules/@deepseek-ai/dsh-tool-fs-search/lib/index.js'
        pins = json.loads((s / 'runtime/patches/pins.json').read_text())['patches'][patch]
        target = o / 'grep-description-before' / relative
        target.parent.mkdir(parents=True)
        shutil.copy2(prefix() / relative, target)
        # Later lifecycle edits touch this same file; unwind the selected chain
        # to the description preimage, checking each real pin boundary.
        all_pins = json.loads((s / 'runtime/patches/pins.json').read_text())
        selected = all_pins['targetSets']['ohos']
        commands = []
        for name in reversed(selected[selected.index(patch):]):
            pin = all_pins['patches'][name].get('0.2.2-rc.1', {}).get(relative)
            if pin is None: continue
            if sha(target) != pin['after']: raise ValueError('Unexpected reverse-patch input: ' + name)
            for flag in ('--check', None):
                argv = ['git', 'apply', '--reverse', '--include=' + relative,
                        *([flag] if flag else []), str(s / 'runtime/patches' / name)]
                proc = subprocess.run(argv, cwd=o / 'grep-description-before', capture_output=True, text=True)
                commands.append({'argv': argv, 'exitCode': proc.returncode, 'stdout': proc.stdout, 'stderr': proc.stderr})
                proc.check_returncode()
            if sha(target) != pin['before']: raise ValueError('Unexpected reverse-patch output: ' + name)
        pin = pins['0.2.2-rc.1'][relative]
        (o / 'grep-description-before/node_modules/@deepseek-ai/dsh-tool-fs-search/package.json').write_text('{"type":"module"}\n')
        # Both source images resolve the real provider's sibling dependencies.
        (o / 'grep-description-before/node_modules/@deepseek-ai/dsh-tool-fs-search/node_modules').symlink_to(prefix() / 'node_modules', target_is_directory=True)
        return {'nativeRgSha256': expected, 'descriptionPin': pin, 'commands': commands,
                'gitfileOracleScope': 'NEW_NATIVE_ORACLE_NOT_HISTORICAL_RECOVERY'}
    g.internal('rg-inputs', rg_inputs, needs=('prepared-inputs',))
    def rg(): return p('android_pristine') / 'node_modules/@vscode/ripgrep-linux-x64/bin/rg'
    for mode in ('jit', 'strict', 'android-old-env', 'linux-old-env', 'openharmony-no-marker'):
        g.node_tests('grep-description-' + mode, [rt + 'process-rg-description.test.mjs'],
                     mode='marker' if mode == 'jit' else ('strict' if mode == 'strict' else 'plain'),
                     needs=('rg-inputs',), extra=lambda m=mode: {
                         'M6_DESCRIPTION_MODE': m, 'M6_PROVIDER_PREFIX': str(prefix()),
                         'M6_DESCRIPTION_BEFORE': str(o / 'grep-description-before/node_modules/@deepseek-ai/dsh-tool-fs-search/lib/index.js'),
                         'M6_DESCRIPTION_AFTER': str(prefix() / 'node_modules/@deepseek-ai/dsh-tool-fs-search/lib/index.js')})
    for mode in ('jit', 'strict'):
        g.run('rg-selection-' + mode, lambda m=mode: g.py(rt + 'process-rg-selection-oracle.py',
              '--runtime', s / 'runtime/ohos/process', '--node', node(), '--rg', rg(),
              '--preload', s / 'runtime/ohos/sim/preload.mjs', '--marker', s / 'runtime/ohos/sim/marker.mjs',
              '--bash-module', s / 'runtime/ohos/process/build/just-bash/index.js', '--out', o / ('rg-selection-' + m + '.json'), '--mode', m),
              needs=('rg-inputs', 'build-bash', 'build-regex', 'permission-tools'), timeout=300,
              tests=[rt + 'process-rg-selection-oracle.py'])
    def gitfile_env(mode):
        return {**g.common(), 'M6_GITFILE_MODE': mode, 'M6_GITFILE_ORACLE': str(o / 'gitfile-oracle/native.json'),
                'M6_GITFILE_FIXTURE_PARENT': str(o / 'gitfile-oracle'), 'OHOS_NATIVE_RG': str(rg()),
                'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony', 'DSH_GO_OHOS_SIM_ADDONS': '[]'}
    g.run('rg-gitfile-record', lambda: g.node(s / (rt + 'process-rg-gitfile-differential.mjs')),
          env=lambda: gitfile_env('record'), needs=('rg-inputs',), timeout=120,
          scope='New private native oracle and actual worktree/submodule; not recovered historical evidence')
    for mode in ('jit', 'strict'):
        g.run('rg-gitfile-' + mode, lambda m=mode: g.node(*(['--jitless', '--import', s / 'runtime/ohos/sim/preload.mjs'] if m == 'strict' else ['--import', s / 'runtime/ohos/sim/marker.mjs']), s / (rt + 'process-rg-gitfile-differential.mjs')),
              env=lambda m=mode: {**gitfile_env('replay'), 'M6_GITFILE_REPORT': str(o / ('rg-gitfile-' + m + '.json'))},
              needs=('rg-gitfile-record', 'build-bash', 'build-regex'), timeout=300,
              tests=[rt + 'process-rg-gitfile-differential.mjs'])
    g.run('rg-unicode-scalars', lambda: g.node(s / (rt + 'process-rg-unicode-differential.mjs')),
          env=lambda: {'OHOS_NATIVE_RG': str(rg())}, needs=('rg-inputs', 'build-regex'), timeout=300,
          tests=[rt + 'process-rg-unicode-differential.mjs'], scope='Existing host-only all-valid-scalar native comparison; not a latency measurement')
    g.run('compose', lambda: g.py('runtime/ohos/package/compose-runtime.py', '--target', 'ohos', '--dsh-prefix', p('prepared') / 'dsh', '--process-prefix', p('prepared') / 'process', '--target-report', p('prepared') / 'target-report.json', '--prepared-inputs', p('prepared') / 'prepared-inputs.json', '--regex-artifact', s / 'runtime/ohos/process/build/re2js-unicode.mjs', '--esbuild-prefix', p('esbuild_prefix'), '--imports-report', o / 'composition-imports.json', '--out', o / 'composed', '--node', node(), '--runtime-core', s / 'app/ohos/entry/src/main/ets/runtime/RuntimeCore.ets', '--keep-expanded'), needs=('prepared-inputs', 'build-regex'), timeout=300)
    # The attachment actor consumes an actual composed payload; its
    # explicit host-only marker is added to a small private test view by the entry.
    g.run('image-attachment-admission', lambda: g.py(rt + 'image-attachment-admission.test.py'),
          needs=('tools',), tests=[rt + 'image-attachment-admission.test.py'],
          scope='Real input selector against explicit Composer dependency fixtures; formal omission and final-pin admission, no full composition or SDK')
    for image_attachment_mode in ('plain', 'jitless'):
        g.run('image-attachment-' + image_attachment_mode,
              lambda m=image_attachment_mode: g.py(
                  rt + 'image-attachment-entry.py',
                  '--source', s, '--payload', payload(),
                  '--manifest', o / 'composed/expanded/dsh-runtime/manifest.json',
                  '--node', node(), '--node-headers', headers(),
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--cc', p('cc'), '--cxx', p('cxx'),
                  '--out', o / ('image-attachment-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'native-publication-build', 'native-tools'), timeout=600,
              tests=[rt + name for name in (
                  'image-attachment-entry.py', 'image-attachment-entry.mjs',
                  'image-attachment-input-catalog.json', 'image-attachment-oracle.json',
                  'image-attachment-sdk.c', 'image-attachment-inputs.c')],
              scope='Original host save/read/request chains, same-variant unknown-colour cache miss, and actual scanner cache-orientation failure recovery; facade/fixed-loader/NDK/bridge with explicit SDK and publication carriers, no real pixel decode, OH link or device')
    for filename in ['composition-inputs.test.py', 'composition-archive.test.py']:
        g.run(filename[:-3], lambda f=filename: g.py(rt + f), needs=('tools',), tests=[rt + filename])
    g.run('composition-boundaries', lambda: g.py(rt + 'composition-gates.py', '--out', o / 'composition-boundaries'), needs=('tools',))
    g.node_tests('composition-required', [rt + 'composition-required.test.mjs'], needs=('tools',), extra=lambda: {'OHOS_TYPESCRIPT_PREFIX': str(p('typescript_prefix'))})
    g.node_tests('composition-import-audit', [rt + 'composition-import-audit.test.mjs'], needs=('tools',))
    g.node_tests('composition-import-seams', [rt + 'composition-import-seams.test.mjs'], mode='strict', needs=('compose',), extra=lambda: {'OHOS_COMPOSITION_PREFIX': str(payload()), 'OHOS_PROCESS_SOURCE': str(payload() / 'runtime/ohos/process')})
    g.run('composition-process-matrix', lambda: g.py(rt + 'run-composition-tests.py', '--payload', payload(), '--node', node(), '--out', o / 'composition-process-matrix'), needs=('compose',), timeout=300)
    g.run('host-core', lambda: g.py(rt + 'host-core.py', '--out', o / 'host-core'), needs=('tools',))
    g.run('host-capture', lambda: g.py(rt + 'host-capture.py', '--cxx', p('cxx'), '--out', o / 'host-capture'),
          needs=('tools',), timeout=90, tests=[rt + 'host-capture.py', rt + 'host-capture.cc'],
          scope='Actual native Capture threads and poll counts with fake Node runner; cancellation/tail/retained writer cases; no SDK/device CPU claim')
    g.run('host-profile', lambda: g.py(rt + 'host-lifecycle-profile.py', '--out', o / 'host-profile'), needs=('tools',))
    g.run('host-adapter', lambda: g.py(rt + 'host-adapter.py', '--node-root', p('node_root'), '--ohos-headers', p('ohos_headers'), '--out', o / 'host-adapter'), needs=('native-tools',))
    def round_libraries(_):
        target = o / 'round-native'; target.mkdir()
        for name in ('libdsh_flock.so', 'libdsh_require_builtin.so'):
            shutil.copy2(p('native_library_dir') / name, target / name)
        command = [str(p('cxx')), '-std=c++17', '-shared', '-fPIC', '-pthread', '-Wall', '-Wextra', '-Werror',
                   '-I', str(s / 'app/ohos/entry/src/main/cpp'), '-I', str(s / 'runtime/ohos/host'),
                   str(s / (rt + 'host-foreground-fixture.cc')), '-o', str(target / 'libdsh_host.so')]
        subprocess.run(command, check=True, capture_output=True, text=True)
        return {'scope': 'Test double of the Ark-hosted library; not a Host build', 'libdshHostSha256': sha(target / 'libdsh_host.so')}
    g.internal('round-native-libraries', round_libraries, needs=('native-tools',))
    g.run('workspace-authority-entry', lambda: g.py(rt + 'workspace-authority-entry.py', '--node', node(), '--assembled-payload', payload(), '--typescript-prefix', p('typescript_prefix'), '--publication-fixture', native() / 'libpublication-test-linked.so', '--round-native-directory', o / 'round-native', '--node-headers', headers(), '--cxx', p('cxx'), '--out', o / 'workspace-authority-entry'), needs=('compose', 'native-publication-build', 'round-native-libraries', 'native-tools'), timeout=240, tests=[rt + name for name in ['workspace-authority-entry.py', 'workspace-authority-entry.mjs', 'workspace-authority-instrumentation.mjs', 'workspace-authority-owner-probe.mjs']], scope='Actual DSH bin/sole product preload/public shell factory and shared native FD authority; explicit SDK and retirement-confirmation fixtures; no Linux guest, SDK, device or complete user-session claim')
    for phone_folder_mode in ('plain', 'jitless'):
        g.run('phone-folders-' + phone_folder_mode,
              lambda m=phone_folder_mode: g.py(rt + 'phone-folders-linux.py',
                  '--source', s, '--payload', payload(),
                  '--manifest', o / 'composed/expanded/dsh-runtime/manifest.json',
                  '--node', node(), '--typescript-prefix', p('typescript_prefix'),
                  '--native-directory', o / 'workspace-authority-entry/native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--out', o / ('phone-folders-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'workspace-authority-entry', 'native-publication-build'),
              timeout=120, tests=[rt + name for name in
                  ['phone-folders-linux.py', 'phone-folders-entry.mjs', 'phone-folders-instrumentation.mjs']],
              scope='Actual composed DSH preload/public Node file provider and native FD leases after actual ETS grants; explicit picker/permission/fileShare OS boundaries; no SDK/HAP/device claim')
    # Insert after the existing workspace-authority-entry registration.
    # Reuse that group's actual host/consumer/publisher output. No new SDK fixture
    # input and no duplicate native build are introduced by these two frontend runs.
    for workspace_frontend_mode in ('plain', 'jitless'):
        g.run('workspace-frontend-' + workspace_frontend_mode,
              lambda m=workspace_frontend_mode: g.py(
                  rt + 'workspace-frontend-entry.py',
                  '--source', s, '--payload', payload(), '--node', node(),
                  '--typescript-prefix', p('typescript_prefix'),
                  '--native-directory', o / 'workspace-authority-entry/native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--provenance-file', o / 'composed/manifest.json',
                  '--out', o / ('workspace-frontend-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'workspace-authority-entry', 'native-publication-build'),
              timeout=120,
              tests=[rt + name for name in (
                  'workspace-frontend-entry.py', 'workspace-frontend-entry.mjs',
                  'workspace-frontend-instrumentation.mjs')],
              scope='Actual DSH bin/sole preload/WorkspaceRegistry/WorkingDirectory/public shell after real ETS FD publication; explicit SDK/storage/session-projection seams; no full chat, SDK, device, Linux guest or durable-storage claim')
    # Reuse the five existing authority-entry native outputs; these two groups
    # neither build native code nor prepare/copy a payload.
    for workspace_read_mode in ('plain', 'jitless'):
        g.run('workspace-read-' + workspace_read_mode,
              lambda m=workspace_read_mode: g.py(
                  rt + 'workspace-read-entry.py',
                  '--source', s, '--payload', payload(), '--node', node(),
                  '--manifest', o / 'composed/manifest.json',
                  '--typescript-prefix', p('typescript_prefix'),
                  '--native-directory', o / 'workspace-authority-entry/native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--out', o / ('workspace-read-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'workspace-authority-entry', 'native-publication-build'),
              timeout=120,
              tests=[rt + name for name in (
                  'workspace-read-entry.py', 'workspace-read-entry.mjs',
                  'workspace-read-instrumentation.mjs')],
              scope='Three ordinary default read calls: physical whole, selected logical whole, same small logical file streamed; actual services/tool pipeline and ETS FD publication with explicit SDK/in-memory Agent fixtures; no full chat, SDK/device, Linux guest or persistent-session claim')
    # Reuse the five existing authority-entry native outputs; these two groups
    # neither build native code nor prepare/copy a payload.
    for workspace_directory_mode in ('plain', 'jitless'):
        g.run('workspace-directory-' + workspace_directory_mode,
              lambda m=workspace_directory_mode: g.py(
                  rt + 'workspace-directory-entry.py',
                  '--source', s, '--payload', payload(), '--node', node(),
                  '--manifest', o / 'composed/manifest.json',
                  '--typescript-prefix', p('typescript_prefix'),
                  '--native-directory', o / 'workspace-authority-entry/native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--out', o / ('workspace-directory-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'workspace-authority-entry', 'native-publication-build'),
              timeout=120,
              tests=[rt + name for name in (
                  'workspace-directory-entry.py', 'workspace-directory-entry.mjs',
                  'workspace-directory-instrumentation.mjs')],
              scope='Two ordinary directory API-service calls: physical root positive control and selected logical root; actual SessionStore/registered lookup/WorkspaceFiles and ETS FD publication with explicit SDK doubles; no full RPC/UI/watch, SDK/device or persistent-session claim')
    # Reuse the existing authority-entry native outputs and composed payload.
    for workspace_bytes_mode in ('plain', 'jitless'):
        g.run('workspace-bytes-' + workspace_bytes_mode,
              lambda m=workspace_bytes_mode: g.py(
                  rt + 'workspace-bytes-entry.py',
                  '--source', s, '--payload', payload(), '--node', node(),
                  '--manifest', o / 'composed/manifest.json',
                  '--typescript-prefix', p('typescript_prefix'),
                  '--native-directory', o / 'workspace-authority-entry/native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--out', o / ('workspace-bytes-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'workspace-authority-entry', 'native-publication-build'),
              timeout=120,
              tests=[rt + name for name in (
                  'workspace-bytes-entry.py', 'workspace-bytes-entry.mjs',
                  'workspace-bytes-instrumentation.mjs')],
              scope='Two ordinary 11-byte file windows through actual SessionStore/registered lookup/WorkspaceFiles and readByteRange: physical and selected logical; complete return-object oracle and target-await resource sample; no full readBytes, multi-window/Dart/RPC/UI, SDK/device or persistent-session claim')
    # Reuse the actual Session scope and native publication outputs for full bytes.
    for workspace_whole_bytes_mode in ('plain', 'jitless'):
        g.run('workspace-whole-bytes-' + workspace_whole_bytes_mode,
              lambda m=workspace_whole_bytes_mode: g.py(
                  rt + 'workspace-whole-bytes-entry.py',
                  '--source', s, '--payload', payload(), '--node', node(),
                  '--manifest', o / 'composed/manifest.json',
                  '--typescript-prefix', p('typescript_prefix'),
                  '--native-directory', o / 'workspace-authority-entry/native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--out', o / ('workspace-whole-bytes-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'workspace-authority-entry', 'native-publication-build'),
              timeout=120,
              tests=[rt + name for name in (
                  'workspace-whole-bytes-entry.py', 'workspace-whole-bytes-entry.mjs',
                  'workspace-whole-bytes-instrumentation.mjs')],
              scope='Four ordinary no-range whole-byte contracts: physical and normally selected logical 11-byte files at cap11 and cap10; actual SessionStore/registered scope/WorkspaceFiles/Sandbox, independent exact versions and target-await/dispose samples; no range, codec, HTTP/RPC/UI, SDK/device or new Native claim')
    # Existing-only default whole-write; no old logical baseline or new-file claim.
    for workspace_write_existing_mode in ('plain', 'jitless'):
        g.run('workspace-write-existing-' + workspace_write_existing_mode,
              lambda m=workspace_write_existing_mode: g.py(
                  rt + 'workspace-write-existing-entry.py',
                  '--source', s, '--payload', payload(), '--node', node(),
                  '--manifest', o / 'composed/manifest.json',
                  '--typescript-prefix', p('typescript_prefix'),
                  '--native-directory', o / 'workspace-authority-entry/native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--out', o / ('workspace-write-existing-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'workspace-authority-entry', 'native-publication-build'),
              timeout=120,
              tests=[rt + name for name in (
                  'workspace-write-existing-entry.py', 'workspace-write-existing-entry.mjs',
                  'workspace-write-existing-instrumentation.mjs', 'workspace-write-existing-oracle.json')],
              scope='Two after-only existing-file default write contracts: physical and normally selected logical; actual SessionStore/ToolRuntime/Sandbox/Local, complete batch and independent exact versions, after-write-await and dispose resource samples; no new file, guard/cancellation, full Host/RPC/UI or device claim')
    # Four normal defaults: existing/new, physical/logical; same-source whole V1 build.
    for workspace_write_whole_mode in ('plain', 'jitless'):
        g.run('workspace-write-whole-' + workspace_write_whole_mode,
              lambda m=workspace_write_whole_mode: g.py(
                  rt + 'workspace-write-whole-entry.py',
                  '--source', s, '--payload', payload(), '--node', node(),
                  '--manifest', o / 'composed/expanded/dsh-runtime/manifest.json',
                  '--typescript-prefix', p('typescript_prefix'),
                  '--native-directory', o / 'workspace-authority-entry/native',
                  '--authority-build-directory', o / 'workspace-authority-entry',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--out', o / ('workspace-write-whole-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'workspace-authority-entry', 'native-publication-build'),
              timeout=120,
              tests=[rt + name for name in (
                  'workspace-write-whole-entry.py', 'workspace-write-whole-entry.mjs',
                  'workspace-write-whole-instrumentation.mjs', 'workspace-write-whole-oracle.json')],
              scope='Four after-only default whole writes through actual SessionStore/ToolRuntime/Sandbox/Local and the new same-source Native group; full batch/version/five-method effect2/resource oracle, same-parent wx directory-default mode/gid reference; no old logical baseline, guard/wx fallback/cancellation/effect1/ACL/SGID/device claim')
    # Two normal logical writes cancelled after a real positive staging write; no publication.
    for workspace_write_cancel_mode in ('plain', 'jitless'):
        g.run('workspace-write-cancel-' + workspace_write_cancel_mode,
              lambda m=workspace_write_cancel_mode: g.py(
                  rt + 'workspace-write-cancel-entry.py',
                  '--source', s, '--payload', payload(), '--node', node(),
                  '--manifest', o / 'composed/expanded/dsh-runtime/manifest.json',
                  '--typescript-prefix', p('typescript_prefix'),
                  '--native-directory', o / 'workspace-authority-entry/native',
                  '--authority-build-directory', o / 'workspace-authority-entry',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--out', o / ('workspace-write-cancel-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'workspace-authority-entry', 'native-publication-build'),
              timeout=120,
              tests=[rt + name for name in (
                  'workspace-write-cancel-entry.py', 'workspace-write-cancel-entry.mjs',
                  'workspace-write-cancel-instrumentation.mjs', 'workspace-write-cancel-oracle.json')],
              scope='Two normal logical existing/new whole writes cancelled through the original signal after the first real positive staging write; full provider rejection/batch, unchanged-or-absent target, owned staging and lease/dispose/retirement oracle; no guarded copy, partial publication, fault injection, physical cancellation, full Host or device claim')
    # Reuse the composed payload and the same authority-entry native registry.
    # Only two normal own-file read/edit cases; no new native build in this runner.
    for workspace_edit_mode in ('plain', 'jitless'):
        g.run('workspace-edit-' + workspace_edit_mode,
              lambda m=workspace_edit_mode: g.py(
                  rt + 'workspace-edit-entry.py',
                  '--source', s, '--payload', payload(), '--node', node(),
                  '--manifest', o / 'composed/manifest.json',
                  '--typescript-prefix', p('typescript_prefix'),
                  '--native-directory', o / 'workspace-authority-entry/native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--out', o / ('workspace-edit-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'workspace-authority-entry', 'native-publication-build'),
              timeout=120,
              tests=[rt + name for name in (
                  'workspace-edit-entry.py', 'workspace-edit-entry.mjs',
                  'workspace-edit-instrumentation.mjs')],
              scope='Two ordinary own-file default read/edit calls through actual SessionStore/Session/WorkingDirectory/tool pipeline and ETS select/attach; real host grant/save components, explicit SDK/Agent/publication fixtures; independent exact-stat versions and post-edit-await lease sample; no full Host/RPC/UI, SDK/device, fault/race/VM or expected-intent claim')
    # Explicit optional apply_patch: two ordinary existing-file Update operations.
    # Default standard preset remains applyPatch:false; no Add/Move/Delete here.
    for workspace_patch_mode in ('plain', 'jitless'):
        g.run('workspace-patch-' + workspace_patch_mode,
              lambda m=workspace_patch_mode: g.py(
                  rt + 'workspace-patch-entry.py',
                  '--source', s, '--payload', payload(), '--node', node(),
                  '--manifest', o / 'composed/manifest.json',
                  '--typescript-prefix', p('typescript_prefix'),
                  '--native-directory', o / 'workspace-authority-entry/native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--out', o / ('workspace-patch-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'workspace-authority-entry', 'native-publication-build'),
              timeout=120,
              tests=[rt + name for name in (
                  'workspace-patch-entry.py', 'workspace-patch-entry.mjs',
                  'workspace-patch-instrumentation.mjs')],
              scope='Explicit applyPatch:true ordinary existing-file single Update through actual SessionStore/tool pipeline and normal ETS select/attach; physical and authorized logical, full oracle and ordinary cleanup; standard default false; no Add/Move/Delete, injected expected, Host/RPC/UI/device/VM or whole-write claim')
    # Explicit optional apply_patch: two ordinary existing-file Delete File operations.
    # Default standard preset remains applyPatch:false; no Add/Move/Update here.
    for workspace_delete_mode in ('plain', 'jitless'):
        g.run('workspace-delete-' + workspace_delete_mode,
              lambda m=workspace_delete_mode: g.py(
                  rt + 'workspace-delete-entry.py',
                  '--source', s, '--payload', payload(), '--node', node(),
                  '--manifest', o / 'composed/manifest.json',
                  '--typescript-prefix', p('typescript_prefix'),
                  '--native-directory', o / 'workspace-authority-entry/native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--out', o / ('workspace-delete-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'workspace-authority-entry', 'native-publication-build'),
              timeout=120,
              tests=[rt + name for name in (
                  'workspace-delete-entry.py', 'workspace-delete-entry.mjs',
                  'workspace-delete-instrumentation.mjs')],
              scope='Explicit applyPatch:true ordinary existing-file single Delete File through actual SessionStore/tool pipeline and normal ETS select/attach; physical and authorized logical, full oracle and ordinary cleanup; standard default false; no Add/Move/Update, injected expected, Host/RPC/UI/device/VM or whole-write claim')
    # Explicit optional apply_patch: two ordinary same-root Move operations.
    # New destination, existing parent; reuse composed payload and existing authority outputs.
    for workspace_move_mode in ('plain', 'jitless'):
        g.run('workspace-move-' + workspace_move_mode,
              lambda m=workspace_move_mode: g.py(
                  rt + 'workspace-move-entry.py',
                  '--source', s, '--payload', payload(), '--node', node(),
                  '--manifest', o / 'composed/manifest.json',
                  '--typescript-prefix', p('typescript_prefix'),
                  '--native-directory', o / 'workspace-authority-entry/native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--out', o / ('workspace-move-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'workspace-authority-entry', 'native-publication-build'),
              timeout=120,
              tests=[rt + name for name in (
                  'workspace-move-entry.py', 'workspace-move-entry.mjs',
                  'workspace-move-instrumentation.mjs')],
              scope='Explicit applyPatch:true ordinary same-root Move to absent destination with existing parent; actual SessionStore/tool pipeline and normal ETS select/attach; physical and logical, complete provider/batch/meta/file-version oracle and ordinary cleanup; default false; no partial/fault/expected/cross-grant/new-parent, Host/RPC/UI/device/VM claim')
    # Explicit optional apply_patch: same-root Move over an owned existing destination.
    # Source mode 0640, destination OLD LF/mode0600; original complete update oracle.
    for workspace_move_overwrite_mode in ('plain', 'jitless'):
        g.run('workspace-move-overwrite-' + workspace_move_overwrite_mode,
              lambda m=workspace_move_overwrite_mode: g.py(
                  rt + 'workspace-move-overwrite-entry.py',
                  '--source', s, '--payload', payload(), '--node', node(),
                  '--manifest', o / 'composed/manifest.json',
                  '--typescript-prefix', p('typescript_prefix'),
                  '--native-directory', o / 'workspace-authority-entry/native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--out', o / ('workspace-move-overwrite-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'workspace-authority-entry', 'native-publication-build'),
              timeout=120,
              tests=[rt + name for name in (
                  'workspace-move-overwrite-entry.py', 'workspace-move-overwrite-entry.mjs',
                  'workspace-move-overwrite-instrumentation.mjs')],
              scope='Explicit applyPatch:true ordinary same-root Move over existing owned destination; source FIRST LF/mode0640 and destination OLD LF/mode0600 to SECOND LF/mode0640, original complete update/provider/batch/meta/version/cleanup oracle; actual SessionStore and normal select/attach; default false, no guard/fallback/partial/new-parent/cross-grant/device/VM claim')
    # Explicit optional apply_patch: new destination under two absent owned parent levels.
    # Source mode 0644; parent mode is 0777 masked by the actual child umask.
    for workspace_move_parents_mode in ('plain', 'jitless'):
        g.run('workspace-move-parents-' + workspace_move_parents_mode,
              lambda m=workspace_move_parents_mode: g.py(
                  rt + 'workspace-move-parents-entry.py',
                  '--source', s, '--payload', payload(), '--node', node(),
                  '--manifest', o / 'composed/manifest.json',
                  '--typescript-prefix', p('typescript_prefix'),
                  '--native-directory', o / 'workspace-authority-entry/native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--out', o / ('workspace-move-parents-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('compose', 'workspace-authority-entry', 'native-publication-build'),
              timeout=120,
              tests=[rt + name for name in (
                  'workspace-move-parents-entry.py', 'workspace-move-parents-entry.mjs',
                  'workspace-move-parents-instrumentation.mjs')],
              scope='Explicit applyPatch:true ordinary same-root Move to nested/archive/moved.txt with both parents absent before and after read; actual SessionStore and normal select/attach; full create/provider/batch/meta/versions, source0644 and parent umask oracle, ordinary cleanup; default false; no overwrite/guard/fallback/partial/fault/cancel/cross-grant/device/VM claim')
    g.run('host-layout', lambda: g.py(rt + 'host-layout.py', '--node', node(), '--native-library-dir', o / 'round-native', '--publication-fixture', native() / 'libpublication-test-linked.so', '--assembled-payload', payload(), '--out', o / 'host-layout'), needs=('compose', 'native-publication-build', 'native-static-resources', 'round-native-libraries'), timeout=240)
    g.run('host-safe-profile', lambda: g.py(rt + 'host-safe-profile.py', '--node', node(), '--native-library-dir', o / 'round-native', '--publication-fixture', native() / 'libpublication-test-linked.so', '--assembled-payload', payload(), '--out', o / 'host-safe-profile'), needs=('compose', 'native-publication-build', 'round-native-libraries'), timeout=600, tests=[rt + 'host-safe-profile.py'], scope='Actual Host safe argv and original public round; not OH device restart')
    for label, host in [('loopback', '127.0.0.1'), ('owned-http', g.config.get('ownedHttpHost', ''))]:
        g.run('mcp-' + label, lambda h=host: g.py(rt + 'add13/host-gate.py', '--source', s, '--payload', payload(), '--manifest', o / 'composed/manifest.json', '--node', node(), '--native-library-dir', o / 'round-native', '--publication-fixture', native() / 'libpublication-test-linked.so', '--out', o / ('mcp-' + label), '--expect', 'complete', '--mcp-host', h if label == 'loopback' else owned_http_host(h)), needs=('compose', 'native-publication-build', 'native-static-resources', 'round-native-libraries'), timeout=240)
    for mcp_start_mode in ['plain', 'jitless']:
        g.run('mcp-start-close-' + mcp_start_mode, lambda m=mcp_start_mode: g.py(
            rt + 'mcp-start-close.py', '--source', s, '--prefix', prefix(),
            '--node', node(), '--python', sys.executable,
            '--out', o / ('mcp-start-close-' + m), *(['--jitless'] if m == 'jitless' else [])),
            needs=('prepared-inputs', 'android-targets'), timeout=120,
            tests=[rt + name for name in ('mcp-start-close.py', 'mcp-start-close-actor.mjs',
                'mcp-stdio-guest-fixture.mjs', 'mcp-stdio-server.py', 'linux-control-fixture.mjs')],
            scope='Actual MCP plugin and ESM/CJS SDK close while main startup waits for Linux admission; real Python normal initialize/two calls; unchanged kill-before-start events; explicit guest/native fixture, no VM/device')
    g.node_tests('python-loader', [rt + 'python-loader.test.mjs'], needs=('tools',))
    g.run('python-build-inputs', lambda: g.py(rt + 'python-build-inputs.test.py'), needs=('tools',), tests=[rt + 'python-build-inputs.test.py'], scope='Python ELF preflight and fixed system certificate compile option; controlled compiler boundary, no SDK build')
    g.run('python-package', lambda: g.py(rt + 'python-package.test.py'), needs=('tools',), tests=[rt + 'python-package.test.py'], scope='Actual stdlib compilation and composer asset integrity; no SDK/device claim')
    g.run('linux-assets-package', lambda: g.py(rt + 'linux-assets-package.test.py'), needs=('tools',), tests=[rt + 'linux-assets-package.test.py'], scope='Actual six-file composition, ZIP integrity and pre-SDK native pairing with small data fixtures; no guest/HAP/device claim')
    # Small build-stage regressions only. Register next to linux-assets-package.
    g.run('linux-tools-ownership', lambda: g.py(
        'tooling/ohos/tests/linux-tools-ownership.test.py', '--source', s,
        '--output', o / 'linux-tools-ownership'),
        needs=('tools',), timeout=60,
        tests=['tooling/ohos/tests/linux-tools-ownership.test.py'],
        scope='Real small production tar assembly/readback; nonroot filesystem or explicit TarInfo owner input reported in RESULT; no six-asset, SDK or guest build')
    g.run('linux-control-staging', lambda: g.py(
        'tooling/ohos/tests/linux-control-staging.test.py', '--source', s,
        '--output', o / 'linux-control-staging'),
        needs=('tools',), timeout=60,
        tests=['tooling/ohos/tests/linux-control-staging.test.py'],
        scope='Actual production Linux source-copy nodes; complete top-level mjs byte/mode set with a future ordinary module; no assets, native or VM execution')
    g.run('linux-assets-composition', lambda: g.py(rt + 'linux-assets-compose.py', '--prepared', p('prepared'), '--regex-artifact', s / 'runtime/ohos/process/build/re2js-unicode.mjs', '--esbuild-prefix', p('esbuild_prefix'), '--assets', p('linux_install_assets'), '--baseline', o / 'composed', '--node', node(), '--out', o / 'linux-assets-composition'), needs=('compose',), timeout=600, tests=[rt + 'linux-assets-compose.py'], scope='Actual composer with real prepared receipt and six Linux assets; ZIP identity and refusal/cleanup, no SDK/HAP/device build')
    g.run('python-production', lambda: g.py(rt + 'python-native.py', '--production', '--node-headers', p('node_source') / 'src', '--output', o / 'python-production'), needs=('tools',), timeout=120, tests=[rt + 'python-production.test.mjs', rt + 'python-owner.test.mjs', rt + 'python-native-symbols.test.mjs', rt + 'python-link-probe.c', rt + 'python-test-observation.mjs'], scope='Host shared-library production source, real subinterpreter/cwd/env/SQLite/SSL/stream/cancel/owner-exit and separately loaded CPython extension ABI; HAP and device NOT_RUN')
    g.node_tests('python-backend', [rt + 'python-backend.test.mjs'], needs=('tools',))
    g.run('python-native', lambda: g.py(rt + 'python-native.py', '--node-headers', p('node_source') / 'src', '--output', o / 'python-native'), needs=('tools',), timeout=120, tests=[rt + 'python-native.test.cjs', rt + 'python-host.test.mjs'], scope='Actual host libpython Node-API probe; streamed text output, cooperative cancellation, no device claim')
    g.run('tinyemu-console-ready', lambda: g.py('tooling/ohos/research/tinyemu-console-ready/run.py', '--source-archive', p('tinyemu_source_archive'), '--node-headers', headers(), '--cc', p('cc'), '--out', o / 'tinyemu-console-ready'), needs=('native-tools',), timeout=240, tests=['tooling/ohos/research/tinyemu-console-ready/' + name for name in ['run.py', 'console-ready.c']], scope='Actual product loop, slirp UDP reply and initialized VirtIO console; explicit CPU packet/ring/IRQ fixtures, diagnostic old/new and normal candidate controls; no guest instructions, SDK/device or performance claim')
    g.run('tinyemu-event-wake', lambda: g.py(rt + 'tinyemu-event-wake/run.py', '--source', s, '--source-archive', p('tinyemu_source_archive'), '--node-headers', headers(), '--cc', p('cc'), '--node', node(), '--out', o / 'tinyemu-event-wake'), needs=('native-tools',), timeout=300, tests=[rt + 'tinyemu-event-wake/' + name for name in ['run.py', 'component.py', 'wake-call.c', 'wake-boundary.c', 'wake-loop-bridge.c', 'slirp-deadline.c', 'owner-fault.c', 'owner-case.mjs', 'lifecycle-case.mjs', 'adoption-case.mjs']], scope='Actual C deadlines/socket waits and Node owner stop/join/FD/GC faults; explicit link fault seams; no device, finite scheduler or blocking disk bound')
    g.run('linux-startup-close', lambda: g.py(rt + 'linux-startup-close/run.py', '--source', s, '--native-run', o / 'tinyemu-event-wake/RUN.json', '--node', node(), '--cc', p('cc'), '--publication', native() / 'libpublication-test-linked.so', '--out', o / 'linux-startup-close'), needs=('tinyemu-event-wake', 'prepared-inputs', 'native-publication-build'), timeout=120, tests=[rt + 'linux-startup-close/' + name for name in ['run.py', 'close-fault.c', 'native-case.mjs', 'owner-case.mjs', 'partial-start.mjs']], scope='Actual drive-open/fseek/ftello rollback and native join, real Owner/Control/files/flock; explicit per-library syscall/configuration faults; no guest instructions, SDK/device or full teardown')
    g.run('linux-creation-retirement', lambda: g.py(rt + 'linux-creation-retirement.py', '--source', s, '--native-run', o / 'tinyemu-event-wake/RUN.json', '--node', node(), '--publication', native() / 'libpublication-test-linked.so', '--out', o / 'linux-creation-retirement'), needs=('tinyemu-event-wake', 'prepared-inputs', 'native-publication-build'), timeout=90, tests=[rt + 'linux-creation-retirement.py', rt + 'linux-creation-retirement.test.mjs'], scope='Actual NAPI constructor and Owner/Control/files/flock with existing pthread/close fault DSO; no VM body, new compile or device')
    g.run('tinyemu-retire', lambda: g.py('tooling/ohos/research/tinyemu-retire/run.py', '--source-archive', p('tinyemu_source_archive'), '--diskimage', p('tinyemu_diskimage_archive'), '--alpine', p('tinyemu_alpine_archive'), '--output', o / 'tinyemu-retire', '--cc', p('cc')), needs=('tools',), timeout=600, tests=['tooling/ohos/research/tinyemu-retire/' + name for name in ['run.py', 'build-image.py', 'install-call.c', 'retire-call.c', 'fault-wrap.c', 'semantic-core.c', 'clock-cpu.c']], scope='Real owned disk FD retirement including flush/close failures and Linux install; VM remains quarantined; no HAP/device')
    g.node_tests('spawn-boundary', [rt + 'child-process-boundary.test.mjs'], needs=('tools',))
    for mode in ['jit', 'strict']:
        g.node_tests('linux-base-download-' + mode, [rt + 'linux-base-download.test.mjs'], mode=mode, needs=('tools',))
    g.run('linux-download-user-agent', lambda: g.py('tooling/ohos/tests/linux-download-ua.py', '--inputs', p('linux_job_inputs'), '--output', o / 'linux-download-user-agent', '--node', node()), needs=('tools',), timeout=180, tests=['tooling/ohos/tests/linux-download-ua.py', rt + 'linux-base-user-agent.test.mjs'], scope='Real verified local HTTPS with fixed product UA, explicit test CA and pinned input-cache checks; no Huawei availability/device claim')

    g.run('tinyemu-clint-deadline', lambda: g.py('tooling/ohos/research/tinyemu-clint-deadline/run.py', '--source-archive', p('tinyemu_source_archive'), '--node-headers', headers(), '--out', o / 'tinyemu-clint-deadline', '--cc', p('cc'), '--node', node()), needs=('native-tools',), timeout=240, tests=['tooling/ohos/research/tinyemu-clint-deadline/' + name for name in ['run.py', 'timer-boundary.c', 'select-observer.c', 'node-case.mjs']] + ['tooling/ohos/research/tinyemu-native/clock-cpu.c'], scope='Actual RV32/RV64 unsigned CLINT and WFI boundaries, existing clock regressions and production Node tiny BIOS select/VM-thread CPU observations; no Linux kernel, SDK/device or App CPU attribution')
    g.run('tinyemu-sleep-micros', lambda: g.py('tooling/ohos/research/tinyemu-sleep-micros/run.py', '--source-archive', p('tinyemu_source_archive'), '--node-headers', headers(), '--out', o / 'tinyemu-sleep-micros', '--cc', p('cc')), needs=('native-tools',), timeout=240, tests=['tooling/ohos/research/tinyemu-sleep-micros/' + name for name in ['run.py', 'sleep-boundary.c']] + ['tooling/ohos/research/tinyemu-native/clock-cpu.c', 'tooling/ohos/research/tinyemu-clint-deadline/timer-boundary.c'], scope='Actual RV32/RV64 WFI and select microsecond boundaries, legacy millisecond and nonembed dispatch, existing CLINT/clock regressions; explicit clock/select/network fixtures, no Linux/device timing or hard deadline claim')
    g.run('slirp-udp-expiry', lambda: g.py('tooling/ohos/research/slirp-udp-expiry/run.py', '--source-archive', p('tinyemu_source_archive'), '--node-headers', headers(), '--cc', p('cc'), '--out', o / 'slirp-udp-expiry'), needs=('native-tools',), timeout=240, tests=['tooling/ohos/research/slirp-udp-expiry/' + name for name in ['run.py', 'expiry.c', 'first-poll.c']], scope='Actual slirp/UDP FDs with controlled monotonic clock, 31-case old/new comparison, nonembed equivalence and real first product loop with explicit CPU packet producer; no guest/device or hard wall-time expiry claim')
    g.run('slirp-fasttimo', lambda: g.py('tooling/ohos/research/slirp-fasttimo/run.py', '--source-archive', p('tinyemu_source_archive'), '--node-headers', headers(), '--cc', p('cc'), '--out', o / 'slirp-fasttimo'), needs=('native-tools',), timeout=240, tests=['tooling/ohos/research/slirp-fasttimo/' + name for name in ['run.py', 'tcp-wire.c']], scope='Actual slirp TCP handshake/data/ACK and loopback peer, 13 old/new cases with explicit guest Ethernet and monotonic clock; nonembed source equivalence; no guest instructions, device or wall-time ACK bound')
    g.run('tinyemu-install', lambda: g.py('tooling/ohos/research/tinyemu-install/run.py', '--source-archive', p('tinyemu_source_archive'), '--diskimage', p('tinyemu_diskimage_archive'), '--alpine', p('tinyemu_alpine_archive'), '--output', o / 'tinyemu-install', '--cc', p('cc'), '--node', node()), needs=('tools',), timeout=600, tests=['tooling/ohos/research/tinyemu-install/' + name for name in ['run.py', 'build-image.py', 'install-call.c', 'prepare-fixture.mjs', 'semantic-core.c', 'clock-cpu.c']], scope='Real three-drive guest installation and Node plain image preparation; no HAP/device or cancellation completion')
    for mode in ['jit', 'strict']:
        g.node_tests('linux-prepare-images-' + mode, [rt + 'linux-prepare-images.test.mjs'], mode=mode, needs=('tools',))
    for mode in ['plain', 'strict']:
        g.node_tests('linux-proxy-policy-' + mode, [rt + 'linux-proxy-policy.test.mjs'],
                     mode=mode, needs=('prepared-inputs',))
        g.node_tests('linux-guest-environment-' + mode, [rt + 'linux-guest-environment.test.mjs'],
                     mode=mode, needs=('prepared-inputs',))
        g.node_tests('linux-wake-retirement-' + mode, [rt + 'linux-wake-retirement.test.mjs'],
                     mode=mode, needs=('prepared-inputs', 'android-targets', 'native-publication-build'),
                     extra=linked_env, timeout=60)
        g.node_tests('linux-off-retirement-' + mode,
                     [rt + 'linux-off-retirement.test.mjs', rt + 'linux-off-retirement-adjacent.test.mjs'],
                     mode=mode, needs=('prepared-inputs', 'android-targets', 'native-publication-build'),
                     extra=lambda m=mode: {**linked_env(), 'DSH_1289_CASES': str(o / ('linux-off-retirement-' + m) / 'cases')}, timeout=60)
        g.node_tests('linux-app-control-' + mode,
                     [rt + 'linux-control-entry.test.mjs', rt + 'linux-owner-control.test.mjs', rt + 'linux-control.test.mjs', rt + 'linux-control-persistence.test.mjs', rt + 'linux-instance.test.mjs', rt + 'linux-proxy-control.test.mjs', rt + 'linux-ram-retirement.test.mjs'],
                     mode=mode, needs=('prepared-inputs', 'android-targets', 'native-publication-build'),
                     extra=linked_env, timeout=120)
        g.run('linux-routed-budget-' + mode,
              lambda m=mode: g.py(rt + 'linux-routed-budget.py', '--node', node(), '--mode', m,
                                 '--out', o / ('linux-routed-budget-' + m)),
              needs=('prepared-inputs',), timeout=60,
              tests=[rt + 'linux-routed-budget.py', rt + 'linux-routed-budget-probe.mjs'],
              scope='Actual LinuxControl with real async timers and isolated child wall-clock offsets; explicit owner/backend; no VM, suspend, SDK or scheduler upper-bound claim')
        g.node_tests('linux-routed-disposal-' + mode, [rt + 'linux-routed-disposal.test.mjs'],
                     mode=mode, needs=('prepared-inputs', 'android-targets'))
        g.node_tests('command-router-' + mode,
                     [rt + 'node-streaming-stdin.test.mjs', rt + 'plugin-process.test.mjs', rt + 'mcp-command-router.test.mjs', rt + 'python-command-router.test.mjs', rt + 'command-router-ownership.test.mjs', rt + 'linux-command-routing.test.mjs'],
                     mode=mode, imports=(["runtime/ohos/sim/marker.mjs"] if mode == 'plain' else []) + ['runtime/ohos/process/node-worker-preload.mjs'],
                     needs=('prepared-inputs', 'android-targets', 'build-bash', 'build-regex'),
                     extra=lambda: {'DSH_PREFIX': str(prefix())})
    g.run('linux-runtime-backend', lambda: g.py('tooling/ohos/research/linux-backend/run.py', '--node', node(), '--dsh-prefix', p('prepared') / 'dsh', '--native-library-dir', p('tinyemu_native_library_dir'), '--guest-config', p('tinyemu_guest_config'), '--output', o / 'linux-runtime-backend'), needs=('prepared-inputs',), timeout=600, tests=['tooling/ohos/research/linux-backend/' + name for name in ['run.py', 'protocol.test.mjs', 'clean-close.test.mjs', 'guest-test.mjs']], scope='Production Linux backend with real Node NAPI and private guest disks; no SDK/device or authorized workspace 9P')
    for mcp_mode in ('plain', 'jitless'):
        g.run('mcp-stdio-plugin-' + mcp_mode, lambda m=mcp_mode: g.py(
            rt + 'mcp-stdio-entry.py', '--source', s, '--prefix', prefix(), '--node', node(),
            '--python', sys.executable, '--out', o / ('mcp-stdio-plugin-' + m),
            *(['--jitless'] if m == 'jitless' else [])),
            needs=('prepared-inputs', 'android-targets'), timeout=60,
            tests=[rt + name for name in ('mcp-stdio-entry.py', 'mcp-stdio-plugin-entry.mjs',
                                         'mcp-stdio-guest-fixture.mjs', 'mcp-stdio-server.py')],
            scope='Real Cordis MCP plugin initialize/list/two calls over current Linux JS routing and TCP to a real local Python stdio server; explicit owner/native-session/guest-kernel fixture, no VM/HAP/device')
    g.node_tests('linux-instance-process', [rt + 'linux-instance-process.test.mjs'],
                 needs=('prepared-inputs', 'native-publication-build'), extra=linked_env, timeout=120)
    g.node_tests('linux-proxy-fixture', ['tooling/ohos/research/linux-proxy/proxy-fixture.test.mjs'], needs=('tools',))
    g.run('linux-private-proxy', lambda: g.py('tooling/ohos/research/linux-proxy/run.py', '--source', s, '--node', node(), '--dsh-prefix', p('prepared') / 'dsh', '--native-library-dir', p('tinyemu_native_library_dir'), '--publication-fixture', native() / 'libpublication-test-linked.so', '--assets', p('linux_install_assets'), '--archive', p('tinyemu_alpine_archive'), '--output', o / 'linux-private-proxy'), needs=('tools', 'prepared-inputs', 'native-publication-build'), timeout=900, tests=['tooling/ohos/research/linux-proxy/' + name for name in ['run.py', 'guest-proxy.mjs', 'proxy-pair.mjs', 'proxy-fixture.mjs', 'proxy-fixture.test.mjs']], scope='Actual private guest Git/gh HTTP CONNECT and TLS-to-proxy, domestic Git/urllib bypass with explicit private TLS/DNS fixtures; credentials/HTTP/wire/raw outputs never recorded; no phone/public account claim')
    g.node_tests('linux-resume-witness', ['tooling/ohos/research/linux-resume/guest-witness.test.mjs'], needs=('tools',))
    for jobs_mode in ('plain', 'jitless'):
        g.node_tests('jobs-active-' + jobs_mode, [rt + 'jobs-active.test.mjs'],
                     mode=jobs_mode, needs=('prepared-inputs', 'android-targets'),
                     extra=lambda: {'DSH_PREFIX': str(prefix())})
    g.node_tests('linux-job-diagnostics', [rt + 'linux-job-diagnostics.test.mjs', rt + 'linux-job-diagnostics-control.test.mjs'], needs=('prepared-inputs',))
    g.run('linux-clean-resume', lambda: g.py('tooling/ohos/research/linux-resume/run.py', '--node', node(), '--dsh-prefix', p('prepared') / 'dsh', '--native-library-dir', p('tinyemu_native_library_dir'), '--publication-fixture', native() / 'libpublication-test-linked.so', '--assets', p('linux_install_assets'), '--archive', p('tinyemu_alpine_archive'), '--output', o / 'linux-clean-resume'), needs=('prepared-inputs', 'native-publication-build'), timeout=900, tests=['tooling/ohos/research/linux-resume/' + name for name in ['run.py', 'guest-resume.mjs', 'guest-witness.mjs', 'guest-witness.test.mjs']], scope='Two sequential real Node/VM lifetimes, same actual supplied asset generation and retained target; real HTTP/guest sync/native retirement plus fresh-epoch directboot, no HAP/device/upgrade migration or power-loss claim')
    g.run('linux-installation-owner', lambda: g.py('tooling/ohos/research/linux-owner/run.py', '--node', node(), '--dsh-prefix', p('prepared') / 'dsh', '--native-library-dir', p('tinyemu_native_library_dir'), '--publication-fixture', native() / 'libpublication-test-linked.so', '--assets', p('linux_install_assets'), '--archive', p('tinyemu_alpine_archive'), '--output', o / 'linux-installation-owner'), needs=('prepared-inputs', 'native-publication-build'), timeout=900, tests=['tooling/ohos/research/linux-owner/run.py', 'tooling/ohos/research/linux-owner/owner-test.mjs'], scope='Actual first install owner/guest pivot/clean close/stop FD cleanup; explicit archive transport, no Huawei HTTP/HAP/device assertion')
    g.run('linux-command-routing-guest', lambda: g.py('tooling/ohos/research/linux-routing/run.py', '--node', node(), '--dsh-prefix', p('prepared') / 'dsh', '--native-library-dir', p('tinyemu_native_library_dir'), '--publication-fixture', native() / 'libpublication-test-linked.so', '--assets', p('linux_install_assets'), '--archive', p('tinyemu_alpine_archive'), '--output', o / 'linux-command-routing-guest'), needs=('prepared-inputs', 'native-publication-build', 'build-bash', 'build-regex'), timeout=900, tests=['tooling/ohos/research/linux-routing/' + name for name in ['run.py', 'guest-routing.mjs']], scope='Agent-style bash -c through the production router/virtual shell into a real TinyEMU guest: gh/python3/pip, 9P workspace read/write seen on the host, read-only view, not-enabled message and cancellation; verified archive transport, no HAP/device/Huawei HTTP')
    g.run('linux-app-control-guest', lambda: g.py('tooling/ohos/research/linux-control/run.py', '--node', node(), '--dsh-prefix', p('prepared') / 'dsh', '--native-library-dir', p('tinyemu_native_library_dir'), '--publication-fixture', native() / 'libpublication-test-linked.so', '--assets', p('linux_install_assets'), '--archive', p('tinyemu_alpine_archive'), '--output', o / 'linux-app-control-guest'), needs=('prepared-inputs', 'native-publication-build'), timeout=600, tests=['tooling/ohos/research/linux-control/' + name for name in ['run.py', 'guest-control.mjs']], scope='Actual authenticated HTTP LinuxControl/owner/backend and native TinyEMU guest; verified archive transport and clean close; paired recovery/HAP/device/Huawei HTTP separate')
    for mode in ['plain', 'jitless']:
        g.node_tests('plugin-archive-' + mode, [rt + 'plugin-archive.test.mjs'], mode=mode, needs=('prepared-inputs',))
    for filename in ['test.sh', 'test-integration.sh', 'test-proxy-env.sh', 'test-dispatcher-errors.sh']:
        g.run('net-' + filename[:-3], lambda f=filename: ['bash', s / 'runtime/ohos/net' / f], needs=('prepared-inputs', *(['network-interface-tools'] if filename == 'test-proxy-env.sh' else [])), env=lambda f=filename: {**g.common(), **({'NODE': str(p('fetch_node'))} if f == 'test.sh' else {})}, timeout=300)
    g.node_tests('net-bootstrap', [rt + 'net-bootstrap.test.mjs'], needs=('prepared-inputs',))
    for web_converter_mode in ('plain', 'jitless'):
        g.run('web-converter-lazy-' + web_converter_mode,
              lambda m=web_converter_mode: g.py(rt + 'web-converter-entry.py',
                  '--source', s, '--prefix', o / 'targets/ohos-prefix', '--node', node(),
                  '--out', o / ('web-converter-lazy-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('prepared-inputs', 'android-targets'), timeout=180,
              tests=[rt + name for name in ('web-converter-entry.py', 'web-converter-entry.mjs',
                                            'web-converter-golden.json')],
              scope='Actual public web tool registration/conversion, lazy module boundary, concurrent first HTML, cache and fault recovery; host only')
    for mode in ['plain', 'jitless']:
        g.node_tests('plugin-store-recovery-' + mode, [rt + 'plugin-store.test.mjs', rt + 'plugin-linkless-recovery.test.mjs'], mode=mode, needs=('prepared-inputs',))
    g.node_tests('provider-body-timeout', [rt + 'provider-body-timeout.test.mjs'], needs=('android-targets',))
    g.node_tests('inspector-compat', [rt + 'inspector-compat.test.mjs'], needs=('android-targets',), timeout=30)
    for mode in ['plain', 'jitless']:
        g.node_tests('piai-text-preabort-' + mode, [rt + 'piai-text-preabort.test.mjs'],
                     mode=mode, imports=(rt + 'piai-empty-models-network.mjs',),
                     needs=('android-targets',), timeout=30, extra=lambda: {'DSH_PREFIX': str(prefix())})
    for mode in ['plain', 'jitless']:
        g.node_tests('piai-empty-models-' + mode, [rt + 'piai-empty-models.test.mjs'],
                     mode=mode, imports=(rt + 'piai-empty-models-network.mjs',),
                     needs=('android-targets',), extra=lambda: {'DSH_PREFIX': str(prefix())})
    for mode in ['plain', 'jitless']:
        g.node_tests('skill-root-events-' + mode,
                     [rt + 'skill-root-events.test.mjs', rt + 'skill-root-events-fault.test.mjs', 'runtime/tests/skill-watcher-recheck.test.mjs'],
                     mode=mode, needs=('android-targets',), extra=lambda: {'DSH_PREFIX': str(prefix())})
    for mode in ['plain', 'jitless']:
        g.node_tests('client-hmr-idle-' + mode,
                     [rt + 'client-hmr-idle.test.mjs', rt + 'client-hmr-disposal.test.mjs',
                      'runtime/tests/client-hmr-closed-response.test.mjs'],
                     mode=mode, needs=('android-targets',), timeout=30)
        g.node_tests('api-gateway-idle-' + mode, [rt + 'api-gateway-idle.test.mjs'],
                     mode=mode, needs=('android-targets',), timeout=30)
    for mode in ['plain', 'jitless']:
        g.node_tests('cordis-catalog-lazy-' + mode, [rt + 'cordis-catalog-lazy.test.mjs'],
                     mode=mode, needs=('android-targets',), extra=lambda: {'DSH_PREFIX': str(prefix())})
    for mode in ['strict', 'plain']:
        g.node_tests('attachment-diagnostic-' + mode, [rt + 'attachment-error-recovery.test.mjs'],
                     mode=mode, needs=('android-targets',), extra=lambda: {'DSH_PREFIX': str(prefix())})
    # Actual storage/cache/shared requests; known-sRGB codec registration is an explicit test seam.
    for mode in ['strict', 'sim']:
        g.node_tests('attachment-image-cache-' + mode, [rt + 'attachment-image-cache.test.mjs'],
                     mode=mode, needs=('android-targets',), extra=lambda: {'DSH_PREFIX': str(prefix())})
    # Requires the already registered 941-12 image components; this overlay adds no native ABI.
    for mode in ['strict', 'sim']:
        g.node_tests('attachment-cache-proof-' + mode, [rt + 'attachment-cache-proof.test.mjs'],
                     mode=mode, needs=('android-targets',), extra=lambda: {'DSH_PREFIX': str(prefix())})
    for proof_mode in ('plain', 'jitless'):
        g.run('attachment-cache-proof-native-' + proof_mode,
              lambda m=proof_mode: g.py(rt + 'attachment-cache-proof.py',
                  '--source', s, '--prefix', o / ('image-attachment-' + m) / 'view',
                  '--native-library-dir', o / ('image-attachment-' + m) / 'native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--node', node(), '--out', o / ('attachment-cache-proof-native-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('image-attachment-' + proof_mode,), timeout=180,
              tests=[rt + name for name in ('attachment-cache-proof.py', 'attachment-cache-proof-native.mjs',
                                            'image-attachment-oracle.json')],
              scope='Actual image pipeline conversion counts, current bytes, owners and one-proof eviction; reuse the prior exact host SDK library, no new ABI or device claim')
    for storage_mode in ('plain', 'jitless'):
        g.run('image-file-storage-native-' + storage_mode,
              lambda m=storage_mode: g.py(rt + 'image-file-storage.py',
                  '--source', s, '--prefix', o / ('image-attachment-' + m) / 'view',
                  '--native-library-dir', o / ('image-attachment-' + m) / 'native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--node', node(), '--out', o / ('image-file-storage-native-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('image-attachment-' + storage_mode,), timeout=60,
              tests=[rt + name for name in ('image-file-storage.py', 'image-file-storage-native.mjs',
                                            'image-file-storage-observer.mjs', 'image-attachment-oracle.json')],
              scope='Actual fs allocation identity, plain Uint8Array public shape/transfer, short/growing/empty reads and unchanged codec snapshot; prior explicit host SDK fixture, no resident-memory or device claim')
    for cancel_mode in ('plain', 'jitless'):
        g.run('image-cancel-cache-miss-native-' + cancel_mode,
              lambda m=cancel_mode: g.py(rt + 'image-cancel-cache-miss.py',
                  '--source', s, '--prefix', o / ('image-attachment-' + m) / 'view',
                  '--native-library-dir', o / ('image-attachment-' + m) / 'native',
                  '--publication-fixture', native() / 'libpublication-test-linked.so',
                  '--node', node(), '--out', o / ('image-cancel-cache-miss-native-' + m),
                  *(['--jitless'] if m == 'jitless' else [])),
              needs=('image-attachment-' + cancel_mode,), timeout=60,
              tests=[rt + name for name in ('image-cancel-cache-miss.py', 'image-cancel-cache-miss-native.mjs',
                                            'image-cancel-cache-miss-fs.mjs', 'image-attachment-oracle.json')],
              scope='Actual missing-cache I/O, abort before its original Promise resolves, no new cancelled native encode, original reason and immediate retry; explicit libuv contention/host SDK fixtures, no time bound')
    # Optional entries that would reach a real process past the OH subprocess backend.
    for name in ['forge-github-unavailable', 'liveshare-owner-unavailable', 'market-git-unavailable']:
        g.node_tests(name, [rt + name + '.test.mjs'], needs=('android-targets',))
    # The package manager's public methods: refused on OH, and the same calls off it.
    for driver in ['plugin-install-refusal', 'plugin-registry-refusal']:
        script = s / (rt + driver + '.mjs')
        g.run(driver + '-ohos', lambda script=script, driver=driver: g.node('--jitless', '--import', s / 'runtime/ohos/sim/preload.mjs', script, prefix(), o / (driver + '-ohos.json'), 'ohos'),
              env={'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony', 'DSH_GO_OHOS_SIM_ADDONS': '[]'}, needs=('android-targets',))
        g.run(driver + '-control', lambda script=script, driver=driver: g.node(script, prefix(), o / (driver + '-control.json'), 'native'), needs=('android-targets',))
    def plugin_contract_env():
        return {'DSH_PREFIX': str(prefix()),
                'DSH_PLUGIN_BACKEND_MODULE': str(s / 'runtime/ohos/plugins/backend.mjs'),
                'DSH_PLUGIN_CAPABILITIES_MODULE': str(s / 'runtime/ohos/capabilities/snapshot.mjs'),
                'DSH_PLUGIN_SIM_PRELOAD': str(s / 'runtime/ohos/sim/preload.mjs')}
    g.node_tests('plugin-package-lifecycle', [rt + 'plugin-package-lifecycle.test.mjs', rt + 'plugin-market-capabilities.test.mjs'],
                 mode='strict', needs=('prepared-inputs', 'ohos-test-helpers'), extra=plugin_contract_env)
    g.node_tests('plugin-registry-fallback', [rt + 'plugin-registry-fallback.test.mjs'],
                 mode='strict', needs=('prepared-inputs', 'ohos-test-helpers'), extra=plugin_contract_env)
    g.node_tests('plugin-market-capabilities-native', [rt + 'plugin-market-capabilities.test.mjs'],
                 needs=('prepared-inputs', 'ohos-test-helpers'), extra=plugin_contract_env)
    g.node_tests('plugin-profile-recovery', [rt + 'plugin-profile-recovery.test.mjs'],
                 needs=('prepared-inputs', 'ohos-test-helpers'), extra=plugin_contract_env)
    g.node_tests('plugin-write-failure', [rt + 'plugin-write-failure.test.mjs'],
                 needs=('prepared-inputs', 'ohos-test-helpers'), extra=plugin_contract_env)
    for mode in ['plain', 'jitless']:
        g.node_tests('discovery-response-cleanup-' + mode, [rt + 'discovery-response-cleanup.test.mjs'],
                     mode=mode, needs=('prepared-inputs', 'android-targets'),
                     extra=lambda: {'DSH_DISCOVERY_PREFIX': str(prefix())})
    for mode in ['marker', 'strict']:
        g.node_tests('net-body-types-' + mode, [rt + 'net-body-types.test.mjs'], mode=mode, needs=('prepared-inputs',), extra={'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony', 'DSH_GO_OHOS_SIM_ADDONS': '[]'})
    g.node_tests('host-link-fixture', [rt + 'host-link-fixture.test.mjs'], mode='strict', host_links=True)
    for filename in ['test.sh', 'test-roots.sh']:
        g.run('process-' + filename[:-3], lambda f=filename: ['bash', s / 'runtime/ohos/process' / f], needs=('build-bash', 'build-regex'), env=g.common, timeout=360)
    for mode in ['marker', 'strict']:
        g.node_tests('process-extra-' + mode, [rt + 'process-limit-effects.test.mjs', rt + 'process-rg-large.test.mjs'], mode=mode, needs=('build-bash', 'build-regex'))
        for suite in ['client', 'oracle', 'semantics', 'worker']:
            g.run('git-' + suite + '-' + mode, lambda su=suite, m=mode: g.py(rt + 'run-git-tests.py', '--node', node(), '--linked', native() / 'libpublication-test-linked.so', '--prefix', prefix(), '--suite', su, '--mode', 'jit' if m == 'marker' else m, '--output', o / ('git-' + su + '-' + m)), needs=('native-publication-build', 'build-bash'), timeout=300)
        for suite in ['core', 'rpc', 'share']:
            g.run('owned-' + suite + '-' + mode, lambda su=suite, m=mode: g.py(rt + 'run-owned-tests.py', '--node', node(), '--native', native() / 'publication.node', '--linked', native() / 'libpublication-test-linked.so', '--sim-preload', s / 'runtime/ohos/sim/preload.mjs', '--marker-preload', s / 'runtime/ohos/sim/marker.mjs', '--suite', su, '--mode', 'jit' if m == 'marker' else m, '--output', o / ('owned-' + su + '-' + m)), needs=('native-publication-build',), timeout=90)
    for mode in ['marker', 'strict']:
        g.run('rg-oracle-' + mode, lambda m=mode: g.node(*(['--jitless', '--import', s / 'runtime/ohos/sim/preload.mjs'] if m == 'strict' else ['--import', s / 'runtime/ohos/sim/marker.mjs']), s / (rt + 'process-rg-m4-differential.mjs')), needs=('build-bash', 'build-regex'), env=lambda: {**g.common(), 'M4_RG_MODE': 'replay', 'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony', 'DSH_GO_OHOS_SIM_ADDONS': '[]'}, timeout=300, tests=[rt + 'process-rg-m4-differential.mjs'])
        g.node_tests('publication-installed-' + mode, [rt + 'publication-integration.test.mjs', rt + 'publication-locks.test.mjs', rt + 'lock-node-contract.test.mjs'], mode='sim' if mode == 'marker' else mode, imports=['runtime/ohos/publication/preload.mjs'], needs=('native-publication-build', 'prepared-inputs'), extra=lambda: {**linked_env(), 'DSH_HOME': str(o / ('publication-installed-' + mode + '-home')), 'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony'}, timeout=240, host_links=True)
    def native_boundary_env():
        return {'M3_PUBLICATION_ADDON': str(native() / 'publication.node'), 'M3_PUBLICATION_SHA256': sha(native() / 'publication.node'), 'M3_PUBLICATION_MODULE': str(s / 'runtime/ohos/publication/atomic.mjs'), 'M3_NATIVE_REPORT': str(o / 'native-boundaries.json'), 'M3_PUBLISHER_ERROR_REPORT': str(o / 'native-errno.json')}
    g.node_tests('publication-native-boundaries', [rt + 'publication-native-boundaries.test.mjs', rt + 'publication-errno-boundaries.test.mjs'], needs=('native-publication-build', 'permission-tools'), extra=native_boundary_env, timeout=240)
    g.run('hap-native-paths', lambda: g.py(rt + 'hap-native-paths.py', '--prefix', o / 'targets/ohos-prefix', '--node', node(), '--headers', headers(), '--loader-addon', p('native_library_dir') / 'libdsh_require_builtin.so', '--compiler', p('cc'), '--out', o / 'hap-native-paths'), needs=('android-targets',), timeout=180)
    g.node_tests('native-loader', [rt + 'native-loader-probe.test.mjs'], needs=('android-targets',), extra=lambda: {'DSH_TEST_NODE': str(node()), 'DSH_TEST_O0_PRELOAD': str(s / 'runtime/ohos/sim/preload.mjs'), 'DSH_TEST_NATIVE_PREFIX': str(o / 'targets/ohos-prefix'), 'DSH_TEST_NATIVE_ADDON': str(p('native_library_dir') / 'libdsh_require_builtin.so'), 'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(p('native_library_dir'))})
    def plugin_hmr_env():
        return {**plugin_contract_env(), 'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(p('native_library_dir')),
                'DSH_GO_OHOS_SIM_ADDONS': json.dumps([str(p('native_library_dir') / name)
                    for name in ['libdsh_flock.so', 'libdsh_require_builtin.so']]),
                'NARB_DISABLE_NATIVE_CACHE': '1'}
    for mode in ['sim', 'strict']:
        g.node_tests('plugin-installer-' + mode, [rt + 'plugin-installer.test.mjs'],
                     mode=mode, needs=('prepared-inputs', 'ohos-test-helpers', 'native-loader'), extra=plugin_hmr_env)
        g.node_tests('plugin-linkless-resolution-' + mode, [rt + 'plugin-linkless-resolution.test.mjs'],
                     mode=mode, needs=('prepared-inputs', 'ohos-test-helpers', 'native-loader'), extra=plugin_hmr_env)
    g.node_tests('plugin-linkless-worker', [rt + 'plugin-linkless-worker.test.mjs'], mode='strict',
                 imports=['runtime/ohos/plugins/preload.mjs'], needs=('prepared-inputs', 'ohos-test-helpers', 'native-loader'), extra=plugin_hmr_env)
    g.node_tests('plugin-internal-workers', [rt + 'plugin-internal-workers.test.mjs'], mode='strict',
                 imports=['runtime/ohos/plugins/preload.mjs', 'runtime/ohos/process/node-worker-preload.mjs'],
                 needs=('prepared-inputs', 'ohos-test-helpers', 'native-loader', 'build-bash', 'build-regex'), extra=plugin_hmr_env, timeout=180)
    g.node_tests('plugin-effect-dispose', [rt + 'plugin-effect-dispose.test.mjs'], mode='strict',
                 needs=('prepared-inputs', 'ohos-test-helpers', 'native-loader'), extra=plugin_hmr_env)
    g.node_tests('plugin-hmr-update', [rt + 'plugin-hmr-update.test.mjs'], mode='strict',
                 needs=('prepared-inputs', 'ohos-test-helpers', 'native-loader'), extra=plugin_hmr_env)
    g.node_tests('plugin-generation-reinstall', [rt + 'plugin-generation-reinstall.test.mjs'], mode='strict',
                 needs=('prepared-inputs', 'ohos-test-helpers', 'native-loader'), extra=plugin_hmr_env)
    g.node_tests('plugin-locale-bom', [rt + 'plugin-locale-bom.test.mjs'], mode='strict',
                 needs=('prepared-inputs', 'ohos-test-helpers', 'native-loader'), extra=plugin_hmr_env)
    for mode in ['strict', 'plain']:
        g.node_tests('plugin-generation-boundaries-' + mode, [rt + 'plugin-generation-boundaries.test.mjs'],
                     mode=mode, needs=('prepared-inputs', 'ohos-test-helpers'), extra=plugin_contract_env)
    g.node_tests('plugin-hmr-write-failure', [rt + 'plugin-hmr-write-failure.test.mjs'],
                 needs=('prepared-inputs', 'ohos-test-helpers', 'native-loader'), extra=plugin_hmr_env)
    g.node_tests('plugin-hmr-remove-failure', [rt + 'plugin-hmr-remove-failure.test.mjs'],
                 needs=('prepared-inputs', 'ohos-test-helpers', 'native-loader'), extra=plugin_hmr_env)
    g.node_tests('plugin-hmr-restart', [rt + 'plugin-hmr-restart.test.mjs'],
                 needs=('prepared-inputs', 'ohos-test-helpers', 'native-loader'), extra=plugin_hmr_env)
    publication = ['publication-atomic', 'publication-atomic-fuse', 'publication-ledger', 'publication-ledger-lifecycle', 'publication-capabilities']
    lifecycle = ['lifecycle-journal', 'lifecycle-budget', 'lifecycle-tool-budgets', 'lifecycle-transport', 'lifecycle-engine', 'lifecycle-explicit-resume', 'runtime-capabilities']
    for parking_mode in ['plain', 'jitless']:
        g.run('background-parking-' + parking_mode,
              lambda m=parking_mode: g.py(rt + 'background-parking.py', '--source', s,
                  '--node', node(), '--node-headers', headers(), '--cxx', p('cxx'),
                  '--esbuild-prefix', p('esbuild_prefix'), '--out', o / ('background-parking-' + m), '--mode', m),
              needs=('native-tools',), timeout=180,
              tests=[rt + name for name in ['background-parking.py', 'background-idle-native.cc', 'background-idle-fixture.mjs', 'background-idle.test.mjs', 'background-foreground.test.mjs', 'background-parking-boundaries.test.mjs']],
              scope='Selected ETS bodies and real LifecycleState; deterministic timer/clock and explicit OS/HTTP/ready boundaries, foreground/cleanup/qualification controls; no SDK/device/actual HTTP or CPU/PSS claim')
    for mode in ['plain', 'jitless']:
        for activity in ['lifecycle-independent-activity', 'lifecycle-jobs-retirement', 'linux-activity']:
            g.node_tests(activity + '-' + mode, [rt + activity + '.test.mjs'], mode=mode,
                         needs=('prepared-inputs', 'native-publication-build', 'round-native-libraries'),
                         extra=lambda: {**linked_env(), 'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(o / 'round-native')}, timeout=30)
    for mode in ['plain', 'jitless']:
        g.node_tests('lifecycle-idle-' + mode, [rt + 'lifecycle-idle.test.mjs'],
                     mode=mode, needs=('android-targets',), timeout=30)
        g.node_tests('lifecycle-native-reader-' + mode, [rt + 'lifecycle-native-reader.test.mjs'],
                     mode=mode, imports=[rt + 'lifecycle-native-reader-instrument.mjs'],
                     needs=('prepared-inputs', 'native-publication-build', 'round-native-libraries'),
                     extra=lambda: {'LD_PRELOAD': str(native() / 'libpublication-test-linked.so') + ':' + str(o / 'round-native/libdsh_host.so'),
                                    'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(o / 'round-native')}, timeout=30)
    for mode in ['marker', 'strict']:
        g.node_tests('publication-' + mode, [rt + n + '.test.mjs' for n in publication], mode=mode, needs=('native-publication-build', 'prepared-inputs'), extra=linked_env, timeout=240, host_links=True)
        g.node_tests('publication-lock-' + mode, [rt + 'publication-lock.test.mjs'],
                     needs=('native-publication-build',), extra=lambda m=mode: {**linked_env(),
                         'DSH_TEST_LOCK_STRICT': '1' if m == 'strict' else '0',
                         'DSH_TEST_SIM_PRELOAD': str(s / 'runtime/ohos/sim/preload.mjs')}, timeout=240)
        g.node_tests('publication-xattr-' + mode, [rt + 'publication-xattr.test.mjs'], mode=mode,
                     needs=('native-publication-build',), extra=lambda m=mode: {**linked_env(),
                         'DSH_TEST_XATTR_STRICT': '1' if m == 'strict' else '0'})
        for name in lifecycle:
            g.node_tests(name + '-' + mode, [rt + name + '.test.mjs'], mode=mode,
                         needs=('native-publication-build', 'compose'), extra=lambda m=mode: {**linked_env(),
                             'DSH_LIFECYCLE_TEST_PREFIX': str(payload() if m == 'strict' else prefix())}, timeout=240)
    # The ETS fixtures are .mts: Node strips those with Wasm, which jitless doesn't have.
    background = ['background-native-contract', 'background-admission', 'background-agent', 'background-owner-before', 'background-protocol']
    for mode in ['marker', 'strict']:
        for name in background:
            g.node_tests(name + '-' + mode, [rt + name + '.test.mjs'], mode=mode, imports=['tooling/ohos/tests/ets-fixture-loader.mjs'] if mode == 'strict' else [],
                         needs=('native-publication-build', 'prepared-inputs', 'android-targets'), extra=lambda: {**linked_env(), 'DSH_HOME': str(o / 'background-home'),
                             'DSH_LIFECYCLE_TEST_PREFIX': str(prefix()), 'DSH_BACKGROUND_OLD_PREFIX': str(o / 'targets/candidate-prefix'),
                             'NODE_PATH': str(p('android_pristine') / 'node_modules'), 'OHOS_ETS_FIXTURE_ARTIFACTS': str(o / 'ets-fixture-artifacts')}, timeout=240, host_links=name in ('background-native-contract', 'background-owner-before', 'background-protocol'))
    for mode in ['marker', 'strict']:
        for name in ['phone-bridge', 'phone-callback', 'phone-effects', 'phone-reminders', 'phone-http', 'phone-plugin-owner']:
            g.node_tests(name + '-' + mode, [rt + name + '.test.mjs'], mode=mode, imports=['tooling/ohos/tests/ets-fixture-loader.mjs'] if mode == 'strict' else [],
                         needs=('native-publication-build', 'prepared-inputs'), extra=lambda: {**linked_env(), 'DSH_HOME': str(o / 'phone-home'),
                             'NODE_PATH': str(p('android_pristine') / 'node_modules'), 'OHOS_ETS_FIXTURE_ARTIFACTS': str(o / 'ets-fixture-artifacts')}, timeout=240, host_links=name == 'phone-http')
    for mode in ['marker', 'strict']:
        g.node_tests('phone-calendar-all-day-' + mode, [rt + 'phone-calendar-all-day.test.mjs'], mode=mode,
                     imports=['tooling/ohos/tests/ets-fixture-loader.mjs'] if mode == 'strict' else [],
                     needs=('native-publication-build', 'prepared-inputs'), extra=lambda: {**linked_env(),
                         'TZ': 'America/New_York', 'OHOS_ETS_FIXTURE_ARTIFACTS': str(o / 'ets-fixture-artifacts')}, timeout=240)
    for label in ('crash', 'freeze'):
        def lifecycle_command(label=label):
            values = g.py(rt + 'lifecycle-' + label + '-controller.py', '--node', node(), '--prefix', prefix(), '--linked', native() / 'libpublication-test-linked.so', '--native-library-dir', p('native_library_dir'), '--out', o / ('lifecycle-' + label))
            if label == 'crash': values += ['--baseline-source', p('android_pristine') / 'node_modules/@deepseek-ai/dsh-tools/lib/pipeline.js']
            return values
        g.run('lifecycle-' + label, lifecycle_command, needs=('prepared-inputs', 'native-publication-build', 'build-bash', 'build-regex') + (('proc-mapping-tools',) if label == 'freeze' else ()), env=g.common, timeout=360, tests=[rt + 'lifecycle-' + label + '-controller.py'])
    g.node_tests('lifecycle-platform', [rt + 'lifecycle-platform.test.mjs'], needs=('prepared-inputs',), extra=lambda: {'DSH_LIFECYCLE_BASE_PIPELINE': str(p('android_pristine') / 'node_modules/@deepseek-ai/dsh-tools/lib/pipeline.js')})
    # Includes steady-heartbeat history isolation and control-completion ACK cases.
    g.node_tests('lifecycle-host-http', [rt + 'lifecycle-host-http.test.mjs'], needs=('prepared-inputs', 'native-publication-build'), extra=lambda: {**linked_env(), 'DSH_LIFECYCLE_BEFORE_ROUTE': str(p('lifecycle_before_route'))})
    g.node_tests('publication-platform', [rt + 'publication-platform.test.mjs', rt + 'fs-exclusive.test.mjs'], needs=('android-targets',), extra=lambda: {'DSH_TEST_PREFIX': str(o / 'targets/ohos-prefix')})
    g.node_tests('publication-capabilities-route', [rt + 'publication-capabilities-route.test.mjs'], needs=('prepared-inputs',), extra=lambda: {'M6_TEST_PREFIX': str(prefix()), 'M6_TEST_CAPABILITIES_MODULE': str(s / 'runtime/ohos/capabilities/index.mjs')})
    g.run('publication-startup', lambda: g.py(rt + 'publication-startup.py', '--node', node(), '--simulation', s / 'runtime/ohos/sim/preload.mjs', '--linked-lib', native() / 'libpublication-test-linked.so', '--out', o / 'publication-startup.json'), needs=('native-publication-build',), timeout=240)
    for mode in ['jit', 'strict']:
        g.run('publication-fuse-' + mode, lambda m=mode: g.py(rt + 'publication-fuse-integration.py', '--node', node(), '--simulation', s / 'runtime/ohos/sim/preload.mjs', '--marker', s / 'runtime/ohos/sim/marker.mjs', '--preload', s / 'runtime/ohos/preload.mjs', '--linked-lib', native() / 'libpublication-test-linked.so', '--prefix', prefix(), '--out', o / ('publication-fuse-' + m), '--mode', m), needs=('native-publication-build', 'prepared-inputs'), timeout=360)
    g.run('publication-scanners', lambda: g.py(rt + 'publication-scanners.py', '--node', node(), '--prefix', prefix(), '--publication-preload', s / 'runtime/ohos/publication/preload.mjs', '--linked', native() / 'libpublication-test-linked.so', '--simulation', s / 'runtime/ohos/sim/preload.mjs', '--marker', s / 'runtime/ohos/sim/marker.mjs', '--out', o / 'publication-scanners'), needs=('native-publication-build', 'prepared-inputs'), timeout=240)
    g.node_tests('deletion-core', ['runtime/tests/session-deletion-core.test.mjs', 'runtime/tests/session-deletion-route.test.mjs'], needs=('compose',), extra=lambda: {'DSH_SESSION_DELETION_CORE': str(o / 'composed/generated/ohos-deletion/core.mjs'), 'DSH_SESSION_DELETION_ROUTE': str(payload() / 'runtime/bridge/dsh-go-bridge/lib/session-deletion.js')})
    g.run('session-resource-cleanup', lambda: g.py(rt + 'session-resource-cleanup.py', '--source', s, '--prefix', prefix(), '--node', node(), '--out', o / 'session-resource-cleanup'), needs=('android-targets',), timeout=60, tests=[rt + 'session-resource-cleanup.py', rt + 'session-resource-cleanup.test.mjs'], scope='Actual authenticated permanent deletion, public SDK cleanup and loopback pooled WebSocket; existing Linux flock host target, no device or close-time guarantee')
    g.node_tests('deletion-publication', [rt + 'session-deletion-publication.test.mjs'], mode='strict', needs=('compose', 'native-publication-build'), extra=lambda: {**linked_env(), 'DSH_SESSION_DELETION_CORE': str(o / 'composed/generated/ohos-deletion/core.mjs')})
    g.run('deletion-directory-sync', lambda: g.node('--jitless', '--import', s / 'runtime/ohos/sim/preload.mjs', '--import', s / 'runtime/ohos/publication/preload.mjs', '--test', '--test-isolation=none', s / (rt + 'session-deletion-sync/directory-sync.test.mjs')), needs=('compose', 'native-publication-build'), env=lambda: {**g.common(), **linked_env(), 'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony', 'DSH_HOME': str(o / 'groups/deletion-directory-sync/home'), 'DSH_DELETION_SYNC_SOURCE': str(o / 'composed/generated/ohos-deletion/core.mjs'), 'DSH_DELETION_SYNC_TRACE': str(o / 'directory-sync-trace.json')}, tests=[rt + 'session-deletion-sync/directory-sync.test.mjs'])
    for name in ['native-files', 'voice']:
        g.run(name, lambda n=name: g.py(rt + n + '-linux.py', '--node', node(), '--typescript-prefix', p('typescript_prefix'), '--out', o / n), needs=('tools',), timeout=240)
    for mode in ['plain', 'jitless']:
        g.run('picture-shortcut-' + mode, lambda m=mode: g.py(rt + 'picture-shortcut-linux.py', '--node', node(), '--typescript-prefix', p('typescript_prefix'), '--mode', m, '--out', o / ('picture-shortcut-' + m)), needs=('tools',), timeout=180, tests=[rt + 'picture-shortcut.test.mjs', rt + 'entry-ability-fixture.test.mjs'], scope='Actual picture-shortcut ETS and Entry registration with real host files; explicit ImageKit/AppGallery/Flutter boundaries, no device permission or launcher proof')
    for name in ['pdf', 'hms-share']:
        g.run(name, lambda n=name: g.py(rt + n + '-linux.py', '--node', node(), '--node-headers', headers(), '--typescript-prefix', p('typescript_prefix'), '--out', o / n, '--cxx', p('cxx')), needs=('tools',), timeout=240)
    g.run('native-media', lambda: g.py(rt + 'native-media-linux.py', '--node', node(), '--node-headers', headers(), '--typescript-prefix', p('typescript_prefix'), '--path-provider-source', p('path_provider_source'), '--cxx', p('cxx'), '--out', o / 'native-media'), needs=('tools',), timeout=240)
    for mode in ['plain', 'jitless']:
        g.run('media-video-' + mode, lambda m=mode: g.py(rt + 'media-video-linux.py', '--node', node(), '--node-headers', headers(), '--typescript-prefix', p('typescript_prefix'), '--embedding-har', p('embedding_har'), '--cxx', p('cxx'), '--mode', m, '--out', o / ('media-video-' + m)), needs=('tools',), timeout=180, tests=[rt + 'media-video.test.mjs'])
    g.run('system-asr-native', lambda: g.py(rt + 'system-asr-linux.py', '--node', node(), '--typescript-prefix', p('typescript_prefix'), '--out', o / 'system-asr-native'), needs=('tools',), timeout=300,
          tests=[rt + 'system-asr-native.test.mjs', rt + 'system-asr-channel.test.mjs', rt + 'system-asr-capture.test.mjs'], scope='Real external-PCM ASR ETS, channel, lease and EntryAbility; explicit HMS/Flutter/clock host boundaries; not SDK/device')
    g.run('pcm-stream-native', lambda: g.py(rt + 'pcm-stream-native.py', '--node', node(), '--typescript-prefix', p('typescript_prefix'), '--out', o / 'pcm-stream-native'), needs=('tools',), timeout=240, tests=[rt + 'pcm-stream.test.mjs', rt + 'pcm-stream-call.test.mjs'], scope='Actual PCM ETS: communication usage, 40ms levels from hardware-frame-position doubles, ownership/drain barriers; not SDK or device audio')
    g.run('performance-dart', lambda: g.py(rt + 'performance-linux.py', '--node', node(), '--dart', p('dart'), '--typescript-prefix', p('typescript_prefix'), '--out', o / 'performance-dart'), needs=('tools', 'dart-tools'), timeout=180)
    g.run('diagnostics-dart', lambda: g.py(rt + 'diagnostics-linux.py', '--node', node(), '--dart', p('dart'), '--typescript-prefix', p('typescript_prefix'), '--zlib-addon', o / 'zlib.node', '--output', o / 'diagnostics-dart'), needs=('tools', 'dart-tools', 'native-zlib-build'), timeout=240)
    g.run('diagnostic-evidence', lambda: g.py(rt + 'diagnostic-evidence-linux.py', '--node', node(), '--typescript-prefix', p('typescript_prefix'), '--zlib-addon', o / 'zlib.node', '--out', o / 'diagnostic-evidence'),
          needs=('tools', 'native-zlib-build'), timeout=240,
          tests=[rt + name for name in ['diagnostic-evidence.test.mjs', 'diagnostic-keyboard.test.mjs', 'diagnostic-evidence-cold.mjs', 'diagnostic-evidence-linux.py']],
          scope='Actual ETS record/fault channel and real Linux FD persistence; explicit HiAppEvent SDK boundary; strict host types and separate cold write/read processes; no device delivery claim')
    g.internal('dart-consumer-evidence', lambda _: verify_dart_consumers(o), needs=('diagnostics-dart', 'performance-dart'))
    g.node_tests('arkts-compatibility', [rt + 'arkts-compatibility.test.mjs'], needs=('tools',), timeout=120)
    g.run('keyboard-geometry', lambda: g.py(rt + 'keyboard-geometry-linux.py', '--node', node(), '--typescript-prefix', p('typescript_prefix'), '--out', o / 'keyboard-geometry'),
          needs=('tools',), timeout=300, tests=[rt + 'keyboard-geometry.test.mjs', rt + 'keyboard-log.test.mjs', rt + 'entry-ability-fixture.test.mjs'],
          scope='Actual own-window geometry/diagnostics/EntryAbility with explicit Window/Flutter/clock boundaries; strict host types, not SDK or device')
    for widget_mode in ('plain', 'jitless'):
        g.run('companion-widget-' + widget_mode, lambda m=widget_mode: g.py(rt + 'companion-widget-linux.py', '--node', node(), '--typescript-prefix', p('typescript_prefix'), '--mode', m, '--out', o / ('companion-widget-' + m)), needs=('tools',), timeout=180, tests=[rt + 'companion-widget.test.mjs', rt + 'entry-ability-fixture.test.mjs'], scope='Actual companion widget ETS/Form data with independent OS processes and real Linux flock/atomic files; explicit FormKit boundary, no page/profile/device proof')
    channels = ['app-links-channel', 'frame-rate-channel', 'keyboard-log', 'connectivity-channel', 'notify-channel', 'paste-channel', 'voice-stop-control', 'liveview-fallback', 'files-media-channel', 'usage-channel', 'launch-channel', 'launcher-icon-channel', 'shortcuts-channel', 'entry-ability-fixture']
    g.node_tests('ets-channels', [rt + n + '.test.mjs' for n in channels], needs=('native-opener-build',), extra=lambda: {'OHOS_USER_FILE_ADDON': str(o / 'user-file-access.node')}, timeout=240)
    def embedding_package(_):
        target = o / 'embedding-package'; target.mkdir()
        with tarfile.open(p('embedding_har')) as har:
            har.extractall(target, filter='data')
        return {'scope': 'The fixed embedding unpacked for the launch clip fixture; not a build'}
    g.internal('embedding-package', embedding_package, needs=('tools',))
    g.node_tests('launch-clip', [rt + 'launch-clip.test.mjs'], needs=('embedding-package',), extra=lambda: {'OHOS_FLUTTER_EMBEDDING': str(o / 'embedding-package/package')})
    # Playback/registration only. Paid synthesis admission still requires the
    # upstream Dart preflight/streaming integration before UI enablement.
    for mode in ['plain', 'jitless']:
        g.run('speech-channel-' + mode, lambda m=mode: g.py(rt + 'speech-channel-linux.py', '--node', node(), '--typescript-prefix', p('typescript_prefix'), '--mode', m, '--out', o / ('speech-channel-' + m)), needs=('tools',), timeout=180, tests=[rt + 'speech-channel.test.mjs', rt + 'speech-channel-pcm.test.mjs', rt + 'entry-ability-fixture.test.mjs'])
    for mode in ['plain', 'jitless']:
        g.run('call-capture-' + mode, lambda m=mode: g.py(rt + 'call-capture-linux.py', '--node', node(), '--typescript-prefix', p('typescript_prefix'), '--mode', m, '--out', o / ('call-capture-' + m)), needs=('tools',), timeout=180,
              tests=[rt + name for name in ['call-capture.test.mjs', 'call-control.test.mjs', 'voice-pcm-tap.test.mjs', 'speech-call-channel.test.mjs', 'voice-channel.test.mjs', 'call-route.test.mjs', 'call-start-mute.test.mjs', 'call-start-pause.test.mjs']],
              scope='Actual ETS energy fallback, capture/control including startup mute and pause, system-TTS app route, PCM tap and dictation regression; explicit OS boundaries; no SDK or device claim')
        g.run('system-tts-' + mode, lambda m=mode: g.py(rt + 'system-tts-linux.py', '--node', node(), '--typescript-prefix', p('typescript_prefix'), '--mode', m, '--out', o / ('system-tts-' + m)), needs=('tools',), timeout=180, tests=[rt + 'system-tts.test.mjs', rt + 'system-tts-init-retry.test.mjs'], scope='Actual EntryAbility and system TTS/PCM channel bodies; explicit HMS/Flutter/AudioRenderer boundaries; not SDK or device validation')
    tooling = ['managed-skill', 'native-host-lazy', 'runtime-archive', 'runtime-channel', 'linux-control', 'lifecycle-host', 'web-files', 'transient-task', 'runtime-recovery', 'recovery-storage', 'native-recovery-gate', 'last-known-good']
    g.node_tests('ets-runtime-tooling', [tools + n + '.test.mjs' for n in tooling], needs=('native-zlib-build', 'prepared-inputs'), extra=lambda: {'OHOS_TEST_ZLIB_ADDON': str(o / 'zlib.node'), 'OHOS_INSTALL_RECORD_WIRE': str(o / 'install-record-wire.json')}, timeout=240)
    g.run('runtime-background-idle', lambda: g.node('--test', '--test-name-pattern=1200 background polling',
        g.source / (tools + 'runtime-channel.test.mjs')), needs=('native-zlib-build',),
        env=lambda: {'OHOS_TEST_ZLIB_ADDON': str(o / 'zlib.node')}, tests=[tools + 'runtime-channel.test.mjs'],
        scope='Actual RuntimeController bodies; count background/foreground polling and one-second lifecycle refresh with the host clock fixture')
    for mode in ['plain', 'jitless']:
        g.node_tests('runtime-archive-copy-' + mode, [tools + 'runtime-archive-copy.test.mjs'], mode=mode, needs=('native-zlib-build',), extra=lambda: {'OHOS_TEST_ZLIB_ADDON': str(o / 'zlib.node')})
    g.internal('install-record-wire', lambda _: verify_install_record_wire(o / 'install-record-wire.json'), needs=('ets-runtime-tooling',))
    for mode in ['plain', 'jitless']:
        g.node_tests('secrets-picker-' + mode, [rt + 'secrets.test.mjs', tools + 'attachment-files-channel.test.mjs'], mode=mode, needs=('tools',))
    for filename in ['runtime-archive-audit.test.py', 'audit-dart-bridges.test.py', 'patch-framework.test.py']:
        g.run(filename[:-3], lambda f=filename: g.py(tools + f), needs=('tools',), tests=[tools + filename])
    g.run('hap-distribution', lambda: g.py(tools + 'hap-distribution.test.py'), needs=('tools',), tests=[tools + 'hap-distribution.test.py'])
    g.run('native-contract', lambda: g.py(tools + 'native-contract.test.py'), needs=('tools',), tests=[tools + 'native-contract.test.py'])
    g.run('hap-native-assets', lambda: g.py(tools + 'hap-native-assets.test.py'), env=lambda: {'OHOS_SDK': str(p('sdk'))}, needs=('tools',), tests=[tools + 'hap-native-assets.test.py'])
    g.run('fork-installed-resolution', lambda: g.py(tools + 'prepare-forks-installed.test.py'), needs=('tools',), tests=[tools + 'prepare-forks-installed.test.py'])
    g.run('archive-manifest', lambda: g.py(tools + 'runtime-archive-manifest-contract.py', '--node', node(), '--report', o / 'archive-manifest.json'), needs=('tools',))
    g.node_tests('scan-channel', [tools + 'scan-channel.test.mjs'], needs=('tools',))
    g.run('hms-declarations', lambda: g.py(tools + 'prepare-hms-sdk.test.py', '--helper', s / 'tooling/ohos/hms-stubs/prepare-sdk.py', '--output', o / 'hms-declarations'), needs=('tools',), tests=[tools + 'prepare-hms-sdk.test.py'])
    g.run('embedding-member-identity', lambda: g.py(tools + 'prepare-pasteboard.test.py'), env=lambda: {'DSH_EMBEDDING_HAR': str(p('embedding_har'))}, needs=('tools',), tests=[tools + 'prepare-pasteboard.test.py'])
    g.run('clipboard-settlement', lambda: g.py(tools + 'clipboard-settlement.py', '--input-har', p('embedding_har'), '--node', node(), '--typescript-prefix', p('typescript_prefix'), '--output', o / 'clipboard-settlement'), needs=('tools',))
    g.run('fork-contract', lambda: g.py(tools + 'prepare-forks-contract.py'), env=lambda: {'DSH_WEBVIEW_FORK': str(p('webview_original'))}, needs=('tools',), tests=[tools + 'prepare-forks-contract.py'])
    g.run('fork-prepare', lambda: g.py('tooling/ohos/prepare-forks.py', '--input', p('webview_original'), '--package', 'webview_flutter_ohos', '--output', o / 'webview-prepared'), needs=('tools',))
    g.node_tests('webview-security', [tools + 'webview-security-contract.mjs'], needs=('fork-prepare',), extra=lambda: {'DSH_WEBVIEW_FORK': str(o / 'webview-prepared/package')})
    g.node_tests('islands-channel', [tools + 'islands-channel.test.mjs'], needs=('fork-prepare',), extra=lambda: {'DSH_WEBVIEW_FORK': str(o / 'webview-prepared/package')})
    # Real Dart/Flutter application sources in this private tree, with an explicitly
    # supplied, fixed offline dependency resolver and real font/asset prerequisites.
    def app_inputs(_):
        app = g.flutter_source / 'app'
        # All resolver and asset generation stays in the independent Flutter
        # copy; the candidate/native Android comparison tree remains untouched.
        shutil.copy2(app / 'pubspec.lock', o / 'pubspec.original.lock')
        overrides = 'dependency_overrides:\n'
        for package, key in [('flutter_secure_storage', 'secure_fork'), ('file_picker', 'picker_fork')]:
            if key not in g.paths: continue
            overrides += '  ' + package + ':\n    path: ' + json.dumps(str(p(key))) + '\n'
        (app / 'pubspec_overrides.yaml').write_text(overrides)
        for f in p('app_fonts').iterdir():
            if f.is_file():
                target = app / 'assets/fonts' / f.name; target.parent.mkdir(parents=True, exist_ok=True)
                if not target.exists(): shutil.copy2(f, target)
        return {'overridesSha256': sha(app / 'pubspec_overrides.yaml'), 'fonts': {f.name: sha(f) for f in p('app_fonts').iterdir() if f.is_file()}}
    g.internal('flutter-inputs', app_inputs, needs=('tools', 'flutter-tools'))
    g.run('flutter-pub', lambda: g.flutter('pub', 'get', '--offline'), cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-inputs',), timeout=180)
    def flutter_vendor(directory):
        sdk = p('flutter').resolve().parent.parent
        source = (sdk / 'packages/flutter/lib/src/foundation/platform.dart').read_text()
        enum = re.search(r'enum TargetPlatform\s*\{(.*?)\}', source, re.S)
        if enum is None: raise ValueError('Cannot determine actual Flutter TargetPlatform enum')
        ohos = re.search(r'\bohos\s*[,}]', enum.group(1) + '}') is not None
        if not ohos:
            return {'extraOhosTarget': False, 'scope': 'Standard Linux Flutter; dependency switches unchanged'}
        argv = [sys.executable, '-I', '-B', g.flutter_source / 'tooling/ohos/vendor_platform_switches.py']
        result = subprocess.run(list(map(str, argv)), cwd=g.flutter_source, env={**g.base_env, **g.flutter_env}, capture_output=True, text=True)
        (directory / 'stdout.log').write_text(result.stdout)
        (directory / 'stderr.log').write_text(result.stderr)
        save(directory / 'command.json', {'argv': list(map(str, argv)), 'exitCode': result.returncode})
        result.check_returncode()
        return {'extraOhosTarget': True, 'scope': 'Existing vendor switch generator for actual oh-flutter SDK'}
    g.internal('flutter-vendor', flutter_vendor, needs=('flutter-pub',))
    g.run('flutter-pub-vendored', lambda: g.flutter('pub', 'get', '--offline'), cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-vendor',), timeout=180)
    g.run('flutter-l10n', lambda: [sys.executable, '-I', '-B', g.flutter_source / 'app/tool/l10n_merge.py'],
          cwd=g.flutter_source / 'app', env=lambda: {**g.flutter_env, 'FLUTTER': str(p('flutter'))},
          needs=('flutter-pub-vendored',), timeout=180)
    def flutter_identity(_):
        g.flutter_env['OHOS_INSTALL_RECORD_WIRE'] = str(o / 'install-record-wire.json')
        return {'source': verify_flutter_inputs(g.flutter_source, g.flutter_original_inputs),
                'localPackages': verify_flutter_packages(g.flutter_source)}
    g.internal('flutter-input-identity', flutter_identity, needs=('flutter-l10n', 'install-record-wire'))
    g.run('flutter-phone-folders', lambda: g.flutter('test', '--no-pub', '--reporter', 'json', '--concurrency=1', '../runtime/tests/ohos/phone-folders-data_test.dart'),
          cwd=g.flutter_source / 'app', env={**g.flutter_env, 'OHOS_PHONE_FOLDERS_WIRE': str(o / 'phone-folders-plain/wire.json')},
          needs=('flutter-input-identity', 'phone-folders-plain'), timeout=180,
          tests=[rt + 'phone-folders-data_test.dart'], scope='Actual Linux Flutter MethodChannel/decoder using actual ETS grant lifecycle wire; logical coordinates do not grant authority; no device claim')
    g.run('flutter-phone-folders-analyze', lambda: g.flutter('analyze', '--no-pub', 'lib/runtime/authorized_workspaces.dart'),
          cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-input-identity',), timeout=180,
          tests=['app/lib/runtime/authorized_workspaces.dart'], scope='Actual Flutter analyzer for the changed data-layer file; no UI or SDK claim')
    g.run('speech-upper-host', lambda: g.py(rt + 'speech-upper.py', '--source', s, '--dart', p('dart'),
          '--node', node(), '--typescript-prefix', p('typescript_prefix'),
          '--deps-config', g.flutter_source / 'app/.dart_tool/package_config.json',
          '--bridge-source', s / 'runtime/bridge/dsh-go-bridge/lib/speech.js', '--out', o / 'speech-upper-host'),
          needs=('tools', 'dart-tools', 'flutter-input-identity', 'speech-channel-jitless', 'system-tts-jitless', 'pcm-stream-native'),
          timeout=240, tests=[rt + 'speech-upper.py'] + [rt + 'speech-upper/' + name for name in
          ['host-speech-tests.dart', 'host-lifecycle-tests.dart', 'host-http-tests.dart', 'host-preview-tests.dart',
           'host-compat-tests.dart', 'host-route-tests.dart', 'host-system-tests.dart', 'host-native-integration.dart']],
          scope='Actual Dart upper/HTTP + fixed main speech.js + frozen 1216 ETS; explicit framework, local provider and AudioRenderer OS boundaries; no Flutter engine, SDK, device, UI enablement or paid API claim')
    g.run('companion-tts-preview-dart', lambda: g.flutter('test', '--no-pub', '--reporter', 'json', '--concurrency=1',
          '../runtime/tests/ohos/companion-external-data_test.dart',
          '../runtime/tests/ohos/system-tts-preview-data_test.dart', 'test/companion/companion_voice_test.dart',
          'test/companion/companion_voice_source_test.dart', 'test/speech/speech_out_test.dart',
          'test/speech/voice_call_test.dart', 'test/settings/voice_settings_test.dart'),
          cwd=g.flutter_source / 'app', env=lambda: {**g.flutter_env, 'NODE': str(node()),
          'OHOS_TYPESCRIPT_PREFIX': str(p('typescript_prefix')), 'OHOS_TTS_SOURCE_ROOT': str(g.flutter_source)},
          needs=('tools', 'flutter-input-identity',), timeout=300,
          tests=[rt + 'companion-external-data_test.dart', rt + 'companion-external-rpc.mjs',
                 rt + 'system-tts-preview-data_test.dart', rt + 'system-tts-preview-rpc.mjs',
                 'app/test/companion/companion_voice_test.dart', 'app/test/companion/companion_voice_source_test.dart',
                 'app/test/speech/speech_out_test.dart', 'app/test/speech/voice_call_test.dart',
                 'app/test/settings/voice_settings_test.dart'],
          scope='Actual Flutter ordinary OH companion external preflight, preserved per-id system fallback and preview cancellation; finite loopback/RPC to actual ETS with explicit HMS/audio boundaries; Android/default data controls; no SDK/device or paid API claim')
    # Only the app's own files: from app/ the analyzer can't resolve package:dsh_app in
    # runtime/tests; `flutter test` above compiles those tests against the app.
    g.run('companion-tts-preview-dart-analyze', lambda: g.flutter('analyze', '--no-pub', 'lib/companion/companion_voice.dart'),
          cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-input-identity',), timeout=180,
          tests=['app/lib/companion/companion_voice.dart', rt + 'companion-external-data_test.dart', rt + 'system-tts-preview-data_test.dart'],
          scope='Actual Flutter analyzer for OH companion preflight/cancellation data and finite consumer tests; no UI or Native edits')
    g.run('call-route-dart', lambda: g.flutter('test', '--no-pub', '--reporter', 'json', '--concurrency=1',
          '../runtime/tests/ohos/audio-route-data_test.dart', '../runtime/tests/ohos/call-start-mute-data_test.dart',
          '../runtime/tests/ohos/call-start-mute-integration_test.dart', '../runtime/tests/ohos/call-start-pause-integration_test.dart',
          'test/speech/voice_call_test.dart', 'test/speech/speech_out_test.dart'),
          cwd=g.flutter_source / 'app', env=lambda: {**g.flutter_env, 'NODE': str(node()), 'OHOS_TYPESCRIPT_PREFIX': str(p('typescript_prefix'))},
          needs=('tools', 'flutter-input-identity',), timeout=180,
          tests=[rt + 'audio-route-data_test.dart', rt + 'call-start-mute-data_test.dart', rt + 'call-start-mute-integration_test.dart',
                 rt + 'call-start-mute-rpc.mjs', rt + 'call-start-pause-integration_test.dart', rt + 'call-start-pause-rpc.mjs',
                 'app/test/speech/voice_call_test.dart', 'app/test/speech/speech_out_test.dart'],
          scope='Actual Flutter OH call-route and preparing mute/pause consumers; preparation tests call actual ETS through finite local RPC with OS audio/permission boundaries; unchanged Android controls; no SDK/device claim')
    g.run('call-route-dart-analyze', lambda: g.flutter('analyze', '--no-pub', 'lib/speech/speech_audio.dart', 'lib/speech/call/voice_call.dart'),
          cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-input-identity',), timeout=180,
          tests=['app/lib/speech/speech_audio.dart', 'app/lib/speech/call/voice_call.dart'],
          scope='Actual Flutter analyzer for the two call-route data files; no UI or SDK claim')
    g.run('system-asr-dart', lambda: g.flutter('test', '--no-pub', '--reporter', 'json', '--concurrency=1',
          '../runtime/tests/ohos/system-asr-data_test.dart', 'test/voice/streaming_asr_test.dart', 'test/voice/streaming_pcm_test.dart',
          'test/speech/voice_call_test.dart', 'test/speech/turn_words_test.dart', 'test/voice/native_trial_test.dart'),
          cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-input-identity',), timeout=300,
          tests=[rt + 'system-asr-data_test.dart', 'app/test/voice/streaming_asr_test.dart', 'app/test/voice/streaming_pcm_test.dart',
                 'app/test/speech/voice_call_test.dart', 'app/test/speech/turn_words_test.dart', 'app/test/voice/native_trial_test.dart'],
          scope='Actual Linux Flutter/Dart system-caption data consumers and unchanged sherpa isolate regression; explicit native channel boundary; not OHOS SDK/device')
    g.run('system-asr-dart-analyze', lambda: g.flutter('analyze', '--no-pub', 'lib/voice/ohos_streaming_asr.dart', 'lib/voice/streaming_asr_model.dart',
          'lib/voice/streaming_pcm.dart', 'lib/voice/live_words.dart', 'lib/state/streaming_asr_state.dart'),
          cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-input-identity',), timeout=300,
          scope='Real Flutter analysis of changed system-caption data/protocol files; no UI enablement')
    g.run('flutter-media-video-poster-data', lambda: g.flutter('test', '--no-pub', '--reporter', 'json', '--concurrency=1',
          '../runtime/tests/ohos/media-video-poster-data_test.dart', 'test/media/media_video_test.dart',
          'test/media/media_card_test.dart', 'test/chat/artifact_card_test.dart'),
          cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-input-identity',), timeout=300,
          tests=[rt + 'media-video-poster-data_test.dart', 'app/test/media/media_video_test.dart',
                 'app/test/media/media_card_test.dart', 'app/test/chat/artifact_card_test.dart'],
          scope='Actual Flutter OH poster-cache producer, finite local Session HTTP/file I/O and real codec; controlled poster encoder markers, unchanged Android/default and existing media consumers; no SDK/device decoding claim')
    g.run('flutter-media-video-poster-analyze', lambda: g.flutter('analyze', '--no-pub', 'lib/media/video.dart'),
          cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-input-identity',), timeout=180,
          tests=['app/lib/media/video.dart', rt + 'media-video-poster-data_test.dart'],
          scope='Actual Flutter analyzer for the OH poster cache data file and its finite consumer tests; no UI or Native edits')
    flutter_tests = ['test/secrets', 'test/ohos/attachment_files_test.dart', 'test/runtime/phone_callback_bridge_test.dart', 'test/runtime/runtime_recovery_test.dart', 'test/runtime/ohos_install_record_test.dart', 'test/usage/ohos_device_contract_test.dart',
                     'test/safe_mode/safe_mode_logic_test.dart', 'test/state/engine_control_test.dart', 'test/runtime/runtime_controller_test.dart',
                     'test/plugins/ohos_replace_cancel_test.dart', 'test/remote/pairing_system_scanner_test.dart',
                     'test/chat/artifact_ohos_workspace_materialize_test.dart',
                     'test/runtime/ohos_idle_diagnostics_test.dart',
                     'test/chat/attachment_file_budget_test.dart', 'test/remote/private_key_file_budget_test.dart',
                     'test/chat/attachment_owner_test.dart', 'test/remote/ssh_key_callback_lifetime_test.dart', 'test/share_hosted', 'test/share/share_panel_test.dart']
    g.run('flutter-keyboard-geometry', lambda: g.flutter('test', '--no-pub', '--reporter', 'json', '--concurrency=1', '../runtime/tests/ohos/keyboard-geometry-data_test.dart',
          'test/diagnostics/system_ime_diagnostics_test.dart', 'test/diagnostics/diagnostics_refresh_test.dart', 'test/diagnostics/diagnostics_sections_test.dart'),
          cwd=g.flutter_source / 'app', env=lambda: {**g.flutter_env, 'OHOS_KEYBOARD_CONSUMER_INPUT': str(o / 'keyboard-geometry/codec-input.json')},
          needs=('flutter-input-identity', 'keyboard-geometry'), timeout=300,
          tests=[rt + 'keyboard-geometry-data_test.dart', 'app/test/diagnostics/system_ime_diagnostics_test.dart', 'app/test/diagnostics/diagnostics_refresh_test.dart', 'app/test/diagnostics/diagnostics_sections_test.dart'],
          scope='Actual Flutter parser/channel/export/coordinator consumes own-window geometry and unchanged Android regressions; no device or UI enablement')
    g.run('flutter-keyboard-geometry-analyze', lambda: g.flutter('analyze', '--no-pub', 'lib/diagnostics/system_ime_evidence.dart', 'lib/diagnostics/diagnostics_channel.dart', 'lib/diagnostics/diagnostics_markdown.dart'),
          cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-input-identity',), timeout=300)
    g.run('flutter-consumers', lambda: g.flutter('test', '--no-pub', '--reporter', 'json', '--concurrency=1', *flutter_tests), cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-input-identity',), timeout=300, tests=['app/' + x for x in flutter_tests], scope='Actual Linux Flutter engine and Dart consumers; not OHOS AOT/device')
    g.run('diagnostic-cancel-wire', lambda: g.node(s / (rt + 'automatic-diagnostics-cancel-wire.mjs')),
          env=lambda: {**g.common(), 'OHOS_TEST_ZLIB_ADDON': str(o / 'zlib.node'),
                       'OHOS_DIAGNOSTIC_SOURCE_ROOT': str(s), 'OHOS_CANCEL_OWNER_WIRE': str(o / 'diagnostic-cancel-wire.json')},
          needs=('tools', 'native-zlib-build'), timeout=60, tests=[rt + 'automatic-diagnostics-cancel-wire.mjs'],
          scope='Two increasing-time snapshots from actual OH diagnostic ETS and Linux persistence; explicit HiAppEvent boundary, no phone fault claim')
    g.run('flutter-diagnostic-cancel-state', lambda: g.flutter('test', '--no-pub', '--reporter', 'json', '--concurrency=1',
          '../runtime/tests/ohos/automatic-diagnostics-cancel-state_test.dart'),
          cwd=g.flutter_source / 'app', env=lambda: {**g.flutter_env, 'OHOS_CANCEL_OWNER_WIRE': str(o / 'diagnostic-cancel-wire.json')},
          needs=('flutter-input-identity', 'diagnostic-cancel-wire'), timeout=300,
          tests=[rt + 'automatic-diagnostics-cancel-state_test.dart'],
          scope='Actual OH provider/sender and DshClient loopback HTTP cancellation ownership; same-epoch new check and Android/default compatibility, zero model requests')
    g.run('flutter-diagnostic-cancel-state-analyze', lambda: g.flutter('analyze', '--no-pub', 'lib/diagnostics/automatic_diagnostics.dart'),
          cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-input-identity',), timeout=180,
          tests=['app/lib/diagnostics/automatic_diagnostics.dart', rt + 'automatic-diagnostics-cancel-state_test.dart'],
          scope='Real Flutter analyzer for the OH cancellation state guard and actual-provider finite tests')
    g.run('flutter-diagnostic-evidence', lambda: g.flutter('test', '--no-pub', '--reporter', 'json', '--concurrency=1', '../runtime/tests/ohos/diagnostic-evidence-data_test.dart',
          'test/diagnostics/automatic_diagnostics_test.dart', 'test/diagnostics/diagnostics_sections_test.dart',
          'test/diagnostics/automatic_diagnostics_provider_test.dart', 'test/diagnostics/voice_diagnostics_test.dart'),
          cwd=g.flutter_source / 'app', env=lambda: {**g.flutter_env, 'OHOS_DIAGNOSTIC_EVIDENCE_WIRE': str(o / 'diagnostic-evidence/wire.json')},
          needs=('flutter-input-identity', 'diagnostic-evidence'), timeout=300,
          tests=[rt + 'diagnostic-evidence-data_test.dart'] + ['app/test/diagnostics/' + name for name in
          ['automatic_diagnostics_test.dart', 'diagnostics_sections_test.dart', 'automatic_diagnostics_provider_test.dart', 'voice_diagnostics_test.dart']],
          scope='Actual Flutter MethodChannel, OH fault facts, automatic-analysis checkpoint and existing Android diagnostics contracts; real ETS wire; no phone fault delivery or model request')
    g.run('flutter-diagnostic-evidence-analyze', lambda: g.flutter('analyze', '--no-pub', 'lib/diagnostics/diagnostics_channel.dart',
          'lib/diagnostics/automatic_diagnostics.dart', 'lib/diagnostics/diagnostics_sections.dart'),
          cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-input-identity',), timeout=180,
          scope='Real Flutter analyzer for the three changed diagnostic data/protocol files')
    g.run('flutter-picture-shortcut-data', lambda: g.flutter('test', '--no-pub', '--reporter', 'json', '../runtime/tests/ohos/picture_shortcut_data_test.dart'), cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-input-identity',), timeout=120, tests=[rt + 'picture_shortcut_data_test.dart'], scope='Actual unchanged Dart picture-shortcut consumer and channel serialization; explicit native boundary, no UI enablement or phone result')
    g.run('flutter-companion-widget-data', lambda: g.flutter('test', '--no-pub', '--reporter', 'json', '../runtime/tests/ohos/companion_widget_data_test.dart'), cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-input-identity',), timeout=120, tests=[rt + 'companion_widget_data_test.dart'], scope='Actual unchanged companion widget Dart consumer and channel serialization; no desktop UI/registration proof')
    g.run('flutter-clipboard-consumer', lambda: g.flutter('test', '--no-pub', '--reporter', 'json', 'test/runtime/ohos_clipboard_consumer_test.dart'), cwd=g.flutter_source / 'app',
          env={**g.flutter_env, 'OHOS_CLIPBOARD_WIRE': str(o / 'clipboard-settlement/after-observations.json')}, needs=('flutter-input-identity', 'clipboard-settlement'), timeout=120,
          tests=['app/test/runtime/ohos_clipboard_consumer_test.dart'], scope='Actual HAR replies consumed by Flutter Clipboard, ApiKeyPage and EditableText; not device clipboard permission')
    g.run('flutter-paste-consumers', lambda: g.flutter('test', '--no-pub', '--reporter', 'json', '--concurrency=1', 'test/clipboard', 'test/forum/paste_authorized_test.dart'), cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-input-identity',), timeout=300, tests=['app/test/clipboard/paste_reader_test.dart', 'app/test/forum/paste_authorized_test.dart'], scope='Actual Dart OH paste consumer and cancellation; native security authorization is a platform boundary')
    g.run('flutter-consumer-analyze', lambda: g.flutter('analyze', '--no-pub', 'lib/secrets', 'lib/state/attachment_files_ohos.dart', 'lib/share_hosted/hosted_links_state.dart', 'lib/ui/share_hosted', 'lib/ui/share/share_panel.dart', 'test/secrets', 'test/ohos/attachment_files_test.dart', 'test/share_hosted', 'test/share/share_panel_test.dart'), cwd=g.flutter_source / 'app', env=g.flutter_env, needs=('flutter-input-identity',), timeout=300)
    g.run('flutter-plugin-install-recovery', lambda: g.flutter('test', '--no-pub', '--reporter', 'json', 'test/plugins/ohos_install_recovery_test.dart'), cwd=g.flutter_source / 'app',
          env=g.flutter_env, needs=('flutter-input-identity',), timeout=300, tests=['app/test/plugins/ohos_install_recovery_test.dart'],
          scope='Actual Dart OH local install result recovery and unchanged Android/remote contracts; not device')
    def retain_resolver(_):
        app = g.flutter_source / 'app'
        names = ['pubspec.lock', 'pubspec_overrides.yaml', '.dart_tool/package_config.json']
        captured = {}
        for name in names:
            src = app / name
            if src.is_file():
                dest = o / 'flutter-resolver' / name
                dest.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(src, dest)
                captured[name] = sha(dest)
        return {'resolvedInputs': captured, 'originalLockSha256': sha(o / 'pubspec.original.lock'),
                'source': verify_flutter_inputs(g.flutter_source, g.flutter_original_inputs),
                'localPackages': verify_flutter_packages(g.flutter_source),
                'androidAfterFlutter': source_files(app / 'android'),
                'androidBeforeFlutter': {path[len('app/android/'):]: value for path, value in g.original.items() if path.startswith('app/android/')}}
    g.internal('flutter-resolver-record', retain_resolver, needs=('flutter-input-identity',))
    g.run('dart-bridge-inventory', lambda: g.py('tooling/ohos/audit-dart-bridges.py', '--source', s, '--fork-roots', p('fork_roots'), '--report', o / 'dart-bridge-inventory.json', '--require-group1'), needs=('tools',))
    for target in ['candidate', 'ohos']:
        g.run('native-protocol-' + ('android' if target == 'candidate' else 'ohos'), lambda t=target: ['bash', s / 'runtime/tests/run-native-tests.sh', o / ('targets/' + t + '-prefix'), '--port', free_port()], needs=('android-targets', 'native-static-resources'), timeout=300, tests=['runtime/tests/native-bridge.mjs', 'runtime/tests/native-capabilities-live.mjs'], scope='Original full native protocol suite against the selected installed target on Linux')
    # The shared suites, whole, on each selected tree. The groups around here pick
    # the files they need and would miss the rest of runtime/tests.
    shared = sorted('runtime/tests/' + f.name for f in (s / 'runtime/tests').glob('*.test.mjs'))
    for target, label in (('candidate', 'android'), ('ohos', 'ohos')):
        g.run('shared-suite-' + label, lambda: g.node('--test', '--test-reporter=tap', *[s / f for f in shared]), env=lambda t=target: {'PNPM_BIN': str(p('pnpm_prefix') / 'node_modules/pnpm/bin/pnpm.mjs'), 'TZ': 'Asia/Shanghai', 'DSH_JOB_RING_BENCH': '1', 'OHOS_TYPESCRIPT_PREFIX': str(p('typescript_prefix')), 'DSH_PREFIX': str(o / ('targets/' + t + '-prefix')), 'DSH_TEST_PREFIX': str(o / ('targets/' + t + '-prefix'))}, needs=('android-targets', 'native-static-resources', 'pnpm-inputs'), timeout=600, tests=shared, scope='Every shared runtime test against the installed target on Linux')
        g.run('route-guard-' + label, lambda t=target: ['bash', s / 'runtime/tests/run-guard-tests.sh', o / ('targets/' + t + '-prefix'), '--port', free_port()], needs=('android-targets',), timeout=300, tests=['runtime/tests/run-guard-tests.sh'])
    g.run('direct-inventory', lambda: g.py('runtime/tests/test_direct_inventory.py', '-v'), needs=('tools',), tests=['runtime/tests/test_direct_inventory.py'])
    g.run('publication-kill', lambda: g.node(s / (rt + 'publication-kill.mjs'), '--node', node(), '--simulation', s / 'runtime/ohos/sim/preload.mjs', '--publication', s / 'runtime/ohos/publication', '--linked-lib', native() / 'libpublication-test-linked.so', '--prefix', prefix(), '--out', o / 'publication-kill.json'), needs=('native-publication-build', 'prepared-inputs'), timeout=300, scope='Real SIGKILL and restart with the current publication preload')
    g.run('manifest-validate', lambda: g.node(s / 'runtime/ohos/package/validate-manifest.mjs', s / 'app/ohos/entry/src/main/ets/runtime/RuntimeCore.ets', o / 'composed/expanded/dsh-runtime/manifest.json'), needs=('compose',))
    g.run('node-build-contract', lambda: g.py(rt + 'node-build.py', '--source', p('node_source')), needs=('tools',), timeout=240)
    g.run('node-embedded-bundle', lambda: g.py(rt + 'node-embedded-bundle.test.py'), needs=('tools',), tests=[rt + 'node-embedded-bundle.test.py'])
    g.run('napi-rename-current', lambda: g.py('runtime/ohos/node/gen-napi-rename.py', '--source', p('node_source'), '--check'), needs=('tools',), timeout=120)
    def market_inputs(_):
        (s / 'market/node_modules').symlink_to(p('market_modules'), target_is_directory=True)
        return {'source': str(p('market_modules'))}
    g.internal('market-inputs', market_inputs, needs=('tools',))
    g.run('market-tests', lambda: g.node('--test', '--test-isolation=none', '--test-reporter=tap'), cwd=lambda: s / 'market', needs=('market-inputs',), timeout=300)
    g.run('market-check', lambda: g.node('scripts/check.mjs'), cwd=lambda: s / 'market', needs=('market-inputs',), timeout=120)
    g.node_tests('file-upload-resolver', ['runtime/tests/file-upload-resolver.test.mjs'], needs=('android-targets',), extra=lambda: {'DSH_TEST_PREFIX': str(o / 'targets/ohos-prefix')}, timeout=240)
    g.node_tests('schedule-contract', ['runtime/tests/schedule-authorization.test.mjs'], needs=('android-targets',), extra=lambda: {'DSH_PREFIX': str(o / 'targets/ohos-prefix')}, timeout=240)
    def fetch_source(_):
        original = p('node_source'); target = o / 'node-fetch-source'
        for relative in ('src/node_version.h', 'deps/undici'):
            src = original / relative; dst = target / relative; dst.parent.mkdir(parents=True, exist_ok=True)
            if src.is_dir(): shutil.copytree(src, dst, symlinks=True)
            elif src.is_file(): shutil.copy2(src, dst)
            else: raise Blocked('missing exact Node source ' + str(src))
        return {'source': str(original), 'selectedBefore': source_files(target)}
    g.internal('node-fetch-source', fetch_source, needs=('tools',))
    g.node_tests('node-fetch-build', [rt + 'node-fetch-build.test.mjs'], needs=('node-fetch-source',), extra=lambda: {'OHOS_NODE_SOURCE': str(p('node_source')), 'OHOS_NODE_BUILD_TOOLS': str(p('esbuild_prefix'))}, timeout=240)
    g.run('node-fetch-prepare', lambda: g.node(s / 'tooling/ohos/prepare-node-fetch.mjs', '--target', 'ohos', '--build-tools', p('esbuild_prefix'), o / 'node-fetch-source'), needs=('node-fetch-source',), timeout=180)
    for mode in ('plain', 'jitless'):
        g.node_tests('node-fetch-' + mode, [rt + 'node-fetch-abort.test.mjs', rt + 'node-formdata.test.mjs'], mode=mode, needs=('node-fetch-prepare',), extra=lambda: {'DSH_GO_UNDICI_BUNDLE': str(o / 'node-fetch-source/deps/undici/undici.js'), 'DSH_GO_UNDICI_SOURCE': str(o / 'node-fetch-source/deps/undici/src'), 'DSH_GO_HTTP_DISPATCHER': str(s / 'runtime/ohos/net/dispatcher.mjs')}, timeout=180)
    for mode in ('full', 'optional-profile'):
        g.run('mcp-linux-r7-' + mode, lambda m=mode: g.py('runtime/tests/plugin-config-r7-live.py', '--prefix', o / 'targets/ohos-prefix', '--bridge', s / 'runtime/bridge/dsh-go-bridge', '--media', s / 'runtime/media/dsh-media', '--image-size', p('image_size'), '--out', o / ('mcp-linux-r7-' + m), '--port', free_port(), '--mode', m), needs=('android-targets',), timeout=240, tests=['runtime/tests/plugin-config-r7-live.py'], scope='Original Linux r7 full/optional profile contracts on current OH-selected full-optional prefix; no OH platform spoof')
    # The SDK checker keeps its own authoritative input/build identity. It uses a
    # distinct work directory and does not perform --full, --clean or --with-forks.
    def sdk_inputs(_):
        project = o / 'sdk-project'; shutil.copytree(s / 'app/ohos', project, symlinks=True)
        # The source snapshot omits these five referenced compile resources.
        # They are a compile fixture, not claimed to be original product assets.
        icons = {}
        for root in ('AppScope', 'entry/src/main'):
            for name in (('background.png', 'foreground.png') if root == 'AppScope' else ('icon.png', 'background.png', 'foreground.png')):
                rel = root + '/resources/base/media/' + name
                src = p('sdk_resources') / rel
                if not src.is_file(): raise Blocked('missing compile resource fixture ' + rel)
                dest = project / rel; dest.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(src, dest)
                icons[rel] = sha(src)
        work = o / 'sdk-work'; work.mkdir()
        cache = p('sdk_cache')
        for name in ('dl', 'tools'):
            src = cache / name
            if not src.is_dir(): raise Blocked('missing pinned SDK tool cache ' + str(src))
            shutil.copytree(src, work / name, symlinks=True)
        return {'scope': 'Independent compile resource fixture; not product icon changes', 'resources': icons,
                'privateToolCache': str(work)}
    g.internal('sdk-inputs', sdk_inputs, needs=('tools',))
    g.run('arkts', lambda: ['bash', s / 'tooling/ohos/check-arkts.sh', '--sdk', p('sdk'), '--work', o / 'sdk-work', '--source', o / 'sdk-project', '--hms-stubs'], env=lambda: {'JAVA_HOME': str(p('java_home')), 'NODE': str(node()), 'TAR_OPTIONS': '--no-same-owner'}, needs=('sdk-inputs',), timeout=300, scope='Ordinary public SDK ArkTS compile with nonofficial HMS stubs: UNCOMPILED_HMS, no native/AOT/device')
    return g.finish()


if __name__ == '__main__':
    raise SystemExit(main())
