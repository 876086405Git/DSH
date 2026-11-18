#!/usr/bin/env python3
"""Audit the bounded OH runtime ZIP32 profile without extracting its tree.

Only archive structure/content is covered here. Native libs, signing, resources,
Ark compilation, and the device remain the responsibility of audit-hap/mainline.
"""
import ast
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import tempfile
import zipfile
import zlib

ASSET = 'dsh-runtime/runtime.zip'
HAP_ASSET = 'resources/rawfile/' + ASSET
CHUNK = 256 * 1024
MAX_ARCHIVE = 0x7fffffff
MAX_FILE = 512 * 1024 * 1024
MAX_SAFE_INTEGER = (1 << 53) - 1


def require(condition, message):
    if not condition:
        raise ValueError(message)


def safe_path(name):
    require(isinstance(name, str) and name and '\\' not in name and '\0' not in name and
            all(part not in ('', '.', '..') for part in name.split('/')) and
            not re.search(r'(?:\.node|\.so(?:\.\d+)*)\Z', name, re.I | re.ASCII), 'unsafe/native manifest path')


def required_entries(repo=None):
    """Read the existing Host/Core facts, never maintain another path list.

    The composer validates these same literal File calls and the Core entry
    loop. Refuse changed source shapes or disagreement instead of guessing.
    """
    repo = Path(repo) if repo is not None else Path(__file__).resolve().parents[2]
    host = (repo / 'app/ohos/entry/src/main/cpp/host_core.cpp').read_text()
    calls = re.findall(r'\bFile\s*\(\s*options\.runtime_root\s*,', host)
    entries = re.findall(r'\bFile\s*\(\s*options\.runtime_root\s*,\s*"([^"\n]+)"\s*\)', host)
    require(entries and len(calls) == len(entries), 'Host runtime requirements are no longer literal File calls')
    core = (repo / 'app/ohos/entry/src/main/ets/runtime/RuntimeCore.ets').read_text()
    loops = re.findall(r'for \(const entry of \[([^\]]+)\]\)', core)
    require(len(loops) == 1, 'RuntimeCore required-entry loop is no longer the checked literal array')
    try:
        manifest_entries = ast.literal_eval('[' + loops[0] + ']')
    except (ValueError, SyntaxError) as error:
        raise ValueError('RuntimeCore required-entry array contains a non-literal value') from error
    require(all(isinstance(item, str) and item for item in manifest_entries) and
            set(entries) == set(manifest_entries), 'Host::Start and RuntimeCore required entries differ')
    return sorted(set(entries))


def safe_integer(value):
    # JSON 1.0 and -0 are JavaScript numbers; booleans are not. Check the range
    # before int conversion so non-finite and arbitrarily large values fail.
    return type(value) in (int, float) and -MAX_SAFE_INTEGER <= value <= MAX_SAFE_INTEGER and int(value) == value


def parse_manifest(data):
    def non_json_constant(value):
        raise ValueError('non-JSON numeric literal in manifest: ' + value)
    return json.loads(data.decode('utf-8'), parse_constant=non_json_constant)


def validate_manifest(manifest):
    """Match RuntimeCore.validateManifest's JSON-domain acceptance rules."""
    require(isinstance(manifest, dict) and type(manifest.get('schema')) in (int, float) and
            manifest['schema'] == 1 and isinstance(manifest.get('runtimeVersion'), str) and
            manifest['runtimeVersion'] and isinstance(manifest.get('dshVersion'), str) and
            manifest.get('nodeVersion') == '24.22.1' and isinstance(manifest.get('files'), list) and
            manifest['files'], 'invalid manifest')
    paths = set()
    for item in manifest['files']:
        require(isinstance(item, dict), 'invalid manifest item')
        name = item.get('path')
        safe_path(name)
        require(name not in paths and safe_integer(item.get('size')) and item['size'] >= 0 and
                isinstance(item.get('sha256'), str) and re.fullmatch('[a-f0-9]{64}', item['sha256']) is not None,
                'invalid manifest item size/SHA256 or duplicate path')
        paths.add(name)
    for name in paths:
        require(not any(parent.as_posix() in paths for parent in PurePosixPath(name).parents if str(parent) != '.'),
                'file/directory conflict')
    require(set(required_entries()).issubset(paths), 'manifest lacks a Host/Core required runtime entry')
    return manifest


