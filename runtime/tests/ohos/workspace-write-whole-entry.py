#!/usr/bin/env python3
from pathlib import Path
import argparse, datetime, hashlib, json, os, stat, subprocess, sys, time

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description='Four ordinary whole-write after cases; formal authority build or exact component inputs')
for name in ['source', 'payload', 'node', 'typescript-prefix', 'native-directory', 'publication-fixture', 'out', 'manifest']:
    parser.add_argument('--' + name, required=True, type=Path)
parser.add_argument('--oracle', type=Path, default=HERE / 'workspace-write-whole-oracle.json')
parser.add_argument('--candidate-inputs', type=Path, help='Required only in component mode')
parser.add_argument('--native-build-receipt', type=Path, help='Original same-source new whole-group receipt; component mode only')
parser.add_argument('--authority-build-directory', type=Path, help='Formal workspace-authority-entry output with BUILD.json and INPUTS.json')
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
TESTS = ['workspace-write-whole-entry.py', 'workspace-write-whole-entry.mjs', 'workspace-write-whole-instrumentation.mjs']
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
    'runtime/tests/ohos/workspace-authority-entry.py',
    'app/ohos/entry/src/main/cpp/workspace_grants.h', 'app/ohos/entry/src/main/cpp/workspace_grants.cpp',
    'app/ohos/entry/src/main/cpp/workspace_grants_abi.h', 'runtime/ohos/process/files/addon.cc',
    'app/ohos/entry/src/main/cpp/workspace_fids.h', 'app/ohos/entry/src/main/cpp/workspace_fids_abi.h',
    'runtime/tests/ohos/workspace-grants-addon.cc',
]
NATIVE_SOURCES = SOURCE[-7:]
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


def same_record(path, row):
    actual = ident(Path(path).resolve())
    if not isinstance(row, dict) or Path(row.get('path', '')).resolve() != Path(actual['path']):
        raise PreparationBlocked('Recorded input path does not bind ' + str(path))
    if (actual['sha256'], actual['bytes'], int(actual['mode'], 8)) != (row.get('sha256'), row.get('bytes'), int(row.get('mode', '-1'), 8)):
        raise PreparationBlocked('Recorded input bytes/mode changed: ' + str(path))
    return actual

def row_map(rows):
    result = {str(Path(row['path']).resolve()): row for row in rows}
    if len(result) != len(rows): raise PreparationBlocked('Duplicate recorded input paths')
    return result

def component_native():
    if args.authority_build_directory or not args.native_build_receipt:
        raise PreparationBlocked('Component mode requires its original Native receipt, not a formal authority directory')
    build = json.loads(args.native_build_receipt.read_text())
    if build.get('schema') != 1 or build.get('status') != 'FROZEN_SAME_SOURCE_WHOLE_WRITE_V1_BUILD':
        raise PreparationBlocked('New same-source Native build receipt is not ready')
    if Path(build.get('nativeDirectory', '')).resolve() != native:
        raise PreparationBlocked('Native directory does not match the original build receipt')
    origin = Path(build['source']).resolve()
    native_rows = {Path(row['path']).name: row for row in build.get('nativeFiles', [])}
    if set(native_rows) != set(NATIVE) or len(build.get('nativeFiles', [])) != len(NATIVE):
        raise PreparationBlocked('Five real Native identities are required')
    for name in NATIVE: same_record(native / name, native_rows[name])
    for name, output in [('host','libdsh_host.so'), ('consumer','libdsh_workspace_grants.so'), ('publisher','workspace-publisher.node')]:
        row = build.get('builds', {}).get(name, {})
        if row.get('exitCode') != 0 or row.get('inputsUnchanged') is not True or row.get('artifact') != native_rows[output]:
            raise PreparationBlocked('Successful original same-source build evidence is missing for ' + name)
    if build.get('publisherNeededHost') != 'libdsh_host.so' or build.get('publisherRunpath') != str(native):
        raise PreparationBlocked('Publisher must link to the same new host registry')
    required = ['whole_output_begin_v1','whole_output_write_v1','whole_output_close_v1','whole_output_publish_step_v1','whole_output_abort_v1']
    if not all('dsh_workspace_' + name in build.get('hostExportedSymbols', []) for name in required):
        raise PreparationBlocked('Original new whole-group exported-symbol evidence is incomplete')
    bindings = row_map(build.get('sourceFiles', [])); mapped = []
    if set(bindings) != {str(origin / name) for name in NATIVE_SOURCES}:
        raise PreparationBlocked('Original receipt must bind exactly the seven Native source inputs')
    for name in NATIVE_SOURCES:
        original = same_record(origin / name, bindings[str(origin / name)])
        current = ident(source / name)
        if any(current[key] != original[key] for key in ['bytes','sha256','mode']):
            raise PreparationBlocked('Current Native source differs from original build: ' + name)
        mapped.append({'relative':name,'builtSource':original,'currentSource':current})
    same_record(publication, build['publication'])
    evidence = build.get('evidence', [])
    if not evidence: raise PreparationBlocked('Original compile/symbol/ELF evidence is required')
    extra = [ident(args.native_build_receipt.resolve())]
    for row in [*evidence, *build.get('headerInputs', [])]: extra.append(same_record(row['path'], row))
    return {'mode':'component-original-native-receipt','receipt':ident(args.native_build_receipt.resolve()),
            'builtSource':str(origin),'currentSource':str(source),'sameSevenNativeSourceBytes':mapped,
            'publisherLinkageBasis':'Original successful build and ELF records; exact same native directory',
            'files':extra}

