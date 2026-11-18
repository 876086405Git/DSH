#!/usr/bin/env python3
"""Actual RV32/RV64 unsigned CLINT boundaries and production Node WFI loop."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-archive', type=Path, required=True)
    parser.add_argument('--node-headers', type=Path, required=True)
    parser.add_argument('--cc', required=True)
    parser.add_argument('--node', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--built-native', type=Path, help='Explicit prebuilt baseline for author red; formal gate builds fresh')
    args = parser.parse_args()
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=False)
    report = {'scope': 'actual CPU/CLINT with explicit clock fixture and production Node/TinyEMU with a tiny MTIE/WFI BIOS; no Linux kernel, SDK/device or App CPU attribution',
              'startedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'commands': [], 'checks': []}

    def save():
        (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')

    def run(label, argv, timeout=30):
        argv = list(map(str, argv))
        try:
            result = subprocess.run(argv, capture_output=True, timeout=timeout,
                                    env={k: os.environ[k] for k in ['PATH', 'LANG', 'LC_ALL'] if k in os.environ})
        except subprocess.TimeoutExpired as error:
            (out / (label + '.stdout')).write_bytes(error.stdout or b'')
            (out / (label + '.stderr')).write_bytes(error.stderr or b'')
            report['commands'].append({'label': label, 'argv': argv, 'exitCode': None, 'timedOut': True})
            report['status'] = 'FAIL_TIMEOUT'; save(); raise
        (out / (label + '.stdout')).write_bytes(result.stdout)
        (out / (label + '.stderr')).write_bytes(result.stderr)
        report['commands'].append({'label': label, 'argv': argv, 'exitCode': result.returncode, 'timedOut': False})
        save(); return result

    native = ROOT / 'runtime/ohos/linux/native'
    built = args.built_native.resolve() if args.built_native else out / 'native'
    if args.built_native:
        assert (built / 'BUILD.json').is_file()
    else:
        run('build-native', [sys.executable, '-I', '-B', native / 'build.py', '--source-archive', args.source_archive.resolve(),
                            '--node-headers', args.node_headers.resolve(), '--cc', args.cc, '--output', built, '--host-test'], 180).check_returncode()
    objects = sorted(built.glob('*.o')); assert len(objects) > 20
    inputs = [HERE / name for name in ['run.py', 'timer-boundary.c', 'select-observer.c', 'node-case.mjs']]
    inputs += [ROOT / 'tooling/ohos/research/tinyemu-native/clock-cpu.c', built / 'BUILD.json', *objects,
               built / 'tinyemu-2019-12-21/riscv_machine.c', args.source_archive.resolve(), args.node_headers.resolve() / 'node_api.h']
    report['inputs'] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}; save()
    probe = out / 'timer-boundary'
    selected = [p for p in objects if p.name not in ['binding.o', 'temu.o', 'riscv_machine.o']]
    run('compile-clock', [args.cc, '-O2', '-w', '-D_FILE_OFFSET_BITS=64', '-D_LARGEFILE_SOURCE', '-D_GNU_SOURCE',
        '-DCONFIG_VERSION="2019-12-21"', '-DCONFIG_SLIRP', '-DCONFIG_RISCV_MAX_XLEN=64', '-DTEMU_EMBED',
        '-I', native, '-I', built / 'tinyemu-2019-12-21', '-I', ROOT / 'tooling/ohos/research/tinyemu-native',
        '-ffunction-sections', '-fdata-sections', HERE / 'timer-boundary.c', *selected,
        *['-Wl,--wrap=' + n for n in ['exit', 'abort', '__assert_fail']], '-Wl,--gc-sections', '-lm', '-o', probe]).check_returncode()
    for label, arguments, count in [('unsigned-boundaries', [], 14), ('existing-clock', ['--existing'], 13),
                                    ('existing-low-write', ['--observe-write'], 1)]:
        result = run(label, [probe, *arguments])
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        passed = result.returncode == 0 and len(rows) == count and all(row['passed'] for row in rows)
        report['checks'].append({'label': label, 'passed': passed, 'rows': rows}); save()
        print(label, 'PASS' if passed else 'FAIL', flush=True)
    code = [0x400080b7, 0x01010137]
    for byte in b'CLINT-IDLE-READY\n':
        code += [(byte << 20) | (3 << 7) | 0x13, (3 << 20) | (1 << 15) | (2 << 12) | 0x23,
                 (2 << 20) | (1 << 15) | (2 << 12) | (4 << 7) | 0x23]
    # Real guest instructions: write UINT64_MAX mtimecmp, enable MTIE, WFI/back-jump.
    code += [0x02004237, 0xfff00293, 0x00523023, 0x08000313, 0x30432073, 0x10500073, 0xffdff06f]
    (out / 'bios.bin').write_bytes(b''.join(struct.pack('<I', x) for x in code))
    (out / 'disk.raw').write_bytes(bytes(32768))
    config = out / 'config.json'
    config.write_text(json.dumps({'version': 1, 'machine': 'riscv64', 'memory_size': 16, 'bios': str(out / 'bios.bin'),
                                 'cmdline': '', 'drive0': {'file': str(out / 'disk.raw')}, 'eth0': {'driver': 'user'}}) + '\n')
    observer = out / 'observer.o'; library = out / 'libdsh_linux.so'
    run('compile-observer', [args.cc, '-std=c11', '-O2', '-fPIC', '-D_GNU_SOURCE', '-Wall', '-Wextra', '-Werror',
                            '-I', args.node_headers.resolve(), '-c', HERE / 'select-observer.c', '-o', observer]).check_returncode()
    run('link-observer', [args.cc, '-shared', '-Wl,-z,nodelete',
        *['-Wl,--wrap=' + n for n in ['exit', 'abort', '__assert_fail', 'select', 'napi_set_named_property']],
        *objects, observer, '-pthread', '-lm', '-o', library]).check_returncode()
    for mode, flags in [('plain', []), ('jitless', ['--jitless'])]:
        result = run('node-' + mode, [args.node, *flags, HERE / 'node-case.mjs', library, config])
        rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith(b'{')]
        passed = result.returncode == 0 and len(rows) == 1
        report['checks'].append({'label': 'node-' + mode, 'passed': passed, 'rows': rows}); save()
        print('node-' + mode, 'PASS' if passed else 'FAIL', flush=True)
    passed = all(row['passed'] for row in report['checks'])
    report['status'] = 'PASS_SCOPED_UNSIGNED_CLINT_AND_HOST_WFI' if passed else 'FAIL'
    report['endedUTC'] = datetime.datetime.now(datetime.timezone.utc).isoformat(); save()
    return int(not passed)


if __name__ == '__main__':
    raise SystemExit(main())