def inspect_deflate(raw, entry, expected_sha):
    """Verify the entire declared compressed range with bounded raw inflate.

    ZipExtFile is unsuitable for this gate: it can stop at file_size and hide
    expanded bytes or trailing compressed input. Here EOF, consumed bytes,
    actual size, CRC and SHA must all agree before admission.
    """
    raw.seek(entry.header_offset + 30 + len(entry.filename.encode('utf-8')))
    remaining = entry.compress_size
    pending = b''
    stream = zlib.decompressobj(-15)
    received = 0
    crc = 0
    digest = hashlib.sha256()
    magic = b''
    while True:
        if not pending and remaining:
            length = min(CHUNK, remaining)
            pending = raw.read(length)
            require(len(pending) == length, 'short compressed member')
            remaining -= length
        previous_size = len(pending)
        # One byte beyond the declared size is enough to prove overflow. Do
        # not expand an entire bomb just to discover a forged one-byte size.
        output = stream.decompress(pending, min(CHUNK, entry.file_size - received + 1))
        pending = stream.unconsumed_tail
        received += len(output)
        require(received <= entry.file_size, 'member exceeds manifest size')
        if len(magic) < 4:
            magic = (magic + output)[:4]
        require(magic != b'\x7fELF', 'ELF payload cannot enter writable runtime')
        digest.update(output)
        crc = zlib.crc32(output, crc)
        if stream.eof:
            require(not stream.unused_data and not pending and remaining == 0,
                    'Deflate stream has trailing or unconsumed compressed bytes')
            break
        require(output or len(pending) < previous_size, 'truncated or stalled Deflate stream')
    require(received == entry.file_size and crc == entry.CRC and digest.hexdigest() == expected_sha,
            'member size/CRC/SHA256 mismatch')
    return received


def copy_archive(source, target):
    digest = hashlib.sha256()
    count = 0
    while True:
        chunk = source.read(CHUNK)
        if not chunk:
            break
        count += len(chunk)
        require(count <= MAX_ARCHIVE, 'archive exceeds ZIP32 profile bound')
        target.write(chunk)
        digest.update(chunk)
    target.seek(0)
    return count, digest.hexdigest()


