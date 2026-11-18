#!/usr/bin/env python3
"""Actual ZIP bytes/files for the bounded single-resource runtime format."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile
import zlib


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('composition', ROOT / 'runtime/ohos/package/compose-runtime.py')
composition = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(composition)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def raw_deflate(data, level):
    stream = zlib.compressobj(level, wbits=-15)
    return stream.compress(data) + stream.flush()


def inspect_records(path):
    """Check the on-disk local/central/EOCD records, not just ZipFile's view."""
    data = path.read_bytes()
    footer = struct.unpack_from('<I4H2IH', data, len(data) - 22)
    signature, disk, directory_disk, count_disk, count, directory_size, directory_offset, comment = footer
    assert signature == 0x06054b50
    assert disk == directory_disk == comment == 0
    assert count_disk == count and count < 0xffff
    assert directory_offset + directory_size == len(data) - 22
    members, local_cursor, central_cursor = [], 0, directory_offset
    with zipfile.ZipFile(path) as archive:
        assert archive.comment == b'' and len(archive.infolist()) == count
        for entry in archive.infolist():
            central = struct.unpack_from('<I6H3I5H2I', data, central_cursor)
            (magic, creator, version, flags, method, time, date, crc, packed, size,
             name_size, extra_size, comment_size, start_disk, internal, external, offset) = central
            assert magic == 0x02014b50 and creator >> 8 == 3 and version == 20
            assert flags in (0, 0x800) and extra_size == comment_size == start_disk == internal == 0
            assert external == 0o100644 << 16 and offset == local_cursor
            central_name = data[central_cursor + 46:central_cursor + 46 + name_size]
            assert central_name == entry.filename.encode('utf-8')
            assert flags == (0 if central_name.isascii() else 0x800)
            assert time == 0 and date == ((2026 - 1980) << 9) | (1 << 5) | 1
            local = struct.unpack_from('<I5H3I2H', data, offset)
            assert local == (0x04034b50, version, flags, method, time, date, crc, packed, size, name_size, 0)
            assert data[offset + 30:offset + 30 + name_size] == central_name
            body_start = offset + 30 + name_size
            body = data[body_start:body_start + packed]
            plain = body if method == 0 else zlib.decompress(body, -15)
            assert len(plain) == size and zlib.crc32(plain) == crc
            assert archive.read(entry) == plain
            members.append({'name': entry.filename, 'method': method, 'body': body, 'plain': plain})
            local_cursor = body_start + packed
            central_cursor += 46 + name_size
    assert local_cursor == directory_offset and central_cursor == len(data) - 22
    return members


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='ohos-composition-archive-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.expanded = self.root / 'expanded'
        self.files = self.expanded / 'files'
        self.files.mkdir(parents=True)
        self.content = {
            '.manifest.json': b'{"retained":true}\n',
            'empty': b'',
            'node_modules/example/dist/client.node.js': b'export const value = 1;\n',
            '中文/原字节.dat': bytes([0, 255, 0xc3, 0xa9, 10]),
        }
        for name, data in self.content.items():
            path = self.files / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(0o755)  # Build input metadata must not leak into the format.
        self.manifest = {'schema': 1, 'runtimeVersion': 'fixture', 'dshVersion': '0.2.1-rc.4',
                         'nodeVersion': '24.22.1',
                         'files': [{'path': name, 'size': len(data), 'sha256': sha(data)}
                                   for name, data in sorted(self.content.items())]}
        self.save_manifest()

    def save_manifest(self):
        (self.expanded / 'manifest.json').write_bytes(composition.json_bytes(self.manifest))

    def write(self, name='runtime.zip'):
        destination = self.root / name
        report = composition.write_runtime_archive(self.expanded, destination)
        return destination, report

    def test_exact_zip32_records_keep_dotfiles_unicode_node_js_and_empty_files(self):
        archive, report = self.write()
        members = inspect_records(archive)
        self.assertEqual([member['name'] for member in members],
                         ['manifest.json'] + ['files/' + name for name in sorted(self.content)])
        self.assertEqual(members[0]['method'], 0)
        self.assertEqual(members[0]['plain'], (self.expanded / 'manifest.json').read_bytes())
        for member in members[1:]:
            self.assertEqual(member['method'], 8)
            self.assertEqual(member['plain'], self.content[member['name'][6:]])
        self.assertEqual(report['bytes'], archive.stat().st_size)
        self.assertEqual(report['sha256'], sha(archive.read_bytes()))
        self.assertEqual(report['members'], len(self.content) + 1)

    def test_per_member_deflate_level_is_really_nine(self):
        data = b''.join((f'{{"key":{n % 731},"text":"same prefix 中文 keyvalue "}}\n'.encode() * (n % 5 + 1))
                        for n in range(2000))
        self.assertNotEqual(raw_deflate(data, 6), raw_deflate(data, 9))
        (self.files / 'level.dat').write_bytes(data)
        self.manifest['files'].append({'path': 'level.dat', 'size': len(data), 'sha256': sha(data)})
        self.manifest['files'].sort(key=lambda item: item['path'])
        self.save_manifest()
        archive, _ = self.write()
        member = next(row for row in inspect_records(archive) if row['name'] == 'files/level.dat')
        self.assertEqual(member['body'], raw_deflate(data, 9))

    def test_deterministic_bytes_ignore_source_mtime_and_permissions(self):
        first, _ = self.write('first.zip')
        for path in self.files.rglob('*'):
            if path.is_file():
                os.utime(path, (12345, 12345))
                path.chmod(0o600)
        second, _ = self.write('second.zip')
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_transport_has_exactly_one_stored_member_with_identical_inner_bytes(self):
        inner, _ = self.write()
        outer = self.root / 'dsh-runtime-rawfile.zip'
        composition.write_transport_archive(inner, outer)
        members = inspect_records(outer)
        self.assertEqual(len(members), 1)
        self.assertEqual(members[0]['name'], 'dsh-runtime/runtime.zip')
        self.assertEqual(members[0]['method'], 0)
        self.assertEqual(members[0]['plain'], inner.read_bytes())

    def test_existing_output_is_preserved(self):
        target = self.root / 'runtime.zip'
        target.write_bytes(b'keep-existing-output')
        with self.assertRaises(FileExistsError):
            self.write()
        self.assertEqual(target.read_bytes(), b'keep-existing-output')

    def test_missing_extra_and_symlink_source_files_are_rejected(self):
        original = self.files / 'empty'
        original.unlink()
        with self.assertRaisesRegex(ValueError, 'file set differs'):
            self.write()
        original.write_bytes(b'')
        extra = self.files / 'unexpected'
        extra.write_bytes(b'unknown')
        with self.assertRaisesRegex(ValueError, 'file set differs'):
            self.write()
        extra.unlink()
        original.unlink()
        original.symlink_to(self.files / '.manifest.json')
        with self.assertRaisesRegex(ValueError, 'only regular files'):
            self.write()

    def test_changed_sha_or_size_is_rejected(self):
        for index, size in enumerate([1, len(self.content['.manifest.json'])]):
            with self.subTest(size=size):
                self.manifest['files'][0]['size'] = size
                self.manifest['files'][0]['sha256'] = '0' * 64
                self.save_manifest()
                with self.assertRaisesRegex(ValueError, 'manifest size|differs from the manifest'):
                    self.write(f'bad-{index}.zip')

    def test_paths_must_be_sorted_unique_relative_and_not_native(self):
        before = list(self.manifest['files'])
        cases = [list(reversed(before)), [before[0], before[0]]]
        cases += [[{'path': name, 'size': 0, 'sha256': sha(b'')}]
                  for name in ['/absolute', '../escape', 'a/../b', 'a\\b', 'native.node', 'lib.so.1.2']]
        for index, rows in enumerate(cases):
            with self.subTest(paths=[row['path'] for row in rows]):
                self.manifest['files'] = rows
                self.save_manifest()
                with self.assertRaises(ValueError):
                    self.write(f'bad-path-{index}.zip')

    def test_empty_file_list_is_rejected_before_publishing_an_unreadable_archive(self):
        for path in list(self.files.rglob('*')):
            if path.is_file():
                path.unlink()
        self.manifest['files'] = []
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'member count'):
            self.write()

    def test_name_and_file_bounds_match_the_actual_installer_profile(self):
        cases = [({'path': 'a' * 4091, 'size': 0, 'sha256': sha(b'')}, 'member name'),
                 ({'path': 'empty', 'size': 512 * 1024 * 1024 + 1, 'sha256': sha(b'')}, 'file size')]
        for index, (row, message) in enumerate(cases):
            with self.subTest(row=row['path'][:30]):
                self.manifest['files'] = [row]
                self.save_manifest()
                with self.assertRaisesRegex(ValueError, message):
                    self.write(f'bad-bound-{index}.zip')

    def test_expanded_total_bound_is_checked_before_writing_members(self):
        self.manifest['files'] = [{'path': f'file-{i}', 'size': 512 * 1024 * 1024, 'sha256': sha(b'')}
                                  for i in range(4)]
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'expanded size'):
            self.write()

    def test_manifest_bound_and_zip64_count_sentinel_are_rejected(self):
        self.manifest['padding'] = 'a' * (16 * 1024 * 1024)
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'manifest size'):
            self.write('big-manifest.zip')
        del self.manifest['padding']
        self.manifest['files'] = [{'path': f'f{i:05d}', 'size': 0, 'sha256': sha(b'')}
                                  for i in range(65534)]
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'member count'):
            self.write('too-many.zip')


if __name__ == '__main__':
    unittest.main(verbosity=2)
