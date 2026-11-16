#!/usr/bin/env python3
from pathlib import Path
import argparse, datetime, hashlib, json, os, stat, subprocess, sys, time

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description='After-only default whole-write: two existing-file cases; official composed inputs or explicitly bound component inputs')
for name in ['source', 'payload', 'node', 'typescript-prefix', 'native-directory', 'publication-fixture', 'out', 'manifest']:
    parser.add_argument('--' + name, required=True, type=Path)
parser.add_argument('--oracle', type=Path, default=HERE / 'workspace-write-existing-oracle.json')
parser.add_argument('--candidate-inputs', type=Path, help='Required in component mode: exact source/payload/native input receipt; optional additional binding in formal mode')
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
TESTS = ['workspace-write-existing-entry.py', 'workspace-write-existing-entry.mjs', 'workspace-write-existing-instrumentation.mjs']
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
    'dsh-lazy-require', 'dsh-working-directory', 'dsh-tools', 'dsh-tool-executor-native', 'dsh-tool-fs',
]] + ['node_modules/@deepseek-ai/' + name + '/package.json' for name in [
    'dsh-working-directory', 'dsh-tools', 'dsh-tool-executor-native', 'dsh-tool-fs',
]]

def utc(): return datetime.datetime.now(datetime.timezone.utc).isoformat()
def ident(path):
    p = Path(path)
    with p.open('rb') as f: digest = hashlib.file_digest(f, 'sha256').hexdigest()
    return {'path': str(p), 'bytes': p.stat().st_size, 'sha256': digest, 'mode': format(stat.S_IMODE(p.stat().st_mode), '04o')}
