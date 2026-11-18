import datetime
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

H, OUT, EXPECTATION = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
assert EXPECTATION in ['existing', 'guard-only', 'complete']

def sha(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()

def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        assert not path.is_symlink(), str(path)
        if path.is_file(): result[path.relative_to(root).as_posix()] = {'bytes': path.stat().st_size, 'sha256': sha(path)}
    return result

OUT.mkdir()
report = {'status': 'RUNNING', 'startedUtc': utc(), 'expectation': EXPECTATION,
          'scope': 'Real Host-generated argv/profile replay with fixed Node on Linux and explicit OH platform simulation. Functional measurement, not target ABI or performance.',
          'driver': {'path': str(Path(__file__)), 'sha256': sha(Path(__file__))},
          'preparation': str(H), 'actualSource': None, 'commands': []}
save(OUT / 'report.json', report)
try:
    binding_path = H / 'source-binding.json'
    binding = json.loads(binding_path.read_text())
    report['binding'] = {'path': str(binding_path), 'sha256': sha(binding_path)}
    for row in binding['files']:
        path = Path(row['path'])
        assert path.stat().st_size == row['bytes'] and sha(path) == row['sha256'], str(path)
    prepared = json.loads((H / 'prepare.json').read_text())
    S=Path(prepared['sourceRoot'])
    NODE=Path(prepared['node'])
    NATIVE=Path(prepared['nativeLibraryDirectory'])
    PUBLICATION=Path(prepared['publicationFixture'])
    assert prepared['status'] == 'PREPARED_NOT_RUN'
    report['actualSource'] = prepared['actualSource']
    report['node'] = {'path': prepared['node'], 'sha256': prepared['nodeSha256']}
    runtime = Path(prepared['hostCommand'][1])
    expected = json.loads((H / 'payload-files.json').read_text())
    assert inventory(runtime) == expected
    report['payloadBefore'] = {'path': str(H / 'payload-files.json'), 'sha256': sha(H / 'payload-files.json'), 'files': len(expected)}
    profile = Path(prepared['hostArgv'][7])
    assert sha(profile) == prepared['profileSha256']
    (OUT / 'host-profile.json').write_bytes(profile.read_bytes())
    argv = [str(NODE), str(H / 'round.mjs'), '--prefix', str(runtime), '--out', str(OUT / 'round'),
            '--mode', 'sim', '--platform', '--native-library-dir', str(NATIVE),
            '--linked-publication-fixture', str(PUBLICATION),
            '--compile-cache-dir', prepared['hostEnvironment']['NODE_COMPILE_CACHE'],
            '--model-fixture', str(S / 'runtime/tests/ohos/node-script-model.mjs'), '--add13-expect', EXPECTATION, '--mcp-host', prepared['mcpHost']]
    for name in ['libdsh_flock.so', 'libdsh_require_builtin.so']:
        argv += ['--allow-addon', str(NATIVE / name)]
    env = {'PATH': os.environ['PATH'], 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8', 'TZ': 'UTC'}
    command = {'argv': argv, 'cwd': str(H), 'env': env, 'startedUtc': utc(), 'timeoutSeconds': 120, 'terminationRequests': [], 'timedOut': False}
    save(OUT / 'command.json', command)
    begun = time.monotonic()
    with (OUT / 'stdout.log').open('wb') as stdout, (OUT / 'stderr.log').open('wb') as stderr:
        process = subprocess.Popen(argv, cwd=H, env=env, stdout=stdout, stderr=stderr, start_new_session=True)
        command['pid'] = process.pid; save(OUT / 'command.json', command)
        print(json.dumps({'status': 'STARTED', 'pid': process.pid, 'utc': command['startedUtc'], 'out': str(OUT), 'binding': report['binding']}), flush=True)
        try: code = process.wait(timeout=120)
        except subprocess.TimeoutExpired:
            command['timedOut'] = True
            command['terminationRequests'].append({'signal': 'SIGTERM', 'utc': utc()})
            os.killpg(process.pid, signal.SIGTERM)
            try: code = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                command['terminationRequests'].append({'signal': 'SIGKILL', 'utc': utc()})
                os.killpg(process.pid, signal.SIGKILL); code = process.wait()
    command.update(exitCode=code, endedUtc=utc(), wallSeconds=time.monotonic()-begun)
    save(OUT / 'command.json', command); report['commands'].append(command)
    path = OUT / 'round/report.json'
    report['actual'] = json.loads(path.read_text()) if path.exists() else None
    actual = report['actual']
    after = inventory(runtime); save(OUT / 'payload-after.json', after)
    assert after == expected
    assert sha(profile) == prepared['profileSha256']
    for row in binding['files']:
        path = Path(row['path'])
        assert path.stat().st_size == row['bytes'] and sha(path) == row['sha256'], str(path)
    report.update(payloadUnchanged=True, sourceInputsUnchanged=True, profileUnchanged=True)
    assert code == 0 and not command['timedOut'] and not command['terminationRequests']
    assert actual['status'] == 'PASS' and actual['controlStatus'] == 'PASS_REAL_FIVE_TOOLS_TWO_APPROVALS_WITH_NODE_WORKER'
    assert actual['approvals'] == 2
    assert actual['engineLifecycle']['closeObserved'] is True
    assert actual['engineLifecycle']['exit']['code'] == 0 and actual['engineLifecycle']['exit']['signal'] is None
    assert not any(row['signal'] == 'SIGKILL' for row in actual['engineLifecycle']['requested'])
    if EXPECTATION == 'complete':
        assert actual['add13']['stdioInventory']['fiberPhase'] == 'active'
        assert actual['add13']['stdioEcho']['result']['content'] == [{'type':'text','text':'真实 stdio MCP'}]
        assert actual['add13']['stdioProcessMarkers'] and all(row['worker'] for row in actual['add13']['stdioProcessMarkers'])
    report.update(status=actual['add13']['status'], endedUtc=utc(), engineLifecycle=actual['engineLifecycle'])
    save(OUT / 'report.json', report)
    print(json.dumps({'status': report['status'], 'reportSha256': sha(OUT / 'report.json'), 'exitCode': code,
                      'engineLifecycle': report['engineLifecycle']}), flush=True)
except BaseException as error:
    report.update(status='FAILED', endedUtc=utc(), error={'name':type(error).__name__,'message':str(error)})
    save(OUT / 'report.json', report)
    raise
