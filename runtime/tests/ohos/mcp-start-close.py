#!/usr/bin/env python3
"""Finite real stdio startup/close regressions; explicit guest/native fixture."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record(path):
    return {'path': str(path), 'bytes': path.stat().st_size, 'sha256': sha(path)}


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--prefix', type=Path, required=True)
    parser.add_argument('--node', required=True)
    parser.add_argument('--python', default=sys.executable)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--jitless', action='store_true')
    args = parser.parse_args()
    source, prefix, output = args.source.resolve(), args.prefix.resolve(), args.out.resolve()
    if output.exists() or output.is_relative_to(source) or output.is_relative_to(prefix):
        raise ValueError('Use a fresh output outside both input trees')
    if (source / 'node_modules').resolve() != prefix / 'node_modules':
        raise ValueError('Source resolution must use the supplied OH prefix')
    if os.environ.get('NODE_OPTIONS'):
        raise ValueError('NODE_OPTIONS must be unset')
    node, python = Path(shutil.which(args.node)).absolute(), Path(shutil.which(args.python)).absolute()
    node_version = subprocess.check_output([str(node), '--version'], text=True).strip()
    # ADD5 fixes the major/minor toolchain family, not the patch release.
    if not node_version.startswith('v24.22.'):
        raise ValueError('Node 24.22.x is required')
    python_version = subprocess.check_output([str(python), '--version'], text=True).strip()
    pins_path = source / 'runtime/patches/pins.json'
    pins = json.loads(pins_path.read_text())
    version = json.loads((prefix / 'node_modules/@deepseek-ai/dsh/package.json').read_text())['version']
    final = {}
    for name in pins['targetSets']['ohos']:
        for path, item in pins['patches'][name][version].items():
            final[path] = item['after']
    for path, expected in final.items():
        if sha(prefix / path) != expected:
            raise ValueError('Current official OH final pin differs: ' + path)
    tests = source / 'runtime/tests/ohos'
    paths = [node, python, pins_path, Path(__file__).resolve()]
    paths += [tests / name for name in ['mcp-start-close-actor.mjs', 'mcp-stdio-server.py',
                                      'mcp-stdio-guest-fixture.mjs', 'linux-control-fixture.mjs']]
    for name in ['linux', 'process', 'publication']:
        paths += sorted((source / 'runtime/ohos' / name).rglob('*.mjs'))
    paths += [prefix / path for path in sorted(final)]
    sdk = prefix / 'node_modules/@modelcontextprotocol/client'
    paths += [sdk / 'package.json', *sorted((sdk / 'dist').glob('*.mjs')), *sorted((sdk / 'dist').glob('*.cjs'))]
    paths = sorted(set(paths))
    before = [record(path) for path in paths]
    output.mkdir(parents=True)
    save(output / 'INPUTS-BEFORE.json', {'files': before, 'selectedPatches': pins['targetSets']['ohos'],
                                      'finalPinsChecked': len(final)})
    runs = []
    for variant in ['plugin-normal', 'plugin-blocked', 'sdk-esm-blocked', 'sdk-cjs-blocked']:
        case = output / variant
        argv = [str(node), *(['--jitless'] if args.jitless else []), str(tests / 'mcp-start-close-actor.mjs'), variant]
        delta = {'DSH_PREFIX': str(prefix), 'OHOS_MCP_AUDIT_SOURCE': str(source),
                 'OHOS_MCP_TEST_OUT': str(case), 'OHOS_MCP_PYTHON': str(python)}
        row = {'variant': variant, 'argv': argv, 'cwd': str(source), 'environmentDelta': delta,
               'startedUtc': datetime.datetime.now(datetime.timezone.utc).isoformat()}
        with (output / (variant + '.stdout.log')).open('wb') as stdout, (output / (variant + '.stderr.log')).open('wb') as stderr:
            child = subprocess.Popen(argv, cwd=source, env=dict(os.environ, **delta), stdin=subprocess.DEVNULL,
                                     stdout=stdout, stderr=stderr, start_new_session=True)
            timeout = False
            try:
                code = child.wait(timeout=20)
            except subprocess.TimeoutExpired:
                timeout = True
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    code = child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    code = child.wait()
        row.update({'endedUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'exitCode': code, 'timeout': timeout})
        result_path = case / 'RESULT.json'
        row['result'] = json.loads(result_path.read_text()) if result_path.exists() else None
        row['pass'] = code == 0 and not timeout and row['result'] is not None and row['result'].get('caught') is None
        runs.append(row)
        print(json.dumps({'variant': variant, 'pass': row['pass'], 'exitCode': code}), flush=True)
    after = [record(path) for path in paths]
    save(output / 'INPUTS-AFTER.json', {'files': after, 'selectedPatches': pins['targetSets']['ohos'],
                                     'finalPinsChecked': len(final)})
    report = {'schema': 1, 'scope': 'Actual Cordis/SDK/routing/TCP/Python; explicit guest/native fixture; no VM/SDK/device',
              'nodeVersion': node_version, 'pythonVersion': python_version, 'mode': 'jitless' if args.jitless else 'plain',
              'tests': len(runs), 'pass': sum(row['pass'] for row in runs), 'skip': 0,
              'inputsUnchanged': before == after, 'runs': runs}
    report['status'] = 'PASS' if report['pass'] == len(runs) and before == after else 'FAIL'
    save(output / 'RUN.json', report)
    return 0 if report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
