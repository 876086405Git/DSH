#!/usr/bin/env python3
"""Production-preload/provider SIGKILL restart controls for the atomic fuse.

The parent only writes fixture/config/source files. It never creates a fuse
record, provides a receipt, recovers the ledger, or unlinks a publication temp
before assertions. Linux syscall evidence is separate from OHOS/seccomp proof.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import tempfile
import time


def digest(data): return hashlib.sha256(data).hexdigest()
def file_state(path):
    try:
        data = Path(path).read_bytes()
        info = Path(path).stat()
        return {'exists': True, 'bytes': len(data), 'sha256': digest(data),
                'dev': str(info.st_dev), 'ino': str(info.st_ino), 'mtimeNs': str(info.st_mtime_ns)}
    except FileNotFoundError: return {'exists': False}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('node', 'simulation', 'marker', 'preload', 'linked-lib', 'prefix', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--mode', choices=['jit', 'strict'], required=True)
    parser.add_argument('--cases', choices=['all', 'kill', 'lifecycle'], default='all')
    args = parser.parse_args()
    for name in ('node', 'simulation', 'marker', 'preload', 'linked_lib', 'prefix', 'out'):
        setattr(args, name, getattr(args, name).resolve())
    scripts = Path(__file__).resolve().parent
    actor, instrument = scripts / 'publication-fuse-actor.mjs', scripts / 'publication-fuse-instrument.mjs'
    dsh_package = args.prefix / 'node_modules/@deepseek-ai/dsh/package.json'
    dsh = json.loads(dsh_package.read_text())
    assert dsh['name'] == '@deepseek-ai/dsh' and dsh['version'] == '0.2.2-rc.1'
    binary = (dsh_package.parent / dsh['bin']['dsh']).resolve()
    sources = {'driver': Path(__file__).resolve(), 'actor': actor, 'instrument': instrument,
               'node': args.node, 'simulation': args.simulation, 'marker': args.marker,
               'productPreload': args.preload, 'linkedLibrary': args.linked_lib,
               'actualDshBin': binary, 'dshPackage': dsh_package,
               'capabilitiesReader': scripts.parents[1] / 'ohos/publication/capabilities.mjs'}
    for path in (args.preload.parent / 'publication').glob('*.mjs'):
        sources['publication/' + path.name] = path
    inputs = {name: {'path': str(path), 'sha256': digest(path.read_bytes())} for name, path in sources.items()}
    version_a = {'osFullName': 'OpenHarmony test fixture A', 'displayVersion': 'test-A',
                 'incrementalVersion': '0001', 'securityPatchTag': 'test-patch-A'}
    version_b = {**version_a, 'displayVersion': 'test-B'}
    rows = []
    with tempfile.TemporaryDirectory(prefix='ohos-publication-fuse-') as temporary:
        root = Path(temporary)
        modules = {}
        for provider in ('dsh-attachment-local', 'dsh-session-persistence-jsonl'):
            original = args.prefix / 'node_modules/@deepseek-ai' / provider / 'lib/index.js'
            raw = original.read_bytes()
            directory = root / 'provider-export-fixtures' / provider
            directory.mkdir(parents=True)
            (directory / 'node_modules').symlink_to(args.prefix / 'node_modules', target_is_directory=True)
            module = directory / 'index.mjs'
            module.write_bytes(raw + b'\nexport { publishOhosExclusive };\n')
            companion = original.with_name('dsh-go-deletion.mjs')
            if companion.exists(): shutil.copy2(companion, directory / companion.name)
            modules[provider] = str(module)
            inputs[provider] = {'path': str(original), 'sha256': digest(raw),
                                'instrumentation': 'unchanged source + export-only line in own test directory',
                                'fixtureSha256': digest(module.read_bytes())}
        serial = 0
        def run(config, kill_at_gate=False):
            nonlocal serial
            serial += 1
            config_path = root / f'config-{serial}.json'
            config_path.write_text(json.dumps(config))
            env = {'PATH': os.environ.get('PATH', ''), 'LANG': 'C.UTF-8',
                   'LD_PRELOAD': str(args.linked_lib), 'DSH_HOME': config['home'],
                   'M6_FUSE_TEST_CONFIG': str(config_path),
                   'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony', 'DSH_GO_OHOS_SIM_ADDONS': '[]'}
            argv = [str(args.node)]
            if args.mode == 'strict': argv += ['--jitless', '--import', str(args.simulation)]
            else: argv += ['--import', str(args.marker)]
            argv += ['--import', str(instrument), '--import', str(args.preload),
                     '--import', str(actor), str(binary)]
            child = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            started = time.monotonic()
            output = {'stdout': bytearray(), 'stderr': bytearray()}
            events, buffer, killed, timed_out = [], b'', False, False
            selector = selectors.DefaultSelector()
            selector.register(child.stdout, selectors.EVENT_READ, 'stdout')
            selector.register(child.stderr, selectors.EVENT_READ, 'stderr')
            while selector.get_map():
                if time.monotonic() - started > 20 and child.poll() is None:
                    timed_out = True; child.kill()
                for key, _ in selector.select(0.25):
                    data = os.read(key.fileobj.fileno(), 65536)
                    if not data:
                        selector.unregister(key.fileobj); continue
                    output[key.data].extend(data)
                    if key.data == 'stdout':
                        buffer += data
                        while b'\n' in buffer:
                            line, buffer = buffer.split(b'\n', 1)
                            if not line: continue
                            try: event = json.loads(line)
                            except ValueError: event = {'type': 'non-json', 'text': line.decode(errors='replace')}
                            events.append(event)
                            if kill_at_gate and event.get('type') == 'gate' and not killed:
                                killed = True
                                child.send_signal(signal.SIGKILL)
            child.wait(timeout=2)
            selector.close()
            return {'argv': argv, 'mode': args.mode, 'config': config, 'exitCode': child.returncode,
                    'killedAtGate': killed, 'timedOut': timed_out, 'events': events,
                    'stdout': output['stdout'].decode(errors='replace'),
                    'stderr': output['stderr'].decode(errors='replace')}
        def setup(name, operation, provider=None):
            directory = root / name; directory.mkdir()
            home = directory / 'home'; home.mkdir(mode=0o700)
            data = directory / 'data'; data.mkdir(mode=0o700)
            source = directory / 'retained-source'
            source.write_bytes(b'\xe4\xb8\xad\xe6\x96\x87\n' + b'a' * (3 * 65536 + 17))
            config = {'home': str(home), 'data': str(data), 'source': str(source),
                      'targets': [str(directory / 'final')], 'mode': args.mode,
                      'prefix': str(args.prefix), 'operation': operation,
                      'versionBindingMember': 'getSystemBuildIdentity', 'versionFixture': version_a,
                      'stop': None}
            if provider: config['moduleFile'] = modules[provider]
            return config, directory
        def event(run, kind): return next((item for item in run['events'] if item.get('type') == kind), None)
        def events(run, kind): return [item for item in run['events'] if item.get('type') == kind]
        def state(home):
            try: return json.loads((Path(home) / 'ohos-ownership/atomic-state.json').read_text())
            except FileNotFoundError: return None
        def ledger(home):
            try: return json.loads((Path(home) / 'ohos-ownership/ledger.json').read_text())
            except FileNotFoundError: return None
        def check(row, condition, message):
            if not condition: row.setdefault('failures', []).append(message)
        def finish(row):
            row['passed'] = not row.get('failures')
            print(row['case'], 'PASS' if row['passed'] else 'FAIL', flush=True)
        if args.cases in ('all', 'kill'):
            operations = [('helper-attachment', 'helper', 'dsh-attachment-local'),
                          ('helper-session', 'helper', 'dsh-session-persistence-jsonl'),
                          ('attachment-public', 'attachment-public', None),
                          ('session-public', 'session-public', None)]
            for name, operation, provider in operations:
                for phase in ('before-native', 'after-native-success'):
                    row = {'case': name + '-' + phase, 'operation': operation, 'phase': phase}
                    rows.append(row)
                    config, directory = setup(row['case'], operation, provider)
                    original = file_state(config['source'])
                    first = row['first'] = run({**config, 'stop': phase}, True)
                    gate = event(first, 'gate')
                    # Always perform restart, even when old code has no marker.
                    if gate:
                        row['afterKill'] = {'state': state(config['home']), 'ledger': ledger(config['home']),
                                            'temporary': file_state(gate['source']), 'final': file_state(gate['target']),
                                            'source': file_state(config['source'])}
                    retry = row['retry'] = run({**config, 'allowedErrors': ['EEXIST']})
                    start, done = event(retry, 'startup'), event(retry, 'done')
                    row['afterRetry'] = {'state': state(config['home']), 'ledger': ledger(config['home']),
                                        'source': file_state(config['source'])}
                    if gate:
                        row['afterRetry'].update(temporary=file_state(gate['source']), final=file_state(gate['target']))
                    check(row, first['killedAtGate'] and first['exitCode'] == -signal.SIGKILL and not first['timedOut'], 'writer must be killed by SIGKILL at the actual commit gate')
                    check(row, bool(gate and gate['state'] and gate['state']['value']['state'] == 'trying'), 'production must durably record trying before native entry')
                    check(row, retry['exitCode'] == 0 and not retry['timedOut'], 'fresh process must complete retry')
                    check(row, bool(start and start['atomic'] == 'disabled-after-crash'), 'startup consumer must observe disabled-after-crash')
                    check(row, bool(done and done['atomic'] == 'disabled-after-crash'), 'retry must keep disabled-after-crash')
                    check(row, len(events(retry, 'native-entry')) == 0, 'same-build retry must never enter native rename wrapper')
                    check(row, bool(row['afterRetry']['state'] and row['afterRetry']['state']['state'] == 'disabled-after-crash'), 'disabled state must remain on disk')
                    check(row, file_state(config['source'])['sha256'] == original['sha256'], 'input source must remain unchanged')
                    if gate:
                        check(row, row['afterRetry']['temporary'] == {'exists': False}, 'production restart must recover owned staging inode without parent cleanup')
                        check(row, row['afterRetry']['final'].get('sha256') == gate['input']['sha256'], 'final bytes must equal the complete staged data')
                        if phase == 'before-native': check(row, not row['afterKill']['final']['exists'], 'before native kill must not expose final bytes')
                        else: check(row, row['afterKill']['final'].get('sha256') == gate['input']['sha256'], 'successful native rename must be preserved across the later crash')
                    if operation == 'helper':
                        if phase == 'before-native':
                            published = event(retry, 'published')
                            check(row, bool(published and published['result']['method'] == 'exclusive-copy-fallback'), 'actual provider helper must report exclusive-copy-fallback')
                        else:
                            error = event(retry, 'publication-error')
                            check(row, bool(error and error['code'] == 'EEXIST'), 'retry must preserve committed final and reject replacement')
                    else:
                        check(row, event(retry, 'public-consumer') is not None, 'real public provider read/list must succeed after restart')
                    check(row, bool(start and start['publicationCapability']['atomic'] == 'disabled-after-crash'), 'O6 consumer projection must expose the actual disabled state')
                    if operation == 'helper' and phase == 'before-native':
                        upgrade = row['upgradeAfterDisabled'] = run({**config,
                            'targets': [str(directory / 'new-build-final')], 'versionFixture': version_b})
                        entry, upgraded = event(upgrade, 'native-entry'), event(upgrade, 'done')
                        check(row, upgrade['exitCode'] == 0 and bool(entry and entry['state'] and entry['state']['value']['state'] == 'trying'), 'changed build must rearm a crash-disabled fuse before its actual call')
                        check(row, bool(upgraded and upgraded['atomic'] == 'available'), 'successful upgraded call must replace disabled with available')
                        if start and upgraded:
                            check(row, start.get('systemVersion') != upgraded.get('systemVersion'), 'version B must produce a distinct stable system generation key')
                    finish(row)
        if args.cases in ('all', 'lifecycle'):
            for provider in ('dsh-attachment-local', 'dsh-session-persistence-jsonl'):
                row = {'case': provider + '-success-rearm'}; rows.append(row)
                config, directory = setup(row['case'], 'helper', provider)
                config['targets'] = [str(directory / 'first'), str(directory / 'second')]
                first = row['first'] = run(config)
                publications = events(first, 'published'); entries = events(first, 'native-entry')
                check(row, first['exitCode'] == 0 and len(publications) == 2 and len(entries) == 2, 'two actual native publications must complete')
                check(row, bool(entries and entries[0]['state'] and entries[0]['state']['value']['state'] == 'trying'), 'first per-process call must arm trying')
                if len(publications) == 2:
                    check(row, publications[0]['atomic'] == publications[1]['atomic'] == 'available', 'success must be observable as available')
                    check(row, publications[0]['state'] == publications[1]['state'], 'same-process subsequent successful native call must not rewrite the fuse record')
                # Starting an idle engine must not itself arm. Only its real call does.
                idle = row['idle'] = run({**config, 'operation': 'startup-only'})
                check(row, bool(event(idle, 'startup') and event(idle, 'startup')['atomic'] == 'available'), 'same-build idle engine reports stored available')
                second = row['newProcess'] = run({**config, 'targets': [str(directory / 'third')]})
                entry = event(second, 'native-entry')
                check(row, second['exitCode'] == 0 and bool(entry and entry['state'] and entry['state']['value']['state'] == 'trying'), 'new process rearms before its first actual call')
                check(row, bool(entry and entries and entry.get('state') and entries[0].get('state') and entry['state']['value']['ownerId'] != entries[0]['state']['value']['ownerId']), 'new process owns its distinct trying record')
                finish(row)
                row = {'case': provider + '-unsupported-upgrade'}; rows.append(row)
                config, directory = setup(row['case'], 'helper', provider)
                config['targets'] = [str(directory / 'first'), str(directory / 'second')]
                first = row['first'] = run({**config, 'injectNativeError': 'EINVAL'})
                published = events(first, 'published')
                check(row, first['exitCode'] == 0 and len(published) == 2, 'explicit EINVAL control must fall back successfully')
                check(row, len(events(first, 'native-entry')) == 1, 'unsupported disables remaining same-process native attempts')
                check(row, all(item['atomic'] == 'unsupported' and item['result']['method'] == 'exclusive-copy-fallback' for item in published), 'unsupported must be observable and retain fallback classification')
                restart = row['restart'] = run({**config, 'targets': [str(directory / 'third')]})
                check(row, restart['exitCode'] == 0 and len(events(restart, 'native-entry')) == 0, 'same-build unsupported persists across restart')
                check(row, bool(event(restart, 'startup') and event(restart, 'startup')['atomic'] == 'unsupported'), 'startup consumer sees persisted unsupported')
                upgrade = row['upgrade'] = run({**config, 'targets': [str(directory / 'fourth')], 'versionFixture': version_b})
                entry = event(upgrade, 'native-entry'); start = event(upgrade, 'startup'); done = event(upgrade, 'done')
                check(row, upgrade['exitCode'] == 0 and bool(entry and entry['state'] and entry['state']['value']['state'] == 'trying'), 'changed build must allow one new protected real native attempt')
                check(row, bool(start and start['atomic'] == 'untried' and done and done['atomic'] == 'available'), 'new build transitions untried to available')
                finish(row)
        for name in ('dsh-attachment-local', 'dsh-session-persistence-jsonl'):
            assert digest(Path(inputs[name]['path']).read_bytes()) == inputs[name]['sha256']
    result = {'passed': sum(row['passed'] for row in rows), 'failed': sum(not row['passed'] for row in rows), 'skipped': 0}
    report = {'schema': 1, 'inputs': inputs, 'mode': args.mode, 'scope': 'Actual locked DSH entry bootstrap + production unified preload + real providers before CLI main; Linux real SIGKILL/native rename. Not complete App/HTTP/target ABI/seccomp/power-loss proof.',
              'parentCreatesFuseState': False, 'parentSuppliesReceipt': False,
              'parentRecoversOrDeletesTempBeforeAssertions': False,
              'versionFixtures': {'getter': 'getSystemBuildIdentity', 'A': version_a, 'B': version_b, 'source': 'explicit test-only native member wrapper, not a production environment override'},
              'result': result, 'rows': rows}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    return 0 if not result['failed'] else 1

if __name__ == '__main__': raise SystemExit(main())
