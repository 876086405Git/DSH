#!/usr/bin/env python3
"""Prepare a private, pinned Flutter embedding HAR with its source fixes.

The fixes are embedding-fixes/pasteboard-settlement.json's: IME paste settlement,
clipboard availability settlement and haptic presets. Never edits the input HAR,
SDK, build-hap.sh or application permissions. Output is a new directory containing the HAR, matching
extracted package, license notices and exact byte audit. A caller chooses how to stage
this private bundle into its build; production build integration is intentionally separate.
"""
import argparse
import copy
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zlib


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_source(source):
    root = Path(__file__).resolve().parent / 'embedding-fixes'
    config_bytes = (root / 'pasteboard-settlement.json').read_bytes()
    config = json.loads(config_bytes)
    if config['schema'] != 2:
        raise ValueError('unsupported preparation schema')
    archive = source.read_bytes()
    if sha(archive) != config['upstream']['harSha256']:
        raise ValueError('input HAR SHA256 does not match the pinned release')
    fixes = config['fixes']
    for fix in fixes:
        if sha((root / fix['patch']).read_bytes()) != fix['patchSha256']:
            raise ValueError('patch SHA256 mismatch: ' + fix['patch'])
    for name, expected in config['licenses'].items():
        if sha((root / name).read_bytes()) != expected:
            raise ValueError('license SHA256 mismatch: ' + name)
    return root, config_bytes, config, archive


def archive_contents(archive):
    seen = set()
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz', ignore_zeros=True) as tar:
        members = tar.getmembers()
        blobs = {}
        for member in members:
            name = PurePosixPath(member.name)
            if name.is_absolute() or '..' in name.parts or not name.parts or name.parts[0] != 'package':
                raise ValueError('unexpected archive member path')
            canonical = name.as_posix()
            if canonical in seen:
                raise ValueError('duplicate archive member path')
            seen.add(canonical)
            if not member.isfile() and not member.isdir():
                raise ValueError('unexpected non-file archive member')
            data = tar.extractfile(member).read() if member.isfile() else None
            blobs[member.name] = data
    return members, blobs


def member_manifest(members, blobs):
    # gzip framing, tar padding/order, timestamps and ownership are transport
    # metadata. Paths, types, modes and every file's bytes define this package.
    return sorted([{'path': member.name, 'type': 'directory' if member.isdir() else 'file',
                    'mode': member.mode, 'sha256': sha(blobs[member.name]) if member.isfile() else None}
                   for member in members], key=lambda row: row['path'])


