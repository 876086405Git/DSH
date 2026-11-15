#!/usr/bin/env python3
"""Real PCM ETS bodies with explicit AudioRenderer doubles; no target SDK or device claim."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

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
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
product_names = ['OhosPcmStream.ets', 'PcmByteQueue.ets', 'PcmStreamTypes.ets']
products = [repo / 'app/ohos/entry/src/main/ets/plugins' / name for name in product_names]
tests = [repo / 'runtime/tests/ohos' / name for name in
         ['pcm-stream.test.mjs', 'pcm-stream-call.test.mjs', 'pcm-stream-fixture.mjs', 'pcm-audio-contract.d.ts', 'pcm-stream-native.py']]
sources = products + tests + [repo / 'tooling/ohos/run-gates.py', repo / 'docs/design/harmonyos/speech-pcm.md']
before = {str(path.relative_to(repo)): sha(path) for path in sources}
(out / 'sources.json').write_text(json.dumps(before, indent=2) + '\n')
version = json.loads((prefix / 'node_modules/typescript/package.json').read_text())['version']
if version != '5.9.3':
    raise SystemExit('requires the pinned TypeScript 5.9.3; got ' + version)
commands = []


def run(name, argv, env):
    command = {'name': name, 'argv': [str(arg) for arg in argv], 'cwd': str(repo),
               'env': {'OHOS_TYPESCRIPT_PREFIX': str(prefix)}}
    commands.append(command)
    start = time.monotonic()
    with (out / (name + '.log')).open('wb') as log:
        try:
            code = subprocess.run(command['argv'], cwd=repo, env=env, stdout=log,
                                  stderr=subprocess.STDOUT, timeout=90).returncode
        except subprocess.TimeoutExpired:
            code = 124
    text = (out / (name + '.log')).read_text()
    counts = {key: int(match.group(1)) for key in ('tests', 'pass', 'fail', 'skipped', 'cancelled')
              if (match := re.search(r'^# ' + key + r' (\d+)$', text, re.M))}
    return {'exitCode': code, 'elapsedSeconds': time.monotonic() - start, 'counts': counts}


env = dict(os.environ, OHOS_TYPESCRIPT_PREFIX=str(prefix))
stage = out / 'typescript-source'
stage.mkdir(exist_ok=True)
staged = []
for path in products:
    target = stage / (path.stem + '.ts')
    target.write_bytes(path.read_bytes())
    assert sha(target) == sha(path), 'typechecked source differs'
    staged.append(target)
surface = stage / 'pcm-audio-contract.d.ts'
surface.write_bytes((repo / 'runtime/tests/ohos/pcm-audio-contract.d.ts').read_bytes())
empty_types = stage / 'empty-types'
empty_types.mkdir(exist_ok=True)
type_result = run('typescript', [node, prefix / 'node_modules/typescript/lib/tsc.js', '--strict',
    '--noEmit', '--target', 'ES2022', '--module', 'commonjs', '--lib', 'ES2022',
    '--typeRoots', empty_types, *staged, surface], env)
results = {'typescript': type_result}
if type_result['exitCode'] == 0:
    for name, flags in [('plain', []), ('jitless', ['--jitless'])]:
        result = run(name, [node, *flags, '--test', '--test-isolation=none', '--test-reporter=tap',
                           repo / 'runtime/tests/ohos/pcm-stream.test.mjs',
                           repo / 'runtime/tests/ohos/pcm-stream-call.test.mjs'], env)
        results[name] = result
        if result['exitCode'] == 0:
            assert result['counts'].get('tests', 0) > 0 and result['counts']['pass'] == result['counts']['tests']
            assert all(result['counts'].get(key, -1) == 0 for key in ('fail', 'skipped', 'cancelled'))
after = {str(path.relative_to(repo)): sha(path) for path in sources}
unchanged = before == after
(out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
ok = unchanged and len(results) == 3 and all(result['exitCode'] == 0 for result in results.values())
report = {'exitCode': 0 if ok else 1, 'nodeSha256': sha(node), 'typescriptVersion': version,
          'sourceUnchangedDuringRun': unchanged, 'results': results,
          'scope': 'Actual ETS backend/queue with explicit AudioRenderer/timer doubles; '
                   'strict TypeScript against documented host surface; not ArkTS/API-26/device execution',
          'notRun': ['HarmonyOS SDK ArkTS compiler', 'AudioRenderer service/device', 'real Dart paid-request preflight'],
          'integrationStatus': 'SCOPED_NATIVE_ONLY; Dart admission is verified by the separate speech-upper gate'}
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
raise SystemExit(report['exitCode'])
