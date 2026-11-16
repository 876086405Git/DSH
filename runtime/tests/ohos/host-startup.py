#!/usr/bin/env python3
"""Linux contract tests: actual dsh_node_start, sequential preloads, one version pin.

The outer coordinator can spawn. Strict children use O0 explicitly; the product
runner's one-import contract is tested separately from those instrumentation runs.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OHOS = ROOT / 'runtime/ohos'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def environment():
    env = os.environ.copy()
    for key in ['NODE_OPTIONS', 'NODE_USE_ENV_PROXY', 'LD_PRELOAD', 'DSH_HOME',
                'DSH_GO_OHOS_SIM', 'DSH_GO_OHOS_SIM_PLATFORM', 'DSH_GO_OHOS_SIM_ADDONS',
                'DSH_GO_OHOS_LINUX_DIRECTORY', 'DSH_GO_OHOS_NATIVE_LIBRARY_DIR',
                'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
                'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy']:
        env.pop(key, None)
    return env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node-root', type=Path, required=True)
    parser.add_argument('--dsh-prefix', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--baseline-runner', type=Path)
    args = parser.parse_args()
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    node = args.node_root.resolve() / 'bin/node'
    entry = args.dsh_prefix.resolve() / 'node_modules/@deepseek-ai/dsh/lib/bin.js'
    assert node.is_file() and entry.is_file()
    build = args.out / 'native'
    result = subprocess.run(['bash', str(HERE / 'build-publication-native.sh'), str(args.node_root.resolve()), str(build)],
                            env=environment(), capture_output=True, text=True)
    (args.out / 'native-build.log').write_text(result.stdout + result.stderr)
    result.check_returncode()
    runner = build / 'libhost-startup-test.so'
    command = [os.environ.get('CXX', 'c++'), '-std=c++20', '-shared', '-fPIC', '-fvisibility=hidden',
               '-DNAPI_VERSION=8', '-I', str(args.node_root.resolve() / 'include/node'), '-I', str(build),
               '-I', str(HERE / 'publication-deviceinfo-fixture'),
               str(HERE / 'publication-deviceinfo-fixture/deviceinfo.cc'),
               str(OHOS / 'host/node_runner.cpp'), str(OHOS / 'host/publication_binding.cc'),
               str(HERE / 'host-startup-linux.cc'), '-ldl', '-o', str(runner)]
    result = subprocess.run(command, env=environment(), capture_output=True, text=True)
    (args.out / 'runner-build.json').write_text(json.dumps({'command': command, 'exit': result.returncode,
        'stdout': result.stdout, 'stderr': result.stderr}, indent=2) + '\n')
    result.check_returncode()
    rows = []
    pin = json.loads((OHOS / 'node-version.json').read_text())
    preload = str(OHOS / 'preload.mjs')
    main_file = str(HERE / 'host-startup-main.mjs')

    def run(name, arguments, env, checker, **extra):
        argv = [str(node), *arguments]
        try:
            proc = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=30)
            passed = checker(proc)
            row = {'case': name, 'passed': bool(passed), 'exitCode': proc.returncode,
                   'argv': argv, 'stdout': proc.stdout, 'stderr': proc.stderr, **extra}
        except Exception as error:
            row = {'case': name, 'passed': False, 'argv': argv, 'testError': repr(error), **extra}
        rows.append(row)
        print(name, 'PASS' if row['passed'] else 'FAIL', flush=True)
        return row

    def fresh(name):
        directory = args.out / 'cases' / name
        directory.mkdir(parents=True, exist_ok=True)
        sentinel = directory / 'preload-ran'
        main_sentinel = directory / 'main-ran'
        for path in [sentinel, main_sentinel]:
            path.unlink(missing_ok=True)
        cjs = directory / 'early.cjs'
        esm = directory / 'early.mjs'
        cjs.write_text('require("node:fs").writeFileSync(' + json.dumps(str(sentinel)) + ', "early");\n')
        esm.write_text('import {writeFileSync} from "node:fs";writeFileSync(' + json.dumps(str(sentinel)) + ', "early");\n')
        env = environment()
        env['LD_PRELOAD'] = str(runner)
        env['OHOS_HOST_MAIN_SENTINEL'] = str(main_sentinel)
        return directory, sentinel, main_sentinel, cjs, esm, env

    positives = [('separate-import', ['--jitless', '--import', preload, main_file]),
                 ('equals-import', ['--jitless', '--import=' + preload, main_file]),
                 ('dsh-arguments-are-not-node-options', ['--jitless', '--import', preload, main_file,
                                                      '--require=literal-dsh-argument', '--import', 'literal']),
                 ('empty-node-options', ['--jitless', '--import', preload, main_file])]
    for name, arguments in positives:
        directory, sentinel, main_sentinel, cjs, esm, env = fresh(name)
        if name == 'empty-node-options': env['NODE_OPTIONS'] = ''
        run(name, arguments, env, lambda p: p.returncode == 0 and main_sentinel.exists()
            and not sentinel.exists() and 'M6_TEST_ENTER_DSH_NODE_START' in p.stderr
            and json.loads(p.stdout)['linuxContractOnly'] is True,
            scope='actual Linux dsh_node_start; OHOS platform branches are no-ops')

    negative_names = ['missing-jitless', 'wrong-preload', 'relative-preload', 'relative-entry',
                      'missing-preload-value', 'duplicate-import', 'cli-require', 'cli-require-equals',
                      'cli-import-before', 'cli-import-after', 'node-options-require',
                      'node-options-import', 'node-options-whitespace', 'node-options-harmless']
    for name in negative_names:
        directory, sentinel, main_sentinel, cjs, esm, env = fresh(name)
        arguments = ['--jitless', '--import', preload, main_file]
        code = 'ERR_OHOS_HOST_ARGV'
        if name == 'missing-jitless': arguments = ['--import', preload, main_file]
        elif name == 'wrong-preload': arguments = ['--jitless', '--import', str(OHOS / 'net/dsh-preload.mjs'), main_file]
        elif name == 'relative-preload': arguments = ['--jitless', '--import', 'runtime/ohos/preload.mjs', main_file]
        elif name == 'relative-entry': arguments[-1] = 'main.mjs'
        elif name == 'missing-preload-value': arguments = ['--jitless', '--import', main_file]
        elif name == 'duplicate-import': arguments = ['--jitless', '--import', preload, '--import', preload, main_file]
        elif name == 'cli-require': arguments = ['--jitless', '-r', str(cjs), '--import', preload, main_file]
        elif name == 'cli-require-equals': arguments = ['--jitless', '--require=' + str(cjs), '--import', preload, main_file]
        elif name == 'cli-import-before': arguments = ['--jitless', '--import', str(esm), '--import', preload, main_file]
        elif name == 'cli-import-after': arguments = ['--jitless', '--import', preload, '--import=' + str(esm), main_file]
        elif name.startswith('node-options-'):
            code = 'ERR_OHOS_HOST_NODE_OPTIONS'
            env['NODE_OPTIONS'] = {'node-options-require': '--require ' + json.dumps(str(cjs)),
                'node-options-import': '--import ' + json.dumps(str(esm)),
                'node-options-whitespace': ' ', 'node-options-harmless': '--no-warnings'}[name]
        run(name, arguments, env, lambda p, c=code: p.returncode == 64 and c in p.stderr
            and 'M6_TEST_ENTER_DSH_NODE_START' in p.stderr and not sentinel.exists()
            and not main_sentinel.exists() and p.stdout == '',
            scope='rejected before Node initialization; no sentinel preloads or main executed')

    # Native Node ordering control; deliberately no product runner or OHOS marker.
    directory = args.out / 'cases' / 'native order with space'
    directory.mkdir(parents=True, exist_ok=True)
    trace = directory / 'trace.jsonl'; trace.unlink(missing_ok=True)
    modules = {}
    for label, extension in [('env-require', 'cjs'), ('cli-require', 'cjs'),
                              ('env-import', 'mjs'), ('cli-import', 'mjs'), ('main', 'mjs')]:
        path = directory / (label + '.' + extension)
        prefix = 'const {appendFileSync}=require("node:fs");' if extension == 'cjs' else 'import {appendFileSync} from "node:fs";'
        path.write_text(prefix + 'appendFileSync(' + json.dumps(str(trace)) + ',' + json.dumps(label + '\n') + ');\n')
        modules[label] = path
    env = environment()
    env['NODE_OPTIONS'] = '--import ' + json.dumps(str(modules['env-import'])) + ' --require ' + json.dumps(str(modules['env-require']))
    run('native-node-preload-order', ['--import=' + str(modules['cli-import']), '-r', str(modules['cli-require']), str(modules['main'])], env,
        lambda p: p.returncode == 0 and trace.read_text().splitlines() ==
        ['env-require', 'cli-require', 'env-import', 'cli-import', 'main'],
        scope='real unmodified Node ordering baseline, not a permitted product argv')

    if args.baseline_runner:
        directory, sentinel, main_sentinel, cjs, esm, env = fresh('old-runner-order-counterexample')
        env['LD_PRELOAD'] = str(args.baseline_runner.resolve())
        env['NODE_OPTIONS'] = '--require ' + json.dumps(str(cjs))
        run('old-runner-order-counterexample', ['--jitless', '--import', preload, main_file], env,
            lambda p: p.returncode == 0 and sentinel.exists() and main_sentinel.exists(),
            scope='expected old-contract counterexample; sentinel executed before wrapper',
            baselineSHA256=sha(args.baseline_runner))
        rows[-1]['newHostContractWouldPass'] = False

    # Real pre-entry DSH resolution + network + publication, instrumented outside
    # the dedicated host argv contract. Simulation/observer imports are TEST ONLY.
    linked = build / 'libpublication-test-linked.so'
    for strict in [False, True]:
        for name in ['happy', 'late-undici', 'missing-binding', 'missing-home', 'wrong-entry', 'android-env']:
            label = ('strict-' if strict else 'jit-') + name
            directory = args.out / 'cases' / label; directory.mkdir(parents=True, exist_ok=True)
            home = directory / 'app-data'; home.mkdir(mode=0o700, exist_ok=True)
            linux_directory = directory / 'linux-tools'; linux_directory.mkdir(mode=0o700, exist_ok=True)
            native_directory = directory / 'native-libraries'; native_directory.mkdir(mode=0o700, exist_ok=True)
            env = environment()
            env['OHOS_STARTUP_CASE'] = json.dumps({'name': name, 'entry': str(entry), 'strict': strict,
                'linuxDirectory': str(linux_directory), 'nativeLibraryDirectory': str(native_directory)})
            env['DSH_GO_OHOS_LINUX_DIRECTORY'] = str(linux_directory)
            env['DSH_GO_OHOS_NATIVE_LIBRARY_DIR'] = str(native_directory)
            if name != 'missing-home': env['DSH_HOME'] = str(home)
            if name != 'missing-binding': env['LD_PRELOAD'] = str(linked)
            arguments = ['--jitless'] if strict else []
            arguments += ['--import', str(HERE / 'host-preload-capture.mjs')]
            if name != 'android-env':
                arguments += ['--import', str(OHOS / 'sim' / ('preload.mjs' if strict else 'marker.mjs'))]
                if strict:
                    env['DSH_GO_OHOS_SIM_PLATFORM'] = 'openharmony'
                    env['DSH_GO_OHOS_SIM_ADDONS'] = '[]'
            else:
                env['DSH_GO_OHOS_SIM'] = '1'
                env['DSH_GO_OHOS_SIM_PLATFORM'] = 'openharmony'
            arguments += ['--import', preload, '--import', str(HERE / 'host-preload-observer.mjs'),
                          main_file if name == 'wrong-entry' else str(entry)]
            def check(p, name=name, strict=strict, home=home):
                outcome = json.loads(p.stdout)
                if name == 'happy':
                    return p.returncode == 0 and outcome == {
                        'beforeDshEntry': True, 'body': 'startup-ready',
                        'publishMethod': 'rename-noreplace' if strict else 'link', 'publication': True,
                        'worker': {'body': 'startup-ready', 'network': True, 'publication': False, 'simulated': True, 'linuxOwnerPaths': False},
                        'constructorsSame': True, 'linuxPathsCapturedBeforeEntry': True, 'strict': strict}
                if name == 'android-env':
                    return p.returncode == 0 and outcome == {
                        'androidGuardOnly': True, 'network': False, 'publication': False, 'fetchSame': True}
                error = {'late-undici': 'ERR_OHOS_NET_BOOTSTRAP_ORDER',
                         'missing-binding': 'ERR_OHOS_PUBLICATION_BINDING_MISSING',
                         'missing-home': 'ERR_OHOS_PUBLICATION_DATA_DIRECTORY',
                         'wrong-entry': 'ERR_OHOS_NET_DSH_ENTRY'}[name]
                network = name in ['missing-binding', 'missing-home']
                return p.returncode != 0 and error in p.stderr and outcome == {
                    'failure': error, 'network': network, 'publication': False} and not (home / 'ohos-ownership').exists()
            run(label, arguments, env, check,
                scope='test-only predecessor simulation/observer; actual locked DSH entry resolved, then pre-entry observer exits')

    # Same alternate single pin is consumed by JS and generated native guard.
    version = args.out / 'version-mutant'; version.mkdir(exist_ok=True)
    mutant = '.'.join(pin.split('.')[:2] + [str(int(pin.split('.')[2]) + 1)])
    mutant_pin = version / 'node-version.json'; mutant_pin.write_text(json.dumps(mutant) + '\n')
    generated = version / 'dsh_node_version.h'
    g = subprocess.run(['python3', str(OHOS / 'host/generate-node-version.py'), '--pin', str(mutant_pin), '--output', str(generated)], capture_output=True, text=True)
    g.check_returncode()
    addon = version / 'publication.node'
    command = [os.environ.get('CXX', 'c++'), '-std=c++20', '-shared', '-fPIC', '-fvisibility=hidden',
               '-DNAPI_VERSION=8', '-DDSH_PUBLICATION_TEST_ADDON', '-I', str(version),
               '-I', str(HERE / 'publication-deviceinfo-fixture'),
               str(HERE / 'publication-deviceinfo-fixture/deviceinfo.cc'),
               '-I', str(args.node_root.resolve() / 'include/node'), str(OHOS / 'host/publication_binding.cc'), '-o', str(addon)]
    c = subprocess.run(command, capture_output=True, text=True); c.check_returncode()
    run('native-consumes-alternate-pin', ['-e', 'require(' + json.dumps(str(addon)) + ')'], environment(),
        lambda p: p.returncode != 0 and 'ERR_OHOS_NATIVE_NODE_VERSION' in p.stderr and mutant in p.stderr,
        pin=mutant, generatedHeaderSHA256=sha(generated), addonSHA256=sha(addon))
    publication = version / 'publication'; publication.mkdir(exist_ok=True)
    for name in ['index.mjs', 'atomic.mjs', 'ledger.mjs', 'atomic-fuse.mjs']:
        shutil.copyfile(OHOS / 'publication' / name, publication / name)
    run('js-consumes-alternate-pin', ['--import', str(OHOS / 'sim/marker.mjs'), '--input-type=module', '-e',
        'const {installPublication}=await import(' + json.dumps((publication / 'index.mjs').as_uri()) + ');await installPublication();'], environment(),
        lambda p: p.returncode != 0 and 'ERR_OHOS_PUBLICATION_NODE_VERSION' in p.stderr and mutant in p.stderr, pin=mutant)
    invalid = version / 'invalid.json'; invalid.write_text(json.dumps({'version': pin}) + '\n')
    bad = subprocess.run(['python3', str(OHOS / 'host/generate-node-version.py'), '--pin', str(invalid), '--output', str(version / 'bad.h')], capture_output=True, text=True)
    rows.append({'case': 'invalid-pin-schema', 'passed': bad.returncode != 0 and not (version / 'bad.h').exists(),
                 'exitCode': bad.returncode, 'stdout': bad.stdout, 'stderr': bad.stderr})
    print('invalid-pin-schema', 'PASS' if rows[-1]['passed'] else 'FAIL', flush=True)
    paths = [node, entry, runner, linked, OHOS / 'node-version.json', OHOS / 'preload.mjs',
             OHOS / 'host/node_runner.cpp', OHOS / 'host/publication_binding.cc',
             OHOS / 'host/generate-node-version.py', OHOS / 'publication/index.mjs', Path(__file__).resolve()]
    paths += [HERE / 'publication-deviceinfo-fixture/deviceinfo.h', HERE / 'publication-deviceinfo-fixture/deviceinfo.cc']
    paths += [OHOS / 'linux/host-paths.mjs', HERE / 'host-preload-observer.mjs', HERE / 'host-preload-worker.mjs']
    report = {'scope': 'Linux contract and explicit simulation evidence; OHOS SDK, ABI, HAP, device NOT_RUN',
              'nodePin': pin, 'inputs': {str(p): sha(p) for p in paths},
              'counts': {'total': len(rows), 'pass': sum(bool(row['passed']) for row in rows),
                         'fail': sum(not row['passed'] for row in rows)}, 'cases': rows}
    (args.out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report['counts']), flush=True)
    return 0 if all(row['passed'] for row in rows) else 1


if __name__ == '__main__':
    raise SystemExit(main())
