#!/usr/bin/env python3
"""Private Linux guest command transport. The host decides which App directories a job sees."""
import argparse
import base64
import ctypes
import errno
import json
import os
import re
import select
import signal
import sys
import termios
import time
import tty

VERSION = 1
PREFIX = b'DSHG1 '
MAX_LINE = 131072
WINDOW = 65536
CHUNK = 4096
UID = GID = 60081
# App directories exported over virtio-9p, one tag each, mounted once per boot
# in a root-only directory. Jobs see them only through their own bind mounts.
EXPORTS = '/run/dsh-9p'
EXPORT_OPTIONS = 'trans=virtio,version=9p2000.L,cache=none,access=any'
MS_RDONLY, MS_NOSUID, MS_NODEV, MS_REMOUNT, MS_BIND, MS_REC, MS_PRIVATE = 1, 2, 4, 32, 4096, 16384, 1 << 18
MNT_DETACH = 2


def write_all(fd, data):
    while data:
        n = os.write(fd, data)
        if n <= 0:
            raise OSError('write made no progress')
        data = data[n:]


def sync_rootfs():
    """Wait for the root filesystem's syncfs result, within this kernel's ABI.

    This is a guest writeback barrier, not a host fsync/power-loss guarantee.
    Older kernels have limited writeback-error reporting even on return zero.
    """
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        syncfs = ctypes.CDLL(None, use_errno=True).syncfs
        syncfs.argtypes = [ctypes.c_int]
        syncfs.restype = ctypes.c_int
        ctypes.set_errno(0)
        if syncfs(fd) != 0:
            raise OSError(ctypes.get_errno() or errno.EIO, 'root filesystem syncfs failed')
    finally:
        os.close(fd)


def close_fds(keep):
    for name in os.listdir('/proc/self/fd'):
        fd = int(name)
        if fd not in keep:
            try:
                os.close(fd)
            except OSError as error:
                if error.errno != errno.EBADF:
                    raise


def private_frame(fd, kind, **data):
    write_all(fd, json.dumps({'kind': kind, **data}, separators=(',', ':')).encode() + b'\n')


def drop_privileges():
    libc = ctypes.CDLL(None, use_errno=True)
    prctl = libc.prctl
    prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
    prctl.restype = ctypes.c_int
    os.setsid()
    os.setgroups([])
    os.setresgid(GID, GID, GID)
    if prctl(38, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), 'PR_SET_NO_NEW_PRIVS')
    last = int(open('/proc/sys/kernel/cap_last_cap').read())
    if not 0 <= last < 64:
        raise RuntimeError('unsupported capability range')
    for cap in range(last + 1):
        if prctl(24, cap, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), 'PR_CAPBSET_DROP')
    os.setresuid(UID, UID, UID)


def mount(source, target, fstype, flags, data=None):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mount.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_ulong, ctypes.c_char_p]
    encode = lambda value: None if value is None else value.encode()
    if libc.mount(encode(source), target.encode(), encode(fstype), flags, encode(data)) != 0:
        # Not an OSError: a missing path here is no missing command (exit 126).
        raise RuntimeError(f'mount {target}: {os.strerror(ctypes.get_errno())}')


def mount_workspaces(mounts):
    """Give this job a private mount namespace holding only its App directories,
    at their host paths. Read-only views are enforced by the guest kernel."""
    if not mounts:
        return
    tags = sorted({item['tag'] for item in mounts})
    for tag in tags:
        base = os.path.join(EXPORTS, tag)
        if not os.path.ismount(base):
            os.makedirs(base, exist_ok=True)
            os.chmod(EXPORTS, 0o700)
            mount(tag, base, '9p', MS_NOSUID | MS_NODEV, EXPORT_OPTIONS)
    os.unshare(os.CLONE_NEWNS)
    mount(None, '/', None, MS_REC | MS_PRIVATE)
    for item in mounts:
        os.makedirs(item['target'], exist_ok=True)
        mount(os.path.join(EXPORTS, item['tag'], item['source']), item['target'], None, MS_BIND)
        if item['readOnly']:
            mount(None, item['target'], None, MS_REMOUNT | MS_BIND | MS_RDONLY | MS_NOSUID | MS_NODEV)
    libc = ctypes.CDLL(None, use_errno=True)
    for tag in tags:
        if libc.umount2(os.path.join(EXPORTS, tag).encode(), MNT_DETACH) != 0:
            raise RuntimeError(f'umount {tag}: {os.strerror(ctypes.get_errno())}')