def formal_native():
    if args.candidate_inputs or args.native_build_receipt or not args.authority_build_directory:
        raise PreparationBlocked('Formal mode requires --authority-build-directory and no private candidate/Native receipt')
    directory = args.authority_build_directory.resolve()
    if native != directory / 'native':
        raise PreparationBlocked('Formal Native directory must be this authority build output/native')
    build_path, inputs_path = directory / 'BUILD.json', directory / 'INPUTS.json'
    builds, inputs = json.loads(build_path.read_text()), json.loads(inputs_path.read_text())
    if Path(inputs.get('source', '')).resolve() != source:
        raise PreparationBlocked('Authority build did not use this current source tree')
    if not isinstance(builds, list) or len(builds) != 3 or {row['name'] for row in builds} != {'host','consumer','publisher'}:
        raise PreparationBlocked('Three actual authority build command records are required')
    libraries = row_map(inputs['libraries'])
    if set(libraries) != {str(native / name) for name in NATIVE}:
        raise PreparationBlocked('Authority input receipt must bind exactly the five current libraries')
    for name in NATIVE: same_record(native / name, libraries[str(native / name)])
    sources = row_map(inputs['nativeSources'])
    if set(sources) != {str(source / name) for name in NATIVE_SOURCES}:
        raise PreparationBlocked('Authority input receipt must bind exactly the seven current Native source files')
    for name in NATIVE_SOURCES: same_record(source / name, sources[str(source / name)])
    for path, row in [(manifest_path,inputs['payloadManifest']), (node,inputs['node']), (publication,inputs['publication'])]:
        same_record(path,row)
    extra = [ident(build_path), ident(inputs_path)]
    authority_products = {'runtime/ohos/preload.mjs', 'runtime/ohos/process/runtime.mjs',
                          'runtime/ohos/process/worker.mjs', 'runtime/ohos/process/files/process-authority.mjs'}
    if set(inputs['productFiles']) != authority_products:
        raise PreparationBlocked('Authority receipt must bind its four current production files')
    for name, row in inputs['productFiles'].items():
        actual = same_record(payload / name, row); origin = ident(source / name)
        if any(actual[key] != origin[key] for key in ['bytes','sha256','mode']):
            raise PreparationBlocked('Authority product file differs from current source: ' + name)
        extra += [actual, origin]
    by_name = {row['name']:row for row in builds}
    common = ['-std=c++17','-pthread','-shared','-fPIC','-Wall','-Wextra','-Werror']
    compiler = by_name['host']['argv'][0]
    consumer_argv = by_name['consumer']['argv']
    if len(consumer_argv) < 10 or consumer_argv[8] != '-I':
        raise PreparationBlocked('Authority consumer is missing its actual Node header directory')
    headers = Path(consumer_argv[9])
    if not headers.is_absolute(): raise PreparationBlocked('Authority Node header input must be absolute')
    tails = {
        'host':[str(source/'app/ohos/entry/src/main/cpp/workspace_grants.cpp'),'-o',str(native/'libdsh_host.so')],
        'consumer':['-I',str(headers),str(source/'runtime/ohos/process/files/addon.cc'),'-ldl','-o',str(native/'libdsh_workspace_grants.so')],
        'publisher':['-I',str(headers),str(source/'runtime/tests/ohos/workspace-grants-addon.cc'),'-L',str(native),'-ldsh_host','-Wl,-rpath,'+str(native),'-o',str(native/'workspace-publisher.node')],
    }
    for name in ['host','consumer','publisher']:
        row = by_name[name]
        if row.get('exitCode') != 0 or row['argv'] != [compiler,*common,*tails[name]]:
            raise PreparationBlocked('Authority build command/output/linkage differs from the current recipe: ' + name)
        extra += [ident(directory/(name+'.stdout')), ident(directory/(name+'.stderr'))]
    for name in ['node_version.h','node_api.h','js_native_api.h']: extra.append(ident(headers/name))
    header = (headers/'node_version.h').read_text()
    import re
    if any(re.search(r'^#define NODE_'+key+r'_VERSION\s+'+str(value)+r'\s*$',header,re.M) is None for key,value in [('MAJOR',24),('MINOR',22),('PATCH',1)]):
        raise PreparationBlocked('Authority compilation headers are not Node 24.22.1')
    return {'mode':'formal-authority-build','directory':str(directory),'buildReceipt':ident(build_path),'inputReceipt':ident(inputs_path),
            'actualBuildCommands':builds,'publisherLinkageBasis':'Actual exit0 publisher argv binds -L, -ldsh_host and rpath to this same native directory; no new ELF scan in this runner',
            'headerObservation':'Current header identity; authority BUILD records its path, not an earlier header SHA',
            'files':extra}

