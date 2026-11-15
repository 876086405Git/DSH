#!/usr/bin/env python3
"""Native rg15, real restricted FS, and explicit private-budget differential."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalize(records):
    output = []
    for record in records:
        if record.get('type') != 'match':
            continue
        value = json.loads(json.dumps(record))
        path = value['data']['path']['text']
        if path.startswith('./'):
            value['data']['path']['text'] = path[2:]
        output.append(value)
    return sorted(output, key=lambda row: json.dumps(row, ensure_ascii=False, sort_keys=True).encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['runtime', 'node', 'rg', 'preload', 'marker', 'bash-module', 'out']:
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--mode', choices=['jit', 'strict'], required=True)
    args = parser.parse_args()
    for name in ('runtime', 'node', 'rg', 'preload', 'marker', 'bash_module', 'out'):
        setattr(args, name, getattr(args, name).resolve())
    actor = Path(__file__).resolve().with_name('process-rg-selection-actor.mjs')
    report = {'schema': 1, 'mode': args.mode,
              'scope': 'Native rg JSON match records; direct adapter and public Bash command context; actual FS. Private lowered limits are not a native rg option.',
              'inputs': {name: sha(path) for name, path in {
                  'node': args.node, 'rg': args.rg, 'rg.mjs': args.runtime / 'rg.mjs',
                  'rg-select.mjs': args.runtime / 'rg-select.mjs',
                  'filesystem.mjs': args.runtime / 'filesystem.mjs',
                  'bashModule': args.bash_module, 'actor': actor,
                  'driver': Path(__file__), 'preload': args.preload, 'marker': args.marker,
              }.items()}, 'rows': [], 'invocations': []}
    report['nativeVersion'] = subprocess.check_output([str(args.rg), '--version'], text=True)
    assert 'ripgrep 15.0.0' in report['nativeVersion']
    assert report['inputs']['rg'] == '193906679498de4d939345b937fa24e0e69a03c244bd70c859f5e41232713f21'
    with tempfile.TemporaryDirectory(prefix='ohos-rg-selection-oracle-') as temporary:
        root = Path(temporary)
        root.chmod(0o755)
        def directory(name, files):
            path = root / name
            path.mkdir(mode=0o755)
            for name, data in files.items():
                target = path / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(data)
            return path

        empty = directory('empty', {})
        hidden = directory('hidden', {'.hidden': 'needle hidden\n'})
        ignored = directory('ignored', {'.ignore': '*\n', 'a.txt': 'needle ignored\n'})
        files = directory('files', {'a.txt': 'needle a 中文\n', 'b.txt': 'needle b\n', 'c.txt': 'needle c\n', 'd.txt': 'other d\n'})
        nested = directory('nested', {'a.txt': 'needle a\n', 'sub/b.txt': 'needle b\n'})
        array_files = directory('array-files', {f'{number:02}.txt': f'needle {number}\n' for number in range(13)})
        argv = ['--no-config', '--json', '--regexp=needle']
        cases = []
        for name, cwd in [('empty', empty), ('hidden-only', hidden), ('ignored-all', ignored)]:
            for explicit in (False, True):
                cases.append({'name': name + ('-explicit' if explicit else '-implicit'),
                              'cwd': str(cwd), 'args': argv + (['--', '.'] if explicit else []), 'comparison': 'exact'})
        for explicit in (False, True):
            cases.append({'name': 'positive-glob-empty' + ('-explicit' if explicit else '-implicit'),
                          'cwd': str(files), 'args': argv + ['--glob=*.md'] + (['--', '.'] if explicit else []), 'comparison': 'exact'})
        cases += [
            {'name': 'negative-glob-empty', 'cwd': str(files), 'args': argv + ['--glob=!*', '--', '.'], 'comparison': 'exact'},
            {'name': 'eligible-no-match', 'cwd': str(files), 'args': ['--no-config', '--json', '--regexp=absent', '--', '.'], 'comparison': 'exact'},
            {'name': 'explicit-file-bypasses-glob', 'cwd': str(files), 'args': argv + ['--glob=*.md', '--', 'a.txt'], 'comparison': 'exact'},
            {'name': 'finite-full-search', 'cwd': str(files), 'args': argv + ['--', '.'], 'comparison': 'exact'},
            {'name': 'glob-exact-boundary', 'cwd': str(files), 'args': argv + ['--', '.'], 'limits': {'maxGlobOperations': 5}, 'comparison': 'exact'},
            {'name': 'array-exact-boundary', 'cwd': str(array_files), 'args': argv + ['--', '.'], 'limits': {'maxArrayElements': 13}, 'comparison': 'exact'},
        ]
        for name, limit, keep in [('glob-before-first', {'maxGlobOperations': 1}, []), ('glob-after-first', {'maxGlobOperations': 2}, ['a.txt'])]:
            cases.append({'name': name, 'cwd': str(files), 'args': argv + ['--', '.'], 'limits': limit, 'comparison': 'private-budget', 'keep': keep})
        # The global array budget also bounds expanded shell argv. Use a larger
        # real fixture so Bash reaches rg before this file-selection budget.
        for limit in (8, 9):
            cases.append({'name': f'array-after-{limit}', 'cwd': str(array_files),
                          'args': argv + ['--', '.'], 'limits': {'maxArrayElements': limit},
                          'comparison': 'private-budget', 'keep': [f'{number:02}.txt' for number in range(limit)]})
        cases += [
            {'name': 'glob-no-match-before-limit', 'cwd': str(files), 'args': ['--no-config', '--json', '--regexp=absent', '--', '.'], 'limits': {'maxGlobOperations': 2}, 'comparison': 'private-budget', 'keep': []},
            {'name': 'glob-implicit-partial', 'cwd': str(files), 'args': argv, 'limits': {'maxGlobOperations': 2}, 'comparison': 'private-budget', 'keep': ['a.txt']},
            {'name': 'glob-nested-before-child', 'cwd': str(nested), 'args': argv + ['--', '.'], 'limits': {'maxGlobOperations': 4}, 'comparison': 'private-budget', 'keep': ['a.txt']},
        ]
        unreadable = []
        permission_cases = []
        for name, denied, allowed in [('denied-dir-first', '00-denied', 'zz-allowed'), ('denied-dir-last', 'zz-denied', '00-allowed')]:
            cwd = directory(name, {denied + '/private.txt': 'needle denied\n', allowed + '/good.txt': 'needle good\n'})
            (cwd / denied).chmod(0)
            unreadable.append(cwd / denied)
            permission_cases.append({'name': name, 'cwd': str(cwd), 'args': argv + ['--', '.'], 'comparison': 'io-error-reference'})
        for name, denied, allowed in [('denied-file-first', '00-denied.txt', 'zz-good.txt'), ('denied-file-last', 'zz-denied.txt', '00-good.txt')]:
            cwd = directory(name, {denied: 'needle denied\n', allowed: 'needle good\n'})
            (cwd / denied).chmod(0)
            unreadable.append(cwd / denied)
            permission_cases.append({'name': name, 'cwd': str(cwd), 'args': argv + ['--', '.'], 'comparison': 'io-error-reference'})

        global_repo = directory('global-repo', {'ordinary.txt': 'needle ordinary\n', '.hidden': 'needle hidden\n'})
        subprocess.run(['git', 'init', '--quiet', str(global_repo)], check=True)
        xdg = root / 'xdg'
        (xdg / 'git').mkdir(parents=True)
        global_ignore = root / 'global-ignore'
        (xdg / 'git/config').write_text('[core]\n excludesFile = ' + str(global_ignore) + '\n')
        baseline_xdg = root / 'empty-xdg'
        baseline_xdg.mkdir()
        executable = root / 'native-rg'
        try:
            os.link(args.rg, executable)
        except OSError:
            shutil.copy2(args.rg, executable)
        uid = 65534 if os.geteuid() == 0 else None
        def lower_uid():
            os.setgroups([])
            os.setgid(uid)
            os.setuid(uid)

        def group(name, source_cases, *, restricted_uid=None, global_rule=None):
            env = {**os.environ, 'LC_ALL': 'C', 'XDG_CONFIG_HOME': str(xdg if global_rule is not None else baseline_xdg)}
            if global_rule is not None:
                global_ignore.write_text(global_rule)
            native = {}
            for case in source_cases:
                result = subprocess.run([str(executable), *case['args']], cwd=case['cwd'], stdin=subprocess.DEVNULL,
                                        capture_output=True, env=env, preexec_fn=lower_uid if restricted_uid is not None else None)
                rows = [json.loads(line) for line in result.stdout.decode().splitlines() if line]
                native[case['name']] = {'exitCode': result.returncode, 'stdout': result.stdout.decode(),
                                        'stderr': result.stderr.decode(), 'matches': normalize(rows)}
            debug = None
            if global_rule is not None:
                case = source_cases[0]
                run = subprocess.run([str(executable), '--debug', *case['args']], cwd=case['cwd'], stdin=subprocess.DEVNULL,
                                     capture_output=True, env=env)
                debug = run.stderr.decode()
                assert 'opened gitignore file: ' + str(global_ignore) in debug, 'global-ignore positive control did not actually load'
            expanded = [{**case, 'name': case['name'] + '-' + entry, 'sourceCase': case['name'], 'entry': entry}
                        for case in source_cases for entry in ['direct', 'bash']]
            request = {'mode': args.mode, 'module': str((args.runtime / 'rg.mjs').resolve()),
                       'filesystem': str((args.runtime / 'filesystem.mjs').resolve()), 'bashModule': str(args.bash_module.resolve()),
                       'cases': expanded}
            if restricted_uid is not None:
                request['uid'] = restricted_uid
            request_path = root / (name + '-request.json')
            request_path.write_text(json.dumps(request))
            request_path.chmod(0o644)
            command = [str(args.node)]
            if args.mode == 'strict':
                command += ['--jitless', '--import', str(args.preload)]
            else:
                command += ['--import', str(args.marker)]
            command += [str(actor), str(request_path)]
            result = subprocess.run(command, capture_output=True, env={**env, 'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony', 'DSH_GO_OHOS_SIM_ADDONS': '[]'})
            invocation = {'group': name, 'argv': command, 'exitCode': result.returncode, 'stderr': result.stderr.decode(), 'request': request,
                          'nativeUid': restricted_uid if restricted_uid is not None else os.geteuid(),
                          'nativeEnv': {'LC_ALL': env['LC_ALL'], 'XDG_CONFIG_HOME': env['XDG_CONFIG_HOME']}}
            report['invocations'].append(invocation)
            assert result.returncode == 0, result.stderr.decode()
            received = json.loads(result.stdout)
            invocation['environment'] = {key: value for key, value in received.items() if key != 'rows'}
            for case, actual in zip(expanded, received['rows'], strict=True):
                expected = native[case['sourceCase']]
                records = normalize(actual['records'])
                kind = case['comparison']
                failures = []
                def check(value, reason):
                    if not value:
                        failures.append(reason)
                if kind == 'exact':
                    check(actual['exitCode'] == expected['exitCode'], 'exit code differs')
                    check(actual['stderr'] == expected['stderr'], 'stderr differs')
                    check(records == expected['matches'], 'complete match records differ')
                elif kind == 'private-budget':
                    retained = [row for row in expected['matches'] if row['data']['path']['text'] in case['keep']]
                    check(actual['exitCode'] == 2, 'incomplete result must remain exit 2')
                    check('结果不完整' in actual['stderr'], 'private limit must be explicit')
                    check(records == retained, 'already-selected matches lost or extra matches returned')
                    check(any(row['operation'] in ('readdir', 'readdirWithFileTypes') for row in actual['trace']), 'rg traversal was not reached')
                elif kind == 'io-error-reference':
                    check(expected['exitCode'] == 2 and 'os error 13' in expected['stderr'], 'native EACCES positive control failed')
                    check(actual['exitCode'] == 2 and 'EACCES' in actual['stderr'], 'adapter EACCES error classification differs')
                    check(records == expected['matches'], 'accessible match records lost after directory/file read error')
                else:
                    want_native = [] if kind == 'documented-extra' else ['.hidden', 'ordinary.txt']
                    check(sorted(row['data']['path']['text'] for row in expected['matches']) == want_native, 'native global-ignore effect differs')
                    check([row['data']['path']['text'] for row in records] == ['ordinary.txt'], 'adapter global-ignore documented boundary differs')
                    check(not any(row['operation'].startswith('readFile') and row['path'] == str(global_ignore) for row in actual['trace']), 'adapter read unauthorized global config')
                report['rows'].append({'name': actual['name'], 'comparison': kind, 'pass': not failures,
                                       'failures': failures, 'native': expected, 'actual': actual,
                                       'nativeDebug': debug, 'globalRule': global_rule})

        try:
            group('ordinary', cases)
            group('permission', permission_cases, restricted_uid=uid)
            for label, rule, comparison in [('global-exclude', 'ordinary.txt\n', 'documented-extra'), ('global-negated-hidden', '!.hidden\n', 'documented-missing')]:
                group(label, [{'name': label, 'cwd': str(global_repo), 'args': argv + ['--', '.'], 'comparison': comparison}], global_rule=rule)
        finally:
            for path in unreadable:
                path.chmod(0o700 if path.is_dir() else 0o600)
    report['passed'] = sum(row['pass'] for row in report['rows'])
    report['total'] = len(report['rows'])
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'passed': report['passed'], 'total': report['total'], 'out': str(args.out),
                      'failures': [{'name': row['name'], 'reasons': row['failures']} for row in report['rows'] if not row['pass']]}, ensure_ascii=False))
    if report['passed'] != report['total']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
