#!/usr/bin/env python3
"""Two ordinary own-file moves over existing destinations through explicitly enabled apply_patch; standard default is false."""
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
CASES = ['physical-read-then-move-overwrite', 'selected-logical-read-then-move-overwrite']
TESTS = ['workspace-move-overwrite-entry.py', 'workspace-move-overwrite-entry.mjs', 'workspace-move-overwrite-instrumentation.mjs']
READ_REFERENCES = ['runtime/tests/ohos/' + name for name in
                   ['workspace-read-entry.py', 'workspace-read-entry.mjs', 'workspace-read-instrumentation.mjs']]
NATIVE = ['libdsh_host.so', 'libdsh_workspace_grants.so', 'workspace-publisher.node',
          'libdsh_flock.so', 'libdsh_require_builtin.so']
PAYLOAD = [
    'runtime/ohos/preload.mjs',
    'runtime/ohos/process/files/authority.mjs',
    'runtime/ohos/process/files/process-authority.mjs',
    'runtime/ohos/process/files/grant-fs.mjs',
    'runtime/ohos/process/files/workspace-paths.mjs',
    'runtime/ohos/process/files/workspace-edit.mjs',
    'node_modules/@deepseek-ai/dsh/lib/bin.js',
    'node_modules/@deepseek-ai/dsh/package.json',
    'node_modules/@deepseek-ai/dsh-base/cordis.patch.yml',
    'node_modules/@deepseek-ai/dsh-web-app/cordis.patch.yml',
    'node_modules/@deepseek-ai/dsh-web-app/presets/standard.patch.yml',
    'node_modules/@dsh-go/ohos-native/package.json',
    'node_modules/@dsh-go/ohos-native/index.cjs',
] + ['node_modules/@deepseek-ai/' + name + '/lib/index.js' for name in [
    'cordis', 'dsh-session', 'dsh-system-prompt', 'dsh-session-projection',
    'dsh-sandbox-policy', 'dsh-sandbox', 'dsh-fs-sandbox', 'dsh-fs-local', 'dsh-fs',
    'dsh-working-directory', 'dsh-tools', 'dsh-tool-executor-native', 'dsh-tool-fs', 'dsh-scope',
    'dsh-fs-observation-policy',
]] + ['node_modules/@deepseek-ai/dsh-tools/lib/pipeline.js']
SOURCE = [
    'runtime/ohos/sim/preload.mjs',
    'runtime/ohos/sim/marker.mjs',
    'runtime/patches/pins.json',
    'runtime/patches/ohos-workspace-edit.diff',
    'runtime/ohos/process/files/workspace-edit.mjs',
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


def file_version(info, grant=None):
    values = info['exactStat']
    if grant is None:
        return ':'.join(values[key] for key in ['dev', 'ino', 'size', 'mtimeNs', 'ctimeNs'])
    mt_sec, mt_ns = divmod(int(values['mtimeNs']), 1_000_000_000)
    ct_sec, ct_ns = divmod(int(values['ctimeNs']), 1_000_000_000)
    return ':'.join(['ohos-grant', grant['id'], str(grant['generation']), values['dev'], values['ino'],
                     values['size'], str(mt_sec), str(mt_ns), str(ct_sec), str(ct_ns)])


def owned(info, value, mode):
    data = value.encode('utf8')
    return (info.get('exists') is True and info.get('bytes') == len(data)
            and info.get('hex') == data.hex() and info.get('sha256') == hashlib.sha256(data).hexdigest()
            and info.get('mode') == mode and info.get('exactStat', {}).get('size') == str(len(data)))

def successful_case(row):
    if not (row.get('status') == 'PASS' and row.get('pass') is True
            and row.get('readPreludePassed') is True and row.get('readBatchReturned') is True
            and row.get('patchCallStarted') is True and row.get('patchBatchReturned') is True
            and row.get('patchProviderEntered') is True and row.get('patchSuccessOraclePassed') is True
            and row.get('markerOutcomeVerified') is True and row.get('contextDisposed') is True
            and row.get('independentReadVersionVerified') is True
            and row.get('independentAbsenceVerified') is True
            and row.get('independentDestinationVersionVerified') is True
            and row.get('completeMoveContractVerified') is True
            and row.get('actualMoveIntent') == {'source': {'present': False}, 'destination': {'present': False}}
            and row.get('destinationParentPreexists') is True
            and row.get('toolConfig') == {'applyPatch': True}
            and not row.get('setupError') and not row.get('unexpectedError')
            and not row.get('cleanupErrors') and not row.get('behaviorErrors')):
        return False
    session = row.get('session', {})
    directory = session.get('headerCwd')
    if not (isinstance(directory, str) and session.get('type') == 'Session'
            and session.get('store') == 'actual in-memory SessionStore'
            and row.get('services', {}).get('sessions') == 'SessionStore'
            and row.get('services', {}).get('executor') == 'NativeToolExecutor'
            and row.get('services', {}).get('fs') == 'SandboxedFileSystem'
            and row.get('policy', {}).get('mode') == 'workspace-write'
            and row.get('policy', {}).get('workspaceRoot') == directory):
        return False
    path, destination = str(Path(directory) / 'marker.txt'), str(Path(directory) / 'moved.txt')
    before, destination_before, after = (row.get('markerBefore', {}), row.get('destinationBefore', {}),
                                        row.get('destinationAfterPatch', {}))
    grant = row.get('grant') if row.get('name') == CASES[1] else None
    try:
        source_version = file_version(before, grant)
        destination_before_version = file_version(destination_before, grant)
        destination_version = file_version(after, grant)
    except (KeyError, TypeError, ValueError):
        return False
    if row.get('name') == CASES[1] and not (isinstance(grant, dict) and grant.get('mountPoint') == directory
                                           and grant.get('writable') is True):
        return False
    read_id, patch_id = '302-read-' + row.get('name', ''), '302-patch-' + row.get('name', '')
    read_value = {'path': path, 'offset': 1, 'lines': [{'number': 1, 'text': 'FIRST'}], 'totalLines': 1}
    read_text = '<path>' + path + '</path>\n<type>file</type>\n<content>\n1: FIRST\n\n(End of file - total 1 lines)\n</content>'
    expected_read = {'isError': False, 'content': [{'type': 'text', 'text': read_text}],
                     'meta': read_value, 'value': read_value}
    expected_patch = {
        'isError': False,
        'content': [{'type': 'text', 'text': 'Success. Updated the following files:\nM ' + destination}],
        'meta': {'diffs': [{'path': destination, 'oldText': 'OLD', 'newText': 'SECOND'},
                           {'path': path, 'oldText': 'FIRST\n', 'newText': ''}], 'stopped': False},
        'value': {'phase': 'commit', 'cancelled': False, 'affectedPaths': [destination, path],
                  'operations': [{'index': 0, 'kind': 'move', 'path': path, 'patchLine': 2,
                                  'destination': destination, 'status': 'completed',
                                  'changes': [{'path': destination, 'before': 'OLD\n', 'after': 'SECOND\n'},
                                              {'path': path, 'before': 'FIRST\n', 'after': None}]}]},
    }
    provider_outcome = {'status': 'fulfilled', 'value': {'sourceBefore': 'FIRST\n',
        'destination': {'operation': 'update', 'version': destination_version, 'before': 'OLD\n', 'after': 'SECOND\n'},
        'sourceDeleted': True}}
    read_call = {'method': 'readText', 'targetKey': path, 'displayPath': path}
    move_call = {'method': 'moveFile', 'targetKey': path, 'displayPath': path,
                 'destinationKey': destination, 'destinationPath': destination,
                 'intent': {'source': {'present': False}, 'destination': {'present': False}},
                 'hunks': [{'lineNumber': 4, 'oldLines': ['FIRST'], 'newLines': ['SECOND'], 'isEndOfFile': False}],
                 'outcome': provider_outcome}
    return (row.get('readBatch') == {'results': [{'callId': read_id, 'result': expected_read}],
                                     'additionalContexts': [], 'concluded': False}
            and row.get('patchBatch') == {'results': [{'callId': patch_id, 'result': expected_patch}],
                                          'additionalContexts': [], 'concluded': False}
            and row.get('readProviderCalls') == [read_call]
            and row.get('patchProviderCalls') == [read_call, move_call]
            and row.get('publicMoveOutcome') == provider_outcome
            and row.get('independentReadVersion') == source_version
            and row.get('independentDestinationBeforeVersion') == destination_before_version
            and row.get('independentDestinationVersion') == destination_version
            and destination_version != destination_before_version
            and row.get('readObservation') == {'target': {'displayPath': path, 'targetKey': path},
                'observed': {'kind': 'present', 'version': source_version}, 'callId': read_id}
            and row.get('destinationObservation') == {'target': {'displayPath': destination, 'targetKey': destination},
                'observed': {'kind': 'present', 'version': destination_version}, 'callId': patch_id}
            and row.get('patchObservation') == {'target': {'displayPath': path, 'targetKey': path},
                'observed': {'kind': 'absent'}, 'callId': patch_id}
            and before.get('exists') is True and before.get('bytes') == 6
            and before.get('hex') == b'FIRST\n'.hex() and before.get('mode') == 0o640
            and before.get('sha256') == hashlib.sha256(b'FIRST\n').hexdigest()
            and before.get('exactStat', {}).get('size') == '6'
            and row.get('markerAfterRead') == before
            and owned(destination_before, 'OLD\n', 0o600)
            and row.get('destinationAfterRead') == destination_before
            and row.get('markerAfterPatch') == row.get('markerAtFinalTeardown') == {'exists': False}
            and after.get('exists') is True and after.get('bytes') == 7
            and after.get('hex') == b'SECOND\n'.hex() and after.get('mode') == 0o640
            and after.get('sha256') == hashlib.sha256(b'SECOND\n').hexdigest()
            and after.get('exactStat', {}).get('size') == '7'
            and row.get('destinationAtFinalTeardown') == after
            and row.get('workingDirectoryAfter') == directory)


def actor_passed(report):
    rows = report.get('cases', [])
    if [row.get('name') for row in rows] != CASES or not all(successful_case(row) for row in rows):
        return False
    logical = rows[1]
    retired = report.get('nativeRetired', {})
    generation = logical.get('grant', {}).get('generation')
    samples = [logical.get(key, {}) for key in ['nativeBefore', 'nativeAfterPatchAwait', 'nativeAfterContextDispose']]
    expected_observations = [observation for row in rows for observation in
                             [row['readObservation'], row['destinationObservation'], row['patchObservation']]]
    return (report.get('pass') is True and report.get('readBatchCount') == 2 and report.get('patchBatchCount') == 2
            and not report.get('setupError') and not report.get('unexpectedError')
            and not report.get('cleanupErrors') and report.get('cleanupCompleted') is True
            and report.get('noSeparateDirectMapping') is True and report.get('ownerSymbolRegistered') is True
            and report.get('hostWorkspacesUnchanged') is True
            and report.get('hostWorkspacesBefore') == report.get('hostWorkspacesAfter') == {'exists': False}
            and report.get('providerMethodsRestored') is True
            and report.get('observations') == expected_observations
            and report.get('published', {}).get('borrowedFDs') == 0
            and logical.get('nativeAfterPatchAwaitVerified') is True
            and all(sample.get('active') is True and sample.get('leases') == 0
                    and sample.get('generation') == generation for sample in samples)
            and retired.get('active') is False and retired.get('leases') == 0
            and retired.get('generation') == generation and retired.get('drained') is True)


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
    if report.get('setupError') or any(row.get('setupError') or row.get('status') == 'SETUP_ERROR' for row in rows):
        return 'SETUP_ERROR'
    if report.get('unexpectedError') or any(row.get('unexpectedError') or row.get('status') == 'UNEXPECTED_ERROR' for row in rows):
        return 'UNEXPECTED_ERROR'
    if code != 0:
        return 'PROCESS_ERROR'
    if actor_passed(report):
        return 'PASS_SCOPED_MOVE_OVERWRITE_ENTRY'
    if any(row.get('status') == 'BEHAVIOR_RED' and row.get('readPreludePassed') is True
           and row.get('patchCallStarted') is True and row.get('patchBatchReturned') is True
           and row.get('patchProviderEntered') is True for row in rows):
        return 'BEHAVIOR_RED'
    return 'INCOMPLETE_REPORT'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['source', 'payload', 'node', 'typescript-prefix', 'native-directory', 'publication-fixture', 'out']:
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--manifest', required=True, type=Path,
                        help='Actual official composer manifest; never synthesize an overlay receipt')
    parser.add_argument('--jitless', action='store_true')
    parser.add_argument('--component-prefix', action='store_true',
                        help='Explicit private validation prefix: two provider JS files must match source OH pins, workspace-edit must equal source; all other selected files match the supplied historical manifest. Not a new official compose.')
    args = parser.parse_args()
    source, payload, node, native, output, manifest_path, typescript, publication = [p.resolve() for p in [
        args.source, args.payload, args.node, args.native_directory, args.out, args.manifest,
        args.typescript_prefix, args.publication_fixture]]
    if output.exists():
        raise SystemExit('--out must be fresh; existing evidence is never overwritten')
    output.mkdir(parents=True, mode=0o700)
    paths, before, command = [], [], None
    result = {'schema': 1, 'startedUTC': utc(), 'pass': False, 'executed': False,
              'classification': 'SETUP_ERROR', 'mode': 'jitless' if args.jitless else 'plain'}
    try:
        if os.path.lexists('/workspaces'):
            raise ValueError('Host /workspaces must be absent for these normal logical-coordinate cases')
        manifest = json.loads(manifest_path.read_text())
        if not isinstance(manifest.get('runtimeVersion'), str) or not manifest['runtimeVersion']:
            raise ValueError('Actual manifest must carry its own nonempty runtimeVersion')
        records = {row['path']: row for row in manifest['files']}
        if len(records) != len(manifest['files']):
            raise ValueError('Manifest contains duplicate file records')
        checked, overrides = [], []
        source_pins = json.loads((source / 'runtime/patches/pins.json').read_text())
        dsh_version = json.loads((payload / 'node_modules/@deepseek-ai/dsh/package.json').read_text())['version']
        provider_pins = source_pins['patches']['ohos-workspace-edit.diff'][dsh_version]
        provider_names = {'node_modules/@deepseek-ai/dsh-fs-local/lib/index.js',
                          'node_modules/@deepseek-ai/dsh-fs-sandbox/lib/index.js'}
        if set(provider_pins) != provider_names:
            raise ValueError('Component mode requires the existing exact two-provider OH pin mapping')
        for name in PAYLOAD:
            actual, recorded = identity(payload / name), records[name]
            if args.component_prefix and name in provider_pins:
                if actual['sha256'] != provider_pins[name]['after']:
                    raise ValueError('Component provider does not match exact source OH pin: ' + name)
                overrides.append({'path': name, 'basis': 'exact source OH patch pin', 'actual': actual,
                                  'expectedSha256': provider_pins[name]['after'], 'dshVersion': dsh_version,
                                  'pinSource': str(source / 'runtime/patches/pins.json'),
                                  'patchSource': str(source / 'runtime/patches/ohos-workspace-edit.diff')})
            elif args.component_prefix and name == 'runtime/ohos/process/files/workspace-edit.mjs':
                original = identity(source / name)
                if (actual['sha256'], actual['bytes'], actual['mode']) != (original['sha256'], original['bytes'], original['mode']):
                    raise ValueError('Component writer differs from exact source: ' + name)
                overrides.append({'path': name, 'basis': 'exact source bytes/mode', 'actual': actual,
                                  'sourceIdentity': original})
            else:
                if (actual['sha256'], actual['bytes']) != (recorded['sha256'], recorded['size']):
                    raise ValueError('Payload/manifest mismatch: ' + name)
                checked.append(name)
        if args.component_prefix and len(overrides) != 3:
            raise ValueError('Component prefix must bind exactly two provider afterimages and one writer source')
        paths = list(dict.fromkeys(
            [HERE / name for name in TESTS] + [source / name for name in SOURCE + READ_REFERENCES]
            + [payload / name for name in PAYLOAD] + [native / name for name in NATIVE]
            + [node, publication, manifest_path, typescript / 'node_modules/typescript/package.json',
               typescript / 'node_modules/typescript/lib/typescript.js']))
        before = [identity(path) for path in paths]
        if json.loads((typescript / 'node_modules/typescript/package.json').read_text())['version'] != '5.9.3':
            raise ValueError('The existing SDK fixture requires TypeScript 5.9.3')
        for name in ['home', 'tmp', 'physical', 'linux-tools']:
            (output / name).mkdir(mode=0o700)
        config = {'source': str(source), 'payload': str(payload), 'nativeDirectory': str(native),
                  'physical': str(output / 'physical'), 'result': str(output / 'REPORT.json'),
                  'fsLocalSha256': identity(payload / 'node_modules/@deepseek-ai/dsh-fs-local/lib/index.js')['sha256']}
        save(output / 'CONFIG.json', config)
        environment = {
            'PATH': os.environ['PATH'],
            'HOME': os.environ['HOME'], 'TMPDIR': str(output / 'tmp'), 'LANG': 'C.UTF-8',
            'LD_PRELOAD': str(native / 'libdsh_host.so') + ':' + str(publication),
            'DSH_HOME': str(output / 'home'), 'NARB_DISABLE_NATIVE_CACHE': '1',
            'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(native),
            'DSH_GO_OHOS_LINUX_DIRECTORY': str(output / 'linux-tools'),
            'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony',
            'OHOS_302_MOVE_CONFIG': str(output / 'CONFIG.json'),
            'OHOS_TYPESCRIPT_PREFIX': str(typescript),
            'OHOS_WORKSPACE_GRANTS_ADDON': str(native / 'workspace-publisher.node'),
        }
        command = [str(node), *(['--jitless'] if args.jitless else []), '--max-old-space-size=256',
                   '--import', str(HERE / 'workspace-move-overwrite-instrumentation.mjs'),
                   '--import', str(payload / 'runtime/ohos/preload.mjs'),
                   '--import', str(HERE / 'workspace-move-overwrite-entry.mjs'),
                   str(payload / 'node_modules/@deepseek-ai/dsh/lib/bin.js'),
                   '--profile', 'web', '--dump-config']
        save(output / 'INPUTS.json', {'recordedUTC': utc(), 'files': before,
            'source': str(source), 'payload': str(payload), 'nativeDirectory': str(native),
            'manifest': str(manifest_path), 'runtimeVersion': None if args.component_prefix else manifest.get('runtimeVersion'),
            'referenceRuntimeVersion': manifest.get('runtimeVersion'), 'componentPrefix': args.component_prefix,
            'exactSourceOverrides': overrides,
            'payloadManifestChecked': checked, 'referenceOnlyNotExecuted': READ_REFERENCES,
            'scope': 'Selected files match the supplied manifest except explicitly recorded source-pinned component overrides when requested. No new compose/runtimeVersion claim for component prefixes. Old read tests are references, not executed.'})
        save(output / 'COMMAND.json', {'argv': command, 'cwd': str(output), 'environment': environment,
            'environmentSource': 'Explicit allowlist; HOME/PATH inherited unchanged, no other ambient dictionary copied',
            'instrumentationAdds': {'DSH_GO_OHOS_SIM_ADDONS': [str(native / name) for name in
                ['libdsh_flock.so', 'libdsh_require_builtin.so', 'libdsh_workspace_grants.so', 'workspace-publisher.node']]},
            'nativeBuild': 'None: reuse five input libraries and the existing linked publication fixture'})
        started, timeout = time.monotonic(), False
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
        result['pass'] = result['classification'] == 'PASS_SCOPED_MOVE_OVERWRITE_ENTRY'
        result['inputsUnchanged'] = unchanged
        result['cases'] = [{key: row.get(key) for key in [
            'name', 'status', 'pass', 'readPreludePassed', 'readBatchReturned', 'patchCallStarted',
            'patchBatchReturned', 'patchProviderEntered', 'knownProductRejection', 'markerOutcomeVerified', 'blockedBy']}
            for row in report.get('cases', [])]
        result['readBatchCount'] = report.get('readBatchCount', 0)
        result['patchBatchCount'] = report.get('patchBatchCount', 0)
        result['cleanupCompleted'] = report.get('cleanupCompleted', False)
        result['report'] = identity(report_path) if report_path.exists() else None
        result['logs'] = [identity(output / name) for name in ['node.stdout', 'node.stderr']]
    except Exception as error:
        result['classification'] = 'UNEXPECTED_RUNNER_ERROR' if result['executed'] else 'SETUP_ERROR'
        result['error'] = error_info(error)
        save(output / 'PREPARATION-STATE.json', {'filesRecorded': before, 'commandPrepared': command,
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
    result['scope'] = 'Two ordinary same-root existing-source/existing-destination read/Move components with explicit applyPatch:true (standard default false), no added observation guard; no Add/Delete, partial failure, cross-grant, new parents, Native build, device/VM or full Host/gate.'
    save(output / 'RESULT.json', result)
    print(json.dumps({'out': str(output), 'pass': result['pass'], 'classification': result['classification'],
                      'executed': result['executed'], 'exitCode': result.get('exitCode'),
                      'cases': result.get('cases', [])}, ensure_ascii=False))
    return 0 if result['pass'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
