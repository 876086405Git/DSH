#!/usr/bin/env python3
"""Actual speech ETS and registration; explicit Flutter/AudioRenderer boundaries."""
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
                        help='Registration-only expected red against the unchanged a836880 source tree')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    product = args.baseline_root.resolve() if args.baseline_root else repo
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    node = args.node.resolve()
    prefix = args.typescript_prefix.resolve()
    version = json.loads((prefix / 'node_modules/typescript/package.json').read_text())['version']
    if version != '5.9.3':
        raise ValueError('The pinned TypeScript 5.9.3 is required')
    env_values = {'OHOS_TYPESCRIPT_PREFIX': str(prefix)}
    if args.baseline_root:
        env_values['OHOS_SPEECH_SOURCE_ROOT'] = str(product)
    argv = [str(node)]
    if args.mode == 'jitless':
        argv.append('--jitless')
    argv += ['--test', '--test-isolation=none', '--test-reporter=tap']
    if args.baseline_root:
        argv += ['--test-name-pattern=^actual EntryAbility registers', 'runtime/tests/ohos/speech-channel.test.mjs']
    else:
        argv += ['runtime/tests/ohos/speech-channel.test.mjs',
                 'runtime/tests/ohos/speech-channel-pcm.test.mjs',
                 'runtime/tests/ohos/entry-ability-fixture.test.mjs']
    drivers = [repo / 'runtime/tests/ohos' / name for name in (
        'speech-channel-fixture.mjs', 'speech-channel.test.mjs', 'speech-channel-contract.json',
        'speech-channel-linux.py')]
    products = [product / 'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets',
                product / 'runtime/tests/ohos/entry-ability-fixture.mjs']
    if not args.baseline_root:
        drivers += [repo / 'runtime/tests/ohos' / name for name in (
            'pcm-stream-fixture.mjs', 'speech-channel-pcm.test.mjs', 'entry-ability-fixture.test.mjs',
            'pcm-audio-contract.d.ts', 'speech-flutter-contract.d.ts')]
        products += [repo / 'app/ohos/entry/src/main/ets/plugins' / (name + '.ets')
                     for name in ('SpeechPlugin', 'OhosSpeechPlayback', 'OhosPcmStream', 'PcmStreamTypes', 'PcmByteQueue',
                                  'OhosSpeechCall', 'OhosCallRoute', 'OhosCallCapture', 'CallEnergyGate', 'VoicePcmTap',
                                  'VoicePcm', 'VoiceTypes', 'VoiceMicLease')]
        drivers += [repo / 'runtime/tests/ohos/call-platform-contract.d.ts']
    sources = sorted(set(drivers + products))
    snapshot = lambda: {str(path): {'bytes': path.stat().st_size, 'sha256': sha(path)} for path in sources}
    before = snapshot(); save(out / 'sources-before.json', before)
    save(out / 'command.json', {'argv': argv, 'cwd': str(repo), 'env': env_values,
                               'productSourceRoot': str(product)})
    typecheck = None
    if not args.baseline_root:
        stage = out / 'typescript-source'; stage.mkdir()
        staged = []
        for path in products:
            if path.parent.name == 'plugins':
                target = stage / (path.stem + '.ts'); target.write_bytes(path.read_bytes())
                assert sha(target) == sha(path)
                staged.append(target)
        for name in ('pcm-audio-contract.d.ts', 'speech-flutter-contract.d.ts', 'call-platform-contract.d.ts'):
            target = stage / name; target.write_bytes((repo / 'runtime/tests/ohos' / name).read_bytes())
            staged.append(target)
        types = stage / 'empty-types'; types.mkdir()
        type_argv = [str(node), str(prefix / 'node_modules/typescript/lib/tsc.js'), '--strict', '--noEmit',
                     '--target', 'ES2022', '--module', 'commonjs', '--lib', 'ES2022', '--typeRoots', str(types),
                     *map(str, staged)]
        save(out / 'type-command.json', {'argv': type_argv, 'cwd': str(repo),
                                       'scope': 'Strict TypeScript with explicit host boundary declarations; not SDK ArkTS'})
        with (out / 'typescript.log').open('wb') as log:
            type_code = subprocess.run(type_argv, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=90).returncode
        typecheck = {'exitCode': type_code, 'scope': 'host declarations only'}
    started = time.monotonic()
    with (out / 'test.log').open('wb') as log:
        try:
            code = subprocess.run(argv, cwd=repo, env=dict(os.environ, **env_values),
                                  stdout=log, stderr=subprocess.STDOUT, timeout=120).returncode
        except subprocess.TimeoutExpired:
            code = 124
    after = snapshot(); save(out / 'sources-after.json', after)
    text = (out / 'test.log').read_text()
    counts = {name: int(match.group(1)) for name in ('tests', 'pass', 'fail', 'cancelled', 'skipped')
              if (match := re.search(r'^# ' + name + r' (\d+)$', text, re.M))}
    expected_red = args.baseline_root is not None
    if expected_red:
        accepted = (code == 1 and counts.get('tests') == 1 and counts.get('fail') == 1 and
                    'SPEECH_CHANNEL_NOT_REGISTERED_OR_UNAVAILABLE' in text and 'missing: true' in text)
    else:
        accepted = (code == 0 and counts.get('tests', 0) > 0 and counts.get('fail') == 0 and
                    counts.get('cancelled') == 0 and counts.get('skipped') == 0)
    accepted = accepted and before == after and (typecheck is None or typecheck['exitCode'] == 0)
    report = {
        'schema': 1, 'status': ('EXPECTED_BASELINE_RED' if expected_red else 'PASS_SCOPED') if accepted else 'FAIL',
        'childExitCode': code, 'counts': counts, 'mode': args.mode,
        'elapsedSeconds': time.monotonic() - started, 'inputsUnchanged': before == after,
        'nodeSha256': sha(node), 'typescriptVersion': version,
        'typescriptSourceSha256': sha(prefix / 'node_modules/typescript/lib/typescript.js'),
        'typecheck': typecheck,
        'scope': ('Actual unchanged EntryAbility registration with explicit platform/unrelated plugin boundaries'
                  if expected_red else
                  'Actual ETS/EntryAbility, explicit platform boundaries; includes separately labelled design-only preflight coordinator'),
        'requiresNativeDependency': not expected_red,
        'notRun': ['actual dd130b31 Dart execution', 'HarmonyOS SDK compile', 'device playback/focus', 'paid synthesis'],
        'overallReadAloudStatus': 'BLOCKED_SOURCE_BASELINE',
    }
    save(out / 'report.json', report)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if accepted else 1


if __name__ == '__main__':
    raise SystemExit(main())