def namespace_init(spec, info, stdin, stdout, stderr):
    if os.getpid() != 1:
        raise RuntimeError('job init did not enter its own PID namespace')
    leader = os.fork()
    if leader == 0:
        os.dup2(stdin, 0)
        os.dup2(stdout, 1)
        os.dup2(stderr, 2)
        close_fds({0, 1, 2, info})
        try:
            mount_workspaces(spec['mounts'])
            os.chdir(spec['cwd'])
            drop_privileges()
            private_frame(info, 'admitted')
            os.close(info)
            os.execvpe(spec['argv'][0], spec['argv'], spec['env'])
        except BaseException as error:
            write_all(2, ('ERR_OHOS_GUEST_EXEC: ' + str(error) + '\n').encode())
            os._exit(127 if isinstance(error, FileNotFoundError) else 126)
    for fd in (stdin, stdout, stderr):
        os.close(fd)
    while True:
        try:
            pid, status = os.waitpid(-1, 0)
        except ChildProcessError:
            break
        except InterruptedError:
            continue
        if pid == leader:
            private_frame(info, 'leader', status=status)
    private_frame(info, 'tree-reaped')
    os.close(info)
    os._exit(0)


def start_namespace(spec, info, cancel, stdin, stdout, stderr):
    close_fds({info, cancel, stdin, stdout, stderr})
    os.unshare(os.CLONE_NEWPID)
    init = os.fork()
    if init == 0:
        os.close(cancel)
        namespace_init(spec, info, stdin, stdout, stderr)
    for fd in (stdin, stdout, stderr):
        os.close(fd)
    # EOF on the private cancellation pipe also means the owning controller died.
    # The namespace init cannot escape this ownership by changing process group.
    wake_r, wake_w = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
    signal.signal(signal.SIGCHLD, lambda *_: None)
    signal.set_wakeup_fd(wake_w)
    cancelled = False
    while True:
        pid, status = os.waitpid(init, os.WNOHANG)
        if pid:
            private_frame(info, 'namespace', status=status)
            break
        ready, _, _ = select.select([wake_r] + ([] if cancelled else [cancel]), [], [])
        if wake_r in ready:
            try:
                os.read(wake_r, 4096)
            except BlockingIOError:
                pass
        if cancel in ready:
            os.read(cancel, 1)
            try:
                os.kill(init, signal.SIGKILL)
            except ProcessLookupError:
                pass
            cancelled = True
    signal.set_wakeup_fd(-1)
    for fd in (wake_r, wake_w, cancel, info):
        os.close(fd)
    os._exit(0)


def validate_start(command):
    argv, cwd, env = command.get('argv'), command.get('cwd'), command.get('env')
    if not isinstance(argv, list) or not argv or not argv[0] or any(not isinstance(x, str) or '\0' in x for x in argv):
        raise ValueError('argv must be a nonempty array of NUL-free strings')
    if not isinstance(cwd, str) or not cwd.startswith('/') or '\0' in cwd:
        raise ValueError('cwd must be an absolute guest path')
    if not isinstance(env, dict) or any(not isinstance(k, str) or not k or '=' in k or '\0' in k
                                       or not isinstance(v, str) or '\0' in v for k, v in env.items()):
        raise ValueError('env must contain NUL-free string entries')
    mounts = command.get('mounts', [])
    if not isinstance(mounts, list) or len(mounts) > 4 or not all(valid_mount(item) for item in mounts):
        raise ValueError('mounts must name App exports and absolute guest paths')
    return {'argv': argv, 'cwd': cwd, 'env': env, 'mounts': mounts}


