#!/usr/bin/env python3
"""Actual Agent.run/command over pipes, with explicit libc/FD fault boundaries.

The real-success child calls the actual host libc syncfs on the actual root FD.
Other children inject the named syscall/FD failure; no VM durability is claimed.
"""
import argparse
import ctypes
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time


EPOCH = 'a' * 64
CASES = ['real-success', 'syscall-ebadf', 'syscall-eio', 'open-failure',
         'close-failure', 'missing-symbol', 'transport-eof', 'wrong-epoch',
         'command-after-close', 'failed-owner']


def probe(args):
    source = args.source.read_bytes()
    spec = importlib.util.spec_from_file_location('actual_guest_agent', args.source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    agent = module.Agent(EPOCH)
    events = []
    actual_open, actual_close, actual_cdll = os.open, os.close, ctypes.CDLL
    native_sync = actual_cdll(None, use_errno=True).syncfs
    native_sync.argtypes, native_sync.restype = [ctypes.c_int], ctypes.c_int
    root_fd = None

    class Sync:
        def __call__(self, fd):
            info = os.fstat(fd)
            row = {'operation': 'syncfs', 'sequenceBefore': agent.sequence,
                   'activeJob': agent.active is not None, 'fd': fd,
                   'fdTarget': os.readlink('/proc/self/fd/' + str(fd)),
                   'isDirectory': stat.S_ISDIR(info.st_mode),
                   'argtypesCorrect': self.argtypes == [ctypes.c_int],
                   'restypeCorrect': self.restype is ctypes.c_int}
            events.append(row)
            started = time.monotonic_ns()
            if args.probe == 'syscall-eio':
                ctypes.set_errno(errno.EIO)
                returned = -1
                row['boundary'] = 'explicit injected EIO; no syscall'
            else:
                actual_fd = -1 if args.probe == 'syscall-ebadf' else fd
                row['actualSyscallFd'] = actual_fd
                returned = native_sync(actual_fd)
                row['boundary'] = 'actual host libc syncfs'
            row.update(returned=returned, errno=ctypes.get_errno(), elapsedNs=time.monotonic_ns() - started)
            return returned

    class Libc:
        syncfs = Sync()

    def cdll(name, **kwargs):
        events.append({'operation': 'CDLL', 'nameIsNone': name is None,
                       'useErrno': kwargs.get('use_errno') is True})
        return object() if args.probe == 'missing-symbol' else Libc()

    def open_root(name, flags, *rest):
        nonlocal root_fd
        if name != '/':
            return actual_open(name, flags, *rest)
        events.append({'operation': 'open-root', 'flags': flags})
        if args.probe == 'open-failure':
            raise OSError(errno.EACCES, 'controlled root open failure')
        root_fd = actual_open(name, flags, *rest)
        return root_fd

    def close_root(fd):
        if fd != root_fd:
            return actual_close(fd)
        events.append({'operation': 'close-root', 'sequenceBefore': agent.sequence})
        actual_close(fd)
        if args.probe == 'close-failure':
            raise OSError(errno.EIO, 'controlled close result after actual FD close')

    if args.probe == 'failed-owner':
        # Production already uses closed=True after an unverified task reap.
        # This must not be confused with the host's explicit normal close.
        agent.closed = True
    module.ctypes.CDLL, module.os.open, module.os.close = cdll, open_root, close_root
    caught = None
    try:
        agent.run()
    except BaseException as error:
        caught = {'type': type(error).__name__, 'errno': getattr(error, 'errno', None)}
    finally:
        module.ctypes.CDLL, module.os.open, module.os.close = actual_cdll, actual_open, actual_close
    args.result.write_text(json.dumps({'events': events, 'raised': caught,
        'sourceSha256': hashlib.sha256(source).hexdigest(),
        'sourceUnchanged': args.source.read_bytes() == source}, indent=2) + '\n')


def main(args):
    args.output.mkdir(parents=True, exist_ok=False)
    source_sha = hashlib.sha256(args.source.read_bytes()).hexdigest()
    records = []
    for case in CASES:
        result = args.output / (case + '.json')
        command = {'v': 1, 'epoch': EPOCH, 'op': 'close'}
        if case == 'wrong-epoch':
            command['epoch'] = 'b' * 64
        wire = json.dumps(command).encode() + b'\n'
        if case == 'transport-eof':
            wire = b''
        elif case == 'command-after-close':
            wire += json.dumps({'v': 1, 'epoch': EPOCH, 'op': 'start', 'job': 1,
                                'argv': ['true'], 'cwd': '/workspace', 'env': {}}).encode() + b'\n'
        argv = [sys.executable, str(Path(__file__).resolve()), '--source', str(args.source),
                '--probe', case, '--result', str(result)]
        started = time.monotonic_ns()
        process = subprocess.run(argv, input=wire, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        (args.output / (case + '.stdout')).write_bytes(process.stdout)
        (args.output / (case + '.stderr')).write_bytes(process.stderr)
        observation = json.loads(result.read_text()) if result.exists() else {}
        frames = [json.loads(line[6:]) for line in process.stdout.splitlines() if line.startswith(b'DSHG1 ')]
        calls = [row for row in observation.get('events', []) if row['operation'] == 'syncfs']
        closed = [row for row in frames if row['kind'] == 'closed']
        failures = [row for row in frames if row['kind'] == 'close-failed']
        checks = {'childExit0': process.returncode == 0, 'sourceUnchanged': observation.get('sourceUnchanged') is True,
                  'sourceIdentity': observation.get('sourceSha256') == source_sha,
                  'openedFirst': bool(frames) and frames[0]['kind'] == 'opened'}
        if case == 'real-success':
            checks.update(oneRealRootCall=len(calls) == 1 and calls[0].get('actualSyscallFd') == calls[0]['fd']
                          and calls[0]['fdTarget'] == '/' and calls[0]['isDirectory']
                          and calls[0]['argtypesCorrect'] and calls[0]['restypeCorrect']
                          and calls[0]['returned'] == 0 and calls[0]['sequenceBefore'] == 1 and not calls[0]['activeJob'],
                          closeAfterSync=[r['operation'] for r in observation.get('events', [])][-2:] == ['syncfs', 'close-root'],
                          cleanClosed=len(closed) == 1 and closed[0].get('rootfsSync') is True
                          and closed[0].get('syncMethod') == 'syncfs' and closed[0].get('syncScope') == 'rootfs'
                          and closed[0]['seq'] == 2 and closed[0]['epoch'] == EPOCH,
                          noFailure=not failures and observation.get('raised') is None)
        elif case in ['syscall-ebadf', 'syscall-eio', 'open-failure', 'close-failure', 'missing-symbol']:
            expected_errno = {'syscall-ebadf': errno.EBADF, 'syscall-eio': errno.EIO,
                              'open-failure': errno.EACCES, 'close-failure': errno.EIO, 'missing-symbol': None}[case]
            checks.update(noClosed=not closed, explicitFailure=len(failures) == 1
                          and failures[0].get('rootfsSync') is False and failures[0].get('syncMethod') == 'syncfs'
                          and failures[0].get('syncScope') == 'rootfs' and failures[0].get('code') == 'ERR_OHOS_GUEST_SYNC'
                          and failures[0].get('errno') == expected_errno,
                          exceptionObserved=observation.get('raised') is not None)
        else:
            checks.update(noSync=not calls, noClosed=not closed, exceptionObserved=observation.get('raised') is not None)
        record = {'case': case, 'argv': argv, 'exitCode': process.returncode,
                  'elapsedNs': time.monotonic_ns() - started, 'checks': checks, 'passed': all(checks.values())}
        records.append(record)
    report = {'pass': all(row['passed'] for row in records), 'source': str(args.source), 'sourceSha256': source_sha,
              'driverSha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'cases': records,
              'scope': 'Actual Agent.run/command with real stdin/stdout; normal case actual host root syncfs, named error cases controlled. Not VM, SDK, phone or power-loss durability.'}
    (args.output / 'RESULT.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'pass': report['pass'], 'passed': sum(row['passed'] for row in records),
                      'total': len(records), 'output': str(args.output)}))
    return 0 if report['pass'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--probe', choices=CASES)
    parser.add_argument('--result', type=Path)
    arguments = parser.parse_args()
    if arguments.probe:
        probe(arguments)
    else:
        if arguments.output is None:
            parser.error('--output is required')
        raise SystemExit(main(arguments))
