#!/usr/bin/env python3
"""Finite chat-video gate: actual ETS/channel + native safe FD open on Linux."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--node', required=True, type=Path)
    parser.add_argument('--node-headers', required=True, type=Path)
    parser.add_argument('--typescript-prefix', required=True, type=Path)
    parser.add_argument('--embedding-har', required=True, type=Path)
    parser.add_argument('--cxx', default='g++')
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--mode', choices=('plain', 'jitless'), default='plain')
    parser.add_argument('--baseline-root', type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    product = args.baseline_root.resolve() if args.baseline_root else repo
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=False)
    node, prefix = args.node.resolve(), args.typescript_prefix.resolve()
    version = json.loads((prefix / 'node_modules/typescript/package.json').read_text())['version']
    if not version.startswith('5.9.'):
        raise ValueError('TypeScript 5.9.x is required')
    tests = repo / 'runtime/tests/ohos'
    embedding_lock = repo / 'tooling/ohos/embedding-fixes/pasteboard-settlement.json'
    embedding_har = args.embedding_har.resolve()
    if sha(embedding_har) != json.loads(embedding_lock.read_text())['upstream']['harSha256']:
        raise ValueError('OH Flutter embedding HAR differs from the repository pin')
    with tarfile.open(embedding_har) as archive:
        archive.extractall(out / 'embedding', filter='data')
    embedding = out / 'embedding/package'
    sources = [tests / name for name in ('media-video-fixture.mjs', 'media-video.test.mjs',
        'media-video-linux.py', 'media-video-contract.d.ts', 'user-file-access-addon.cc')]
    sources += [product / 'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets',
        product / 'runtime/tests/ohos/entry-ability-fixture.mjs',
        repo / 'app/ohos/entry/src/main/cpp/file_access.h',
        repo / 'app/ohos/entry/src/main/ets/plugins/FilesMediaPlugin.ets',
        repo / 'app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/media/MediaVideoPlugin.kt',
        repo / 'app/lib/media/video.dart', repo / 'app/lib/ui/chat/media/media_video_viewer.dart']
    sources += [embedding_lock, embedding_har]
    sources += [embedding / name for name in ('src/main/ets/view/TextureRegistry.ets',
        'src/main/ets/embedding/engine/renderer/FlutterRenderer.ets',
        'src/main/ets/embedding/engine/FlutterNapi.ets', 'src/main/ets/embedding/engine/plugins/FlutterPlugin.ets',
        'src/main/ets/embedding/engine/FlutterEngine.ets', 'src/main/ets/embedding/engine/FlutterEngineConnectionRegistry.ets')]
    if not args.baseline_root:
        sources += [product / 'app/ohos/entry/src/main/ets/plugins' / (name + '.ets')
            for name in ('MediaVideoPlugin', 'OhosMediaVideo')]
        sources.append(product / 'app/ohos/entry/src/main/ets/runtime/RuntimePaths.ets')
    snapshot = lambda: {str(path): {'bytes': path.stat().st_size, 'sha256': sha(path)} for path in sources}
    before = snapshot(); save(out / 'sources-before.json', before)
    addon = out / 'user-file-access.node'
    build = [args.cxx, '-std=c++17', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
        '-I', str(args.node_headers.resolve()), str(tests / 'user-file-access-addon.cc'), '-o', str(addon)]
    save(out / 'native-command.json', {'argv': build, 'cwd': str(repo), 'scope': 'Linux host N-API, not cross compilation'})
    with (out / 'native-build.log').open('wb') as log:
        subprocess.run(build, cwd=repo, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
    typecheck = None
    if not args.baseline_root:
        stage = out / 'typescript-source'; stage.mkdir()
        (stage / 'plugins').mkdir(); (stage / 'runtime').mkdir(); (stage / 'empty-types').mkdir()
        for name in ('MediaVideoPlugin', 'OhosMediaVideo'):
            (stage / 'plugins' / (name + '.ts')).write_bytes(
                (product / 'app/ohos/entry/src/main/ets/plugins' / (name + '.ets')).read_bytes())
        (stage / 'runtime/RuntimePaths.ts').write_bytes(
            (product / 'app/ohos/entry/src/main/ets/runtime/RuntimePaths.ets').read_bytes())
        (stage / 'media-video-contract.d.ts').write_bytes((tests / 'media-video-contract.d.ts').read_bytes())
        save(stage / 'tsconfig.json', {'compilerOptions': {'strict': True, 'noEmit': True, 'target': 'ES2022',
            'module': 'commonjs', 'lib': ['ES2022'], 'typeRoots': ['./empty-types']},
            'include': ['plugins/*.ts', 'runtime/*.ts', '*.d.ts']})
        type_argv = [str(node), str(prefix / 'node_modules/typescript/lib/tsc.js'), '--project', str(stage / 'tsconfig.json')]
        save(out / 'type-command.json', {'argv': type_argv, 'cwd': str(repo), 'scope': 'Host-only declarations; not ArkTS SDK'})
        with (out / 'typescript.log').open('wb') as log:
            type_code = subprocess.run(type_argv, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=90).returncode
        typecheck = {'exitCode': type_code, 'scope': 'strict host TypeScript only'}
    env = {'OHOS_TYPESCRIPT_PREFIX': str(prefix), 'OHOS_VIDEO_SOURCE_ROOT': str(product),
        'OHOS_USER_FILE_ADDON': str(addon), 'OHOS_FLUTTER_EMBEDDING': str(embedding)}
    argv = [str(node), *(['--jitless'] if args.mode == 'jitless' else []), '--test', '--test-isolation=none', '--test-reporter=tap']
    if args.baseline_root:
        argv.append('--test-name-pattern=^actual EntryAbility registers')
    argv.append('runtime/tests/ohos/media-video.test.mjs')
    save(out / 'command.json', {'argv': argv, 'cwd': str(repo), 'env': env})
    started = time.monotonic()
    with (out / 'test.log').open('wb') as log:
        try:
            code = subprocess.run(argv, cwd=repo, env={**os.environ, **env}, stdout=log, stderr=subprocess.STDOUT, timeout=120).returncode
        except subprocess.TimeoutExpired:
            code = 124
    after = snapshot(); save(out / 'sources-after.json', after)
    output = (out / 'test.log').read_text()
    counts = {key: int(match.group(1)) for key in ('tests', 'pass', 'fail', 'cancelled', 'skipped')
        if (match := re.search(r'^# ' + key + r' (\d+)$', output, re.M))}
    accepted = (code == 1 and counts.get('tests') == 1 and counts.get('fail') == 1 and 'CHAT_VIDEO_CHANNEL_MISSING' in output) \
        if args.baseline_root else (code == 0 and counts.get('tests', 0) > 0 and counts.get('fail') == 0 and
            counts.get('cancelled') == 0 and counts.get('skipped') == 0)
    accepted = accepted and before == after and (typecheck is None or typecheck['exitCode'] == 0)
    report = {'schema': 1, 'status': ('EXPECTED_BASELINE_RED' if args.baseline_root else 'TESTS_PASSED') if accepted else 'FAIL',
        'childExitCode': code, 'counts': counts, 'mode': args.mode, 'typecheck': typecheck,
        'elapsedSeconds': time.monotonic() - started, 'inputsUnchanged': before == after,
        'nodeSha256': sha(node), 'typescriptVersion': version,
        'typescriptSourceSha256': sha(prefix / 'node_modules/typescript/lib/typescript.js'), 'addonSha256': sha(addon),
        'scope': 'Actual Entry/ETS + pinned OH FlutterRenderer + native openUserFile; explicit OS codec/focus/FlutterNapi boundaries',
        'notRun': ['HarmonyOS SDK ArkTS compile', 'device codec/texture/audio focus/seek precision', 'full unified gates'],
        'independentReview': 'REQUIRED_SEPARATELY'}
    save(out / 'report.json', report)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if accepted else 1


if __name__ == '__main__':
    raise SystemExit(main())
