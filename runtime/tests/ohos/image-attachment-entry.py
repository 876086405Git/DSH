#!/usr/bin/env python3
"""Finite host attachment integration with original cases and cache-error recovery.

Formal mode reads an actual adjacent composer manifest. Component mode instead
requires a current official patcher target report and never reports a runtimeVersion.
Only a small selected payload view is copied; the production payload is read-only.
No dependency installation, patcher, whole-tree copy or OH SDK build is performed.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import time


TESTS = Path('runtime/tests/ohos')
IMAGE = Path('runtime/ohos/image')
NODE_HEADERS = ('node_api.h', 'node_api_types.h', 'js_native_api.h',
                'js_native_api_types.h', 'node_version.h')
METRICS = ('packs', 'sourceDecodes', 'verificationDecodes', 'scales')
# Composer.dependencies removes these development files from the formal payload.
# Component prefixes still contain them and must satisfy every final pin.
COMPOSER_DEVELOPMENT_SUFFIXES = ('.map', '.d.ts', '.d.cts', '.d.mts')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def record(path):
    path = Path(path)
    require(path.is_file(), 'Missing regular input: ' + str(path))
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {'path': str(path), 'resolvedPath': str(path.resolve()),
            'bytes': path.stat().st_size, 'sha256': digest,
            'mode': format(stat.S_IMODE(path.stat().st_mode), '04o')}


def same_identity(actual, expected):
    return all(actual[key] == expected[key] for key in ('bytes', 'sha256', 'mode'))


def frozen(path, expected):
    actual = record(path)
    require(same_identity(actual, expected), 'Frozen source or fixture differs: ' + str(path))
    return actual


def relative_path(value):
    path = Path(value)
    require(str(path) == value and not path.is_absolute() and '..' not in path.parts,
            'Invalid relative input path: ' + str(value))
    return path


def inside(root, relative):
    path = root / relative_path(relative)
    require(path.resolve().is_relative_to(root), 'Input leaves its explicit root: ' + relative)
    return path


def executable(value):
    found = shutil.which(str(value))
    require(found is not None, 'Executable is missing: ' + str(value))
    path = Path(found).absolute()
    require(path.is_file() and os.access(path, os.X_OK), 'Input is not executable: ' + str(path))
    return path


def selected_inputs(args):
    source, payload = args.source.resolve(), args.payload.resolve()
    tests, image = source / TESTS, source / IMAGE
    catalog_path = tests / 'image-attachment-input-catalog.json'
    catalog = json.loads(catalog_path.read_text())
    require(catalog.get('schema') == 1 and catalog.get('bridgeFixtureMacro') is False,
            'Unexpected attachment fixture catalog')
    cc, cxx, node = executable(args.cc), executable(args.cxx), executable(args.node)
    headers = args.node_headers.resolve()
    version = (headers / 'node_version.h').read_text()
    for key, value in (('MAJOR', 24), ('MINOR', 22), ('PATCH', 1)):
        require(re.search(r'^#define NODE_' + key + r'_VERSION\s+' + str(value) + r'\s*$', version, re.M),
                'Actual Node 24.22.1 headers are required')
    publication = args.publication_fixture.resolve()
    inputs = [record(path) for path in (Path(__file__).resolve(), catalog_path, cc, cxx,
                                        node, Path(sys.executable), publication)]
    inputs += [record(headers / name) for name in NODE_HEADERS]
    # The SDK headers and image samples are fixed evidence. Product sources use
    # current file hashes so normal reviewed changes do not invalidate the runner.
    for field in ('frozenTests', 'frozenSource'):
        for row in catalog[field]:
            path = inside(source, row['path'])
            if '/image-ndk-sdk26/include/' in row['path'] or '/image-attachment-fixtures/' in row['path']:
                inputs.append(frozen(path, row))
            else:
                inputs.append(record(path))
    oracle = json.loads((tests / 'image-attachment-oracle.json').read_text())
    require([row['name'] for row in oracle['cases']] == ['opaque-jpeg', 'transparent-png'],
            'The JPEG and transparent PNG cases are required')

    pins_path = source / 'runtime/patches/pins.json'
    pins = json.loads(pins_path.read_text())
    inputs.append(record(pins_path))
    require(pins.get('schema') == 2 and 'ohos-image-codec.diff' in pins['targetSets']['ohos'],
            'Current OH image patch is not selected')
    version_path = inside(payload, 'node_modules/@deepseek-ai/dsh/package.json')
    dsh_version = json.loads(version_path.read_text())['version']
    require(dsh_version == catalog['dshVersion'], 'Unexpected DSH version')
    final_pins = {}
    for patch in pins['targetSets']['ohos']:
        for name, value in pins['patches'][patch][dsh_version].items():
            relative_path(name)
            final_pins[name] = {'sha256': value['after'], 'patch': patch}

    selected, added, source_mappings = {}, [], []
    def add_payload(name):
        actual = record(inside(payload, name))
        selected[name] = actual
        return actual

    add_payload('node_modules/@deepseek-ai/dsh/package.json')
    composition_omitted = []
    for name, expected in final_pins.items():
        if not args.component_prefix and name.endswith(COMPOSER_DEVELOPMENT_SUFFIXES):
            path = inside(payload, name)
            require(not path.exists() and not path.is_symlink(),
                    'Composer development artifact remained: ' + name)
            composition_omitted.append({'path': name, **expected, 'reason': 'composer-development-artifact'})
            continue
        require(add_payload(name)['sha256'] == expected['sha256'], 'Final OH pin differs: ' + name)
    for row in catalog['extraPayload']:
        require(same_identity(add_payload(row['path']), row), 'Locked dependency differs: ' + row['path'])
    mappings = list(catalog['runtimeMappings'])
    if not args.component_prefix:
        mappings += catalog['formalAdditionalMappings']
    for row in mappings:
        origin = record(inside(source, row['source']))
        if row['hostFixtureOnly']:
            added.append({'relative': row['payload'], 'origin': origin, 'reason': 'explicit host simulation marker'})
        else:
            actual = add_payload(row['payload'])
            require(same_identity(actual, origin), 'Runtime/loader differs from current source: ' + row['payload'])
            source_mappings.append({'source': origin, 'payload': actual})

    admission = {'componentPrefix': args.component_prefix, 'runtimeVersion': None, 'dshVersion': dsh_version,
                 'sourceScope': 'Current selected input hashes; no whole-runtime behavior claim',
                 'finalPins': [{'path': name, **final_pins[name]} for name in sorted(final_pins)],
                 'checkedFinalPinCount': len(final_pins) - len(composition_omitted),
                 'compositionOmittedPins': sorted(composition_omitted, key=lambda row: row['path']),
                 'sourceRuntimeMappings': source_mappings, 'hostViewAdditions': added}
    if args.component_prefix:
        require(args.target_report is not None and args.manifest is None,
                'Component mode requires the current official patcher target report')
        target_path = args.target_report.resolve()
        target = json.loads(target_path.read_text())
        require(target.get('schema') == 1 and target.get('target') == 'ohos' and
                target.get('dshVersion') == dsh_version and target['selected'] == pins['targetSets']['ohos'],
                'The target report is not for the current OH patch selection')
        for entry in target['inputs']['patches']:
            path = source / 'runtime/patches' / entry['name']
            require(record(path)['sha256'] == entry['sha256'] and
                    entry['pins'] == pins['patches'][entry['name']][dsh_version],
                    'Current patch differs from its target report: ' + entry['name'])
        inputs.append(record(target_path))
        admission['targetReport'] = record(target_path)
    else:
        require(args.manifest is not None and args.target_report is None,
                'Formal mode requires the actual adjacent composer manifest')
        manifest_path = args.manifest.resolve()
        require(payload.name == 'files' and manifest_path == payload.parent / 'manifest.json',
                'Use the manifest adjacent to the actual expanded dsh-runtime/files payload')
        manifest = json.loads(manifest_path.read_text())
        require(manifest.get('schema') == 1 and manifest.get('nodeVersion') == catalog['nodeVersion'] and
                manifest.get('dshVersion') == dsh_version and manifest.get('runtimeVersion', '').startswith('ohos-'),
                'Composer manifest identity differs')
        recorded = {row['path']: row for row in manifest['files']}
        for row in composition_omitted:
            require(row['path'] not in recorded,
                    'Composer development artifact is listed in manifest: ' + row['path'])
        for name, actual in selected.items():
            require(name in recorded and (actual['bytes'], actual['sha256']) ==
                    (recorded[name]['size'], recorded[name]['sha256']),
                    'Selected payload differs from actual composer manifest: ' + name)
        inputs.append(record(manifest_path))
        admission.update(manifest=record(manifest_path), runtimeVersion=manifest['runtimeVersion'],
                         selectedManifestFiles=len(selected), wholeManifestFiles=len(recorded))
    inputs += list(selected.values())
    inputs = list({row['path']: row for row in inputs}.values())
    return {'source': source, 'payload': payload, 'tests': tests, 'image': image,
            'catalog': catalog, 'oracle': oracle, 'cc': cc, 'cxx': cxx, 'node': node,
            'headers': headers, 'publication': publication, 'inputs': inputs,
            'selectedPayload': selected, 'hostAdditions': added, 'admission': admission}


def make_view(selection, destination):
    rows = [{'relative': name, 'origin': row, 'reason': 'verified selected payload'}
            for name, row in selection['selectedPayload'].items()]
    rows += selection['hostAdditions']
    require(len({row['relative'] for row in rows}) == len(rows), 'Duplicate test-view destination')
    made = []
    for row in rows:
        source = Path(row['origin']['path'])
        require(same_identity(record(source), row['origin']), 'Selected input drift before copying')
        target = destination / relative_path(row['relative'])
        target.parent.mkdir(parents=True, exist_ok=True)
        require(not target.exists(), 'Test-view destination already exists')
        shutil.copy2(source, target)
        actual = record(target)
        require(same_identity(actual, row['origin']), 'Test-view copy differs')
        made.append({'relative': row['relative'], 'reason': row['reason'],
                     'origin': row['origin'], 'copy': actual})
    return made


def build_commands(selection, native):
    tests, image = selection['tests'], selection['image']
    common = [selection['cc'], '-std=c11', '-O2', '-g0', '-Wall', '-Wextra', '-Werror',
              '-fPIC', '-fvisibility=hidden', '-pthread', '-D_POSIX_C_SOURCE=200809L',
              '-DDSH_IMAGE_NDK_HOST_FIXTURE=1', '-DDSH_IMAGE_DESTROY_COLORSPACE_GETTER=1',
              '-include', tests / 'image-attachment-host-compat.h',
              '-I', tests / 'image-ndk-shims', '-I', tests, '-I', image,
              '-isystem', tests / 'image-ndk-sdk26/include']
    sources = [image / 'codec_ndk.c', image / 'container_facts.c', image / 'encoding_ladder.c',
               tests / 'image-attachment-sdk.c', tests / 'image-attachment-inputs.c']
    commands, objects = [], []
    for index, source in enumerate(sources):
        target = native / ('part' + str(index) + '.o')
        commands.append({'name': 'compile-' + str(index), 'argv': list(map(str, common + ['-c', source, '-o', target])),
                         'timeoutSeconds': 60, 'artifact': str(target)})
        objects.append(target)
    target = native / 'libdsh_image_codec.so'
    # The host integration uses ordinary Node API symbols. The bridge does not
    # receive DSH_IMAGE_HOST_FIXTURE, so the original real factory is preserved.
    argv = [selection['cxx'], '-std=c++17', '-O2', '-g0', '-fPIC', '-fvisibility=hidden',
            '-shared', '-DNAPI_VERSION=8', '-pthread', '-I', selection['headers'], '-I', image,
            image / 'addon.cc', *objects, '-o', target]
    commands.append({'name': 'link-host', 'argv': list(map(str, argv)),
                     'timeoutSeconds': 60, 'artifact': str(target)})
    return commands


def run_command(step, directory, environment, delta):
    row = dict(step, cwd='/', startedUTC=utc(), timeout=False, started=False,
               environmentDelta=delta, HOME='inherited unchanged', PATH='inherited unchanged',
               networkAndProxy='inherited unchanged; values omitted')
    start_path = directory / (step['name'] + '-ARGV.json')
    save(start_path, row)
    stdout, stderr = directory / (step['name'] + '.stdout'), directory / (step['name'] + '.stderr')
    start = time.monotonic()
    child = None
    try:
        with stdout.open('xb') as output, stderr.open('xb') as error:
            child = subprocess.Popen(step['argv'], cwd='/', env=environment, stdin=subprocess.DEVNULL,
                                     stdout=output, stderr=error, start_new_session=True)
            row.update(started=True, pid=child.pid)
            save(start_path, row)
            try:
                code = child.wait(timeout=step['timeoutSeconds'])
            except subprocess.TimeoutExpired:
                row['timeout'] = True
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        row['retirementUnconfirmed'] = True
                code = 124
            row.update(exitCode=code, secondsToChildReturn=time.monotonic() - start)
    except BaseException as error:
        row['invokeError'] = {'name': type(error).__name__, 'message': str(error)}
        if child is not None and child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                row['retirementUnconfirmed'] = True
        row.setdefault('secondsToChildReturn', time.monotonic() - start)
    finally:
        row['endedUTC'] = utc()
        for name, path in (('stdout', stdout), ('stderr', stderr)):
            if path.is_file():
                row[name] = record(path)
        save(directory / (step['name'] + '-RESULT.json'), row)
    return row


def trace_snapshot(rows):
    live, created, released = {}, 0, 0
    for row in rows:
        if row['type'] == 'create':
            require(row['id'] not in live, 'SDK trace creates an already live handle')
            live[row['id']] = row['a']
            created += 1
        elif row['type'] == 'release':
            require(live.get(row['id']) == row['a'], 'SDK trace release type/handle differs')
            del live[row['id']]
            released += 1
    return {'rows': len(rows), 'created': created, 'released': released,
            'live': [[key, value] for key, value in live.items()],
            'packs': sum(row['type'] == 'pack' for row in rows),
            'sourceDecodes': sum(row['type'] == 'decode' and row['name'] == 'source' for row in rows),
            'verificationDecodes': sum(row['type'] == 'decode' and row['name'] == 'verify' for row in rows),
            'scales': sum(row['type'] == 'scale' for row in rows),
            'packRecords': [row for row in rows if row['type'] == 'pack'],
            'sourceOrigins': [row for row in rows if row['type'] == 'source']}


def byte_object(expected):
    return {'$bytes': expected['bytes'], 'hex': expected['hex'], 'sha256': expected['sha256']}


def request_object(case):
    return {'variantId': case['variantId'], 'attachment': case['ref'], 'mediaType': case['ref']['mediaType'],
            'bytes': case['request']['bytes'], 'width': 3, 'height': 2, 'depth': 'uchar',
            'space': 'srgb', 'hasAlpha': case['alpha'], 'data': byte_object(case['request'])}


def validate_result(directory, oracle, native):
    report_path, trace_path = directory / 'REPORT.json', directory / 'SDK-TRACE.jsonl'
    report = json.loads(report_path.read_text())
    require(report.get('schema') == 1 and report.get('state') == 'PASS' and
            report.get('originalPlatform') == 'linux' and report.get('node') == '24.22.1' and
            report.get('pixelsDecodedByRealSDK') is False and report.get('deviceRun') is False and
            report.get('scope') == oracle['scope'], 'Original actor did not report its complete scoped PASS')
    admission = report['admission']
    require(admission['fixedPath'] == str(native / 'libdsh_image_codec.so') and
            admission['fixtureOnly'] is False and admission['identity'] == oracle['identity'] and
            admission['publicationProtocol'] == 1 and admission['platformCarrier'] == 'openharmony',
            'Real factory/fixed-loader admission differs')
    text = trace_path.read_text()
    require(text.endswith('\n'), 'SDK JSONL is incomplete')
    rows = [json.loads(line) for line in text.splitlines()]
    require(rows and rows[-1]['type'] == 'carrier' and rows[-1]['name'] == 'process-exit',
            'Normal carrier process-exit observation is missing')
    for index, row in enumerate(rows):
        require(set(row) == {'seq', 'type', 'name', 'id', 'a', 'b'} and row['seq'] == index + 1,
                'SDK trace has incomplete or reordered records')
    labels = ['ready-before-target']
    for case in oracle['cases']:
        labels += [case['name'] + suffix for suffix in
                   (':before-save', ':save-returned', ':read-returned', ':request-returned')]
    labels += ['sequential-repeat:before', 'sequential-repeat:returned',
               'all-public-awaits-finished', 'cache-unknown-orientation:before',
               'cache-unknown-orientation:reencoded', 'context-dispose-returned']
    phases = report['phases']
    require([phase['label'] for phase in phases] == labels, 'Original public boundary list differs')
    previous_rows = 0
    by_label = {}
    for phase in phases:
        count = phase['sdk']['rows']
        require(type(count) is int and previous_rows <= count < len(rows), 'Invalid SDK boundary position')
        snapshot = trace_snapshot(rows[:count])
        require(phase['sdk'] == snapshot and snapshot['live'] == [] and snapshot['created'] == snapshot['released'],
                'SDK object retirement differs at public await')
        require(all(phase[key] == 0 for key in ('publicationPending', 'compressionActive',
                                               'queuedCompression', 'requestInflight')),
                'Publication/limiter/request work remains at public await')
        previous_rows = count
        by_label[phase['label']] = snapshot
    require(len(report['cases']) == len(oracle['cases']) == 2, 'The two image cases are incomplete')
    for observed, case in zip(report['cases'], oracle['cases']):
        facts = dict(case['sourceFacts'], space={'$undefined': True})
        require(observed['name'] == case['name'] and observed['sourceFacts'] == facts and observed['ref'] == case['ref'],
                'Original source facts/reference differ')
        require(observed['read'] == {'data': byte_object(case['normalized']), 'ref': case['ref']} and
                observed['request'] == request_object(case), 'Complete public image values differ')
        cached = observed['cached']
        require(cached['bytes'] == byte_object(case['request']) and
                cached['sourceFacts']['space'] == {'$undefined': True} and
                cached['sourceFacts']['hasAlpha'] == case['alpha'] and
                cached['sourceFacts']['width'] == 3 and cached['sourceFacts']['height'] == 2,
                'Original cache-byte/source-fact checks differ')
        checkpoints = [by_label[case['name'] + suffix] for suffix in
                       (':before-save', ':save-returned', ':read-returned', ':request-returned')]
        expected_deltas = [(1, 2, 1, 0), (0, 0, 0, 0), (1, 1, 1, 1)]
        for before, after, expected in zip(checkpoints, checkpoints[1:], expected_deltas):
            require(tuple(after[key] - before[key] for key in METRICS) == expected,
                    'Original per-operation SDK counts differ')
    repeated = next(case for case in oracle['cases'] if case['name'] == oracle['sequentialRepeat']['case'])
    repeat = report['sequentialRepeat']
    require(repeat['value'] == request_object(repeated) and repeat['delta'] == dict.fromkeys(METRICS, 1),
            'Original same-variant sequential miss differs')
    require(repeat['cached']['bytes'] == byte_object(repeated['request']) and
            repeat['cached']['sourceFacts']['space'] == {'$undefined': True}, 'Repeated cache evidence differs')
    before, after = by_label['sequential-repeat:before'], by_label['sequential-repeat:returned']
    require(all(after[key] - before[key] == 1 for key in METRICS), 'Repeat did not perform the original fresh work')
    legacy = by_label['all-public-awaits-finished']
    require(all(legacy[key] == oracle['total'][key] for key in METRICS),
            'Original integration totals changed before the added cache regression')
    recovery = report['cacheUnavailableRecovery']
    alpha = next(case for case in oracle['cases'] if case['name'] == 'transparent-png')
    require(recovery['result'] == 'RECOVERED_SOURCE_REENCODE' and
            recovery['stage'] == 'source-orientation' and recovery['variantId'] == alpha['variantId'] and
            recovery['cacheSha256'] == '2682f9b15402276e3a33d0dfddfbc3a7a2450a7ad9eed9369d634ef455921417' and
            recovery['delta'] == dict.fromkeys(METRICS, 1),
            'Actual scanner cache failure did not recover the unchanged source variant')
    before, after = by_label['cache-unknown-orientation:before'], by_label['cache-unknown-orientation:reencoded']
    require(all(after[key] - before[key] == 1 for key in METRICS),
            'Cache recovery did not perform one fresh verified encoding')
    total = trace_snapshot(rows)
    require(total['live'] == [] and total['created'] == total['released'] and
            all(total[key] == oracle['total'][key] + 1 for key in METRICS) and
            all(row['a'] == 85 and row['b'] == 240 for row in total['packRecords']),
            'Final SDK trace totals differ')
    require(report['cleanup'].get('contextDisposed') is True and 'error' not in report['cleanup'] and
            report['cleanup']['afterContextDispose'] == phases[-1]['sdk'], 'Context cleanup was not confirmed')
    require(not any(row['path'].startswith('attachments/v1/tmp/') or row['path'].endswith('.tmp')
                    for row in report['files']), 'Original actor observed leftover temporary files')
    return {'report': record(report_path), 'trace': record(trace_path), 'imageCases': 2,
            'sequentialRequests': 1, 'cacheUnavailableRecovery': recovery,
            'boundaryCount': len(phases), 'traceRows': len(rows),
            'sdkTotals': {key: total[key] for key in METRICS}, 'sameVariantRequestCache': 'observed miss',
            'scope': 'Recomputed original actor observations and added real-scanner cache recovery; not a second filesystem measurement or real pixel decode',
            'publicationOwner': report['cleanup']['publicationOwner'], 'observerFD': report['cleanup']['observerFD']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--payload', type=Path, required=True)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--component-prefix', action='store_true')
    parser.add_argument('--target-report', type=Path)
    parser.add_argument('--node', required=True)
    parser.add_argument('--node-headers', type=Path, required=True)
    parser.add_argument('--publication-fixture', type=Path, required=True)
    parser.add_argument('--cc', required=True)
    parser.add_argument('--cxx', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--jitless', action='store_true')
    args = parser.parse_args()
    args.out = args.out.resolve()
    require(not args.out.exists() and not args.out.is_relative_to(args.source.resolve()) and
            not args.out.is_relative_to(args.payload.resolve()), 'Use a fresh output directory outside source and payload')
    args.out.mkdir(parents=True, exist_ok=False)
    state = {'schema': 1, 'status': 'SETUP_NOT_RUN', 'startedUTC': utc(), 'steps': [],
             'mode': 'jitless' if args.jitless else 'plain', 'productStarted': False,
             'scope': 'Two original host attachment cases, sequential unknown-colour miss and actual cache-orientation recovery; explicit SDK/pixels fixture, no OH link or device'}
    save(args.out / 'STARTED.json', state)
    inputs, view_rows, built, selection = [], [], [], None
    try:
        require(not os.environ.get('NODE_OPTIONS'), 'NODE_OPTIONS must be unset for the fixed host actor')
        selection = selected_inputs(args)
        inputs = selection['inputs']
        save(args.out / 'INPUTS-BEFORE.json', {'files': inputs, 'admission': selection['admission']})
        for name in ('view', 'native', 'tmp', 'home'):
            (args.out / name).mkdir(mode=0o700 if name == 'home' else 0o755)
        view, native = args.out / 'view', args.out / 'native'
        view_rows = make_view(selection, view)
        save(args.out / 'VIEW.json', {'files': view_rows, 'entirePayloadCopied': False,
                                    'productionPayloadModified': False, 'admission': selection['admission']})
        commands = build_commands(selection, native)
        node_delta = {'TMPDIR': str(args.out / 'tmp'), 'DSH_HOME': str(args.out / 'home'),
                      'DSH_PREFIX': str(view), 'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(native),
                      'DSH_IMAGE_TEST_OUT': str(args.out), 'DSH_IMAGE_TEST_TRACE': str(args.out / 'SDK-TRACE.jsonl'),
                      'LD_PRELOAD': str(selection['publication'])}
        commands.append({'name': 'node', 'argv': [str(selection['node']), *(['--jitless'] if args.jitless else []),
                         str(selection['tests'] / 'image-attachment-entry.mjs')], 'timeoutSeconds': 90})
        save(args.out / 'COMMANDS.json', {'steps': commands, 'nodeEnvironmentDelta': node_delta,
                                        'HOME': 'inherited unchanged', 'PATH': 'inherited unchanged'})
        state.update(status='RUNNING', admission=selection['admission'])
        save(args.out / 'RESULT.json', state)
        for step in commands:
            require([record(row['path']) for row in inputs] == inputs, 'Selected input drift before command')
            require(all(same_identity(record(row['copy']['path']), row['copy']) for row in view_rows),
                    'Selected test-view drift before command')
            require(all(same_identity(record(row['path']), row) for row in built), 'Build artifact drift before command')
            delta = node_delta if step['name'] == 'node' else {'TMPDIR': str(args.out / 'tmp')}
            environment = dict(os.environ, **delta)
            if step['name'] == 'node':
                state['productStarted'] = True
                save(args.out / 'RESULT.json', state)
            result = run_command(step, args.out, environment, delta)
            state['steps'].append(result)
            save(args.out / 'RESULT.json', state)
            require(result.get('exitCode') == 0 and not result['timeout'] and 'invokeError' not in result,
                    'Command did not complete normally: ' + step['name'])
            if 'artifact' in step:
                result['artifactIdentity'] = record(step['artifact'])
                built.append(result['artifactIdentity'])
            else:
                state['readback'] = validate_result(args.out, selection['oracle'], native)
            require([record(row['path']) for row in inputs] == inputs, 'Selected input drift after command')
            require(all(same_identity(record(row['copy']['path']), row['copy']) for row in view_rows),
                    'Selected test-view drift after command')
            require(all(same_identity(record(row['path']), row) for row in built), 'Build artifact drift after command')
            result['inputsUnchanged'] = True
            save(args.out / 'RESULT.json', state)
        state['status'] = 'PASS_SCOPED_HOST_ATTACHMENT_CHAIN'
    except BaseException as error:
        state['status'] = 'STOPPED_AT_FIRST_ANOMALY' if state['steps'] or state['productStarted'] else 'SETUP_BLOCKED_NOT_RUN'
        state['error'] = {'name': type(error).__name__, 'message': str(error)}
    if inputs:
        try:
            after = [record(row['path']) for row in inputs]
            view_after = [record(row['copy']['path']) for row in view_rows]
            state['inputsUnchanged'] = after == inputs
            state['viewUnchanged'] = all(same_identity(actual, row['copy']) for actual, row in zip(view_after, view_rows))
            save(args.out / 'INPUTS-AFTER.json', {'files': after, 'unchanged': after == inputs,
                                               'viewFiles': view_after, 'viewUnchanged': state['viewUnchanged']})
            if not state['inputsUnchanged'] or not state['viewUnchanged']:
                state['status'] = 'INPUT_DRIFT'
        except BaseException as error:
            state['status'] = 'INPUT_DRIFT'
            state['afterIdentityError'] = {'name': type(error).__name__, 'message': str(error)}
    state['endedUTC'] = utc()
    state['exitCode'] = 0 if state['status'] == 'PASS_SCOPED_HOST_ATTACHMENT_CHAIN' else 1
    save(args.out / 'RESULT.json', state)
    print(json.dumps(state, ensure_ascii=False))
    return state['exitCode']


if __name__ == '__main__':
    sys.exit(main())
