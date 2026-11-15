#!/usr/bin/env python3
"""Finite actual ETS companion-widget gate; SDK boundaries remain explicit."""
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
    names = ('plugins/CompanionWidgetPlugin', 'companion/CompanionWidgetData', 'companion/CompanionWidgetStore',
        'companion/CompanionWidgetForms', 'formability/CompanionFormAbility')
    sources = [tests / name for name in ('companion-widget-fixture.mjs', 'companion-widget.test.mjs',
        'companion-widget-linux.py', 'companion-widget-child.mjs')]
    sources += [product / 'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets',
        product / 'runtime/tests/ohos/entry-ability-fixture.mjs',
        repo / 'app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/companion/CompanionWidget.kt',
        repo / 'app/lib/companion/companion_widget.dart',
        repo / 'app/lib/ui/companion/companion_page.dart',
        repo / 'app/ohos/entry/src/main/module.json5']
    if not args.baseline_root:
        sources += [product / 'app/ohos/entry/src/main/ets' / (name + '.ets') for name in names]
        sources.append(tests / 'companion-widget-contract.d.ts')
    snapshot = lambda: {str(path): {'bytes': path.stat().st_size, 'sha256': sha(path)} for path in sources}
    before = snapshot(); save(out / 'sources-before.json', before)
    typecheck = None
    if not args.baseline_root:
        stage = out / 'typescript-source'; stage.mkdir(); (stage / 'empty-types').mkdir()
        for name in names:
            (stage / name).parent.mkdir(exist_ok=True)
            (stage / (name + '.ts')).write_bytes((product / 'app/ohos/entry/src/main/ets' / (name + '.ets')).read_bytes())
        (stage / 'contract.d.ts').write_bytes((tests / 'companion-widget-contract.d.ts').read_bytes())
        save(stage / 'tsconfig.json', {'compilerOptions': {'strict': True, 'noEmit': True,
            'target': 'ES2022', 'module': 'commonjs', 'lib': ['ES2022'], 'typeRoots': ['./empty-types']},
            'include': ['**/*.ts']})
        argv = [str(node), str(prefix / 'node_modules/typescript/lib/tsc.js'), '--project', str(stage / 'tsconfig.json')]
        save(out / 'type-command.json', {'argv': argv, 'cwd': str(repo), 'scope': 'Host declarations, not SDK headers'})
        with (out / 'typescript.log').open('wb') as log:
            code = subprocess.run(argv, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=90).returncode
        typecheck = {'exitCode': code, 'scope': 'strict host TypeScript only'}
    env = {'OHOS_TYPESCRIPT_PREFIX': str(prefix), 'OHOS_WIDGET_SOURCE_ROOT': str(product)}
    argv = [str(node), *(['--jitless'] if args.mode == 'jitless' else []), '--test', '--test-isolation=none', '--test-reporter=tap']
    if args.baseline_root:
        argv.append('--test-name-pattern=^actual EntryAbility registers')
    argv.append('runtime/tests/ohos/companion-widget.test.mjs')
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
    accepted = (code == 1 and counts.get('tests') == 1 and counts.get('fail') == 1 and 'COMPANION_WIDGET_CHANNEL_MISSING' in output) \
        if args.baseline_root else (code == 0 and counts.get('tests', 0) > 0 and counts.get('fail') == 0 and
            counts.get('cancelled') == 0 and counts.get('skipped') == 0)
    accepted = accepted and before == after and (typecheck is None or typecheck['exitCode'] == 0)
    report = {'schema': 1, 'status': ('EXPECTED_BASELINE_RED' if args.baseline_root else 'TESTS_PASSED') if accepted else 'FAIL',
        'childExitCode': code, 'counts': counts, 'mode': args.mode, 'typecheck': typecheck,
        'elapsedSeconds': time.monotonic() - started, 'inputsUnchanged': before == after,
        'nodeSha256': sha(node), 'typescriptVersion': version,
        'typescriptSourceSha256': sha(prefix / 'node_modules/typescript/lib/typescript.js'),
        'scope': 'Actual Entry/Form/ETS + independent processes + real Linux file IO/flock; FormKit, UTF-8 conversion and Flutter messenger are explicit boundaries',
        'notRun': ['HarmonyOS SDK ArkTS compilation', 'HarmonyOS process freezing/file-lock behavior, Form page/profile/assets registration and actual desktop rendering', 'full unified gates'],
        'independentReview': 'REQUIRED_SEPARATELY'}
    save(out / 'report.json', report)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if accepted else 1


if __name__ == '__main__':
    raise SystemExit(main())
