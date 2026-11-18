#!/usr/bin/env python3
from pathlib import Path
import argparse, datetime, hashlib, json, os, stat, subprocess, sys, time

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description='Four ordinary no-range WorkspaceFiles whole-byte contracts; normal SDK chooser and actual Session scope')
for name in ['source', 'payload', 'node', 'typescript-prefix', 'native-directory', 'publication-fixture', 'out', 'manifest']:
    parser.add_argument('--' + name, required=True, type=Path)
parser.add_argument('--jitless', action='store_true')
parser.add_argument('--component-prefix', action='store_true',
    help='Private validation prefix only: two final OH provider pins, source writer and the source-derived deletion companion; all other selected files match the actual historical manifest. Never a new compose/runtimeVersion.')
args = parser.parse_args()
source, payload, node, native, O, manifest_path, typescript, publication = [p.resolve() for p in [
    args.source, args.payload, args.node, args.native_directory, args.out, args.manifest,
    args.typescript_prefix, args.publication_fixture]]
if O.exists():
    raise SystemExit('--out must be fresh; existing evidence is never overwritten')
O.mkdir(mode=0o700, parents=True)
TESTS = ['workspace-whole-bytes-entry.py', 'workspace-whole-bytes-entry.mjs', 'workspace-whole-bytes-instrumentation.mjs']
NATIVE = ['libdsh_host.so', 'libdsh_workspace_grants.so', 'workspace-publisher.node', 'libdsh_flock.so', 'libdsh_require_builtin.so']
SOURCE = [
    'runtime/ohos/sim/preload.mjs', 'runtime/ohos/sim/marker.mjs',
    'runtime/patches/pins.json', 'runtime/patches/ohos-workspace-edit.diff',
    'runtime/ohos/process/files/workspace-edit.mjs',
    'runtime/session-deletion/core.mjs', 'runtime/ohos/package/compose-runtime.py',
    'runtime/ohos/package/session-deletion-ohos.diff', 'runtime/ohos/package/dynamic-omissions.json',
    'runtime/tests/ohos/authorized-workspaces-fixture.mjs', 'runtime/tests/ohos/entry-ability-fixture.mjs',
    'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets',
    'app/ohos/entry/src/main/ets/plugins/AuthorizedWorkspacesPlugin.ets',
    'app/ohos/entry/src/main/ets/plugins/NativeFilePolicy.ets',
]
PAYLOAD = [
    'runtime/ohos/preload.mjs', 'runtime/ohos/process/files/authority.mjs',
    'runtime/ohos/process/files/process-authority.mjs', 'runtime/ohos/process/files/grant-fs.mjs',
    'runtime/ohos/process/files/workspace-paths.mjs', 'runtime/ohos/process/files/workspace-edit.mjs',
    'node_modules/@deepseek-ai/dsh/lib/bin.js', 'node_modules/@deepseek-ai/dsh/package.json',
    'node_modules/@deepseek-ai/dsh-base/cordis.patch.yml',
    'node_modules/@deepseek-ai/dsh-web-app/cordis.patch.yml',
    'node_modules/@deepseek-ai/dsh-web-app/presets/standard.patch.yml',
    'node_modules/@dsh-go/ohos-native/package.json', 'node_modules/@dsh-go/ohos-native/index.cjs',
    'node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/dsh-go-deletion.mjs',
] + ['node_modules/@deepseek-ai/' + name + '/lib/index.js' for name in [
    'cordis', 'dsh-session', 'dsh-system-prompt', 'dsh-session-projection', 'dsh-sandbox-policy',
    'dsh-sandbox', 'dsh-fs-sandbox', 'dsh-fs-local', 'dsh-fs', 'dsh-llm', 'dsh-home-paths',
    'dsh-lazy-require', 'dsh-typert-registry', 'dsh-api-workspace-files', 'dsh-typert-protocol',
]] + ['node_modules/@deepseek-ai/' + name + '/package.json' for name in [
    'dsh-typert-registry', 'dsh-api-workspace-files', 'dsh-typert-protocol',
]]

