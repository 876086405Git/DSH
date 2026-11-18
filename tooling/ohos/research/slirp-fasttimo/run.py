#!/usr/bin/env python3
"""Real TCP delayed-ACK zero-timestamp regression; explicit guest packets and clock."""
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
CASES = [
    (1000, 1, 'normal', 0), (1000, 10, 'normal', 0),
    (0xffffffff, 1, 'normal', 0), (0x100000000, 1, 'normal', 0),
    (0x100000000, 10, 'normal', 0), (0x200000000, 1, 'normal', 0),
    (0x100000001, 1, 'normal', 0), (1000, 1, 'repeat', 0),
    (0x100000000, 1, 'repeat', 0), (1000, 1, 'second', 0),
    (0x100000000, 1, 'second', 0), (0x100000000, 1, 'closed', 0),
    (0x100000000, 1, 'normal', 1),
]
LEGACY_FAILURES = [3, 4, 5, 8, 10, 12]


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
              'scope': 'Actual slirp TCP handshake/data/ACK and loopback peer, explicit guest Ethernet/clock; no guest instructions, device, wall-time ACK bound or long-wait change'}
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
        record([HERE / name for name in ['run.py', 'tcp-wire.c']])
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
        compile_slirp = next(c['argv'] for c in commands if '-c' in c['argv'] and str(source / 'slirp/slirp.c') in c['argv'])
        product_flags = compile_slirp[1:compile_slirp.index('-c')]
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
        run(out, 'baseline-reverse-0021', ['patch', '--fuzz=0', '-R', '-d', baseline, '-p1', '-i',
                                     native / 'patches/0021-embedded-fasttimo-zero.patch'])
        changed = sorted(p.relative_to(comparison).as_posix() for p in comparison.rglob('*')
                   if p.suffix in ('.c', '.h') and sha(p) != sha(baseline / p.relative_to(comparison)))
        assert changed == ['slirp/slirp.c'], changed
        report['baselineMeaning'] = 'Common historical layer: current chain minus0024/0023, then only0021 reversed; full current candidate also executes separately'
        report['comparisonReversedPatches'] = comparison_reversed
        report['onlyTargetDifferencesBetweenCommonLayers'] = changed
        report['fullCandidateVersusCommonLayerDifferences'] = sorted(p.relative_to(source).as_posix()
            for p in source.rglob('*') if p.suffix in ('.c', '.h')
            and sha(p) != sha(comparison / p.relative_to(source)))
        assert report['fullCandidateVersusCommonLayerDifferences'] == [
            'machine.h', 'riscv_machine.c', 'slirp/libslirp.h', 'slirp/slirp.c', 'temu.c', 'temu_embed.h']
        record([p for root in [comparison, baseline] for p in root.rglob('*') if p.suffix in ('.c', '.h')])

        sets = {}
        for label, src, embedded, reuse in [
            ('baseline-embed', baseline, True, False), ('comparison-embed', comparison, True, False),
            ('candidate-embed', source, True, True),
            ('baseline-nonembed', baseline, False, False), ('candidate-nonembed', source, False, False),
        ]:
            folder = out / label; objects = []
            flags = [x.replace(str(source), str(src)) for x in product_flags if embedded or x != '-DTEMU_EMBED']
            for name in ['slirp/' + x for x in SLIRP] + ['cutils']:
                if reuse and name != 'slirp/misc':
                    objects.append(built / (name.replace('/', '_') + '.o')); continue
                obj = folder / (name.replace('/', '_') + '.o')
                run(folder, 'compile-' + name.replace('/', '_'), [args.cc, *flags,
                    *(['-Dclock_gettime=controlled_clock'] if name == 'slirp/misc' else []),
                    '-c', src / (name + '.c'), '-o', obj])
                objects.append(obj)
            record(objects)
            exe = folder / 'tcp-wire'
            run(folder, 'link', [args.cc, *flags, HERE / 'tcp-wire.c', *objects, '-lm', '-o', exe])
            rows = []; failed = []
            for index, case in enumerate(CASES):
                result = run(folder, 'case-' + str(index), [exe, *case], expected=None, timeout=10)
                row = json.loads(result.stdout); rows.append(row)
                assert result.returncode == int(not row['passed'])
                if not row['passed']: failed.append(index)
            expected_failures = [] if label in ('comparison-embed', 'candidate-embed') else LEGACY_FAILURES
            assert failed == expected_failures, (label, failed)
            report['checks'].append({'label': label, 'rows': rows, 'failedCases': failed,
                'meaning': '13 candidate scenarios passed' if not failed else 'Original 6 failing cases for one zero-sentinel defect among 13 controls; not13green'})
            sets[label] = rows; save()
            if not embedded:
                result = run(folder, 'preprocess', [args.cc, *flags, '-E', '-P',
                    '-ffile-prefix-map=' + str(src) + '=/fixed-tinyemu', src / 'slirp/slirp.c'])
                report[label + 'PreprocessedSha256'] = hashlib.sha256(result.stdout).hexdigest()
            print(label, '13 green' if not failed else '7 green / 6 original red', flush=True)
        assert sets['comparison-embed'] == sets['candidate-embed']
        report['fullCandidateAndCommonLayerExact13RowsEqual'] = True
        assert sets['baseline-nonembed'] == sets['candidate-nonembed']
        assert report['baseline-nonembedPreprocessedSha256'] == report['candidate-nonembedPreprocessedSha256']
        report['nonembedExactRowsAndNormalizedPreprocessorEqual'] = True
        assert inputs == {name: sha(name) for name in inputs}
        report['inputsBeforeAndAfter'] = inputs
        report.update(status='PASS_SCOPED_TCP_FASTTIMO', endedUTC=utc(), fullMatrix='NOT_RUN', sdkDevice='NOT_RUN')
        save(); print('PASS_SCOPED_TCP_FASTTIMO', flush=True); return 0
    except Exception as error:
        report.update(status='FAIL', error=repr(error), endedUTC=utc(), inputsBefore=inputs)
        save(); raise


if __name__ == '__main__':
    raise SystemExit(main())
