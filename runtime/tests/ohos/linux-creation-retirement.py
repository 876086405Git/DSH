#!/usr/bin/env python3
"""Actual Owner/Control creation debt; reuse the selected native fault DSO."""
import argparse, hashlib, json, os, re, subprocess
from pathlib import Path

ap = argparse.ArgumentParser()
for key in ['source', 'native-run', 'node', 'publication', 'out']:
    ap.add_argument('--' + key, type=Path, required=True)
a = ap.parse_args(); source = a.source.resolve(); out = a.out.resolve()
out.mkdir(parents=True, exist_ok=False)
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
native_run = json.loads(a.native_run.read_text())
assert native_run['status'].startswith('PASS_SCOPED')
assert native_run['inputsBefore'] == native_run['inputsAfter']
for path, digest in native_run['inputsAfter'].items(): assert sha(path) == digest, path
calls = [row for row in native_run['commands'] if row['name'] == 'owner-normal']
assert len(calls) == 1 and calls[0]['exitCode'] == 0
library = Path(calls[0]['argv'][2]); assert sha(library) == native_run['faultLibrary']['sha256']
test = source / 'runtime/tests/ohos/linux-creation-retirement.test.mjs'
files = [a.native_run.resolve(), library, a.node.resolve(), a.publication.resolve(), test, Path(__file__).resolve()]
files += [source / 'runtime/ohos/linux' / name for name in ['owner.mjs', 'backend.mjs', 'control.mjs',
          'instance.mjs', 'native-session.mjs']]
before = {str(p): sha(p) for p in files}
report = {'scope': 'Actual NAPI constructor, Owner/Control/files/flock, existing pthread_create and close link faults; no VM body, extra compilation, full gate or device',
          'nativeRunSha256': sha(a.native_run), 'inputsBefore': before, 'rows': []}
environment = {k: v for k, v in os.environ.items() if k not in {'NODE_OPTIONS', 'NODE_PATH', 'LD_PRELOAD'}
               and not k.startswith(('OHOS_', 'DSH_', 'M3_', 'M4_', 'M6_'))}
for mode, flags in [('plain', []), ('jitless', ['--jitless'])]:
    for fault in ['rollback-close', 'create-eagain']:
        name = mode + '-' + fault
        overrides = {'LD_PRELOAD': str(a.publication.resolve()), 'UV_THREADPOOL_SIZE': '1',
                     'DSH_TEST_OWNER_FAULT': fault, 'DSH_REVIEW_NATIVE_DIRECTORY': str(library.parent)}
        argv = [str(a.node.resolve()), *flags, '--test', '--test-reporter=tap', str(test)]
        r = subprocess.run(argv, cwd=source, env=environment | overrides, capture_output=True, timeout=15)
        (out / (name + '.stdout')).write_bytes(r.stdout); (out / (name + '.stderr')).write_bytes(r.stderr)
        totals = {k: int(v) for k, v in re.findall(r'^# (tests|pass|fail|cancelled|skipped|todo) (\d+)$', r.stdout.decode(), re.M)}
        report['rows'].append({'name': name, 'argv': argv, 'environmentOverrides': overrides,
                               'exitCode': r.returncode, 'totals': totals})
        (out / 'RUN.json').write_text(json.dumps(report, indent=2) + '\n')
        assert r.returncode == 0 and totals.get('tests') == totals.get('pass') == 1, name
        assert all(totals.get(k) == 0 for k in ['fail', 'cancelled', 'skipped', 'todo']), name
        print(name, 'PASS', flush=True)
after = {str(p): sha(p) for p in files}; assert before == after
report.update(inputsAfter=after, status='PASS_SCOPED_CREATION_RETIREMENT')
(out / 'RUN.json').write_text(json.dumps(report, indent=2) + '\n')
lines = ['TAP version 13'] + ['ok ' + str(i + 1) + ' - ' + row['name'] for i, row in enumerate(report['rows'])]
lines += ['1..4', '# tests 4', '# pass 4', '# fail 0', '# cancelled 0', '# skipped 0', '# todo 0']
(out / 'test.log').write_text('\n'.join(lines) + '\n')