def save(name, value): (O / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
def version(state, grant=None):
    x = state['exactStat']
    if not grant: return ':'.join(x[k] for k in ['dev', 'ino', 'size', 'mtimeNs', 'ctimeNs'])
    ms, mn = divmod(int(x['mtimeNs']), 1_000_000_000)
    cs, cn = divmod(int(x['ctimeNs']), 1_000_000_000)
    return ':'.join(['ohos-grant', grant['id'], str(grant['generation']), x['dev'], x['ino'], x['size'], str(ms), str(mn), str(cs), str(cn)])
class PreparationBlocked(Exception): pass

def prepare_inputs():
    oracle = json.loads(args.oracle.read_text())
    candidate = json.loads(args.candidate_inputs.read_text()) if args.candidate_inputs else None
    if args.component_prefix and candidate is None:
        raise PreparationBlocked('Component mode requires an explicit exact candidate input receipt')
    if oracle.get('scope') != 'existing-only-after' or oracle.get('cases') != [
            {'name': 'physical-existing', 'logical': False, 'existing': True, 'filename': 'existing.txt'},
            {'name': 'logical-existing', 'logical': True, 'existing': True, 'filename': 'existing.txt'}]:
        raise PreparationBlocked('This runner admits exactly the two frozen existing-file cases')
    if candidate is not None:
        if candidate.get('status') != 'FROZEN_AFTER_CANDIDATE' or not candidate.get('sourceContractReference') or not candidate.get('sourceClosure'):
            raise PreparationBlocked('Frozen candidate receipt lacks the existing-only source closure')
        if any(Path(candidate.get(key, '')).resolve() != expected for key, expected in [('source', source), ('payload', payload), ('nativeDirectory', native)]):
            raise PreparationBlocked('Candidate paths do not bind these inputs')
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
    # Input safety guard only: never run the old unconnected logical write as a baseline.
    for name in provider_names:
        if ident(payload / name)['sha256'] != final_pins[name]['sha256']:
            raise PreparationBlocked('Provider must match the current source final OH pin: ' + name)
    writer_relative = 'runtime/ohos/process/files/workspace-edit.mjs'
    writer_source, writer_payload = ident(source / writer_relative), ident(payload / writer_relative)
    if any(writer_source[key] != writer_payload[key] for key in ['sha256', 'bytes', 'mode']):
        raise PreparationBlocked('Private writer must match current source bytes and mode')
    local_text = (payload / 'node_modules/@deepseek-ai/dsh-fs-local/lib/index.js').read_text()
    sandbox_text = (payload / 'node_modules/@deepseek-ai/dsh-fs-sandbox/lib/index.js').read_text()
    local_write = local_text.partition('async writeText(')[2].partition('async editText(')[0]
    sandbox_write = sandbox_text.partition('async writeText(')[2].partition('async editText(')[0]
    closure_checks = {
        'localScopedWrite': 'withWorkspace' in local_write and 'io.writeWhole(' in local_write,
        'sandboxFreshPolicy': 'const fresh = await this.checkedTarget(target, policy);' in sandbox_write
            and 'super.writeText(fresh, content, expected, signal, ohosWorkspaceEdit?.workspaceEditScope(fresh, policy, signal))' in sandbox_write,
        'privateWriteWhole': 'async function writeWhole(' in (source / writer_relative).read_text(),
    }
    if not all(closure_checks.values()):
        raise PreparationBlocked('Existing-only logical whole-write source closure is absent; no Node process started')
    input_receipt = ident(args.candidate_inputs.resolve()) if args.candidate_inputs else {
        'basis': 'actual composer manifest plus current source final OH pins and exact writer',
        'manifest': ident(manifest_path), 'pins': ident(pins_path), 'writer': writer_source,
        'closureChecks': closure_checks,
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
                'scope': 'prepared source-derived deletion companion, not the composed OH variant' if name.endswith('dsh-go-deletion.mjs') else 'exact private writer source'})
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
    if candidate is not None:
        bindings = {str(Path(item['path']).resolve()): item for item in candidate.get('files', [])}
        if len(bindings) != len(candidate.get('files', [])): raise PreparationBlocked('Duplicate candidate input identities')
        # Product receipt membership only: does not supply authority or substitute for source review.
        product_paths = [source / name for name in SOURCE] + [payload / name for name in PAYLOAD] + [native / name for name in NATIVE] + [publication]
        for path in product_paths:
            expected = bindings.get(str(path.resolve()))
            actual = ident(path)
            if expected is None or any(actual[key] != expected.get(key) for key in ['sha256', 'bytes', 'mode']):
                raise PreparationBlocked('Candidate receipt does not bind selected product input: ' + str(path))
    files += [ident(args.oracle.resolve())]
    if args.candidate_inputs: files.append(ident(args.candidate_inputs.resolve()))
    return {'files': files, 'manifest': ident(manifest_path),
        'runtimeVersion': None if args.component_prefix else manifest['runtimeVersion'],
        'referenceRuntimeVersion': manifest['runtimeVersion'], 'componentPrefix': args.component_prefix,
        'selectedManifestReadback': checked, 'exactSourceOverrides': overrides,
        'sourceSelectionSHA256': hashlib.sha256(json.dumps([item for item in files if Path(item['path']).is_relative_to(source)],sort_keys=True,separators=(',', ':')).encode()).hexdigest(),
        'sourceCanonicalSHA256': None,
        'oracle': oracle, 'candidateInputReceipt': input_receipt, 'sourceClosureChecks': closure_checks,
        'providers': {'local': ident(payload / 'node_modules/@deepseek-ai/dsh-fs-local/lib/index.js'),
                      'sandbox': ident(payload / 'node_modules/@deepseek-ai/dsh-fs-sandbox/lib/index.js')},
        'nativePair': [ident(native / name) for name in NATIVE],
        'scope': 'Selected inputs only. Four known component differences explicitly checked; no claim of a fresh complete-prefix audit or new composition.'}


BEFORE = 'FIRST\n'
AFTER = 'SECOND\n'
NAMES = ['physical-existing', 'logical-existing']
def check_file(snapshot, text, mode):
    value = text.encode()
    assert snapshot['exists'] is True and snapshot['bytes'] == len(value)
    assert snapshot['hex'] == value.hex() and snapshot['sha256'] == hashlib.sha256(value).hexdigest()
    assert snapshot['mode'] == mode and snapshot['exactStat']['size'] == str(len(value))
