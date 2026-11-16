#!/usr/bin/env python3
"""Finite real-Dart speech gate, with named framework/OS/provider boundaries.

Requires the separately frozen 1216 native component and the already-integrated
main speech bridge. It never downloads, synthesizes paid audio or enables UI.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urljoin, urlparse


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def run(argv, label, out, env, timeout=60):
    command = [str(value) for value in argv]
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    result = subprocess.run(command, capture_output=True, text=True, env=env, timeout=timeout)
    (out / (label + '.stdout.log')).write_text(result.stdout)
    (out / (label + '.stderr.log')).write_text(result.stderr)
    row = {'argv': command, 'startedUTC': started, 'exitCode': result.returncode}
    save(out / (label + '.command.json'), row)
    if result.returncode:
        raise RuntimeError(label + ' exited ' + str(result.returncode))
    return result.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--dart', type=Path, required=True)
    ap.add_argument('--node', type=Path, required=True)
    ap.add_argument('--typescript-prefix', type=Path, required=True)
    ap.add_argument('--deps-config', type=Path, required=True)
    ap.add_argument('--bridge-source', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    source, out = args.source.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    fixture = source / 'runtime/tests/ohos/speech-upper'
    report = {'schema': 1, 'status': 'RUNNING', 'scope':
              'Actual Dart/HTTP and 1216 ETS methods; explicit Flutter/provider/AudioRenderer OS boundaries; no Flutter engine, SDK, device or paid API claim'}
    try:
        # Known source contexts, not a general reflection/compatibility layer.
        contexts = json.loads((fixture / 'source-contexts.json').read_text())
        context = next((name for name, files in contexts.items()
                        if all(sha(source / path) == expected for path, expected in files.items())), None)
        if context is None:
            raise ValueError('companion/diagnostics source context is not pinned')
        contract = json.loads((fixture / 'integration-inputs.json').read_text())
        for name, expected in contract['native'].items():
            if sha(source / name) != expected:
                raise ValueError('1216 native dependency differs: ' + name)
        if sha(args.bridge_source) != contract['bridge']['sha256']:
            raise ValueError('already-integrated main speech bridge identity differs')
        config_path = args.deps_config.resolve()
        config = json.loads(config_path.read_text())
        dependencies = json.loads((fixture / 'http-dependencies.json').read_text())['packages']
        resolver = {row['name']: row for row in config['packages']}
        package_files = {}
        source_lock = (source / 'app/pubspec.lock').read_text()
        for name, expected in dependencies.items():
            row = resolver[name]
            uri = urlparse(urljoin(config_path.as_uri(), row['rootUri']))
            if uri.scheme != 'file' or uri.netloc not in ('', 'localhost') or uri.query or uri.fragment:
                raise ValueError('nonlocal dependency resolver: ' + name)
            root = Path(unquote(uri.path)).resolve()
            version = re.search(r'^version:\s*["\']?([^"\'\s]+)', (root / 'pubspec.yaml').read_text(), re.M)
            if version is None or version.group(1) != expected['version']:
                raise ValueError('dependency version differs: ' + name)
            block = re.search(r'^  ' + re.escape(name) + r':\n(.*?)(?=^  \S|\Z)', source_lock, re.M | re.S)
            if block is None or expected['sha256'] not in block.group(1):
                raise ValueError('dependency archive hash differs from source lock: ' + name)
            for relative, digest in expected['libSources'].items():
                path = root / relative
                if sha(path) != digest:
                    raise ValueError('dependency source differs: ' + name + '/' + relative)
                package_files[str(path)] = digest
        # The test copy always starts from this invocation's candidate, not a
        # previous good host view or a machine package's dsh_client sources.
        tracked = [source / path for path in contract['native']]
        tracked += [source / 'runtime/tests/ohos/speech-upper.py', source / 'tooling/ohos/run-gates.py']
        tracked += [args.bridge_source.resolve(), source / 'app/pubspec.lock']
        tracked.append(source / 'app/lib/state/android_features.dart')
        for directory in ['app/lib/speech', 'packages/dsh_client/lib',
                          'app/lib/companion', 'app/lib/diagnostics', 'runtime/tests/ohos/speech-upper']:
            tracked += [path for path in (source / directory).rglob('*') if path.is_file()]
        before = {str(path): sha(path) for path in sorted(set(tracked))}
        save(out / 'source-before.json', before)
        save(out / 'dependency-sources.json', package_files)
        env = {**os.environ, 'DART_SUPPRESS_ANALYTICS': 'true', 'CI': 'true', 'PYTHONDONTWRITEBYTECODE': '1'}
        env.pop('NODE_OPTIONS', None)
        dart_version = run([args.dart, '--version'], 'dart-version', out, env)
        if not dart_version.startswith('Dart SDK version: 3.13.'):
            raise ValueError('this recorded gate uses Dart SDK 3.13.x')
        run([sys.executable, '-B', fixture / 'prepare-host.py', '--reference', source,
             '--out', out / 'host', '--deps-config', config_path, '--real-companion', '--real-diagnostics'],
            'prepare', out, env)
        run([args.dart, 'analyze', '--format', 'machine', out / 'host/app/lib/speech'],
            'dart-analyze-host', out, env)
        command = [args.dart, '--enable-asserts', '--packages=' + str(out / 'host/.dart_tool/package_config.json')]
        cases = []
        for name, extra in [
            ('host-speech-tests', []), ('host-lifecycle-tests', []), ('host-http-tests', []),
            ('host-preview-tests', []), ('host-compat-tests', [context]), ('host-route-tests', []),
            ('host-system-tests', []),
            ('host-native-integration', [args.node, fixture / 'native-rpc.mjs', source,
                                         args.typescript_prefix, out / 'native', args.bridge_source]),
        ]:
            text = run([*command, fixture / (name + '.dart'), *extra], name, out, env)
            rows = [json.loads(line) for line in text.splitlines() if line.startswith('{')]
            if not rows or rows[-1].get('failed') != 0:
                raise ValueError('missing successful finite case summary: ' + name)
            if any(row.get('pass') is False for row in rows):
                raise ValueError('failed individual case: ' + name)
            cases.append({'name': name, 'cases': rows[-1]['tests'], 'summary': rows[-1]})
        after = {path: sha(path) for path in before}
        if before != after or any(sha(path) != value for path, value in package_files.items()):
            raise ValueError('source changed during this gate')
        save(out / 'source-after.json', after)
        report.update(status='PASS', sourceContext=context, tests=sum(case['cases'] for case in cases),
                      groups=cases, nativeDependencies=contract['native'], bridge=contract['bridge'],
                      sourceFilesUnchanged=len(before), externalLibrarySourcesUnchanged=len(package_files),
                      dartSha256=sha(args.dart), nodeSha256=sha(args.node))
    except (FileNotFoundError, KeyError) as error:
        report.update(status='BLOCKED_NOT_RUN', error=str(error))
    except Exception as error:
        report.update(status='FAIL', error=str(error))
    save(out / 'REPORT.json', report)
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
