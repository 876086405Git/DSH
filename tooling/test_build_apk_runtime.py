"""Exercise the shipped build-apk shell with tiny files and a fake Flutter.

No Flutter, Gradle, JVM, actual runtime archive or APK is built by these tests.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
ABIS = {"arm64": "arm64-v8a", "x64": "x86_64"}
JNI = ("libproot.so", "libproot-loader.so", "libtalloc.so", "libandroid-shmem.so")


class BuildApkRuntimeTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="build-apk-runtime-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "tooling").mkdir()
        (self.root / "app").mkdir()
        for name in ("build-apk.sh", "build_number.py", "check_runtime_bundle.py"):
            shutil.copy2(ROOT / "tooling" / name, self.root / "tooling" / name)
        (self.root / "app/pubspec.yaml").write_text("version: 1.0.0+1\n")
        # Stand-in for runtime/tawcroot/build.py: TAWCROOT_EXIT decides whether it "builds".
        tawcroot = self.root / "runtime/tawcroot"
        tawcroot.mkdir(parents=True)
        (tawcroot / "build.py").write_text("import os, sys\nsys.exit(int(os.environ.get('TAWCROOT_EXIT', '0')))\n")
        # Stand-in for tooling/check_apk_jni.py: notes each APK; JNI_CHECK_EXIT decides whether it passes.
        self.jni_file = self.root / "jni-checks.txt"
        (self.root / "tooling/check_apk_jni.py").write_text(
            "import os, sys\nopen(os.environ['RUNTIME_GATE_TEST_JNI'], 'a').write(sys.argv[1] + '\\n')\n"
            "sys.exit(int(os.environ.get('JNI_CHECK_EXIT', '0')))\n")
        # Stand-in for tooling/companion_pack.py: notes each call; the pack is a placeholder file.
        self.pack_file = self.root / "pack-calls.txt"
        (self.root / "tooling/companion_pack.py").write_text(
            "import os, sys\nopen(os.environ['RUNTIME_GATE_TEST_PACK'], 'a').write(' '.join(sys.argv[1:]) + '\\n')\n"
            "sys.exit(int(os.environ.get('PACK_CHECK_EXIT', '0')) if sys.argv[1] == 'check' else 0)\n")
        pack = self.root / "whale-girl-source.zip"
        pack.write_bytes(b"pack")
        self.calls_file = self.root / "flutter-calls.jsonl"
        tools = self.root / "bin"
        tools.mkdir()
        flutter = tools / "flutter"
        flutter.write_text(f"#!{sys.executable}\n" + '''import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['RUNTIME_GATE_TEST_CALLS'], 'a') as out:
    out.write(json.dumps(args) + '\\n')
if code := int(os.environ.get('RUNTIME_GATE_TEST_FLUTTER_EXIT', '0')):
    sys.exit(code)
flavor = args[args.index('--flavor') + 1]
mode = next((arg[2:] for arg in reversed(args) if arg in ('--release', '--debug', '--profile')), 'release')
apk = pathlib.Path('build/app/outputs/flutter-apk') / f'app-{flavor}-{mode}.apk'
apk.parent.mkdir(parents=True, exist_ok=True)
apk.write_bytes(b'fake APK: shell flow only')
''')
        flutter.chmod(0o755)
        aapt = tools / "aapt2"
        aapt.write_text(f"#!{sys.executable}\n" + '''print("package: name='fixture' versionCode='10251234' versionName='1.0.0'")
''')
        aapt.chmod(0o755)
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                        RUNTIME_GATE_TEST_CALLS=str(self.calls_file), RUNTIME_GATE_TEST_JNI=str(self.jni_file),
                        RUNTIME_GATE_TEST_PACK=str(self.pack_file), DSH_COMPANION_PACK=str(pack))

    def run_script(self, *args, keep_daemon=True):
        self.calls_file.unlink(missing_ok=True)
        return subprocess.run(["bash", str(self.root / "tooling/build-apk.sh"),
                               *(["--keep-daemon"] if keep_daemon else []),
                               "--build-name", "1.0.0", "-n", "10251234", *args],
                              env=self.env, capture_output=True, text=True, timeout=15)

    def test_release_places_and_checks_the_companion_pack(self):
        self.make_bundle("arm64", 2)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        place, check = self.pack_file.read_text().splitlines()
        self.assertTrue(place.startswith("place ") and check.startswith("check "), (place, check))

        self.env["PACK_CHECK_EXIT"] = "1"
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("companion pack", result.stderr)
        del self.env["PACK_CHECK_EXIT"]

        self.pack_file.unlink()
        self.env["DSH_COMPANION_PACK"] = str(self.root / "missing.zip")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--no-companion", result.stderr)
        # A pack an earlier build placed sits out a --no-companion build and comes back after.
        placed = self.root / "app/assets/companion/whale-girl.zip"
        placed.parent.mkdir(parents=True)
        placed.write_bytes(b"placed")
        self.assertEqual(self.run_script("--no-companion").returncode, 0)
        self.assertFalse(self.pack_file.exists())
        self.assertEqual(placed.read_bytes(), b"placed")
        self.assertFalse((self.root / "app/build/.whale-girl.zip.held").exists())

    def test_exit_cleanup_leaves_daemons_outside_gradle_stop_alive(self):
        android = self.root / "app/android"
        android.mkdir()
        stop_log = self.root / "gradle-stop.log"
        gradlew = android / "gradlew"
        gradlew.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$RUNTIME_GATE_TEST_STOP_LOG"\n')
        gradlew.chmod(0o755)
        self.env["RUNTIME_GATE_TEST_STOP_LOG"] = str(stop_log)
        # Use the actual name predicate, but forward only our own peer's PID.
        # No unrelated workspace process can reach the shipped shell's kill.
        real_pgrep = shutil.which("pgrep")
        self.assertIsNotNone(real_pgrep)
        pgrep = self.root / "bin/pgrep"
        pgrep.write_text(f"#!{sys.executable}\nimport os, subprocess, sys\n"
                         f"pids = subprocess.check_output([{real_pgrep!r}, *sys.argv[1:]], text=True)\n"
                         "for pid in pids.splitlines():\n"
                         "    if pid == os.environ['RUNTIME_GATE_TEST_PEER_PID']: print(pid)\n")
        pgrep.chmod(0o755)
        for flutter_exit in (0, 23):
            for keep_daemon in (False, True):
                with self.subTest(flutter_exit=flutter_exit, keep_daemon=keep_daemon):
                    stop_log.unlink(missing_ok=True)
                    self.env["RUNTIME_GATE_TEST_FLUTTER_EXIT"] = str(flutter_exit)
                    # A stand-in for another version/home: Gradle's scoped stop
                    # leaves it alone; a global name-based SIGTERM reaches it.
                    peer = subprocess.Popen(["bash", "-c",
                                             "exec -a org.gradle.launcher.daemon.bootstrap.GradleDaemon sleep 30"])
                    self.env["RUNTIME_GATE_TEST_PEER_PID"] = str(peer.pid)
                    try:
                        result = self.run_script("--debug", keep_daemon=keep_daemon)
                        self.assertEqual(result.returncode, flutter_exit, result.stderr)
                        if keep_daemon:
                            self.assertFalse(stop_log.exists())
                        else:
                            self.assertEqual(stop_log.read_text().splitlines(), ["--stop", "-q"])
                        with self.assertRaises(subprocess.TimeoutExpired):
                            peer.wait(timeout=0.2)
                    finally:
                        peer.terminate()
                        peer.wait(timeout=5)

    def calls(self):
        if not self.calls_file.exists():
            return []
        return [json.loads(line) for line in self.calls_file.read_text().splitlines()]

    def make_bundle(self, flavor, schema):
        abi = ABIS[flavor]
        bundle = self.root / "runtime/out" / abi
        assets = bundle / "assets/runtime"
        assets.mkdir(parents=True, exist_ok=True)
        jni = bundle / "jniLibs" / abi
        jni.mkdir(parents=True, exist_ok=True)
        records = {}
        for name in JNI:
            payload = f"fixture {abi} {name}".encode()
            (jni / name).write_bytes(payload)
            records[name] = {"bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
        data = {"schema": schema, "abi": abi, "jniLibs": records}
        archives = {}
        for kind in (("rootfs",) if schema == 1 else ("base", "engine")):
            payload = f"fixture {abi} {kind} archive".encode()
            name = f"{kind}-{abi}.tar.xz"
            (assets / name).write_bytes(payload)
            archives[kind] = {"asset": name, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
        if schema == 1:
            rootfs = archives["rootfs"]
            data.update(rootfs=rootfs["asset"], rootfsBytes=rootfs["bytes"], rootfsSha256=rootfs["sha256"])
        else:
            data["layers"] = archives
        path = assets / "manifest.json"
        path.write_text(json.dumps(data))
        return path, data

    def assert_blocked(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assertEqual(self.calls(), [], "preflight must finish before any Flutter build")

    def test_release_missing_runtime_blocks_each_flavor(self):
        for flavor in ("arm64", "x64", "all"):
            with self.subTest(flavor=flavor):
                self.assert_blocked(self.run_script("--release", "-f", flavor), "manifest.json")

    def test_all_preflights_both_before_building_either(self):
        self.make_bundle("arm64", 1)
        self.assert_blocked(self.run_script("-f", "all"), "x86_64/assets/runtime/manifest.json")

    def test_both_schemas_and_abis_accept_complete_bundles(self):
        for flavor in ABIS:
            for schema in (1, 2):
                with self.subTest(flavor=flavor, schema=schema):
                    self.make_bundle(flavor, schema)
                    result = self.run_script("-f", flavor)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(len(self.calls()), 1)

    def test_all_complete_flavors_build_with_one_number(self):
        self.make_bundle("arm64", 1)
        self.make_bundle("x64", 2)
        result = self.run_script("-f", "all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([args[args.index("--flavor") + 1] for args in self.calls()], ["arm64", "x64"])
        self.assertEqual({args[args.index("--build-number") + 1] for args in self.calls()}, {"10251234"})
        checked = [Path(line).name for line in self.jni_file.read_text().splitlines()]
        self.assertEqual(checked, ["app-arm64-release.apk", "app-x64-release.apk"])

    def test_an_apk_without_the_onnx_jni_classes_stops_the_build(self):
        self.make_bundle("arm64", 1)
        self.env["JNI_CHECK_EXIT"] = "1"
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("proguard-rules.pro", result.stderr)

    def test_each_archive_is_required(self):
        for schema, kind in ((1, "rootfs"), (2, "base"), (2, "engine")):
            with self.subTest(schema=schema, kind=kind):
                path, data = self.make_bundle("arm64", schema)
                name = data["rootfs"] if schema == 1 else data["layers"][kind]["asset"]
                (path.parent / name).unlink()
                self.assert_blocked(self.run_script(), name)

    def test_each_required_jni_file_is_required(self):
        for name in JNI:
            with self.subTest(name=name):
                self.make_bundle("arm64", 2)
                (self.root / "runtime/out/arm64-v8a/jniLibs/arm64-v8a" / name).unlink()
                self.assert_blocked(self.run_script(), name)

    def test_jni_cannot_be_omitted_from_manifest(self):
        path, data = self.make_bundle("arm64", 2)
        del data["jniLibs"]["libproot-loader.so"]
        path.write_text(json.dumps(data))
        self.assert_blocked(self.run_script(), "libproot-loader.so")

    def test_declared_archive_and_jni_size_and_hash_are_checked(self):
        for item in ("archive", "jni"):
            for field, value, message in (("bytes", 1, "size mismatch"), ("sha256", "0" * 64, "sha256 mismatch")):
                with self.subTest(item=item, field=field):
                    path, data = self.make_bundle("arm64", 2)
                    record = data["layers"]["engine"] if item == "archive" else data["jniLibs"]["libproot.so"]
                    record[field] = value
                    path.write_text(json.dumps(data))
                    self.assert_blocked(self.run_script(), message)

    def test_wrong_abi_unknown_schema_and_mixed_manifests_fail(self):
        cases = [(1, {"abi": "x86_64"}, "expected ABI"), (1, {"schema": 9}, "schema"),
                 (1, {"layers": {}}, "schema 1"), (2, {"rootfs": "old.tar.xz"}, "schema 2")]
        for schema, change, message in cases:
            with self.subTest(change=change):
                path, data = self.make_bundle("arm64", schema)
                data.update(change)
                path.write_text(json.dumps(data))
                self.assert_blocked(self.run_script(), message)

    def test_release_needs_libtawcroot_and_debug_goes_on_without_it(self):
        self.make_bundle("arm64", 2)
        self.env["TAWCROOT_EXIT"] = "1"
        self.assert_blocked(self.run_script("--release", "-f", "arm64"), "libtawcroot.so did not build")
        result = self.run_script("--debug", "-f", "arm64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("tawcroot launch option will be unavailable", result.stderr)
        self.assertEqual(len(self.calls()), 1)

    def test_debug_and_profile_keep_allowing_no_runtime(self):
        for mode in ("debug", "profile"):
            with self.subTest(mode=mode):
                result = self.run_script("--" + mode, "-f", "x64")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.calls()), 1)

    def test_dry_run_does_not_require_runtime_or_invoke_flutter(self):
        result = self.run_script("--dry-run", "-f", "all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertEqual(result.stdout.count("flutter build apk"), 2)

    def test_leading_zero_build_number_uses_one_decimal_value(self):
        result = self.run_script("--debug", "-n", "00010251234")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls()), 1)
        args = self.calls()[0]
        self.assertEqual(args[args.index("--build-number") + 1], "10251234")
        self.assertIn("--dart-define=DSH_APP_VERSION=1.0.0+10251234", args)
        # The existing fake aapt2 returns integer metadata 10251234; the actual
        # shell has completed its readback check, without running Flutter/Gradle.

    def test_placeholder_build_number_is_rejected_before_flutter(self):
        for value in ("1", "0001"):
            with self.subTest(value=value):
                self.assert_blocked(self.run_script("--debug", "-n", value), "reserved")

    def test_invalid_custom_build_number_is_rejected_before_flutter(self):
        for value in ("0", "0000", "2100000001"):
            with self.subTest(value=value):
                self.assert_blocked(self.run_script("--debug", "-n", value), "versionCode must be")

    def test_extra_mode_flags_cannot_bypass_the_release_gate(self):
        for arg in ("--release", "--profile", "--debug", "--no-debug", "--release=true"):
            with self.subTest(arg=arg):
                self.assert_blocked(self.run_script("--debug", "--", arg), "set by this script")


if __name__ == "__main__":
    unittest.main()