def batch(call_id, result): return {'results': [{'callId': call_id, 'result': result}], 'additionalContexts': [], 'concluded': False}
def observation(call_id, path, token): return {'callId': call_id, 'target': {'displayPath': path, 'targetKey': path}, 'observed': {'kind': 'present', 'version': token}}
def validate_report(report, oracle):
    assert report['mode'] == 'after-only' and report['pass'] and report['cleanupCompleted']
    assert report['writeBatchCount'] == 2 and report['readBatchCount'] == 2
    assert report['hostWorkspacesBefore'] == report['hostWorkspacesAfter'] == {'exists': False}
    assert report['hostWorkspacesUnchanged'] and report['noSeparateDirectMapping'] and report['publicMethodsRestored']
    assert report['nativeRetired']['active'] is False and report['nativeRetired']['leases'] == 0 and report['nativeRetired']['drained']
    assert report['published']['normalFileUriPath'] == '/storage/Users/currentUser/Projects/whole-write-existing-after'
    assert len(report['cases']) == 2
    expected_observations = []
    for index, row in enumerate(report['cases']):
        logical, existing = index == 1, True
        assert row['name'] == NAMES[index] and row['logical'] == logical and row['existing'] == existing
        assert row['status'] == 'PASS' and row['pass'] and row['completeOraclePassed'] and row['targetEntered'] and row['contextDisposed']
        assert not row['cleanupErrors'] and not row.get('setupError') and not row.get('unexpectedError')
        directory, path, sid = row['session']['headerCwd'], row['path'], row['session']['id']
        filename = 'existing.txt'
        assert row['filename'] == filename and path == directory + '/' + filename
        assert row['arguments'] == {'file_path': filename, 'content': AFTER}
        assert row['toolConfig'] == {'applyPatch': False} and row['actualWriteIntent'] == {'present': False}
        assert row['session']['type'] == 'Session' and row['session']['store'] == 'actual in-memory SessionStore'
        policy = {'mode': 'workspace-write', 'workspaceRoot': directory, 'sessionId': sid}
        assert row['policy'] == policy and row['ensure'] == directory
        assert row['services'] == {'fs': 'SandboxedFileSystem', 'policy': 'SandboxPolicyService', 'executor': 'NativeToolExecutor', 'tools': 'ToolsService',
                                  'directory': 'WorkingDirectoryService', 'sessions': 'SessionStore', 'projections': 'SessionProjectionRegistry', 'mode': 'workspace-write'}
        grant = row.get('grant')
        if logical: assert grant['mountPoint'] == directory and grant['writable'] is True
        else: assert grant is None
        target = {'displayPath': path, 'targetKey': path}
        check_file(row['fileBefore'], BEFORE, 0o644)
        assert row['fileAfterRead'] == row['fileBeforeWrite'] == row['fileBefore']
        token = version(row['fileBefore'], grant)
        assert row['independentReadVersion'] == token and row['readPreludePassed'] and row['readBatchReturned']
        read_value = {'path': path, 'offset': 1, 'lines': [{'number': 1, 'text': 'FIRST'}], 'totalLines': 1}
        result = {'isError': False, 'content': [{'type': 'text', 'text': f'<path>{path}</path>\n<type>file</type>\n<content>\n1: FIRST\n\n(End of file - total 1 lines)\n</content>'}],
                  'meta': read_value, 'value': read_value}
        assert row['readId'] == 'read-' + row['name'] and row['readBatch'] == batch(row['readId'], result)
        assert row['readCalls'] == [{'layer': 'local', 'method': 'readText', 'input': {'target': target}, 'originalPromiseReturned': True,
                                     'outcome': {'status': 'fulfilled', 'value': BEFORE}}]
        ob = observation(row['readId'], path, token); assert row['readObservation'] == ob; expected_observations.append(ob)
        check_file(row['fileAfterWrite'], AFTER, 0o644)
        assert row['fileAfterWrite'] == row['fileAtCaseExit'] == row['fileAtFinalTeardown']
        token = version(row['fileAfterWrite'], grant); assert row['independentWriteVersion'] == token
        assert token != row['independentReadVersion']
        operation = 'update'
        provider = {'operation': operation, 'version': token, 'before': BEFORE, 'after': AFTER}
        inp = {'target': target, 'content': AFTER, 'intent': {'present': False}}
        assert row['writeCalls'] == [
            {'layer': 'sandbox', 'method': 'writeText', 'input': {**inp, 'policy': policy}, 'originalPromiseReturned': True, 'outcome': {'status': 'fulfilled', 'value': provider}},
            {'layer': 'local', 'method': 'writeText', 'input': inp, 'originalPromiseReturned': True, 'outcome': {'status': 'fulfilled', 'value': provider}}]
        value = {'path': path, 'operation': operation, 'before': BEFORE, 'after': AFTER}
        meta = {'operation': operation, 'path': path, 'diffs': [{'path': path, 'oldText': 'FIRST', 'newText': 'SECOND'}]}
        word = 'Updated'
        result = {'isError': False, 'content': [{'type': 'text', 'text': f'<path>{path}</path>\n<type>file</type>\n<content>\n{word} file\n</content>'}], 'meta': meta, 'value': value}
        assert row['writeId'] == 'write-' + row['name'] and row['writeBatch'] == batch(row['writeId'], result)
        assert row['writeBatchReturned'] and row['writeCallStarted']
        ob = observation(row['writeId'], path, token); assert row['writeObservation'] == ob; expected_observations.append(ob)
        if logical:
            for key in ['nativeBefore', 'nativeAfterWriteAwait', 'nativeAfterContextDispose']:
                assert row[key]['active'] is True and row[key]['leases'] == 0
                assert row[key]['generation'] == row['nativeBefore']['generation']
            assert row['borrowedAfterWriteAwait'] == row['borrowedAfterContextDispose'] == 0
    assert report['observations'] == expected_observations