def inspect_archive(raw):
    raw.seek(0, 2)
    length = raw.tell()
    require(22 <= length <= MAX_ARCHIVE, 'archive size outside profile')
    raw.seek(length - 22)
    signature, disk, directory_disk, on_disk, count, directory_size, directory_offset, comment = struct.unpack('<I4H2IH', raw.read(22))
    require(signature == 0x06054b50 and disk == directory_disk == comment == 0 and on_disk == count and
            2 <= count < 0xffff and directory_offset + directory_size == length - 22 and
            count * 46 <= directory_size <= 32 * 1024 * 1024, 'unsupported or inconsistent EOCD')
    with zipfile.ZipFile(raw) as archive:
        entries = archive.infolist()
        require(len(entries) == count and len({entry.filename for entry in entries}) == count, 'duplicate/count mismatch')
        require(entries[0].filename == 'manifest.json', 'manifest must be first')
        expected_offset = 0
        central_used = 0
        expanded = 0
        for index, entry in enumerate(entries):
            name = entry.filename.encode('utf-8')
            require(entry.create_system == 3 and entry.external_attr >> 16 == 0o100644 and
                    entry.extract_version <= 20 and entry.reserved == 0 and entry.flag_bits in (0, 0x800) and not entry.extra and
                    not entry.comment and entry.volume == 0 and entry.internal_attr == 0 and
                    0 < len(name) <= 4096 and entry.header_offset == expected_offset and
                    0 <= entry.file_size <= MAX_FILE and 0 <= entry.compress_size <= MAX_ARCHIVE and
                    (entry.flag_bits == 0x800 or name.isascii()), 'unsupported member metadata')
            require(entry.compress_type == (zipfile.ZIP_STORED if index == 0 else zipfile.ZIP_DEFLATED),
                    'manifest must be Stored and files must be Deflate')
            require(index == 0 or entry.filename.startswith('files/'), 'unexpected member')
            raw.seek(entry.header_offset)
            local = raw.read(30)
            require(len(local) == 30, 'short local header')
            magic, version, flags, method, time, date, crc, packed, size, name_size, extra_size = struct.unpack('<I5H3I2H', local)
            require(magic == 0x04034b50 and version == entry.extract_version and flags == entry.flag_bits and
                    method == entry.compress_type and crc == entry.CRC and packed == entry.compress_size and
                    size == entry.file_size and name_size == len(name) and extra_size == 0 and
                    raw.read(name_size) == name, 'local/central header mismatch')
            observed_date = ((date >> 9) + 1980, (date >> 5) & 15, date & 31, time >> 11, (time >> 5) & 63, (time & 31) * 2)
            require(observed_date == entry.date_time, 'local/central timestamp mismatch')
            expected_offset += 30 + name_size + packed
            central_used += 46 + name_size
            expanded += entry.file_size
            require(expected_offset <= directory_offset, 'member overlaps central directory')
            require(expanded <= MAX_ARCHIVE, 'expanded tree exceeds profile')
        require(expected_offset == directory_offset and central_used == directory_size, 'hidden data or unsupported central record')
        require(entries[0].file_size <= 16 * 1024 * 1024 and entries[0].file_size == entries[0].compress_size,
                'manifest size outside profile')
        manifest = validate_manifest(parse_manifest(archive.read(entries[0])))
        require(len(manifest['files']) == count - 1, 'manifest/member count mismatch')
        paths = set()
        payload_bytes = 0
        for item, entry in zip(manifest['files'], entries[1:]):
            name = item['path']
            require(entry.filename == 'files/' + name and entry.file_size == item['size'], 'manifest/member mismatch')
            paths.add(name)
            received = inspect_deflate(raw, entry, item['sha256'])
            payload_bytes += received
            require(payload_bytes + entries[0].file_size <= MAX_ARCHIVE, 'expanded tree exceeds profile')
        return {'runtimeVersion': manifest['runtimeVersion'], 'files': len(paths), 'bytes': payload_bytes,
                'archiveBytes': length, 'manifestBytes': entries[0].file_size,
                'dotfiles': sum(any(part.startswith('.') for part in name.split('/')) for name in paths),
                'missing': 0, 'wrong': 0, 'extra': 0}


def audit_runtime(hap, runtime_input):
    problems = []
    report = {}
    try:
        entries = [entry for entry in hap.infolist() if entry.filename.startswith('resources/rawfile/dsh-runtime/')]
        require(len(entries) == 1 and entries[0].filename == HAP_ASSET, 'HAP must contain exactly one runtime rawfile')
        require(entries[0].compress_type == zipfile.ZIP_STORED and entries[0].compress_size == entries[0].file_size,
                'HAP runtime archive must be exact Stored bytes for getRawFd')
        with zipfile.ZipFile(runtime_input) as source:
            source_entries = source.infolist()
            require(len(source_entries) == 1 and source_entries[0].filename == ASSET and
                    source_entries[0].compress_type == zipfile.ZIP_STORED and
                    source_entries[0].compress_size == source_entries[0].file_size,
                    'composer input must contain only Stored dsh-runtime/runtime.zip')
            with tempfile.TemporaryFile() as expected, tempfile.TemporaryFile() as actual:
                with source.open(source_entries[0]) as member:
                    source_size, source_sha = copy_archive(member, expected)
                with hap.open(entries[0]) as member:
                    hap_size, hap_sha = copy_archive(member, actual)
                require((source_size, source_sha) == (hap_size, hap_sha), 'packaged runtime archive differs from composer input')
                report = inspect_archive(actual)
                report.update(archiveSHA256=hap_sha, identicalToInput=True, stored=True)
    except (ValueError, KeyError, TypeError, UnicodeError, OSError, zipfile.BadZipFile, struct.error, zlib.error) as error:
        problems.append('runtime archive: ' + str(error))
    return report, problems
