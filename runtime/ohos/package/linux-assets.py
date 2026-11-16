#!/usr/bin/env python3
"""Build-time validation for the optional, trusted Linux installation data.

The caller selects a trusted build directory. Its manifest may name only the five
fixed data files, never native libraries or host paths. Runtime publication still
uses the existing whole-payload manifest and installer transaction.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import zipfile
import zlib

DIRECTORY = 'runtime/ohos/linux/assets'
ASSETS = {'bios': 'bbl64.bin', 'kernel': 'kernel-riscv64.bin', 'tools': 'tools.block',
          'bootstrap': 'bootstrap.ext4.gz', 'empty': 'empty.ext4.gz'}
NAMES = ('install-manifest.json', *ASSETS.values())
ARCHIVE = {'url': 'https://repo.huaweicloud.com/alpine/v3.24/releases/riscv64/alpine-minirootfs-3.24.4-riscv64.tar.gz',
           'bytes': 3451625, 'sha256': '010683db6c73b3ad1c334fc8f93f64ae748ef67ae6d69e964929aeaf8517bff3'}
MAX_FILE = 512 * 1024 * 1024
MAX_MANIFEST = 65536
CHUNK = 1024 * 1024


def unique_object(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError(f'Duplicate Linux manifest field: {key}')
        result[key] = value
    return result


def positive_size(value):
    return type(value) is int and 0 < value <= MAX_FILE


def valid_hash(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def parse_manifest(data):
    if not 0 < len(data) <= MAX_MANIFEST:
        raise ValueError('Linux installation manifest exceeds its size limit')
    value = json.loads(data.decode('utf-8'), object_pairs_hook=unique_object)
    if not isinstance(value, dict) or set(value) != {*ASSETS, 'archive'}:
        raise ValueError('Linux installation manifest must contain exactly five assets and archive')
    if value['archive'] != ARCHIVE or type(value['archive'].get('bytes')) is not int:
        raise ValueError('Linux base archive differs from the fixed version/URL/bytes/SHA256')
    for role, name in ASSETS.items():
        row = value[role]
        fields = {'path', 'bytes', 'sha256'}
        if role in ('bootstrap', 'empty'):
            fields |= {'expandedBytes', 'expandedSha256'}
        if not isinstance(row, dict) or set(row) != fields or row['path'] != name:
            raise ValueError(f'Linux {role} must name only its fixed asset and fields: {name}')
        if not positive_size(row['bytes']) or not valid_hash(row['sha256']):
            raise ValueError(f'Invalid Linux asset size/SHA256: {role}')
        if role in ('bootstrap', 'empty') and (not positive_size(row['expandedBytes']) or
                                               not valid_hash(row['expandedSha256'])):
            raise ValueError(f'Invalid Linux expanded image size/SHA256: {role}')
        if role == 'tools' and row['bytes'] % 512:
            raise ValueError('Linux tools.block must be aligned to 512 bytes')
    return value


def check_stream(stream, row):
    digest = hashlib.sha256()
    count = 0
    while data := stream.read(min(CHUNK, row['bytes'] - count + 1)):
        count += len(data)
        if count > row['bytes']:
            raise ValueError('Linux asset exceeds declared bytes')
        digest.update(data)
    if count != row['bytes'] or digest.hexdigest() != row['sha256']:
        raise ValueError('Linux asset differs from declared bytes/SHA256')
    if 'expandedBytes' in row:
        stream.seek(0)
        expanded, size = hashlib.sha256(), 0
        try:
            with gzip.GzipFile(fileobj=stream, mode='rb') as image:
                while data := image.read(min(CHUNK, row['expandedBytes'] - size + 1)):
                    size += len(data)
                    if size > row['expandedBytes']:
                        raise ValueError('Linux gzip exceeds declared expanded bytes')
                    expanded.update(data)
        except (OSError, EOFError, zlib.error) as error:
            raise ValueError('Invalid Linux gzip image') from error
        if size != row['expandedBytes'] or expanded.hexdigest() != row['expandedSha256']:
            raise ValueError('Linux gzip differs from expanded bytes/SHA256')


def open_regular(path, limit=MAX_FILE):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= limit:
            raise ValueError(f'Linux asset must be an unshared bounded regular file: {path.name}')
        return os.fdopen(descriptor, 'rb')
    except BaseException:
        os.close(descriptor)
        raise


def receipt(manifest, manifest_bytes):
    files = [{'path': NAMES[0], 'size': len(manifest_bytes),
              'sha256': hashlib.sha256(manifest_bytes).hexdigest()}]
    files.extend({'path': row['path'], 'size': row['bytes'], 'sha256': row['sha256']}
                 for role, row in manifest.items() if role != 'archive')
    return {'directory': DIRECTORY, 'manifestSha256': files[0]['sha256'],
            'archive': dict(ARCHIVE), 'files': sorted(files, key=lambda row: row['path'])}


def verify_assets(directory):
    directory = Path(directory).absolute()
    if not stat.S_ISDIR(directory.lstat().st_mode):
        raise ValueError('Linux assets input must be a real directory, not a symlink')
    if {path.name for path in directory.iterdir()} != set(NAMES):
        raise ValueError('Linux assets directory must contain exactly the six fixed files')
    with open_regular(directory / NAMES[0], MAX_MANIFEST) as source:
        data = source.read(MAX_MANIFEST + 1)
    manifest = parse_manifest(data)
    for role, name in ASSETS.items():
        with open_regular(directory / name) as source:
            check_stream(source, manifest[role])
    return receipt(manifest, data)


def publish_assets(image, destination):
    """Publish only six verified files inside a new private build output."""
    image, destination = Path(image), Path(destination)
    if destination.exists() or destination.is_symlink():
        raise ValueError('Linux assets output already exists; preserved')
    staging = Path(tempfile.mkdtemp(prefix='.linux-assets-', dir=destination.parent))
    try:
        for name in NAMES:
            with open_regular(image / name, MAX_MANIFEST if name == NAMES[0] else MAX_FILE) as source:
                with (staging / name).open('xb') as target:
                    shutil.copyfileobj(source, target, CHUNK)
            (staging / name).chmod(0o644)
        result = verify_assets(staging)
        if destination.exists() or destination.is_symlink():
            raise ValueError('Linux assets output already exists; preserved')
        os.rename(staging, destination)
        return result
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def verify_runtime_archive(bundle, native_libraries):
    """Check the actual inner ZIP; library-only component builds remain valid."""
    root = 'files/' + DIRECTORY
    entries = [entry for entry in bundle.infolist()
               if entry.filename == root or entry.filename.startswith(root + '/')]
    if not entries:
        return None
    expected = {root + '/' + name for name in NAMES}
    names = [entry.filename for entry in entries]
    if len(names) != len(expected) or set(names) != expected:
        raise ValueError('Packaged Linux assets must be exactly the six fixed files without duplicates')
    if any(parent in bundle.namelist() for parent in ('files', 'files/runtime', 'files/runtime/ohos',
                                                      'files/runtime/ohos/linux')):
        raise ValueError('Packaged Linux assets have a file/directory parent conflict')
    if 'libdsh_linux.so' not in native_libraries:
        raise ValueError('Packaged Linux assets require libdsh_linux.so in HAP native libraries')
    for entry in entries:
        mode = (entry.external_attr >> 16) & 0xffff
        if entry.is_dir() or stat.S_IFMT(mode) not in (0, stat.S_IFREG) or entry.flag_bits & 1:
            raise ValueError('Packaged Linux asset is not an ordinary unencrypted file')
    entry = bundle.getinfo(root + '/' + NAMES[0])
    if not 0 < entry.file_size <= MAX_MANIFEST:
        raise ValueError('Packaged Linux manifest exceeds its size limit')
    data = bundle.read(entry)
    manifest = parse_manifest(data)
    for role, name in ASSETS.items():
        entry = bundle.getinfo(root + '/' + name)
        if entry.file_size != manifest[role]['bytes']:
            raise ValueError('Packaged Linux asset size differs from installation manifest')
        with bundle.open(entry) as stream:
            check_stream(stream, manifest[role])
    return receipt(manifest, data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-zip', type=Path, required=True)
    parser.add_argument('--native-directory', type=Path, required=True)
    args = parser.parse_args()
    libraries = {'libdsh_linux.so'} if (args.native_directory / 'libdsh_linux.so').is_file() else set()
    try:
        with zipfile.ZipFile(args.runtime_zip) as bundle:
            result = verify_runtime_archive(bundle, libraries)
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        parser.exit(1, f'Linux assets validation failed: {error}\n')
    print(json.dumps({'linuxAssets': result}, sort_keys=True))


if __name__ == '__main__':
    main()
