#!/usr/bin/env python3
"""Run the finite event-wait C component against supplied actual build objects.

The parent gate must bind the native build receipt. This runner hashes those
objects and all generated C/H before/after; it is not the complete Owner gate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--generated-source', type=Path, required=True)
    p.add_argument('--native', type=Path, required=True)
    p.add_argument('--objects', type=Path, required=True)
    p.add_argument('--repository', type=Path, required=True)
    p.add_argument('--inner-patch', type=Path, required=True)
    p.add_argument('--cc', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    src = a.generated_source.resolve(); native = a.native.resolve(); repo = a.repository.resolve()
    objects_dir = a.objects.resolve(); out = a.out.resolve(); out.mkdir(parents=True, exist_ok=False)
    here = Path(__file__).resolve().parent; cc = a.cc.resolve()
    research = repo / 'tooling/ohos/research'
    names = ['virtio', 'pci', 'fs', 'cutils', 'iomem', 'simplefb', 'json', 'machine', 'temu',
             'fs_disk', 'riscv_machine', 'softfp']
    names += ['slirp_' + x for x in 'bootp ip_icmp mbuf slirp tcp_output cksum ip_input misc socket tcp_subr udp if ip_output sbuf tcp_input tcp_timer'.split()]
    names += ['riscv_cpu32', 'riscv_cpu64', 'embed-fatal', 'embed-ram', 'fs_export']
    objects = [objects_dir / (name + '.o') for name in names]
    own = [here / n for n in ['component.py', 'wake-call.c', 'wake-boundary.c', 'wake-loop-bridge.c', 'slirp-deadline.c']]
    refs = [research / 'tinyemu-native/clock-cpu.c', research / 'tinyemu-sleep-micros/sleep-boundary.c',
            research / 'tinyemu-clint-deadline/timer-boundary.c', research / 'slirp-fasttimo/tcp-wire.c']
    source_files = sorted(f for f in src.rglob('*') if f.suffix in {'.c', '.h'})
    assert len(source_files) == 89
    inputs = {str(f): sha(f) for f in [*source_files, *objects, *own, *refs, native / 'temu_embed.h', a.inner_patch.resolve(), cc]}
    assert sha(native / 'temu_embed.h') == sha(src / 'temu_embed.h')
    report = {'scope': 'Actual C component, supplied real native objects bound by parent build receipt; explicit clock/select/syscall faults where stated; not full Owner/NAPI/Linux guest proof',
              'status': 'RUNNING', 'inputsBefore': inputs, 'commands': [], 'groups': []}

    def save():
        (out / 'RUN.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')

    def run(name, argv, expected=0, rows=None, raw=True):
        argv = [str(x) for x in argv]
        try:
            result = subprocess.run(argv, capture_output=True, timeout=30)
            code = result.returncode; stdout = result.stdout; stderr = result.stderr
        except subprocess.TimeoutExpired as error:
            code = None; stdout = error.stdout or b''; stderr = error.stderr or b''
        if raw:
            (out / (name + '.stdout')).write_bytes(stdout)
            (out / (name + '.stderr')).write_bytes(stderr)
        report['commands'].append({'name': name, 'argv': argv, 'exitCode': code,
            'stdoutSHA256': hashlib.sha256(stdout).hexdigest(), 'stderrSHA256': hashlib.sha256(stderr).hexdigest(), 'rawSaved': raw})
        save()
        assert code == expected, (name, code, stderr.decode(errors='replace')[:1800])
        if rows is not None:
            values = [json.loads(line) for line in stdout.splitlines()]
            assert len(values) == rows and all(v['passed'] == (expected == 0) for v in values)
            report['groups'].append({'name': name, 'exitCode': code, 'rows': values}); save()
        return stdout

    flags = ['-O2', '-g0', '-fPIC', '-fvisibility=hidden', '-UNDEBUG', '-D_FILE_OFFSET_BITS=64',
             '-D_LARGEFILE_SOURCE', '-D_GNU_SOURCE', '-DCONFIG_VERSION="2019-12-21"', '-DCONFIG_SLIRP',
             '-DCONFIG_RISCV_MAX_XLEN=64', '-DTEMU_EMBED', '-DDSH_FS_EXPORT', '-I', native, '-I', src]
    fatal = ['-Wl,--wrap=exit', '-Wl,--wrap=abort', '-Wl,--wrap=__assert_fail']
    exe = out / 'wake-call'
    run('link-entry', [cc, *flags, '-std=c11', '-Wall', '-Wextra', '-Werror', here / 'wake-call.c', *objects,
        *fatal, '-Wl,--wrap=select', '-Wl,--wrap=poll', '-Wl,--wrap=clock_gettime', '-pthread', '-lm', '-o', exe])
    def addi(rd, value): return ((value & 4095) << 20) | (rd << 7) | 0x13
    def sw(rs, offset): return (rs << 20) | (1 << 15) | (2 << 12) | (offset << 7) | 0x23
    code = [0x400080b7, 0x01010137]
    for byte in b'1247-WFI\n': code += [addi(3, byte), sw(3, 0), sw(2, 4)]
    code += [0x10500073, 0xffdff06f]
    (out / 'bios.bin').write_bytes(b''.join(struct.pack('<I', n) for n in code))
    config = out / 'config.json'; config.write_text(json.dumps({'version': 1, 'machine': 'riscv64', 'memory_size': 16, 'bios': 'bios.bin', 'cmdline': ''}) + '\n')
    modes = ['select-stop', 'select-before', 'stop-before', 'output-stop', 'select-eintr', 'output-eintr',
             'select-fail', 'output-fail', 'clock-fail', 'wake-eof', 'wake-data', 'output-closed', 'invalid',
             'legacy-select', 'legacy-output', 'select-fail-stop', 'output-fail-stop']
    for mode in modes: run('entry-' + mode, [exe, config, mode], rows=1)

    baseline = out / 'baseline-source'; shutil.copytree(src, baseline)
    run('reverse-only-event-wait', ['patch', '--fuzz=0', '-R', '-d', baseline, '-p1', '-i', a.inner_patch.resolve()])
    changed = [str(f.relative_to(src)) for f in source_files if sha(f) != sha(baseline / f.relative_to(src))]
    assert sorted(changed) == ['machine.h', 'riscv_machine.c', 'slirp/libslirp.h', 'slirp/slirp.c', 'temu.c', 'temu_embed.h']
    report['baselineGeneratedDifferences'] = changed
    misc = out / 'slirp_misc_clock.o'
    run('compile-slirp-clock', [cc, *flags, '-Dclock_gettime=controlled_clock', '-c', src / 'slirp/misc.c', '-o', misc])
    slirp_objects = [f for f in objects if f.name.startswith('slirp_') and f.name not in {'slirp_slirp.o', 'slirp_misc.o'}]
    slirp_objects += [objects_dir / 'cutils.o', misc]
    cases = [('normal', ['tcp', '1000', '2']), ('absolute-zero', ['tcp', '0', '2']),
             ('wrap', ['tcp', str(0xffffffff), '2']), ('long-pause', ['tcp', '1000', str(0x100000001)]),
             ('high-uptime', ['tcp', str(0x100000000), '1']), ('udp', ['udp-expiry']), ('ready', ['ready']),
             ('queue', ['queued']), ('empty', ['empty']), ('fragment', ['fragment'])]
    for label, source in [('baseline', baseline), ('candidate', src)]:
        exe = out / ('slirp-' + label)
        scoped_flags = [str(x).replace(str(src), str(source)) for x in flags]
        run('link-slirp-' + label, [cc, *scoped_flags, '-I', research / 'slirp-fasttimo', '-I', source / 'slirp',
            *(['-DPRODUCT_DEADLINE'] if label == 'candidate' else []),
            '-DSLIRP_STUDY_SOURCE="' + str(source / 'slirp/slirp.c') + '"', here / 'slirp-deadline.c',
            *slirp_objects, '-lm', '-o', exe])
        for name, argv in cases:
            run('slirp-' + label + '-' + name, [exe, *argv], int(label == 'baseline' and name == 'long-pause'), rows=1)

    misc = out / 'slirp_misc_boundary.o'; bridge = out / 'wake-loop-bridge.o'
    run('compile-boundary-clock', [cc, *flags, '-Dclock_gettime=controlled_slirp_clock', '-c', src / 'slirp/misc.c', '-o', misc])
    run('compile-boundary-bridge', [cc, *flags, '-Dclock_gettime=controlled_slirp_clock', '-c', here / 'wake-loop-bridge.c', '-o', bridge])
    selected = [f for f in objects if f.name not in {'temu.o', 'riscv_machine.o', 'slirp_misc.o'}] + [misc, bridge]
    exe = out / 'wake-boundary'
    run('link-boundary', [cc, *flags, '-I', research / 'tinyemu-native', here / 'wake-boundary.c', *selected,
        *fatal, '-Wl,--wrap=select', '-pthread', '-lm', '-o', exe])
    for mode in ['distant-future', 'submicro', 'micro-floor', 'due', 'non-wfi', 'masked-mtip', 'legacy', 'fragment-common-sample', 'permanent-udp']:
        run('boundary-' + mode, [exe, mode], rows=1)

    selected = [f for f in objects if f.name != 'riscv_machine.o']
    exe = out / 'sleep-boundary'
    run('link-legacy-micros', [cc, *flags, '-I', research / 'tinyemu-native', research / 'tinyemu-sleep-micros/sleep-boundary.c',
        *selected, *fatal, '-Wl,--wrap=select', '-pthread', '-lm', '-o', exe])
    for name, argv, count in [('micros', [], 52), ('legacy-ms', ['--legacy-ms'], 14), ('legacy-class', ['--legacy-class'], 3)]:
        run(name, [exe, *argv], rows=count)
    exe = out / 'timer-boundary'
    run('link-unsigned-clint', [cc, *flags, '-I', research / 'tinyemu-native', research / 'tinyemu-clint-deadline/timer-boundary.c',
        *selected, *fatal, '-pthread', '-lm', '-o', exe])
    run('unsigned-clint', [exe], rows=14)

    preprocessed = {}
    for name in ['temu.c', 'riscv_machine.c', 'slirp/slirp.c']:
        values = []
        for label, source in [('baseline', baseline), ('candidate', src)]:
            scoped_flags = [str(x).replace(str(src), str(source)) for x in flags if x != '-DTEMU_EMBED']
            data = run('nonembed-' + label + '-' + name.replace('/', '_'), [cc, *scoped_flags,
                '-ffile-prefix-map=' + str(source) + '=/fixed-tinyemu', '-E', '-P', source / name], raw=False)
            values.append(hashlib.sha256(data).hexdigest())
        assert values[0] == values[1], (name, values)
        preprocessed[name] = values[0]
    report['nonembedEqualSHA256'] = preprocessed
    report['inputsAfter'] = {path: sha(path) for path in inputs}
    assert inputs == report['inputsAfter']
    report.update(status='PASS_SCOPED_C_COMPONENT', candidateChecks=119, baselineControls=9, baselineExpectedRed=1,
                  completeWaker='NOT_PROVEN_BY_COMPONENT', sdkDevice='NOT_RUN')
    save()
    print(json.dumps({'status': report['status'], 'candidateChecks': 119, 'baselineControls': 9, 'baselineRed': 1}))


if __name__ == '__main__':
    main()