result = {'schema': 1, 'startedUTC': utc(), 'executed': False, 'classification': 'SETUP_ERROR', 'mode': 'jitless' if args.jitless else 'plain',
          'evidenceVerified': False, 'ordinaryCases': 2, 'scope': 'after-only; never old logical baseline'}
try:
    pre = prepare_inputs(); before = pre['files']; oracle = pre['oracle']
    assert oracle['before'] == BEFORE and oracle['after'] == AFTER and oracle['existingMode'] == 0o644
    assert [row['name'] for row in oracle['cases']] == NAMES
    for name in ['home', 'tmp', 'physical-existing', 'linux-tools']: (O / name).mkdir(mode=0o700)
    cfg = {'source': str(source), 'payload': str(payload), 'nativeDirectory': str(native), 'result': str(O / 'REPORT.json'),
           'physical': [str(O / 'physical-existing')], 'oracle': str(args.oracle.resolve()),
           'candidateInputReceipt': pre['candidateInputReceipt']}
    save('CONFIG.json', cfg)
    env = {'HOME': os.environ['HOME'], 'PATH': os.environ['PATH'], 'TMPDIR': str(O / 'tmp'), 'LANG': 'C.UTF-8',
           'LD_PRELOAD': str(native / 'libdsh_host.so') + ':' + str(publication), 'DSH_HOME': str(O / 'home'), 'NARB_DISABLE_NATIVE_CACHE': '1',
           'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(native), 'DSH_GO_OHOS_LINUX_DIRECTORY': str(O / 'linux-tools'),
           'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony', 'OHOS_WHOLE_WRITE_EXISTING_CONFIG': str(O / 'CONFIG.json'),
           'OHOS_TYPESCRIPT_PREFIX': str(typescript), 'OHOS_WORKSPACE_GRANTS_ADDON': str(native / 'workspace-publisher.node')}
    argv = [str(node), *(['--jitless'] if args.jitless else []), '--max-old-space-size=256', '--import', str(HERE / 'workspace-write-existing-instrumentation.mjs'),
            '--import', str(payload / 'runtime/ohos/preload.mjs'), '--import', str(HERE / 'workspace-write-existing-entry.mjs'),
            str(payload / 'node_modules/@deepseek-ai/dsh/lib/bin.js'), '--profile', 'web', '--dump-config']
    save('COMMAND.json', {'argv': argv, 'cwd': str(O), 'environment': env,
        'environmentSource': 'Explicit allowlist; HOME/PATH remain the executor values; no accounts/model endpoint',
        'instrumentationAdds': {'DSH_GO_OHOS_SIM_ADDONS': [str(native / x) for x in ['libdsh_flock.so', 'libdsh_require_builtin.so', 'libdsh_workspace_grants.so', 'workspace-publisher.node']]}})
    save('INVOCATION.json', {'argv': [sys.executable, *sys.argv], 'cwd': str(Path.cwd()), 'atUTC': utc()})
    save('INPUTS.json', {**pre, 'files': before, 'newCompose': False, 'newNativeBuild': False,
        'oracleValidation': 'Coordinator recomputes exact result from independent actor fs snapshots; this is not a second filesystem measurement.'})
    timed_out = False; result['executed'] = True; started = time.monotonic()
    with (O / 'node.stdout').open('wb') as out, (O / 'node.stderr').open('wb') as err:
        try:
            code = subprocess.run(argv, cwd=O, env=env, stdout=out, stderr=err, timeout=90).returncode
            elapsed = time.monotonic() - started
            child_returned_utc = utc()
        except subprocess.TimeoutExpired:
            elapsed = time.monotonic() - started
            child_returned_utc = utc()
            code, timed_out = 124, True
    result.update(exitCode=code, seconds=elapsed, timeout=timed_out, childReturnedUTC=child_returned_utc)
    after = [ident(row['path']) for row in before]; result['inputsUnchanged'] = before == after
    save('SOURCE-AFTER.json', {'files': after, 'unchanged': before == after})
    report = json.loads((O / 'REPORT.json').read_text()) if (O / 'REPORT.json').is_file() else {}
    rows = report.get('cases', [])
    if before != after: classification = 'INPUT_DRIFT'
    elif timed_out: classification = 'TIMEOUT_UNCLASSIFIED'
    elif not report: classification = 'SETUP_ERROR_NO_REPORT'
    elif report.get('cleanupErrors') or any(row.get('cleanupErrors') for row in rows): classification = 'CLEANUP_FAILED'
    elif report.get('setupError') or any(row.get('setupError') for row in rows): classification = 'SETUP_ERROR'
    elif report.get('unexpectedError') or any(row.get('unexpectedError') for row in rows): classification = 'UNEXPECTED_RESULT_STOP'
    elif code != 0: classification = 'PROCESS_ERROR'
    else:
        validate_report(report, oracle); classification = 'TWO_EXISTING_AFTER_CONTRACTS_PASS'; result['evidenceVerified'] = True
    result['classification'] = classification
    result['cases'] = [{key: row.get(key) for key in ['name', 'status', 'pass', 'targetEntered', 'completeOraclePassed', 'contextDisposed']} for row in rows]
    result['cleanupCompleted'] = report.get('cleanupCompleted', False)
    result['report'] = ident(O / 'REPORT.json') if (O / 'REPORT.json').is_file() else None
except PreparationBlocked as error:
    result.update(classification='SETUP_BLOCKED', error={'name': type(error).__name__, 'message': str(error)})
except Exception as error:
    result.update(classification='UNEXPECTED_COORDINATOR_ERROR' if result['executed'] else 'SETUP_ERROR', error={'name': type(error).__name__, 'message': str(error)})
result['endedUTC'] = utc(); result['coordinatorExitCode'] = 0 if result['evidenceVerified'] else 2
save('RESULT.json', result); print(json.dumps(result, ensure_ascii=False)); raise SystemExit(result['coordinatorExitCode'])
