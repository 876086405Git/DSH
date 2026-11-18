"""Per-subinterpreter OH platform adaptation; not an untrusted-code sandbox."""
def _dsh_install(context):
    import builtins
    import io
    import os
    import sys
    import pathlib
    import sqlite3
    import subprocess
    import ssl
    import ctypes

    native = {name: getattr(os, name) for name in (
        'getcwd', 'stat', 'lstat', 'listdir', 'scandir', 'open', 'mkdir', 'rmdir',
        'remove', 'unlink', 'rename', 'replace', 'chmod', 'utime', 'access', 'readlink')}
    original_open, original_io_open = builtins.open, io.open
    current = context['cwd']
    roots = tuple(context['roots'])
    read_only = context.get('readOnly', False)
    resolving = False

    def denied(message):
        raise PermissionError('ERR_OHOS_PYTHON_PATH: ' + message)

    def path(value, write=False, follow=True):
        nonlocal resolving
        if isinstance(value, int):
            denied('raw file descriptors are not supported')
        value = os.fspath(value)
        if isinstance(value, bytes):
            value = os.fsdecode(value)
        candidate = os.path.join(current, value)
        trailing = candidate.endswith('/')
        # Resolve ancestors for authorization, preserving leaf operations. A
        # trailing slash makes the kernel resolve the leaf as a directory even
        # for follow_symlinks=False, so its target needs a separate check.
        resolving = True
        try:
            if follow:
                candidate = os.path.realpath(candidate) + ('/' if trailing else '')
                authorized = candidate
            else:
                parent, leaf = os.path.split(candidate.rstrip('/'))
                candidate = os.path.join(os.path.realpath(parent), leaf) + ('/' if trailing else '')
                authorized = os.path.realpath(candidate) if trailing else candidate
        finally:
            resolving = False
        if not any(os.path.commonpath((os.path.normpath(authorized), root)) == root for root in roots):
            denied('path is outside host-authorized roots')
        if write and read_only:
            denied('workspace is read-only')
        return candidate

    def opened(original, file, mode='r', *args, **kwargs):
        if kwargs.get('opener') is not None:
            denied('custom opener is unsupported')
        return original(path(file, any(flag in mode for flag in 'wax+'), follow='x' not in mode), mode, *args, **kwargs)

    builtins.open = lambda file, mode='r', *a, **kw: opened(original_open, file, mode, *a, **kw)
    io.open = lambda file, mode='r', *a, **kw: opened(original_io_open, file, mode, *a, **kw)
    os.getcwd = lambda: current
    os.getcwdb = lambda: os.fsencode(current)

    def chdir(value):
        nonlocal current
        candidate = path(value)
        if not os.path.isdir(candidate):
            raise NotADirectoryError(candidate)
        current = candidate
        if not context.get('scriptDirectory'):
            sys.path[0] = current
    os.chdir = chdir

    # Never call process-wide setenv/putenv/chdir. Each subinterpreter gets a dict.
    os.environ = dict(context['env'])
    os.getenv = lambda key, default=None: os.environ.get(key, default)
    os.putenv = lambda key, value: os.environ.__setitem__(os.fsdecode(key), os.fsdecode(value))
    os.unsetenv = lambda key: os.environ.pop(os.fsdecode(key), None)
    if hasattr(os, 'environb'):
        del os.environb

    def unary(name, value='.', *args, **kwargs):
        if resolving:
            return native[name](value, *args, **kwargs)
        if kwargs.get('dir_fd') is not None:
            denied('dir_fd is unsupported')
        return native[name](path(value, name in {'mkdir', 'rmdir', 'remove', 'unlink', 'chmod', 'utime'},
                                 follow=name not in {'lstat', 'readlink', 'unlink', 'remove', 'rmdir', 'mkdir'} and kwargs.get('follow_symlinks', True)), *args, **kwargs)
    for name in ('stat', 'lstat', 'listdir', 'scandir', 'mkdir', 'rmdir', 'remove', 'unlink', 'chmod', 'utime', 'access', 'readlink'):
        setattr(os, name, (lambda name: lambda value='.', *a, **kw: unary(name, value, *a, **kw))(name))

    def renamed(name, source, dest, **kwargs):
        if kwargs:
            denied('rename dir_fd options unsupported')
        return native[name](path(source, True, follow=False), path(dest, True, follow=False))
    os.rename = lambda src, dst, **kw: renamed('rename', src, dst, **kw)
    os.replace = lambda src, dst, **kw: renamed('replace', src, dst, **kw)

    def os_open(file, flags, mode=0o777, *, dir_fd=None):
        if dir_fd is not None:
            denied('dir_fd is unsupported')
        return native['open'](path(file, bool(flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND)),
                                   follow=not (flags & os.O_NOFOLLOW or (flags & os.O_CREAT and flags & os.O_EXCL))), flags, mode)
    os.open = os_open

    def unsupported(*args, **kwargs):
        raise RuntimeError('ERR_OHOS_PYTHON_PROCESS: use App Linux for this process operation')
    for name in ('fork', 'forkpty', 'posix_spawn', 'posix_spawnp', 'system', 'execv', 'execve', 'execl', 'execle', 'execvp', 'execvpe', '_exit', 'fchdir', 'chroot', 'link', 'symlink', 'abort', 'kill', 'killpg'):
        if hasattr(os, name):
            setattr(os, name, unsupported)
    import subprocess
    subprocess.Popen = unsupported

    class NoStdin(io.TextIOBase):
        def read(self, *args):
            raise RuntimeError('ERR_OHOS_PYTHON_STDIN: interactive stdin is not implemented; use App Linux')
        readline = read
        readinto = read
        @property
        def buffer(self):
            return self
    sys.stdin = NoStdin()

    # C extension filenames bypass Python's open, so adapt the specific entry.
    import sqlite3
    original_connect = sqlite3.connect
    def connect(database, *args, **kwargs):
        if kwargs.get('uri') or (isinstance(database, str) and database.startswith('file:')):
            denied('SQLite URI paths unsupported')
        database = database if database == ':memory:' else path(database, True)
        return original_connect(database, *args, **kwargs)
    sqlite3.connect = connect
    sqlite3.dbapi2.connect = connect

    # Keep structures/sizeof/casts and all compiled _ctypes functionality; limit dlopen.
    approved = frozenset(context.get('approvedLibraries', ()))
    def audit(event, args):
        if event == 'ctypes.dlopen' and args[0] not in approved:
            raise PermissionError('ERR_OHOS_PYTHON_DLOPEN: library is not packaged and host-approved')
    sys.addaudithook(audit)

    # Default requests trust the bundled CA and the host-initialized system store.
    if context.get('caFile'):
        import ssl
        original_context = ssl.create_default_context
        def default_context(purpose=ssl.Purpose.SERVER_AUTH, *, cafile=None, capath=None, cadata=None):
            if cafile is None and capath is None and cadata is None:
                result = original_context(purpose, cafile=context['caFile'])
                result.load_default_certs(purpose)
                return result
            return original_context(purpose, cafile=cafile, capath=capath, cadata=cadata)
        ssl.create_default_context = default_context
        ssl._create_default_https_context = default_context

    sys.argv = list(context['argv'])
    sys.path.insert(0, context.get('scriptDirectory') or current)
