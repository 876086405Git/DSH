#!/usr/bin/env python3
"""Actual Node thread, exit, cancellation and host-survival regression tests."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node', required=True, type=Path)
    parser.add_argument('--headers', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--baseline', type=Path)
    args = parser.parse_args()
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    args.node = args.node.resolve()
    args.headers = args.headers.resolve()
    pin = json.loads((ROOT / 'runtime/ohos/node-version.json').read_text())
    assert subprocess.check_output([args.node, '--version'], text=True).strip() == 'v' + pin
    commands = []

    def build(repo, label):
        directory = args.out / label
        directory.mkdir()
        subprocess.run(['python3', str(repo / 'runtime/ohos/host/generate-node-version.py'),
                        '--output', str(directory / 'dsh_node_version.h')], check=True)
        paths = [repo / 'runtime/ohos/host/node_runner.cpp',
                 repo / 'runtime/ohos/host/publication_binding.cc',
                 repo / 'runtime/tests/ohos/publication-deviceinfo-fixture/deviceinfo.cc',
                 ROOT / 'runtime/tests/ohos/host-embedded.cc']
        command = [os.environ.get('CXX', 'clang++'), '-std=c++20', '-shared', '-fPIC',
                   '-fvisibility=hidden', '-DNAPI_VERSION=8', '-I', str(args.headers),
                   '-I', str(directory), '-I', str(repo / 'runtime/tests/ohos/publication-deviceinfo-fixture'),
                   *(str(p) for p in paths), '-ldl', '-pthread', '-o', str(directory / 'runner.so')]
        result = subprocess.run(command, capture_output=True, text=True)
        commands.append({'command': command, 'code': result.returncode,
                         'stdout': result.stdout, 'stderr': result.stderr,
                         'inputs': {str(p): digest(p) for p in paths}})
        (args.out / 'build.json').write_text(json.dumps(commands, indent=2))
        result.check_returncode()
        return directory / 'runner.so'

    library = build(ROOT, 'current')
    baseline_library = build(args.baseline.resolve(), 'baseline') if args.baseline else None
    cases = [
        ('natural-exit-code', 'process.exitCode = 23;', 23),
        ('explicit-exit', 'process.exit(23);', 23),
        ('negative-exit', 'process.exit(-1);', -1),
        ('invalid-openssl-config', 'throw new Error("must not execute");', 101),
        ('uncaught-exception', 'throw new Error("P1 fixture exception");', 1),
        ('invalid-esm-syntax', 'export const broken = ;', 1),
        ('stdio-and-jitless', 'import assert from "node:assert/strict";'
         'assert.equal(typeof WebAssembly,"undefined");'
         'process.stdout.write("中文输出\\n");process.stderr.write("P1_STDERR\\n");', 0),
        ('worker', 'import {Worker} from "node:worker_threads";'
         'const w=new Worker("process.stdout.write(\\"P1_WORKER\\\\n\\");",{eval:true});'
         'await new Promise((resolve,reject)=>{w.once("exit",code=>code?reject(new Error(String(code))):resolve());w.once("error",reject);});', 0),
        ('stop-timer', 'import {writeFileSync} from "node:fs";'
         'writeFileSync(process.env.P1_TEST_STOP_MARKER,"ready");setInterval(()=>{},1000);', 0),
        ('stop-busy-js', 'import {writeFileSync} from "node:fs";'
         'writeFileSync(process.env.P1_TEST_STOP_MARKER,"ready");while(true){}', 0),
        ('stop-before-entry', 'throw new Error("must not execute after early stop");', 0),
    ]
    rows = []
    for name, source, expected in cases:
        script = args.out / (name + '.mjs')
        script.write_text(source)
        env = {key: value for key, value in os.environ.items() if key in ['PATH', 'LANG', 'LC_ALL']}
        env.update(LD_PRELOAD=str(library), P1_TEST_REPEAT='1')
        if name == 'invalid-openssl-config':
            config = args.out / 'invalid-openssl.conf'
            config.write_text('this is not an openssl configuration = [\n[\n')
            env['OPENSSL_CONF'] = str(config)
        if name == 'stop-before-entry':
            env['P1_TEST_EARLY_STOP'] = '1'
        elif name.startswith('stop-'):
            env['P1_TEST_STOP_MARKER'] = str(args.out / (name + '.ready'))
        command = [str(args.node), '--jitless', '--import', str(ROOT / 'runtime/ohos/preload.mjs'), str(script)]
        result = subprocess.run(command, capture_output=True, text=True, env=env, timeout=20)
        required = [f'P1_RUNNER_RETURNED={expected}', 'P1_HOST_ALIVE_AFTER',
                    'P1_SIGNAL_PRESERVED=1', 'P1_REPEAT=64', 'P1_STOP_AFTER=0']
        if name.startswith('stop-'):
            required.append('P1_STOP_REQUEST=1')
        passed = result.returncode == 0 and all(item in result.stderr for item in required)
        if name == 'stdio-and-jitless':
            passed = passed and result.stdout == '中文输出\n' and 'P1_STDERR' in result.stderr
        if name == 'worker':
            passed = passed and 'P1_WORKER' in result.stdout
        rows.append({'case': name, 'passed': passed, 'command': command,
                     'code': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
        print(name, 'PASS' if passed else 'FAIL', flush=True)
    baseline = []
    if baseline_library:
        for name in ['explicit-exit', 'uncaught-exception']:
            env = {'PATH': os.environ['PATH'], 'LD_PRELOAD': str(baseline_library)}
            command = [str(args.node), '--jitless', '--import',
                       str(args.baseline.resolve() / 'runtime/ohos/preload.mjs'), str(args.out / (name + '.mjs'))]
            result = subprocess.run(command, capture_output=True, text=True, env=env, timeout=20)
            baseline.append({'case': name, 'hostSurvived': 'P1_HOST_ALIVE_AFTER' in result.stderr,
                             'code': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
    report = {'scope': 'Linux real official Node, real product runner/binding, test deviceinfo only; no Ark or OHOS ABI claim',
              'nodeSHA256': digest(args.node), 'headerSHA256': digest(args.headers / 'node.h'),
              'runnerSHA256': digest(ROOT / 'runtime/ohos/host/node_runner.cpp'),
              'rows': rows, 'baselineEvidence': baseline}
    (args.out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    assert all(row['passed'] for row in rows)
    assert all(not row['hostSurvived'] for row in baseline)


if __name__ == '__main__':
    main()
