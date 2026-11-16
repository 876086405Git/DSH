#!/usr/bin/env python3
"""Build HostCore's profile driver and replay its exact layout in actual DSH.

The prefix and dependency cache are read-only inputs. Development mode copies a
private runtime; --assembled-payload uses the exact manifest tree without a copy
or rebuild. Local HTTP/WS is used by the existing strict five-tool test peer.
This is Linux host evidence, not an Ark/SDK/HAP run or a startup benchmark.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import runpy
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            result[name] = {'link': os.readlink(path)}
        elif path.is_file():
            result[name] = {'bytes': path.stat().st_size, 'sha256': sha(path)}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['node', 'native-library-dir', 'publication-fixture', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ['prefix', 'process-dependencies', 'esbuild-prefix', 'assembled-payload', 'model-fixture']:
        parser.add_argument('--' + name, type=Path)
    args = parser.parse_args()
    for name, value in vars(args).items():
        if value is not None:
            setattr(args, name, value.resolve())
    if not args.assembled_payload and not all([args.prefix, args.process_dependencies, args.esbuild_prefix]):
        parser.error('Use --assembled-payload, or all three development prefix/dependency/build inputs')
    out = args.out
    out.mkdir(parents=True, exist_ok=False)
    base_env = {key: os.environ[key] for key in ['PATH', 'LANG', 'LC_ALL'] if key in os.environ}
    base_env['LANG'] = 'C.UTF-8'
    commands = []

    def run(name, command, env=None, cwd=None, timeout=150):
        command = [str(value) for value in command]
        start_utc = datetime.datetime.now(datetime.timezone.utc).isoformat()
        started = time.monotonic()
        process = subprocess.Popen(command, env=env or base_env, cwd=cwd or ROOT,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        timed_out = False
        forced = False
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                stdout, stderr = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                forced = True
                os.killpg(process.pid, signal.SIGKILL)
                stdout, stderr = process.communicate()
        (out / (name + '.stdout.log')).write_text(stdout)
        (out / (name + '.stderr.log')).write_text(stderr)
        commands.append({'name': name, 'command': command, 'cwd': str(cwd or ROOT),
                         'startUTC': start_utc, 'endUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                         'wallSeconds': time.monotonic() - started, 'timeoutSeconds': timeout,
                         'timedOut': timed_out, 'forcedTermination': forced, 'exitCode': process.returncode})
        write_json(out / 'commands.json', commands)
        print(name, process.returncode, flush=True)
        if timed_out:
            raise TimeoutError(name + ' exceeded its existing command budget')
        completed = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        completed.check_returncode()
        return completed

    if args.assembled_payload:
        runtime = args.assembled_payload
        payload_before = inventory(runtime)
        manifest = json.loads((runtime.parent / 'manifest.json').read_text())
        expected = {row['path']: {'bytes': row['size'], 'sha256': row['sha256']} for row in manifest['files']}
        assert payload_before == expected, 'Use the actual exact manifest payload, never a development prefix'
        write_json(out / 'prefix-input.json', payload_before)
    else:
        source_process = ROOT / 'runtime/ohos/process'
        assert sha(source_process / 'package-lock.json') == sha(args.process_dependencies.parent / 'package-lock.json')
        assert sha(source_process / 'package.json') == sha(args.process_dependencies.parent / 'package.json')
        write_json(out / 'prefix-input.json', inventory(args.prefix))
        write_json(out / 'process-dependencies-input.json', inventory(args.process_dependencies))
        runtime = out / 'runtime'
        shutil.copytree(args.prefix, runtime, symlinks=True)
        runtime_ohos = runtime / 'runtime/ohos'
        shutil.copytree(ROOT / 'runtime/ohos', runtime_ohos,
                        ignore=shutil.ignore_patterns('node', 'node_modules', 'build', '__pycache__'))
        bridge = ROOT / 'runtime/bridge/dsh-go-bridge'
        target_bridge = runtime / 'runtime/bridge/dsh-go-bridge'
        target_bridge.mkdir(parents=True, exist_ok=True)
        shutil.copytree(bridge / 'lib', target_bridge / 'lib')
        for name in ['package.json', 'cordis.patch.yml']:
            shutil.copyfile(bridge / name, target_bridge / name)
        process = runtime_ohos / 'process'
        shutil.copytree(args.process_dependencies, process / 'node_modules', symlinks=True)
        inherited = process / 'node_modules/@deepseek-ai'
        if inherited.is_symlink():
            inherited.unlink()
        elif inherited.exists():
            raise AssertionError('Dependency cache unexpectedly owns concrete DSH packages')
        run('link-dsh', [args.node, process / 'link-dsh.mjs', runtime])
        run('build-just-bash', [sys.executable, process / 'build-just-bash.py'])
        run('build-re2js', [args.node, process / 'build-rg-regex.mjs', args.esbuild_prefix])
        # The development copy must exercise the same OH-only variants as the
        # ordinary composer; the shared prefix and repository remain untouched.
        generated_root = out / 'generated-ohos-deletion'
        variants = runpy.run_path(str(ROOT / 'runtime/ohos/package/compose-runtime.py'))['deletion_variants'](
            ROOT, args.prefix, generated_root)
        for row in variants['files']:
            shutil.copyfile(generated_root / row['file'], runtime / row['destination'])
        write_json(out / 'development-deletion-variants.json', variants)

    runtime_modules = {name: {'bytes': (runtime / name).stat().st_size, 'sha256': sha(runtime / name)} for name in [
        'node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/dsh-go-deletion.mjs',
        'runtime/bridge/dsh-go-bridge/lib/session-deletion.js',
        'runtime/ohos/publication/atomic.mjs', 'runtime/ohos/publication/index.mjs']}
    write_json(out / 'runtime-deletion-modules.json', runtime_modules)
    run('bridge-isolated-import', [sys.executable, HERE / 'bridge-isolated-import.py',
        '--node', args.node, '--bridge', runtime / 'runtime/bridge/dsh-go-bridge',
        '--out', out / 'bridge-isolated-import'])

    guest = out / '中文应用目录/runtime/rootfs'
    dsh = guest / 'root/.dsh'
    agents = guest / 'root/.agents'
    workspace = guest / 'root/workspace'
    cache = out / 'cache'
    for directory in [dsh, agents, workspace, cache]:
        directory.mkdir(parents=True)
    for directory, name in [(dsh, 'dsh-home-proof'), (agents, 'agents-home-proof')]:
        skill = directory / 'skills' / name / 'SKILL.md'
        skill.parent.mkdir(parents=True)
        skill.write_text('---\nname: ' + name + '\ndescription: Host layout fixture\n---\n中文技能\n')
    (dsh / 'AGENTS.md').write_text('DSH_GLOBAL_FIXTURE_中文\n')
    (agents / 'AGENTS.md').write_text('AGENTS_GLOBAL_FIXTURE_中文\n')
    core = ROOT / 'app/ohos/entry/src/main/cpp'
    driver = out / 'host-profile'
    run('compile-driver', [os.environ.get('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra', '-Werror',
        '-I', core, core / 'host_core.cpp', HERE / 'host-profile.cc', '-pthread', '-o', driver])
    argv_path = out / 'argv.json'
    run('generate-host', [driver, runtime, guest, dsh, workspace, cache, args.native_library_dir, argv_path])
    argv = json.loads(argv_path.read_text())
    captured = json.loads(Path(str(argv_path) + '.env.json').read_text())
    expected = {'HOME': str(guest / 'root'), 'DSH_HOME': str(dsh), 'DSH_AGENTS_HOME': str(agents),
        'TMPDIR': str(cache / 'ohos-process'), 'NODE_COMPILE_CACHE': str(cache / 'node-compile-cache'),
        'NARB_DISABLE_NATIVE_CACHE': '1', 'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(args.native_library_dir),
        'DSH_GO_OHOS_LINUX_DIRECTORY': str(guest.parent.parent / 'linux-tools'),
        'DSH_PERMISSION_MODE': 'workspace-write'}
    assert captured == expected
    assert len(argv) == 13 and argv[1] == '--jitless' and argv.count('--import') == 1
    profile = Path(argv[7])
    before_profile = sha(profile)
    environment = {**base_env, **captured}
    run('actual-consumers', [args.node, '--jitless', HERE / 'host-layout-consumers.mjs', runtime, guest,
        str(argv_path) + '.env.json', out / 'consumers.json'], env=environment, cwd=workspace)
    # Dump is diagnostic-only: remove the web listening flags, add dump-config.
    run('actual-dump', [args.node, *argv[1:8], '--dump-config'], env=environment, cwd=workspace)
    dump = (out / 'actual-dump.stdout.log').read_text()
    assert str(workspace) in dump and 'ohos-subprocess' in dump and 'sandbox-policy' in dump

    fixture = runpy.run_path(str(HERE / 'host-bridge-fixture.py'))['prepare_bridge_fixture'](runtime, dsh, out)

    # Reuse all real five-tool/approval assertions from the repository round.
    # Only its fixture layout, argv/env inputs and omitted session cwd change.
    source_round = ROOT / 'runtime/ohos/sim/round.mjs'
    round_text = source_round.read_text()
    replacements = [
        ("from './fake-model.mjs';", "from " + json.dumps((ROOT / 'runtime/ohos/sim/fake-model.mjs').as_uri()) + ';'),
        ("new URL('./preload.mjs', import.meta.url)", "new URL(" + json.dumps((ROOT / 'runtime/ohos/sim/preload.mjs').as_uri()) + ')'),
        ("new URL('./observe-loader.mjs', import.meta.url)", "new URL(" + json.dumps((ROOT / 'runtime/ohos/sim/observe-loader.mjs').as_uri()) + ')'),
        ("const workspace = join(out, 'workspace');\nawait mkdir(workspace);", 'const workspace = ' + json.dumps(str(workspace)) + ';'),
        ("await mkdir(join(out, 'home'), { mode: 0o700 });", '// Existing private guest directories are supplied by Host.'),
        ("if (values.mode !== 'jit') flags.push('--jitless');", '// --jitless is already in the captured production argv.'),
        ("const env = {", 'const hostEnvironment = ' + json.dumps(captured, ensure_ascii=False) + ';\nconst env = {'),
        ("DSH_HOME: join(out, 'home'),", '...hostEnvironment,'),
        ("const args = [...flags, join(prefix, 'node_modules/@deepseek-ai/dsh/lib/bin.js'), 'web'];", 'const hostArgv = ' + json.dumps(argv, ensure_ascii=False) + ';\nconst args = [...flags, ...hostArgv.slice(1)];'),
        ("for (const name of [...profilePatches, overlay]) args.push('--patch', resolve(name));\nargs.push('--host', '127.0.0.1', '--port', '0', '--no-open');", "args.splice(args.indexOf('--host'), 0, ...[...profilePatches, overlay].flatMap(name => ['--patch', resolve(name)]));"),
        ("report.profilePatches = profilePatches.map((name) => resolve(name));", "report.profilePatches = [hostArgv[7], ...profilePatches.map((name) => resolve(name))];\nreport.hostGenerated = {argv:hostArgv, environment:hostEnvironment, sessionCreateOmitsCwd:true};"),
        ("{ request: { cwd: workspace, agentPreset: 'standard' } }", "{ request: { agentPreset: 'standard' } }"),
        ("const engineClosed = new Promise((resolve) => engine.once('close', resolve));", "report.engineLifecycle = { pid: engine.pid, requested: [], closeObserved: false };\nconst engineClosed = new Promise((resolve) => engine.once('close', (code, signal) => {\n  report.engineLifecycle.exit = { code, signal, utc: new Date().toISOString(), elapsedMs: performance.now()-start };\n  report.engineLifecycle.closeObserved = true; resolve(code);\n}));\nfunction requestEngineSignal(signal, reason) {\n  const accepted = engine.kill(signal);\n  report.engineLifecycle.requested.push({ signal, reason, accepted, utc: new Date().toISOString(), elapsedMs: performance.now()-start });\n}\nengine.once('error', error => { report.engineLifecycle.spawnError = { name:error.name, message:error.message }; });"),
        ("ready.reject(new Error('engine diagnostic limit')); engine.kill(); return;", "ready.reject(new Error('engine diagnostic limit')); requestEngineSignal('SIGTERM', 'diagnostic-limit'); return;"),
        ("const force = setTimeout(() => engine.kill('SIGKILL'), 5000);\n    engine.kill('SIGTERM'); await engineClosed; clearTimeout(force);", "const force = setTimeout(() => requestEngineSignal('SIGKILL', 'cleanup-grace-expired'), 5000);\n    requestEngineSignal('SIGTERM', 'observer-finally'); await engineClosed; clearTimeout(force);"),
    ]
    for before, after in replacements:
        assert round_text.count(before) == 1, before
        round_text = round_text.replace(before, after)
    # The test fixture never supplies a bridge entry. A missing production bridge
    # must fail authenticated inventory before any positive fixture operation.
    round_text = 'import { runBridgeRouteContract } from ' + json.dumps((HERE / 'host-bridge-routes.mjs').as_uri()) + ';\n' + round_text
    before = "  report.status = 'PASS';\n  report.stage = 'complete';"
    after = """  if (report.approvals !== 2) throw new Error('expected exactly two real approvals');
  report.controlStatus = 'PASS_FIVE_TOOLS_TWO_APPROVALS';
  socket.send(JSON.stringify({ type: 'close', streamId: 'session' }));
  report.stage = 'bridge-route-contract';
  report.routes = await runBridgeRouteContract({ base, cookie, rpc, WebSocket, out, ownedSessionId: sessionId, fixture: """ + json.dumps(fixture) + """ });
  report.status = 'PASS';
  report.stage = 'complete';"""
    assert round_text.count(before) == 1
    round_text = round_text.replace(before, after)
    before = "} catch (error) {\n  report.error = { name: error.name, message: error.message };"
    after = """} catch (error) {
  if (report.stage === 'bridge-route-contract') {
    try { report.routes = JSON.parse(await readFile(join(out, 'bridge-routes/report.json'), 'utf8')); } catch {}
  }
  report.error = { name: error.name, message: error.message };"""
    assert round_text.count(before) == 1
    round_text = round_text.replace(before, after)
    round_driver = out / 'host-layout-round.mjs'
    round_driver.write_text(round_text)
    command = [args.node, round_driver, '--prefix', runtime, '--out', out / 'round', '--mode', 'sim', '--platform',
        '--native-library-dir', args.native_library_dir, '--linked-publication-fixture', args.publication_fixture]
    for name in ['libdsh_flock.so', 'libdsh_require_builtin.so']:
        command += ['--allow-addon', args.native_library_dir / name]
    if args.model_fixture:
        command += ['--model-fixture', args.model_fixture]
    run('actual-round', command)
    report = json.loads((out / 'round/report.json').read_text())
    assert report['status'] == 'PASS' and report['approvals'] == 2 and report['loader']['observedRoute'] == 'native-addon'
    assert report['routes']['status'] == 'PASS_HOST_BRIDGE_ROUTE_CONTRACT' and report['routes']['requiredTemplates'] == 15
    assert report['routes']['attachments']['status'] == 'PASS_OH_FULL_REFERENCE_CONTRACT'
    assert len(report['routes']['attachments']['cases']) == 7
    assert all(row['passed'] for row in report['routes']['attachments']['cases'])
    assert report['engineLifecycle']['closeObserved'] is True
    assert report['engineLifecycle']['exit']['code'] == 0
    assert report['engineLifecycle']['exit']['signal'] is None
    assert not any(item['signal'] == 'SIGKILL' for item in report['engineLifecycle']['requested'])
    # Read-only image lookup must not mutate its durable inputs, including after
    # the unrelated disposable Session is actually deleted and Host is closed.
    for row in fixture['attachments']['objects']:
        path = Path(row['path'])
        assert path.stat().st_size == row['bytes'] and sha(path) == row['sha256']
    assert not Path(fixture['attachments']['missingPath']).exists()

    for name, expected_module in runtime_modules.items():
        assert (runtime / name).stat().st_size == expected_module['bytes'] and sha(runtime / name) == expected_module['sha256']
    assert 'changed-label' in (dsh / 'profiles/web/cordis.patch.yml').read_text()
    assert sha(profile) == before_profile
    if args.assembled_payload:
        assert inventory(runtime) == payload_before, 'Host/round must not mutate the installed runtime payload'
    write_json(out / 'report.json', {'scope': 'Linux actual pinned DSH, strict simulation; no SDK/Ark/HAP/device claim',
        'assertionsPassed': True, 'tools': 5, 'approvals': report['approvals'], 'profileUnchanged': True,
        'bridgeRouteContract': report['routes']['status'], 'bridgeConsumerTemplates': 15,
        'attachmentContract': report['routes']['attachments'],
        'attachmentFixtureSha256': sha(out / 'attachment-fixture-input.json'),
        'attachmentObjectsUnchangedAfterHostExit': True,
        'engineLifecycle': report['engineLifecycle'], 'runtimeDeletionModules': runtime_modules,
        'isolatedBridgeSource': str(runtime / 'runtime/bridge/dsh-go-bridge'),
        'bridgeFixtureSha256': sha(out / 'bridge-fixture-input.json'),
        'bridgeIsolatedImport': json.loads((out / 'bridge-isolated-import/report.json').read_text())['status'],
        'profileSha256': before_profile, 'roundSourceSha256': sha(source_round), 'roundDriverSha256': sha(round_driver),
        'prefixInputManifestSha256': sha(out / 'prefix-input.json'),
        'runtimeInput': 'exact assembled payload' if args.assembled_payload else 'development-prefix copy',
        'processDependencyManifestSha256': sha(out / 'process-dependencies-input.json') if not args.assembled_payload else None,
        'inputs': {str(path): sha(path) for path in [core / 'host_core.cpp', core / 'host_core.h', HERE / 'host-profile.cc',
            HERE / 'host-layout-consumers.mjs', HERE / 'host-bridge-routes.mjs',
            HERE / 'host-bridge-fixture.py', HERE / 'bridge-isolated-import.py',
            Path(__file__), args.publication_fixture,
            args.native_library_dir / 'libdsh_flock.so', args.native_library_dir / 'libdsh_require_builtin.so']}})
    print('Host layout, isolated bridge import, strict five-tool/two-approval round and all bridge route contracts completed.', flush=True)


if __name__ == '__main__':
    main()
