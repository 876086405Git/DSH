#!/usr/bin/env python3
"""Actual startup close sites and Owner/Control; reuse a verified native build."""
import argparse, datetime, hashlib, json, os, re, struct, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ap = argparse.ArgumentParser()
for key in ['source', 'node', 'cc', 'publication', 'out']:
    ap.add_argument('--' + key, type=Path, required=True)
ap.add_argument('--native-run', type=Path)
ap.add_argument('--native-build', type=Path)
ap.add_argument('--native-source', type=Path)
ap.add_argument('--expect-baseline', action='store_true')
a = ap.parse_args(); source = a.source.resolve(); out = a.out.resolve()
out.mkdir(parents=True, exist_ok=False)
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
read = lambda p: json.loads(Path(p).read_text())
report = {'startedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'status': 'RUNNING', 'commands': [], 'rows': [], 'expectedBaseline': a.expect_baseline,
          'scope': 'Actual native startup/thread/join and actual Owner/Control/files/native flock; explicit private configuration and syscall link faults; no guest CPU dispatch, SDK/device or full gate'}
def save():
    (out / 'RUN.json').write_text(json.dumps(report, indent=2) + '\n')
save()
environment = {k: v for k, v in os.environ.items() if k not in {'NODE_OPTIONS', 'NODE_PATH', 'LD_PRELOAD'}
               and not k.startswith(('OHOS_', 'DSH_', 'M3_', 'M4_', 'M6_'))}
environment['UV_THREADPOOL_SIZE'] = '1'

