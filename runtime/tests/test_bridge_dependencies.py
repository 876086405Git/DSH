"""Test dependency staging with disposable, deliberately non-executable fixtures.

This tooling suite needs no installed node_modules. Actual PDF extraction from
the staged, locked dependency is covered by companion-receipt-pdf.test.mjs in
the runtime job, which prepares the real bridge dependency before running it.
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
        self.prefix = self.root / 'prefix'
        self.prefix.mkdir()
        shutil.copyfile(dependencies.BRIDGE / 'package-lock.json', self.prefix / 'package-lock.json')
        self.pdf = self.prefix / 'node_modules/pdfjs-dist'
        self.selected = {
            'package.json', 'README.md', 'LICENSE',
            'legacy/build/pdf.mjs', 'legacy/build/pdf.worker.mjs',
            'cmaps/LICENSE', 'standard_fonts/LICENSE_FOXIT', 'standard_fonts/LICENSE_LIBERATION',
            'cmaps/78-EUC-H.bcmap',
            *(f'cmaps/fixture-{index:03}.bcmap' for index in range(167)),
            *(f'standard_fonts/fixture-{index:02}.pfb' for index in range(14)),
        }
        self.assertEqual(len(self.selected), 190)
        for name in self.selected | {'build/pdf.mjs', 'web/viewer.html', 'wasm/unused.wasm'}:
            path = self.pdf / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(f'Fixture inventory only, not PDF.js resource bytes: {name}\n'.encode())
        (self.pdf / 'package.json').write_text(json.dumps({'name': 'pdfjs-dist', 'version': '6.5.438'}))
        canvas = self.prefix / 'node_modules/@napi-rs/canvas/package.json'
        canvas.parent.mkdir(parents=True)
        canvas.write_text('{"name":"@napi-rs/canvas"}')

    def test_staged_bridge_copies_only_selected_fixture_files_without_native_canvas(self):
        staged = self.root / 'bridge'
        subprocess.run([sys.executable, '-I', str(ROOT / 'runtime/lib/bridge_dependencies.py'),
                        '--prefix', str(self.prefix), '--out', str(staged)], check=True)
        self.assertFalse((staged / 'lib/companion/pdfjs-6.5.438').exists())
        self.assertFalse((staged / 'node_modules/@napi-rs').exists())
        original, files = dependencies.pdf_files(self.prefix)
        self.assertEqual({path.relative_to(original).as_posix() for path in files}, self.selected)
        self.assertEqual({path.relative_to(staged / 'node_modules/pdfjs-dist').as_posix()
                          for path in (staged / 'node_modules/pdfjs-dist').rglob('*') if path.is_file()},
                         self.selected)
        for path in files:
            self.assertEqual((staged / 'node_modules/pdfjs-dist' / path.relative_to(original)).read_bytes(),
                             path.read_bytes())

    def test_same_subset_survives_actual_ohos_composer_and_retains_licenses(self):
        source, files = dependencies.pdf_files(self.prefix)
        composer = composition.Composer(self.root / 'payload')
        for path in files:
            destination = 'runtime/bridge/dsh-go-bridge/node_modules/pdfjs-dist/' + path.relative_to(source).as_posix()
            composer.add(path, self.prefix, 'bridge-dependencies', destination)
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
        runtime = self.root / 'runtime'
        for name in ['build-runtime.sh', 'locks/android-recipe-compat.json']:
            target = runtime / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / 'runtime' / name, target)
        for name in ['lib', 'patches', 'bridge', 'boot', 'direct', 'session-deletion']:
            shutil.copytree(ROOT / 'runtime' / name, runtime / name, symlinks=True,
                            ignore=shutil.ignore_patterns('node_modules', '__pycache__'))
        before = recipe.recipe_inputs(runtime, '0.2.2-rc.1')
        bridge = runtime / 'bridge/dsh-go-bridge'
        shutil.copytree(self.prefix / 'node_modules', bridge / 'node_modules')
        self.assertEqual(recipe.recipe_inputs(runtime, '0.2.2-rc.1'), before)
        with (bridge / 'package-lock.json').open('a') as lock:
            lock.write('\n')
        self.assertNotEqual(recipe.recipe_inputs(runtime, '0.2.2-rc.1'), before)

    def test_different_lock_and_incomplete_resource_installation_are_rejected(self):
        prefix = self.root / 'incomplete'
        prefix.mkdir()
        lock = dependencies.BRIDGE / 'package-lock.json'
        (prefix / 'package-lock.json').write_bytes(lock.read_bytes() + b'\n')
        with self.assertRaisesRegex(ValueError, 'lock differs'):
            dependencies.pdf_files(prefix)
        shutil.copyfile(lock, prefix / 'package-lock.json')
        dependencies.copy_pdf(self.prefix, prefix / 'node_modules')
        (prefix / 'node_modules/pdfjs-dist/cmaps/78-EUC-H.bcmap').unlink()
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            dependencies.pdf_files(prefix)


if __name__ == '__main__':
    unittest.main(verbosity=2)
