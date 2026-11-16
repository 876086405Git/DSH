#!/usr/bin/env python3
"""Finite image host components; each invocation builds and runs one suite once.

Source fixtures and their complete assertions are unchanged. The NDK suite uses
actual SDK declarations with explicit fake implementations, never SDK libraries.
The bridge suite uses the ordinary host Node API with a fixture-only backend.
No environment values are changed; no install, download or product preparation.
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
HEADERS = ('node_api.h', 'node_api_types.h', 'js_native_api.h',
           'js_native_api_types.h', 'node_version.h')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def record(path):
    path = Path(path)
    require(path.is_file(), 'Missing regular input: ' + str(path))
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {'path': str(path), 'resolvedPath': str(path.resolve()),
            'bytes': path.stat().st_size, 'sha256': digest,
            'mode': format(stat.S_IMODE(path.stat().st_mode), '04o')}


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def executable(value):
    found = shutil.which(str(value))
    require(found is not None, 'Executable not found: ' + str(value))
    path = Path(found).absolute()
    require(path.is_file() and os.access(path, os.X_OK), 'Not executable: ' + str(path))
    return path


def setup(args):
    source = args.source.resolve()
    tests, image = source / TESTS, source / IMAGE
    oracle_path = tests / 'image-host-oracle.json'
    oracle = json.loads(oracle_path.read_text())
    require(oracle.get('schema') == 1, 'Unsupported image host oracle')
    cc = executable(args.cc)
    common = [Path(__file__).resolve(), oracle_path, cc]
    selected, commands = [], []

    def step(name, argv, timeout, check=None, artifact=None):
        commands.append({'name': name, 'argv': list(map(str, argv)),
                         'cwd': '/', 'timeoutSeconds': timeout,
                         'check': check, 'artifact': str(artifact) if artifact else None})

    if args.suite in ('container', 'ladder'):
        stem = 'container_facts' if args.suite == 'container' else 'encoding_ladder'
        fixture = 'image-container-facts.c' if args.suite == 'container' else 'image-encoding-ladder.c'
        selected = [image / (stem + '.c'), image / (stem + '.h'), tests / fixture]
        binary = args.out / ('image-' + args.suite)
        step('build', [cc, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-pedantic',
                      '-I', image, selected[0], tests / fixture, '-o', binary], 60, artifact=binary)
        step('run', [binary], 30, args.suite)
    elif args.suite == 'ndk':
        sdk = tests / 'image-ndk-sdk26/include'
        selected = [image / name for name in ('codec_ndk.c', 'codec_bridge.h',
                    'container_facts.c', 'container_facts.h', 'encoding_ladder.c', 'encoding_ladder.h')]
        selected += [tests / name for name in ('image-ndk-sdk-fake.c', 'image-ndk-contract.c',
                     'image-ndk-inputs.c', 'image-ndk-host.h', 'image-ndk-host-compat.h',
                     'image-ndk-oracle.json', 'image-ndk-shims/info/application_target_sdk_version.h',
                     'image-ndk-shims/napi/native_api.h', 'image-ndk-shims/rawfile/raw_file.h')]
        sdk_rows = [row for row in oracle['frozenTestInputs']
                    if row['path'].startswith(str(TESTS / 'image-ndk-sdk26/include') + '/')]
        require(len(sdk_rows) == 6, 'Exactly six original test SDK headers required')
        selected += [source / row['path'] for row in sdk_rows]
        for policy, value in (('destroy', 1), ('borrow', 0)):
            binary = args.out / ('image-ndk-' + policy)
            step(policy + '-build', [cc, '-std=c11', '-O2', '-g0', '-Wall', '-Wextra', '-Werror',
                 '-DDSH_IMAGE_NDK_HOST_FIXTURE=1', '-DDSH_IMAGE_DESTROY_COLORSPACE_GETTER=' + str(value),
                 '-include', tests / 'image-ndk-host-compat.h', '-I', tests / 'image-ndk-shims',
                 '-I', tests, '-I', image, '-isystem', sdk,
                 image / 'codec_ndk.c', image / 'container_facts.c', image / 'encoding_ladder.c',
                 tests / 'image-ndk-sdk-fake.c', tests / 'image-ndk-contract.c',
                 tests / 'image-ndk-inputs.c', '-o', binary], 60, artifact=binary)
            step(policy + '-normal', [binary, 'normal'], 30, 'ndk')
            step(policy + '-cleanup-unconfirmed', [binary, 'cleanup-unconfirmed'], 30, 'ndk')
    else:
        require(args.node is not None and args.node_headers is not None and args.cxx is not None,
                'bridge requires --node, --node-headers and --cxx')
        node, cxx = executable(args.node), executable(args.cxx)
        headers = args.node_headers.resolve()
        version = (headers / 'node_version.h').read_text()
        for key, value in (('MAJOR', 24), ('MINOR', 22), ('PATCH', 1)):
            require(re.search(r'^#define NODE_' + key + r'_VERSION\s+' + str(value) + r'\s*$', version, re.M),
                    'Bridge fixtures require actual Node 24.22.1 headers')
        selected = [image / 'addon.cc', image / 'codec_bridge.h']
        selected += [tests / name for name in ('image-codec-fake.c', 'image-codec-fake.h',
                                              'image-codec-bridge.test.mjs')]
        selected += [headers / name for name in HEADERS] + [node, cxx]
        obj, addon = args.out / 'fake.o', args.out / 'image-codec-fixture.node'
        step('fake-build', [cc, '-std=c11', '-O2', '-g0', '-fPIC', '-fvisibility=hidden',
             '-DDSH_IMAGE_HOST_FIXTURE=1', '-pthread', '-I', image, '-I', tests, '-c',
             tests / 'image-codec-fake.c', '-o', obj], 60, artifact=obj)
        step('addon-link', [cxx, '-std=c++17', '-O2', '-g0', '-fPIC', '-fvisibility=hidden',
             '-shared', '-DNAPI_VERSION=8', '-DDSH_IMAGE_HOST_FIXTURE=1', '-pthread',
             '-I', headers, '-I', image, '-I', tests, image / 'addon.cc', obj, '-o', addon], 60, artifact=addon)
        # Explicitly retain the original spec output protocol, including its JSON diagnostic.
        step('run', [node, *(['--jitless'] if args.jitless else []), '--test-reporter=spec',
             tests / 'image-codec-bridge.test.mjs', addon], 30, 'bridge')

    require(not args.jitless or args.suite == 'bridge', '--jitless is only a bridge mode')
    inputs = [record(path) for path in dict.fromkeys(common + selected)]
    expected = {row['path']: row for row in oracle['frozenTestInputs']}
    for row in inputs:
        path = Path(row['path'])
        if path.is_relative_to(source):
            rel = path.relative_to(source).as_posix()
            if rel in expected:
                require(all(row[key] == expected[rel][key] for key in ('bytes', 'sha256', 'mode')),
                        'Frozen fixture or original SDK header differs: ' + rel)
    return source, oracle, commands, inputs


def validate_ndk(step, lines, oracle):
    separate = step['name'].endswith('cleanup-unconfirmed')
    names = ([oracle['separateProcessCase']['name']] if separate
             else [row['name'] for row in oracle['normalCases']])
    policy = 'destroy' if step['name'].startswith('destroy-') else 'borrow'
    expected_summary = ('SUMMARY cases=' + str(len(names)) +
        ' failed=0 sdk=fake pixels=fake real_backend=codec_ndk color_getter_policy=' + policy)
    require(len(lines) == 2 * len(names) + 1 and lines[-1] == expected_summary,
            'NDK output count or complete summary differs')
    observations = []
    fields = {'case', 'sdkCalls', 'sourceDecodes', 'verifyDecodes', 'clones', 'rotations', 'scales',
              'packs', 'baseOptions', 'verificationOptions', 'colorGets', 'colorNames', 'colorDestroys',
              'sourceInputChecks', 'qualities', 'capacities', 'liveFakeObjects'}
    for index, name in enumerate(names):
        require(lines[index * 2] == 'PASS ' + name and lines[index * 2 + 1].startswith('OBS '),
                'Missing, duplicated or reordered NDK case: ' + name)
        row = json.loads(lines[index * 2 + 1][4:])
        require(set(row) == fields and row['case'] == name, 'Incomplete NDK observation')
        for key in fields - {'case', 'qualities', 'capacities', 'liveFakeObjects'}:
            require(type(row[key]) is int and row[key] >= 0, 'Invalid NDK count: ' + key)
        require(row['liveFakeObjects'] == ([1, 0, 0, 1, 0, 0, 0] if separate else [0] * 7),
                'Fake lifetime fact differs; unconfirmed objects must not be hidden')
        require(row['baseOptions'] in (0, 31) and row['verificationOptions'] in (0, 1),
                'Unexpected base or verification options')
        require(len(row['qualities']) == len(row['capacities']) == row['packs'], 'Pack records incomplete')
        require(all(value in (85, 75, 60) for value in row['qualities']), 'Unexpected quality')
        require(all(value == 52428800 for value in row['capacities']), 'Pack capacity differs')
        require(row['colorNames'] <= row['colorGets'], 'Color observation differs')
        require(row['colorDestroys'] == (row['colorNames'] if policy == 'destroy' else 0),
                'Compiled color getter policy differs')
        observations.append(row)
    return {'cases': len(names), 'passNames': names, 'observations': observations,
            'summary': expected_summary, 'realOwnershipClaim': False}


def validate_bridge(lines, oracle):
    # ANSI is a renderer detail only; raw stdout is retained without edits.
    clean = [re.sub(r'\x1b\[[0-9;]*m', '', line) for line in lines]
    names, totals, diagnostics, durations = [], {}, [], []
    for line in clean:
        passed = re.fullmatch(r'✔ (.+) \([0-9.]+ms\)', line)
        total = re.fullmatch(r'ℹ (tests|suites|pass|fail|cancelled|skipped|todo) (\d+)', line)
        if passed:
            names.append(passed[1])
        elif total:
            require(total[1] not in totals, 'Duplicate Node summary field')
            totals[total[1]] = int(total[2])
        elif line.startswith('ℹ {'):
            diagnostics.append(json.loads(line[2:]))
        else:
            require(re.fullmatch(r'ℹ duration_ms [0-9.]+', line) is not None, 'Unexpected Node output: ' + line)
            durations.append(line)
    require(names == oracle['bridge']['passNames'], 'Four exact bridge cases did not all pass')
    require(totals == {'tests': 4, 'suites': 0, 'pass': 4, 'fail': 0,
                       'cancelled': 0, 'skipped': 0, 'todo': 0}, 'Incomplete Node result')
    require(len(durations) == 1, 'Missing or duplicate Node duration summary')
    require(len(diagnostics) == 1 and set(diagnostics[0]) == {'phase', 'stats'} and
            diagnostics[0]['phase'] == 'before-native-release', 'Missing complete lifecycle diagnostic')
    stats = diagnostics[0]['stats']
    keys = {'opens', 'closes', 'active', 'encodes', 'overlaps', 'outputs',
            'releasedOutputs', 'inputMismatches', 'cleanupStarts'}
    require(set(stats) == keys and all(type(value) is int and value >= 0 for value in stats.values()),
            'Incomplete fake backend diagnostic')
    # Hook ordering is intentionally observed, not constrained beyond the frozen fixture.
    return {'cases': 4, 'passNames': names, 'totals': totals, 'diagnostics': diagnostics}


def validate(step, stdout, stderr, source, oracle, jitless):
    text = stderr.decode('utf-8')
    allowed = 'Warning: disabling flag --expose_wasm due to conflicting flags'
    require(not text or (step['check'] == 'bridge' and jitless and
                        all(line == allowed for line in text.splitlines())), 'Unexpected stderr')
    lines = stdout.decode('utf-8').splitlines()
    if step['check'] is None:
        require(not stdout, 'Unexpected compiler stdout')
        return {'artifact': record(step['artifact'])}
    if step['check'] == 'container':
        expected = ['PASS ' + name for name in oracle['container']['passNames']]
        expected += [oracle['container']['summary']]
        require(lines == expected, 'Container complete case output differs')
        return {'cases': 28, 'passNames': oracle['container']['passNames']}
    if step['check'] == 'ladder':
        rows = [json.loads(line) for line in lines]
        require(rows == oracle['ladder']['cases'] + [oracle['ladder']['summary']], 'Ladder complete result differs')
        return {'cases': 13, 'rows': rows}
    if step['check'] == 'ndk':
        frozen = json.loads((source / oracle['ndkOracle']).read_text())
        return validate_ndk(step, lines, frozen)
    return validate_bridge(lines, oracle)


def run_step(step, out):
    started = time.monotonic()
    row = dict(step, startedUTC=utc(), timeout=False)
    stdout, stderr = out / (step['name'] + '.stdout'), out / (step['name'] + '.stderr')
    with stdout.open('wb') as output, stderr.open('wb') as error:
        child = subprocess.Popen(step['argv'], cwd='/', stdin=subprocess.DEVNULL,
                                 stdout=output, stderr=error, start_new_session=True)
        try:
            code = child.wait(timeout=step['timeoutSeconds'])
        except subprocess.TimeoutExpired:
            row['timeout'] = True
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            code = 124
    row.update(exitCode=code, seconds=time.monotonic() - started, endedUTC=utc(),
               stdout=record(stdout), stderr=record(stderr))
    return row, stdout.read_bytes(), stderr.read_bytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--suite', choices=('container', 'ladder', 'ndk', 'bridge'), required=True)
    parser.add_argument('--cc', required=True)
    parser.add_argument('--cxx')
    parser.add_argument('--node')
    parser.add_argument('--node-headers', type=Path)
    parser.add_argument('--jitless', action='store_true')
    args = parser.parse_args()
    args.out = args.out.resolve()
    require(not args.out.exists() and not args.out.is_relative_to(args.source.resolve()),
            'Use a fresh output directory outside source; no overwrite or retry')
    args.out.mkdir(parents=True, exist_ok=False)
    result = {'schema': 1, 'startedUTC': utc(), 'suite': args.suite,
              'mode': 'jitless' if args.jitless else 'plain', 'steps': [],
              'status': 'SETUP_NOT_RUN', 'environment': 'Inherited unchanged from invoking process',
              'scope': 'Finite host component only; no attachment-chain, real SDK codec, OH link or device claim'}
    inputs = []
    try:
        source, oracle, commands, inputs = setup(args)
        save(args.out / 'INPUTS-BEFORE.json', {'files': inputs})
        save(args.out / 'COMMANDS.json', {'steps': commands, 'environment': result['environment']})
        result['status'] = 'RUNNING'
        save(args.out / 'RESULT.json', result)
        for step in commands:
            require([record(row['path']) for row in inputs] == inputs, 'Input drift before command')
            row, stdout, stderr = run_step(step, args.out)
            result['steps'].append(row)
            save(args.out / 'RESULT.json', result)
            require(row['exitCode'] == 0 and not row['timeout'], 'Command failed: ' + step['name'])
            row['readback'] = validate(step, stdout, stderr, source, oracle, args.jitless)
            require([record(item['path']) for item in inputs] == inputs, 'Input drift after command')
            row['inputsUnchanged'] = True
            save(args.out / 'RESULT.json', result)
        result['status'] = 'PASS_SCOPED_HOST_COMPONENT'
    except Exception as error:
        result['status'] = 'SETUP_BLOCKED_NOT_RUN' if not result['steps'] else 'STOPPED_AT_FIRST_ANOMALY'
        result['error'] = {'name': type(error).__name__, 'message': str(error)}
    if inputs:
        try:
            after = [record(row['path']) for row in inputs]
            result['inputsUnchanged'] = after == inputs
            save(args.out / 'INPUTS-AFTER.json', {'files': after, 'unchanged': after == inputs})
            if after != inputs:
                result['status'] = 'INPUT_DRIFT'
        except Exception as error:
            result['status'] = 'INPUT_DRIFT'
            result['inputReadbackError'] = str(error)
    result['endedUTC'] = utc()
    result['exitCode'] = 0 if result['status'] == 'PASS_SCOPED_HOST_COMPONENT' else 1
    save(args.out / 'RESULT.json', result)
    print(json.dumps(result, ensure_ascii=False))
    return result['exitCode']


if __name__ == '__main__':
    sys.exit(main())
