"""Exercise real installed PDF files through the shared staging and OH composer.

Prepare the bridge first with its exact npm ci --omit=optional lock. No downloads,
package installation, fake resource bytes or target device execution occur here.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


dependencies = load('bridge_dependencies', ROOT / 'runtime/lib/bridge_dependencies.py')
composition = load('bridge_ohos_composition', ROOT / 'runtime/ohos/package/compose-runtime.py')


class BridgeDependencyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='bridge-dependency-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def test_staged_bridge_runs_pdf_extraction_without_vendored_source_or_native_canvas(self):
        staged = self.root / 'bridge'
        subprocess.run([sys.executable, '-I', str(ROOT / 'runtime/lib/bridge_dependencies.py'),
                        '--prefix', str(dependencies.BRIDGE), '--out', str(staged)], check=True)
        self.assertFalse((staged / 'lib/companion/pdfjs-6.5.438').exists())
        self.assertFalse((staged / 'node_modules/@napi-rs').exists())
        source = f"""
import assert from 'node:assert/strict';
import {{readReceiptPdf}} from {json.dumps((staged / 'lib/companion/receipt-pdf.js').as_uri())};
import {{ordinary,textLines}} from {json.dumps((ROOT / 'runtime/tests/fixtures/companion-receipt-pdf.mjs').as_uri())};
const result=await readReceiptPdf(ordinary([textLines(['DATE 2026-11-20'])]));
assert.deepEqual(result.pages[0].lines,[{{line:1,text:'DATE 2026-11-20'}}]);
"""
        entry = self.root / 'extract.mjs'
        entry.write_text(source)
        result = subprocess.run(['node', '--jitless', '--no-addons', str(entry)],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        original, files = dependencies.pdf_files(dependencies.BRIDGE)
        for path in files:
            self.assertEqual((staged / 'node_modules/pdfjs-dist' / path.relative_to(original)).read_bytes(),
                             path.read_bytes())

    def test_same_subset_survives_actual_ohos_composer_and_retains_licenses(self):
        source, files = dependencies.pdf_files(dependencies.BRIDGE)
        composer = composition.Composer(self.root / 'payload')
        for path in files:
            destination = 'runtime/bridge/dsh-go-bridge/node_modules/pdfjs-dist/' + path.relative_to(source).as_posix()
            composer.add(path, dependencies.BRIDGE, 'bridge-dependencies', destination)
        self.assertEqual(len(composer.payload), 190)
        names = set(composer.payload)
        for name in ['LICENSE', 'cmaps/LICENSE', 'standard_fonts/LICENSE_FOXIT', 'standard_fonts/LICENSE_LIBERATION']:
            self.assertIn('runtime/bridge/dsh-go-bridge/node_modules/pdfjs-dist/' + name, names)
        for path in files:
            destination = 'runtime/bridge/dsh-go-bridge/node_modules/pdfjs-dist/' + path.relative_to(source).as_posix()
            self.assertEqual(composer.payload[destination]['sha256'], hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertFalse(any(name.endswith(('.wasm', '.node', '.map', '.d.ts')) for name in names))

    def test_android_recipe_identity_ignores_installed_dependency_files(self):
        recipe = load('bridge_android_recipe', ROOT / 'runtime/lib/android_recipe.py')
        before = recipe.recipe_inputs(ROOT / 'runtime', '0.2.2-rc.1')
        with tempfile.NamedTemporaryFile(dir=dependencies.BRIDGE / 'node_modules',
                                         prefix='build-only-', suffix='.txt') as marker:
            marker.write(b'local installed dependency marker')
            marker.flush()
            self.assertEqual(recipe.recipe_inputs(ROOT / 'runtime', '0.2.2-rc.1'), before)

    def test_different_lock_and_incomplete_resource_installation_are_rejected(self):
        prefix = self.root / 'prefix'
        prefix.mkdir()
        lock = dependencies.BRIDGE / 'package-lock.json'
        (prefix / 'package-lock.json').write_bytes(lock.read_bytes() + b'\n')
        with self.assertRaisesRegex(ValueError, 'lock differs'):
            dependencies.pdf_files(prefix)
        shutil.copyfile(lock, prefix / 'package-lock.json')
        dependencies.copy_pdf(dependencies.BRIDGE, prefix / 'node_modules')
        (prefix / 'node_modules/pdfjs-dist/cmaps/78-EUC-H.bcmap').unlink()
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            dependencies.pdf_files(prefix)


if __name__ == '__main__':
    unittest.main(verbosity=2)
