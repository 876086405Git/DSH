#!/usr/bin/env python3
"""Two ordinary byte windows; reuse an official payload and five existing native libraries."""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import stat
import subprocess
import time

HERE = Path(__file__).resolve().parent
CASES = ['physical-workspace-byte-window', 'selected-logical-workspace-byte-window']
TESTS = ['workspace-bytes-entry.py', 'workspace-bytes-entry.mjs', 'workspace-bytes-instrumentation.mjs']
NATIVE = ['libdsh_host.so', 'libdsh_workspace_grants.so', 'workspace-publisher.node',
          'libdsh_flock.so', 'libdsh_require_builtin.so']
PAYLOAD = [
    'runtime/ohos/preload.mjs',
    'runtime/ohos/process/files/authority.mjs',
    'runtime/ohos/process/files/process-authority.mjs',
    'runtime/ohos/process/files/grant-fs.mjs',
    'runtime/ohos/process/files/workspace-paths.mjs',
    'node_modules/@deepseek-ai/dsh/lib/bin.js',
    'node_modules/@deepseek-ai/dsh-base/cordis.patch.yml',
    'node_modules/@deepseek-ai/dsh-web-app/cordis.patch.yml',
    'node_modules/@dsh-go/ohos-native/package.json',
    'node_modules/@dsh-go/ohos-native/index.cjs',
] + ['node_modules/@deepseek-ai/' + name + '/lib/index.js' for name in [
    'cordis', 'dsh-session', 'dsh-system-prompt', 'dsh-session-projection',
    'dsh-sandbox-policy', 'dsh-fs-sandbox', 'dsh-fs-local', 'dsh-fs',
    'dsh-typert-registry', 'dsh-typert-protocol', 'dsh-api-workspace-files', 'dsh-scope',
]] + ['node_modules/@deepseek-ai/dsh-api-workspace-files/lib/typert.host.js']
SOURCE = [
    'runtime/ohos/sim/preload.mjs',
    'runtime/tests/ohos/authorized-workspaces-fixture.mjs',
    'runtime/tests/ohos/entry-ability-fixture.mjs',
    'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets',
    'app/ohos/entry/src/main/ets/plugins/AuthorizedWorkspacesPlugin.ets',
    'app/ohos/entry/src/main/ets/plugins/NativeFilePolicy.ets',
]


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def identity(path):
    path = Path(path)
    info = path.stat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('Expected a regular input file: ' + str(path))
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return {'path': str(path), 'resolvedPath': str(path.resolve()), 'bytes': info.st_size,
            'sha256': value.hexdigest(), 'mode': format(stat.S_IMODE(info.st_mode), '04o')}


def error_info(error):
    return {'name': type(error).__name__, 'message': str(error)}


def actor_passed(report):
    rows = report.get('cases', [])
    retired = report.get('nativeRetired', {})
    expected_data = [228, 184, 173, 230, 150, 135]
    if [row.get('name') for row in rows] != CASES:
        return False
    for row in rows:
        path = row.get('knownAbsolutePath')
        prelude = row.get('preludeResult', {})
        version = prelude.get('version')
        expected = {'absolutePath': path, 'version': version, 'bytes': 11,
                    'offset': 2, 'data': expected_data, 'eof': False}
        before = row.get('ownedBefore', {})
        file = before.get('file', {})
        if not (isinstance(path, str) and path.endswith('/byte-marker.txt')
                and isinstance(version, str) and version
                and prelude == {'absolutePath': path, 'version': version, 'bytes': 11}
                and row.get('opaqueVersion') == version
                and row.get('expected') == expected and row.get('result') == expected
                and row.get('status') == 'PASS' and row.get('pass') is True
                and row.get('preludePassed') is True
                and row.get('targetEntryCount') == 1 and row.get('targetEntered') is True
                and row.get('targetReturned') is True and row.get('targetRejected') is False
                and row.get('targetAwaitSettled') is True
                and row.get('providerEntryCount') == 1 and row.get('providerEntered') is True
                and row.get('providerReturned') is True and row.get('providerRejected') is False
                and row.get('reached', {}).get('wholeReadBytes') is False
                and row.get('dataIsUint8Array') is True and row.get('dataByteLength') == 6
                and row.get('dataHex') == 'e4b8ade69687' and row.get('resultOraclePassed') is True
                and row.get('contextDisposed') is True and row.get('ownedUnchanged') is True
                and before == row.get('ownedAfterPrelude') == row.get('ownedAfter')
                and file.get('bytes') == 11 and file.get('hex') == '4142e4b8ade6968743440a'
                and file.get('mode') == 0o600
                and not row.get('setupError') and not row.get('unexpectedError')
                and not row.get('cleanupErrors') and not row.get('behaviorErrors')
                and all(not call.get('observationError') for call in row.get('calls', []))):
            return False
    logical = rows[1]
    return (report.get('pass') is True and report.get('targetCallCount') == 2
            and not report.get('setupError') and not report.get('unexpectedError')
            and not report.get('cleanupErrors') and report.get('cleanupCompleted') is True
            and report.get('noSeparateDirectMapping') is True
            and report.get('logicalHostPathAbsent') is True
            and report.get('logicalHostPathStillAbsent') is True
            and report.get('ownedFilesUnchanged') is True and report.get('methodsRestored') is True
            and logical.get('nativeBeforeTarget', {}).get('leases') == 0
            and logical.get('nativeAfterTargetAwait', {}).get('leases') == 0
            and logical.get('nativeAfterTargetAwait', {}).get('active') is True
            and logical.get('borrowedFDsAfterTargetAwait') == 0
            and logical.get('nativeAfterContextDispose', {}).get('leases') == 0
            and logical.get('nativeAfterContextDispose', {}).get('active') is True
            and logical.get('borrowedFDsAfterContextDispose') == 0
            and retired.get('active') is False and retired.get('leases') == 0
            and retired.get('drained') is True)


