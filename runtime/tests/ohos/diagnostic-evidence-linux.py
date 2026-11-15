#!/usr/bin/env python3
"""Actual diagnostic ETS over real files; HiAppEvent and Flutter are OS boundaries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--node', type=Path, required=True)
    p.add_argument('--typescript-prefix', type=Path, required=True)
    p.add_argument('--zlib-addon', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    repo = Path(__file__).resolve().parents[3]
    out = a.out.resolve(); out.mkdir(parents=True, exist_ok=False)
    node, prefix, zlib = a.node.resolve(), a.typescript_prefix.resolve(), a.zlib_addon.resolve()
    version = json.loads((prefix / 'node_modules/typescript/package.json').read_text())['version']
    if not version.startswith('5.9.'):
        raise ValueError('TypeScript 5.9.x is required; exact observed version is recorded, not pinned')
    plugin_names = ['DiagnosticsPlugin', 'OhosDiagnosticEvidence', 'OhosFaultEvents', 'OhosKeyboardLog']
    sources = [repo / 'app/ohos/entry/src/main/ets/plugins' / (name + '.ets') for name in plugin_names]
    sources += [repo / 'app/ohos/entry/src/main/ets/plugins/OhosDeviceFacts.ets']
    sources += [repo / 'app/ohos/entry/src/main/ets/runtime' / (name + '.ets') for name in
                ['PersistedRuntimeLog', 'RuntimeCore', 'RuntimeController', 'RuntimeLifecycle',
                 'RuntimeZip', 'OhosRuntimeArchive', 'OhosRuntimeStorage']]
    sources += [repo / 'runtime/tests/ohos' / name for name in
                ['diagnostic-evidence.test.mjs', 'diagnostic-keyboard.test.mjs', 'diagnostic-evidence-cold.mjs', 'diagnostics-fixture.mjs',
                 'diagnostic-evidence-linux.py', 'diagnostic-evidence-host.d.ts', 'keyboard-geometry-host.d.ts', 'diagnostic-evidence-data_test.dart']]
    sources += [repo / 'tooling/ohos/tests/runtime-archive-fixture.mjs', repo / 'tooling/ohos/run-gates.py']
    sources += [repo / 'app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/diagnostics/EvidenceStore.kt']
    sources += [repo / 'app/lib/diagnostics' / name for name in
                ['diagnostics_channel.dart', 'automatic_diagnostics.dart', 'diagnostics_sections.dart']]
    snapshot = lambda: {str(path.relative_to(repo)): sha(path) for path in sources}
    before = snapshot(); save(out / 'sources-before.json', before)
    stage = out / 'typescript-source'; plugins = stage / 'plugins'; runtime = stage / 'runtime'
    plugins.mkdir(parents=True); runtime.mkdir(); (stage / 'empty-types').mkdir()
    for name in plugin_names:
        origin = repo / 'app/ohos/entry/src/main/ets/plugins' / (name + '.ets')
        target = plugins / (name + '.ts'); target.write_bytes(origin.read_bytes())
        assert sha(target) == sha(origin)
    (stage / 'host.d.ts').write_bytes((repo / 'runtime/tests/ohos/diagnostic-evidence-host.d.ts').read_bytes())
    (stage / 'window.d.ts').write_bytes((repo / 'runtime/tests/ohos/keyboard-geometry-host.d.ts').read_bytes())
    # Type-only surfaces for unchanged neighbors. Runtime tests load their real bodies.
    (plugins / 'OhosDeviceFacts.d.ts').write_text('export declare function ohosDeviceIdentity(): Map<string, unknown>;\nexport declare function systemMemoryBytes(): number | null;\n')
    (runtime / 'RuntimeCore.d.ts').write_text('export interface RuntimeFile {size: number;}\nexport interface RuntimeManifest {runtimeVersion: string; dshVersion: string; nodeVersion: string; files: RuntimeFile[];}\n')
    (runtime / 'OhosRuntimeStorage.d.ts').write_text("import {RuntimeManifest} from './RuntimeCore';\nexport declare class OhosRuntimeStorage {constructor(resources: object, filesDir: string); readBundledManifest(): Promise<RuntimeManifest>;}\n")
    (runtime / 'PersistedRuntimeLog.d.ts').write_text('export declare class PersistedRuntimeLog {static get(filesDir: string): PersistedRuntimeLog; tail(limit: number): Promise<string[]>; facts(): Map<string, unknown>;}\n')
    save(stage / 'tsconfig.json', {'compilerOptions': {'strict': True, 'noEmit': True, 'target': 'ES2022',
         'module': 'commonjs', 'lib': ['ES2022'], 'typeRoots': ['./empty-types']}, 'include': ['**/*.ts']})
    env_values = {'OHOS_TYPESCRIPT_PREFIX': str(prefix), 'OHOS_TEST_ZLIB_ADDON': str(zlib),
                  'DIAGNOSTICS_TMP_PARENT': str(out)}
    env = {**os.environ, **env_values}; env.pop('NODE_OPTIONS', None)
    commands, results = [], {}
    plans = [('typescript', [node, prefix / 'node_modules/typescript/lib/tsc.js', '--project', stage / 'tsconfig.json'])]
    for mode in ['plain', 'jitless']:
        plans.append((mode, [node] + (['--jitless'] if mode == 'jitless' else []) +
                     ['--test', '--test-isolation=none', '--test-reporter=tap', repo / 'runtime/tests/ohos/diagnostic-evidence.test.mjs',
                      repo / 'runtime/tests/ohos/diagnostic-keyboard.test.mjs']))
    for mode in ['write', 'read']:
        plans.append(('cold-' + mode, [node, repo / 'runtime/tests/ohos/diagnostic-evidence-cold.mjs', mode, out / 'cold-root']))
    for name, argv in plans:
        command = [str(value) for value in argv]
        specific = {**env, 'OHOS_DIAGNOSTIC_EVIDENCE_WIRE': str(out / ('wire.json' if name == 'plain' else 'wire-jitless.json'))}
        commands.append({'name': name, 'argv': command, 'cwd': str(repo), 'env': {**env_values,
                         'OHOS_DIAGNOSTIC_EVIDENCE_WIRE': specific['OHOS_DIAGNOSTIC_EVIDENCE_WIRE']}})
        with (out / (name + '.log')).open('wb') as log:
            try: code = subprocess.run(command, cwd=repo, env=specific, stdout=log, stderr=subprocess.STDOUT, timeout=120).returncode
            except subprocess.TimeoutExpired: code = 124
        output = (out / (name + '.log')).read_text()
        counts = {key: int(match.group(1)) for key in ['tests', 'pass', 'fail', 'cancelled', 'skipped']
                  if (match := re.search(r'^# ' + key + r' (\d+)$', output, re.M))}
        valid = code == 0
        if name in ('plain', 'jitless'):
            valid = valid and counts.get('tests', 0) > 0 and counts.get('tests') == counts.get('pass') and all(counts.get(k) == 0 for k in ['fail', 'cancelled', 'skipped'])
        results[name] = {'exitCode': code, 'accepted': valid, 'counts': counts}
    after = snapshot(); save(out / 'sources-after.json', after); save(out / 'commands.json', commands)
    ok = before == after and all(row['accepted'] for row in results.values())
    report = {'status': 'PASS_SCOPED' if ok else 'FAIL', 'results': results, 'inputsUnchanged': before == after,
              'nodeSha256': sha(node), 'typescriptVersion': version,
              'typescriptSourceSha256': sha(prefix / 'node_modules/typescript/lib/typescript.js'), 'zlibAddonSha256': sha(zlib),
              'scope': 'Actual ETS diagnostic plugin/store/watcher, real Linux FD persistence and two cold processes; explicit HiAppEvent/Flutter/errno boundaries; strict host type fixtures',
              'notRun': ['HarmonyOS SDK/ArkTS/HAP', 'actual OS crash/freeze delivery', 'device filesystem cleanup', 'phone startup latency'],
              'requiresDartConsumerGate': 'flutter-diagnostic-evidence', 'independentReview': 'REQUIRED_SEPARATELY'}
    save(out / 'report.json', report); print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
