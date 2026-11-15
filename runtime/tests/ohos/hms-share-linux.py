#!/usr/bin/env python3
"""Actual Linux ETS+FS probe. This does not compile HMS/ArkTS or run a device."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node', type=Path, required=True)
    parser.add_argument('--node-headers', type=Path, required=True)
    parser.add_argument('--typescript-prefix', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--cxx', default='clang++-18')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    node = args.node.resolve()
    headers = args.node_headers.resolve()
    prefix = args.typescript_prefix.resolve()
    paths = repo / 'app/ohos/entry/src/main/ets/runtime/RuntimePaths.ets'
    if not paths.is_file():
        raise SystemExit('P2 v6 RuntimePaths dependency is missing; apply the documented P2 v6 stack first')
    commands: list[dict] = []

    def run(name: str, argv: list[str], extra_env: dict[str, str] | None = None) -> int:
        begin = time.time()
        env = dict(os.environ)
        env.update(extra_env or {})
        with (out / (name + '.log')).open('wb') as log:
            try:
                code = subprocess.run(argv, cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT,
                                      timeout=180).returncode
            except subprocess.TimeoutExpired:
                code = 124
        commands.append({'name': name, 'argv': argv, 'environment': extra_env or {},
                         'exitCode': code, 'elapsedSeconds': time.time() - begin})
        (out / 'commands.json').write_text(json.dumps(commands, ensure_ascii=False, indent=2) + '\n')
        return code

    addon = out / 'user-file-access.node'
    source = repo / 'runtime/tests/ohos/user-file-access-addon.cc'
    code = run('native-build', [args.cxx, '-std=c++17', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                               '-I', str(headers), str(source), '-o', str(addon)])
    if code:
        return code
    with tempfile.TemporaryDirectory(prefix='dsh-hms-share-probe-') as temporary:
        fifo = Path(temporary) / 'external.fifo'
        os.mkfifo(fifo, 0o600)
        code = run('logic', [str(node), '--test', '--test-isolation=none', '--test-reporter=tap',
                            str(repo / 'runtime/tests/ohos/hms-share-channel.test.mjs')], {
            'OHOS_TYPESCRIPT_PREFIX': str(prefix), 'OHOS_USER_FILE_ADDON': str(addon),
            'OHOS_SHARE_FIFO': str(fifo),
        })
    tested = [*sorted((repo / 'app/ohos/entry/src/main/ets/plugins').glob('HmsShare*.ets')),
              repo / 'app/ohos/entry/src/main/ets/plugins/HmsKits.ets',
              paths, repo / 'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets',
              repo / 'app/ohos/entry/src/main/module.json5', source,
              repo / 'app/ohos/entry/src/main/cpp/file_access.h', Path(__file__).resolve(),
              repo / 'runtime/tests/ohos/hms-share-fixture.mjs',
              repo / 'runtime/tests/ohos/hms-share-channel.test.mjs']
    log = (out / 'logic.log').read_text()
    counts = {key: int(value) for key, value in re.findall(r'^# (tests|pass|fail|cancelled|skipped|todo) (\d+)$', log, re.M)}
    report = {
        'scope': 'Actual ETS bodies after TS erasure; real Linux filesystem and production descriptor opener. HMS/Flutter/URI-grant/display boundaries are explicit doubles.',
        'hms': 'UNCOMPILED_HMS', 'arkts': 'Not run by this script; separate check-arkts evidence required',
        'exitCode': code, 'counts': counts,
        'node': {'path': str(node), 'sha256': sha(node)},
        'typescript': json.loads((prefix / 'node_modules/typescript/package.json').read_text())['version'],
        'addonSha256': sha(addon), 'sources': [{'path': str(path.relative_to(repo)), 'sha256': sha(path)} for path in tested],
        'logs': [{'path': path.name, 'sha256': sha(path)} for path in [out / 'native-build.log', out / 'logic.log', out / 'commands.json']],
    }
    (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'scope': report['scope'], 'exitCode': code, 'counts': counts, 'report': str(out / 'report.json')}, ensure_ascii=False))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
