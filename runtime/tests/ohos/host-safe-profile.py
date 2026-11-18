#!/usr/bin/env python3
"""Actual Host argv -> rc.1 safe profile -> original public five-tool round.

Linux evidence only. Recording callback is followed by actual fixed Node/DSH;
no second embedded Node or OH Ability restart is simulated as device success.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['node', 'assembled-payload', 'native-library-dir', 'publication-fixture', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    node, runtime, native, publication, out = [getattr(args, name).resolve() for name in
        ['node', 'assembled_payload', 'native_library_dir', 'publication_fixture', 'out']]
    out.mkdir(parents=True, exist_ok=False)
    commands = []
    base_env = {key: os.environ[key] for key in ['PATH', 'LANG', 'LC_ALL'] if key in os.environ}
    base_env['LANG'] = 'C.UTF-8'
    def run(name, argv, env=None, cwd=None, expected=0, timeout=150):
        argv = [str(x) for x in argv]
        began = datetime.datetime.now(datetime.timezone.utc).isoformat()
        start = time.monotonic()
        proc = subprocess.Popen(argv, env=env or base_env, cwd=cwd or ROOT,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        timed_out = False
        signals = []
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGTERM); signals.append('SIGTERM')
            try:
                stdout, stderr = proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL); signals.append('SIGKILL')
                stdout, stderr = proc.communicate()
        (out / (name + '.stdout.log')).write_bytes(stdout)
        (out / (name + '.stderr.log')).write_bytes(stderr)
        commands.append({'name': name, 'argv': argv, 'cwd': str(cwd or ROOT),
            'startedUTC': began, 'endedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'wallSeconds': time.monotonic()-start, 'timeoutSeconds': timeout,
            'exitCode': proc.returncode, 'timedOut': timed_out, 'cleanupSignals': signals,
            'naturalExit': not timed_out and proc.returncode >= 0})
        save(out / 'commands.json', commands)
        assert not timed_out and proc.returncode >= 0, name
        if expected == 'nonzero':
            assert proc.returncode != 0, name
        else:
            assert proc.returncode == expected, name
        return stdout.decode()

    manifest_path = runtime.parent / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    for row in manifest['files']:
        path = runtime / row['path']
        assert path.is_file() and not path.is_symlink()
        assert path.stat().st_size == row['size'] and sha(path) == row['sha256']
    save(out / 'inputs.json', {'manifestSHA256': sha(manifest_path), 'runtimeVersion': manifest['runtimeVersion'],
        'nodeSHA256': sha(node), 'hostSourceSHA256': sha(ROOT / 'app/ohos/entry/src/main/cpp/host_core.cpp'),
        'roundSourceSHA256': sha(ROOT / 'runtime/ohos/sim/round.mjs'),
        'scope': 'Exact composed input; no target-device or performance claim'})
    core = ROOT / 'app/ohos/entry/src/main/cpp'
    driver = out / 'host-profile'
    run('compile-host', [os.environ.get('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra', '-Werror',
        '-I', core, core / 'host_core.cpp', HERE / 'host-profile.cc', '-pthread', '-o', driver], timeout=60)
    guest = out / '中文应用/runtime/rootfs'
    dsh = guest / 'root/.dsh'
    agents = guest / 'root/.agents'
    workspace = guest / 'root/workspace'
    cache = out / 'cache'
    for directory in [dsh, agents, workspace, cache]:
        directory.mkdir(parents=True, exist_ok=True)
    web = dsh / 'profiles/web'
    web.mkdir(parents=True)
    broken = web / 'package.json'
    broken.write_text('{"name":"original-web","private":true,"dsh":{"profile":{"bundles":["dsh-safe-missing-bundle"]}}}\n')
    settings = web / 'cordis.patch.yml'
    settings.write_text('# original malformed user settings remain untouched\n- {id: broken, config: [\n')
    originals = {str(p): sha(p) for p in [broken, settings]}
    normal_path = out / 'normal-argv.json'
    run('normal-host', [driver, runtime, guest, dsh, workspace, cache, native, normal_path], timeout=15)
    normal = json.loads(normal_path.read_text())
    normal_env = json.loads(Path(str(normal_path) + '.env.json').read_text())
    assert len(normal) == 13 and normal[5] == 'web'
    normal_patch = json.loads(Path(normal[7]).read_text())
    assert not any(row.get('id') in ['plugin-manager', 'tool-plugin-manager', 'hmr'] for row in normal_patch)
    run('normal-broken-profile', [node, *normal[1:8], '--dump-config'],
        env={**base_env, **normal_env}, cwd=workspace, expected='nonzero')
    diagnostic = (out / 'normal-broken-profile.stdout.log').read_text() + (out / 'normal-broken-profile.stderr.log').read_text()
    assert 'failed to parse overlay ' + str(settings) in diagnostic, diagnostic
    safe_path = out / 'safe-argv.json'
    run('safe-host', [driver, runtime, guest, dsh, workspace, cache, native, safe_path, 'safe'], timeout=15)
    argv = json.loads(safe_path.read_text())
    captured = json.loads(Path(str(safe_path) + '.env.json').read_text())
    assert argv[5:9] == ['--profile', 'dsh-app-safe', '--from-default-profile', 'web']
    assert captured == normal_env, 'safe changes profile selection, never user home/session paths'
    patch = Path(argv[argv.index('--patch') + 1])
    rows = json.loads(patch.read_text())
    assert any(row.get('id') == 'hmr' and row.get('disabled') is True for row in rows)
    for key in ['plugin-manager', 'tool-plugin-manager']:
        assert not any(row.get('id') == key and row.get('disabled') is True for row in rows)
    text = run('actual-safe-dump', [node, *argv[1:argv.index('--host')], '--dump-config'],
        env={**base_env, **captured}, cwd=workspace)
    for key in ['ohos-subprocess', 'ohos-sandbox', 'ohos-lifecycle', 'ohos-phone', 'ohos-capabilities', 'dsh-go-bridge']:
        assert key in text, key
    assert 'dsh-safe-missing-bundle' not in text
    # Exact original round assertions remain intact. Only its layout, fixed Host
    # argv/env and relative test-support imports are rebound to this private case.
    original_round = ROOT / 'runtime/ohos/sim/round.mjs'
    round_text = original_round.read_text()
    swaps = [
        ("from './fake-model.mjs';", 'from ' + json.dumps((ROOT / 'runtime/ohos/sim/fake-model.mjs').as_uri()) + ';'),
        ("new URL('./preload.mjs', import.meta.url)", 'new URL(' + json.dumps((ROOT / 'runtime/ohos/sim/preload.mjs').as_uri()) + ')'),
        ("new URL('./observe-loader.mjs', import.meta.url)", 'new URL(' + json.dumps((ROOT / 'runtime/ohos/sim/observe-loader.mjs').as_uri()) + ')'),
        ("const workspace = join(out, 'workspace');\nawait mkdir(workspace);", 'const workspace = ' + json.dumps(str(workspace)) + ';'),
        ("await mkdir(join(out, 'home'), { mode: 0o700 });", '// Host supplies the existing private home.'),
        ("if (values.mode !== 'jit') flags.push('--jitless');", '// Already present in the production Host argv.'),
        ("DSH_HOME: join(out, 'home'),", '...' + json.dumps(captured, ensure_ascii=False) + ','),
        ("const args = [...flags, join(prefix, 'node_modules/@deepseek-ai/dsh/lib/bin.js'), 'web'];", 'const args = [...flags, ...' + json.dumps(argv[1:], ensure_ascii=False) + '];'),
        ("for (const name of [...profilePatches, overlay]) args.push('--patch', resolve(name));\nargs.push('--host', '127.0.0.1', '--port', '0', '--no-open');", "args.splice(args.indexOf('--host'), 0, ...[...profilePatches, overlay].flatMap(name => ['--patch', resolve(name)]));"),
        ("const engineClosed = new Promise((resolve) => engine.once('close', resolve));",
         "report.engineLifecycle = {requested: [], closeObserved: false};\nconst engineClosed = new Promise((resolve) => engine.once('close', (code, signal) => { report.engineLifecycle.exit = {code,signal}; report.engineLifecycle.closeObserved=true; resolve(code); }));\nfunction observedStop(signal) {report.engineLifecycle.requested.push(signal); return engine.kill(signal);}"),
        ("ready.reject(new Error('engine diagnostic limit')); engine.kill(); return;",
         "ready.reject(new Error('engine diagnostic limit')); observedStop('SIGTERM'); return;"),
        ("const force = setTimeout(() => engine.kill('SIGKILL'), 5000);\n    engine.kill('SIGTERM'); await engineClosed; clearTimeout(force);",
         "const force = setTimeout(() => observedStop('SIGKILL'), 5000);\n    observedStop('SIGTERM'); await engineClosed; clearTimeout(force);"),
    ]
    for before, after in swaps:
        assert round_text.count(before) == 1, before
        round_text = round_text.replace(before, after)
    round_driver = out / 'safe-round.mjs'
    round_driver.write_text(round_text)
    run('actual-safe-round', [node, round_driver, '--prefix', runtime, '--out', out / 'round', '--mode', 'sim', '--platform',
        '--native-library-dir', native, '--linked-publication-fixture', publication,
        '--allow-addon', native / 'libdsh_flock.so', '--allow-addon', native / 'libdsh_require_builtin.so'])
    report = json.loads((out / 'round/report.json').read_text())
    assert report['status'] == 'PASS' and report['approvals'] == 2
    assert report['engineLifecycle']['closeObserved'] is True
    assert report['engineLifecycle']['exit'] == {'code': 0, 'signal': None}
    assert 'SIGKILL' not in report['engineLifecycle']['requested']
    for name, expected in originals.items():
        assert sha(Path(name)) == expected, 'normal user profile changed: ' + name
    for row in manifest['files']:
        assert sha(runtime / row['path']) == row['sha256'], row['path']
    save(out / 'report.json', {'status': 'PASS_MANUAL_SAFE_PROFILE', 'normalProfileUnchanged': originals,
        'safeArgv': argv, 'roundStatus': report['status'], 'approvals': report['approvals'],
        'scope': 'Actual Linux Host-generated argv and original public round; no Ability restart/device claim'})

if __name__ == '__main__':
    main()