def prepare_inputs():
    oracle = json.loads(args.oracle.read_text())
    if oracle.get('newFileMode') != {'policy':'directory-default','requestedMode':0o666,
            'oracle':'independent same-parent Node wx creation; mode and gid, not ACL contents'}:
        raise PreparationBlocked('The frozen directory-default oracle does not match')
    candidate = None
    if args.component_prefix:
        if not args.candidate_inputs: raise PreparationBlocked('Component mode requires the exact current candidate receipt')
        candidate = json.loads(args.candidate_inputs.read_text())
        if candidate.get('status') != 'FROZEN_SOURCE_NEW_WHOLE_NATIVE_BOUND' or not candidate.get('sourceClosure'):
            raise PreparationBlocked('Exact new source closure is not bound; no Node process started')
        for key, expected in [('source',source),('payload',payload),('nativeDirectory',native)]:
            if Path(candidate.get(key,'')).resolve() != expected: raise PreparationBlocked('Candidate does not bind '+key)
    if os.path.lexists('/workspaces'):
        raise PreparationBlocked('Host /workspaces must be absent for these ordinary logical-coordinate cases')
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('schema') != 1 or not isinstance(manifest.get('runtimeVersion'),str) or not manifest['runtimeVersion'] or manifest.get('nodeVersion') != '24.22.1':
        raise PreparationBlocked('An actual Node24.22.1 composer manifest with runtimeVersion is required')
    records = {item['path']:item for item in manifest['files']}
    if len(records) != len(manifest['files']): raise PreparationBlocked('Duplicate manifest paths')
    pins_path = source/'runtime/patches/pins.json'; pins=json.loads(pins_path.read_text())
    dsh_version=json.loads((payload/'node_modules/@deepseek-ai/dsh/package.json').read_text())['version']
    if manifest.get('dshVersion') != dsh_version: raise PreparationBlocked('Manifest DSH version mismatch')
    final_pins={}
    for patch in pins['targetSets']['ohos']:
        for name,value in pins['patches'][patch][dsh_version].items(): final_pins[name]={'sha256':value['after'],'patch':patch}
    provider_names={'node_modules/@deepseek-ai/dsh-fs-local/lib/index.js','node_modules/@deepseek-ai/dsh-fs-sandbox/lib/index.js'}
    source_overrides={
        'runtime/ohos/process/files/workspace-edit.mjs':'runtime/ohos/process/files/workspace-edit.mjs',
        'node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/dsh-go-deletion.mjs':'runtime/session-deletion/core.mjs',
    }
    # Admission before Node: hashes plus current connection shape, never a behavior verdict.
    for name in provider_names:
        if ident(payload/name)['sha256'] != final_pins[name]['sha256']:
            raise PreparationBlocked('Provider is not the current final OH pin: '+name)
    writer_relative='runtime/ohos/process/files/workspace-edit.mjs'
    writer_source,writer_payload=ident(source/writer_relative),ident(payload/writer_relative)
    if any(writer_source[k] != writer_payload[k] for k in ['bytes','sha256','mode']):
        raise PreparationBlocked('Writer must equal the current source bytes/mode')
    local=(payload/'node_modules/@deepseek-ai/dsh-fs-local/lib/index.js').read_text()
    sandbox=(payload/'node_modules/@deepseek-ai/dsh-fs-sandbox/lib/index.js').read_text()
    local_write=local.partition('async writeText(')[2].partition('async editText(')[0]
    sandbox_write=sandbox.partition('async writeText(')[2].partition('async editText(')[0]
    writer=(source/writer_relative).read_text(); addon=(source/'runtime/ohos/process/files/addon.cc').read_text()
    abi=(source/'app/ohos/entry/src/main/cpp/workspace_grants_abi.h').read_text()
    methods=['beginWholeOutput','writeWholeOutput','closeWholeOutput','stepWholeOutput','abortWholeOutput']
    symbols=['whole_output_begin_v1','whole_output_write_v1','whole_output_close_v1','whole_output_publish_step_v1','whole_output_abort_v1']
    closure_checks={
        'localScopedWrite':'withWorkspace' in local_write and 'io.writeWhole(' in local_write,
        'sandboxFreshSamePolicy':'const fresh = await this.checkedTarget(target, policy);' in sandbox_write and
            'super.writeText(fresh, content, expected, signal, ohosWorkspaceEdit?.workspaceEditScope(fresh, policy, signal))' in sandbox_write,
        'writerFiveMethods':'async function writeWhole(' in writer and all(name in writer for name in methods),
        'consumerWholeGroup':'WHOLE_METHODS' in addon and 'WholeApi()' in addon and all('"'+name+'"' in addon for name in methods),
        'nativeWholeDeclarations':all('dsh_workspace_'+name in abi for name in symbols),
    }
    if not all(closure_checks.values()):
        raise PreparationBlocked('New whole-write source closure is absent; no Node process started')
    native_evidence=component_native() if args.component_prefix else formal_native()
    old_primary={'libdsh_host.so':'62a6b557d45d38d80d968ce033c92fcaee03f3d1498beed83bd33192bd0f9793',
        'libdsh_workspace_grants.so':'8fa6047d775f1600c30ba9368cce5e7a11f1d395fdf69a7cc67911ce9dce8af6',
        'workspace-publisher.node':'1650694d53cb6bacffcdc71967112b4e68b8793018e13679a2f536c6a8e0354e'}
    if any(ident(native/name)['sha256']==sha for name,sha in old_primary.items()):
        raise PreparationBlocked('Old297 primary Native artifact cannot stand for the new whole group')
    checked,overrides=[],[]
    for name in PAYLOAD:
        actual,recorded=ident(payload/name),records[name]
        if args.component_prefix and name in provider_names:
            pin=final_pins[name]
            overrides.append({'path':name,'basis':'final source OH targetSet pin','actual':actual,
                'historicalManifest':recorded,'expectedSHA256':pin['sha256'],'pinSource':ident(pins_path),
                'patchSource':ident(source/'runtime/patches'/pin['patch'])})
        elif args.component_prefix and name in source_overrides:
            origin=ident(source/source_overrides[name])
            if any(actual[k]!=origin[k] for k in ['bytes','sha256','mode']):
                raise PreparationBlocked('Component companion differs from source: '+name)
            overrides.append({'path':name,'basis':'exact source bytes/mode','actual':actual,'historicalManifest':recorded,
                'sourceIdentity':origin,'scope':'source-derived deletion companion, not the composed OH variant' if name.endswith('dsh-go-deletion.mjs') else 'current private writer'})
        else:
            if (actual['sha256'],actual['bytes'])!=(recorded['sha256'],recorded['size']):
                raise PreparationBlocked('Payload differs from actual composer manifest: '+name)
            checked.append({'path':name,'sha256':actual['sha256'],'bytes':actual['bytes']})
    if args.component_prefix:
        if {x['path'] for x in overrides} != provider_names | set(source_overrides):
            raise PreparationBlocked('Exactly four component historical differences must be declared')
        if any((x['actual']['sha256'],x['actual']['bytes'])==(x['historicalManifest']['sha256'],x['historicalManifest']['size']) for x in overrides):
            raise PreparationBlocked('Historical manifest must expose each declared component difference')
    paths=list(dict.fromkeys([HERE/name for name in TESTS]+[source/name for name in SOURCE]+[payload/name for name in PAYLOAD]
        +[native/name for name in NATIVE]+[node,publication,manifest_path,typescript/'node_modules/typescript/package.json',
        typescript/'node_modules/typescript/lib/typescript.js',args.oracle.resolve()]))
    files=[ident(path) for path in paths]
    if candidate is not None:
        bindings=row_map(candidate.get('files',[]))
        for path in paths:
            expected=bindings.get(str(path.resolve()))
            if expected is None: raise PreparationBlocked('Candidate omits selected input: '+str(path))
            same_record(path,expected)
        files.append(ident(args.candidate_inputs.resolve()))
    files += native_evidence['files'];files=list({row['path']:row for row in files}.values())
    input_receipt=ident(args.candidate_inputs.resolve()) if candidate is not None else {
        'basis':'Current composer manifest, final OH pins/exact writer and actual authority BUILD/INPUTS',
        'manifest':ident(manifest_path),'pins':ident(pins_path),'writer':writer_source,'closureChecks':closure_checks,
        'authorityBuild':native_evidence['buildReceipt'],'authorityInputs':native_evidence['inputReceipt']}
    return {'files':files,'manifest':ident(manifest_path),'runtimeVersion':None if args.component_prefix else manifest['runtimeVersion'],
        'referenceRuntimeVersion':manifest['runtimeVersion'],'componentPrefix':args.component_prefix,
        'selectedManifestReadback':checked,'exactSourceOverrides':overrides,'oracle':oracle,'candidateInputReceipt':input_receipt,
        'sourceSelectionSHA256':hashlib.sha256(json.dumps([x for x in files if Path(x['path']).is_relative_to(source)],sort_keys=True,separators=(',',':')).encode()).hexdigest(),
        'sourceCanonicalSHA256':None,'sourceClosureChecks':closure_checks,
        'providers':{'local':ident(payload/'node_modules/@deepseek-ai/dsh-fs-local/lib/index.js'),'sandbox':ident(payload/'node_modules/@deepseek-ai/dsh-fs-sandbox/lib/index.js')},
        'nativePair':[ident(native/name) for name in NATIVE],'nativeBuildEvidence':native_evidence,
        'scope':'Selected inputs only. Formal: all selected payload bytes match current composer. Component: four explicit historical differences, runtimeVersion null. Native behavior is checked by the actual actor, not by source markers.'}

