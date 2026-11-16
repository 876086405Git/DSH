#!/usr/bin/env python3
"""Real-file tests for fixed input receipts and required-entry drift."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


inputs = load('prepared_inputs', ROOT / 'runtime/ohos/package/prepare-inputs.py')
composition = load('composition', ROOT / 'runtime/ohos/package/compose-runtime.py')


class InputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ohos-input-gate-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = json.loads((ROOT / 'runtime/ohos/package/composition.json').read_text())
        self.prefixes = {}
        for name in ('dsh', 'process'):
            prefix = self.root / name
            (prefix / 'node_modules/example').mkdir(parents=True)
            (prefix / 'package.json').write_text('{"name":"fixture"}\n')
            (prefix / 'package-lock.json').write_text('{"lockfileVersion":3}\n')
            (prefix / 'node_modules/example/package.json').write_text('{"name":"example","version":"1.0.0"}\n')
            (prefix / 'node_modules/example/index.js').write_text('module.exports = 1;\n')
            self.prefixes[name] = prefix
        self.receipt = self.root / 'prepared-inputs.json'
        self.data = {'schema': 1, 'nodeVersion': self.config['nodeVersion'],
                     'installation': self.config['installation'],
                     'files': {name: inputs.prefix_files(prefix) for name, prefix in self.prefixes.items()}}
        self.save()

    def save(self):
        self.receipt.write_bytes(inputs.encoded(self.data))

    def verify(self):
        return inputs.verify_inputs(self.receipt, self.config, self.prefixes['dsh'], self.prefixes['process'])

    def test_exact_files_and_recipe_pass(self):
        self.assertEqual(self.verify(), hashlib.sha256(self.receipt.read_bytes()).hexdigest())

    def test_same_package_version_does_not_excuse_changed_source(self):
        (self.prefixes['dsh'] / 'node_modules/example/index.js').write_text('module.exports = 2;\n')
        with self.assertRaisesRegex(ValueError, 'input bytes/file set changed'):
            self.verify()

    def test_added_and_removed_files_are_rejected(self):
        source = self.prefixes['process'] / 'node_modules/example/extra.json'
        source.write_text('{}\n')
        with self.assertRaisesRegex(ValueError, 'input bytes/file set changed'):
            self.verify()
        source.unlink()
        (self.prefixes['process'] / 'node_modules/example/index.js').unlink()
        with self.assertRaisesRegex(ValueError, 'input bytes/file set changed'):
            self.verify()

    def test_wrong_npm_recipe_is_rejected(self):
        self.data['installation'] = {**self.config['installation'], 'arguments': ['ci', '--include=optional']}
        self.save()
        with self.assertRaisesRegex(ValueError, 'installation recipe differs'):
            self.verify()

    def test_wrong_node_version_is_rejected(self):
        self.data['nodeVersion'] = '24.0.0'
        self.save()
        with self.assertRaisesRegex(ValueError, 'different Node version'):
            self.verify()

    def test_hardlinked_inputs_are_rejected_without_mutation(self):
        source = self.prefixes['process'] / 'node_modules/example/index.js'
        before = source.read_bytes()
        os.link(source, self.root / 'shared.js')
        with self.assertRaisesRegex(ValueError, 'shared by hardlink'):
            self.verify()
        self.assertEqual(source.read_bytes(), before)

    def test_unknown_links_rejected_known_development_links_ignored(self):
        dependency = self.prefixes['process'] / 'node_modules'
        (dependency / '.bin').mkdir()
        os.symlink('../example/index.js', dependency / '.bin/example')
        os.symlink(self.prefixes['dsh'] / 'node_modules', dependency / '@deepseek-ai')
        self.verify()
        os.symlink('example/index.js', dependency / 'unknown.js')
        with self.assertRaisesRegex(ValueError, 'Unexpected installed symlink'):
            self.verify()

    def test_optional_install_is_detected_by_actual_locked_package_presence(self):
        prefix = self.prefixes['dsh']
        lock = {'packages': {'': {}, 'node_modules/example': {'version': '1.0.0'},
                            'node_modules/optional-native': {'version': '1.0.0', 'optional': True}}}
        (prefix / 'package-lock.json').write_bytes(inputs.encoded(lock))
        expected = hashlib.sha256((prefix / 'package-lock.json').read_bytes()).hexdigest()
        self.assertEqual(len(composition.checked_lock(prefix, expected)), 1)
        native = prefix / 'node_modules/optional-native'
        native.mkdir()
        (native / 'package.json').write_text('{"name":"optional-native","version":"1.0.0"}\n')
        with self.assertRaisesRegex(ValueError, '--omit=optional'):
            composition.checked_lock(prefix, expected)
        (native / 'package.json').unlink()
        (prefix / 'node_modules/example/package.json').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing locked package'):
            composition.checked_lock(prefix, expected)


class DependencyPruningTests(unittest.TestCase):
    def test_runtime_outputs_and_vendor_licenses_survive_development_pruning(self):
        # Explicit real-file fixtures exercise the production Composer, not a
        # second implementation of its glob rules. License contents are fixture
        # markers; actual vendor texts are separately bound by composed manifests.
        config = json.loads((ROOT / 'runtime/ohos/package/composition.json').read_text())
        with tempfile.TemporaryDirectory(prefix='ohos-pruning-gate-') as directory:
            root = Path(directory)
            output = root / 'files'
            composer = composition.Composer(output)
            expected = {}
            inputs_before = {}
            for source, destination in [('dsh', ''), ('process', 'runtime/ohos/process')]:
                prefix = root / source
                keep = {
                    '@mixmark-io/domino/package.json': b'{"main":"./lib"}\n',
                    '@mixmark-io/domino/lib/index.js': b'module.exports = {};\n',
                    '@mixmark-io/domino/LICENSE': b'domino fixture license\n',
                    'yaml/package.json': b'{"main":"./dist/index.js"}\n',
                    'yaml/dist/index.js': b'exports.parse = value => value;\n',
                    'yaml/LICENSE': b'yaml fixture license\n',
                    'undici/package.json': b'{"main":"index.js"}\n',
                    'undici/index.js': b'module.exports = {};\n',
                    'undici/LICENSE': b'undici fixture license\n',
                }
                development = {
                    '@mixmark-io/domino/test/wpt/parser.html': b'<p>test only</p>\n',
                    'yaml/browser/index.js': b'export const browserOnly = true;\n',
                    'yaml/browser/package.json': b'{"type":"module"}\n',
                    'undici/docs/docs/api/Client.md': b'API documentation fixture\n',
                }
                if source == 'dsh':
                    keep.update({
                        'openai/package.json': b'{"main":"./index.js"}\n',
                        'openai/index.js': b'module.exports = {};\n',
                        'openai/index.mjs': b'export default {};\n',
                        'openai/src/internal/qs/LICENSE.md': b'qs fixture license\n',
                        'openai/src/_vendor/zod-to-json-schema/LICENSE': b'zod converter fixture license\n',
                        'openai/src/_vendor/partial-json-parser/LICENSE': b'partial parser fixture license\n',
                        '@anthropic-ai/sdk/package.json': b'{"main":"./index.js"}\n',
                        '@anthropic-ai/sdk/index.js': b'module.exports = {};\n',
                        '@anthropic-ai/sdk/index.mjs': b'export default {};\n',
                        '@anthropic-ai/sdk/src/internal/qs/LICENSE.md': b'qs fixture license\n',
                        'zod/package.json': b'{"main":"./index.cjs"}\n',
                        'zod/index.cjs': b'module.exports = {};\n',
                        'zod/index.js': b'export const z = {};\n',
                        'ajv/package.json': b'{"main":"dist/ajv.js"}\n',
                        'ajv/dist/ajv.js': b'module.exports = {};\n',
                        'ajv/dist/refs/json-schema-draft-07.json': b'{"type":"object"}\n',
                    })
                    development.update({
                        'openai/src/client.ts': b'export const client = true;\n',
                        'openai/src/internal/auth/state.cts': b'export const state = true;\n',
                        '@anthropic-ai/sdk/src/client.ts': b'export const client = true;\n',
                        'zod/src/index.ts': b'export const z = {};\n',
                        'ajv/lib/ajv.ts': b'export const ajv = {};\n',
                        'ajv/lib/refs/json-schema-draft-07.json': b'{"type":"object"}\n',
                    })
                for name, data in {**keep, **development}.items():
                    path = prefix / 'node_modules' / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(data)
                    inputs_before[path] = data
                packages = [{'path': 'node_modules/' + name[:-len('/package.json')]}
                            for name in keep if name.endswith('/package.json')]
                composer.dependencies(prefix, source, destination, packages,
                                      config[source + 'RemovePackages'], config[source + 'RemoveFiles'])
                for name, data in keep.items():
                    relative = '/'.join(part for part in (destination, 'node_modules', name) if part)
                    expected[relative] = data
            # First assert all retained bytes, including the four vendor texts.
            # A broad src/* regression fails here before omission assertions.
            for name, data in expected.items():
                self.assertEqual((output / name).read_bytes(), data, name)
                self.assertEqual(composer.payload[name]['sha256'], hashlib.sha256(data).hexdigest())
            actual = sorted(path.relative_to(output).as_posix()
                            for path in output.rglob('*') if path.is_file())
            self.assertEqual(actual, sorted(expected), 'development files leaked into composed runtime')
            self.assertEqual(sorted(composer.payload), sorted(expected))
            self.assertTrue(any(row['decision'] == 'omit' for row in composer.inputs))
            for path, data in inputs_before.items():
                self.assertEqual(path.read_bytes(), data, str(path))


class DeletionVariantTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='ohos-deletion-variant-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.prefix = self.root / 'prefix'
        self.companion = self.prefix / 'node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/dsh-go-deletion.mjs'
        self.companion.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / 'runtime/session-deletion/core.mjs', self.companion)
        self.output = self.root / 'generated'

    def test_variants_are_generated_without_modifying_shared_or_prepared_inputs(self):
        paths = [ROOT / 'runtime/session-deletion/core.mjs',
                 ROOT / 'runtime/bridge/dsh-go-bridge/lib/session-deletion.js', self.companion]
        before = [path.read_bytes() for path in paths]
        report = composition.deletion_variants(ROOT, self.prefix, self.output)
        self.assertEqual([path.read_bytes() for path in paths], before)
        self.assertEqual(len(report['files']), 2)
        for row in report['files']:
            data = (self.output / row['file']).read_bytes()
            self.assertEqual(len(data), row['size'])
            self.assertEqual(hashlib.sha256(data).hexdigest(), row['sha256'])
            self.assertNotEqual(row['sourceSha256'], row['sha256'])

    def test_a_changed_prepared_companion_is_rejected_before_output(self):
        self.companion.write_bytes(self.companion.read_bytes() + b'\n')
        with self.assertRaisesRegex(ValueError, 'Prepared deletion companion differs'):
            composition.deletion_variants(ROOT, self.prefix, self.output)
        self.assertFalse(self.output.exists())

    def private_repo(self):
        repo = self.root / 'repo'
        for name in ['runtime/session-deletion/core.mjs',
                     'runtime/bridge/dsh-go-bridge/lib/session-deletion.js',
                     'runtime/lib/rtbuild.py', 'runtime/ohos/package/session-deletion-ohos.diff']:
            target = repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        return repo

    def test_new_shared_source_requires_review_instead_of_silent_rebase(self):
        repo = self.private_repo()
        source = repo / 'runtime/session-deletion/core.mjs'
        source.write_bytes(source.read_bytes() + b'\n')
        with self.assertRaisesRegex(ValueError, 'OH deletion source changed'):
            composition.deletion_variants(repo, self.prefix, self.output)
        self.assertFalse(self.output.exists())

    def test_changed_transform_cannot_replace_the_reviewed_output(self):
        repo = self.private_repo()
        patch = repo / 'runtime/ohos/package/session-deletion-ohos.diff'
        text = patch.read_text()
        self.assertIn('Atomic session deletion publication is unavailable.', text)
        patch.write_text(text.replace('Atomic session deletion publication is unavailable.', 'Different output.'))
        with self.assertRaisesRegex(ValueError, 'variant differs from its reviewed output'):
            composition.deletion_variants(repo, self.prefix, self.output)
        self.assertFalse(self.output.exists())


class RequiredTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ohos-required-gate-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.host = self.root / 'app/ohos/entry/src/main/cpp/host_core.cpp'
        self.core = self.root / 'app/ohos/entry/src/main/ets/runtime/RuntimeCore.ets'
        for target in (self.host, self.core):
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((ROOT / target.relative_to(self.root)).read_bytes())

    def test_actual_host_requirements_include_bridge_and_match_manifest(self):
        entries = composition.required_entries(self.root)
        self.assertEqual(len(entries), 9)
        self.assertIn('runtime/ohos/phone/index.mjs', entries)
        self.assertIn('runtime/bridge/dsh-go-bridge/lib/index.js', entries)
        self.assertIn('runtime/ohos/process/child-process.mjs', entries)

    def test_each_missing_manifest_entry_is_rejected(self):
        before = self.core.read_text()
        for entry in composition.required_entries(self.root):
            with self.subTest(entry=entry):
                self.core.write_text(before.replace("'" + entry + "'", "'wrong/" + entry + "'", 1))
                with self.assertRaisesRegex(ValueError, 'required entries differ'):
                    composition.required_entries(self.root)
        self.core.write_text(before)

    def test_new_host_requirement_forces_manifest_and_composition_update(self):
        self.host.write_text(self.host.read_text() + '\nFile(options.runtime_root, "new/entry.mjs");\n')
        with self.assertRaisesRegex(ValueError, 'required entries differ'):
            composition.required_entries(self.root)

    def test_host_syntax_change_cannot_silently_shrink_extracted_requirements(self):
        self.host.write_text(self.host.read_text() + '\nFile(options.runtime_root, computed_entry);\n')
        with self.assertRaisesRegex(ValueError, 'no longer the checked literal File calls'):
            composition.required_entries(self.root)


if __name__ == '__main__':
    unittest.main(verbosity=2)
