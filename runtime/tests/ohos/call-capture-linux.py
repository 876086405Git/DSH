#!/usr/bin/env python3
"""Actual call/tap ETS and existing dictation; explicit OS and Flutter boundaries."""
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
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=False)
    node = args.node.resolve(); prefix = args.typescript_prefix.resolve()
    version = json.loads((prefix / 'node_modules/typescript/package.json').read_text())['version']
    if not version.startswith('5.9.'):
        raise ValueError('TypeScript 5.9.x is required')
    tests = ['call-capture.test.mjs', 'call-control.test.mjs', 'voice-pcm-tap.test.mjs',
             'speech-call-channel.test.mjs', 'voice-channel.test.mjs', 'call-route.test.mjs', 'call-start-mute.test.mjs', 'call-start-pause.test.mjs']
    drivers = [repo / 'runtime/tests/ohos' / name for name in
               tests + ['call-capture-fixture.mjs', 'call-route-fixture.mjs', 'voice-fixture.mjs', 'call-capture-linux.py']]
    plugins = repo / 'app/ohos/entry/src/main/ets/plugins'
    products = list(plugins.glob('*Voice*.ets')) + [plugins / (name + '.ets') for name in
               ['CallEnergyGate', 'OhosCallCapture', 'OhosSpeechCall', 'OhosCallRoute', 'SpeechPlugin',
                'OhosPcmStream', 'PcmByteQueue', 'HmsTextToSpeechKit',
                'PcmStreamTypes', 'OhosSpeechPlayback', 'HmsKits', 'HmsSpeechKit', 'HmsAsrLease']]
    reference = repo / 'app/android/app/src/main/kotlin/ai/dsh/go/SpeechPlugin.kt'
    # Android is a read-only method-name oracle for speech-call-channel.test.mjs.
    if not reference.exists():
        reference = next((repo / 'app/android').rglob('SpeechPlugin.kt'))
    sources = sorted(set(drivers + products + [reference]))
    snapshot = lambda: {str(p.relative_to(repo)): {'bytes': p.stat().st_size, 'sha256': sha(p)} for p in sources}
    before = snapshot(); save(out / 'sources-before.json', before)
    env_values = {'OHOS_TYPESCRIPT_PREFIX': str(prefix)}
    argv = [str(node)] + (['--jitless'] if args.mode == 'jitless' else [])
    argv += ['--test', '--test-isolation=none', '--test-reporter=tap'] + ['runtime/tests/ohos/' + name for name in tests]
    save(out / 'command.json', {'argv': argv, 'cwd': str(repo), 'env': env_values})
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
    accepted = code == 0 and counts.get('tests', 0) > 0 and counts.get('fail') == 0 and \
        counts.get('cancelled') == 0 and counts.get('skipped') == 0 and before == after
    report = {'schema': 1, 'status': 'PASS_SCOPED' if accepted else 'FAIL', 'childExitCode': code,
              'counts': counts, 'mode': args.mode, 'elapsedSeconds': time.monotonic() - started,
              'inputsUnchanged': before == after, 'nodeSha256': sha(node), 'typescriptVersion': version,
              'typescriptSourceSha256': sha(prefix / 'node_modules/typescript/lib/typescript.js'),
              'scope': 'Actual ETS call energy/capture/control/tap/channel, system-TTS app-route and existing dictation; explicit OS/Flutter boundaries',
              'notRun': ['HarmonyOS SDK/HAP', 'physical microphone/AEC', 'Silero/smart-turn',
                         'device ASR accuracy', 'actual speaker route or screen power'],
              'requiresCumulativePlaybackGate': 'pcm-stream-native plus speech-channel plain/jitless'}
    save(out / 'report.json', report); print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if accepted else 1


if __name__ == '__main__':
    raise SystemExit(main())
