#!/usr/bin/env python3
"""Actual product Node join -> RAM advice, measured with test-only link observers."""
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
    parser.add_argument('--built-native', type=Path, help='Explicit already-built input for author red/green; formal gate builds fresh')
    parser.add_argument('--case', action='append', choices=['normal', 'poweroff', 'early-stop', 'advice-error', 'disk-error', 'fatal', 'missing', 'join-error', 'cancelled'])
    parser.add_argument('--plain-only', action='store_true')
    args = parser.parse_args()
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=False)
    report = {'scope': 'actual product Node async join and TinyEMU allocation; explicit host-page-touch/fault/observer wrappers; no guest workload, SDK, device or PSS claim',
              'startedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'commands': [], 'observations': []}

    def save():
        (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')

    def run(label, argv, timeout=30):
        command = list(map(str, argv))
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=timeout,
                                    env={key: os.environ[key] for key in ['PATH', 'LANG', 'LC_ALL'] if key in os.environ})
        except subprocess.TimeoutExpired as error:
            (out / (label + '.stdout')).write_bytes(error.stdout or b'')
            (out / (label + '.stderr')).write_bytes(error.stderr or b'')
            report['commands'].append({'label': label, 'argv': command, 'exitCode': None, 'timedOut': True})
            report['status'] = 'FAIL_TIMEOUT'; save(); raise
        (out / (label + '.stdout')).write_text(result.stdout)
        (out / (label + '.stderr')).write_text(result.stderr)
        report['commands'].append({'label': label, 'argv': command, 'exitCode': result.returncode,
                                   'stdout': label + '.stdout', 'stderr': label + '.stderr', 'timedOut': False})
        save()
        return result

    native = ROOT / 'runtime/ohos/linux/native'
    if args.built_native:
        built = args.built_native.resolve()
        assert (built / 'BUILD.json').is_file()
        report['buildInput'] = 'explicit previously compiled production objects'
    else:
        built = out / 'native'
        run('build-native', [sys.executable, '-I', '-B', native / 'build.py',
                             '--source-archive', args.source_archive.resolve(), '--node-headers', args.node_headers.resolve(),
                             '--output', built, '--cc', args.cc, '--host-test'], timeout=180).check_returncode()
        report['buildInput'] = 'fresh production build'
    objects = sorted(built.glob('*.o'))
    assert len(objects) > 20
    inputs = [HERE / 'monitor.c', HERE / 'node-case.mjs', Path(__file__), built / 'BUILD.json', *objects,
              args.source_archive.resolve(), args.node_headers.resolve() / 'node_api.h']
    report['inputs'] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    save()
    code = [0x00000097, 0x70008093, 0x02a00113, 0x0020a023, 0x0000a183, 0x400080b7, 0x01010137]
    for byte in b'MEMORY-PROBE-READY\n':
        code += [(byte << 20) | (3 << 7) | 0x13, (3 << 20) | (1 << 15) | (2 << 12) | 0x23,
                 (2 << 20) | (1 << 15) | (2 << 12) | (4 << 7) | 0x23]
    code += [0x10500073, 0xffdff06f]
    assert len(code) * 4 < 1024
    (out / 'bios.bin').write_bytes(b''.join(struct.pack('<I', word) for word in code))
    poweroff = code[:-2] + [0x00100193, 0x0030a023, 0x0000a223, 0x10500073, 0xffdff06f]
    (out / 'poweroff.bin').write_bytes(b''.join(struct.pack('<I', word) for word in poweroff))
    (out / 'large.bin').write_bytes(bytes(17 * 1024 * 1024))
    (out / 'disk.raw').write_bytes(bytes(32768))
    (out / 'export').mkdir()
    config = {'version': 1, 'machine': 'riscv64', 'memory_size': 16, 'bios': str(out / 'bios.bin'), 'cmdline': '',
              'drive0': {'file': str(out / 'disk.raw')}, 'eth0': {'driver': 'user'},
              'fs0': {'file': str(out / 'export'), 'tag': 'dsh0'}}
    (out / 'normal.json').write_text(json.dumps(config) + '\n')
    (out / 'poweroff.json').write_text(json.dumps({**config, 'bios': str(out / 'poweroff.bin')}) + '\n')
    (out / 'fatal.json').write_text(json.dumps({**config, 'bios': str(out / 'large.bin')}) + '\n')
    cases = args.case or ['normal', 'poweroff', 'early-stop', 'advice-error', 'disk-error', 'fatal', 'missing', 'join-error', 'cancelled']
    modes = {'normal': 0, 'poweroff': 0, 'early-stop': 0, 'advice-error': 1, 'disk-error': 4, 'fatal': 0, 'missing': 0, 'join-error': 2, 'cancelled': 3}
    libraries = {}
    for mode in sorted(set(modes[case] for case in cases)):
        folder = out / ('mode-' + str(mode)); folder.mkdir()
        monitor = folder / 'monitor.o'
        run('compile-monitor-' + str(mode), [args.cc, '-std=c11', '-O2', '-fPIC', '-D_GNU_SOURCE',
            '-DNAPI_VERSION=8', '-DMAX_XLEN=64', '-DFAULT_MODE=' + str(mode), '-Wall', '-Wextra', '-Werror',
            '-I', args.node_headers.resolve(), '-I', built / 'tinyemu-2019-12-21', '-c', HERE / 'monitor.c', '-o', monitor]).check_returncode()
        library = folder / 'libdsh_linux.so'; libraries[mode] = library
        wraps = ['exit', 'abort', '__assert_fail', 'mallocz', 'phys_mem_map_init', 'riscv_cpu_init',
                 'pthread_join', 'madvise', 'fclose', 'napi_create_async_work', 'napi_set_named_property']
        run('link-monitor-' + str(mode), [args.cc, '-shared', '-Wl,-z,nodelete',
            *['-Wl,--wrap=' + name for name in wraps], *objects, monitor, '-pthread', '-lm', '-o', library]).check_returncode()
    failed = False
    for variant in ['plain'] if args.plain_only else ['plain', 'jitless']:
        for case in cases:
            label = variant + '-' + case
            config_path = out / (case + '.json' if case in ['poweroff', 'fatal', 'missing'] else 'normal.json')
            result = run(label, [args.node, *(['--jitless'] if variant == 'jitless' else []),
                                 HERE / 'node-case.mjs', libraries[modes[case]], config_path, case])
            rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
            report['observations'].append({'label': label, 'exitCode': result.returncode, 'rows': rows})
            failed |= result.returncode != 0
            print(label, 'PASS' if result.returncode == 0 else 'FAIL', flush=True)
            save()
    report['status'] = 'FAIL' if failed else 'PASS_SCOPED_PRODUCT_JOIN_RAM_RETIREMENT'
    report['endedUTC'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    save()
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())
