#!/usr/bin/env python3
"""Finite external-PCM ASR gate: real ETS, named OS/Flutter/timer boundaries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--node', type=Path, required=True)
    parser.add_argument('--typescript-prefix', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=False)
    node, prefix = args.node.resolve(), args.typescript_prefix.resolve()
    version = json.loads((prefix / 'node_modules/typescript/package.json').read_text())['version']
    if not version.startswith('5.9.'):
        raise ValueError('TypeScript 5.9.x is required; the measured version and compiler SHA are recorded')
    plugins = ('HmsAsrLease', 'HmsStreamingAsr', 'StreamingAsrPlugin', 'HmsVoiceRecognizer', 'VoiceTypes')
    tests = ('system-asr-native.test.mjs', 'system-asr-channel.test.mjs', 'system-asr-capture.test.mjs')
    files = [repo / 'app/ohos/entry/src/main/ets/plugins' / (name + '.ets') for name in plugins]
    files += [repo / 'runtime/tests/ohos' / name for name in (*tests, 'system-asr-fixture.mjs',
              'system-asr-linux.py', 'system-asr-host-kits.d.ts', 'system-asr-host-globals.d.ts',
              'speech-flutter-contract.d.ts', 'entry-ability-fixture.mjs')]
    files += [repo / 'app/ohos/entry/src/main/ets/plugins' / name for name in ('HmsKits.ets', 'HmsSpeechKit.ets')]
    files += [repo / 'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets', repo / 'tooling/ohos/run-gates.py']
    kit_source = (repo / 'tooling/ohos/hms-stubs/kits/@kit.CoreSpeechKit.d.ts').read_text()
    modules = re.findall(r"from ['\"](@hms\.ai\.[^'\"]+)['\"]", kit_source)
    if '@hms.ai.speechRecognizer' not in modules:
        raise ValueError('Core Speech host declaration lacks speechRecognizer')
    stubs = ['kits/@kit.CoreSpeechKit.d.ts'] + ['api/' + name + '.d.ts' for name in modules]
    files += [repo / 'tooling/ohos/hms-stubs' / name for name in stubs]
    files += [repo / 'runtime/tests/ohos/call-capture-fixture.mjs']
    files += [repo / 'app/ohos/entry/src/main/ets/plugins' / (name + '.ets') for name in
              ('OhosCallCapture', 'CallEnergyGate', 'VoicePcmTap', 'VoicePcm', 'VoiceTypes')]
    snapshot = lambda: {str(path.relative_to(repo)): sha(path) for path in files}
    before = snapshot(); save(out / 'sources-before.json', before)
    stage = out / 'typescript-source'; stage.mkdir()
    for name in plugins:
        origin = repo / 'app/ohos/entry/src/main/ets/plugins' / (name + '.ets')
        target = stage / (name + '.ts'); target.write_bytes(origin.read_bytes())
        assert sha(target) == sha(origin)
    for source, target in [('system-asr-host-kits.d.ts', 'HmsKits.d.ts'),
                           ('system-asr-host-globals.d.ts', 'globals.d.ts'),
                           ('speech-flutter-contract.d.ts', 'speech-flutter-contract.d.ts')]:
        (stage / target).write_bytes((repo / 'runtime/tests/ohos' / source).read_bytes())
    for name in stubs:
        (stage / Path(name).name).write_bytes((repo / 'tooling/ohos/hms-stubs' / name).read_bytes())
    (stage / 'empty-types').mkdir()
    save(stage / 'tsconfig.json', {'compilerOptions': {
        'strict': True, 'noEmit': True, 'target': 'ES2022', 'module': 'commonjs', 'lib': ['ES2022'],
        'typeRoots': ['./empty-types'], 'baseUrl': '.',
        'paths': {name: ['./' + name + '.d.ts'] for name in ['@kit.CoreSpeechKit', *modules]}
    }, 'include': ['*.ts']})
    commands, results = [], {}
    env = {**os.environ, 'OHOS_TYPESCRIPT_PREFIX': str(prefix)}
    env.pop('NODE_OPTIONS', None)
    for name, argv in [('typescript', [node, prefix / 'node_modules/typescript/lib/tsc.js', '--project', stage / 'tsconfig.json']),
                       ('plain', [node, '--test', '--test-isolation=none', '--test-reporter=tap', *[repo / 'runtime/tests/ohos' / x for x in tests]]),
                       ('jitless', [node, '--jitless', '--test', '--test-isolation=none', '--test-reporter=tap', *[repo / 'runtime/tests/ohos' / x for x in tests]])]:
        command = [str(value) for value in argv]
        commands.append({'name': name, 'argv': command, 'cwd': str(repo)})
        with (out / (name + '.log')).open('wb') as log:
            try: code = subprocess.run(command, cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120).returncode
            except subprocess.TimeoutExpired: code = 124
        output = (out / (name + '.log')).read_text()
        counts = {key: int(match.group(1)) for key in ('tests', 'pass', 'fail', 'cancelled', 'skipped')
                  if (match := re.search(r'^# ' + key + r' (\d+)$', output, re.M))}
        valid = code == 0
        if name != 'typescript':
            valid = valid and counts.get('tests', 0) > 0 and counts.get('tests') == counts.get('pass') and all(counts.get(k) == 0 for k in ('fail', 'cancelled', 'skipped'))
        results[name] = {'exitCode': code, 'accepted': valid, 'counts': counts}
    after = snapshot(); save(out / 'sources-after.json', after); save(out / 'commands.json', commands)
    ok = before == after and all(row['accepted'] for row in results.values())
    report = {'status': 'TESTS_PASSED' if ok else 'FAIL', 'results': results, 'inputsUnchanged': before == after,
              'nodeSha256': sha(node), 'typescriptVersion': version,
              'typescriptSourceSha256': sha(prefix / 'node_modules/typescript/lib/typescript.js'),
              'scope': 'Actual ETS service, lease, channel and EntryAbility with explicit HMS/Flutter/clock boundaries; strict host declarations',
              'notRun': ['HMS SDK ArkTS compilation', 'real recognizer accuracy/latency/offline resource availability', 'device long-call audio continuity'],
              'independentReview': 'REQUIRED_SEPARATELY'}
    save(out / 'report.json', report); print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
