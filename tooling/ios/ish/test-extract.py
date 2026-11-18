#!/usr/bin/env python3
"""Pinned-source extraction on Python 3.9; synthetic archives never leave staging."""
import importlib.util
import io
import os
import pathlib
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('ish_build', pathlib.Path(__file__).with_name('build.py'))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
PREFIX = 'ish-arm64-' + build.LOCK['commit']


def archive(rows):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w') as writer:
        for name, kind, payload in rows:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.mode = 0o755 if kind == tarfile.DIRTYPE else 0o640
            if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                info.linkname = payload
                writer.addfile(info)
            elif kind == tarfile.REGTYPE:
                data = payload.encode()
                info.size = len(data)
                writer.addfile(info, io.BytesIO(data))
            else:
                writer.addfile(info)
    buffer.seek(0)
    return tarfile.open(fileobj=buffer, mode='r:')


class ExtractionTests(unittest.TestCase):
    def test_regular_and_directory_content_mode(self):
        with tempfile.TemporaryDirectory() as tmp, archive([
                (PREFIX, tarfile.DIRTYPE, ''),
                (PREFIX + '/中文 file', tarfile.REGTYPE, 'contents')]) as source:
            build.extract_source(source, pathlib.Path(tmp))
            path = pathlib.Path(tmp) / PREFIX / '中文 file'
            self.assertEqual(path.read_text(), 'contents')
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)

    def test_paths_links_special_members_and_collisions_reject_before_writes(self):
        bad = [
            [('/outside', tarfile.REGTYPE, 'bad')],
            [(PREFIX + '/../outside', tarfile.REGTYPE, 'bad')],
            [(PREFIX + '/a/../../outside', tarfile.REGTYPE, 'bad')],
            [(PREFIX + '/C:outside', tarfile.REGTYPE, 'bad')],
            [(PREFIX + '/a\\outside', tarfile.REGTYPE, 'bad')],
            [(PREFIX + '/link', tarfile.SYMTYPE, '../../outside')],
            [(PREFIX + '/link', tarfile.SYMTYPE, '/outside')],
            [(PREFIX + '/link', tarfile.LNKTYPE, '../../outside')],
            [(PREFIX + '/link', tarfile.LNKTYPE, PREFIX + '/file')],
            [(PREFIX + '/pipe', tarfile.FIFOTYPE, '')],
            [(PREFIX + '/device', tarfile.CHRTYPE, '')],
            [(PREFIX + '/dup', tarfile.REGTYPE, '1'), (PREFIX + '/dup', tarfile.DIRTYPE, '')],
            [(PREFIX + '/parent', tarfile.REGTYPE, '1'), (PREFIX + '/parent/child', tarfile.REGTYPE, '2')],
            [(PREFIX + '/parent/child', tarfile.REGTYPE, '2'), (PREFIX + '/parent', tarfile.REGTYPE, '1')],
        ]
        for rows in bad:
            with self.subTest(rows=rows), tempfile.TemporaryDirectory() as tmp, archive(rows) as source:
                with self.assertRaises(RuntimeError):
                    build.extract_source(source, pathlib.Path(tmp))
                self.assertEqual(list(pathlib.Path(tmp).iterdir()), [])

    def test_preexisting_symlink_directory_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            outside = root / 'outside'
            outside.mkdir()
            (outside / 'sentinel').write_text('unchanged')
            stage = root / 'stage'
            stage.mkdir()
            (stage / PREFIX).symlink_to(outside, target_is_directory=True)
            with archive([(PREFIX + '/sentinel', tarfile.REGTYPE, 'changed')]) as source:
                with self.assertRaises(RuntimeError):
                    build.extract_source(source, stage)
            self.assertEqual((outside / 'sentinel').read_text(), 'unchanged')

    @unittest.skipUnless(os.environ.get('ISH_SOURCE_ARCHIVE'), 'set ISH_SOURCE_ARCHIVE for fixed archive comparison')
    def test_actual_pinned_archive_every_member(self):
        path = pathlib.Path(os.environ['ISH_SOURCE_ARCHIVE'])
        self.assertEqual(build.digest(path), build.LOCK['sha256'])
        with tempfile.TemporaryDirectory() as tmp, tarfile.open(path) as source:
            build.extract_source(source, pathlib.Path(tmp))
            members = source.getmembers()
            self.assertEqual(len(members), 1979)
            for member in members:
                extracted = pathlib.Path(tmp) / member.name
                self.assertFalse(extracted.is_symlink())
                self.assertEqual(extracted.stat().st_mode & 0o777, member.mode & 0o777)
                if member.isfile():
                    self.assertEqual(extracted.read_bytes(), source.extractfile(member).read())
                else:
                    self.assertTrue(extracted.is_dir())


if __name__ == '__main__':
    unittest.main()
