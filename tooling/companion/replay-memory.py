#!/usr/bin/env python3
"""09g offline results from the product tests; no model client or rule clone."""
import argparse
import base64
from collections import Counter
from datetime import datetime, timezone
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET


STATUSES = ('FAIL', 'NOT_RUN', 'NEEDS_REVIEW', 'PASS', 'NOT_APPLICABLE')
UNREAD = object()


def aggregate(values):
    values = set(values)
    return next((status for status in STATUSES if status in values), 'NOT_APPLICABLE')


class Report:
    """Read the whole JSON stream: an error may arrive after testDone."""

    def __init__(self, path, raw=UNREAD):
        self.path = path
        self.tests = {}
        self.complete = False
        self.success = None
        self.issue = None
        if raw is UNREAD:
            raw = path.read_bytes() if path.is_file() else None
        if raw is None:
            self.issue = 'report missing'
            return
        try:
            for line in raw.decode('utf-8').splitlines():
                event = json.loads(line)
                kind = event['type']
                if kind == 'testStart':
                    self.tests[event['test']['id']] = {'test': event['test'], 'errors': []}
                elif kind in ('testDone', 'error'):
                    item = self.tests.get(event['testID'])
                    if item is None:
                        raise ValueError('result without testStart')
                    if kind == 'error':
                        item['errors'].append(event)
                    else:
                        item['done'] = event
                elif kind == 'done':
                    success = event.get('success')
                    if type(success) is not bool:
                        self.issue = 'done.success must be a boolean'
                    elif self.success is not False:
                        self.success = success
        except (ValueError, KeyError, TypeError) as error:
            self.issue = f'incomplete reporter stream: {error}'
        self.complete = self.issue is None and self.success is not None
        if not self.complete and self.success is not False:
            self.success = None

    def check(self, name):
        found = [item for item in self.tests.values() if item['test']['name'] == name]
        if len(found) != 1:
            return 'NOT_RUN', self.issue or f'expected one named test; observed {len(found)}'
        item = found[0]
        done = item.get('done', {})
        # A proved failure survives an interrupted run or a later malformed line.
        if item['errors'] or done.get('result') in ('failure', 'error'):
            return 'FAIL', 'test error; see raw reporter events'
        if not self.complete:
            return 'NOT_RUN', self.issue or 'runner did not complete'
        if done.get('skipped') is not False:
            return 'NOT_RUN', 'required test was skipped'
        if done.get('hidden') is not False or done.get('result') != 'success':
            return 'NOT_RUN', 'no completed visible test result'
        return 'PASS', 'offline product assertion completed'


def batch_exit(codes):
    return next((code for code in codes if code not in (0, None)),
                None if None in codes else 0)