BEFORE = 'FIRST\n'
AFTER = 'SECOND\n'
NAMES = ['physical-existing', 'physical-new', 'logical-existing', 'logical-new']
def check_file(snapshot, text, mode):
    value = text.encode()
    assert snapshot['exists'] is True and snapshot['bytes'] == len(value)
    assert snapshot['hex'] == value.hex() and snapshot['sha256'] == hashlib.sha256(value).hexdigest()
    assert snapshot['mode'] == mode and snapshot['exactStat']['size'] == str(len(value))
def batch(call_id, result): return {'results': [{'callId': call_id, 'result': result}], 'additionalContexts': [], 'concluded': False}
def observation(call_id, path, token): return {'callId': call_id, 'target': {'displayPath': path, 'targetKey': path}, 'observed': {'kind': 'present', 'version': token}}
def validate_native_calls(row):
    calls = row['nativeWholeCalls']; assert row['nativeWholeOraclePassed'] is True
    if not row['logical']:
        assert calls == []; return
    assert len(calls) >= 5
    lease_id = calls[0]['input']['leaseId']; assert type(lease_id) is int and lease_id > 0
    assert calls[0] == {'method':'beginWholeOutput', 'input': {'leaseId':lease_id, 'relative':row['filename'],
        'policy':0 if row['existing'] else 1, 'priorMode':0o644 if row['existing'] else 0, 'createIfAbsent':False},
        'outcome':{'status':'returned','value':1}}
    index, offset, body = 1, 0, AFTER.encode()
    while index < len(calls) and calls[index]['method'] == 'writeWholeOutput':
        item = calls[index]; index += 1
        assert item['input'] == {'leaseId':lease_id,'bytes':len(body)-offset,'hex':body[offset:].hex()}
        assert item['outcome']['status'] == 'returned'; count = item['outcome']['value']
        assert type(count) is int and 0 < count <= len(body)-offset; offset += count
    assert offset == len(body)
    assert calls[index:] == [
        {'method':'closeWholeOutput','input':{'leaseId':lease_id},'outcome':{'status':'returned','value':1}},
        {'method':'stepWholeOutput','input':{'leaseId':lease_id},'outcome':{'status':'returned','value':{'schemaVersion':1,'effectKnown':True,'effect':2,'continuation':0,'stagingRemoved':True}}},
        {'method':'abortWholeOutput','input':{'leaseId':lease_id},'outcome':{'status':'returned','value':1}},
    ]
    assert row['nativeWholeCoverage'] == {'unguardedPublication':'confirmed-effect2','copyFdClose':'abort returned; lease observations separate',
        'guardedWx':'NOT_MEASURED','boundedCopy':'NOT_MEASURED','cancellation':'NOT_MEASURED','effect1':'NOT_MEASURED','cleanupFailure':'NOT_MEASURED'}

