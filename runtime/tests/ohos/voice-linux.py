#!/usr/bin/env python3
"""Actual ETS logic with explicit platform doubles; never an HMS/AudioCapturer device claim."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import time
import wave

parser = argparse.ArgumentParser()
parser.add_argument('--node', required=True, type=Path)
parser.add_argument('--typescript-prefix', required=True, type=Path)
parser.add_argument('--out', required=True, type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
node = args.node.resolve()
prefix = args.typescript_prefix.resolve()
wav_path = out / 'actual-recorder.wav'
env_values = {'OHOS_TYPESCRIPT_PREFIX': str(prefix), 'OHOS_VOICE_WAV_OUTPUT': str(wav_path)}
env = dict(os.environ, **env_values)
argv = [str(node), '--test', '--test-isolation=none', '--test-reporter=tap',
        'runtime/tests/ohos/voice-channel.test.mjs']
sources = list((repo / 'app/ohos/entry/src/main/ets/plugins').glob('*Voice*.ets'))
sources += [repo / 'app/ohos/entry/src/main/ets/plugins/HmsKits.ets', repo / 'app/ohos/entry/src/main/ets/plugins/HmsSpeechKit.ets']
sources += list((repo / 'runtime/tests/ohos').glob('voice-*.mjs')) + [Path(__file__).resolve()]
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
(out / 'sources.json').write_text(json.dumps({str(p.relative_to(repo)): sha(p) for p in sources}, indent=2) + '\n')
(out / 'command.json').write_text(json.dumps({'argv': argv, 'cwd': str(repo), 'env': env_values}, indent=2) + '\n')
start = time.time()
with (out / 'test.log').open('wb') as log:
    try:
        code = subprocess.run(argv, cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120).returncode
    except subprocess.TimeoutExpired:
        code = 124
text = (out / 'test.log').read_text()
counts = {name: int(re.search(r'^# ' + name + r' (\d+)$', text, re.M).group(1))
          for name in ('tests', 'pass', 'fail', 'cancelled', 'skipped')
          if re.search(r'^# ' + name + r' (\d+)$', text, re.M)}
decoded = None
if code == 0:
    with wave.open(str(wav_path), 'rb') as wav:
        decoded = {'channels': wav.getnchannels(), 'sampleWidth': wav.getsampwidth(),
                   'sampleRate': wav.getframerate(), 'frames': wav.getnframes(),
                   'samples': list(struct.unpack('<4h', wav.readframes(4))), 'sha256': sha(wav_path)}
    assert {k: decoded[k] for k in ('channels', 'sampleWidth', 'sampleRate', 'frames', 'samples')} == {
        'channels': 1, 'sampleWidth': 2, 'sampleRate': 16000, 'frames': 4,
        'samples': [0, 32767, -32768, 4660]}
report = {'exitCode': code, 'elapsedSeconds': time.time() - start, 'counts': counts,
          'nodeSha256': sha(node), 'typescriptVersion': json.loads((prefix / 'node_modules/typescript/package.json').read_text())['version'],
          'waveDecoder': decoded,
          'scope': 'Actual ETS implementation, explicit Flutter/OH audio/HMS/permissions doubles; UNCOMPILED_HMS; no device microphone'}
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
raise SystemExit(code)
