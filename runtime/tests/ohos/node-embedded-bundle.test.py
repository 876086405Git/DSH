#!/usr/bin/env python3
"""The check for a built-in JS file looks for the bytes Node embeds, not the file's own."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('ohos_build', ROOT / 'runtime/ohos/node/build-node.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class EmbeddedCopies(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def copies(self, source, image):
        (self.root / 'bundle.js').write_text(source, encoding='utf-8')
        (self.root / 'libnode.so').write_bytes(b'\x7fELF' + image + b'\0tail')
        return build.embedded_copies(self.root / 'libnode.so', self.root / 'bundle.js')

    def test_a_latin1_character_is_found_in_its_embedded_byte(self):
        source = '// Jimmy Wärting\nmodule.exports = 1;\n'
        found = self.copies(source, source.encode('latin-1'))
        self.assertEqual((found['encoding'], found['copies']), ('latin-1', 1))

    def test_the_files_own_utf8_bytes_are_not_what_node_embeds(self):
        source = '// Jimmy Wärting\n'
        self.assertEqual(self.copies(source, source.encode('utf-8'))['copies'], 0)

    def test_a_character_past_latin1_is_found_in_utf16(self):
        source = '// 中文 Wärting\n'
        found = self.copies(source, source.encode('utf-16-le'))
        self.assertEqual((found['encoding'], found['copies']), ('utf-16-le', 1))

    def test_a_library_without_the_bundle_reports_none(self):
        self.assertEqual(self.copies('// patched bundle\n', b'// unpatched bundle\n')['copies'], 0)

    def test_a_second_copy_is_counted(self):
        source = '// ascii only\n'
        self.assertEqual(self.copies(source, source.encode('latin-1') * 2)['copies'], 2)


if __name__ == '__main__':
    unittest.main()
