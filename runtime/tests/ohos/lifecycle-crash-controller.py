#!/usr/bin/env python3
"""External POSIX process controller; engine actors retain every O0 restriction."""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import selectors
import signal
import shutil
import subprocess
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--node', required=True)
parser.add_argument('--prefix', required=True)
parser.add_argument('--linked', required=True)
parser.add_argument('--baseline-source', required=True)
parser.add_argument('--native-library-dir', required=True)
parser.add_argument('--out', required=True)
args = parser.parse_args()
tree = Path(__file__).resolve().parents[2]
out = Path(args.out).resolve(); out.mkdir(parents=True, exist_ok=True)
counter = {}
counter_lock = threading.Lock()
class Counter(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        label = self.rfile.read(int(self.headers['content-length'])).decode()
        with counter_lock:
            counter.setdefault(self.path, []).append(label)
        self.send_response(200); self.end_headers(); self.wfile.write(b'counted')
    def log_message(self, *unused): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Counter)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = {**os.environ, 'DSH_LIFECYCLE_TEST_PREFIX': str(Path(args.prefix).resolve()),
       'LD_PRELOAD': str(Path(args.linked).resolve()), 'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony',
       'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(Path(args.native_library_dir).resolve()), 'NARB_DISABLE_NATIVE_CACHE': '1',
       'DSH_GO_OHOS_SIM_ADDONS': json.dumps([str(Path(args.native_library_dir).resolve() / name) for name in ['libdsh_flock.so', 'libdsh_require_builtin.so']])}
command = [args.node, '--jitless', '--import', str(tree / 'ohos/sim/preload.mjs'), str(Path(__file__).with_name('lifecycle-crash-actor.mjs'))]
processes = []
transcripts = {}
buffers = {}
def launch(config, label):
    config_path = out / (label + '.config.json'); config_path.write_text(json.dumps(config, indent=2) + '\n')
    err = (out / (label + '.stderr.log')).open('wb')
    proc = subprocess.Popen(command + [str(config_path)], env=env, stdout=subprocess.PIPE, stderr=err, bufsize=0)
    processes.append((proc, err)); transcripts[proc.pid] = (out / (label + '.stdout.log')).open('w')
    buffers[proc.pid] = b''
    return proc
def stage(proc, expected):
    deadline = time.monotonic() + 40
    selector = selectors.DefaultSelector(); selector.register(proc.stdout, selectors.EVENT_READ)
    try:
        while time.monotonic() < deadline:
            if b'\n' not in buffers[proc.pid]:
                if not selector.select(min(0.5, max(0, deadline - time.monotonic()))): continue
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk: raise AssertionError(f'actor exited before {expected}: {proc.poll()}')
                buffers[proc.pid] += chunk
                continue
            line, buffers[proc.pid] = buffers[proc.pid].split(b'\n', 1)
            line = (line + b'\n').decode()
            transcripts[proc.pid].write(line); transcripts[proc.pid].flush()
            try: value = json.loads(line)
            except json.JSONDecodeError: continue
            if value.get('stage') == expected: return value
        raise AssertionError(f'handshake timeout: {expected}')
    finally: selector.close()
def finish(proc, expected=0):
    status = proc.wait(timeout=20)
    transcripts[proc.pid].write((buffers[proc.pid] + proc.stdout.read()).decode())
    buffers[proc.pid] = b''
    transcripts[proc.pid].flush()
    assert status == expected, (proc.pid, status, expected)
def run_case(name, target, *, baseline=False, scenario='single', damage=None, original_first=False, recovery_kill=False):
    root = out / name; root.mkdir()
    config = {'root': str(root), 'mode': 'run', 'scenario': scenario, 'stopAt': target,
              'baseline': baseline, 'baselineSource': str(Path(args.baseline_source).resolve()),
              'counterUrl': f'http://127.0.0.1:{server.server_port}/{name}'}
    proc = launch(config, name + '-run'); reached = stage(proc, target)
    os.kill(proc.pid, signal.SIGKILL); finish(proc, -signal.SIGKILL)
    count_before = list(counter.get('/' + name, []))
    if damage == 'missing-result':
        records = [json.loads(line) for line in (root / 'boundary/boundary.jsonl').read_text().splitlines()]
        saved = next(row['body']['result'] for row in records if row['body']['kind'] == 'outcome')
        (root / 'boundary' / saved['path']).unlink()
    if damage == 'tail':
        path = root / 'boundary/boundary.jsonl'; data = path.read_bytes(); path.write_bytes(data[:-7])
        config['damagedSha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    if damage == 'spill-files-missing':
        spill_files = sorted((root / 'spills').rglob('*.txt'))
        assert spill_files, 'actual spill consumer did not write a file'
        config['removedSpillHashes'] = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in spill_files}
        shutil.rmtree(root / 'spills')
    recoveries = []
    if original_first:
        original = {**config, 'mode': 'original-recovery', 'stopAt': '', 'baseline': False,
                    'reportPath': str(out / (name + '-original.json'))}
        proc = launch(original, name + '-original'); stage(proc, 'recovered'); finish(proc)
    if recovery_kill:
        interrupted = {**config, 'mode': 'recover', 'stopAt': 'recovered-flushed', 'baseline': False,
                       'reportPath': str(out / (name + '-partial.json'))}
        proc = launch(interrupted, name + '-partial'); stage(proc, 'recovered-flushed')
        os.kill(proc.pid, signal.SIGKILL); finish(proc, -signal.SIGKILL)
    for index in range(2 if damage != 'tail' else 1):
        report_path = out / f'{name}-recovery-{index}.json'
        recovery = {**config, 'mode': 'recover', 'stopAt': '', 'baseline': False, 'reportPath': str(report_path),
                    'independentSession': f'independent-{index}' if name == 'dispatched-effect-unknown' else None}
        proc = launch(recovery, f'{name}-recovery-{index}')
        if damage == 'tail': finish(proc, 1)
        else: stage(proc, 'recovered'); finish(proc)
        recoveries.append(json.loads(report_path.read_text()))
    assert counter.get('/' + name, []) == count_before, 'recovery replayed an HTTP side effect'
    local_effects = (root / 'workspace/effects.txt').read_text().splitlines() if (root / 'workspace/effects.txt').exists() else []
    assert local_effects == count_before
    return {'name': name, 'handshake': reached, 'count': count_before, 'recoveries': recoveries,
            'localEffects': local_effects, 'noReplay': True}

