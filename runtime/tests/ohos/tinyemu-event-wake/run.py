#!/usr/bin/env python3
"""Finite OH event-wake native tests, with exact fresh/reused build admission."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys


HERE = Path(__file__).resolve().parent
SOURCE_SHA = 'be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555'
C_NAMES = ['virtio', 'pci', 'fs', 'cutils', 'iomem', 'simplefb', 'json', 'machine',
           'temu', 'fs_disk', 'riscv_machine', 'softfp']
C_NAMES += ['slirp_' + name for name in
            'bootp ip_icmp mbuf slirp tcp_output cksum ip_input misc socket tcp_subr udp if ip_output sbuf tcp_input tcp_timer'.split()]
C_NAMES += ['riscv_cpu32', 'riscv_cpu64', 'embed-fatal', 'embed-ram', 'fs_export']
OBJECT_NAMES = sorted(name + '.o' for name in [*C_NAMES, 'binding'])
OWNER_WRAPS = ['socketpair', 'shutdown', 'close', 'pthread_join', 'pthread_create',
               'napi_create_reference', 'napi_add_env_cleanup_hook', 'napi_create_async_work',
               'select', 'napi_set_named_property']
FATAL_WRAPS = ['exit', 'abort', '__assert_fail']
REFERENCE_PATHS = [
    'tooling/ohos/research/tinyemu-native/clock-cpu.c',
    'tooling/ohos/research/tinyemu-sleep-micros/sleep-boundary.c',
    'tooling/ohos/research/tinyemu-clint-deadline/timer-boundary.c',
    'tooling/ohos/research/slirp-fasttimo/tcp-wire.c',
    'tooling/ohos/research/tinyemu-native/node-case.mjs',
    'tooling/ohos/research/tinyemu-native/join-fault.c',
    'tooling/ohos/research/tinyemu-native/join-fault.mjs',
    'tooling/ohos/research/tinyemu-native/socket-construction.mjs',
    'runtime/ohos/linux/native-session.mjs',
    'runtime/ohos/sim/preload.mjs',
    'runtime/ohos/sim/marker.mjs',
]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def files(root, suffixes=None):
    return {str(path.relative_to(root)): sha(path) for path in sorted(root.rglob('*'))
            if path.is_file() and '__pycache__' not in path.parts
            and (suffixes is None or path.suffix in suffixes)}


def read(path):
    return json.loads(Path(path).read_text())


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


class Driver:
    def __init__(self, args):
        self.args = args
        self.source = args.source.resolve()
        self.native = self.source / 'runtime/ohos/linux/native'
        self.out = args.out.resolve()
        self.out.mkdir(parents=True, exist_ok=False)
        self.cc, self.node = args.cc.resolve(), args.node.resolve()
        self.headers = args.node_headers.resolve()
        self.rows = []
        self.report = {'schema': 1, 'status': 'RUNNING', 'startedUTC': utc(), 'commands': [],
                       'scope': 'OH-only actual host C/Node native short tests; explicit link/clock/transport boundaries; no Linux kernel, SDK, device or performance claim',
                       'checks': self.rows}
        self.base_env = {key: value for key, value in os.environ.items() if key != 'DSH_TEST_OWNER_FAULT'}
        self.base_env['UV_THREADPOOL_SIZE'] = '1'
        self.save()

    def save(self):
        (self.out / 'RUN.json').write_text(json.dumps(self.report, indent=2) + '\n')
        text = ['TAP version 13']
        for number, row in enumerate(self.rows, 1):
            label = re.sub(r'[\r\n]+', ' ', row['name'])
            text.append(('ok ' if row['passed'] else 'not ok ') + str(number) + ' - ' + label)
        passed = sum(row['passed'] is True for row in self.rows)
        text += [f'1..{len(self.rows)}', f'# tests {len(self.rows)}', f'# pass {passed}',
                 f'# fail {len(self.rows) - passed}', '# cancelled 0', '# skipped 0', '# todo 0']
        (self.out / 'test.log').write_text('\n'.join(text) + '\n')

    def check(self, name, passed, **facts):
        self.rows.append({'name': name, 'passed': bool(passed), **facts})
        self.save()
        assert passed, name

    def command(self, name, argv, *, env=None, timeout=30):
        argv = list(map(str, argv))
        try:
            result = subprocess.run(argv, capture_output=True, timeout=timeout,
                                    env={**self.base_env, **(env or {})})
            code, stdout, stderr = result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired as error:
            code, stdout, stderr = None, error.stdout or b'', error.stderr or b''
        for suffix, data in [('stdout', stdout), ('stderr', stderr)]:
            (self.out / (name + '.' + suffix)).write_bytes(data)
        self.report['commands'].append({'name': name, 'argv': argv, 'exitCode': code,
            'environmentOverrides': env or {}, 'timeoutSeconds': timeout,
            'stdoutSHA256': hashlib.sha256(stdout).hexdigest(), 'stderrSHA256': hashlib.sha256(stderr).hexdigest()})
        self.save()
        assert code == 0, (name, code, stderr.decode(errors='replace')[-2500:])
        return stdout, stderr

    def admit(self):
        a = self.args
        assert bool(a.reuse_native_build) == bool(a.reuse_native_inputs), 'reuse arguments must be paired'
        assert sha(a.source_archive) == SOURCE_SHA
        self.native_inputs = files(self.native)
        lock = read(self.native / 'source-lock.json')
        assert lock['archiveSha256'] == SOURCE_SHA
        assert all(self.native_inputs.get(name) == digest for name, digest in lock['files'].items())
        assert 'patches/0023-embedded-event-wait.patch' in lock['files']
        self.header_inputs = files(self.headers)
        (self.out / 'NODE-HEADERS-BEFORE.json').write_text(json.dumps(self.header_inputs, indent=2) + '\n')
        watched = [HERE / name for name in ['run.py', 'component.py', 'wake-call.c', 'wake-boundary.c',
                   'wake-loop-bridge.c', 'slirp-deadline.c', 'owner-fault.c', 'owner-case.mjs',
                   'lifecycle-case.mjs', 'adoption-case.mjs', 'idle-wfi.mjs']]
        watched += [self.source / path for path in REFERENCE_PATHS]
        watched += [a.source_archive.resolve(), self.cc, self.node]
        watched += [self.native / name for name in self.native_inputs]
        self.watched = {str(path): sha(path) for path in watched}
        self.report['inputsBefore'] = self.watched
        self.save()

        receipt_paths = []
        if a.reuse_native_build:
            self.build = a.reuse_native_build.resolve()
            receipt_dir = a.reuse_native_inputs.resolve().parent
            receipt = read(a.reuse_native_inputs)
            assert receipt['files'] == self.native_inputs, 'reused native input tree differs from selected source'
            assert receipt['count'] == len(self.native_inputs)
            names = ['NATIVE-INPUTS.json', 'SOURCE-LOCK.json', 'GENERATED-C-H.json', 'OBJECTS.json',
                     'COMPILER.json', 'NODE-HEADERS.json', 'RESULT.json', 'BUILD-COMMAND.json']
            assert a.reuse_native_inputs.resolve() == receipt_dir / 'NATIVE-INPUTS.json'
            receipt_paths = [receipt_dir / name for name in names]
            snapshots = {name: read(receipt_dir / name) for name in names}
            assert snapshots['SOURCE-LOCK.json'] == lock
            assert snapshots['NODE-HEADERS.json']['files'] == self.header_inputs
            assert snapshots['COMPILER.json']['sha256'] == sha(self.cc), 'compiler identity differs: use a fresh build'
            assert snapshots['BUILD-COMMAND.json']['exitCode'] == 0
            assert snapshots['RESULT.json']['status'] == 'FRESH_HOST_NATIVE_BUILD_SOURCE_VERIFIED'
        else:
            self.build = self.out / 'native'
            self.command('fresh-native-build', [sys.executable, '-I', '-B', self.native / 'build.py',
                         '--source-archive', a.source_archive.resolve(), '--node-headers', self.headers,
                         '--output', self.build, '--cc', self.cc, '--host-test'], timeout=240)
            snapshots = None

        build_receipt = read(self.build / 'BUILD.json')
        assert build_receipt['scope'] == 'HOST_TEST_ONLY'
        assert build_receipt['sourceSha256'] == SOURCE_SHA
        assert build_receipt['sources'] == self.native_inputs
        assert files(self.native) == self.native_inputs
        assert files(self.headers) == self.header_inputs
        commands = build_receipt['commands']
        assert commands and all(row['code'] == 0 for row in commands)
        assert read(self.build / 'commands.json') == commands
        self.generated = self.build / 'tinyemu-2019-12-21'
        generated = files(self.generated, {'.c', '.h'})
        assert len(generated) == 89
        assert generated['temu_embed.h'] == self.native_inputs['temu_embed.h']
        actual_objects = {path.name: sha(path) for path in self.build.glob('*.o')}
        assert sorted(actual_objects) == OBJECT_NAMES
        self.library = self.build / 'libdsh_linux.so'
        assert build_receipt['librarySha256'] == sha(self.library)

        patches = [Path(row['argv'][-1]).name for row in commands if row['argv'][0] == 'patch']
        assert patches == sorted(path.name for path in (self.native / 'patches').glob('*.patch'))
        compile_rows = [row for row in commands if '-c' in row['argv']]
        assert len(compile_rows) == 34
        compiled = {}
        for row in compile_rows:
            argv = row['argv']
            assert Path(argv[0]).resolve() == self.cc
            output = Path(argv[argv.index('-o') + 1]).resolve()
            source = Path(argv[argv.index('-c') + 1]).resolve()
            assert output.parent == self.build and output.name not in compiled
            assert output.name in actual_objects
            if source.is_relative_to(self.generated):
                assert sha(source) == generated[str(source.relative_to(self.generated))]
            else:
                # A reused build may have compiled the identical selected native
                # inputs under its original private root; record that exact path.
                assert source.name in self.native_inputs and sha(source) == self.native_inputs[source.name]
            compiled[output.name] = {'source': str(source), 'sourceSHA256': sha(source),
                                     'objectSHA256': actual_objects[output.name]}
        assert sorted(compiled) == OBJECT_NAMES
        linked = [row for row in commands if '-shared' in row['argv']]
        assert len(linked) == 1
        argv = linked[0]['argv']
        assert Path(argv[0]).resolve() == self.cc
        assert Path(argv[argv.index('-o') + 1]).resolve() == self.library
        assert sorted(Path(value).name for value in argv if value.endswith('.o')) == OBJECT_NAMES
        assert all(Path(value).resolve().parent == self.build for value in argv if value.endswith('.o'))
        assert len(commands) == len(patches) + 34 + 1
        if snapshots:
            assert snapshots['GENERATED-C-H.json'] == generated
            assert snapshots['OBJECTS.json'] == actual_objects
            final = snapshots['RESULT.json']
            assert final['librarySha256'] == sha(self.library)
            assert final['buildJsonSha256'] == sha(self.build / 'BUILD.json')
            assert final['commandsJsonSha256'] == sha(self.build / 'commands.json')
            assert final['nativeInputsSha256'] == sha(a.reuse_native_inputs)
            assert final['sourceLockSha256'] == sha(self.native / 'source-lock.json')
        self.objects = [self.build / name for name in OBJECT_NAMES]
        receipt_paths += [self.build / 'BUILD.json', self.build / 'commands.json']
        self.watched.update({str(path): sha(path) for path in receipt_paths})
        self.watched.update({str(self.generated / name): digest for name, digest in generated.items()})
        self.watched.update({str(path): sha(path) for path in [*self.objects, self.library]})
        self.report['admission'] = {'mode': 'reused-exact-native' if snapshots else 'fresh-native',
            'buildDirectory': str(self.build),
            'nativeFiles': len(self.native_inputs), 'lockedNativeFiles': len(lock['files']),
            'generatedCAndH': len(generated), 'objects': len(actual_objects), 'buildCommands': len(commands),
            'librarySHA256': sha(self.library), 'buildReceiptSHA256': sha(self.build / 'BUILD.json'),
            'sourceLockSHA256': sha(self.native / 'source-lock.json'), 'compiled': compiled,
            'nodeHeaderFiles': len(self.header_inputs), 'nodeHeadersBeforeSHA256': sha(self.out / 'NODE-HEADERS-BEFORE.json'),
            'toolchainPolicy': 'Identity locks this execution/reuse only; no exact compiler or Node patch-version assertion in this driver'}
        self.report['inputsBefore'] = dict(self.watched)
        self.save()

    def component(self):
        component_out = self.out / 'c-component'
        self.command('c-component', [sys.executable, '-I', '-B', HERE / 'component.py',
            '--generated-source', self.generated, '--native', self.native, '--objects', self.build,
            '--repository', self.source, '--inner-patch', self.native / 'patches/0023-embedded-event-wait.patch',
            '--cc', self.cc, '--out', component_out], timeout=240)
        result = read(component_out / 'RUN.json')
        assert result['status'] == 'PASS_SCOPED_C_COMPONENT'
        assert result['inputsBefore'] == result['inputsAfter']
        assert all(sha(path) == digest for path, digest in result['inputsAfter'].items())
        baseline = [group for group in result['groups'] if group['name'].startswith('slirp-baseline-')]
        candidate = [group for group in result['groups'] if not group['name'].startswith('slirp-baseline-')]
        assert len(baseline) == 10 and sum(group['exitCode'] == 1 for group in baseline) == 1
        assert sum(len(group['rows']) for group in candidate) == 119
        self.report['originalBaseline'] = {'controls': 9, 'expectedFunctionalRed': 1,
            'scope': 'Recorded separately from candidate TAP checks; actual original long-pause TCP behavior',
            'groups': baseline}
        for group in candidate:
            assert group['exitCode'] == 0
            for index, row in enumerate(group['rows']):
                self.check('C/' + group['name'] + '/' + str(index + 1), row.get('passed') is True, facts=row)

    def configs(self):
        fixture = self.out / 'guest-fixture'; fixture.mkdir()
        addi = lambda register, value: ((value & 4095) << 20) | (register << 7) | 0x13
        store = lambda register, offset: (register << 20) | (1 << 15) | (2 << 12) | (offset << 7) | 0x23
        instructions = [0x400080b7, 0x01010137]
        for byte in b'900-BEFORE-POWEROFF\n':
            instructions += [addi(3, byte), store(3, 0), store(2, 4)]
        instructions += [0x10500073, 0xffdff06f]
        bios = b''.join(struct.pack('<I', word) for word in instructions)
        (fixture / 'bios.bin').write_bytes(bios)
        assert bios.count(struct.pack('<I', 0x10500073)) == 1
        (fixture / 'busy.bin').write_bytes(bios.replace(struct.pack('<I', 0x10500073), struct.pack('<I', 0x0000006f)))
        (fixture / 'disk.raw').write_bytes(bytes(32768))
        common = {'version': 1, 'machine': 'riscv64', 'memory_size': 16, 'cmdline': '',
                  'drive0': {'file': str(fixture / 'disk.raw')}}
        self.config = {}
        for name, file in [('normal', 'bios.bin'), ('busy', 'busy.bin'), ('failed', 'deliberately-missing.bin')]:
            path = fixture / (name + '.json')
            path.write_text(json.dumps({**common, 'bios': str(fixture / file)}) + '\n')
            self.config[name] = path
        self.report['guestFixture'] = {'scope': 'Small actual RISC-V BIOS instruction fixture, not Linux kernel',
                                      'filesBefore': files(fixture)}
        self.save()

    def owner(self):
        target = self.out / 'owner-fixture'; target.mkdir()
        fault, library = target / 'fault.o', target / 'libdsh_linux.so'
        declared = set(re.findall(r'\b__wrap_([A-Za-z0-9_]+)\s*\(', (HERE / 'owner-fault.c').read_text()))
        assert declared == set(OWNER_WRAPS), 'fixture wrappers must match the explicit complete link contract'
        self.command('owner-fixture-compile', [self.cc, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
            '-fPIC', '-pthread', '-I', self.headers, '-c', HERE / 'owner-fault.c', '-o', fault])
        self.command('owner-fixture-link', [self.cc, '-shared', '-Wl,-z,nodelete',
            *['-Wl,--wrap=' + name for name in FATAL_WRAPS + OWNER_WRAPS], *self.objects, fault,
            '-pthread', '-lm', '-o', library])
        modes = ['normal', 'notify-eio', 'notify-eintr', 'peer-close', 'reader-close', 'writer-close',
                 'writer-reuse', 'join-esrch', 'work-cancelled', 'reference-fail', 'second-pair',
                 'create-eagain', 'hook-fail', 'rollback-close', 'already-returned', 'notify-reader-race']
        for mode in modes:
            config = self.config['failed' if mode == 'already-returned' else 'busy' if mode == 'notify-reader-race' else 'normal']
            stdout, stderr = self.command('owner-' + mode, [self.node, HERE / 'owner-case.mjs', library, config, mode],
                                           env={'DSH_TEST_OWNER_FAULT': mode}, timeout=12)
            result = json.loads(stdout)
            raw = [line[len('OWNER_FACTS '):] for line in stderr.decode().splitlines() if line.startswith('OWNER_FACTS ')]
            assert len(raw) == 1
            facts = json.loads(raw[0])
            if mode.startswith('notify-e'):
                assert facts['notifications'] == 1 and facts['joins'] == 0 and facts['workCalls'] == 0
            elif mode == 'rollback-close':
                assert facts['joins'] == 0 and facts['notifications'] == 0 and facts['creates'] == 1
            elif mode == 'work-cancelled':
                assert facts['joins'] == 0 and facts['workCalls'] == 1
            else:
                assert facts['joins'] == 1
            if mode == 'already-returned':
                assert facts['notifications'] == 0 and facts['bodyReturned'] == 1
            if mode == 'writer-reuse':
                assert facts['reuseUnaffected'] == facts['writeCloses'] == facts['notifications'] == 1
            if mode == 'notify-reader-race':
                assert facts['protectedReader'] == facts['readCloses'] == 1
            self.check('Owner/' + mode, True, result=result, linkFacts=facts)
        for mode in ['gc-success', 'gc-notify-failure', 'worker-cleanup']:
            fault_mode = 'notify-eio' if mode == 'gc-notify-failure' else 'normal'
            stdout, _ = self.command('lifecycle-' + mode, [self.node, '--expose-gc', HERE / 'lifecycle-case.mjs',
                library, self.config['normal'], mode], env={'DSH_TEST_OWNER_FAULT': fault_mode}, timeout=12)
            self.check('Lifecycle/' + mode, True, result=json.loads(stdout))
        for mode in ['reference-fail', 'notify-eio']:
            for close_failure in ['no', 'yes']:
                stdout, _ = self.command('adoption-' + mode + '-' + close_failure, [self.node, HERE / 'adoption-case.mjs',
                    target, self.config['normal'], self.source / 'runtime/ohos/linux/native-session.mjs', mode, close_failure],
                    env={'DSH_TEST_OWNER_FAULT': mode}, timeout=12)
                self.check('Adoption/' + mode + '/' + close_failure, True, result=json.loads(stdout))
        self.report['faultLibrary'] = {'sha256': sha(library), 'fixtureObjectSHA256': sha(fault),
            'wraps': FATAL_WRAPS + OWNER_WRAPS, 'scope': 'Test-only relink of admitted 34 actual product objects; production library unchanged'}

    def regressions(self):
        research = self.source / 'tooling/ohos/research/tinyemu-native'
        for mode in ['plain', 'strict']:
            for case in ['normal', 'unread-output']:
                arguments = [self.node]
                if mode == 'strict':
                    arguments += ['--jitless', '--import', self.source / 'runtime/ohos/sim/preload.mjs']
                arguments += [research / 'node-case.mjs', self.build, self.config['normal'], case]
                stdout, _ = self.command('original-node-' + mode + '-' + case, arguments,
                    env={'DSH_GO_OHOS_SIM_ADDONS': json.dumps([str(self.library)])}, timeout=12)
                self.check('OriginalNode/' + mode + '/' + case, True, result=json.loads(stdout))
        for mode in [1, 2, 3]:
            target = self.out / ('original-join-' + str(mode)); target.mkdir()
            obj, library = target / 'fault.o', target / 'libdsh_linux.so'
            self.command('original-join-compile-' + str(mode), [self.cc, '-O2', '-fPIC', '-DFAULT_MODE=' + str(mode),
                '-I', self.headers, '-c', research / 'join-fault.c', '-o', obj])
            wraps = FATAL_WRAPS + ['napi_create_reference', 'pthread_join', 'napi_create_async_work']
            self.command('original-join-link-' + str(mode), [self.cc, '-shared', '-Wl,-z,nodelete',
                *['-Wl,--wrap=' + name for name in wraps], *self.objects, obj, '-lm', '-pthread', '-o', library])
            stdout, _ = self.command('original-join-' + str(mode), [self.node, research / 'join-fault.mjs',
                target, self.config['normal'], mode], timeout=12)
            self.check('OriginalJoin/' + str(mode), True, result=json.loads(stdout))
        for mode in ['no', 'yes']:
            stdout, _ = self.command('original-socket-' + mode, [self.node, research / 'socket-construction.mjs',
                self.build, self.config['normal'], mode, self.source / 'runtime/ohos/linux/native-session.mjs'], timeout=12)
            self.check('OriginalSocket/' + mode, True, result=json.loads(stdout))

    def execute(self):
        try:
            self.admit()
            self.component()
            self.configs()
            self.owner()
            self.regressions()
            after = {path: sha(path) for path in self.watched}
            self.report['inputsAfter'] = after
            assert after == self.watched
            headers_after = files(self.headers)
            (self.out / 'NODE-HEADERS-AFTER.json').write_text(json.dumps(headers_after, indent=2) + '\n')
            assert headers_after == self.header_inputs
            self.report['nodeHeadersAfterSHA256'] = sha(self.out / 'NODE-HEADERS-AFTER.json')
            assert len(self.rows) == 151 and all(row['passed'] for row in self.rows)
            self.report.update(status='PASS_SCOPED_EVENT_WAKE_NATIVE', endedUTC=utc(),
                totals={'C': 119, 'owner': 16, 'lifecycle': 3, 'adoption': 4, 'originalNode': 4, 'originalJoin': 3, 'originalSocket': 2},
                candidateChecks=151, SDKDevice='NOT_RUN', LinuxGuest='SEPARATE_EVIDENCE_NOT_REPEATED')
            self.save()
            print((self.out / 'test.log').read_text(), end='')
            return 0
        except Exception as error:
            self.report.update(status='FAILED', endedUTC=utc(), failure=repr(error))
            self.rows.append({'name': 'driver admission/execution failure', 'passed': False, 'error': repr(error)})
            self.save()
            print((self.out / 'test.log').read_text(), end='')
            print(repr(error), file=sys.stderr)
            return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--source-archive', type=Path, required=True)
    parser.add_argument('--node-headers', type=Path, required=True)
    parser.add_argument('--cc', type=Path, required=True)
    parser.add_argument('--node', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--reuse-native-build', type=Path)
    parser.add_argument('--reuse-native-inputs', type=Path)
    return Driver(parser.parse_args()).execute()


if __name__ == '__main__':
    sys.exit(main())
