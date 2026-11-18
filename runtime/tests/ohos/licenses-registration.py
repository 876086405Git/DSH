#!/usr/bin/env python3
"""从真实锁定依赖复核 M4-6 的已知源内通知；不声称穷尽所有嵌入许可。"""
import argparse
import copy
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--registration-root', required=True, type=pathlib.Path,
                    help='含 THIRD_PARTY_NOTICES.md 与 runtime/ohos/licenses 的源码根')
parser.add_argument('--process-prefix', required=True, type=pathlib.Path)
parser.add_argument('--esbuild-prefix', required=True, type=pathlib.Path)
args = parser.parse_args()
sha = lambda data: hashlib.sha256(data).hexdigest()
ANGULAR_LICENSE = 'texts/mixmark-io--domino-2.2.0/ANGULAR-LICENSE.txt'
ANGULAR_HEADER = 'texts/mixmark-io--domino-2.2.0/ANGULAR-STYLE-PARSER-NOTICE.txt'
BUNDLE_HEADER = 'texts/just-bash-3.6.0/ANGULAR-BUNDLED-NOTICE.txt'
APACHE = 'texts/clean-git-ref-2.0.1/APACHE-2.0.txt'


class ActualSourceNotices(unittest.TestCase):
    def setUp(self):
        self.here = args.registration_root / 'runtime/ohos/licenses'
        self.m = json.loads((self.here / 'manifest.json').read_text())
        self.docs = {doc['path']: doc for doc in self.m['documents']}
        self.packages = {item['name']: item for item in self.m['packages']}

    def verify(self, root=None, *flags):
        base = root or args.registration_root
        return subprocess.run([sys.executable, str(base / 'runtime/ohos/licenses/verify.py'),
            '--process-prefix', str(args.process_prefix), '--esbuild-prefix',
            str(args.esbuild_prefix), *flags], text=True, capture_output=True)

    def test_domino_retains_bsd_and_exact_angular_mit_terms(self):
        package = self.packages['@mixmark-io/domino']
        self.assertEqual(package['declaredLicense'], 'BSD-2-Clause')
        self.assertIn('texts/mixmark-io--domino-2.2.0/LICENSE', package['documents'])
        self.assertIn(ANGULAR_LICENSE, package['documents'])
        data = (self.here / ANGULAR_LICENSE).read_bytes()
        self.assertEqual(sha(data), '1d65ce0e0d6f0f237eeeb8fa186402ec8c6169d05ddadac6bcf9fa683eb5b34b')
        self.assertIn(b'Copyright (c) 2010-2022 Google LLC.', data)
        self.assertEqual(self.docs[ANGULAR_LICENSE]['source']['url'],
            'https://raw.githubusercontent.com/angular/angular/92e41e9cb417223d9888a4c23b4c0e73188f87d0/LICENSE')

    def test_actual_source_and_bundle_notices_have_bound_raw_byte_ranges(self):
        for path, actual_file, identity in [
            (ANGULAR_HEADER, 'node_modules/@mixmark-io/domino/lib/style_parser.js',
             'b41b215a146a119303d052223216207ca4cbc48a14b122eda966094a56610f10'),
            (BUNDLE_HEADER, 'node_modules/just-bash/dist/bin/chunks/chunk-DTGQQKI2.js',
             '1da8061bec7f16f2ca625c36d5c4daf8810148627e9bda9fdf6a396ac8f184f7'),
        ]:
            with self.subTest(path=path):
                original = (args.process_prefix / actual_file).read_bytes()
                self.assertEqual(sha(original), identity)
                self.assertIn(b'Copyright Google LLC All Rights Reserved.', original)
                self.assertTrue(path in self.docs, f'缺少源内通知登记：{path}')
                source = self.docs[path]['source']
                self.assertEqual(source['path'], actual_file)
                self.assertEqual(source['sha256'], identity)
                begin, end = source['byteRange']
                text = (self.here / path).read_bytes()
                self.assertEqual(text, original[begin:end])
                self.assertIn(b'MIT-style license', text)
        self.assertIn(BUNDLE_HEADER, self.packages['just-bash']['documents'])
        embedded = [x for x in self.m['embeddedComponents'] if x.get('id') == 'angular-style-parser']
        self.assertEqual(len(embedded), 1)
        self.assertEqual(set(embedded[0]['documents']), {ANGULAR_LICENSE, ANGULAR_HEADER, BUNDLE_HEADER})
        root_notice = (args.registration_root / 'THIRD_PARTY_NOTICES.md').read_text()
        self.assertIn('Angular', root_notice)
        self.assertIn('92e41e9cb417223d9888a4c23b4c0e73188f87d0', root_notice)

    def test_apache_standard_and_actual_metadata_without_invented_copyright(self):
        package = self.packages['clean-git-ref']
        actual = json.loads((args.process_prefix / package['path'] / 'package.json').read_text())
        self.assertEqual(actual['license'], 'Apache-2.0')
        self.assertIn(APACHE, package['documents'])
        self.assertEqual(sha((self.here / APACHE).read_bytes()),
            'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30')
        self.assertEqual(package.get('attributionFields'), {'author': actual['author'], 'license': actual['license']})
        self.assertNotIn('clean-git-ref-terms', {x['id'] for x in self.m['blockers']})
        retained = (self.here / 'texts/clean-git-ref-2.0.1/PACKAGE-DECLARATIONS.txt').read_text()
        self.assertIn(actual['author'], retained)
        self.assertNotIn('Copyright', retained)

    def test_minimisted_known_mit_metadata_and_actual_remaining_gap(self):
        package = self.packages['minimisted']
        actual = json.loads((args.process_prefix / package['path'] / 'package.json').read_text())
        self.assertEqual(package['declaredLicense'], 'MIT')
        self.assertEqual(package.get('attributionFields'), {'author': actual['author'], 'license': actual['license']})
        self.assertIn('minimisted-terms', {x['id'] for x in self.m['blockers']})
        retained = (self.here / 'texts/minimisted-2.0.1/PACKAGE-DECLARATIONS.txt').read_text()
        self.assertIn(actual['author'], retained)
        self.assertNotIn('Copyright', retained)

    def test_verifier_preserves_explicit_release_block(self):
        for flags, code in [((), 0), (('--require-complete',), 2)]:
            result = self.verify(None, *flags)
            self.assertEqual(result.returncode, code, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report['releaseStatus'], 'BLOCKED')
            self.assertEqual(set(report['blockers']), {'minimisted-terms', 'cpython-embedded-notices'})
            self.assertEqual(report['runtimePackages'], 91)
            self.assertEqual(report['originalLicenseFilesPreserved'], 94)

    def test_verifier_rejects_removal_of_the_known_embedded_component(self):
        # 首版仅遍历 LICENSE/NOTICE 文件名，删除整个已识别嵌入条目亦可退出0；
        # 这里真实复制自己的小登记树、移除三项及其引用，保留锁定依赖只读。
        with tempfile.TemporaryDirectory(prefix='dsh-notice-regression-') as tmp:
            root = pathlib.Path(tmp) / 'tree'
            shutil.copytree(self.here, root / 'runtime/ohos/licenses')
            process = root / 'runtime/ohos/process'
            process.mkdir(parents=True)
            for name in ['package.json', 'package-lock.json']:
                shutil.copy2(args.registration_root / 'runtime/ohos/process' / name, process / name)
            manifest = copy.deepcopy(self.m)
            targets = {ANGULAR_LICENSE, ANGULAR_HEADER, BUNDLE_HEADER}
            manifest['documents'] = [x for x in manifest['documents'] if x['path'] not in targets]
            manifest['embeddedComponents'] = [x for x in manifest['embeddedComponents']
                                               if x.get('id') != 'angular-style-parser']
            for item in manifest['packages']:
                item['documents'] = [x for x in item['documents'] if x not in targets]
            here = root / 'runtime/ohos/licenses'
            for target in targets:
                (here / target).unlink(missing_ok=True)
            (here / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
            result = self.verify(root)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('Angular', result.stderr)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]], verbosity=2)