def classify(report, code, timeout, unchanged):
    rows = report.get('cases', [])
    if not unchanged:
        return 'INPUT_DRIFT'
    if timeout:
        return 'TIMEOUT_UNCLASSIFIED'
    if not report:
        return 'SETUP_ERROR_NO_ACTOR_REPORT'
    if report.get('cleanupErrors') or any(row.get('cleanupErrors') for row in rows):
        return 'CLEANUP_FAILED'
    if report.get('setupError') or any(row.get('status') == 'SETUP_ERROR' or row.get('setupError') for row in rows):
        return 'SETUP_ERROR'
    if report.get('unexpectedError') or any(row.get('status') == 'UNEXPECTED_ERROR' or row.get('unexpectedError') for row in rows):
        return 'UNEXPECTED_ERROR'
    if code != 0:
        return 'PROCESS_ERROR'
    if actor_passed(report):
        return 'PASS_SCOPED_BYTES_WINDOW'
    if any(row.get('status') == 'BEHAVIOR_RED' and row.get('preludePassed') is True
           and row.get('targetEntered') is True and row.get('targetAwaitSettled') is True
           and (row.get('targetReturned') is True or (row.get('targetRejected') is True
                and row.get('knownProductRejection') is True)) for row in rows):
        return 'BEHAVIOR_RED'
    return 'INCOMPLETE_REPORT'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['source', 'payload', 'node', 'typescript-prefix', 'native-directory', 'publication-fixture', 'out']:
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--manifest', required=True, type=Path,
                        help='Actual composer manifest for the selected payload; no synthetic/overlay receipt')
    parser.add_argument('--jitless', action='store_true')
    args = parser.parse_args()
    source, payload, node, native, output, manifest_path, typescript, publication = [p.resolve() for p in [
        args.source, args.payload, args.node, args.native_directory, args.out, args.manifest,
        args.typescript_prefix, args.publication_fixture]]
    if output.exists():
        raise SystemExit('--out must be a fresh directory; previous evidence is never overwritten')
    output.mkdir(parents=True, mode=0o700)
    paths, before, command = [], [], None
    save(output / 'INVOCATION.json', {
        'source': str(source), 'payload': str(payload), 'node': str(node),
        'typescriptPrefix': str(typescript), 'nativeDirectory': str(native),
        'publicationFixture': str(publication), 'manifest': str(manifest_path),
        'out': str(output), 'jitless': args.jitless, 'preparedOrBuiltByThisRunner': False})
    result = {'schema': 1, 'startedUTC': utc(), 'pass': False, 'executed': False,
              'classification': 'SETUP_ERROR', 'mode': 'jitless' if args.jitless else 'plain'}
    payload_checked_before_failure = []
    try:
        manifest = json.loads(manifest_path.read_text())
        rows = {row['path']: row for row in manifest['files']}
        if len(rows) != len(manifest['files']):
            raise ValueError('Manifest contains duplicate file records')
        payload_checks = []
        for name in PAYLOAD:
            actual, recorded = identity(payload / name), rows[name]
            payload_checked_before_failure.append(actual)
            if (actual['sha256'], actual['bytes']) != (recorded['sha256'], recorded['size']):
                raise ValueError('Payload/manifest mismatch: ' + name)
            payload_checks.append(name)
        paths = list(dict.fromkeys(
            [HERE / name for name in TESTS] + [source / name for name in SOURCE]
            + [payload / name for name in PAYLOAD] + [native / name for name in NATIVE]
            + [node, publication, manifest_path, typescript / 'node_modules/typescript/package.json',
               typescript / 'node_modules/typescript/lib/typescript.js']))
        before = [identity(path) for path in paths]
        if json.loads((typescript / 'node_modules/typescript/package.json').read_text())['version'] != '5.9.3':
            raise ValueError('The existing SDK fixture requires TypeScript 5.9.3')
        for name in ['home', 'tmp', 'physical', 'linux-tools']:
            (output / name).mkdir(mode=0o700)
        config = {'source': str(source), 'payload': str(payload), 'nativeDirectory': str(native),
                  'physical': str(output / 'physical'), 'result': str(output / 'REPORT.json')}
        save(output / 'CONFIG.json', config)
        environment = {
            'PATH': os.pathsep.join([str(node.parent), '/usr/bin', '/bin']),
            'HOME': str(output / 'home'), 'TMPDIR': str(output / 'tmp'), 'LANG': 'C.UTF-8',
            'LD_PRELOAD': str(native / 'libdsh_host.so') + ':' + str(publication),
            'DSH_HOME': str(output / 'home'), 'NARB_DISABLE_NATIVE_CACHE': '1',
            'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(native),
            'DSH_GO_OHOS_LINUX_DIRECTORY': str(output / 'linux-tools'),
            'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony',
            'OHOS_939_BYTES_CONFIG': str(output / 'CONFIG.json'),
            'OHOS_TYPESCRIPT_PREFIX': str(typescript),
            'OHOS_WORKSPACE_GRANTS_ADDON': str(native / 'workspace-publisher.node'),
        }
        command = [str(node), *(['--jitless'] if args.jitless else []), '--max-old-space-size=256',
                   '--import', str(HERE / 'workspace-bytes-instrumentation.mjs'),
                   '--import', str(payload / 'runtime/ohos/preload.mjs'),
                   '--import', str(HERE / 'workspace-bytes-entry.mjs'),
                   str(payload / 'node_modules/@deepseek-ai/dsh/lib/bin.js'),
                   '--profile', 'web', '--dump-config']
        save(output / 'INPUTS.json', {'recordedUTC': utc(), 'files': before,
            'source': str(source), 'payload': str(payload), 'nativeDirectory': str(native),
            'manifest': str(manifest_path), 'runtimeVersion': manifest.get('runtimeVersion'),
            'payloadManifestChecked': payload_checks,
            'scope': 'Selected actual payload files matched the supplied manifest. No archive, prepare or whole-build verification is claimed here. Source supplies unchanged SDK fixture bodies; executed product JS comes from payload.'})
        save(output / 'COMMAND.json', {'argv': command, 'cwd': str(output), 'environment': environment,
            'environmentSource': 'Complete literal child environment; no os.environ inheritance',
            'nativeBuild': 'None: five existing native files and the publication fixture are input-only'})
        started = time.monotonic()
        timeout = False
        result['executed'] = True
        with (output / 'node.stdout').open('wb') as stdout, (output / 'node.stderr').open('wb') as stderr:
            try:
                child = subprocess.run(command, cwd=output, env=environment, stdout=stdout, stderr=stderr, timeout=90)
                code = child.returncode
            except subprocess.TimeoutExpired:
                code, timeout = 124, True
        result.update(exitCode=code, seconds=time.monotonic() - started, timeout=timeout)
        after = [identity(path) for path in paths]
        unchanged = before == after
        save(output / 'SOURCE-AFTER.json', {'files': after, 'unchanged': unchanged})
        report_path = output / 'REPORT.json'
        report = json.loads(report_path.read_text()) if report_path.exists() else {}
        result['classification'] = classify(report, code, timeout, unchanged)
        result['pass'] = result['classification'] == 'PASS_SCOPED_BYTES_WINDOW'
        result['inputsUnchanged'] = unchanged
        result['cases'] = [{key: row.get(key) for key in
                            ['name', 'status', 'pass', 'preludePassed', 'targetCallStarted', 'targetEntered', 'targetReturned', 'targetRejected', 'targetAwaitSettled', 'providerEntered', 'providerReturned', 'providerRejected', 'resultOraclePassed', 'reached', 'notReached', 'blockedBy']}
                           for row in report.get('cases', [])]
        result['targetCallCount'] = report.get('targetCallCount', 0)
        result['cleanupCompleted'] = report.get('cleanupCompleted', False)
        result['report'] = identity(report_path) if report_path.exists() else None
        result['logs'] = [identity(output / name) for name in ['node.stdout', 'node.stderr']]
    except Exception as error:
        result['classification'] = 'UNEXPECTED_RUNNER_ERROR' if result['executed'] else 'SETUP_ERROR'
        result['error'] = error_info(error)
        # Preserve every available input identity even for preparation failures.
        save(output / 'PREPARATION-STATE.json', {'filesRecorded': before, 'payloadFilesRead': payload_checked_before_failure,
                                               'commandPrepared': command,
                                               'error': error_info(error)})
        if before and not (output / 'SOURCE-AFTER.json').exists():
            after, failures = [], []
            for path in paths:
                try:
                    after.append(identity(path))
                except Exception as followup:
                    failures.append({'path': str(path), **error_info(followup)})
            save(output / 'SOURCE-AFTER.json', {'files': after, 'failures': failures,
                                               'unchanged': not failures and before == after})
    result['endedUTC'] = utc()
    result['scope'] = 'Exactly two ordinary 11-byte file windows through real SessionStore, registered lookup and readBytes/readByteRange. No whole-file readBytes, multi-window/Dart/carrier/UI, full Host, persistent Session, SDK/device, extra scenarios or native build.'
    save(output / 'RESULT.json', result)
    print(json.dumps({'out': str(output), 'pass': result['pass'], 'classification': result['classification'],
                      'executed': result['executed'], 'exitCode': result.get('exitCode'),
                      'cases': result.get('cases', [])}, ensure_ascii=False))
    return 0 if result['pass'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