results = []
try:
    # This control demonstrably loses a completed result in the original engine.
    baseline = run_case('baseline-outcome-gap', 'outcome', baseline=True)
    assert baseline['count'] == ['A']
    assert baseline['recoveries'][0]['status']['state'] == 'result-unknown'
    assert baseline['recoveries'][0]['events'][4]['data']['error']['code'] == 'TOOL_OUTCOME_UNKNOWN'
    baseline['expectedOriginalFailure'] = 'completed final result unavailable after crash'
    results.append(baseline)
    for name, kwargs in [
        ('outcome-recovered', {'target': 'outcome'}),
        ('dispatched-effect-unknown', {'target': 'effect'}),
        ('prepared-proves-not-dispatched', {'target': 'prepared'}),
        ('parallel-returned-not-final', {'target': 'returned:B', 'scenario': 'parallel'}),
        ('outcome-file-missing', {'target': 'outcome', 'damage': 'missing-result'}),
        ('outcome-tail-corrupt', {'target': 'outcome', 'damage': 'tail'}),
        ('existing-unknown-preserved', {'target': 'outcome', 'original_first': True}),
        ('recovery-flushed-before-commit', {'target': 'outcome', 'recovery_kill': True}),
        ('policy-spill-missing-stays-unknown', {'target': 'outcome', 'scenario': 'policy-spill', 'damage': 'spill-files-missing'}),
        ('search-spill-missing-stays-unknown', {'target': 'outcome', 'scenario': 'search-spill', 'damage': 'spill-files-missing'}),
        ('deferred-context-stays-unknown', {'target': 'outcome', 'scenario': 'deferred-context'}),
    ]:
        row = run_case(name, **kwargs)
        for recovered in row['recoveries']:
            if name == 'outcome-tail-corrupt':
                assert recovered['error']['code'] == 'ERR_OHOS_LIFECYCLE_BLOCKED'
                assert recovered['status']['state'] == 'result-unknown'
                continue
            results_events = [event for event in recovered['events'] if event['type'] == 'tool/result']
            assert len(results_events) == (2 if 'parallel' in name else 1)
            if name in ('outcome-recovered', 'recovery-flushed-before-commit'):
                assert recovered['status']['state'] == 'completed'
                assert recovered['admission'] == 'allowed'
                assert results_events[0]['data']['message']['content'][0]['text'] == 'durable final A 中文'
                assert recovered['stored'][0]['final'] is True
            elif name == 'prepared-proves-not-dispatched':
                assert row['count'] == []
                assert results_events[0]['data']['error']['code'] == 'TOOL_NOT_STARTED'
                assert recovered['status']['state'] == 'completed'
            else:
                assert recovered['status']['state'] == 'result-unknown'
                assert recovered['admission'] == 'ERR_OHOS_LIFECYCLE_RESULT_UNKNOWN'
                assert all(event['data']['error']['code'] == 'TOOL_OUTCOME_UNKNOWN' for event in results_events)
            if name == 'parallel-returned-not-final':
                assert row['count'] == ['B']
                assert recovered['stored'][0]['final'] is False
                assert recovered['stored'][0]['result']['content'][0]['text'] == 'durable final B 中文'
            if 'spill-missing' in name:
                assert recovered['stored'][0]['resources'] == ['spill-reference']
                assert recovered['stored'][0]['final'] is True
            if name == 'dispatched-effect-unknown':
                assert recovered['independent']['state'] == 'completed'
                assert recovered['independent']['oldSessionState'] == 'result-unknown'
                assert recovered['independent']['effect'] == 'new explicitly requested call'
        if name in ('outcome-recovered', 'recovery-flushed-before-commit') or 'stays-unknown' in name:
            a, b = row['recoveries']
            assert a['events'] == b['events'], 'second recovery rewrote or duplicated the first durable result'
        results.append(row)
    (out / 'report.json').write_text(json.dumps({'status': 'PASS_SCOPED', 'scope': 'real external SIGKILL, pinned DSH scheduler and JSONL, Linux linked flock and HTTP counter; not OH device',
        'command': command, 'results': results}, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'status': 'PASS_SCOPED', 'cases': len(results), 'report': str(out / 'report.json')}))
finally:
    for proc, err in processes:
        if proc.poll() is None: proc.kill(); proc.wait(timeout=10)
        transcripts[proc.pid].close(); err.close()
    server.shutdown(); server.server_close()
