#!/usr/bin/env python3
"""Actual embedded RISC-V select microsecond boundaries and legacy timer paths."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-archive', type=Path, required=True)
    parser.add_argument('--node-headers', type=Path, required=True)
    parser.add_argument('--cc', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--built-native', type=Path, help='Explicit author reuse/red input; default formal gate builds fresh')
    parser.add_argument('--native-include', type=Path, help='Explicit matching headers for a reused native build')
    args = parser.parse_args()
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=False)
    native = ROOT / 'runtime/ohos/linux/native'
    built = args.built_native.resolve() if args.built_native else out / 'native'
    include = args.native_include.resolve() if args.native_include else native
    report = {'scope': 'Actual RISC-V state and production virt_machine_run; explicit clock/select/net boundaries, '
                       'real WFI setup and replacement only of the following interpreter batch. '
                       'Not Linux workload, device timing, networking integration or hard real-time proof.',
              'startedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'reusedNative': bool(args.built_native), 'commands': [], 'checks': []}

    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def save():
        (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')

    def run(label, argv, timeout=30):
        argv = list(map(str, argv))
        started = datetime.datetime.now(datetime.timezone.utc).isoformat()
        try:
            result = subprocess.run(argv, capture_output=True, timeout=timeout,
                env={key: os.environ[key] for key in ['PATH', 'LANG', 'LC_ALL'] if key in os.environ})
        except subprocess.TimeoutExpired as error:
            (out / (label + '.stdout')).write_bytes(error.stdout or b'')
            (out / (label + '.stderr')).write_bytes(error.stderr or b'')
            report['commands'].append({'label': label, 'argv': argv, 'startedUTC': started, 'exitCode': None, 'timedOut': True})
            report['status'] = 'FAIL_TIMEOUT'; save(); raise
        (out / (label + '.stdout')).write_bytes(result.stdout)
        (out / (label + '.stderr')).write_bytes(result.stderr)
        report['commands'].append({'label': label, 'argv': argv, 'startedUTC': started,
                                   'exitCode': result.returncode, 'timedOut': False})
        save(); return result

    lock = json.loads((native / 'source-lock.json').read_text())
    assert sha(args.source_archive) == 'be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555'
    for name, digest in lock['files'].items():
        assert sha(native / name) == digest, name
    if not args.built_native:
        run('build-native', [sys.executable, '-I', '-B', native / 'build.py',
            '--source-archive', args.source_archive.resolve(), '--node-headers', args.node_headers.resolve(),
            '--cc', args.cc, '--output', built, '--host-test'], 180).check_returncode()
    assert (built / 'BUILD.json').is_file()
    source = built / 'tinyemu-2019-12-21'
    objects = sorted(built.glob('*.o')); assert len(objects) > 20
    inputs = [HERE / 'run.py', HERE / 'sleep-boundary.c', HERE / 'README.zh.md',
              ROOT / 'tooling/ohos/research/tinyemu-native/clock-cpu.c',
              ROOT / 'tooling/ohos/research/tinyemu-clint-deadline/timer-boundary.c',
              ROOT / 'tooling/ohos/run-gates.py', native / 'README.md', native / 'source-lock.json',
              native / 'build.py', built / 'BUILD.json', args.source_archive.resolve(),
              args.node_headers.resolve() / 'node_api.h', *objects]
    inputs += [native / name for name in lock['files']]
    inputs += [source / name for name in ['machine.h', 'riscv_machine.c', 'temu.c']]
    report['inputs'] = before = {str(p): sha(p) for p in inputs}; save()
    flags = ['-O2', '-w', '-UNDEBUG', '-D_FILE_OFFSET_BITS=64', '-D_LARGEFILE_SOURCE', '-D_GNU_SOURCE',
             '-DCONFIG_VERSION="2019-12-21"', '-DCONFIG_SLIRP', '-DCONFIG_RISCV_MAX_XLEN=64', '-DDSH_FS_EXPORT',
             '-I', include, '-I', source, '-I', ROOT / 'tooling/ohos/research/tinyemu-native',
             '-ffunction-sections', '-fdata-sections']
    wraps = ['-Wl,--wrap=' + name for name in ['exit', 'abort', '__assert_fail', 'select']]
    selected = [p for p in objects if p.name not in ['binding.o', 'riscv_machine.o']]
    probe = out / 'sleep-boundary'
    run('compile-boundary', [args.cc, *flags, '-DTEMU_EMBED', HERE / 'sleep-boundary.c',
        *selected, *wraps, '-Wl,--gc-sections', '-lm', '-o', probe]).check_returncode()

    def check(label, program, arguments, count):
        result = run(label, [program, *arguments])
        rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith(b'{')]
        passed = result.returncode == 0 and len(rows) == count and all(row['passed'] for row in rows)
        report['checks'].append({'label': label, 'passed': passed, 'expectedCount': count, 'rows': rows})
        save(); print(label, 'PASS' if passed else 'FAIL', flush=True)

    check('select-microsecond-boundaries', probe, [], 52)
    check('legacy-ms-api', probe, ['--legacy-ms'], 14)
    check('other-class-dispatch', probe, ['--legacy-class'], 3)
    check('existing-clock', probe, ['--existing'], 13)
    check('existing-low-write', probe, ['--observe-write'], 1)
    unsigned = out / 'unsigned-boundary'
    no_temu = [p for p in selected if p.name != 'temu.o']
    run('compile-unsigned', [args.cc, *flags, '-DTEMU_EMBED',
        ROOT / 'tooling/ohos/research/tinyemu-clint-deadline/timer-boundary.c', *no_temu,
        *wraps, '-Wl,--gc-sections', '-lm', '-o', unsigned]).check_returncode()
    check('existing-unsigned-clint', unsigned, [], 14)
    # Compile the same actual source without TEMU_EMBED. This must not introduce
    # any reference to the embedded-only microsecond entry point.
    nonembed = out / 'temu-nonembed.o'
    run('compile-nonembed-temu', [args.cc, *flags, '-UTEMU_EMBED', '-Dmain=tinyemu_cli_main',
        '-c', source / 'temu.c', '-o', nonembed]).check_returncode()
    legacy = out / 'nonembed-boundary'
    run('compile-nonembed-boundary', [args.cc, *flags, '-UTEMU_EMBED', HERE / 'sleep-boundary.c',
        *no_temu, nonembed, *wraps, '-Wl,--gc-sections', '-lm', '-o', legacy]).check_returncode()
    check('nonembed-legacy-ms-api', legacy, ['--legacy-ms'], 14)
    check('nonembed-other-class-dispatch', legacy, ['--legacy-class'], 3)
    after = {str(p): sha(p) for p in inputs}
    report['sourceUnchangedDuringRun'] = before == after
    passed = before == after and all(check['passed'] for check in report['checks'])
    report['status'] = 'PASS_SCOPED_HOST_SLEEP_MICROS' if passed else 'FAIL'
    report['endedUTC'] = datetime.datetime.now(datetime.timezone.utc).isoformat(); save()
    return int(not passed)


if __name__ == '__main__':
    raise SystemExit(main())
