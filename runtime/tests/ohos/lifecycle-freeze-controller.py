#!/usr/bin/env python3
"""Real external SIGSTOP/SIGCONT with acknowledged boundaries and wall-time auth."""
import argparse
import http.server
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import threading
import time
import uuid

parser = argparse.ArgumentParser()
for option in ['node', 'prefix', 'linked', 'native-library-dir', 'out']: parser.add_argument('--' + option, required=True)
args = parser.parse_args()
out = Path(args.out).resolve(); out.mkdir(parents=True, exist_ok=True)
runtime = Path(__file__).resolve().parents[2]
env = {**os.environ, 'DSH_LIFECYCLE_TEST_PREFIX': str(Path(args.prefix).resolve()), 'LD_PRELOAD': str(Path(args.linked).resolve()),
       'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony', 'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(Path(args.native_library_dir).resolve()),
       'NARB_DISABLE_NATIVE_CACHE': '1',
       'DSH_GO_OHOS_SIM_ADDONS': json.dumps([str(Path(args.native_library_dir).resolve() / name) for name in ['libdsh_flock.so', 'libdsh_require_builtin.so']])}
command = [args.node, '--jitless', '--import', str(runtime / 'ohos/sim/preload.mjs'), str(Path(__file__).with_name('lifecycle-freeze-actor.mjs'))]
results = []
def run_case(mode, logical, tool):
    name = f'{tool}-{mode}-' + ('acknowledged' if logical else 'unannounced')
    root = out / name; root.mkdir()
    release = threading.Event(); requests = []; token = uuid.uuid4().hex; expiry = [None]
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def body(self, status, value):
            self.send_response(status); self.send_header('content-length', str(len(value))); self.end_headers(); self.wfile.write(value)
        def do_GET(self):
            assert self.path == '/issue'; expiry[0] = time.time() + 0.7
            self.body(200, json.dumps({'token': token, 'expiresAt': expiry[0] * 1000}).encode())
        def do_POST(self):
            self.rfile.read(int(self.headers.get('content-length', '0')))
            valid = self.headers.get('authorization') == 'Bearer ' + token and time.time() < expiry[0]
            requests.append({'path': self.path, 'valid': valid, 'port': self.client_address[1]})
            if not valid: self.body(401, b'expired'); return
            if self.path == '/hold':
                self.send_response(200); self.send_header('content-length', '10'); self.end_headers()
                self.wfile.write(b'first-'); self.wfile.flush(); release.wait(20); self.wfile.write(b'last')
            else: self.body(200, b'accepted')
        def log_message(self, *unused): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    config = {'root': str(root), 'mode': mode, 'logical': logical, 'tool': tool,
              'server': f'http://127.0.0.1:{server.server_port}', 'reportPath': str(root / 'report.json')}
    config_path = root / 'config.json'; config_path.write_text(json.dumps(config, indent=2) + '\n')
    err = (root / 'stderr.log').open('wb'); transcript = (root / 'stdout.log').open('w')
    proc = subprocess.Popen(command + [str(config_path)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, bufsize=0)
    buffered = b''
    def stage(expected):
        nonlocal buffered
        timeout = time.monotonic() + 20
        select = selectors.DefaultSelector(); select.register(proc.stdout, selectors.EVENT_READ)
        try:
            while time.monotonic() < timeout:
                if b'\n' not in buffered:
                    if not select.select(0.25): continue
                    chunk = os.read(proc.stdout.fileno(), 65536)
                    assert chunk, f'actor ended before {expected}'
                    buffered += chunk; continue
                line, buffered = buffered.split(b'\n', 1)
                transcript.write(line.decode() + '\n'); transcript.flush()
                value = json.loads(line)
                if value.get('stage') == expected: return value
            raise AssertionError('handshake timeout: ' + expected)
        finally: select.close()
    def send(value): proc.stdin.write((value + '\n').encode()); proc.stdin.flush()
    try:
        ready = stage('ready')
        # procfs can belong to an outer PID namespace. Signals still use our
        # Popen PID; observe only the identity reported by this exact child.
        assert ready['pid'] == proc.pid
        assert isinstance(ready['procfsPid'], int) and ready['procfsPid'] > 0
        procfs = Path('/proc') / str(ready['procfsPid'])
        fields = dict(line.split(':', 1) for line in (procfs / 'status').read_text().splitlines() if ':' in line)
        assert int(fields['Pid']) == ready['procfsPid']
        assert int(fields['PPid']) == int(os.readlink('/proc/self'))
        assert int(fields['NSpid'].split()[-1]) == proc.pid
        assert os.readlink(procfs / 'ns/pid') == os.readlink('/proc/self/ns/pid')
        def starttime(): return (procfs / 'stat').read_text().rsplit(')', 1)[1].split()[19]
        started = starttime()
        acknowledged = None
        if logical: send('pause'); acknowledged = stage('paused'); assert acknowledged['status']['confirmedPause']
        os.kill(proc.pid, signal.SIGSTOP)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            assert starttime() == started, 'the observed process identity changed'
            state = next(line for line in (procfs / 'status').read_text().splitlines() if line.startswith('State:'))
            if '\tT ' in state: break
            time.sleep(0.002)
        else: raise AssertionError('kernel did not acknowledge stopped state')
        stopped = time.monotonic(); release.set()
        # This wait measures an intentionally controlled stop after /proc T;
        # it is not used by the product to infer an unannounced freeze.
        time.sleep((ready['budget'] + 500) / 1000)
        os.kill(proc.pid, signal.SIGCONT)
        frozen_ms = (time.monotonic() - stopped) * 1000
        send('resume'); resumed = stage('resumed'); send('release'); stage('done')
        assert proc.wait(timeout=15) == 0
        report = json.loads((root / 'report.json').read_text())
        assert report['strict'] and report['effects'] == 'once\n'
        assert report['inFlightBody'] == 'first-last'
        assert report['authenticationAfterFreeze'] == 401
        assert requests == [{'path': '/hold', 'valid': True, 'port': requests[0]['port']}, {'path': '/write', 'valid': False, 'port': requests[1]['port']}]
        assert requests[0]['port'] != requests[1]['port'], 'new request reused the retired connection'
        assert report['forbiddenMarker'] is False
        final = next(event for event in report['events'] if event['type'] == 'tool/result')
        if tool == 'tool':
            expected_success = mode == 'current' and logical
            assert report['completedMarker'] == expected_success
            if expected_success:
                assert final['data']['message']['isError'] is False
                assert final['data']['message']['content'][0]['text'] == 'completed once'
            else: assert final['data']['error']['code'] == 'TOOL_TIMEOUT'
        else:
            expected_timeout = mode != 'current' or not logical
            assert report['shellResult']['timedOut'] == expected_timeout
            assert report['shellResult']['aborted'] == (not expected_timeout)
            assert report['liveAfterCancel'] == 0
        result = {'name': name, 'status': 'PASS_SCOPED', 'ready': ready, 'acknowledged': acknowledged,
                  'resumed': resumed, 'frozenMsMeasuredExternally': frozen_ms, 'requests': requests, 'report': str(root / 'report.json'),
                  'observedProcess': {'signalPid': proc.pid, 'procfsPid': ready['procfsPid'], 'starttime': started, 'kernelState': state}}
        if mode == 'baseline': result['expectedOriginalFailure'] = 'old deadline expires during acknowledged logical pause'
        results.append(result)
    finally:
        release.set()
        if proc.poll() is None:
            os.kill(proc.pid, signal.SIGCONT); proc.kill(); proc.wait(timeout=10)
        transcript.write((buffered + proc.stdout.read()).decode()); transcript.close(); err.close()
        server.shutdown(); server.server_close()

for tool in ['tool', 'bash']:
    run_case('baseline', True, tool)
    run_case('current', True, tool)
    run_case('current', False, tool)
(out / 'report.json').write_text(json.dumps({'status': 'PASS_SCOPED', 'scope': 'real Linux SIGSTOP/SIGCONT, actual pinned engine/worker and local HTTP; not OH device',
    'command': command, 'results': results}, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'status': 'PASS_SCOPED', 'cases': len(results), 'report': str(out / 'report.json')}))