class BatchReport:
    """Keep each Windows child's Dart IDs and completion inside that child."""

    def __init__(self, path, raw, suite, guards, names, exit_code):
        self.path = path
        self.complete = False
        self.success = None
        self.issue = None
        self.guards = list(guards)
        self.plan = {}
        self.owners = {}
        self.observed = []
        results = {}
        failed = False
        footer = False
        if raw is None:
            self.issue = 'batch report missing'
            return
        try:
            lines = raw.splitlines()
            if not lines:
                raise ValueError('batch plan missing')
            plan = json.loads(lines[0])
            if (not isinstance(plan, dict) or plan.get('type') != 'replayBatchPlan' or
                    type(plan.get('version')) is not int or plan['version'] != 1 or
                    plan.get('suite') != suite or plan.get('guards') != self.guards):
                raise ValueError('batch plan does not match this suite and its guards')
            batches = plan.get('batches')
            if not isinstance(batches, list) or not batches:
                raise ValueError('batch plan has no batches')
            for batch in batches:
                identifier = batch['id']
                normal = batch['names']
                if (type(identifier) is not int or identifier <= 0 or identifier in self.plan or
                        not isinstance(normal, list) or any(not isinstance(n, str) or not n for n in normal)):
                    raise ValueError('invalid or duplicate planned batch')
                self.plan[identifier] = normal
                for name in normal:
                    if name in self.owners or name in self.guards:
                        raise ValueError('ordinary name belongs to more than one batch or is a guard')
                    self.owners[name] = identifier
            if set(self.owners) != set(names).difference(self.guards):
                raise ValueError('batch plan does not cover the manifest names')
            for line in lines[1:]:
                event = json.loads(line)
                kind = event['type']
                if kind == 'replayBatchResult':
                    identifier = event['id']
                    code = event['exit_code']
                    if type(code) is int and code != 0:
                        failed = True
                    if code is not None and type(code) is not int:
                        raise ValueError('invalid batch exit code')
                    encoded = event['report_base64']
                    if encoded is not None and not isinstance(encoded, str):
                        raise ValueError('invalid batch reporter bytes')
                    report = Report(path, None if encoded is None else base64.b64decode(encoded, validate=True))
                    # Remember proof before rejecting a duplicate/unknown result.
                    # A later structural error must not erase an earlier failure.
                    self.observed.append((identifier, report))
                    failed = failed or report.success is False or any(
                        item['errors'] or item.get('done', {}).get('result') in ('failure', 'error')
                        for item in report.tests.values())
                    if (footer or type(identifier) is not int or identifier not in self.plan or
                            identifier in results):
                        raise ValueError('duplicate, unknown or post-footer batch result')
                    results[identifier] = (code, report)
                elif kind == 'replayBatchesDone' and not footer:
                    footer = True
                else:
                    raise ValueError('unexpected batch event')
            if not footer or set(results) != set(self.plan):
                raise ValueError('batch run did not complete')
            codes = [results[identifier][0] for identifier in self.plan]
            if ((exit_code is not None and type(exit_code) is not int) or batch_exit(codes) != exit_code):
                raise ValueError('batch exits disagree with the original suite exit')
            if any(code is None for code in codes):
                raise ValueError('a batch has no actual child exit')
            if any(not report.complete for _, report in results.values()):
                raise ValueError('a Dart batch did not complete')
            for identifier, (_, report) in results.items():
                for item in report.tests.values():
                    owner = self.owners.get(item['test']['name'])
                    if owner is not None and owner != identifier:
                        raise ValueError('required test appeared in another batch')
            if any(report.check(name)[0] != 'PASS' for _, report in results.values() for name in self.guards):
                raise ValueError('every batch must complete every guard')
            successful = all(code == 0 and report.success is True and
                             all(report.check(name)[0] == 'PASS' for name in self.plan[identifier])
                             for identifier, (code, report) in results.items())
            self.complete = True
            if successful:
                self.success = True
        except (ValueError, KeyError, TypeError) as error:
            self.issue = f'incomplete batch reporter stream: {error}'
        if failed:
            self.success = False

    def check(self, name):
        identifiers = set(self.plan) if name in self.guards else {self.owners.get(name)}
        found = []
        for identifier, report in self.observed:
            if type(identifier) is int and identifier in identifiers:
                try:
                    found.append(report.check(name))
                except (ValueError, KeyError, TypeError) as error:
                    found.append(('NOT_RUN', f'incomplete Dart batch: {error}'))
        if any(status == 'FAIL' for status, _ in found):
            return 'FAIL', 'test error in a Dart batch; see canonical reporter bytes'
        if not self.complete:
            return 'NOT_RUN', self.issue or 'batch run did not complete'
        if not found:
            return 'NOT_RUN', 'name not in the batch plan'
        return next((result for result in found if result[0] != 'PASS'),
                    ('PASS', 'offline product assertion and every batch guard completed'))


def dart_report(path, raw, key, data, exit_code):
    try:
        first = json.loads(raw.splitlines()[0]) if raw else None
    except (ValueError, IndexError):
        first = None
    if isinstance(first, dict) and first.get('type') == 'replayBatchPlan':
        names = {check['name'] for case in data['cases'] for check in case['checks'] if check['suite'] == key}
        return BatchReport(path, raw, key, data['suites'][key]['guards'], names, exit_code)
    return Report(path, raw)