def validate_report(report, oracle):
    assert report['mode'] == 'after-only' and report['pass'] and report['cleanupCompleted']
    assert report['writeBatchCount'] == 4 and report['readBatchCount'] == 2
    assert report['hostWorkspacesBefore'] == report['hostWorkspacesAfter'] == {'exists': False}
    assert report['hostWorkspacesUnchanged'] and report['noSeparateDirectMapping'] and report['publicMethodsRestored']
    assert report['nativeWholeGroup'] == 'WHOLE_WRITE_ABI_V1' and report['nativeWholeMethodsRestored']
    assert report['unmeasured'] == oracle['notCovered']
    assert report['nativeRetired']['active'] is False and report['nativeRetired']['leases'] == 0 and report['nativeRetired']['drained']
    assert report['published']['normalFileUriPath'] == '/storage/Users/currentUser/Projects/whole-write-normal-after'
    assert len(report['cases']) == 4
    expected_observations = []
    for index, row in enumerate(report['cases']):
        logical, existing = index >= 2, index % 2 == 0
        assert row['name'] == NAMES[index] and row['logical'] == logical and row['existing'] == existing
        assert row['status'] == 'PASS' and row['pass'] and row['completeOraclePassed'] and row['targetEntered'] and row['contextDisposed']
        assert not row['cleanupErrors'] and not row.get('setupError') and not row.get('unexpectedError')
        directory, path, sid = row['session']['headerCwd'], row['path'], row['session']['id']
        filename = 'existing.txt' if existing else 'new.txt'
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
        if existing:
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
        else:
            assert row['fileBefore'] == row['fileAfterRead'] == row['fileBeforeWrite'] == {'exists': False}
            assert row['readPreludeNotApplicable'] and 'readBatch' not in row and 'readCalls' not in row
        if not existing:
            ref = row['defaultReference']
            check_file(ref, '', ref['mode'])
            # App-workspace files keep the upstream 0600; granted folders follow the directory default.
            assert row['expectedNewMode'] == (ref['mode'] if row['logical'] else 0o600)
            assert row['expectedNewGid'] == ref['gid'] == row['fileAfterWrite']['gid']
            assert ref == row['defaultReferenceAtExit']
            assert row['defaultReferencePath'] == str(Path(row['backing']).parent / 'directory-default-reference.txt')
            assert row['defaultReferenceBasis'] == 'normal Node wx(0666), same backing parent; no mode/gid changes'
        check_file(row['fileAfterWrite'], AFTER, 0o644 if existing else row['expectedNewMode'])
        validate_native_calls(row)
        assert row['fileAfterWrite'] == row['fileAtCaseExit'] == row['fileAtFinalTeardown']
        token = version(row['fileAfterWrite'], grant); assert row['independentWriteVersion'] == token
        if existing: assert token != row['independentReadVersion']
        operation = 'update' if existing else 'create'
        provider = {'operation': operation, 'version': token, 'before': BEFORE if existing else None, 'after': AFTER}
        inp = {'target': target, 'content': AFTER, 'intent': {'present': False}}
        assert row['writeCalls'] == [
            {'layer': 'sandbox', 'method': 'writeText', 'input': {**inp, 'policy': policy}, 'originalPromiseReturned': True, 'outcome': {'status': 'fulfilled', 'value': provider}},
            {'layer': 'local', 'method': 'writeText', 'input': inp, 'originalPromiseReturned': True, 'outcome': {'status': 'fulfilled', 'value': provider}}]
        value = {'path': path, 'operation': operation, 'before': BEFORE if existing else None, 'after': AFTER}
        meta = {'operation': operation, 'path': path, 'diffs': [{'path': path, 'oldText': 'FIRST', 'newText': 'SECOND'}] if existing else []}
        word = 'Updated' if existing else 'Created'
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
    assert report['nativeWholeCalls'] == [call for row in report['cases'] for call in row['nativeWholeCalls']]

