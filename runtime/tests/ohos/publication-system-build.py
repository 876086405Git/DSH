#!/usr/bin/env python3
"""Exercise the real Node binding with an explicit Linux deviceinfo provider.

This is not an OHOS device/SDK run. Optional pinned official header compilation
checks the four public C declarations, not target ABI or installed SDK contents.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
FIELDS = ['osFullName', 'displayVersion', 'incrementalVersion', 'securityPatchTag']
NORMAL = dict(zip(FIELDS, ['DSH-Linux-Test-OS-1', 'DSH-Linux-Test-Display-1',
                           'DSH-Linux-Test-Incremental-1', 'DSH-Linux-Test-Security-1']))
OFFICIAL_HEADER_SHA256 = '3dbf1c80762cd50ddec5a152fd55267087f5d844e44da109334fdc839d34621f'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node-root', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--official-deviceinfo-header', type=Path)
    parser.add_argument('--baseline-addon', type=Path)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    node_root = args.node_root.resolve()
    node = node_root / 'bin/node'
    native = ROOT / 'runtime/ohos/host/publication_binding.cc'
    fixture = HERE / 'publication-deviceinfo-fixture'
    build = out / 'native'
    env = os.environ.copy()
    for name in ['NODE_OPTIONS', 'LD_PRELOAD', 'DSH_HOME', 'DSH_GO_OHOS_SIM',
                 'DSH_GO_OHOS_SIM_PLATFORM', 'DSH_GO_OHOS_SIM_ADDONS']:
        env.pop(name, None)
    rows = []

    def execute(name, command, *, extra_env=None, success=0):
        started = datetime.datetime.now(datetime.timezone.utc).isoformat()
        result = subprocess.run(command, env={**env, **(extra_env or {})}, capture_output=True,
                                text=True, timeout=60)
        row = {'name': name, 'started_utc': started, 'command': list(map(str, command)),
               'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr,
               'passed': result.returncode == success}
        rows.append(row)
        (out / 'progress.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2) + '\n')
        return result

    execute('build-native-fixtures', ['bash', str(HERE / 'build-publication-native.sh'),
                                     str(node_root), str(build)]).check_returncode()
    check = '''
const assert = require('node:assert/strict');
const { Worker } = require('node:worker_threads');
const load = %s;
const binding = load();
assert.equal(typeof binding.getSystemBuildIdentity, 'function');
const first = binding.getSystemBuildIdentity();
assert.deepEqual(first, %s);
assert.deepEqual(binding.getSystemBuildIdentity(), first);
const worker = new Worker('const {parentPort}=require("node:worker_threads"); const load='+load.toString()+'; parentPort.postMessage(load().getSystemBuildIdentity());', {eval:true});
worker.once('message', value => { assert.deepEqual(value, first); console.log(JSON.stringify({main:first,worker:value})); });
worker.once('error', error => { throw error; });
'''
    for linked in [False, True]:
        loader = "() => process._linkedBinding('dsh_ohos_publication')" if linked else \
                 '() => require(' + json.dumps(str(build / 'publication.node')) + ')'
        for strict in [False, True]:
            execute(('linked-' if linked else 'addon-') + ('jitless' if strict else 'jit'),
                    [str(node), *(['--jitless'] if strict else []), '-e', check % (loader, json.dumps(NORMAL))],
                    extra_env={'LD_PRELOAD': str(build / 'libpublication-test-linked.so')} if linked else {})

    if args.baseline_addon:
        code = "const binding=require(" + json.dumps(str(args.baseline_addon.resolve())) + ");" \
               "require('node:assert/strict').equal(typeof binding.getSystemBuildIdentity,'function');"
        execute('baseline-real-binding-missing-getter', [str(node), '-e', code], success=1)
        rows[-1]['classification'] = 'expected old-contract failure; not a candidate positive'
        rows[-1]['new_contract_passed'] = False

    def compile_variant(label, field, case, include=fixture):
        addon = build / (label + '.node')
        command = [os.environ.get('CXX', 'c++'), '-std=c++20', '-shared', '-fPIC', '-fvisibility=hidden',
                   '-DNAPI_VERSION=8', '-DDSH_PUBLICATION_TEST_ADDON',
                   '-DDSH_TEST_BUILD_FIELD=' + str(field), '-DDSH_TEST_BUILD_CASE=' + str(case),
                   '-I', str(build), '-I', str(node_root / 'include/node'), '-I', str(include),
                   str(fixture / 'deviceinfo.cc'), str(native), '-o', str(addon)]
        execute('compile-' + label, command).check_returncode()
        return addon

    for field in range(4):
        for case, label in [(1, 'null'), (2, 'empty'), (3, 'oversized')]:
            label = FIELDS[field] + '-' + label
            addon = compile_variant(label, field, case)
            code = "const b=require(" + json.dumps(str(addon)) + ");" \
                   "require('node:assert/strict').throws(()=>b.getSystemBuildIdentity(),{code:'ERR_OHOS_SYSTEM_BUILD_IDENTITY'});" \
                   "console.log('expected identity error');"
            execute(label, [str(node), '--jitless', '-e', code])
            rows[-1]['classification'] = 'expected error from compile-time C API fault fixture'

    addon = compile_variant('maximum-1024-byte-field', 0, 4)
    expected = {**NORMAL, 'osFullName': 'x' * 1024}
    execute('maximum-1024-byte-field', [str(node), '--jitless', '-e',
            "require('node:assert/strict').deepEqual(require(" + json.dumps(str(addon)) +
            ").getSystemBuildIdentity()," + json.dumps(expected) + ");"])

    if args.official_deviceinfo_header:
        original = args.official_deviceinfo_header.resolve()
        assert sha(original) == OFFICIAL_HEADER_SHA256
        official = out / 'official-header'
        official.mkdir()
        shutil.copyfile(original, official / 'deviceinfo.h')
        addon = compile_variant('official-public-header', -1, 0, official)
        execute('official-public-header', [str(node), '--jitless', '-e',
                "require('node:assert/strict').deepEqual(require(" + json.dumps(str(addon)) +
                ").getSystemBuildIdentity()," + json.dumps(NORMAL) + ");"])

    inputs = [node, native, fixture / 'deviceinfo.h', fixture / 'deviceinfo.cc',
              HERE / 'build-publication-native.sh', Path(__file__).resolve()]
    if args.official_deviceinfo_header:
        inputs.append(args.official_deviceinfo_header.resolve())
    report = {'scope': __doc__, 'inputs': {str(path): sha(path) for path in inputs},
              'binaries': {path.name: sha(path) for path in build.iterdir() if path.suffix in ['.so', '.node']},
              'counts': {'total': len(rows), 'passed': sum(row['passed'] for row in rows),
                         'failed': sum(not row['passed'] for row in rows)}, 'cases': rows}
    (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report['counts']))
    return 0 if all(row['passed'] for row in rows) else 1


if __name__ == '__main__':
    raise SystemExit(main())
