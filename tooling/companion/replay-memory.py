#!/usr/bin/env python3
"""09g offline results from the product tests; no model client or rule clone."""
import argparse
from collections import Counter
from datetime import datetime, timezone
from hashlib import sha256
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET


STATUSES = ('FAIL', 'NOT_RUN', 'NEEDS_REVIEW', 'PASS', 'NOT_APPLICABLE')


def aggregate(values):
    values = set(values)
    return next((status for status in STATUSES if status in values), 'NOT_APPLICABLE')


class Report:
    """Read the whole JSON stream: an error may arrive after testDone."""

    def __init__(self, path):
        self.path = path
        self.tests = {}
        self.complete = False
        self.success = None
        self.issue = None
        if not path.is_file():
            self.issue = 'report missing'
            return
        try:
            for line in path.read_text(encoding='utf-8').splitlines():
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
                    self.complete = event['success'] is not None
                    self.success = event['success']
        except (ValueError, KeyError, TypeError) as error:
            self.complete = False
            self.issue = f'incomplete reporter stream: {error}'

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


class EngineReport:
    """Node's real pinned-engine tests, with skipped cases kept as NOT_RUN."""

    def __init__(self, path):
        self.path = path
        self.cases = []
        self.success = None
        self.issue = 'engine report missing'
        if not path.is_file():
            return
        try:
            self.cases = list(ET.parse(path).getroot().iter('testcase'))
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
    output.mkdir(parents=True, exist_ok=True)
    # Even a rejected input is a new attempt, never the old green summary.
    for name in ('summary.json', 'results.jsonl'):
        (output / name).unlink(missing_ok=True)
    now = datetime.now(timezone.utc).isoformat()
    try:
        data = read_cases(args.cases)
        manifest_sha256 = sha256(args.cases.read_bytes()).hexdigest()
    except (OSError, ValueError, KeyError, TypeError) as error:
        issue = f'case manifest not verified: {error}'
        if not args.reports:
            for name in ('run-inputs.json', 'sdk.jsonl', 'app.jsonl', 'engine.xml'):
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
    try:
        fixtures = read_fixtures(args.model_fixtures, root, data['fixture_sources'])
        if args.reports:
            inputs = json.loads((report_dir / 'run-inputs.json').read_text(encoding='utf-8'))
            if inputs['manifest_sha256'] != manifest_sha256 or inputs['fixture_catalog_sha256'] != fixtures['sha256']:
                raise ValueError('imported reports belong to different replay inputs')
            if not isinstance(inputs.get('run_id'), str):
                raise ValueError('imported reports have no original run identifier')
            exits = inputs.get('suite_exits')
            if inputs.get('execution_complete') is not True or not isinstance(exits, dict) or set(exits) != set(data['suites']):
                raise ValueError('imported reports have no completed original execution record')
            if any(code is not None and type(code) is not int for code in exits.values()):
                raise ValueError('imported reports have invalid original exit codes')
        else:
            inputs = {'run_id': now, 'mode': 'offline', 'manifest_sha256': manifest_sha256,
                      'fixture_catalog_sha256': fixtures['sha256'],
                      'execution_complete': False,
                      'engine_report': str(args.engine_report) if args.engine_report else 'launched by replay'}
        (output / 'run-inputs.json').write_text(json.dumps(inputs, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    except (OSError, ValueError, KeyError, TypeError) as error:
        fixture_issue = f'compiled fixture catalog not verified: {error}'
        if not args.reports:
            (output / 'run-inputs.json').unlink(missing_ok=True)
            for key in data['suites']:
                target = output / ('engine.xml' if key == 'engine' else f'{key}.jsonl')
                if args.engine_report and target == args.engine_report.resolve():
                    continue  # This is an explicitly supplied input, not a prior output.
                target.unlink(missing_ok=True)
    exits = None
    if not fixture_issue:
        if args.reports:
            exits = inputs['suite_exits']
        else:
            exits = run_suites(root, data, output, args.engine_report.resolve() if args.engine_report else None)
            inputs.update(execution_complete=True, suite_exits=exits)
            (output / 'run-inputs.json').write_text(json.dumps(inputs, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    reports = {key: EngineReport(report_dir / 'engine.xml') if key == 'engine'
               else Report(report_dir / f'{key}.jsonl') for key in data['suites']}
    run_id = inputs['run_id'] if inputs and not fixture_issue else now
    rows = collect(data, reports, run_id, fixture_issue, fixtures['sha256'] if fixtures else None)
    if args.reports and not fixture_issue:
        for key, report in reports.items():
            target = output / report.path.name
            if report.path != target:
                target.unlink(missing_ok=True)
                if report.path.is_file():
                    target.write_bytes(report.path.read_bytes())
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
               'model_fixtures': fixtures, 'fixture_issue': fixture_issue,
               'collection_only': bool(args.reports), 'collected_at': now,
               'suite_exits': exits, 'report_success': {key: report.success for key, report in reports.items()},
               'reports_considered': not bool(fixture_issue),
               'unresolved_requirements': data.get('unresolved_requirements', []),
               'separate_modes': data.get('separate_modes', []),
               'limits': data['limits']}
    (output / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(summary, ensure_ascii=False))
    if execution_status == 'FAIL':
        return 1
    if counts.get('NOT_RUN') or counts.get('NEEDS_REVIEW') or any(report.success is not True for report in reports.values()):
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