result = {'schema': 1, 'startedUTC': utc(), 'executed': False, 'classification': 'SETUP_ERROR', 'mode': 'jitless' if args.jitless else 'plain',
          'evidenceVerified': False, 'ordinaryCases': 4, 'scope': 'after-only; never old logical baseline'}
try:
    pre = prepare_inputs(); before = pre['files']; oracle = pre['oracle']
    assert oracle['before'] == BEFORE and oracle['after'] == AFTER and oracle['existingMode'] == 0o644
    assert [row['name'] for row in oracle['cases']] == NAMES
    for name in ['home', 'tmp', 'physical-existing', 'physical-new', 'linux-tools']: (O / name).mkdir(mode=0o700)
    cfg = {'source': str(source), 'payload': str(payload), 'nativeDirectory': str(native), 'result': str(O / 'REPORT.json'),
           'physical': [str(O / 'physical-existing'), str(O / 'physical-new')], 'oracle': str(args.oracle.resolve()),
           'candidateInputReceipt': pre['candidateInputReceipt']}
    save('CONFIG.json', cfg)
    environment_delta = { 'TMPDIR': str(O / 'tmp'), 'LANG': 'C.UTF-8',
           'LD_PRELOAD': str(native / 'libdsh_host.so') + ':' + str(publication), 'DSH_HOME': str(O / 'home'), 'NARB_DISABLE_NATIVE_CACHE': '1',
           'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(native), 'DSH_GO_OHOS_LINUX_DIRECTORY': str(O / 'linux-tools'),
           'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony', 'OHOS_WHOLE_WRITE_CONFIG': str(O / 'CONFIG.json'),
           'OHOS_TYPESCRIPT_PREFIX': str(typescript), 'OHOS_WORKSPACE_GRANTS_ADDON': str(native / 'workspace-publisher.node')}
    env = os.environ.copy(); env.update(environment_delta)
    argv = [str(node), *(['--jitless'] if args.jitless else []), '--max-old-space-size=256', '--import', str(HERE / 'workspace-write-whole-instrumentation.mjs'),
            '--import', str(payload / 'runtime/ohos/preload.mjs'), '--import', str(HERE / 'workspace-write-whole-entry.mjs'),
            str(payload / 'node_modules/@deepseek-ai/dsh/lib/bin.js'), '--profile', 'web', '--dump-config']
    save('COMMAND.json', {'argv': argv, 'cwd': str(O), 'environmentDelta': environment_delta,
        'environmentSource': 'Inherited real HOME/PATH/network/proxy values unchanged; only listed component variables added; other values not logged',
        'inherited': {'HOME': os.environ.get('HOME'), 'PATH': os.environ.get('PATH')},
        'instrumentationAdds': {'DSH_GO_OHOS_SIM_ADDONS': [str(native / x) for x in ['libdsh_flock.so', 'libdsh_require_builtin.so', 'libdsh_workspace_grants.so', 'workspace-publisher.node']]}})
    save('INVOCATION.json', {'argv': [sys.executable, *sys.argv], 'cwd': str(Path.cwd()), 'atUTC': utc()})
    save('INPUTS.json', {**pre, 'files': before, 'newCompose': False, 'newNativeBuildInThisRun': False, 'consumesNewSameSourceWholeV1Build': True,
        'oracleValidation': 'Coordinator recomputes exact result from independent actor fs snapshots; this is not a second filesystem measurement.'})
    timed_out = False; result['executed'] = True; started = time.monotonic()
    with (O / 'node.stdout').open('wb') as out, (O / 'node.stderr').open('wb') as err:
        try: code = subprocess.run(argv, cwd=O, env=env, stdout=out, stderr=err, timeout=90).returncode
        except subprocess.TimeoutExpired: code, timed_out = 124, True
    elapsed = time.monotonic() - started
    result.update(exitCode=code, seconds=elapsed, timeout=timed_out, childReturnedUTC=utc())
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
        validate_report(report, oracle); classification = 'FOUR_AFTER_CONTRACTS_PASS'; result['evidenceVerified'] = True
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
