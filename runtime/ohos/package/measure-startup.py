#!/usr/bin/env python3
"""Paired Linux strict-simulation runs with empty/reused V8 compile caches.

This does not flush the operating system's page cache or measure an OHOS device.
Both prefixes must already be built; no input tree is modified.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess


def cache_size(root):
    files = [path for path in root.rglob('*') if path.is_file()]
    return {'files': len(files), 'bytes': sum(path.stat().st_size for path in files)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('before', 'after', 'node', 'native-library-dir', 'publication-fixture', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--before-runtime-root', type=Path,
                        help='Explicit same-source runtime/ohos directory for an unpruned development reference')
    parser.add_argument('--samples', type=int, default=5)
    args = parser.parse_args()
    if args.samples < 1:
        parser.error('--samples must be positive')
    repo = Path(__file__).resolve().parents[3]
    args.out = args.out.absolute()
    args.out.mkdir(parents=True, exist_ok=False)
    variants = {}
    for name in ('before', 'after'):
        prefix = getattr(args, name).resolve(strict=True)
        runtime = (args.before_runtime_root.resolve(strict=True) if name == 'before' and args.before_runtime_root
                   else prefix / 'runtime/ohos')
        variants[name] = {'prefix': str(prefix), 'runtimeRoot': str(runtime),
            'layout': 'unpruned fixed npm prefix with explicitly separate same-source runtime' if
                name == 'before' and args.before_runtime_root else 'materialized runtime tree'}
    # The after side must be the actual assembled payload, not another npm prefix.
    after_manifest = args.after.resolve(strict=True).parent / 'manifest.json'
    if not after_manifest.is_file():
        raise ValueError('The after variant requires its real assembled manifest')
    variants['after']['runtimeVersion'] = json.loads(after_manifest.read_text())['runtimeVersion']
    (args.out / 'variants.json').write_text(json.dumps(variants, indent=2) + '\n')
    rows = []
    for index in range(args.samples):
        # Alternate which variant runs first, while retaining cold→warm order.
        for name in (['before', 'after'] if index % 2 == 0 else ['after', 'before']):
            prefix = getattr(args, name).resolve(strict=True)
            cache = args.out / f'{name}-{index + 1}-cache'
            for temperature in ['cold', 'warm']:
                case = args.out / f'{name}-{index + 1}-{temperature}'
                profile = args.out / f'{case.name}-profile.json'
                runtime = Path(variants[name]['runtimeRoot'])
                process = runtime / 'process'
                profile.write_text(json.dumps([
                    {'id': 'subprocess', 'disabled': True}, {'id': 'sandbox', 'disabled': True},
                    {'insert': [
                        {'id': 'ohos-subprocess', 'name': str(process / 'index.mjs'),
                         'config': {'workspaceRoots': [str(case / 'workspace')]}},
                        {'id': 'ohos-sandbox', 'name': str(process / 'sandbox.mjs')},
                        {'id': 'ohos-runtime-capabilities', 'name': str(runtime / 'capabilities/index.mjs')},
                        {'id': 'ohos-lifecycle', 'name': str(runtime / 'lifecycle/index.mjs')}]}], indent=2) + '\n')
                native = args.native_library_dir.resolve(strict=True)
                command = [str(args.node), str(repo / 'runtime/ohos/sim/round.mjs'),
                    '--prefix', str(prefix), '--out', str(case), '--mode', 'sim', '--platform',
                    '--patch', str(profile), '--import', str(runtime / 'preload.mjs'),
                    '--linked-publication-fixture', str(args.publication_fixture.resolve(strict=True)),
                    '--allow-addon', str(native / 'libdsh_flock.so'),
                    '--allow-addon', str(native / 'libdsh_require_builtin.so'),
                    '--native-library-dir', str(native), '--compile-cache-dir', str(cache)]
                before = cache_size(cache)
                load = os.getloadavg()
                result = subprocess.run(command, capture_output=True, text=True, timeout=120)
                (args.out / (case.name + '-command.json')).write_text(json.dumps({
                    'command': command, 'code': result.returncode,
                    'stdout': result.stdout, 'stderr': result.stderr}, indent=2) + '\n')
                result.check_returncode()
                report = json.loads((case / 'report.json').read_text())
                if report['status'] != 'PASS' or report['approvals'] != 2:
                    raise ValueError('Every timing sample must complete the real five-tool/two-approval round')
                if (temperature == 'cold' and before['files'] != 0) or (temperature == 'warm' and before['files'] == 0):
                    raise ValueError('Compile-cache temperature did not match the measured case')
                row = {'variant': name, 'sample': index + 1, 'cache': temperature,
                    'loadAverageBefore': load, 'cacheBefore': before, 'cacheAfter': cache_size(cache),
                    **{key: report[key] for key in ['urlReadyMs', 'hostReadyMs', 'firstRoundMs']}}
                rows.append(row)
                (args.out / 'samples.json').write_text(json.dumps(rows, indent=2) + '\n')
                print(json.dumps(row), flush=True)
    summary = []
    for variant in ['before', 'after']:
        for temperature in ['cold', 'warm']:
            selected = [row for row in rows if row['variant'] == variant and row['cache'] == temperature]
            values = {}
            for metric in ['urlReadyMs', 'hostReadyMs', 'firstRoundMs']:
                numbers = [row[metric] for row in selected]
                values[metric] = {'median': statistics.median(numbers), 'min': min(numbers), 'max': max(numbers)}
            summary.append({'variant': variant, 'cache': temperature, 'samples': len(selected), **values})
    (args.out / 'report.json').write_text(json.dumps({
        'scope': 'Linux Node24.22.1 --jitless strict simulation; real DSH and local fake-model fixtures',
        'coldDefinition': 'empty V8 compile-cache directory; OS page cache was not flushed',
        'warmDefinition': 'new process/home/workspace reuses immediately preceding compile cache',
        'host': platform.platform(), 'variants': variants,
        'layoutCaveat': 'A separate development runtime root changes file layout and module resolution. These samples compare the stated end-to-end layouts, not a controlled proof of the isolated pruning effect.',
        'summary': summary, 'samples': rows}, indent=2) + '\n')


if __name__ == '__main__':
    main()
