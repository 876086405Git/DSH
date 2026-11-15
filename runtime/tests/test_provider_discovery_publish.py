#!/usr/bin/env python3
"""Provider discovery patch publication: failed writes preserve the prior patch."""
import ast
import errno
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock


GENERATOR = Path(__file__).resolve().parents[1] / 'provider-discovery/generate.py'
# Load the production helper without starting the script's source build CLI.
definition = next(node for node in ast.parse(GENERATOR.read_text(encoding='utf-8')).body
                  if isinstance(node, ast.FunctionDef) and node.name == 'publish_patch')
namespace = {}
exec(compile(ast.Module(body=[definition], type_ignores=[]), str(GENERATOR), 'exec'), namespace)
publish_patch = namespace['publish_patch']


class ProviderDiscoveryPublish(unittest.TestCase):
    def test_failed_write_preserves_patch_and_retry_replaces_it(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'provider-discovery-headers.diff'
            previous = b'--- a/provider.js\n+++ b/provider.js\n@@ -1 +1 @@\n-old\n+reviewed\n'
            updated = '--- a/provider.js\n+++ b/provider.js\n@@ -1 +1 @@\n-old\n+updated\n'
            target.write_bytes(previous)
            write_text = Path.write_text

            def interrupted_write(path, text, *args, **kwargs):
                # Write real partial bytes, without filling the host's disk.
                write_text(path, text[:12], *args, **kwargs)
                raise OSError(errno.ENOSPC, 'injected patch write failure')

            with mock.patch.object(Path, 'write_text', interrupted_write):
                with self.assertRaises(OSError) as failure:
                    publish_patch(target, updated)
            self.assertEqual(failure.exception.errno, errno.ENOSPC)
            self.assertEqual(target.read_bytes(), previous)

            publish_patch(target, updated)
            self.assertEqual(target.read_bytes(), updated.replace('\n', os.linesep).encode('utf-8'))
            self.assertEqual(list(Path(directory).iterdir()), [target])


if __name__ == '__main__':
    unittest.main(verbosity=2)
