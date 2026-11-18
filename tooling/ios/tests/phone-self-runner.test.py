"""Build-contract checks everywhere, real Security-framework handshake on macOS.

This does not run testmanagerd or prove on-device XCTest launch.
"""
import os
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class PhoneBuildContracts(unittest.TestCase):
    def test_shared_bootstrap_and_state_tests_are_in_the_correct_targets(self):
        project = (ROOT / 'app/ios/Runner.xcodeproj/project.pbxproj').read_text()
        definitions = re.findall(r'^\t\t([A-F0-9]{24}) /\*.*?\*/ = \{', project, re.M)
        self.assertEqual(len(definitions), len(set(definitions)), 'duplicate Xcode object ids')
        for object_id, expected in [
            ('97C146EA1CF9000F007C117D', ['D5480000000000000000F102', 'D5480000000000000000F105']),
            ('D5480000000000000000E003', ['D5480000000000000000F103']),
            ('331C807D294A63A400263BE5', ['D5480000000000000000F107']),
        ]:
            source_phase = re.search(r'\t\t' + object_id + r' /\* Sources \*/ = \{(.*?)\n\t\t\};', project, re.S)
            self.assertIsNotNone(source_phase)
            for build_id in expected:
                self.assertIn(build_id, source_phase.group(1))
        for relative in [
            'app/ios/PhoneRunner/PhoneRunnerBootstrap.swift',
            'app/ios/Runner/IOSPhoneSelfRunner.swift',
            'app/ios/RunnerTests/IOSPhoneSelfRunnerTests.swift',
        ]:
            self.assertTrue((ROOT / relative).is_file(), relative)

    def test_xcode_configs_allow_a_missing_generated_native_config(self):
        for filename in ['Debug.xcconfig', 'Release.xcconfig']:
            data = (ROOT / 'app/ios/Flutter' / filename).read_text()
            self.assertIn('#include? "../PhoneSelfRunnerNative/PhoneSelfRunner.xcconfig"', data)
            self.assertNotIn('-force_load', data)
            self.assertNotIn('DSH_PHONE_SELF_RUNNER =', data)
        manager = (ROOT / 'app/ios/Runner/IOSPhoneSelfRunner.swift').read_text()
        self.assertIn('#if DSH_PHONE_SELF_RUNNER', manager)
        self.assertIn('return nil', manager)

    def test_local_network_and_no_group_runner_configuration(self):
        with (ROOT / 'app/ios/Runner/Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        self.assertIn('_remotepairing._tcp', info['NSBonjourServices'])
        self.assertIn('local developer service', info['NSLocalNetworkUsageDescription'])
        self.assertNotIn('NSAllowsArbitraryLoads', info['NSAppTransportSecurity'])
        with (ROOT / 'app/ios/PhoneRunner/PhoneRunnerSelf.entitlements').open('rb') as stream:
            self.assertEqual(plistlib.load(stream), {})
        with (ROOT / 'app/ios/PhoneRunner/PhoneRunner.entitlements').open('rb') as stream:
            self.assertIn('com.apple.security.application-groups', plistlib.load(stream))

    @unittest.skipUnless(shutil.which(os.environ.get('CC', 'cc')), 'C compiler unavailable')
    def test_native_header_remains_a_standalone_c_interface(self):
        source = '#include "dsh_phone_self_runner.h"\nstatic dsh_phone_xctest_callback sink;\nint main(void) { return sink != 0; }\n'
        subprocess.run([os.environ.get('CC', 'cc'), '-x', 'c', '-std=c11', '-Werror', '-fsyntax-only',
                        '-I', str(ROOT / 'tooling/ios/phone-self-runner/include'), '-'], input=source, text=True, check=True)


class PhoneSetupScript(unittest.TestCase):
    def run_setup(self, valid):
        with tempfile.TemporaryDirectory(prefix='phone-setup-') as temporary:
            base = Path(temporary)
            binaries = base / 'bin'
            binaries.mkdir()
            (base / 'temporary builds').mkdir()
            (binaries / 'uname').write_text('#!/bin/sh\nprintf "Darwin\\n"\n')
            recorder = '''#!/usr/bin/env python3
import json, os, pathlib, sys
with open(os.environ['PHONE_SETUP_LOG'], 'a') as stream:
    stream.write(json.dumps([pathlib.Path(sys.argv[0]).name, *sys.argv[1:]]) + '\\n')
if pathlib.Path(sys.argv[0]).name == 'xcodebuild':
    derived = pathlib.Path(sys.argv[sys.argv.index('-derivedDataPath') + 1])
    (derived / 'Build/Products/Debug-iphoneos/PhoneRunnerUITests-Runner.app').mkdir(parents=True)
'''
            for name in ['xcodebuild', 'xcrun']:
                (binaries / name).write_text(recorder)
            for path in binaries.iterdir():
                path.chmod(0o755)
            pairing = base / 'synthetic pairing.plist'
            value = {'identifier': 'synthetic', 'public_key': bytes(32), 'private_key': bytes(32)} if valid else {'HostID': 'not-an-RP-record'}
            pairing.write_bytes(plistlib.dumps(value))
            log = base / 'commands.jsonl'
            env = {**os.environ, 'PATH': str(binaries) + os.pathsep + os.environ['PATH'],
                   'PHONE_SETUP_LOG': str(log), 'TMPDIR': str(base / 'temporary builds')}
            result = subprocess.run(['bash', str(ROOT / 'tooling/ios/prepare-phone-self-runner.sh'),
                                     '--device', 'synthetic-device', '--pairing', str(pairing),
                                     '--team', 'synthetic-team', '--app-bundle-id', 'example.dsh'],
                                    env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_explicit_setup_builds_and_installs_without_issuing_phone_actions(self):
        result, calls = self.run_setup(valid=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][0:2], ['xcodebuild', 'build-for-testing'])
        self.assertIn('CODE_SIGN_ENTITLEMENTS=PhoneRunner/PhoneRunnerSelf.entitlements', calls[0])
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER=example.dsh.PhoneRunner', calls[0])
        self.assertEqual(calls[1][0:5], ['xcrun', 'devicectl', 'device', 'install', 'app'])
        self.assertFalse(any('copy' in call for call in calls))
        self.assertIn('choose how to store it', result.stdout)
        self.assertNotIn('private_key', result.stdout + result.stderr)

    def test_lockdown_record_is_rejected_before_any_device_command(self):
        result, calls = self.run_setup(valid=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not a lockdown pairing file', result.stderr)
        self.assertEqual(calls, [])


class PhoneNoticeEmbedding(unittest.TestCase):
    def test_unconfigured_notice_phase_skips_unused_inputs(self):
        result = subprocess.run(['bash', str(ROOT / 'tooling/ios/embed-phone-self-runner-notices.sh')],
                                env={**os.environ, 'DSH_PHONE_SELF_RUNNER_ENABLED': 'NO'}, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_enabled_build_copies_only_declared_notices(self):
        with tempfile.TemporaryDirectory(prefix='phone-notices-') as temporary:
            base = Path(temporary)
            source = base / 'ios/PhoneSelfRunnerNative'
            source.mkdir(parents=True)
            for name in ['LICENSE.idevice.txt', 'THIRD_PARTY_CRATES.json', 'NOTICES.txt', 'SOURCE.json']:
                (source / name).write_text('synthetic notice')
            (source / 'pairingFile.plist').write_text('not-a-real-pairing-record')
            env = {**os.environ, 'DSH_PHONE_SELF_RUNNER_ENABLED': 'YES', 'SRCROOT': str(base / 'ios'),
                   'TARGET_BUILD_DIR': str(base / 'products'), 'UNLOCALIZED_RESOURCES_FOLDER_PATH': 'Runner.app'}
            subprocess.run(['bash', str(ROOT / 'tooling/ios/embed-phone-self-runner-notices.sh')], env=env, check=True)
            output = base / 'products/Runner.app/PhoneSelfRunnerNotices'
            self.assertEqual({path.name for path in output.iterdir()}, {'LICENSE.idevice.txt', 'THIRD_PARTY_CRATES.json', 'NOTICES.txt', 'SOURCE.json'})
            self.assertEqual((output / 'NOTICES.txt').read_bytes(), (source / 'NOTICES.txt').read_bytes())

    def test_old_inventory_only_inputs_cannot_publish_a_new_bundle(self):
        with tempfile.TemporaryDirectory(prefix='phone-notices-') as temporary:
            base = Path(temporary)
            source = base / 'ios/PhoneSelfRunnerNative'
            source.mkdir(parents=True)
            for name in ['LICENSE.idevice.txt', 'THIRD_PARTY_CRATES.json', 'SOURCE.json']:
                (source / name).write_text('old synthetic notice')
            env = {**os.environ, 'DSH_PHONE_SELF_RUNNER_ENABLED': 'YES', 'SRCROOT': str(base / 'ios'),
                   'TARGET_BUILD_DIR': str(base / 'products'), 'UNLOCALIZED_RESOURCES_FOLDER_PATH': 'Runner.app'}
            result = subprocess.run(['bash', str(ROOT / 'tooling/ios/embed-phone-self-runner-notices.sh')], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'NOTICES.txt', result.stderr)
            self.assertFalse((base / 'products').exists())

    def test_enabled_build_missing_notices_fails_before_publishing(self):
        with tempfile.TemporaryDirectory(prefix='phone-notices-') as temporary:
            base = Path(temporary)
            env = {**os.environ, 'DSH_PHONE_SELF_RUNNER_ENABLED': 'YES', 'SRCROOT': str(base / 'ios'),
                   'TARGET_BUILD_DIR': str(base / 'products'), 'UNLOCALIZED_RESOURCES_FOLDER_PATH': 'Runner.app'}
            result = subprocess.run(['bash', str(ROOT / 'tooling/ios/embed-phone-self-runner-notices.sh')], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((base / 'products').exists())


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'Requires Apple Security and Swift; not tested on Linux')
class PhoneAppleHandshake(unittest.TestCase):
    def test_model_plan_cannot_invoke_private_activation_or_choose_return_target(self):
        with tempfile.TemporaryDirectory(prefix='phone-operation-') as temporary:
            temporary = Path(temporary)
            # The actual Foundation-only request envelope, without UIKit views.
            source = (ROOT / 'app/ios/Runner/IOSPhoneActions.swift').read_text()
            request = source[source.index('struct IOSPhoneRequest:'):source.index('struct IOSPhoneOutcome')]
            request_file = temporary / 'request.swift'
            request_file.write_text('import Foundation\n' + request)
            executable = temporary / 'check'
            subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                            str(request_file), str(ROOT / 'app/ios/PhoneRunner/PhoneRunnerBootstrap.swift'),
                            str(ROOT / 'app/ios/Runner/IOSPhoneOperation.swift'),
                            str(ROOT / 'tooling/ios/tests/phone-operation.swift'), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_real_ephemeral_rsa_readiness_protocol(self):
        with tempfile.TemporaryDirectory(prefix='phone-handshake-') as temporary:
            executable = Path(temporary) / 'check'
            subprocess.run(['xcrun', 'swiftc', '-swift-version', '5',
                            str(ROOT / 'app/ios/PhoneRunner/PhoneRunnerBootstrap.swift'),
                            str(ROOT / 'tooling/ios/tests/phone-bootstrap.swift'),
                            '-framework', 'Security', '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)


def load_tests(loader, tests, pattern):
    # This is the existing macOS CI entry point. Include the real portable
    # collector/build-input suite so notice publication is an automatic gate.
    path = ROOT / 'tooling/ios/phone-self-runner/tests/test_build_inputs.py'
    spec = importlib.util.spec_from_file_location('phone_native_build_inputs', path)
    inputs = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(inputs)
    tests.addTests(loader.loadTestsFromModule(inputs))
    return tests


if __name__ == '__main__':
    unittest.main()
