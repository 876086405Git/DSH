#!/usr/bin/env python3
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('composer', ROOT / 'runtime/ohos/package/compose-runtime.py')
composer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(composer)

class PythonBundleTests(unittest.TestCase):
    def test_real_bundle_compile_and_transactional_failure(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); lib = root / 'Lib'; lib.mkdir()
            (lib / 'hello.py').write_text('value = 42\n')
            (lib / 'resource.dat').write_bytes(b'data')
            (lib / 'unsafe.so').write_bytes(b'not an asset')
            sysconfig = root / '_sysconfigdata_target.py'; sysconfig.write_text('build_time_vars = {}\n')
            ca = root / 'ca.pem'; ca.write_text('-----BEGIN CERTIFICATE-----\nfixture\n')
            licenses = root / 'licenses'; licenses.mkdir()
            for label in ('CPython', 'OpenSSL', 'libffi', 'SQLite', 'zlib', 'CA'):
                (licenses / (label + '.txt')).write_text(label + ' fixture notice\n')
            output = root / 'bundle'
            command = [sys.executable, str(ROOT / 'runtime/ohos/python/prepare-bundle.py'), '--stdlib', str(lib),
                       '--sysconfig', str(sysconfig), '--version', '.'.join(map(str, sys.version_info[:3])),
                       '--ca-bundle', str(ca), '--licenses', str(licenses), '--output', str(output)]
            subprocess.run(command, check=True)
            with zipfile.ZipFile(output / 'stdlib.zip') as archive:
                self.assertIn('hello.pyc', archive.namelist())
                self.assertIn('resource.dat', archive.namelist())
                self.assertNotIn('unsafe.so', archive.namelist())
            manifest = json.loads((output / 'manifest.json').read_text())
            for row in manifest['files']:
                self.assertEqual(hashlib.sha256((output / row['path']).read_bytes()).hexdigest(), row['sha256'])
            previous = (output / 'manifest.json').read_bytes()
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(previous, (output / 'manifest.json').read_bytes())

    def test_composer_includes_verified_assets_and_rejects_tamper_and_native_name(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); bundle = root / 'bundle'; bundle.mkdir()
            files = {'stdlib.zip': b'zip-fixture', 'ca.pem': b'ca-fixture'}
            rows = []
            for name, data in files.items():
                (bundle / name).write_bytes(data)
                rows.append({'path': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
            manifest = {'schema': 1, 'pythonVersion': '3.14.7', 'files': rows}
            (bundle / 'manifest.json').write_text(json.dumps(manifest))
            target = composer.Composer(root / 'payload')
            composer.compose_python(target, bundle, ROOT / 'runtime/ohos', ROOT)
            self.assertEqual((root / 'payload/runtime/ohos/python/assets/stdlib.zip').read_bytes(), files['stdlib.zip'])
            self.assertTrue((root / 'payload/runtime/ohos/python/host-worker.mjs').is_file())
            (bundle / 'stdlib.zip').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'differs'):
                composer.compose_python(composer.Composer(root / 'bad'), bundle, ROOT / 'runtime/ohos', ROOT)
            rows[0]['path'] = 'libevil.so'
            (bundle / 'manifest.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'Unsafe'):
                composer.compose_python(composer.Composer(root / 'native'), bundle, ROOT / 'runtime/ohos', ROOT)

if __name__ == '__main__':
    unittest.main(verbosity=2)
