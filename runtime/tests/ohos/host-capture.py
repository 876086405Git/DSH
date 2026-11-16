#!/usr/bin/env python3
"""Measure real native Capture waits and cancellation with an explicit fake runner."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=ROOT)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--cxx', default=os.environ.get('CXX', 'clang++'))
    args = parser.parse_args()
    repo, out = args.repo.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    core = repo / 'app/ohos/entry/src/main/cpp'
    fixture = ROOT / 'runtime/tests/ohos/host-capture.cc'
    inputs = [core / name for name in ['host_core.cpp', 'host_core.h', 'lifecycle_state.h', 'phone_state.h']]
    inputs += [repo / 'runtime/ohos/host/node_runner.cpp', fixture, Path(__file__).resolve()]
    report = {'scope': 'actual host Capture threads/fds, link-time poll observation, fake Node runner; no OH SDK/device',
              'inputs': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}, 'rows': []}

    def record(command, kind, **values):
        result = subprocess.run(command, text=True, capture_output=True, timeout=30,
                                env={key: os.environ[key] for key in ['PATH', 'LANG', 'LC_ALL'] if key in os.environ})
        row = {'kind': kind, 'command': command, 'code': result.returncode,
               'stdout': result.stdout, 'stderr': result.stderr, **values}
        report['rows'].append(row)
        (out / 'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
        return result

    command = [args.cxx, '-std=c++17', '-Wall', '-Wextra', '-Werror', '-pthread', '-I', str(core),
               str(core / 'host_core.cpp'), str(fixture), '-Wl,--wrap=poll', '-Wl,--wrap=pipe',
               '-o', str(out / 'host-capture')]
    record(command, 'build').check_returncode()
    failed = False
    for case in ['idle', 'idle-dup', 'stop-before-capture', 'stop-race', 'throw-dup']:
        result = record([str(out / 'host-capture'), case, str(out / ('fixture-' + case))], 'run', case=case)
        print(result.stdout, end='')
        print(result.stderr, end='')
        failed |= result.returncode != 0
    report['status'] = 'FAIL' if failed else 'PASS_SCOPED_HOST_CAPTURE'
    (out / 'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())
