#!/usr/bin/env python3
"""Offline, patched-only host unit regression for the pinned iSH path guards.

No old implementation is compiled or run. No directory, database, device, or
network operation from iSH runs; the C fixture records those interfaces.
"""
import argparse
import hashlib
import importlib.util
import json
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
PIN = {
    'commit': 'c5c264da19148512167aa493d7bd4e50aae1b74e',
    'bytes': 3025227,
    'sha256': '046e17769c9978e21060d465c0610a27a033dba2af92f58f42e7d8bcb6bb36ad',
}
TARGETS = (
    ('fs/fake.c', 'fakefs_mount'),
    ('fs/fake.c', 'fakefs_readdir'),
    ('fs/real.c', 'getpath'),
    ('fs/path.c', 'path_is_normalized'),
    ('fs/path.c', '__path_normalize'),
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def complete_function(source, name):
    """Return the exact complete definition; skip braces in comments/literals."""
    signature = rb'(?m)^(?:static )?(?:int|bool) ' + re.escape(name.encode()) + rb'\([^;\n]*\) \{'
    matches = list(re.finditer(signature, source))
    require(len(matches) == 1, f'expected one complete definition of {name}')
    start = matches[0].start()
    position = source.index(b'{', start)
    depth = 0
    while position < len(source):
        char = source[position:position + 1]
        if source[position:position + 2] == b'//':
            end = source.find(b'\n', position + 2)
            require(end != -1, f'unterminated comment in {name}')
            position = end + 1
            continue
        if source[position:position + 2] == b'/*':
            end = source.find(b'*/', position + 2)
            require(end != -1, f'unterminated comment in {name}')
            position = end + 2
            continue
        if char in (b'"', b"'"):
            quote = char
            position += 1
            while position < len(source):
                char = source[position:position + 1]
                if char == b'\\':
                    position += 2
                elif char == quote:
                    position += 1
                    break
                else:
                    position += 1
            continue
        if char == b'{':
            depth += 1
        elif char == b'}':
            depth -= 1
            if depth == 0:
                return source[start:position + 1], source[:start].count(b'\n') + 1
        position += 1
    raise RuntimeError(f'unterminated function {name}')


def require_patched_guards(functions):
    """Fail before executing boundary inputs if the candidate guard is absent.

    These source checks are an execution prerequisite, not the behavioral oracle.
    The C expectations come from the independent capacity/protocol table.
    """
    guards = {
        'fakefs_mount': (
            b'if (slash == NULL || strcmp(slash + 1, "data") != 0)',
            b'if (prefix_length > sizeof(db_path) - sizeof("meta.db"))',
        ),
        'fakefs_readdir': (
            b'int path_error = realfs_getpath(fd, entry_path);',
            b'if (path_error < 0)\n        return path_error;',
            b'if (strlen(entry_path) + 1 + strlen(entry->name) >= sizeof(entry_path))',
        ),
        'getpath': (
            b'char proc_fd[64];',
            b'snprintf(proc_fd, sizeof(proc_fd), "/proc/self/fd/%d", fd);',
        ),
        '__path_normalize': (
            b'if ((size_t) res >= MAX_PATH - (size_t) (c - out))',
            b'if (strlen(p) >= sizeof(possible_symlink) - prefix_length - 1)',
        ),
    }
    for name, snippets in guards.items():
        for snippet in snippets:
            require(snippet in functions[name],
                    f'patched-only prerequisite missing in {name}: {snippet.decode()}')
    ordering = (
        ('fakefs_mount', guards['fakefs_mount'][1], b'memcpy(db_path,'),
        ('fakefs_readdir', guards['fakefs_readdir'][1], b'strcat(entry_path,'),
        ('fakefs_readdir', guards['fakefs_readdir'][2], b'strcat(entry_path,'),
        ('__path_normalize', guards['__path_normalize'][0], b"c[res] = '\\0';"),
        ('__path_normalize', guards['__path_normalize'][1], b'strcat(expanded_path,'),
    )
    for name, guard, write in ordering:
        require(functions[name].index(guard) < functions[name].index(write),
                f'patched-only guard must precede the write in {name}')


def check_fixture_constants(source):
    expected = {
        'kernel/fs.h': {'MAX_PATH': '4096'},
        'kernel/errno.h': {'_ENOENT': '-2', '_EIO': '-5', '_EACCES': '-13',
                           '_ENOTDIR': '-20', '_EINVAL': '-22',
                           '_ENAMETOOLONG': '-36', '_ELOOP': '-40'},
        'fs/path.h': {'N_SYMLINK_FOLLOW': '1', 'N_SYMLINK_NOFOLLOW': '2'},
        'fs/fd.h': {'NAME_MAX': '255'},
    }
    for filename, values in expected.items():
        data = (source / filename).read_text()
        for name, value in values.items():
            pattern = r'^#define\s+' + re.escape(name) + r'\s+' + re.escape(value) + r'\b'
            require(re.search(pattern, data, re.MULTILINE) is not None,
                    f'fixture constant differs from the pinned source: {name}')
    access_header = (source / 'kernel/fs.h').read_text()
    require(re.search(r'^#define\s+AC_X\s+1\b', access_header, re.MULTILINE) is not None,
            'fixture access flag differs from the pinned source')


def backend_capacity_review(backend):
    """Source evidence and integer capacity proof, never an initialize run."""
    declaration = b'char root[PATH_MAX], data[PATH_MAX], directory[PATH_MAX];'
    guard = b'if (!strcmp(root, "/") || strlen(root) > sizeof data - sizeof "/meta.db") {'
    append = b'strcpy(data, root); strcat(data, "/data");'
    require(declaration in backend and guard in backend and append in backend,
            'backend preflight changed: review its capacity proof before proceeding')
    begin = backend.index(guard)
    end = backend.index(b'  size_t parent_length', begin)
    require(begin < backend.index(append), 'backend capacity gate must precede data append')
    return {
        'status': 'SOURCE_REVIEW_ONLY_NOT_EXECUTED',
        'declaration': declaration.decode(),
        'guard': backend[begin:end].decode(),
        'append': append.decode(),
        'independent_capacity_table': [
            {'PATH_MAX': 1024, 'maximum_root_bytes': 1015,
             'meta_path_with_NUL_bytes': 1024, 'data_path_with_NUL_bytes': 1021,
             'next_root_bytes': 1016, 'next_meta_path_with_NUL_bytes': 1025},
            {'PATH_MAX': 4096, 'maximum_root_bytes': 4087,
             'meta_path_with_NUL_bytes': 4096, 'data_path_with_NUL_bytes': 4093,
             'next_root_bytes': 4088, 'next_meta_path_with_NUL_bytes': 4097},
        ],
        'reason': 'The /meta.db suffix uses 8 bytes plus NUL; /data uses 5 plus NUL.',
        'not_covered': 'realpath, locking, crash records, complete initialization, kernel entry',
    }


def execute(args, work, receipt):
    def run(command, label, cwd=None):
        command = [str(part) for part in command]
        result = subprocess.run(command, cwd=cwd, text=True, capture_output=True, timeout=60)
        (work / (label + '.stdout')).write_text(result.stdout)
        (work / (label + '.stderr')).write_text(result.stderr)
        receipt['commands'].append({'argv': command, 'cwd': str(cwd or pathlib.Path.cwd()),
                                    'exit_code': result.returncode,
                                    'stdout_file': label + '.stdout', 'stderr_file': label + '.stderr'})
        require(result.returncode == 0, f'{label} failed ({result.returncode}): {result.stderr.strip()}')
        return result.stdout

    require(sys.platform.startswith('linux'), 'This runner requires a Linux host; Apple remains UNRUN')
    spec = importlib.util.spec_from_file_location('ish_build_for_path_tests', HERE / 'build.py')
    build = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(build)
    require(all(build.LOCK.get(key) == value for key, value in PIN.items()),
            'source.lock.json pin changed; review and update this pinned regression explicitly')
    archive = args.archive or build.CACHE / (PIN['commit'] + '.tar.gz')
    require(archive.is_file(), f'provide the existing pinned local archive with --archive: {archive}')
    require(archive.stat().st_size == PIN['bytes'] and digest(archive.read_bytes()) == PIN['sha256'],
            'local source archive size or SHA256 mismatch')
    receipt.update({'platform': {'system': platform.system(), 'machine': platform.machine()},
                    'archive': {'path': str(archive.resolve()), **PIN}, 'inputs': {},
                    'source_files': {}, 'functions': {}, 'comparisons': {}})
    receipt['base_head'] = run(['git', 'rev-parse', 'HEAD'], 'base-head', ROOT).strip()
    receipt['compiler'] = run([args.cc, '--version'], 'compiler-version').splitlines()[0]
    snapshots = work / 'inputs'
    snapshots.mkdir()
    files = ['build.py', 'source.lock.json', 'build.patch', 'job-runtime.patch',
             'test-host-path-bounds.py', 'tests/host-path-bounds.c']
    for name in files:
        data = (HERE / name).read_bytes()
        receipt['inputs']['tooling/ios/ish/' + name] = digest(data)
        path = snapshots / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    backend_name = 'runtime/ios/guest/native/guest_backend.c'
    backend = (ROOT / backend_name).read_bytes()
    receipt['inputs'][backend_name] = digest(backend)
    receipt['backend_capacity_review'] = backend_capacity_review(backend)
    (work / 'backend-capacity-review.json').write_text(json.dumps(receipt['backend_capacity_review'], indent=2) + '\n')
    staging = work / 'extracted'
    staging.mkdir()
    with tarfile.open(archive, 'r:gz') as tar:
        build.extract_source(tar, staging)
    source = staging / ('ish-arm64-' + PIN['commit'])
    for name, expected in build.LOCK['buildInputs'].items():
        require(digest((source / name).read_bytes()) == expected,
                f'pinned build input digest mismatch before patching: {name}')
    for patch in ('build.patch', 'job-runtime.patch'):
        run(['patch', '--batch', '--fuzz=0', '-p1', '-i', snapshots / patch], patch, source)
    check_fixture_constants(source)
    functions = {}
    header = b'/* Generated from newly verified and freshly patched iSH source. */\n'
    for filename, name in TARGETS:
        data = (source / filename).read_bytes()
        receipt['source_files'][filename] = digest(data)
        function, line = complete_function(data, name)
        functions[name] = function
        receipt['functions'][name] = {'source': filename, 'line': line,
                                       'sha256': digest(function), 'bytes': len(function)}
        if name == 'getpath':
            header += b'\n#define readlink recorded_readlink\n'
        header += ('\n#line %d %s\n' % (line, json.dumps(str(source / filename)))).encode()
        header += function + b'\n'
        if name == 'getpath':
            header += b'#undef readlink\n'
    require_patched_guards(functions)
    for filename in receipt['source_files']:
        if args.compare_source:
            expected = args.compare_source / pathlib.Path(filename).name
            require(expected.is_file(), f'comparison source missing: {expected}')
            equal = (source / filename).read_bytes() == expected.read_bytes()
            receipt['comparisons'][filename] = {'reference': str(expected), 'byte_equal': equal}
            require(equal, f'freshly patched file differs from the supplied comparison: {filename}')
    (work / 'patched-host-path-functions.h').write_bytes(header)
    receipt['generated_header_sha256'] = digest(header)
    fixture = work / 'host-path-bounds.c'
    fixture.write_bytes((snapshots / 'tests/host-path-bounds.c').read_bytes())
    receipt['runs'] = []
    for capacity in (1024, 4096):
        executable = work / ('host-path-bounds-' + str(capacity))
        run([args.cc, '-std=c11', '-D_DEFAULT_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1',
             '-DTEST_PATH_MAX=' + str(capacity), '-I', work, fixture, '-o', executable],
            'compile-' + str(capacity))
        output = run([executable], 'test-' + str(capacity))
        receipt['runs'].append({'synthetic_PATH_MAX': capacity, 'guest_MAX_PATH': 4096,
                                'exit_code': 0, 'stdout': output.strip()})
        print(output.strip())
    # A result belongs to the exact candidate tested, even if another editor
    # changes repository inputs concurrently. Report that fact without replay.
    receipt['repository_inputs_still_match'] = {
        name: (ROOT / name).is_file() and digest((ROOT / name).read_bytes()) == expected
        for name, expected in receipt['inputs'].items()}
    receipt['unrun'] = ['Apple compilation/execution', 'complete iSH integration', 'N-API',
                        'real filesystem/database/device/network behavior', 'complete dsh_guest_initialize']
    receipt['status'] = 'PASS'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=pathlib.Path, help='existing local pinned source archive; never downloaded')
    parser.add_argument('--cc', default='cc', help='local C compiler executable (default: cc)')
    parser.add_argument('--evidence-dir', type=pathlib.Path, help='retain a fresh run directory and receipt under this directory')
    parser.add_argument('--compare-source', type=pathlib.Path,
                        help='optional directory containing candidate fake.c, real.c and path.c for byte comparison')
    args = parser.parse_args()
    require(shutil.which(args.cc) is not None, 'local C compiler not found: ' + args.cc)
    require(shutil.which('patch') is not None, 'local patch tool not found')
    if args.evidence_dir:
        args.evidence_dir.mkdir(parents=True, exist_ok=True)
        work = pathlib.Path(tempfile.mkdtemp(prefix='run-', dir=args.evidence_dir.resolve()))
        temporary = None
    else:
        temporary = tempfile.TemporaryDirectory(prefix='ish-host-path-bounds-')
        work = pathlib.Path(temporary.name)
    receipt = {'schema': 1, 'scope': 'patched-only isolated host unit regression',
               'status': 'RUNNING', 'commands': []}
    code = 0
    try:
        execute(args, work, receipt)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        receipt.update({'status': 'FAIL', 'error': str(error)})
        print(str(error), file=sys.stderr)
        code = 1
    finally:
        try:
            (work / 'receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
        except OSError as error:
            print(f'Could not save the evidence receipt: {error}', file=sys.stderr)
            code = 1
        if args.evidence_dir:
            print('Evidence:', work)
        if temporary:
            temporary.cleanup()
    return code


if __name__ == '__main__':
    sys.exit(main())