def utc(): return datetime.datetime.now(datetime.timezone.utc).isoformat()
def ident(path):
    p = Path(path)
    with p.open('rb') as f: digest = hashlib.file_digest(f, 'sha256').hexdigest()
    return {'path': str(p), 'bytes': p.stat().st_size, 'sha256': digest, 'mode': format(stat.S_IMODE(p.stat().st_mode), '04o')}
def save(name, value): (O / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
def version(row):
    x, grant = row['fileBefore']['exactStat'], row.get('grant')
    if not grant: return ':'.join(x[k] for k in ['dev', 'ino', 'size', 'mtimeNs', 'ctimeNs'])
    ms, mn = divmod(int(x['mtimeNs']), 1_000_000_000)
    cs, cn = divmod(int(x['ctimeNs']), 1_000_000_000)
    return ':'.join(['ohos-grant', grant['id'], str(grant['generation']), x['dev'], x['ino'], x['size'], str(ms), str(mn), str(cs), str(cn)])
def fs_error(code, message):
    return {'name': 'FsError', 'code': code, 'message': message, 'details': None, 'isDSHRemoteError': False, 'cause': None}

def prepare_inputs():
    if os.path.lexists('/workspaces'):
        raise ValueError('Host /workspaces must be absent for these ordinary logical-coordinate cases')
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('schema') != 1 or not isinstance(manifest.get('runtimeVersion'), str) or not manifest['runtimeVersion']:
        raise ValueError('An actual official composer manifest with a nonempty runtimeVersion is required')
    records = {item['path']: item for item in manifest['files']}
    if len(records) != len(manifest['files']):
        raise ValueError('Duplicate manifest paths')
    pins_path = source / 'runtime/patches/pins.json'
    pins = json.loads(pins_path.read_text())
    dsh_version = json.loads((payload / 'node_modules/@deepseek-ai/dsh/package.json').read_text())['version']
    if manifest.get('dshVersion') != dsh_version:
        raise ValueError('Manifest DSH version mismatch')
    final_pins = {}
    for patch in pins['targetSets']['ohos']:
        for name, value in pins['patches'][patch][dsh_version].items():
            final_pins[name] = {'sha256': value['after'], 'patch': patch}
    provider_names = {'node_modules/@deepseek-ai/dsh-fs-local/lib/index.js',
                      'node_modules/@deepseek-ai/dsh-fs-sandbox/lib/index.js'}
    source_overrides = {
        'runtime/ohos/process/files/workspace-edit.mjs': 'runtime/ohos/process/files/workspace-edit.mjs',
        'node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/dsh-go-deletion.mjs': 'runtime/session-deletion/core.mjs',
    }
    checked, overrides = [], []
    for name in PAYLOAD:
        actual, recorded = ident(payload / name), records[name]
        if args.component_prefix and name in provider_names:
            pin = final_pins[name]
            if actual['sha256'] != pin['sha256']:
                raise ValueError('Component provider is not the final OH source pin: ' + name)
            overrides.append({'path': name, 'basis': 'final source OH targetSet pin', 'actual': actual,
                'historicalManifest': recorded, 'expectedSHA256': pin['sha256'], 'pinSource': ident(pins_path),
                'patchSource': ident(source / 'runtime/patches' / pin['patch'])})
        elif args.component_prefix and name in source_overrides:
            origin = ident(source / source_overrides[name])
            if any(actual[key] != origin[key] for key in ['sha256', 'bytes', 'mode']):
                raise ValueError('Component companion differs from its exact source: ' + name)
            overrides.append({'path': name, 'basis': 'exact source bytes/mode', 'actual': actual,
                'historicalManifest': recorded, 'sourceIdentity': origin,
                'scope': 'prepared source-derived deletion companion, not the composed OH variant' if name.endswith('dsh-go-deletion.mjs') else 'unchanged private writer source'})
        else:
            if (actual['sha256'], actual['bytes']) != (recorded['sha256'], recorded['size']):
                raise ValueError('Payload differs from actual composer manifest: ' + name)
            checked.append({'path': name, 'sha256': actual['sha256'], 'bytes': actual['bytes']})
    if args.component_prefix and {item['path'] for item in overrides} != provider_names | set(source_overrides):
        raise ValueError('Component mode must explicitly bind all four known historical differences')
    if args.component_prefix and any((item['actual']['sha256'], item['actual']['bytes']) ==
                                    (item['historicalManifest']['sha256'], item['historicalManifest']['size']) for item in overrides):
        raise ValueError('The supplied historical manifest must expose the four declared component differences')
    paths = list(dict.fromkeys([HERE / name for name in TESTS] + [source / name for name in SOURCE]
        + [payload / name for name in PAYLOAD] + [native / name for name in NATIVE]
        + [node, publication, manifest_path, typescript / 'node_modules/typescript/package.json',
           typescript / 'node_modules/typescript/lib/typescript.js']))
    files = [ident(path) for path in paths]
    return {'files': files, 'manifest': ident(manifest_path),
        'runtimeVersion': None if args.component_prefix else manifest['runtimeVersion'],
        'referenceRuntimeVersion': manifest['runtimeVersion'], 'componentPrefix': args.component_prefix,
        'selectedManifestReadback': checked, 'exactSourceOverrides': overrides,
        'sourceSelectionSHA256': hashlib.sha256(json.dumps([item for item in files if Path(item['path']).is_relative_to(source)],sort_keys=True,separators=(',', ':')).encode()).hexdigest(),
        'sourceCanonicalSHA256': None,
        'providers': {'local': ident(payload / 'node_modules/@deepseek-ai/dsh-fs-local/lib/index.js'),
                      'sandbox': ident(payload / 'node_modules/@deepseek-ai/dsh-fs-sandbox/lib/index.js')},
        'nativePair': [ident(native / name) for name in NATIVE],
        'scope': 'Selected inputs only. Four known component differences explicitly checked; no claim of a fresh complete-prefix audit or new composition.'}

FULL_HEX = '4142e4b8ade6968743440a'
FULL_DATA = list(bytes.fromhex(FULL_HEX))
FULL_SHA = hashlib.sha256(bytes.fromhex(FULL_HEX)).hexdigest()
result = {'schema': 1, 'startedUTC': utc(), 'executed': False, 'classification': 'SETUP_ERROR',
          'evidenceVerified': False, 'mode': 'jitless' if args.jitless else 'plain', 'ordinaryCases': 4}
try:
    pre = prepare_inputs()
    before = pre['files']
    for name in ['home', 'tmp', 'physical', 'linux-tools']:
        (O / name).mkdir(mode=0o700)
    cfg = {'source': str(source), 'payload': str(payload), 'nativeDirectory': str(native),
           'physical': str(O / 'physical'), 'result': str(O / 'REPORT.json'),
           'fsLocalSha256': pre['providers']['local']['sha256']}
    save('CONFIG.json', cfg)
    env = {'HOME': os.environ['HOME'], 'PATH': os.environ['PATH'], 'TMPDIR': str(O / 'tmp'), 'LANG': 'C.UTF-8',
           'LD_PRELOAD': str(native / 'libdsh_host.so') + ':' + str(publication),
           'DSH_HOME': str(O / 'home'), 'NARB_DISABLE_NATIVE_CACHE': '1',
           'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(native), 'DSH_GO_OHOS_LINUX_DIRECTORY': str(O / 'linux-tools'),
           'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony', 'OHOS_321_WHOLE_BYTES_CONFIG': str(O / 'CONFIG.json'),
           'OHOS_TYPESCRIPT_PREFIX': str(typescript),
           'OHOS_WORKSPACE_GRANTS_ADDON': str(native / 'workspace-publisher.node')}
    argv = [str(node), *(['--jitless'] if args.jitless else []), '--max-old-space-size=256', '--import', str(HERE / 'workspace-whole-bytes-instrumentation.mjs'),
            '--import', str(payload / 'runtime/ohos/preload.mjs'), '--import', str(HERE / 'workspace-whole-bytes-entry.mjs'),
            str(payload / 'node_modules/@deepseek-ai/dsh/lib/bin.js'), '--profile', 'web', '--dump-config']
    save('COMMAND.json', {'argv': argv, 'cwd': str(O), 'environment': env,
        'environmentSource': 'Explicit allowlist; executor HOME/PATH unchanged. No credentials or model endpoint.',
        'instrumentationAdds': {'DSH_GO_OHOS_SIM_ADDONS': [str(native / x) for x in [
            'libdsh_flock.so', 'libdsh_require_builtin.so', 'libdsh_workspace_grants.so', 'workspace-publisher.node']]},
        'scope': 'One selected-mode ordinary API component process: physical max11, physical max10, normal selected logical max11, logical max10; no range or codec. No HTTP/RPC or model call.'})
    save('INVOCATION.json', {'argv': [sys.executable, *sys.argv], 'cwd': str(Path.cwd()), 'atUTC': utc()})
    save('INPUTS.json', {'files': before, 'testFiles': [ident(HERE / name) for name in TESTS],
        'sourceCanonicalSHA256': pre['sourceCanonicalSHA256'], 'sourceSelectionSHA256': pre['sourceSelectionSHA256'], 'source': str(source), 'payload': str(payload),
        'componentPrefix': args.component_prefix, 'runtimeVersion': pre['runtimeVersion'], 'referenceRuntimeVersion': pre['referenceRuntimeVersion'],
        'manifest': pre['manifest'], 'selectedManifestReadback': pre['selectedManifestReadback'], 'exactSourceOverrides': pre['exactSourceOverrides'],
        'nativePair': pre['nativePair'], 'newCompose': False, 'newNativeBuild': False})
    started = time.monotonic(); timed_out = False; result['executed'] = True
    with (O / 'node.stdout').open('wb') as out, (O / 'node.stderr').open('wb') as err:
        try: code = subprocess.run(argv, cwd=O, env=env, stdout=out, stderr=err, timeout=90).returncode
        except subprocess.TimeoutExpired: code, timed_out = 124, True
    elapsed = time.monotonic() - started
    result.update(exitCode=code, seconds=elapsed, timeout=timed_out, childReturnedUTC=utc())
    after = [ident(item['path']) for item in pre['files']]
    result['inputsUnchanged'] = before == after
    save('SOURCE-AFTER.json', {'files': after, 'unchanged': before == after})
    report = json.loads((O / 'REPORT.json').read_text()) if (O / 'REPORT.json').is_file() else {}
    rows = report.get('cases', [])
    if before != after: classification = 'INPUT_DRIFT'
    elif timed_out: classification = 'TIMEOUT_UNCLASSIFIED'
    elif not report: classification = 'SETUP_ERROR_NO_REPORT'
    elif report.get('cleanupErrors') or any(x.get('cleanupErrors') for x in rows): classification = 'CLEANUP_FAILED'
    elif report.get('setupError') or any(x.get('setupError') for x in rows): classification = 'SETUP_ERROR'
    elif report.get('unexpectedError') or any(x.get('unexpectedError') for x in rows): classification = 'UNEXPECTED_RESULT_STOP'
    elif code != 0: classification = 'PROCESS_ERROR'
    else:
        assert len(rows) == 4
        assert report['diagnosticVerified'] and report['cleanupCompleted'] and report['targetCallCount'] == 4
        assert report['publicMethodsRestored'] and report['noSeparateDirectMapping'] and report['hostWorkspacesUnchanged']
        assert report['hostWorkspacesBefore'] == report['hostWorkspacesAfter'] == {'exists': False}
        assert report['nativeRetired']['active'] is False and report['nativeRetired']['leases'] == 0 and report['nativeRetired']['drained']
        assert report['published']['normalFileUriPath'] == '/storage/Users/currentUser/Projects/321-normal-whole-bytes'
        statuses = []
        for index, row in enumerate(rows):
            logical, limit = index >= 2, (10 if index % 2 else 11)
            directory, path, session_id = row['session']['headerCwd'], row['path'], row['session']['id']
            assert path == directory + '/byte-marker.bin'
            assert row['maxFileBytes'] == limit and row['logical'] == logical
            assert row['session']['type'] == 'Session' and row['session']['store'] == 'actual in-memory SessionStore'
            assert row['services'] == {'fs': 'SandboxedFileSystem', 'policy': 'SandboxPolicyService', 'sessions': 'SessionStore',
                                      'typert': 'TypertRegistry', 'workspaceFiles': 'WorkspaceFiles', 'mode': 'read-only'}
            assert row['lookup'] == {'key': 'workspaceFileScope', 'wire': 'workspaceFileScopeId', 'resource': 'session',
                                    'resolved': {'sessionId': session_id, 'workspaceRoot': directory}}
            assert row['policy']['mode'] == 'read-only' and row['policy']['workspaceRoot'] == directory
            assert row['arguments'] == {'workspaceFileScopeId': session_id, 'path': 'byte-marker.bin', 'options': {}, 'maxFileBytes': limit}
            assert row['independentVersion'] == version(row)
            assert row['fileBefore'] == row['fileAfterPrelude'] == row['fileAfterTargetAwait'] == row['fileAtFinalTeardown']
            assert row['fileBefore']['bytes'] == 11 and row['fileBefore']['hex'] == FULL_HEX
            assert row['fileBefore']['sha256'] == FULL_SHA and row['fileBefore']['mode'] == 0o600
            stat_value = {'absolutePath': path, 'version': version(row), 'bytes': 11}
            provider_stat = {'version': version(row), 'type': 'file', 'size': 11}
            target = {'displayPath': path, 'targetKey': path}
            scope = {'sessionId': session_id, 'workspaceRoot': directory}
            assert row['preludeActual'] == stat_value
            assert row['preludeCalls'] == [
                {'layer': 'api', 'method': 'stat', 'input': {'scope': scope, 'path': 'byte-marker.bin'},
                 'originalPromiseReturned': True, 'outcome': {'status': 'fulfilled', 'value': stat_value}},
                {'layer': 'provider', 'method': 'stat', 'input': {'target': target},
                 'originalPromiseReturned': True, 'outcome': {'status': 'fulfilled', 'value': provider_stat}}]
            success = {**stat_value, 'offset': 0, 'data': FULL_DATA, 'eof': True}
            cap = {'name': 'RemoteError', 'code': 'workspace-file/too-large',
                   'message': f'"byte-marker.bin" exceeds the {limit} byte full-file cap',
                   'details': {'path': 'byte-marker.bin', 'limit': limit}, 'isDSHRemoteError': True,
                   'cause': fs_error('FS_TOO_LARGE', f'cannot read "{path}": 11 bytes exceeds the {limit}-byte limit')}
            missing = fs_error('FS_NOT_FOUND', f'cannot read "{path}": not found')
            assert row['expectedSuccess'] == success and row['expectedCapError'] == cap
            assert row['oldLogicalFailurePrediction'] == missing
            status = row['status']; statuses.append(status)
            if status == 'PASS_FULL_BYTES':
                assert limit == 11 and row['targetReturned'] and row['contractPassed'] and row['dataIsUint8Array']
                assert row['result'] == success
                raw = row['rawResultJSON']; assert {k: v for k, v in raw.items() if k != 'data'} == {k: v for k, v in success.items() if k != 'data'}
                if row['dataIsBuffer']: assert raw['data'] == {'type': 'Buffer', 'data': FULL_DATA}
                else: assert raw['data'] == {str(i): v for i, v in enumerate(FULL_DATA)}
                api_outcome, provider_outcome = {'status': 'fulfilled', 'value': success}, {'status': 'fulfilled', 'value': FULL_DATA}
            elif status == 'PASS_CAP_REFUSAL':
                assert limit == 10 and row['targetRejected'] and row['contractPassed']
                assert row['actualError']['stable'] == cap and row['actualError']['cause']['stable'] == cap['cause']
                assert row['actualError']['ownPropertyNames'] == ['cause', 'code', 'details', 'isDSHRemoteError', 'message', 'name', 'stack']
                assert row['actualError']['cause']['ownPropertyNames'] == ['code', 'message', 'name', 'stack']
                api_outcome, provider_outcome = {'status': 'rejected', 'error': cap}, {'status': 'rejected', 'error': cap['cause']}
            elif status == 'BEHAVIOR_RED_READ_BYTES':
                assert logical and row['targetRejected'] and row['contractPassed'] is False
                assert row['actualError']['stable'] == missing and row['actualError']['cause'] is None
                assert row['actualError']['ownPropertyNames'] == ['code', 'message', 'name', 'stack']
                api_outcome = provider_outcome = {'status': 'rejected', 'error': missing}
            else: raise AssertionError('Unexpected case classification ' + status)
            assert row['publicCalls'] == [
                {'layer': 'api', 'method': 'readBytes', 'input': {'scope': scope, 'path': 'byte-marker.bin', 'options': {}, 'maxFileBytes': limit},
                 'originalPromiseReturned': True, 'outcome': api_outcome},
                {'layer': 'provider', 'method': 'stat', 'input': {'target': target},
                 'originalPromiseReturned': True, 'outcome': {'status': 'fulfilled', 'value': provider_stat}},
                {'layer': 'provider', 'method': 'readBytes', 'input': {'target': target, 'maxBytes': limit},
                 'originalPromiseReturned': True, 'outcome': provider_outcome}]
            assert row['diagnosticVerified'] and row['completeObjectAndCallsVerified'] and row['preludePassed']
            assert row['targetAwaitSettled'] and row['targetEntered'] and row['targetEntryCount'] == row['providerEntryCount'] == 1
            assert row['readByteRangeEntered'] is False and row['fileUnchanged'] and row['contextDisposed']
            if logical:
                for key in ['nativeBefore', 'nativeBeforeTarget', 'nativeAfterTargetAwait', 'nativeAfterContextDispose']:
                    assert row[key]['active'] is True and row[key]['leases'] == 0
                assert row['borrowedFDsAfterTargetAwait'] == row['borrowedFDsAfterContextDispose'] == 0
        assert statuses[:2] == ['PASS_FULL_BYTES', 'PASS_CAP_REFUSAL']
        if statuses[2:] == ['BEHAVIOR_RED_READ_BYTES', 'BEHAVIOR_RED_READ_BYTES']:
            classification = 'TWO_PHYSICAL_PASS_TWO_LOGICAL_BEHAVIOR_RED'
            assert report['contractPassCount'] == 2 and report['behaviorRedCount'] == 2 and report['pass'] is False
        elif statuses[2:] == ['PASS_FULL_BYTES', 'PASS_CAP_REFUSAL']:
            classification = 'ALL_FOUR_CONTRACTS_PASS'
            assert report['contractPassCount'] == 4 and report['behaviorRedCount'] == 0 and report['pass'] is True
        else: raise AssertionError('Unexpected mixed logical outcomes')
        result['evidenceVerified'] = True
    result['classification'] = classification
    result['cases'] = [{key: row.get(key) for key in ['name', 'status', 'maxFileBytes', 'contractPassed', 'diagnosticVerified', 'targetEntered', 'providerEntryCount', 'readByteRangeEntered', 'contextDisposed']} for row in rows]
    result['cleanupCompleted'] = report.get('cleanupCompleted', False)
    result['report'] = ident(O / 'REPORT.json') if (O / 'REPORT.json').is_file() else None
except Exception as error:
    result['error'] = {'name': type(error).__name__, 'message': str(error)}
    result['classification'] = 'UNEXPECTED_COORDINATOR_ERROR' if result['executed'] else 'SETUP_ERROR'
result['endedUTC'] = utc()
result['coordinatorExitCode'] = 0 if result['classification'] == 'ALL_FOUR_CONTRACTS_PASS' else 1 if result['evidenceVerified'] else 2
save('RESULT.json', result)
print(json.dumps(result, ensure_ascii=False))
raise SystemExit(result['coordinatorExitCode'])