class EngineReport:
    """Node's real pinned-engine tests, with skipped cases kept as NOT_RUN."""

    def __init__(self, path, raw=UNREAD):
        self.path = path
        self.cases = []
        self.success = None
        self.issue = 'engine report missing'
        if raw is UNREAD:
            raw = path.read_bytes() if path.is_file() else None
        if raw is None:
            return
        try:
            self.cases = list(ET.fromstring(raw).iter('testcase'))
            self.success = bool(self.cases) and all(case.find('failure') is None and
                case.find('error') is None for case in self.cases)
            self.issue = None
        except ET.ParseError:
            self.issue = 'incomplete engine XML report'

    def check(self, name):
        found = [case for case in self.cases if case.get('name') == name]
        if len(found) != 1:
            return 'NOT_RUN', self.issue or f'expected one engine test; observed {len(found)}'
        case = found[0]
        if case.find('failure') is not None or case.find('error') is not None:
            return 'FAIL', 'actual engine test failed; see raw XML'
        skipped = case.find('skipped')
        if skipped is not None:
            return 'NOT_RUN', skipped.get('message', 'actual engine test skipped')
        return 'PASS', 'actual pinned engine with synthetic fetch completed'


def read_cases(path):
    data = json.loads(path.read_text(encoding='utf-8'))
    cases = data['cases']
    if data['fixture_version'] != 1 or data['ruleset'] != '09e-r2+r2.1':
        raise ValueError('unsupported fixture/rules version')
    if sorted(case['id'] for case in cases) != list(range(1, 16)):
        raise ValueError('the current acceptance set is exactly fixtures 1 through 15')
    if any(not suite['guards'] for key, suite in data['suites'].items() if key != 'engine'):
        raise ValueError('each offline suite must verify its network boundary')
    for case in cases:
        ids = [check['id'] for check in case['checks'] + case.get('required_gaps', [])]
        if not ids or len(ids) != len(set(ids)):
            raise ValueError(f'fixture {case["id"]}: missing or duplicate checks')
        for check in case['checks']:
            if check['suite'] not in data['suites'] or not check['name']:
                raise ValueError('check must identify a configured suite and full test name')
    return data


def read_fixtures(path, root, required_sources):
    """Bind this run to the compiled synthetic fixture sources, not a fake API."""
    raw = path.read_bytes()
    data = json.loads(raw)
    if data['fixture_version'] != 1 or data['kind'] != 'compiled-product-fixtures':
        raise ValueError('unsupported compiled fixture catalog')
    sources = data['sources']
    paths = [source['path'] for source in sources]
    if len(paths) != len(set(paths)) or set(paths) != set(required_sources):
        raise ValueError('catalog must cover exactly the manifest fixture sources')
    for source in sources:
        actual = sha256((root / source['path']).read_bytes()).hexdigest()
        if actual != source['sha256']:
            raise ValueError(f'fixture source changed: {source["path"]}')
    return {'sha256': sha256(raw).hexdigest(), 'sources': sources}


def checkout_identity(root):
    """Bind tracked changes and untracked product sources, without copying them."""
    def git(*args):
        try:
            return subprocess.check_output(['git', *args], cwd=root, stderr=subprocess.PIPE)
        except (OSError, subprocess.CalledProcessError) as error:
            raise ValueError('cannot read checkout source identity') from error

    # diff deliberately trusts these index flags, so it cannot identify the
    # working bytes beneath them. Reject, without changing the owner's index.
    entries = git('ls-files', '-v', '-z').split(b'\0')
    if any(entry[:1].islower() or entry.startswith(b'S ') for entry in entries):
        raise ValueError('checkout contains assume-unchanged or skip-worktree entries')
    head = git('rev-parse', 'HEAD').decode('ascii').strip()
    changes = git('-c', 'core.filemode=true', 'diff', '--binary', '--full-index',
                  '--no-ext-diff', '--no-textconv', '--no-renames', 'HEAD', '--')
    roots = ['app', 'packages', 'runtime']
    paths = sorted(name for name in git('ls-files', '--others', '--exclude-standard', '-z',
                                        '--', *roots).decode('utf-8').split('\0') if name)
    untracked = sha256()
    for name in paths:
        untracked.update(name.encode('utf-8') + b'\0')
        untracked.update(sha256((root / name).read_bytes()).digest())
    return {'head': head, 'tracked_diff_sha256': sha256(changes).hexdigest(),
            'untracked_roots': roots, 'untracked_count': len(paths),
            'untracked_sha256': untracked.hexdigest()}