def valid_mount(item):
    if not isinstance(item, dict) or set(item) != {'tag', 'source', 'target', 'readOnly'}:
        return False
    source, target = item['source'], item['target']
    return (isinstance(item['tag'], str) and re.fullmatch('dsh[0-3]', item['tag']) is not None
            and isinstance(source, str) and '\0' not in source
            and (source == '' or all(part not in ('', '.', '..') for part in source.split('/')))
            and isinstance(target, str) and '\0' not in target and target != '/'
            and target.startswith('/') and os.path.normpath(target) == target
            and type(item['readOnly']) is bool)


class Agent:
    def __init__(self, epoch):
        self.epoch = epoch
        self.sequence = 0
        self.last_job = 0
        self.active = None
        self.input = b''
        self.closed = False
        self.close_requested = False
        self.wake_r, self.wake_w = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
        signal.signal(signal.SIGCHLD, lambda *_: None)
        signal.set_wakeup_fd(self.wake_w)

    def frame(self, kind, job=None, **data):
        self.sequence += 1
        write_all(1, PREFIX + json.dumps({'v': VERSION, 'epoch': self.epoch, 'seq': self.sequence,
                  'kind': kind, 'job': job, **data}, separators=(',', ':')).encode() + b'\n')

    def start(self, command):
        job = command.get('job')
        if self.active is not None:
            raise ValueError('guest command lane is busy')
        if type(job) is not int or job <= self.last_job or job > 9007199254740991:
            raise ValueError('job must be a strictly increasing safe integer')
        spec = validate_start(command)
        pipes = [os.pipe2(os.O_CLOEXEC) for _ in range(5)]
        (stdin_r, stdin_w), (stdout_r, stdout_w), (stderr_r, stderr_w), (info_r, info_w), (cancel_r, cancel_w) = pipes
        try:
            pid = os.fork()
        except BaseException:
            for pair in pipes:
                for fd in pair:
                    os.close(fd)
            raise
        if pid == 0:
            signal.set_wakeup_fd(-1)
            signal.signal(signal.SIGCHLD, signal.SIG_DFL)
            try:
                start_namespace(spec, info_w, cancel_r, stdin_r, stdout_w, stderr_w)
            except BaseException as error:
                private_frame(info_w, 'failure', message=str(error))
                os._exit(125)
        for fd in (stdin_r, stdout_w, stderr_w, info_w, cancel_r):
            os.close(fd)
        os.set_blocking(stdin_w, False)
        self.last_job = job
        self.active = {'id': job, 'pid': pid, 'stdin': stdin_w, 'input': b'', 'input_end': False,
                       'input_offset': 0, 'input_received': 0, 'cancel': cancel_w, 'cancelled': False,
                       'outputs': {stdout_r: 'stdout', stderr_r: 'stderr'}, 'info': info_r, 'info_data': b'',
                       'sent': {'stdout': 0, 'stderr': 0}, 'acked': {'stdout': 0, 'stderr': 0},
                       'ends': {'stdout': {0}, 'stderr': {0}}, 'eof': set(), 'info_eof': False,
                       'leader': None, 'namespace': None, 'tree': False, 'wait': None, 'failure': None}
        self.frame('started', job)

    def cancel(self):
        job = self.active
        if job and not job['cancelled']:
            try:
                write_all(job['cancel'], b'K')
            except BrokenPipeError:
                # The namespace may already have completed while sink ACKs
                # are pending; the private reap facts still decide completion.
                pass
            job['cancelled'] = True
            job['input'] = b''
            job['input_end'] = True

    def command(self, command):
        if not isinstance(command, dict) or command.get('v') != VERSION or command.get('epoch') != self.epoch:
            raise ValueError('guest transport identity mismatch')
        if self.closed:
            raise ValueError('guest already closing; no further command may be admitted')
        operation = command.get('op')
        if operation == 'start':
            self.start(command)
            return
        if operation == 'close' and self.active is None:
            self.close_requested = True
            self.closed = True
            return
        job = self.active
        if job is None or command.get('job') != job['id']:
            raise ValueError('guest job identity mismatch')
        if operation == 'cancel':
            self.cancel()
            self.frame('cancel-requested', job['id'])
        elif operation == 'stdin':
            if job['stdin'] is None or job['input_end'] or job['cancelled']:
                raise ValueError('stdin is closed')
            raw = command.get('data')
            if not isinstance(raw, str):
                raise ValueError('stdin data must be base64')
            data = base64.b64decode(raw, validate=True)
            if len(job['input']) + len(data) > WINDOW:
                raise ValueError('stdin credit exceeded')
            if command.get('offset') != str(job['input_received']):
                raise ValueError('stdin offset gap')
            job['input_received'] += len(data)
            job['input'] += data
        elif operation == 'stdin-end':
            job['input_end'] = True
        elif operation == 'ack':
            stream, through = command.get('stream'), command.get('through')
            if stream not in ('stdout', 'stderr') or not isinstance(through, str) or not re.fullmatch(r'0|[1-9][0-9]*', through):
                raise ValueError('invalid output ack')
            offset = int(through)
            if offset < job['acked'][stream] or offset not in job['ends'][stream]:
                raise ValueError('invalid output ack boundary')
            job['acked'][stream] = offset
            job['ends'][stream] = {n for n in job['ends'][stream] if n >= offset}
        else:
            raise ValueError('unknown guest operation')

    def input_ready(self):
        data = os.read(0, 4096)
        if not data:
            raise EOFError('host transport closed')
        self.input += data
        if len(self.input) > MAX_LINE:
            raise ValueError('guest control line too large')
        while b'\n' in self.input:
            line, self.input = self.input.split(b'\n', 1)
            self.command(json.loads(line))

    def poll_job(self, ready, writable):
        job = self.active
        if job is None:
            return
        fd = job['stdin']
        if fd is not None and fd in writable and job['input']:
            try:
                size = os.write(fd, job['input'])
                job['input'] = job['input'][size:]
                job['input_offset'] += size
                self.frame('stdin-ack', job['id'], through=str(job['input_offset']))
            except BrokenPipeError:
                job['input'] = b''
                job['input_end'] = True
                self.frame('stdin-closed', job['id'])
            except BlockingIOError:
                pass
        if fd is not None and job['input_end'] and not job['input']:
            os.close(fd)
            job['stdin'] = None
        if job['info'] in ready and not job['info_eof']:
            data = os.read(job['info'], 8192)
            if not data:
                job['info_eof'] = True
                os.close(job['info'])
                if job['info_data']:
                    raise RuntimeError('truncated private status')
            else:
                job['info_data'] += data
                if len(job['info_data']) > MAX_LINE:
                    raise RuntimeError('private status overflow')
                while b'\n' in job['info_data']:
                    line, job['info_data'] = job['info_data'].split(b'\n', 1)
                    event = json.loads(line)
                    kind = event['kind']
                    if kind == 'leader':
                        job['leader'] = event['status']
                    elif kind == 'namespace':
                        job['namespace'] = event['status']
                    elif kind == 'tree-reaped':
                        job['tree'] = True
                    elif kind == 'failure':
                        job['failure'] = event['message']
                    elif kind == 'admitted':
                        self.frame('admitted', job['id'])
                    else:
                        raise RuntimeError('invalid private status')
        for fd, stream in job['outputs'].items():
            if fd not in ready or stream in job['eof']:
                continue
            credit = WINDOW - (job['sent'][stream] - job['acked'][stream])
            data = os.read(fd, min(CHUNK, credit))
            if data:
                offset = job['sent'][stream]
                job['sent'][stream] += len(data)
                job['ends'][stream].add(job['sent'][stream])
                self.frame('data', job['id'], stream=stream, offset=str(offset), data=base64.b64encode(data).decode())
            else:
                job['eof'].add(stream)
                os.close(fd)
                self.frame('eof', job['id'], stream=stream, through=str(job['sent'][stream]))
        if job['wait'] is None:
            pid, status = os.waitpid(job['pid'], os.WNOHANG)
            if pid:
                job['wait'] = status
        reaped = job['wait'] is not None and job['info_eof'] and len(job['eof']) == 2
        if reaped and job['sent'] == job['acked']:
            if job['stdin'] is not None:
                os.close(job['stdin'])
            os.close(job['cancel'])
            valid_tree = job['wait'] == 0 and ((job['namespace'] == 0 and job['tree']) or
                         (job['cancelled'] and job['namespace'] == signal.SIGKILL))
            if not valid_tree or job['failure'] is not None or (job['leader'] is None and not job['cancelled']):
                self.frame('failed', job['id'], code='ERR_OHOS_GUEST_REAP', message=job['failure'] or 'task tree completion is unverified')
                # A failed owner is not reusable merely because some pipes closed.
                self.closed = True
            else:
                raw = job['leader']
                code = os.waitstatus_to_exitcode(raw) if raw is not None else -signal.SIGKILL
                self.frame('complete', job['id'], exitCode=code if code >= 0 else None,
                           signal=signal.Signals(-code).name if code < 0 else None,
                           cancelled=job['cancelled'], produced={k: str(v) for k, v in job['sent'].items()})
            self.active = None

    def run(self):
        self.frame('opened', capabilities={'streamingStdin': True, 'pidNamespace': True, 'workspaceLease': False,
                                           'mounts': True})
        try:
            while not self.closed:
                reads = [0, self.wake_r]
                writes = []
                job = self.active
                if job:
                    if not job['info_eof']:
                        reads.append(job['info'])
                    for fd, stream in job['outputs'].items():
                        if stream not in job['eof'] and job['sent'][stream] - job['acked'][stream] < WINDOW:
                            reads.append(fd)
                    if job['stdin'] is not None and job['input']:
                        writes.append(job['stdin'])
                    self.poll_job([], [])
                    if self.active is None:
                        continue
                ready, writable, _ = select.select(reads, writes, [])
                if self.wake_r in ready:
                    try:
                        os.read(self.wake_r, 4096)
                    except BlockingIOError:
                        pass
                if 0 in ready:
                    self.input_ready()
                self.poll_job(ready, writable)
            if not self.close_requested or self.active is not None:
                raise RuntimeError('guest did not reach an explicit quiescent close')
            try:
                sync_rootfs()
            except Exception as error:
                number = getattr(error, 'errno', None)
                self.frame('close-failed', rootfsSync=False, syncMethod='syncfs', syncScope='rootfs',
                           code='ERR_OHOS_GUEST_SYNC',
                           errno=number if type(number) is int and 0 < number <= 4095 else None)
                raise
            self.frame('closed', rootfsSync=True, syncMethod='syncfs', syncScope='rootfs')
        finally:
            # Losing the controller closes its private cancellation pipe; the
            # starter kills its PID namespace. Native transport loss must quarantine.
            if self.active:
                self.cancel()
                os.close(self.active['cancel'])
            signal.set_wakeup_fd(-1)
            os.close(self.wake_r)
            os.close(self.wake_w)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--epoch', required=True)
    args = parser.parse_args()
    if not re.fullmatch('[0-9a-f]{64}', args.epoch):
        parser.error('epoch must be 32 host-provided random bytes in lowercase hex')
    if os.geteuid() != 0 or not hasattr(os, 'CLONE_NEWPID'):
        raise RuntimeError('guest agent requires Linux root with PID namespaces')
    previous = termios.tcgetattr(0) if os.isatty(0) else None
    if previous is not None:
        tty.setraw(0)
    try:
        Agent(args.epoch).run()
    finally:
        if previous is not None:
            termios.tcsetattr(0, termios.TCSANOW, previous)


if __name__ == '__main__':
    main()
