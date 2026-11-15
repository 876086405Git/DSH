#!/usr/bin/env python3
"""Repack a read-only real runtime and measure installation in separate Linux PIDs.

No device/Ark claims. The optional 16000/167000000 scale fixture is explicitly
labelled and adds deterministic data to the actual input without modifying it.
"""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import time
import zipfile

DATE = (2026, 1, 1, 0, 0, 0)
CHUNK = 256 * 1024


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(CHUNK), b''):
            h.update(block)
    return h.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def remove_generated_tree(target):
    """Bounded cleanup of this driver's generated test application only.

    Keep any ENOTEMPTY observation in a separate record; it must not silently
    turn an incomplete measurement into a successful matrix.
    """
    attempts = []
    record = target.parent / (target.name + '.cleanup-' + str(time.monotonic_ns()) + '.json')
    for attempt in range(1, 4):
        try:
            shutil.rmtree(target)
            attempts.append({'attempt': attempt, 'removed': True})
            write_json(record, {'target': str(target), 'attempts': attempts})
            return
        except OSError as error:
            remaining = []
            for directory, _, files in os.walk(target):
                for name in files:
                    relative = (Path(directory) / name).relative_to(target).as_posix()
                    remaining.append(relative)
            attempts.append({'attempt': attempt, 'errno': error.errno, 'error': str(error),
                             'remainingFiles': len(remaining), 'firstRemainingPaths': sorted(remaining)[:50]})
            write_json(record, {'target': str(target), 'attempts': attempts})
            if error.errno != errno.ENOTEMPTY or attempt == 3:
                raise


def info(name, method):
    result = zipfile.ZipInfo(name, DATE)
    result.create_system = 3
    result.external_attr = 0o100644 << 16
    result.compress_type = method
    result._compresslevel = 9  # ZipInfo's writer-level field in our Python 3.12.
    return result


def write_member(archive, name, source=None, data=None, method=zipfile.ZIP_DEFLATED):
    member = info(name, method)
    member.file_size = len(data) if data is not None else source.stat().st_size
    with archive.open(member, 'w', force_zip64=False) as out:
        if data is not None:
            out.write(data)
        else:
            with source.open('rb') as inp:
                shutil.copyfileobj(inp, out, CHUNK)