def report_name(key):
    return 'engine.xml' if key == 'engine' else f'{key}.jsonl'


def report_bytes(folder, suites):
    return {key: (folder / report_name(key)).read_bytes()
            if (folder / report_name(key)).is_file() else None for key in suites}


def report_hashes(raw_reports):
    return {report_name(key): sha256(raw).hexdigest() if raw is not None else None
            for key, raw in raw_reports.items()}


def collect(data, reports, run_id, fixture_issue=None, fixture_sha256=None):
    rows = []
    for case in data['cases']:
        checks = []
        guard_results = []
        suites = {check['suite'] for check in case['checks']}
        for suite in sorted(suites):
            for name in data['suites'][suite]['guards']:
                status, reason = ('NOT_RUN', fixture_issue) if fixture_issue else reports[suite].check(name)
                guard_results.append(status)
                checks.append({'id': f'{suite}:{name}', 'status': status, 'reason': reason,
                               'suite': suite, 'test_name': name, 'guard': True})
        for check in case['checks']:
            status, reason = ('NOT_RUN', fixture_issue) if fixture_issue else reports[check['suite']].check(check['name'])
            checks.append({'id': check['id'], 'status': status, 'reason': reason,
                           'suite': check['suite'], 'test_name': check['name'],
                           'source_file': check.get('file'), 'scope': check.get('scope')})
        checks.extend({'id': gap['id'], 'status': 'NOT_RUN', 'reason': gap['reason']}
                      for gap in case.get('required_gaps', []))
        # The Dart guard does not run inside the engine process. Its required
        # synthetic-peer observations must also finish before asserting zero.
        guarded = bool(guard_results) and all(status == 'PASS' for status in guard_results) and all(
            check['status'] == 'PASS' for check in checks if check.get('suite') == 'engine')
        rows.append({
            'run_id': run_id, 'case_id': f'r2-{case["id"]:02d}', 'original_ids': case['original_ids'],
            'variant': 'product-offline', 'mode': 'offline', 'ruleset': data['ruleset'],
            'fixture_version': data['fixture_version'], 'status': aggregate(c['status'] for c in checks),
            'fixture_catalog_sha256': fixture_sha256,
            'checks': checks, 'evidence_refs': [f'{suite}.xml' if suite == 'engine' else f'{suite}.jsonl'
                                               for suite in sorted(suites)],
            'limits': case.get('limits', []),
            'usage': {'requests': 0 if guarded else None, 'charged_amount': None,
                      'source': 'real provider calls; synthetic HTTP exchanges are not provider calls or a bill'},
            'model_quality': None, 'participant_feedback': None,
        })
    return rows


def unique_test_counts(rows):
    # Several acceptance groups can cite one physical test. Count it once.
    tests = {(check['suite'], check['test_name']): check['status']
             for row in rows for check in row['checks'] if 'test_name' in check}
    return dict(Counter(tests.values()))


