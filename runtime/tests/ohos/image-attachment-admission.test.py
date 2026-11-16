#!/usr/bin/env python3
"""Exercise the real input selector against small actual Composer dependency outputs.

All files and tool identities here are explicit admission fixtures. No Node,
compiler, full runtime composition, SDK or attachment operation is executed.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


entry = load('image_attachment_admission_entry', 'runtime/tests/ohos/image-attachment-entry.py')
composer = load('image_attachment_admission_composer', 'runtime/ohos/package/compose-runtime.py')


def put(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return hashlib.sha256(data).hexdigest()


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='image-admission-')
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.prepared = self.root / 'prepared'
        self.payload = self.root / 'expanded/dsh-runtime/files'
        self.tests = self.source / 'runtime/tests/ohos'
        self.package = 'node_modules/@deepseek-ai/dsh'
        self.runtime = self.package + '/lib/index.js'
        self.omitted = [self.package + '/lib/' + name for name in
                        ('index.d.ts', 'index.d.cts', 'index.d.mts', 'index.js.map')]
        manifest = {'name': '@deepseek-ai/dsh', 'version': '0.2.2-rc.1'}
        put(self.prepared / self.package / 'package.json', json.dumps(manifest).encode())
        pins = {}
        for name in [self.runtime, *self.omitted]:
            digest = put(self.prepared / name, ('explicit admission fixture: ' + name).encode())
            pins[name] = {'before': digest, 'after': digest}
        patch_name = 'ohos-image-codec.diff'
        patch_sha = put(self.source / 'runtime/patches' / patch_name, b'explicit patch report fixture\n')
        patch_pins = {'schema': 2, 'patches': {patch_name: {'0.2.2-rc.1': pins}},
                      'targetSets': {'ohos': [patch_name], 'android': []}}
        put(self.source / 'runtime/patches/pins.json', json.dumps(patch_pins).encode())
        runtime_mapping = {'source': 'runtime/ohos/image/preload.mjs',
                           'payload': 'runtime/ohos/image/preload.mjs', 'hostFixtureOnly': False}
        put(self.source / runtime_mapping['source'], b'// explicit runtime mapping fixture\n')
        catalog = {'schema': 1, 'bridgeFixtureMacro': False, 'dshVersion': '0.2.2-rc.1',
                   'nodeVersion': '24.22.1', 'frozenTests': [], 'frozenSource': [],
                   'extraPayload': [], 'runtimeMappings': [runtime_mapping], 'formalAdditionalMappings': []}
        put(self.tests / 'image-attachment-input-catalog.json', json.dumps(catalog).encode())
        put(self.tests / 'image-attachment-oracle.json',
            json.dumps({'cases': [{'name': 'opaque-jpeg'}, {'name': 'transparent-png'}]}).encode())
        self.composed = composer.Composer(self.payload)
        self.composed.dependencies(self.prepared, 'explicit admission fixture', '',
                                   [{'path': self.package}], {})
        self.composed.add(self.source / runtime_mapping['source'], self.source,
                          'explicit runtime fixture', runtime_mapping['payload'])
        self.manifest = self.payload.parent / 'manifest.json'
        self.write_manifest()
        headers = self.root / 'headers'
        for name in entry.NODE_HEADERS:
            put(headers / name, b'/* explicit non-compiling admission header fixture */\n')
        put(headers / 'node_version.h',
            b'#define NODE_MAJOR_VERSION 24\n#define NODE_MINOR_VERSION 22\n#define NODE_PATCH_VERSION 1\n')
        publication = self.root / 'publication.so'
        put(publication, b'explicit non-loading admission fixture')
        self.target_report = self.root / 'target-report.json'
        put(self.target_report, json.dumps({'schema': 1, 'target': 'ohos', 'dshVersion': '0.2.2-rc.1',
            'selected': [patch_name], 'inputs': {'patches': [
                {'name': patch_name, 'sha256': patch_sha, 'pins': pins}]}}).encode())
        self.args = argparse.Namespace(source=self.source, payload=self.payload, manifest=self.manifest,
            component_prefix=False, target_report=None, node=sys.executable,
            cc=sys.executable, cxx=sys.executable, node_headers=headers, publication_fixture=publication)

    def tearDown(self):
        self.temp.cleanup()

    def write_manifest(self):
        data = {'schema': 1, 'nodeVersion': '24.22.1', 'dshVersion': '0.2.2-rc.1',
                'runtimeVersion': 'ohos-explicit-admission-fixture',
                'files': list(self.composed.payload.values())}
        put(self.manifest, json.dumps(data).encode())

    def test_formal_accepts_actual_composer_development_omissions(self):
        self.assertTrue(all(not (self.payload / name).exists() for name in self.omitted))
        selected = entry.selected_inputs(self.args)
        self.assertIn(self.runtime, selected['selectedPayload'])
        omitted = selected['admission']['compositionOmittedPins']
        self.assertEqual([row['path'] for row in omitted], sorted(self.omitted))
        self.assertEqual(selected['admission']['checkedFinalPinCount'], 1)
        self.assertTrue(all(row['reason'] == 'composer-development-artifact' for row in omitted))

    def test_formal_still_rejects_missing_runtime_pin(self):
        (self.payload / self.runtime).unlink()
        with self.assertRaisesRegex(ValueError, 'Missing regular input'):
            entry.selected_inputs(self.args)

    def test_formal_still_rejects_changed_runtime_pin(self):
        (self.payload / self.runtime).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Final OH pin differs'):
            entry.selected_inputs(self.args)

    def test_formal_requires_manifest_membership_and_bytes(self):
        original = json.loads(self.manifest.read_text())
        for mode in ('missing', 'hash'):
            with self.subTest(mode=mode):
                value = json.loads(json.dumps(original))
                if mode == 'missing':
                    value['files'] = [row for row in value['files'] if row['path'] != self.runtime]
                else:
                    next(row for row in value['files'] if row['path'] == self.runtime)['sha256'] = '0' * 64
                self.manifest.write_text(json.dumps(value))
                with self.assertRaisesRegex(ValueError, 'Selected payload differs from actual composer manifest'):
                    entry.selected_inputs(self.args)

    def test_formal_does_not_silently_admit_declarations(self):
        shutil.copy2(self.prepared / self.omitted[0], self.payload / self.omitted[0])
        with self.assertRaisesRegex(ValueError, 'Composer development artifact remained'):
            entry.selected_inputs(self.args)

    def test_formal_rejects_omitted_declaration_claimed_in_manifest(self):
        data = json.loads(self.manifest.read_text())
        data['files'].append({'path': self.omitted[0], 'size': 1, 'sha256': '0' * 64})
        self.manifest.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'Composer development artifact is listed in manifest'):
            entry.selected_inputs(self.args)

    def test_component_requires_all_final_pins_including_declarations(self):
        self.args.component_prefix = True
        self.args.manifest = None
        self.args.target_report = self.target_report
        for name in self.omitted:
            shutil.copy2(self.prepared / name, self.payload / name)
        selected = entry.selected_inputs(self.args)
        self.assertEqual(selected['admission']['compositionOmittedPins'], [])
        self.assertEqual(selected['admission']['checkedFinalPinCount'], 5)
        (self.payload / self.omitted[0]).unlink()
        with self.assertRaisesRegex(ValueError, 'Missing regular input'):
            entry.selected_inputs(self.args)


if __name__ == '__main__':
    unittest.main(verbosity=2)