def manifest_sha(members):
    return sha(json.dumps(members, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8'))


def verify_prepared(source, prepared):
    _, config_bytes, config, archive = read_source(source)
    members, blobs = archive_contents(archive)
    expected = member_manifest(members, blobs)
    expected_files = {row['path']: row for row in expected if row['type'] == 'file'}
    for fix in config['fixes']:
        if expected_files.get(fix['target'], {}).get('sha256') != fix['beforeSha256']:
            raise ValueError('target SHA256 mismatch: ' + fix['target'])
        expected_files[fix['target']]['sha256'] = fix['afterSha256']
    for name, digest in config['consumers'].items():
        if sha(blobs[name]) != digest:
            raise ValueError('consumer SHA256 mismatch: ' + name)
    data = prepared.read_bytes()
    actual = member_manifest(*archive_contents(data))
    if actual != expected:
        raise ValueError('prepared HAR member identity mismatch')
    if sha(source.read_bytes()) != config['upstream']['harSha256']:
        raise ValueError('source HAR changed while verifying')
    return {'status': 'VERIFIED_MEMBERS', 'memberIdentitySchema': 1,
            'sourceHarSha256': sha(archive), 'harSha256': sha(data),
            'membersSha256': manifest_sha(actual), 'memberCount': len(actual),
            'configSha256': sha(config_bytes)}


def prepare(source, output):
    root, config_bytes, config, archive = read_source(source)
    fixes = config['fixes']
    if os.path.lexists(output):
        raise FileExistsError('output must be a new directory')

    members, blobs = archive_contents(archive)
    before = {name: sha(data) for name, data in blobs.items() if data is not None}
    for fix in fixes:
        if before.get(fix['target']) != fix['beforeSha256']:
            raise ValueError('target SHA256 mismatch: ' + fix['target'])
    for name, expected in config['consumers'].items():
        if before.get(name) != expected:
            raise ValueError('consumer SHA256 mismatch: ' + name)

    # Isolated temporary directory outside any checkout: git apply never modifies
    # an installed SDK or accidentally interprets a parent repository index.
    with tempfile.TemporaryDirectory(prefix='dsh-pasteboard-patch-') as temporary:
        for fix in fixes:
            target, patch = fix['target'], root / fix['patch']
            copy_path = Path(temporary) / target
            copy_path.parent.mkdir(parents=True, exist_ok=True)
            copy_path.write_bytes(blobs[target])
            for argv in [['git', 'apply', '--check', str(patch)], ['git', 'apply', str(patch)]]:
                subprocess.run(argv, cwd=temporary, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            changed = copy_path.read_bytes()
            if sha(changed) != fix['afterSha256']:
                raise ValueError('patched SHA256 mismatch: ' + target)
            # Copyright header is unchanged. Retain all source bytes except the pinned diff.
            if changed.split(b'import ', 1)[0] != blobs[target].split(b'import ', 1)[0]:
                raise ValueError('upstream notice changed: ' + target)
            blobs[target] = changed
    targets = sorted(fix['target'] for fix in fixes)

    tar_bytes = io.BytesIO()
    with tarfile.open(fileobj=tar_bytes, mode='w', format=tarfile.PAX_FORMAT) as tar:
        for original in members:
            member = copy.copy(original)
            if member.name in targets:
                member.size = len(blobs[member.name])
            data = blobs[member.name]
            tar.addfile(member, io.BytesIO(data) if data is not None else None)
    compressed_stream = io.BytesIO()
    with gzip.GzipFile(fileobj=compressed_stream, mode='wb', filename='', compresslevel=9, mtime=0) as compressed_file:
        compressed_file.write(tar_bytes.getvalue())
    compressed = compressed_stream.getvalue()
    output_members = member_manifest(*archive_contents(compressed))
    if output_members != member_manifest(members, blobs):
        raise ValueError('generated HAR members differ from prepared source')
    after = {name: sha(data) for name, data in blobs.items() if data is not None}
    differences = [name for name in before if before[name] != after[name]]
    if sorted(differences) != targets:
        raise ValueError('unexpected changes outside the fixed files')
    if sha(source.read_bytes()) != config['upstream']['harSha256']:
        raise ValueError('source HAR changed while preparing')

    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.pasteboard-stage-', dir=output.parent))
    try:
        (stage / 'flutter_embedding_release.har').write_bytes(compressed)
        for member in members:
            destination = stage / member.name
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(blobs[member.name])
                destination.chmod(member.mode & 0o777)
        licenses = stage / 'licenses'
        licenses.mkdir()
        for name in config['licenses']:
            shutil.copyfile(root / name, licenses / name)
        for fix in fixes:
            shutil.copyfile(root / fix['patch'], stage / fix['patch'])
        report = {
            'schema': 1, 'sourceHar': str(source), 'sourceHarSha256': sha(archive),
            'memberIdentitySchema': 1, 'outputMembersSha256': manifest_sha(output_members),
            'outputMembers': output_members, 'outputHarSha256': sha(compressed), 'patches': {fix['patch']: fix['patchSha256'] for fix in fixes},
            'configSha256': sha(config_bytes), 'preparerSha256': sha(Path(__file__).read_bytes()),
            'pythonVersion': sys.version, 'zlibVersion': zlib.ZLIB_RUNTIME_VERSION,
            'changedFiles': differences, 'regularFileCount': len(before),
            'before': before, 'after': after, 'licenses': config['licenses'],
            'status': 'PREPARED_ONLY: exact ArkTS/build/device verification required',
        }
        (stage / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        if os.path.lexists(output):
            raise FileExistsError('output appeared while preparing')
        stage.rename(output)
        return report
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-har', required=True, type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--output', type=Path)
    mode.add_argument('--verify-har', type=Path, help='verify every decompressed member against the pinned original and fixes')
    args = parser.parse_args()
    if args.verify_har is not None:
        print(json.dumps(verify_prepared(args.input_har.resolve(), args.verify_har.resolve()), indent=2))
        return
    report = prepare(args.input_har.resolve(), args.output.absolute())
    print(json.dumps({'output': str(args.output.absolute()), 'harSha256': report['outputHarSha256'],
                      'membersSha256': report['outputMembersSha256'], 'changedFiles': report['changedFiles'], 'regularFileCount': report['regularFileCount']}, indent=2))


if __name__ == '__main__':
    main()
