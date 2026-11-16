#!/usr/bin/env python3
"""Run the unchanged process assertions against the actual assembled tree.

Only test module import locations are rewritten. No runtime dependency is copied
from a development prefix, and the entire payload must remain unchanged.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
TESTS = ['process', 'process-integration', 'process-policy', 'process-diagnostics',
         'process-streaming', 'node-script', 'node-script-runtime', 'node-script-stderr',
         'process-cancel-before-start', 'process-combined']


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def inventory(root):
    rows = []
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('Assembled payload unexpectedly contains a symlink')
        if path.is_file():
            data = path.read_bytes()
            rows.append({'path': path.relative_to(root).as_posix(), 'size': len(data), 'sha256': sha(data)})
    return sorted(rows, key=lambda row: row['path'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('payload', 'node', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    payload, node, out = args.payload.resolve(), args.node.resolve(), args.out.resolve()
    if out.is_relative_to(payload) or out.exists():
        raise ValueError('Use a new output outside the immutable payload')
    out.mkdir(parents=True)
    before = inventory(payload)
    manifest = json.loads((payload.parent / 'manifest.json').read_text())
    assert before == manifest['files'], 'Tests require the exact assembled manifest tree'
    save(out / 'payload-input.json', before)
    tests = out / 'tests'
    tests.mkdir()
    rewrite = []
    module_root = (payload / 'runtime/ohos/process').as_uri() + '/'
    for name in TESTS:
        source = HERE / (name + '.test.mjs')
        text = source.read_text()
        updated, count = re.subn(r"(?<=[\"'])\.\./\.\./ohos/process/", module_root, text)
        assert count > 0, 'Test no longer matches the exact import-only rewrite contract: ' + name
        target = tests / source.name
        target.write_text(updated)
        # Reversing only the module root must recover every original assertion byte.
        assert updated.replace(module_root, '../../ohos/process/') == text
        rewrite.append({'file': source.name, 'sourceSha256': sha(source.read_bytes()),
                        'testSha256': sha(target.read_bytes()), 'importReplacements': count})
    for name in ['node-script-api-fixture.mjs', 'host-link-fixture.mjs']:
        fixture = HERE / name
        (tests / fixture.name).write_bytes(fixture.read_bytes())
        rewrite.append({'file': name, 'sourceSha256': sha(fixture.read_bytes()),
                        'testSha256': sha((tests / name).read_bytes()), 'importReplacements': 0})
    save(out / 'test-inputs.json', rewrite)
    commands = []
    environment = os.environ.copy()
    environment.pop('DSH_GO_OHOS_SIM', None)
    environment['OHOS_TEST_PROCESS_PREFIX'] = str(payload)
    for mode in ('jit', 'strict'):
        env = {**environment, 'M4_DIAGNOSTICS_MODE': mode}
        flags = ['--import', str(ROOT / 'runtime/ohos/sim/marker.mjs')]
        if mode == 'strict':
            env.update(DSH_GO_OHOS_SIM_PLATFORM='openharmony', DSH_GO_OHOS_SIM_ADDONS='[]')
            flags = ['--jitless', '--import', str(ROOT / 'runtime/ohos/sim/preload.mjs')]
        argv = [str(node), *flags, '--import', str(payload / 'runtime/ohos/process/child-process.mjs'),
                '--import', str(payload / 'runtime/ohos/process/node-worker-preload.mjs'),
                '--test', '--test-isolation=none', *[str(tests / (name + '.test.mjs')) for name in TESTS]]
        if mode == 'strict':
            argv = [sys.executable, str(HERE / 'process-link-fixture.py'),
                    '--evidence', str(out / 'strict-host-link-fixture.json'), '--', *argv]
            if 'LD_PRELOAD' in env:
                env['OHOS_TEST_LINK_LD_PRELOAD'] = env.pop('LD_PRELOAD')
        with (out / (mode + '.log')).open('x') as log:
            result = subprocess.run(argv, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        commands.append({'argv': argv, 'cwd': str(ROOT), 'mode': mode, 'exitCode': result.returncode,
                         'environment': {key: env[key] for key in ['OHOS_TEST_PROCESS_PREFIX', 'M4_DIAGNOSTICS_MODE',
                            'DSH_GO_OHOS_SIM_PLATFORM', 'DSH_GO_OHOS_SIM_ADDONS'] if key in env},
                         'removedEnvironment': ['DSH_GO_OHOS_SIM']})
        save(out / 'commands.json', commands)
        print(mode, result.returncode, flush=True)
        result.check_returncode()
    assert inventory(payload) == before, 'Process tests modified the installed runtime tree'
    save(out / 'report.json', {'scope': 'Real assembled bytes, Linux JIT and strict simulation; no OH target ABI claim',
        'passed': True, 'testAssertionsUnchanged': True, 'payloadUnchanged': True,
        'payloadInputSha256': sha((out / 'payload-input.json').read_bytes()),
        'testInputsSha256': sha((out / 'test-inputs.json').read_bytes())})


if __name__ == '__main__':
    main()
