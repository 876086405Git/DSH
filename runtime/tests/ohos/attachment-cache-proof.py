#!/usr/bin/env python3
"""Count actual image conversions using the already built, explicit host SDK carrier.

The formal gate follows image-attachment-{mode}; it does not build another NDK ABI.
Each case has its own process/SDK pool, trace, real home, and exact input hashes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

CASES = ('warm', 'alpha-warm', 'caller-alias', 'same-header-tamper', 'corrupt-cache',
         'variant-eviction', 'owner-isolation', 'disposed-reference', 'public-helper',
         'missing-source', 'corrupt-source')


def record(path):
    return {'path': str(path), 'bytes': path.stat().st_size,
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--prefix', type=Path, required=True)
    ap.add_argument('--native-library-dir', type=Path, required=True)
    ap.add_argument('--publication-fixture', type=Path, required=True)
    ap.add_argument('--node', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--jitless', action='store_true')
    ap.add_argument('--case', action='append', choices=CASES)
    args = ap.parse_args()
    source, prefix, out = args.source.resolve(), args.prefix.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    native, publication, node = args.native_library_dir.resolve(), args.publication_fixture.resolve(), args.node.resolve()
    actor = source / 'runtime/tests/ohos/attachment-cache-proof-native.mjs'
    oracle = source / 'runtime/tests/ohos/image-attachment-oracle.json'
    module = prefix / 'node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js'
    pins = source / 'runtime/patches/pins.json'
    expected = json.loads(pins.read_text())['patches']['ohos-image-codec.diff']['0.2.2-rc.1']
    assert record(module)['sha256'] == expected['node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js']['after']
    inputs = [Path(__file__).resolve(), actor, oracle, pins, module, node, publication,
              native / 'libdsh_image_codec.so', prefix / 'runtime/ohos/image/preload.mjs',
              prefix / 'runtime/ohos/publication/preload.mjs']
    before = [record(path) for path in inputs]
    save(out / 'INPUTS-BEFORE.json', before)
    (out / 'ACTOR-INPUT.mjs').write_bytes(actor.read_bytes())
    environment = {k: v for k, v in os.environ.items()
                   if k not in ('NODE_OPTIONS', 'NODE_PATH', 'LD_PRELOAD') and not k.startswith(('DSH_', 'OHOS_'))}
    rows = []
    combined = []
    for case in args.case or CASES:
        destination = out / case
        (destination / 'home').mkdir(parents=True)
        argv = [str(node), *(['--jitless'] if args.jitless else []), '--test', '--test-reporter=tap', str(actor)]
        delta = {'DSH_PREFIX': str(prefix), 'DSH_HOME': str(destination / 'home'),
                 'DSH_IMAGE_PROOF_OUT': str(destination), 'DSH_IMAGE_PROOF_CASE': case,
                 'DSH_IMAGE_PROOF_ORACLE': str(oracle), 'DSH_IMAGE_TEST_TRACE': str(destination / 'SDK-TRACE.jsonl'),
                 'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(native), 'LD_PRELOAD': str(publication)}
        save(destination / 'COMMAND.json', {'argv': argv, 'environment': delta})
        with (destination / 'test.log').open('wb') as log:
            code = subprocess.run(argv, env=environment | delta, stdout=log, stderr=subprocess.STDOUT,
                                  stdin=subprocess.DEVNULL, timeout=30).returncode
        combined.append((destination / 'test.log').read_bytes())
        counts = {key: int(value) for key, value in re.findall(
            r'^# (tests|pass|fail|cancelled|skipped|todo) (\d+)$', (destination / 'test.log').read_text(), re.M)}
        good = code == 0 and counts == {'tests': 1, 'pass': 1, 'fail': 0, 'cancelled': 0, 'skipped': 0, 'todo': 0}
        row = {'case': case, 'exitCode': code, 'counts': counts, 'status': 'PASS_SCOPED' if good else 'FAIL'}
        save(destination / 'RESULT.json', row)
        rows.append(row)
        print(case, row['status'], flush=True)
    after = [record(path) for path in inputs]
    assert before == after
    save(out / 'INPUTS-AFTER.json', after)
    (out / 'test.log').write_bytes(b'\n'.join(combined))
    save(out / 'RESULT.json', {'rows': rows, 'inputsStable': True,
                             'scope': 'Existing exact host SDK library, actual product image chain; no SDK/device pixel or performance claim'})
    return 0 if all(row['status'] == 'PASS_SCOPED' for row in rows) else 1


if __name__ == '__main__':
    raise SystemExit(main())
