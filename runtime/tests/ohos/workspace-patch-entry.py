#!/usr/bin/env python3
"""Two ordinary own-file updates through explicitly enabled apply_patch; standard default is false."""
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
CASES = ['physical-read-then-patch', 'selected-logical-read-then-patch']
TESTS = ['workspace-patch-entry.py', 'workspace-patch-entry.mjs', 'workspace-patch-instrumentation.mjs']
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


def successful_case(row):
    if not (row.get('status') == 'PASS' and row.get('pass') is True
            and row.get('readPreludePassed') is True and row.get('readBatchReturned') is True
            and row.get('patchCallStarted') is True and row.get('patchBatchReturned') is True
            and row.get('patchProviderEntered') is True and row.get('patchSuccessOraclePassed') is True
            and row.get('markerOutcomeVerified') is True and row.get('contextDisposed') is True
            and row.get('independentReadVersionVerified') is True
            and row.get('independentPatchVersionVerified') is True
            and not row.get('setupError') and not row.get('unexpectedError')
            and not row.get('cleanupErrors') and not row.get('behaviorErrors')):
        return False
    session = row.get('session', {})
    if not (session.get('type') == 'Session' and session.get('store') == 'actual in-memory SessionStore'
            and row.get('services', {}).get('sessions') == 'SessionStore'
            and row.get('services', {}).get('executor') == 'NativeToolExecutor'
            and row.get('policy', {}).get('mode') == 'workspace-write'):
        return False
    directory = session.get('headerCwd')
    if not isinstance(directory, str):
        return False
    path = str(Path(directory) / 'marker.txt')
    read_rows, patch_rows = row.get('readBatch', {}).get('results', []), row.get('patchBatch', {}).get('results', [])
    if len(read_rows) != 1 or len(patch_rows) != 1:
        return False
    if any(row[key].get('additionalContexts') != [] or row[key].get('concluded') is not False
           for key in ['readBatch', 'patchBatch']):
        return False
    read, patch = read_rows[0].get('result', {}), patch_rows[0].get('result', {})
    read_value = {'path': path, 'offset': 1, 'lines': [{'number': 1, 'text': 'FIRST'}], 'totalLines': 1}
    read_text = '<path>' + path + '</path>\n<type>file</type>\n<content>\n1: FIRST\n\n(End of file - total 1 lines)\n</content>'
    before, after = row.get('markerBefore', {}), row.get('markerAfterPatch', {})
    return (read.get('isError') is False and read.get('value') == read_value and read.get('meta') == read_value
            and read.get('content') == [{'type': 'text', 'text': read_text}]
            and patch.get('isError') is False
            and patch.get('value') == {'phase': 'commit', 'cancelled': False, 'affectedPaths': [path], 'operations': [{'index': 0, 'kind': 'update', 'path': path, 'patchLine': 2, 'status': 'completed', 'changes': [{'path': path, 'before': 'FIRST\n', 'after': 'SECOND\n'}]}]}
            and patch.get('content') == [{'type': 'text', 'text': 'Success. Updated the following files:\nM ' + path}]
            and patch.get('meta') == {'diffs': [{'path': path, 'oldText': 'FIRST', 'newText': 'SECOND'}], 'stopped': False}
            and before.get('bytes') == 6 and before.get('hex') == b'FIRST\n'.hex()
            and after.get('bytes') == 7 and after.get('hex') == b'SECOND\n'.hex()
            and before.get('mode') == 0o644 and after.get('mode') == 0o644
            and row.get('workingDirectoryAfter') == directory)


def actor_passed(report):
    rows = report.get('cases', [])
    retired = report.get('nativeRetired', {})
    return (report.get('pass') is True and [r.get('name') for r in rows] == CASES
            and report.get('readBatchCount') == 2 and report.get('patchBatchCount') == 2
            and all(successful_case(row) for row in rows)
            and not report.get('setupError') and not report.get('unexpectedError')
            and not report.get('cleanupErrors') and report.get('cleanupCompleted') is True
            and report.get('noSeparateDirectMapping') is True and report.get('hostWorkspacesUnchanged') is True
            and report.get('providerMethodsRestored') is True
            and rows[1].get('nativeAfterPatchAwaitVerified') is True
            and rows[1].get('nativeAfterContextDispose', {}).get('active') is True
            and rows[1].get('nativeAfterContextDispose', {}).get('leases') == 0
            and retired.get('active') is False and retired.get('leases') == 0 and retired.get('drained') is True)


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
        return 'PASS_SCOPED_PATCH_ENTRY'
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
        manifest = json.loads(manifest_path.read_text())
        records = {row['path']: row for row in manifest['files']}
        if len(records) != len(manifest['files']):
            raise ValueError('Manifest contains duplicate file records')
        checked, overrides = [], []
        source_pins = json.loads((source / 'runtime/patches/pins.json').read_text())
        dsh_version = json.loads((payload / 'node_modules/@deepseek-ai/dsh/package.json').read_text())['version']
        provider_pins = source_pins['patches']['ohos-workspace-edit.diff'][dsh_version]
        for name in PAYLOAD:
            actual, recorded = identity(payload / name), records[name]
            if args.component_prefix and name in provider_pins:
                if actual['sha256'] != provider_pins[name]['after']:
                    raise ValueError('Component provider does not match exact source OH pin: ' + name)
                overrides.append({'path': name, 'basis': 'exact source OH patch pin', 'actual': actual})
            elif args.component_prefix and name == 'runtime/ohos/process/files/workspace-edit.mjs':
                original = identity(source / name)
                if (actual['sha256'], actual['bytes'], actual['mode']) != (original['sha256'], original['bytes'], original['mode']):
                    raise ValueError('Component writer differs from exact source: ' + name)
                overrides.append({'path': name, 'basis': 'exact source bytes/mode', 'actual': actual})
            else:
                if (actual['sha256'], actual['bytes']) != (recorded['sha256'], recorded['size']):
                    raise ValueError('Payload/manifest mismatch: ' + name)
                checked.append(name)
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
            'OHOS_278_EDIT_CONFIG': str(output / 'CONFIG.json'),
            'OHOS_TYPESCRIPT_PREFIX': str(typescript),
            'OHOS_WORKSPACE_GRANTS_ADDON': str(native / 'workspace-publisher.node'),
        }
        command = [str(node), *(['--jitless'] if args.jitless else []), '--max-old-space-size=256',
                   '--import', str(HERE / 'workspace-patch-instrumentation.mjs'),
                   '--import', str(payload / 'runtime/ohos/preload.mjs'),
                   '--import', str(HERE / 'workspace-patch-entry.mjs'),
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
        result['pass'] = result['classification'] == 'PASS_SCOPED_PATCH_ENTRY'
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
    result['scope'] = 'Two ordinary existing-file read/Update components with explicit applyPatch:true (standard default false), no added observation guard; no Add/Move/Delete, Native build, device/VM or full Host/gate.'
    save(output / 'RESULT.json', result)
    print(json.dumps({'out': str(output), 'pass': result['pass'], 'classification': result['classification'],
                      'executed': result['executed'], 'exitCode': result.get('exitCode'),
                      'cases': result.get('cases', [])}, ensure_ascii=False))
    return 0 if result['pass'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