def build(raw, output, mode):
    output.mkdir()
    original = json.loads((raw / 'manifest.json').read_bytes())
    manifest = json.loads(json.dumps(original))
    generated = {}
    if mode == 'scale':
        missing = 16000 - len(manifest['files'])
        remaining = 167000000 - sum(item['size'] for item in manifest['files'])
        if missing <= 0 or remaining < missing:
            raise ValueError('actual input already exceeds the specified scale fixture')
        for i in range(missing):
            length = remaining // (missing - i)
            seed = ('scale-fixture-%06d-' % i + hashlib.sha256(str(i).encode()).hexdigest()).encode()
            data = (seed * (length // len(seed) + 1))[:length]
            name = f'zz-archive-scale/{i:06d}.txt'
            generated[name] = data
            manifest['files'].append({'path': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
            remaining -= length
        manifest['runtimeVersion'] = 'explicit-archive-scale-fixture'
        manifest['files'].sort(key=lambda item: item['path'])
    elif mode == 'upgrade':
        name = 'runtime/ohos/preload.mjs'
        data = (raw / 'files' / name).read_bytes() + b'\n// Explicit archive increment measurement fixture.\n'
        generated[name] = data
        item = next(row for row in manifest['files'] if row['path'] == name)
        item.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
        manifest['runtimeVersion'] = 'explicit-archive-one-file-upgrade-fixture'
    manifest_bytes = ((json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()
                      if mode != 'actual' else (raw / 'manifest.json').read_bytes())
    inner = output / 'runtime.zip'
    with zipfile.ZipFile(inner, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9, allowZip64=False) as archive:
        write_member(archive, 'manifest.json', data=manifest_bytes, method=zipfile.ZIP_STORED)
        for item in manifest['files']:
            name = item['path']
            if name in generated:
                write_member(archive, 'files/' + name, data=generated[name])
            else:
                source = raw / 'files' / name
                if source.stat().st_size != item['size'] or sha(source) != item['sha256']:
                    raise ValueError('read-only input differs from manifest: ' + name)
                write_member(archive, 'files/' + name, source=source)
    transmission = output / 'dsh-runtime-rawfile.zip'
    with zipfile.ZipFile(transmission, 'w', allowZip64=False) as archive:
        write_member(archive, 'dsh-runtime/runtime.zip', source=inner, method=zipfile.ZIP_STORED)
    hap = output / 'runtime-only.hap'
    with zipfile.ZipFile(hap, 'w', allowZip64=False) as archive:
        write_member(archive, 'fixture-prefix.txt', data=b'Nonzero rawfile offset fixture', method=zipfile.ZIP_STORED)
        write_member(archive, 'resources/rawfile/dsh-runtime/runtime.zip', source=inner, method=zipfile.ZIP_STORED)
        write_member(archive, 'fixture-suffix.txt', data=b'Bounded rawfile length fixture', method=zipfile.ZIP_STORED)
    with zipfile.ZipFile(hap) as archive, hap.open('rb') as f:
        member = archive.getinfo('resources/rawfile/dsh-runtime/runtime.zip')
        f.seek(member.header_offset)
        header = f.read(30)
        names, extras = struct.unpack('<HH', header[26:30])
        offset = member.header_offset + 30 + names + extras
    description = {'kind': mode, 'hap': str(hap), 'offset': offset, 'length': inner.stat().st_size,
                   'runtimeVersion': manifest['runtimeVersion'], 'files': len(manifest['files']),
                   'bytes': sum(item['size'] for item in manifest['files']),
                   'manifestSHA256': hashlib.sha256(manifest_bytes).hexdigest(), 'innerSHA256': sha(inner),
                   'transmissionSHA256': sha(transmission), 'hapSHA256': sha(hap),
                   'scope': 'runtime-only HAP-shaped ZIP fixture; not a build-hap output or signed HAP'}
    write_json(output / 'description.json', description)
    # One canonical inner is already inside each measured wrapper. Keep the
    # transmission artifact for audit/rebuild; remove only this redundant copy.
    inner.unlink()
    return description


def run_measured(command, env, log, report):
    started = time.monotonic()
    peak_kib = None
    proc_pid = None
    samples = 0
    try:
        # In the executor /proc is mounted in an ancestor PID namespace. The
        # Popen PID is not necessarily the directory name in this /proc mount.
        proc_parent = int(os.readlink('/proc/self'))
    except (OSError, ValueError):
        proc_parent = os.getpid()
    with log.open('wb') as stream:
        process = subprocess.Popen(command, env=env, stdout=stream, stderr=subprocess.STDOUT)
        while process.poll() is None:
            try:
                if proc_pid is None:
                    # Some Linux kernels omit /proc/.../task/.../children.
                    # The measured worker records its own proc-mount identity;
                    # verify both namespaces and parent before reading memory.
                    identity = json.loads(Path(str(report) + '.identity.json').read_text())
                    candidate = int(identity['procPID'])
                    fields = dict(line.split(':', 1) for line in Path(f'/proc/{candidate}/status').read_text().splitlines() if ':' in line)
                    namespace_pids = [int(item) for item in fields.get('NSpid', str(candidate)).split()]
                    if identity['namespacePID'] == process.pid and int(fields['PPid']) == proc_parent and namespace_pids[-1] == process.pid:
                        proc_pid = candidate
                if proc_pid is None:
                    time.sleep(0.025)
                    continue
                values = Path(f'/proc/{proc_pid}/status').read_text()
                measured = []
                for line in values.splitlines():
                    if line.startswith(('VmRSS:', 'VmHWM:')):
                        measured.append(int(line.split()[1]))
                if measured:
                    peak_kib = max([peak_kib or 0] + measured)
                    samples += 1
            except (OSError, ValueError, KeyError):
                pass
            time.sleep(0.025)
        code = process.wait()
    result = {'argv': command, 'pid': process.pid, 'returncode': code,
              'wallSeconds': time.monotonic() - started, 'sampledMaxRSSKiB': peak_kib,
              'procPID': proc_pid, 'memorySamples': samples,
              'sampleIntervalSeconds': 0.025, 'log': str(log), 'report': str(report),
              'sampling': 'worker identity + NSpid + parent verified in the mounted proc namespace; null means unavailable'}
    write_json(log.with_suffix('.command.json'), result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['repo', 'raw', 'node', 'node-headers', 'typescript-prefix', 'output']:
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--scale', action='store_true')
    parser.add_argument('--compiler', default='g++')
    parser.add_argument('--source-root', type=Path,
                        help='optional exact ETS source tree, e.g. baseline + the frozen required-entry dependency')
    parser.add_argument('--reuse-archives', type=Path,
                        help='reuse a previous measured actual/scale/upgrade wrapper after verifying its recorded SHA256')
    parser.add_argument('--keep-actual-tree', action='store_true')
    args = parser.parse_args()
    args.output.mkdir()  # Refuse to overwrite previous evidence.
    source_root = args.source_root or args.repo
    inputs = args.output / 'input-sources'
    source_rows = []
    for name in ['RuntimeCore', 'RuntimeZip', 'OhosRuntimeArchive', 'OhosRuntimeStorage']:
        relative = Path('app/ohos/entry/src/main/ets/runtime') / (name + '.ets')
        source = source_root / relative
        target = inputs / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        source_rows.append({'path': relative.as_posix(), 'source': str(source), 'sha256': sha(target)})
    for name in ['runtime-archive-benchmark.py', 'runtime-archive-measure.mjs',
                 'runtime-archive-fixture.mjs', 'runtime-zip-zlib.cc']:
        relative = Path('tooling/ohos/tests') / name
        source = args.repo / relative
        target = inputs / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        source_rows.append({'path': relative.as_posix(), 'source': str(source), 'sha256': sha(target)})
    write_json(args.output / 'input-sources.json', source_rows)
    # Every measured worker imports these immutable test/source snapshots.
    tests = inputs / 'tooling/ohos/tests'
    addon = args.output / 'zlib-boundary.node'
    compile_command = [args.compiler, '-std=c++17', '-shared', '-fPIC', '-O2', '-I' + str(args.node_headers),
                       str(tests / 'runtime-zip-zlib.cc'), '-lz', '-o', str(addon)]
    compile_result = subprocess.run(compile_command, capture_output=True, text=True)
    write_json(args.output / 'compile.json', {'argv': compile_command, 'exit': compile_result.returncode,
                                            'stdout': compile_result.stdout, 'stderr': compile_result.stderr})
    compile_result.check_returncode()
    staged = args.output / 'staged'
    env = {**os.environ, 'OHOS_TEST_ZLIB_ADDON': str(addon), 'OHOS_TYPESCRIPT_PREFIX': str(args.typescript_prefix),
           'OHOS_ARCHIVE_ROOT': str(inputs), 'OHOS_ARCHIVE_STAGED': str(staged)}
    prepare = 'import {prepareArchiveModules} from ' + json.dumps((tests / 'runtime-archive-fixture.mjs').as_uri()) + '; await prepareArchiveModules(process.env.OHOS_ARCHIVE_ROOT,process.env.OHOS_ARCHIVE_STAGED);'
    command = [str(args.node), '--input-type=module', '-e', prepare]
    prepared = subprocess.run(command, env=env, capture_output=True, text=True)
    write_json(args.output / 'prepare.json', {'argv': command, 'exit': prepared.returncode,
                                            'stdout': prepared.stdout, 'stderr': prepared.stderr})
    prepared.check_returncode()

    def archive_description(kind):
        if args.reuse_archives is None:
            return build(args.raw, args.output / kind, kind)
        previous = args.reuse_archives / kind
        description = json.loads((previous / 'description.json').read_text())
        if (description['kind'] != kind or sha(Path(description['hap'])) != description['hapSHA256'] or
                sha(previous / 'dsh-runtime-rawfile.zip') != description['transmissionSHA256']):
            raise ValueError('reused archive does not match its original SHA256: ' + kind)
        if kind == 'actual' and sha(args.raw / 'manifest.json') != description['manifestSHA256']:
            raise ValueError('raw input manifest is not the reused actual archive input')
        directory = args.output / kind
        directory.mkdir()
        description['reusedFrom'] = str(previous / 'description.json')
        write_json(directory / 'description.json', description)
        return description

    summaries = []
    for kind in ['actual'] + (['scale'] if args.scale else []):
        description = archive_description(kind)
        print(json.dumps({'prepared': kind, **description}), flush=True)
        target = args.output / (kind + '-application')
        for mode in ['interrupt', 'resume', 'fresh', 'repeat']:
            if mode == 'fresh':
                # Recovery is already verified; reset only this generated test
                # application's tree to measure an uninterrupted first install.
                remove_generated_tree(target)
            report = args.output / kind / (mode + '.json')
            log = args.output / kind / (mode + '.log')
            command = [str(args.node), str(tests / 'runtime-archive-measure.mjs'), str(staged),
                       str(args.output / kind / 'description.json'), str(target), mode, str(report)]
            result = run_measured(command, env, log, report)
            if mode == 'interrupt':
                if result['returncode'] != -signal.SIGKILL:
                    raise RuntimeError('interruption did not stop the real worker with SIGKILL')
                journal = target / 'dsh-runtime/installing.json'
                if not journal.is_file() or (target / 'dsh-runtime/installed.json').exists():
                    raise RuntimeError('interruption state was falsely committed')
                result.update(journalSHA256=sha(journal), installedMarker=False)
                if report.exists():
                    result['measurement'] = json.loads(report.read_text())
            elif result['returncode'] != 0:
                raise RuntimeError('actual install worker failed: ' + str(log))
            else:
                result['measurement'] = json.loads(report.read_text())
                if mode == 'repeat' and result['measurement']['inflatedMembers'] != 0:
                    raise RuntimeError('unchanged reinstall inflated payload members')
            summaries.append({'kind': kind, 'mode': mode, **result})
            print(json.dumps({'completed': kind + '/' + mode, **result}), flush=True)
        if kind == 'actual':
            archive_description('upgrade')
            preserved = target / 'dsh-runtime/tree/node_modules/@deepseek-ai/dsh/lib/bin.js'
            changed = target / 'dsh-runtime/tree/runtime/ohos/preload.mjs'
            before = {'preservedInode': preserved.stat().st_ino, 'changedInode': changed.stat().st_ino}
            report = args.output / 'upgrade/upgrade.json'
            command = [str(args.node), str(tests / 'runtime-archive-measure.mjs'), str(staged),
                       str(args.output / 'upgrade/description.json'), str(target), 'upgrade', str(report)]
            result = run_measured(command, env, args.output / 'upgrade/upgrade.log', report)
            if result['returncode'] != 0:
                raise RuntimeError('one-member upgrade failed')
            result['measurement'] = json.loads(report.read_text())
            if result['measurement']['inflatedMembers'] != 1 or preserved.stat().st_ino != before['preservedInode'] or changed.stat().st_ino == before['changedInode']:
                raise RuntimeError('incremental upgrade did not preserve unchanged inode/one-member inflate')
            result.update(before=before, preservedInodeAfter=preserved.stat().st_ino, changedInodeAfter=changed.stat().st_ino)
            summaries.append({'kind': 'upgrade', 'mode': 'upgrade', **result})
            print(json.dumps({'completed': 'upgrade/upgrade', **result}), flush=True)
        if kind == 'scale' or not args.keep_actual_tree:
            # Release this generated application before allocating the next
            # scale tree. Input archives and all source/report evidence remain.
            remove_generated_tree(target)
    write_json(args.output / 'report.json', {'runs': summaries, 'rawInput': str(args.raw),
        'rawManifestSHA256': sha(args.raw / 'manifest.json'), 'environment': 'Linux separate real Node PIDs, real libz/fs, exact ETS method bodies',
        'pageCacheCleared': False, 'device': 'NOT_RUN', 'realInput': 'actual',
        'inputSources': str(args.output / 'input-sources.json'), 'reuseArchives': str(args.reuse_archives) if args.reuse_archives else None,
        'actualTreeKept': args.keep_actual_tree,
        'scaleFixture': 'actual input plus explicitly generated regular data; not a claimed final runtime composition'})
    print(json.dumps({'finished': str(args.output / 'report.json')}), flush=True)


if __name__ == '__main__':
    main()