def windows_command(command, environment, comspec=None):
    """Assemble one launch; CRT quoting is only for a direct executable."""
    child = environment.copy()
    if Path(command[0]).suffix.lower() in ('.bat', '.cmd'):
        if not comspec:
            raise OSError('COMSPEC is missing or cannot be resolved')
        if any(char in value for value in [comspec, *command] for char in ('"', '\r', '\n', '\0')):
            raise ValueError('bat/cmd arguments containing a double quote, CR, LF or NUL are not representable')
        child['DSH_REPLAY_EXE'] = command[0]
        variables = ['DSH_REPLAY_EXE']
        for index, value in enumerate(command[1:]):
            variable = f'DSH_REPLAY_ARG_{index}'
            child[variable] = value
            variables.append(variable)
        prefix = f'"{comspec}" /d /v:off /s /c "'
        raw = prefix + ' '.join(f'"%{variable}%"' for variable in variables) + '"'
        # Substitute this launch's values once, without rescanning literal %.
        expanded = prefix + ' '.join(f'"{value}"' for value in command) + '"'
        units = [len(value.encode('utf-16-le')) // 2 + 1 for value in (raw, expanded)]
        return {'args': raw, 'options': {'executable': comspec, 'shell': False, 'env': child},
                'units': units, 'limit': 8191}
    units = len(subprocess.list2cmdline(command).encode('utf-16-le')) // 2 + 1
    return {'args': command, 'options': {'shell': False, 'env': child}, 'units': [units], 'limit': 32767}


def windows_batches(key, suite, cases, folder, executable, environment, comspec=None):
    groups = {}
    seen = set(suite['guards'])
    for case in cases:
        for check in case['checks']:
            if check['suite'] == key and check['name'] not in seen:
                seen.add(check['name'])
                groups.setdefault(check.get('file'), []).append(check['name'])
    batches = []

    def assemble(names):
        identifier = len(batches) + 1
        report = folder / f'{identifier}.jsonl'
        selected = sorted(set(suite['guards']).union(names))
        command = [executable, *suite['command'][1:], '--name',
                   '^(?:' + '|'.join(re.escape(name) for name in selected) + ')$',
                   '--file-reporter', f'json:{report}']
        launch = windows_command(command, environment, comspec)
        return {'id': identifier, 'names': list(names), 'report': report, **launch}

    for group in groups.values() if groups else [[]]:
        whole = assemble(group)
        if max(whole['units']) <= whole['limit']:
            batches.append(whole)
            continue
        pending = []
        for name in group:
            candidate = assemble([*pending, name])
            if max(candidate['units']) > candidate['limit']:
                if pending:
                    batches.append(assemble(pending))
                pending = [name]
                candidate = assemble(pending)
                if max(candidate['units']) > candidate['limit']:
                    raise ValueError(f'one full name plus guards/paths exceeds the Windows command limit: '
                                     f'{candidate["units"]} UTF-16 units, limit {candidate["limit"]}')
            else:
                pending.append(name)
        if pending:
            batches.append(assemble(pending))
        elif not group:
            raise ValueError(f'guards/paths exceed the Windows command limit: '
                             f'{whole["units"]} UTF-16 units, limit {whole["limit"]}')
    return batches


def run_windows_suite(root, key, suite, cases, output, log):
    environment = os.environ.copy()
    executable = shutil.which(suite['command'][0])
    if executable is None:
        raise OSError(f'command not found on PATH/PATHEXT: {suite["command"][0]}')
    executable = os.path.abspath(executable)
    comspec = None
    if Path(executable).suffix.lower() in ('.bat', '.cmd'):
        requested = environment.get('COMSPEC')
        comspec = shutil.which(requested) if requested else None
        if comspec is None:
            raise OSError('COMSPEC is missing or cannot be resolved')
        comspec = os.path.abspath(comspec)
    folder = Path(tempfile.mkdtemp(prefix=f'{key}-replay-'))
    try:
        # Resolve the actual temporary paths before measuring any command.
        batches = windows_batches(key, suite, cases, folder, executable, environment, comspec)
        codes = []
        with (output / f'{key}.jsonl').open('w', encoding='utf-8', newline='\n') as canonical:
            def emit(event):
                canonical.write(json.dumps(event, ensure_ascii=False) + '\n')
                canonical.flush()

            emit({'type': 'replayBatchPlan', 'version': 1, 'suite': key, 'guards': suite['guards'],
                  'batches': [{'id': batch['id'], 'names': batch['names']} for batch in batches]})
            log.write(f'Windows executable: {executable}; COMSPEC: {comspec}\n')
            for batch in batches:
                log.write(f'--- batch {batch["id"]}: {len(batch["names"])} ordinary names; '
                          f'command UTF-16 units {batch["units"]}/{batch["limit"]} ---\n')
                log.flush()
                try:
                    code = subprocess.run(batch['args'], cwd=root / suite['cwd'], stdout=log,
                                          stderr=subprocess.STDOUT, check=False, **batch['options']).returncode
                except (OSError, ValueError) as error:
                    code = None
                    log.write(f'NOT_RUN: {error}\n')
                codes.append(code)
                try:
                    raw = batch['report'].read_bytes()
                except OSError as error:
                    raw = None
                    log.write(f'NOT_RUN: batch reporter unavailable: {error}\n')
                emit({'type': 'replayBatchResult', 'id': batch['id'], 'exit_code': code,
                      'report_base64': base64.b64encode(raw).decode('ascii') if raw is not None else None})
            emit({'type': 'replayBatchesDone'})
        return batch_exit(codes)
    finally:
        try:
            shutil.rmtree(folder)
        except OSError as error:
            log.write(f'Could not clean up {folder}: {error}\n')


def run_suites(root, data, output, engine_report=None):
    exits = {}
    for key, suite in data['suites'].items():
        if key == 'engine':
            target = output / 'engine.xml'
            if engine_report is not None:
                if engine_report != target:
                    target.unlink(missing_ok=True)
                    if engine_report.is_file():
                        target.write_bytes(engine_report.read_bytes())
                exits[key] = None
            else:
                with target.open('w', encoding='utf-8') as report, (output / 'engine.log').open('w', encoding='utf-8') as log:
                    try:
                        exits[key] = subprocess.run(suite['command'], cwd=root, stdout=report,
                            stderr=log, check=False).returncode
                    except OSError as error:
                        exits[key] = None
                        log.write(f'NOT_RUN: {error}\n')
            continue
        # A failed new launch must never reuse a previous run's green report.
        (output / f'{key}.jsonl').unlink(missing_ok=True)
        names = set(suite['guards'])
        names.update(check['name'] for case in data['cases'] for check in case['checks']
                     if check['suite'] == key)
        command = [*suite['command'], '--name', '^(?:' + '|'.join(re.escape(n) for n in sorted(names)) + ')$',
                   '--file-reporter', f'json:{output / (key + ".jsonl")}']
        with (output / f'{key}.log').open('w', encoding='utf-8') as log:
            package = root / suite['cwd'] / '.dart_tool'
            if any(not (package / name).is_file() for name in ('package_config.json', 'package_graph.json')):
                exits[key] = None
                log.write('NOT_RUN: resolve dependencies explicitly before offline replay; implicit pub is disabled here\n')
                continue
            if os.name == 'nt' and key in ('sdk', 'app'):
                try:
                    exits[key] = run_windows_suite(root, key, suite, data['cases'], output, log)
                except (OSError, ValueError) as error:
                    exits[key] = None
                    log.write(f'NOT_RUN: {error}\n')
                continue
            try:
                exits[key] = subprocess.run(command, cwd=root / suite['cwd'], stdout=log,
                                             stderr=subprocess.STDOUT, check=False).returncode
            except OSError as error:
                exits[key] = None
                log.write(f'NOT_RUN: {error}\n')
    return exits


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=['offline'], default='offline')
    parser.add_argument('--cases', type=Path, default=Path(__file__).with_name('memory-replay-cases.json'))
    parser.add_argument('--model-fixtures', type=Path,
                        default=Path(__file__).with_name('memory-model-fixtures.json'),
                        help='versioned catalog of compiled synthetic fixture sources; verify before launch')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--reports', type=Path, help='collect existing sdk.jsonl/app.jsonl/engine.xml; do not run tests')
    parser.add_argument('--engine-report', type=Path, help='use the actual runtime CI engine XML; run SDK/App here')
    args = parser.parse_args()
    output = args.output.resolve()
    in_place_collection = args.reports is not None and args.reports.resolve() == output
    output.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc).isoformat()

    def reject_collection(issue):
        # A rejected collection has not acquired the destination for writing.
        # Report this attempt on stdout; retain every original evidence byte.
        summary = {'run_id': now, 'mode': 'offline', 'case_counts': {'NOT_RUN': 15},
                   'execution_status': 'NOT_RUN', 'acceptance_status': 'NOT_RUN',
                   'fixture_issue': issue, 'reports_considered': False,
                   'collection_only': True, 'output_preserved': True}
        print(json.dumps(summary, ensure_ascii=False))
        return 2

    try:
        data = read_cases(args.cases)
        manifest_sha256 = sha256(args.cases.read_bytes()).hexdigest()
    except (OSError, ValueError, KeyError, TypeError) as error:
        issue = f'case manifest not verified: {error}'
        if in_place_collection:
            return reject_collection(issue)
        for name in ('summary.json', 'results.jsonl', 'run-inputs.json'):
            (output / name).unlink(missing_ok=True)
        if not args.reports:
            for name in ('sdk.jsonl', 'app.jsonl', 'engine.xml'):
                target = output / name
                if not args.engine_report or target != args.engine_report.resolve():
                    target.unlink(missing_ok=True)
        rows = [{'run_id': now, 'case_id': f'r2-{index:02d}', 'original_ids': [],
                 'mode': 'offline', 'status': 'NOT_RUN', 'checks': [], 'reason': issue,
                 'usage': {'requests': None, 'charged_amount': None}}
                for index in range(1, 16)]
        summary = {'run_id': now, 'mode': 'offline', 'case_counts': {'NOT_RUN': 15},
                   'execution_status': 'NOT_RUN', 'acceptance_status': 'NOT_RUN',
                   'fixture_issue': issue, 'reports_considered': False,
                   'collection_only': bool(args.reports), 'suite_exits': None}
        (output / 'results.jsonl').write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n'
                                                   for row in rows), encoding='utf-8')
        (output / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(json.dumps(summary, ensure_ascii=False))
        return 2
    report_dir = args.reports.resolve() if args.reports else output
    root = Path(__file__).resolve().parents[2]
    fixture_issue = None
    fixtures = None
    inputs = None
    checkout = None
    raw_reports = {}
    exits = None
    try:
        fixtures = read_fixtures(args.model_fixtures, root, data['fixture_sources'])
        checkout = checkout_identity(root)
        if args.reports:
            inputs = json.loads((report_dir / 'run-inputs.json').read_text(encoding='utf-8'))
            # Capture before invalidating the destination, including in-place collection.
            raw_reports = report_bytes(report_dir, data['suites'])
            if not isinstance(inputs.get('run_id'), str):
                raise ValueError('imported reports have no original run identifier')
            exits = inputs.get('suite_exits')
            if inputs.get('execution_complete') is not True or not isinstance(exits, dict) or set(exits) != set(data['suites']):
                raise ValueError('imported reports have no completed original execution record')
            if any(code is not None and type(code) is not int for code in exits.values()):
                raise ValueError('imported reports have invalid original exit codes')
            if inputs['manifest_sha256'] != manifest_sha256 or inputs['fixture_catalog_sha256'] != fixtures['sha256']:
                raise ValueError('imported reports belong to different replay inputs')
            if inputs.get('checkout_identity') != checkout:
                raise ValueError('imported reports belong to different or unrecorded production content')
            if inputs.get('report_sha256') != report_hashes(raw_reports):
                raise ValueError('imported raw report bytes do not match the original execution record')
        else:
            inputs = {'run_id': now, 'mode': 'offline', 'manifest_sha256': manifest_sha256,
                      'fixture_catalog_sha256': fixtures['sha256'],
                      'checkout_identity': checkout,
                      'execution_complete': False,
                      'engine_report': str(args.engine_report) if args.engine_report else 'launched by replay'}
    except (OSError, ValueError, KeyError, TypeError) as error:
        fixture_issue = f'replay inputs not verified: {error}'
    if fixture_issue and in_place_collection:
        return reject_collection(fixture_issue)
    # No old completion may describe partially replaced reports. The original
    # input record and bytes above are retained, and an in-place collection has
    # passed every input check before it may replace its original evidence.
    for name in ('summary.json', 'results.jsonl', 'run-inputs.json'):
        (output / name).unlink(missing_ok=True)
    if fixture_issue:
        if not args.reports:
            for key in data['suites']:
                target = output / report_name(key)
                if args.engine_report and target == args.engine_report.resolve():
                    continue  # This is an explicitly supplied input, not a prior output.
                target.unlink(missing_ok=True)
    else:
        pending = {**inputs, 'execution_complete': False}
        (output / 'run-inputs.json').write_text(json.dumps(pending, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        if not args.reports:
            exits = run_suites(root, data, output, args.engine_report.resolve() if args.engine_report else None)
            try:
                raw_reports = report_bytes(output, data['suites'])
                if checkout_identity(root) != checkout:
                    raise ValueError('production content changed during execution')
            except (OSError, ValueError) as error:
                fixture_issue = f'replay inputs not verified: {error}'
    reports = {key: EngineReport(report_dir / report_name(key), raw_reports.get(key)) if key == 'engine'
               else dart_report(report_dir / report_name(key), raw_reports.get(key), key, data,
                                exits.get(key) if exits else None) for key in data['suites']}
    run_id = inputs['run_id'] if inputs and not fixture_issue else now
    rows = collect(data, reports, run_id, fixture_issue, fixtures['sha256'] if fixtures else None)
    if not fixture_issue:
        for key, raw in raw_reports.items():
            target = output / report_name(key)
            if raw is None:
                target.unlink(missing_ok=True)
            else:
                # Publish exactly the bytes parsed above, never reread a moving source.
                target.write_bytes(raw)
    (output / 'results.jsonl').write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows),
                                        encoding='utf-8')
    counts = dict(Counter(row['status'] for row in rows))
    execution_results = [row['status'] for row in rows]
    if exits and any(code not in (0, None) for code in exits.values()):
        execution_results.append('FAIL')
    if not fixture_issue:
        execution_results.extend('FAIL' if report.success is False else 'NOT_RUN'
                                 for report in reports.values() if report.success is not True)
    execution_status = aggregate(execution_results)
    summary = {'run_id': run_id, 'mode': 'offline', 'case_counts': counts,
               'execution_status': execution_status,
               'acceptance_status': aggregate([execution_status,
                    *(['NEEDS_REVIEW'] if data.get('unresolved_requirements') else [])]),
               'check_reference_counts': dict(Counter(check['status'] for row in rows for check in row['checks'])),
               'unique_test_counts': unique_test_counts(rows),
               'required_gap_counts': dict(Counter(check['status'] for row in rows for check in row['checks']
                                                  if 'test_name' not in check)),
               'manifest_sha256': manifest_sha256,
               'checkout_identity': checkout,
               'tested_checkout_identity': inputs.get('checkout_identity') if inputs else None,
               'report_sha256': report_hashes(raw_reports),
               'model_fixtures': fixtures, 'fixture_issue': fixture_issue,
               'collection_only': bool(args.reports), 'collected_at': now,
               'suite_exits': exits, 'report_success': {key: report.success for key, report in reports.items()},
               'reports_considered': not bool(fixture_issue),
               'unresolved_requirements': data.get('unresolved_requirements', []),
               'separate_modes': data.get('separate_modes', []),
               'limits': data['limits']}
    (output / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    if not fixture_issue:
        inputs.update(execution_complete=True, suite_exits=exits,
                      report_sha256=report_hashes(raw_reports))
        temporary = output / '.run-inputs.json.tmp'
        temporary.write_text(json.dumps(inputs, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        temporary.replace(output / 'run-inputs.json')
    print(json.dumps(summary, ensure_ascii=False))
    if execution_status == 'FAIL':
        return 1
    if counts.get('NOT_RUN') or counts.get('NEEDS_REVIEW') or any(report.success is not True for report in reports.values()):
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
