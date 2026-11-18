#!/usr/bin/env python3
"""Actual pinned HAR, real preparation/verification CLI; no SDK/compiler/device invocation."""
import copy
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'prepare-pasteboard.py'
SOURCE = Path(os.environ['DSH_EMBEDDING_HAR']).resolve(strict=True)
CONFIG = json.loads((HELPER.parent / 'embedding-fixes/pasteboard-settlement.json').read_text())


class PortableHar(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='portable-har-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.original_sha = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
        result = cls.cli('--input-har', SOURCE, '--output', cls.root / 'prepared')
        if result.returncode:
            raise AssertionError(result.stderr)
        cls.prepared = cls.root / 'prepared/flutter_embedding_release.har'
        with tarfile.open(cls.prepared, 'r:gz') as archive:
            cls.members = [(m, archive.extractfile(m).read() if m.isfile() else None) for m in archive.getmembers()]

    @classmethod
    def tearDownClass(cls):
        if hashlib.sha256(SOURCE.read_bytes()).hexdigest() != cls.original_sha:
            raise AssertionError('original HAR changed')

    @staticmethod
    def cli(*args):
        return subprocess.run([sys.executable, '-I', '-B', str(HELPER), *map(str, args)],
                              capture_output=True, text=True, timeout=30)

    def repack(self, change=None, level=9, mtime=0):
        entries = [(copy.copy(m), data) for m, data in self.members]
        if change: change(entries)
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w', format=tarfile.PAX_FORMAT) as archive:
            for member, data in entries:
                if data is not None: member.size = len(data)
                archive.addfile(member, io.BytesIO(data) if data is not None else None)
        path = self.root / (self.id().split('.')[-1] + '.har')
        path.write_bytes(gzip.compress(stream.getvalue(), compresslevel=level, mtime=mtime))
        return path

    def verify(self, path, expected=True, source=SOURCE):
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        result = self.cli('--input-har', source, '--verify-har', path)
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), before)
        if expected:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('unrecognized arguments', result.stderr)
        return result

    def test_same_members_with_different_gzip_bytes_are_accepted(self):
        first = self.verify(self.prepared)
        alternate = self.repack(level=1, mtime=123456789)
        self.assertNotEqual(alternate.read_bytes(), self.prepared.read_bytes())
        second = self.verify(alternate)
        self.assertEqual(first['membersSha256'], second['membersSha256'])
        self.assertNotEqual(first['harSha256'], second['harSha256'])

    def test_stored_deflate_payload_has_the_same_identity(self):
        self.assertEqual(self.verify(self.prepared)['membersSha256'],
                         self.verify(self.repack(level=0))['membersSha256'])

    def test_wrong_original_is_rejected_before_preparation_and_verification(self):
        bad = self.root / 'wrong-source.har'; bad.write_bytes(SOURCE.read_bytes() + b'wrong')
        output = self.root / 'must-not-exist'
        result = self.cli('--input-har', bad, '--output', output)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('input HAR SHA256', result.stderr)
        self.assertFalse(output.exists())
        result = self.verify(self.prepared, False, bad)
        self.assertIn('input HAR SHA256', result.stderr)

    def test_unmodified_member_change_is_not_hidden_by_matching_target_hashes(self):
        targets = {fix['target'] for fix in CONFIG['fixes']}
        def change(entries):
            index = next(i for i, (m, _) in enumerate(entries) if m.isfile() and m.name not in targets)
            member, data = entries[index]; entries[index] = (member, data + b'changed')
        self.verify(self.repack(change), False)

    def test_target_change_is_rejected(self):
        target = CONFIG['fixes'][0]['target']
        def change(entries):
            index = next(i for i, (m, _) in enumerate(entries) if m.name == target)
            member, data = entries[index]; entries[index] = (member, data + b'changed')
        self.verify(self.repack(change), False)

    def test_extra_member_is_rejected(self):
        def change(entries):
            member = tarfile.TarInfo('package/unexpected.txt'); member.mode = 0o644
            entries.append((member, b'extra'))
        self.verify(self.repack(change), False)

    def test_members_after_tar_end_marker_are_not_ignored(self):
        extra = io.BytesIO()
        with tarfile.open(fileobj=extra, mode='w') as archive:
            member = tarfile.TarInfo('package/after-trailer.txt'); member.size = 5
            archive.addfile(member, io.BytesIO(b'extra'))
        path = self.root / 'concatenated.har'
        path.write_bytes(self.prepared.read_bytes() + gzip.compress(extra.getvalue(), mtime=0))
        self.verify(path, False)

    def test_missing_member_is_rejected(self):
        def change(entries): entries.pop(next(i for i, (m, _) in enumerate(entries) if m.isfile()))
        self.verify(self.repack(change), False)

    def test_duplicate_path_is_rejected(self):
        def change(entries):
            member, data = next((m, data) for m, data in entries if m.isfile())
            entries.append((copy.copy(member), data))
        self.verify(self.repack(change), False)

    def test_normalized_duplicate_path_is_rejected(self):
        def change(entries):
            member, data = next((m, data) for m, data in entries if m.isfile())
            member = copy.copy(member); member.name = member.name.replace('package/', 'package/./', 1)
            entries.append((member, data))
        self.verify(self.repack(change), False)

    def test_file_and_directory_modes_are_pinned(self):
        for directory in (False, True):
            with self.subTest(directory=directory):
                def change(entries): next(m for m, _ in entries if m.isdir() == directory).mode ^= 0o100
                self.verify(self.repack(change), False)

    def test_symlink_and_directory_type_substitutions_are_rejected(self):
        for kind in (tarfile.SYMTYPE, tarfile.DIRTYPE):
            with self.subTest(kind=kind):
                def change(entries):
                    index = next(i for i, (m, _) in enumerate(entries) if m.isfile())
                    member, _ = entries[index]; member.type = kind; member.size = 0; member.linkname = 'outside'
                    entries[index] = (member, None)
                self.verify(self.repack(change), False)

    def test_parent_path_is_rejected(self):
        def change(entries):
            member = tarfile.TarInfo('package/../escape'); entries.append((member, b'escape'))
        self.verify(self.repack(change), False)

    def test_build_entries_call_member_verifier_instead_of_a_compressed_byte_pin(self):
        for name in ('build-hap.sh', 'check-arkts.sh'):
            with self.subTest(name=name):
                source = (HELPER.parent / name).read_text()
                self.assertIn('--verify-har', source)
                self.assertNotIn('PREPARED_HAR_SHA256', source)


if __name__ == '__main__':
    unittest.main()
