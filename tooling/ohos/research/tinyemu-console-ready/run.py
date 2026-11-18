#!/usr/bin/env python3
"""Actual TinyEMU/slirp/VirtIO console readiness with finite diagnostic controls."""
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
CASES = ('queue-unready', 'queue-empty', 'no-ready', 'no-console',
         'console-ready', 'both-ready', 'console-eof')
DIAGNOSTIC_REDS = {'queue-unready', 'queue-empty'}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-archive', type=Path, required=True)
    parser.add_argument('--node-headers', type=Path, required=True)
    parser.add_argument('--cc', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    native = ROOT / 'runtime/ohos/linux/native'
    environment = {key: os.environ[key] for key in ('PATH', 'LANG', 'LC_ALL') if key in os.environ}
    report = {'status': 'RUNNING', 'startedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'scope': 'Real product translation unit/slirp UDP/VirtIO console; explicit CPU packet/ring/IRQ fixtures; no guest instructions or device',
              'commands': [], 'checks': [], 'inputsBefore': {}}

    def save():
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')

    def record(paths):
        for path in paths:
            path = Path(path).resolve()
            digest = sha(path)
            if str(path) in report['inputsBefore']:
                assert report['inputsBefore'][str(path)] == digest
            report['inputsBefore'][str(path)] = digest

    def run(folder, label, argv, expected=0, timeout=45):
        folder.mkdir(parents=True, exist_ok=True)
        argv = list(map(str, argv))
        row = {'label': label, 'directory': str(folder.relative_to(out)), 'argv': argv}
        try:
            result = subprocess.run(argv, capture_output=True, timeout=timeout, env=environment)
        except subprocess.TimeoutExpired as error:
            (folder / (label + '.stdout')).write_bytes(error.stdout or b'')
            (folder / (label + '.stderr')).write_bytes(error.stderr or b'')
            row.update(exitCode=None, timedOut=True)
            report['commands'].append(row)
            save()
            raise
        (folder / (label + '.stdout')).write_bytes(result.stdout)
        (folder / (label + '.stderr')).write_bytes(result.stderr)
        row.update(exitCode=result.returncode, timedOut=False)
        report['commands'].append(row)
        save()
        if expected is not None:
            assert result.returncode == expected, (label, result.stderr.decode(errors='replace'))
        return result

    try:
        lock = json.loads((native / 'source-lock.json').read_text())
        assert sha(args.source_archive) == lock['archiveSha256']
        assert all(sha(native / name) == digest for name, digest in lock['files'].items())
        record([HERE / 'run.py', HERE / 'console-ready.c', native / 'build.py',
                native / 'source-lock.json', args.source_archive, args.cc])
        record(native / name for name in lock['files'])
        record(args.node_headers / name for name in ('node_api.h', 'node_api_types.h',
               'js_native_api.h', 'js_native_api_types.h', 'node_version.h'))
        built = out / 'native'
        run(out, 'build-native', [sys.executable, '-I', '-B', native / 'build.py',
            '--source-archive', args.source_archive.resolve(), '--node-headers', args.node_headers.resolve(),
            '--cc', args.cc.resolve(), '--output', built, '--host-test'], timeout=180)
        source = built / 'tinyemu-2019-12-21'
        commands = json.loads((built / 'commands.json').read_text())
        assert all(item['code'] == 0 for item in commands)
        compile_temu = next(item['argv'] for item in commands if '-c' in item['argv']
                            and str(source / 'temu.c') in item['argv'])
        flags = compile_temu[1:compile_temu.index('-c')]
        objects = [Path(item) for item in commands[-1]['argv'] if item.endswith('.o')
                   and Path(item).name not in ('temu.o', 'binding.o')]
        source_paths = [p for p in source.rglob('*') if p.suffix in ('.c', '.h')]
        record([built / 'BUILD.json', built / 'commands.json', *objects, *source_paths])
        report['freshNativeCommands'] = len(commands)
        report['reusedUnchangedProductObjects'] = len(objects)
        report['productCompileFlags'] = flags
        report['compilerVersion'] = run(out, 'compiler-version', [args.cc, '--version']).stdout.decode(errors='replace')
        baseline = out / 'baseline-source'
        shutil.copytree(source, baseline, ignore=shutil.ignore_patterns('*.orig'))
        run(out, 'reverse-only-console-guard', ['patch', '--fuzz=0', '-R', '-d', baseline,
            '-p1', '-i', native / 'patches/0022-console-input-ready.patch'])
        differences = [p.relative_to(source).as_posix() for p in source_paths
                       if sha(p) != sha(baseline / p.relative_to(source))]
        assert differences == ['temu.c']
        report['onlyGeneratedSourceDifference'] = differences
        record(p for p in baseline.rglob('*') if p.suffix in ('.c', '.h'))
        original = (baseline / 'temu.c').read_text()
        fragment = '#ifndef _WIN32\n    int stdin_fd;\n#endif'
        assert original.count(fragment) == 1
        assert original.count('if (m->console_dev && FD_ISSET(stdin_fd, &rfds))') == 1
        exact_guard = original.replace(fragment, fragment.replace('int stdin_fd;', 'int stdin_fd = -1;'))
        exact_guard = exact_guard.replace('if (m->console_dev && FD_ISSET(stdin_fd, &rfds))',
            'if (m->console_dev && stdin_fd >= 0 && FD_ISSET(stdin_fd, &rfds))')
        assert exact_guard == (source / 'temu.c').read_text()
        report['onlyTwoLineGuard'] = True

        for label, src, diagnostic in (('baseline-diagnostic', baseline, True),
                                       ('candidate-diagnostic', source, True),
                                       ('candidate-product-flags', source, False)):
            folder = out / label
            selected_flags = [item.replace(str(source), str(src)) for item in flags]
            extra = ['-O1', '-g', '-ftrivial-auto-var-init=pattern', '-fsanitize=undefined',
                     '-fno-sanitize-recover=all'] if diagnostic else []
            obj = folder / 'console-ready.o'
            exe = folder / 'console-ready'
            run(folder, 'compile', [args.cc, *selected_flags, *extra,
                '-c', HERE / 'console-ready.c', '-o', obj])
            run(folder, 'link', [args.cc, *(['-fsanitize=undefined'] if diagnostic else []),
                obj, *objects, *['-Wl,--wrap=' + name for name in ('select', 'recv', 'exit', 'abort', '__assert_fail')],
                '-pthread', '-lm', '-o', exe])
            rows = []
            for case in CASES:
                expected = 1 if label == 'baseline-diagnostic' and case in DIAGNOSTIC_REDS else 0
                result = run(folder, case, [exe, case], expected=expected, timeout=5)
                if expected:
                    assert b'runtime error:' in result.stderr and b'temu.c:' in result.stderr
                    value = {'case': case, 'legacyDiagnosticRed': True}
                else:
                    value = json.loads(result.stdout)
                    assert value['case'] == case and value['passed'] is True
                rows.append(value)
            report['checks'].append({'label': label, 'diagnosticFlags': extra,
                'executableSha256': sha(exe), 'cases': rows,
                'legacyReds': 2 if label == 'baseline-diagnostic' else 0,
                'successfulCases': 5 if label == 'baseline-diagnostic' else 7})
            save()
            print(label, '2 expected diagnostic reds, 5 controls' if label == 'baseline-diagnostic' else '7/7', flush=True)

        assert report['inputsBefore'] == {name: sha(name) for name in report['inputsBefore']}
        report.update(status='PASS_SCOPED_CONSOLE_READY', inputReadbackUnchanged=True,
            endedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
            limits=['diagnostic baseline does not claim normal-production crash',
                    'CPU packets and guest ring are explicit fixtures, no guest instruction execution',
                    'case processes retain their local network queue until exit, not a shutdown/leak test',
                    'no waker/cap/SDK/HAP/device/performance claim'])
        save()
        print(report['status'], flush=True)
        return 0
    except Exception as error:
        report.update(status='FAIL', error=repr(error))
        save()
        raise


if __name__ == '__main__':
    raise SystemExit(main())
