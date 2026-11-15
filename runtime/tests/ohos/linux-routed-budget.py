#!/usr/bin/env python3
"""Real async LinuxControl cases; each wall-clock offset lives in one child."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--node', type=Path, required=True)
    parser.add_argument('--mode', choices=['plain', 'strict'], required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[3]
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    paths = ['runtime/ohos/linux/control.mjs', 'runtime/ohos/linux/proxy.mjs',
             'runtime/ohos/linux/host-paths.mjs', 'runtime/ohos/linux/job-diagnostics.mjs',
             'runtime/tests/ohos/linux-routed-budget-probe.mjs', 'runtime/tests/ohos/linux-routed-budget.py',
             'runtime/ohos/sim/preload.mjs', 'runtime/ohos/sim/marker.mjs']
    before = {name: sha(source / name) for name in paths}
    environment = {name: value for name, value in os.environ.items()
                   if name not in {'NODE_OPTIONS', 'NODE_PATH', 'LD_PRELOAD'}
                   and not name.startswith(('OHOS_', 'DSH_'))}
    flags = []
    if args.mode == 'strict':
        flags = ['--jitless', '--import', str(source / 'runtime/ohos/sim/preload.mjs')]
        environment.update(DSH_GO_OHOS_SIM_PLATFORM='openharmony', DSH_GO_OHOS_SIM_ADDONS='[]')
    cases = ['resume-forward', 'resume-backward', 'busy-forward', 'busy-backward',
             'ready-resume-before-expiry-check', 'ready-busy-before-expiry-check',
             'already-ready-expired-budget', 'first-install-refused', 'abort-during-wait', 'preaborted-ready']
    rows = []
    for name in cases:
        command = [str(args.node.resolve()), *flags, str(source / 'runtime/tests/ohos/linux-routed-budget-probe.mjs'), name]
        completed = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=10)
        (out / (name + '.stdout.log')).write_text(completed.stdout)
        (out / (name + '.stderr.log')).write_text(completed.stderr)
        values = [json.loads(line) for line in completed.stdout.splitlines() if line.startswith('{')]
        row = {'name': name, 'argv': command, 'exitCode': completed.returncode,
               'result': values[0] if len(values) == 1 else None}
        row['pass'] = completed.returncode == 0 and row['result'] is not None and row['result']['pass'] is True
        rows.append(row)
        print(name, 'PASS' if row['pass'] else 'FAIL', flush=True)
    after = {name: sha(source / name) for name in paths}
    stable = before == after
    result = {'mode': args.mode, 'status': 'PASS_SCOPED' if stable and all(row['pass'] for row in rows) else 'FAIL',
              'tests': len(rows), 'passed': sum(row['pass'] for row in rows), 'sourceUnchanged': stable,
              'sourceBefore': before, 'sourceAfter': after, 'nodeSha256': sha(args.node.resolve()), 'cases': rows,
              'scope': 'actual LinuxControl and real timers; isolated Date.now fixture offsets; explicit owner/backend; no VM/SDK/suspend/device or scheduler upper-bound claim'}
    (out / 'REPORT.json').write_text(json.dumps(result, indent=2) + '\n')
    return 0 if result['status'] == 'PASS_SCOPED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
