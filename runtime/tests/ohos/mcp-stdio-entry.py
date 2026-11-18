#!/usr/bin/env python3
"""Run the real MCP plugin against an explicit host-process guest fixture."""
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
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record(path):
    path = Path(path)
    return {'path': str(path), 'bytes': path.stat().st_size, 'sha256': digest(path)}


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
        raise ValueError('Use a fresh output directory outside both input trees')
    if (source / 'node_modules').resolve() != prefix / 'node_modules':
        raise ValueError('Source dependency resolution must use the explicitly supplied OH prefix')
    if os.environ.get('NODE_OPTIONS'):
        raise ValueError('NODE_OPTIONS must be unset')
    node, python = Path(shutil.which(args.node)).absolute(), Path(shutil.which(args.python)).absolute()
    node_version = subprocess.check_output([str(node), '--version'], text=True).strip()
    if node_version != 'v24.22.1':
        raise ValueError('Exact Node 24.22.1 is required')
    python_version = subprocess.check_output([str(python), '--version'], text=True).strip()
    pins_path = source / 'runtime/patches/pins.json'
    pins = json.loads(pins_path.read_text())
    version = json.loads((prefix / 'node_modules/@deepseek-ai/dsh/package.json').read_text())['version']
    final = {}
    for name in pins['targetSets']['ohos']:
        for path, value in pins['patches'][name][version].items():
            final[path] = value['after']
    for path, expected in final.items():
        if digest(prefix / path) != expected:
            raise ValueError('Current official OH final pin differs: ' + path)
    paths = [node, python, pins_path, Path(__file__).resolve()]
    tests = source / 'runtime/tests/ohos'
    paths += [tests / name for name in ('mcp-stdio-server.py', 'mcp-stdio-guest-fixture.mjs',
                                      'mcp-stdio-plugin-entry.mjs', 'linux-control-fixture.mjs')]
    for directory in ('linux', 'process', 'publication'):
        paths += sorted((source / 'runtime/ohos' / directory).rglob('*.mjs'))
    paths += [prefix / path for path in sorted(final)]
    paths = sorted(set(paths))
    before = [record(path) for path in paths]
    output.mkdir(parents=True)
    save(output / 'INPUTS-BEFORE.json', {'files': before, 'target': 'ohos',
        'selectedPatches': pins['targetSets']['ohos'], 'finalPinsChecked': len(final)})
    argv = [str(node), *(['--jitless'] if args.jitless else []), str(tests / 'mcp-stdio-plugin-entry.mjs')]
    delta = {'DSH_PREFIX': str(prefix), 'OHOS_MCP_TEST_OUT': str(output), 'OHOS_MCP_PYTHON': str(python)}
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    metadata = {'schema': 1, 'argv': argv, 'cwd': str(source), 'environmentDelta': delta,
                'nodeVersion': node_version, 'pythonVersion': python_version, 'startedUTC': started,
                'scope': 'Finite host integration; no full gate, VM, SDK, HAP or device',
                'mode': 'jitless' if args.jitless else 'plain'}
    save(output / 'COMMAND.json', metadata)
    start = time.monotonic()
    with (output / 'node.stdout').open('wb') as stdout, (output / 'node.stderr').open('wb') as stderr:
        child = subprocess.Popen(argv, cwd=source, env=dict(os.environ, **delta), stdin=subprocess.DEVNULL,
                                 stdout=stdout, stderr=stderr, start_new_session=True)
        timeout = False
        try:
            code = child.wait(timeout=45)
        except subprocess.TimeoutExpired:
            timeout = True
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=5)
            code = 124
    after = [record(path) for path in paths]
    unchanged = before == after
    save(output / 'INPUTS-AFTER.json', {'files': after, 'unchanged': unchanged})
    report_path = output / 'REPORT.json'
    report = json.loads(report_path.read_text()) if report_path.exists() else None
    passed = code == 0 and not timeout and unchanged and report and report['state'] == 'PASS_SCOPED_HOST_STDIO_MCP_PLUGIN'
    result = {**metadata, 'exitCode': code, 'timeout': timeout, 'seconds': time.monotonic() - start,
              'inputsUnchanged': unchanged, 'status': 'PASS_SCOPED_HOST_STDIO_MCP_PLUGIN' if passed else 'FAILED',
              'report': record(report_path) if report_path.exists() else None,
              'endedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    save(output / 'RESULT.json', result)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
