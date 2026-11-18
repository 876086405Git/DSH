#!/usr/bin/env python3
"""Linux observer of real provider reads; does not replace Node filesystem APIs."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import tempfile
import time

p = argparse.ArgumentParser()
for name in ('node', 'prefix', 'publication-preload', 'linked', 'simulation', 'marker', 'out'):
    p.add_argument('--' + name, required=True, type=Path)
a = p.parse_args()
for name, value in vars(a).items():
    setattr(a, name, value.resolve())
a.out.parent.mkdir(parents=True, exist_ok=True)
actor = Path(__file__).with_name('publication-scanner-actor.mjs')
lib = ctypes.CDLL(None, use_errno=True)
lib.inotify_init1.argtypes = [ctypes.c_int]
lib.inotify_init1.restype = ctypes.c_int
lib.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
lib.inotify_add_watch.restype = ctypes.c_int
OPEN, ACCESS, OVERFLOW, IGNORED = 0x20, 0x01, 0x4000, 0x8000


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def receive(process, expected):
    if not select.select([process.stdout], [], [], 20)[0]:
        raise TimeoutError('actor phase deadline: ' + expected)
    line = process.stdout.readline()
    if not line:
        raise RuntimeError('actor exited before phase ' + expected)
    value = json.loads(line)
    if value.get('stage') != expected:
        raise AssertionError((expected, value))
    return value


def send(process, text):
    process.stdin.write(text + '\n')
    process.stdin.flush()


def drain(fd, watches):
    events = []
    while True:
        try:
            data = os.read(fd, 65536)
        except BlockingIOError:
            break
        offset = 0
        while offset < len(data):
            wd, mask, cookie, size = struct.unpack_from('iIII', data, offset)
            offset += 16 + size
            if mask & (OVERFLOW | IGNORED):
                raise AssertionError({'observationInvalid': True, 'wd': wd, 'mask': mask})
            if wd not in watches:
                raise AssertionError({'unknownWatch': wd, 'mask': mask})
            events.append({'wd': wd, 'mask': mask, 'open': bool(mask & OPEN), 'access': bool(mask & ACCESS)})
    return events


providers = [a.prefix / 'node_modules/@deepseek-ai' / name / 'lib/index.js'
             for name in ('dsh-session-persistence-jsonl', 'dsh-attachment-local')]
publication_dependencies = [a.publication_preload.parent / name for name in ('index.mjs', 'atomic.mjs', 'ledger.mjs')]
inputs = [a.node, a.publication_preload, *publication_dependencies, a.linked, a.simulation, a.marker, actor, Path(__file__), *providers]
input_hashes = {str(path): digest(path) for path in inputs}
rows = []
for mode in ('jit', 'strict'):
    for scenario in ('session-none', 'session-zstd', 'attachment-files'):
        name = mode + '-' + scenario
        stderr_path = a.out.parent / (a.out.stem + '-' + name + '.stderr')
        row = {'mode': mode, 'scenario': scenario, 'status': 'FAIL', 'stderr': str(stderr_path)}
        with tempfile.TemporaryDirectory(prefix='scanner-' + name + '-', dir=a.out.parent) as temp:
            home = Path(temp) / 'home'
            home.mkdir(mode=0o700)
            env = {k: v for k, v in os.environ.items() if k not in {
                'NODE_OPTIONS', 'LD_PRELOAD', 'DSH_GO_OHOS_SIM', 'DSH_GO_OHOS_SIM_PLATFORM',
                'DSH_GO_OHOS_SIM_ADDONS', 'DSH_HOME', 'DSH_TEST_PREFIX', 'DSH_SCANNER_STRICT'}}
            env.update(DSH_HOME=str(home), DSH_TEST_PREFIX=str(a.prefix), LD_PRELOAD=str(a.linked),
                       DSH_SCANNER_STRICT='1' if mode == 'strict' else '0')
            flags = ['--jitless', '--import', str(a.simulation)] if mode == 'strict' else ['--import', str(a.marker)]
            if mode == 'strict':
                env.update(DSH_GO_OHOS_SIM_PLATFORM='openharmony', DSH_GO_OHOS_SIM_ADDONS='[]')
            argv = [str(a.node), *flags, '--import', str(a.publication_preload), str(actor), scenario]
            row['argv'] = argv
            row['environment'] = {key: env[key] for key in ('DSH_HOME', 'DSH_TEST_PREFIX', 'LD_PRELOAD', 'DSH_SCANNER_STRICT')}
            fd, process = -1, None
            start = time.monotonic()
            with stderr_path.open('w') as stderr:
                try:
                    process = subprocess.Popen(argv, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                               stderr=stderr, text=True, bufsize=1)
                    ready = receive(process, 'ready')
                    row['ready'] = ready
                    fd = lib.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
                    if fd < 0:
                        raise OSError(ctypes.get_errno(), 'inotify_init1')
                    watches = {}
                    for item in ready['watched']:
                        wd = lib.inotify_add_watch(fd, os.fsencode(item['path']), OPEN | ACCESS)
                        if wd < 0:
                            raise OSError(ctypes.get_errno(), 'inotify_add_watch: ' + item['path'])
                        if wd in watches:
                            raise AssertionError('duplicate watched inode: observation would be ambiguous')
                        watches[wd] = item
                    assert drain(fd, watches) == [], 'events before controlled scan'
                    send(process, 'scan')
                    row['scan'] = receive(process, 'scanned')
                    scan_events = drain(fd, watches)
                    row['scanEvents'] = scan_events
                    for wd, item in watches.items():
                        events = [e for e in scan_events if e['wd'] == wd]
                        if item['kind'] == 'orphan':
                            assert not any(e['open'] or e['access'] for e in events), (item, events)
                        else:
                            assert any(e['open'] for e in events), ('no canonical OPEN control', item)
                            assert any(e['access'] for e in events), ('no canonical ACCESS control', item)
                    send(process, 'positive')
                    row['positive'] = receive(process, 'positive')
                    positive_events = drain(fd, watches)
                    row['positiveEvents'] = positive_events
                    for wd, item in watches.items():
                        if item['kind'] != 'orphan':
                            continue
                        events = [e for e in positive_events if e['wd'] == wd]
                        assert any(e['open'] for e in events), ('orphan watch failed positive OPEN', item)
                        if item['bytes']:
                            assert any(e['access'] for e in events), ('orphan watch failed positive ACCESS', item)
                    # Observation ends before semantic restoration and cleanup,
                    # which intentionally move/delete the test-owned files.
                    os.close(fd)
                    fd = -1
                    send(process, 'controls')
                    row['controls'] = receive(process, 'done')
                    process.stdin.close()
                    row['exitCode'] = process.wait(timeout=20)
                    assert row['exitCode'] == 0
                    row['status'] = 'PASS'
                except Exception as error:
                    row['error'] = {'type': type(error).__name__, 'message': str(error)}
                finally:
                    if fd >= 0:
                        os.close(fd)
                    if process is not None and process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
                    row['elapsedSeconds'] = time.monotonic() - start
        rows.append(row)
        print(json.dumps({'case': name, 'status': row['status'], 'error': row.get('error')}), flush=True)
report = {'scope': 'Linux inotify inode-event observations of unmodified real providers; not OHOS or all DSH consumers',
          'eventCounting': 'presence only; events may coalesce; overflow, ignored or failed watches invalidate observation',
          'nodeInputsSHA256': input_hashes, 'allInputsUnchanged': all(digest(path) == input_hashes[str(path)] for path in inputs),
          'providersUnchanged': all(digest(path) == input_hashes[str(path)] for path in providers),
          'pass': sum(r['status'] == 'PASS' for r in rows), 'fail': sum(r['status'] != 'PASS' for r in rows), 'skip': 0, 'rows': rows}
a.out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
raise SystemExit(0 if report['fail'] == 0 and report['providersUnchanged'] and report['allInputsUnchanged'] else 1)
