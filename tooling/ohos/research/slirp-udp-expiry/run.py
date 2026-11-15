#!/usr/bin/env python3
"""Real slirp UDP deadlines/FDs; explicit monotonic clock and CPU packet fixture."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
SLIRP = 'bootp ip_icmp mbuf slirp tcp_output cksum ip_input misc socket tcp_subr udp if ip_output sbuf tcp_input tcp_timer'.split()
LEGACY_FAILURES = {
    'wrap-new', 'deadline-zero-at-zero', 'deadline-zero-after', 'pause-over-full32-cycle',
    'listener-accept-once-2', 'send-renews-zero-deadline', 'send-creates-zero-deadline',
    'recv-normal240s-renews-zero-deadline', 'recv-normal240s-renews-creates-zero',
    'recv-DNS10s-renews-zero-deadline', 'recv-DNS10s-renews-creates-zero',
}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-archive', type=Path, required=True)
    parser.add_argument('--node-headers', type=Path, required=True)
    parser.add_argument('--cc', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=False)
    native = ROOT / 'runtime/ohos/linux/native'
    report = {'schema': 1, 'status': 'RUNNING', 'startedUTC': utc(), 'commands': [], 'checks': [],
              'scope': 'Fresh real slirp, real UDP FDs and actual first product loop; explicit CLOCK_MONOTONIC and CPU packet producer, no guest instructions, device or wall-time expiry bound'}
    environment = {k: os.environ[k] for k in ['PATH', 'LANG', 'LC_ALL'] if k in os.environ}
    inputs = {}

    def save():
        (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')

    def run(folder, label, argv, expected=0, timeout=45):
        folder.mkdir(parents=True, exist_ok=True)
        argv = list(map(str, argv))
        row = {'directory': str(folder.relative_to(out)), 'label': label, 'argv': argv, 'startedUTC': utc()}
        try:
            result = subprocess.run(argv, capture_output=True, env=environment, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            (folder / (label + '.stdout')).write_bytes(error.stdout or b'')
            (folder / (label + '.stderr')).write_bytes(error.stderr or b'')
            row.update(exitCode=None, timedOut=True); report['commands'].append(row); save(); raise
        (folder / (label + '.stdout')).write_bytes(result.stdout)
        (folder / (label + '.stderr')).write_bytes(result.stderr)
        row.update(exitCode=result.returncode, timedOut=False, endedUTC=utc())
        report['commands'].append(row); save()
        if expected is not None and result.returncode != expected:
            raise RuntimeError(label + ' returned ' + str(result.returncode))
        return result

    def record(paths):
        for path in paths:
            path = path.resolve(); value = sha(path)
            if str(path) in inputs: assert inputs[str(path)] == value
            inputs[str(path)] = value

    try:
        lock = json.loads((native / 'source-lock.json').read_text())
        assert sha(args.source_archive) == lock['archiveSha256']
        for path, value in lock['files'].items(): assert sha(native / path) == value
        record([HERE / name for name in ['run.py', 'expiry.c', 'first-poll.c']])
        record([native / 'build.py', native / 'source-lock.json', args.source_archive, args.cc])
        record([args.node_headers / name for name in ['node_api.h', 'node_api_types.h',
                'js_native_api.h', 'js_native_api_types.h', 'node_version.h']])
        record([native / path for path in lock['files']])
        built = out / 'native'
        run(out, 'build-native', [sys.executable, '-I', '-B', native / 'build.py',
            '--source-archive', args.source_archive.resolve(), '--node-headers', args.node_headers.resolve(),
            '--cc', args.cc.resolve(), '--output', built, '--host-test'], timeout=180)
        source = built / 'tinyemu-2019-12-21'
        commands = json.loads((built / 'commands.json').read_text())
        compile_temu = next(c['argv'] for c in commands if '-c' in c['argv'] and str(source / 'temu.c') in c['argv'])
        product_flags = compile_temu[1:compile_temu.index('-c')]
        product_objects = [Path(x) for x in commands[-1]['argv'] if x.endswith('.o')]
        assert len(product_objects) > 20 and '-DTEMU_EMBED' in product_flags and '-UNDEBUG' in product_flags
        record([built / 'BUILD.json', *product_objects])
        record([p for p in source.rglob('*') if p.suffix in ('.c', '.h')])
        # 0023 consumes the corrected UDP fields/clock and TCP pending state.
        # Compare the target patch on a common pre-event-wait layer, while the
        # separately named candidate-embed set still runs the full current chain.
        comparison = out / 'comparison-source'
        report['uncompiledBackupsOmitted'] = [str(p.relative_to(source)) for p in source.rglob('*.orig')]
        shutil.copytree(source, comparison, ignore=shutil.ignore_patterns('*.orig'))
        comparison_reversed = ['0024-embedded-start-close-debt.patch', '0023-embedded-event-wait.patch']
        for patch in comparison_reversed:
            run(out, 'comparison-reverse-' + patch[:4], ['patch', '--fuzz=0', '-R', '-d', comparison,
                '-p1', '-i', native / 'patches' / patch])
        baseline = out / 'baseline-source'
        shutil.copytree(comparison, baseline, ignore=shutil.ignore_patterns('*.orig'))
        run(out, 'baseline-reverse-0020', ['patch', '--fuzz=0', '-R', '-d', baseline, '-p1', '-i',
                                     native / 'patches/0020-embedded-udp-expiry.patch'])
        changed = sorted(p.relative_to(comparison).as_posix() for p in comparison.rglob('*')
                   if p.suffix in ('.c', '.h') and sha(p) != sha(baseline / p.relative_to(comparison)))
        assert changed == ['slirp/misc.c', 'slirp/misc.h', 'slirp/slirp.c',
                                   'slirp/socket.c', 'slirp/socket.h', 'slirp/udp.c'], changed
        report['baselineMeaning'] = 'Common historical layer: current chain minus0024/0023, then only0020 reversed; full current candidate also executes separately'
        report['comparisonReversedPatches'] = comparison_reversed
        report['onlyTargetDifferencesBetweenCommonLayers'] = changed
        report['fullCandidateVersusCommonLayerDifferences'] = sorted(p.relative_to(source).as_posix()
            for p in source.rglob('*') if p.suffix in ('.c', '.h')
            and sha(p) != sha(comparison / p.relative_to(source)))
        assert report['fullCandidateVersusCommonLayerDifferences'] == [
            'machine.h', 'riscv_machine.c', 'slirp/libslirp.h', 'slirp/slirp.c', 'temu.c', 'temu_embed.h']
        record([p for root in [comparison, baseline] for p in root.rglob('*') if p.suffix in ('.c', '.h')])

        def flags_for(src, embedded):
            return [x.replace(str(source), str(src)) for x in product_flags if embedded or x != '-DTEMU_EMBED']

        def compile_slirp(label, src, embedded, reuse=False):
            folder = out / label; flags = flags_for(src, embedded); objects = []
            for name in ['slirp/' + x for x in SLIRP] + ['cutils']:
                if reuse and name != 'slirp/misc':
                    objects.append(built / (name.replace('/', '_') + '.o')); continue
                obj = folder / (name.replace('/', '_') + '.o')
                extra = ['-Dclock_gettime=controlled_clock'] if name == 'slirp/misc' else []
                run(folder, 'compile-' + name.replace('/', '_'), [args.cc, *flags, *extra,
                    '-c', src / (name + '.c'), '-o', obj])
                objects.append(obj)
            record(objects)
            return folder, flags, objects

        sets = {}
        for label, src, embedded, reuse in [
            ('baseline-embed', baseline, True, False), ('comparison-embed', comparison, True, False),
            ('candidate-embed', source, True, True),
            ('baseline-nonembed', baseline, False, False), ('candidate-nonembed', source, False, False),
        ]:
            folder, flags, objects = compile_slirp(label, src, embedded, reuse)
            run(folder, 'link-expiry', [args.cc, *flags, HERE / 'expiry.c', *objects, '-lm', '-o', folder / 'expiry'])
            result = run(folder, 'expiry', [folder / 'expiry'], expected=None)
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            assert len(rows) == 31 and len({x['case'] for x in rows}) == 31
            failures = {x['case'] for x in rows if not x['passed']}
            expected_failures = set() if label in ('comparison-embed', 'candidate-embed') else LEGACY_FAILURES
            passed = failures == expected_failures and result.returncode == int(bool(expected_failures))
            check = {'label': label, 'passed': passed, 'rows': rows, 'failedCases': sorted(failures),
                     'meaning': 'Corrected candidate31/31' if not expected_failures else 'Original11defects reproduced; not31green'}
            report['checks'].append(check); save(); assert passed, label
            sets[label] = (folder, flags, objects, rows)
            print(label, 'candidate31/31' if not failures else 'expected legacy11failures/31', flush=True)
        assert sets['comparison-embed'][3] == sets['candidate-embed'][3]
        report['fullCandidateAndCommonLayerExact31RowsEqual'] = True
        assert sets['baseline-nonembed'][3] == sets['candidate-nonembed'][3]
        report['nonembedExact31RowsEqual'] = True

        layout_source = out / 'layout.c'
        layout_source.write_text('#include "slirp/slirp.h"\n#include <stddef.h>\nint main(void){printf("{\\"socketBytes\\":%zu,\\"slirpBytes\\":%zu,\\"expiryOffset\\":%zu,\\"queueOffset\\":%zu,\\"receiveOffset\\":%zu}\\n",sizeof(struct socket),sizeof(Slirp),offsetof(struct socket,so_expire),offsetof(struct socket,so_queued),offsetof(struct socket,so_rcv));return 0;}\n')
        layouts = {}
        for label in ['baseline-nonembed', 'candidate-nonembed']:
            folder, flags, _, _ = sets[label]
            run(folder, 'compile-layout', [args.cc, *flags, layout_source, '-o', folder / 'layout'])
            result = run(folder, 'layout', [folder / 'layout'])
            layouts[label] = json.loads(result.stdout)
        assert layouts['baseline-nonembed'] == layouts['candidate-nonembed']
        report['nonembedLayout'] = layouts

        first_polls = {}
        for label in ['baseline-embed', 'comparison-embed', 'candidate-embed']:
            folder, flags, slirp_objects, _ = sets[label]
            # Rebuild all slirp units against the matching private socket layout;
            # the unrelated machine objects come from the one fresh product build.
            other_objects = [p for p in product_objects if not p.name.startswith('slirp_')
                             and p.name not in ('temu.o', 'binding.o', 'cutils.o')]
            run(folder, 'compile-first-poll', [args.cc, *flags, '-c', HERE / 'first-poll.c', '-o', folder / 'first-poll.o'])
            run(folder, 'link-first-poll', [args.cc, folder / 'first-poll.o', *slirp_objects, *other_objects,
                *['-Wl,--wrap=' + x for x in ['select', 'exit', 'abort', '__assert_fail']],
                '-pthread', '-lm', '-o', folder / 'first-poll'])
            result = run(folder, 'first-poll', [folder / 'first-poll'])
            row = json.loads(result.stdout); assert row['passed'] is True
            first_polls[label] = row
            report['checks'].append({'label': label + '-first-poll', 'passed': True, 'row': row}); save()
        report['firstPollScope'] = 'Realtemu.c including private slirp_open/adapters; real loopback UDP; explicitCPUbatch, notguestinstructions'
        report['firstPollRows'] = first_polls
        assert inputs == {name: sha(name) for name in inputs}
        report['inputsBeforeAndAfter'] = inputs
        report.update(status='PASS_SCOPED_UDP_EXPIRY', endedUTC=utc(), fullMatrix='NOT_RUN', sdkDevice='NOT_RUN')
        save(); print('PASS_SCOPED_UDP_EXPIRY', flush=True); return 0
    except Exception as error:
        report.update(status='FAIL', error=repr(error), endedUTC=utc(), inputsBefore=inputs)
        save(); raise


if __name__ == '__main__':
    raise SystemExit(main())
