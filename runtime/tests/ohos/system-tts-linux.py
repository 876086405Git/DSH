#!/usr/bin/env python3
"""Finite system-TTS channel gate; real ETS, explicit HMS/Flutter/PCM boundaries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--node', required=True, type=Path)
    parser.add_argument('--typescript-prefix', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--mode', choices=('plain', 'jitless'), default='plain')
    parser.add_argument('--baseline-root', type=Path,
                        help='Expected registration failure against unmodified 8faafe6')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    product = args.baseline_root.resolve() if args.baseline_root else repo
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=False)
    node, prefix = args.node.resolve(), args.typescript_prefix.resolve()
    version = json.loads((prefix / 'node_modules/typescript/package.json').read_text())['version']
    if not version.startswith('5.9.'):
        raise ValueError('TypeScript 5.9.x is required')
    env = {'OHOS_TYPESCRIPT_PREFIX': str(prefix), 'OHOS_TTS_SOURCE_ROOT': str(product)}
    argv = [str(node), *(['--jitless'] if args.mode == 'jitless' else []),
            '--test', '--test-isolation=none', '--test-reporter=tap']
    if args.baseline_root:
        argv.append('--test-name-pattern=^actual EntryAbility registers')
    argv.append('runtime/tests/ohos/system-tts.test.mjs')
    if not args.baseline_root:
        argv.append('runtime/tests/ohos/system-tts-init-retry.test.mjs')
    sources = [repo / 'runtime/tests/ohos' / name for name in
               ('system-tts-fixture.mjs', 'system-tts.test.mjs', 'system-tts-linux.py')]
    sources += [product / 'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets',
                product / 'runtime/tests/ohos/entry-ability-fixture.mjs',
                repo / 'app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/companion/CompanionVoicePlugin.kt']
    plugins = ('CompanionVoicePlugin', 'HmsTextToSpeechKit', 'OhosSpeechPlayback')
    stubs = ('kits/@kit.CoreSpeechKit.d.ts', 'api/@hms.ai.textToSpeech.d.ts', 'api/@hms.ai.speechRecognizer.d.ts')
    if not args.baseline_root:
        sources.append(repo / 'runtime/tests/ohos/system-tts-init-retry.test.mjs')
        sources += [product / 'app/ohos/entry/src/main/ets/plugins' / (name + '.ets')
                    for name in (*plugins, 'SpeechPlugin')]
        sources += [repo / 'tooling/ohos/hms-stubs' / name for name in stubs]
        sources.append(repo / 'runtime/tests/ohos/speech-flutter-contract.d.ts')
        sources.append(repo / 'runtime/tests/ohos/call-platform-contract.d.ts')
        sources += [product / 'app/ohos/entry/src/main/ets/plugins' / (name + '.ets') for name in
                    ('OhosSpeechCall', 'OhosCallRoute', 'OhosCallCapture', 'CallEnergyGate', 'VoicePcmTap', 'VoicePcm', 'VoiceTypes', 'VoiceMicLease')]
    snapshot = lambda: {str(path): {'bytes': path.stat().st_size, 'sha256': sha(path)} for path in sources}
    before = snapshot(); save(out / 'sources-before.json', before)
    save(out / 'command.json', {'argv': argv, 'cwd': str(repo), 'env': env})
    typecheck = None
    if not args.baseline_root:
        stage = out / 'typescript-source'; stage.mkdir()
        for name in plugins:
            origin = product / 'app/ohos/entry/src/main/ets/plugins' / (name + '.ets')
            (stage / (name + '.ts')).write_bytes(origin.read_bytes())
        for name in stubs:
            (stage / Path(name).name).write_bytes((repo / 'tooling/ohos/hms-stubs' / name).read_bytes())
        (stage / 'speech-flutter-contract.d.ts').write_bytes((repo / 'runtime/tests/ohos/speech-flutter-contract.d.ts').read_bytes())
        (stage / 'call-platform-contract.d.ts').write_bytes((repo / 'runtime/tests/ohos/call-platform-contract.d.ts').read_bytes())
        # The real SDK's ESObject dynamic import is narrowed to the exact lazy
        # module here. This host-only alias is not added to product sources.
        (stage / 'host-dynamic-import.d.ts').write_text("type ESObject = typeof import('./HmsTextToSpeechKit');\n")
        (stage / 'empty-types').mkdir()
        save(stage / 'tsconfig.json', {'compilerOptions': {
            'strict': True, 'noEmit': True, 'target': 'ES2022', 'module': 'commonjs', 'lib': ['ES2022'],
            'typeRoots': ['./empty-types'], 'baseUrl': '.',
            'paths': {name: ['./' + name + '.d.ts'] for name in
                      ('@kit.CoreSpeechKit', '@hms.ai.textToSpeech', '@hms.ai.speechRecognizer')},
        }, 'include': ['*.ts']})
        type_argv = [str(node), str(prefix / 'node_modules/typescript/lib/tsc.js'), '--project', str(stage / 'tsconfig.json')]
        save(out / 'type-command.json', {'argv': type_argv, 'cwd': str(repo),
                                       'scope': 'Strict host TypeScript and nonofficial declarations; not SDK ArkTS'})
        with (out / 'typescript.log').open('wb') as log:
            type_code = subprocess.run(type_argv, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=90).returncode
        typecheck = {'exitCode': type_code, 'scope': 'host declarations only'}
    started = time.monotonic()
    with (out / 'test.log').open('wb') as log:
        try:
            code = subprocess.run(argv, cwd=repo, env={**os.environ, **env}, stdout=log,
                                  stderr=subprocess.STDOUT, timeout=120).returncode
        except subprocess.TimeoutExpired:
            code = 124
    after = snapshot(); save(out / 'sources-after.json', after)
    output = (out / 'test.log').read_text()
    counts = {key: int(match.group(1)) for key in ('tests', 'pass', 'fail', 'cancelled', 'skipped')
              if (match := re.search(r'^# ' + key + r' (\d+)$', output, re.M))}
    if args.baseline_root:
        accepted = (code == 1 and counts.get('tests') == 1 and counts.get('fail') == 1 and
                    'SYSTEM_TTS_UNAVAILABLE' in output and 'missing: true' in output)
    else:
        accepted = (code == 0 and counts.get('tests', 0) > 0 and counts.get('fail') == 0 and
                    counts.get('cancelled') == 0 and counts.get('skipped') == 0)
    accepted = accepted and before == after and (typecheck is None or typecheck['exitCode'] == 0)
    report = {'schema': 1, 'status': ('EXPECTED_BASELINE_RED' if args.baseline_root else 'TESTS_PASSED') if accepted else 'FAIL',
              'childExitCode': code, 'counts': counts, 'mode': args.mode, 'typecheck': typecheck,
              'elapsedSeconds': time.monotonic() - started, 'inputsUnchanged': before == after,
              'nodeSha256': sha(node), 'typescriptVersion': version,
              'typescriptSourceSha256': sha(prefix / 'node_modules/typescript/lib/typescript.js'),
              'scope': 'Real EntryAbility/ETS channel bodies; explicit HMS, Flutter and PCM OS boundaries',
              'notRun': ['HarmonyOS SDK ArkTS compile', 'real device voice availability/audio focus/latency', 'paid synthesis'],
              'independentReview': 'REQUIRED_SEPARATELY'}
    save(out / 'report.json', report)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if accepted else 1


if __name__ == '__main__':
    raise SystemExit(main())