def command(name, argv, overrides=None, expected=0):
    argv = list(map(str, argv)); overrides = overrides or {}
    row = {'name': name, 'argv': argv, 'cwd': str(source), 'environmentOverrides': overrides,
           'startedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    report['commands'].append(row); save()
    try:
        r = subprocess.run(argv, cwd=source, env=environment | overrides, capture_output=True, timeout=15)
        code, stdout, stderr = r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired as e:
        code, stdout, stderr = None, e.stdout or b'', e.stderr or b''
    (out / (name + '.stdout')).write_bytes(stdout); (out / (name + '.stderr')).write_bytes(stderr)
    row.update(exitCode=code, expectedExitCode=expected,
               stdoutSHA256=hashlib.sha256(stdout).hexdigest(), stderrSHA256=hashlib.sha256(stderr).hexdigest())
    save(); assert code == expected, (name, code, expected, stderr.decode(errors='replace')[-1800:])
    return stdout.decode(), stderr.decode()

if a.native_run:
    assert not a.native_build and not a.native_source
    native_run = read(a.native_run)
    assert native_run['status'].startswith('PASS_SCOPED')
    assert native_run['inputsBefore'] == native_run['inputsAfter']
    for name, digest in native_run['inputsAfter'].items(): assert sha(name) == digest, name
    build = Path(native_run['admission']['buildDirectory'])
    native_source = source / 'runtime/ohos/linux/native'
    report['nativeRun'] = {'path': str(a.native_run.resolve()), 'sha256': sha(a.native_run),
                           'status': native_run['status']}
else:
    assert a.native_build and a.native_source, 'explicit baseline/recheck requires both build and source'
    build = a.native_build.resolve(); native_source = a.native_source.resolve()

receipt = read(build / 'BUILD.json'); assert receipt['scope'] == 'HOST_TEST_ONLY'
assert receipt['commands'] == read(build / 'commands.json')
assert all(row['code'] == 0 for row in receipt['commands'])
native_inputs = {str(p.relative_to(native_source)): sha(p) for p in native_source.rglob('*') if p.is_file()}
assert native_inputs == receipt['sources']
lock = read(native_source / 'source-lock.json')
assert all(native_inputs[name] == digest for name, digest in lock['files'].items())
assert sha(build / 'libdsh_linux.so') == receipt['librarySha256']
link = list(receipt['commands'][-1]['argv'])
objects = [Path(v) for v in link if v.endswith('.o')]; assert len(objects) == 34
assert all(p.parent == build for p in objects)
assert Path(link[0]).resolve() == a.cc.resolve()
watched = [*objects, build / 'BUILD.json', build / 'commands.json', build / 'libdsh_linux.so',
           a.node.resolve(), a.cc.resolve(), a.publication.resolve(), *HERE.glob('*.py'),
           *HERE.glob('*.mjs'), *HERE.glob('*.c')]
watched += [native_source / name for name in native_inputs]
watched += [source / 'runtime/ohos/linux' / n for n in ['owner.mjs', 'backend.mjs', 'control.mjs',
            'instance.mjs', 'native-session.mjs', 'controller.mjs', 'streams.mjs', 'base-download.mjs',
            'prepare-images.mjs', 'host-paths.mjs', 'proxy.mjs', 'job-diagnostics.mjs']]
watched += [source / 'runtime/tests/ohos/linux-control-fixture.mjs']
before = {str(p): sha(p) for p in watched}; report['inputsBefore'] = before
report['nativeBuild'] = {'path': str(build), 'receiptSha256': sha(build / 'BUILD.json'),
                        'productLibrarySha256': receipt['librarySha256'], 'objects': {p.name: sha(p) for p in objects},
                        'sourceFiles': len(native_inputs), 'productionCompiles': 0}
save()
seam = out / 'close-fault.o'; library_dir = out / 'native'; library_dir.mkdir()
library = library_dir / 'libdsh_linux.so'
command('compile-seam', [a.cc.resolve(), '-O2', '-g0', '-std=c11', '-fPIC', '-Wall', '-Wextra',
                         '-Werror', '-c', HERE / 'close-fault.c', '-o', seam])
link[link.index('-o') + 1] = str(library)
link[link.index('-pthread'):link.index('-pthread')] = [str(seam), '-Wl,--wrap=fclose',
                                                     '-Wl,--wrap=fseek', '-Wl,--wrap=ftello64']
command('link-seam', link)
report['testLibrary'] = {'sha256': sha(library), 'fixtureObjectSha256': sha(seam),
                         'fixtureCompiles': 1, 'links': 1}
fixture = out / 'fixtures'; fixture.mkdir()
bios = fixture / 'bios.bin'; bios.write_bytes(struct.pack('<II', 0x10500073, 0xffdff06f))

def capture(name, stdout, stderr, fault, kind):
    combined = stdout + '\n' + stderr
    close = [json.loads(line.split('STARTUP_CLOSE ', 1)[1]) for line in combined.splitlines()
             if 'STARTUP_CLOSE {' in line]
    assert len(close) == 1, (name, close)
    fact = close[0]; assert fact['fault'] == (fault == 'retain-eio')
    assert fact['live'] == (fault == 'retain-eio')
    assert fact['returned'] == (-1 if fault == 'retain-eio' else 0)
    observations = [json.loads(line.split(kind + ' ', 1)[1]) for line in combined.splitlines()
                    if kind + ' {' in line]
    assert len(observations) == 1
    report['rows'].append({'name': name, 'fault': fault, 'nativeClose': fact,
                           'observation': observations[0],
                           'outcome': 'EXPECTED_OLD_RED' if a.expect_baseline and fault == 'retain-eio' else 'PASS'})
    save(); print(name, report['rows'][-1]['outcome'], flush=True)

for flags, mode in [([], 'plain'), (['--jitless'], 'jitless')]:
    for site in ['drive', 'seek', 'tell']:
        for fault in ['control', 'retain-eio']:
            name = mode + '-' + site + '-' + fault; case = fixture / name; case.mkdir()
            prior = case / 'prior.raw'; disk = case / 'target.raw'
            prior.write_bytes(bytes(4096)); disk.write_bytes(bytes(4096))
            config = {'version': 1, 'machine': 'riscv64', 'memory_size': 16, 'bios': str(bios), 'cmdline': '',
                      'drive0': {'file': str(prior)}, 'drive1': {'file': str(disk)},
                      'drive2': {'file': str(case / 'missing.raw')}}
            path = case / 'config.json'; path.write_text(json.dumps(config) + '\n')
            overrides = {'DSH_TEST_STARTUP_DISK': str(disk), 'DSH_TEST_STARTUP_SITE': site,
                         'DSH_TEST_STARTUP_CLOSE': fault}
            stdout, stderr = command(name, [a.node.resolve(), *flags, HERE / 'native-case.mjs', library,
                                           path, disk, fault, prior], overrides,
                                     1 if a.expect_baseline and fault == 'retain-eio' else 0)
            if site != 'drive': assert ('STARTUP_SITE ' + site) in stderr
            capture(name, stdout, stderr, fault, 'STARTUP_NATIVE')
    for fault in ['control', 'retain-eio']:
        name = mode + '-owner-' + fault
        overrides = {'LD_PRELOAD': str(a.publication.resolve()), 'DSH_TEST_STARTUP_CLOSE': fault,
                     'DSH_TEST_STARTUP_NATIVE': str(library_dir)}
        stdout, stderr = command(name, [a.node.resolve(), *flags, '--test', '--test-reporter=tap',
                                       HERE / 'owner-case.mjs'], overrides,
                                 1 if a.expect_baseline and fault == 'retain-eio' else 0)
        capture(name, stdout, stderr, fault, 'STARTUP_OWNER')

case = fixture / 'partial-setup'; case.mkdir()
disk = case / 'disk.raw'; disk.write_bytes(bytes(4096))
path = case / 'config.json'
path.write_text(json.dumps({'version': 1, 'machine': 'riscv64', 'memory_size': 16,
    'bios': str(bios), 'cmdline': '', 'drive0': {'file': str(disk)},
    'fs0': {'tag': 'dsh0', 'file': str(case / 'missing-root')}}) + '\n')
stdout, _ = command('jitless-partial-setup', [a.node.resolve(), '--jitless', HERE / 'partial-start.mjs',
                     build / 'libdsh_linux.so', path, disk])
partial = json.loads(stdout)
assert partial['result']['apiResult'] == -2 and partial['result']['retirementError'] is None
assert partial['result']['fdRetirement']['retired'] is True and len(partial['openDrives']) == 1
report['rows'].append({'name': 'jitless-partial-setup', 'outcome': 'PASS', 'observation': partial,
                       'fault': 'No syscall injection: real missing fs root after actual drive open'})
after = {str(p): sha(p) for p in watched}; assert after == before
report['inputsAfter'] = after
report['status'] = 'BASELINE_RED_OBSERVED' if a.expect_baseline else 'PASS_SCOPED_STARTUP_CLOSE'
report['finishedUTC'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
assert len(report['rows']) == 17
save()
lines = ['TAP version 13'] + ['ok ' + str(i + 1) + ' - ' + row['name'] for i, row in enumerate(report['rows'])]
lines += ['1..17', '# tests 17', '# pass 17', '# fail 0', '# cancelled 0', '# skipped 0', '# todo 0']
if not a.expect_baseline: (out / 'test.log').write_text('\n'.join(lines) + '\n')
