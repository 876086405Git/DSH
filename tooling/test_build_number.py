"""Tests for tooling/build_number.py and tooling/build-apk.sh.

    python3 -m unittest discover -s tooling -p 'test_*.py'
"""

import datetime
import os
import pathlib
import re
import subprocess
import unittest

from build_number import MAX_VERSION_CODE, UTC_OFFSET, build_number, check, decode

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "tooling" / "build-apk.sh"


def at(text: str) -> datetime.datetime:
    return datetime.datetime.fromisoformat(text)


class BuildNumberTest(unittest.TestCase):
    def test_app_version_fallback_matches_pubspec(self):
        pubspec = (ROOT / "app" / "pubspec.yaml").read_text(encoding="utf-8")
        app_info = (ROOT / "app" / "lib" / "state" / "app_info.dart").read_text(encoding="utf-8")
        version = re.search(r"^version:\s*(\S+)", pubspec, re.MULTILINE)
        fallback = re.search(r"String\.fromEnvironment\('DSH_APP_VERSION', defaultValue: '([^']+)'\)", app_info)
        self.assertIsNotNone(version)
        self.assertIsNotNone(fallback)
        self.assertEqual(fallback.group(1), version.group(1))

    def test_reads_as_the_build_minute(self):
        self.assertEqual(build_number(at("2026-10-25T12:34+08:00")), 10251234)
        self.assertEqual(build_number(at("2026-01-01T00:00+08:00")), 1010000)
        self.assertEqual(build_number(at("2027-01-02T03:04+08:00")), 101020304)
        self.assertEqual(build_number(at("2046-12-31T23:59+08:00")), 2012312359)

    def test_clock_is_utc_plus_8_whatever_the_input_zone(self):
        self.assertEqual(build_number(at("2026-10-25T04:34Z")), 10251234)
        self.assertEqual(build_number(at("2026-10-24T22:34-06:00")), 10251234)
        # 16:30 UTC on New Year's Eve is already next year at UTC+8.
        self.assertEqual(build_number(at("2026-12-31T16:30Z")), 101010030)

    def test_needs_a_timezone(self):
        with self.assertRaises(ValueError):
            build_number(datetime.datetime(2026, 10, 25, 12, 34))

    def test_bounded_by_epoch_and_android_limit(self):
        with self.assertRaises(ValueError):
            build_number(at("2025-12-31T23:59+08:00"))
        with self.assertRaises(ValueError):
            build_number(at("2047-01-01T00:00+08:00"))
        self.assertLessEqual(build_number(at("2046-12-31T23:59+08:00")), MAX_VERSION_CODE)

    def test_later_minute_is_always_larger(self):
        # Every minute around the boundaries that could break ordering…
        edges = ["2026-10-25T12:00", "2026-12-31T23:00", "2027-02-28T23:00", "2028-02-28T23:00",
                 "2028-12-31T23:00", "2036-06-30T23:00", "2046-12-31T22:58"]
        for edge in edges:
            start = at(edge + "+08:00")
            codes = [build_number(start + datetime.timedelta(minutes=m)) for m in range(62)]
            self.assertEqual(codes, sorted(set(codes)), edge)
        # …and hourly across the whole range.
        t, end, last = at("2026-01-01T00:00+08:00"), at("2046-12-31T23:00+08:00"), 0
        while t <= end:
            code = build_number(t)
            self.assertGreater(code, last, t)
            last = code
            t += datetime.timedelta(hours=1, minutes=7)

    def test_decode_round_trips(self):
        for text in ["2026-10-25T12:34", "2027-01-02T03:04", "2028-02-29T00:00", "2046-12-31T23:59"]:
            t = at(text + "+08:00")
            self.assertEqual(decode(build_number(t)), t)
        self.assertEqual(decode(10251234).tzinfo, UTC_OFFSET)

    def test_decode_rejects_what_is_not_a_build_minute(self):
        for code in [0, -1, 1, 10321234, 10251260, 12312459, MAX_VERSION_CODE + 1]:
            with self.assertRaises(ValueError, msg=code):
                decode(code)

    def test_check(self):
        check(1)
        check(MAX_VERSION_CODE)
        for bad in [0, -5, MAX_VERSION_CODE + 1]:
            with self.assertRaises(ValueError):
                check(bad)

    def test_gradle_fallback_uses_the_same_encoding(self):
        gradle = (ROOT / "app" / "android" / "app" / "build.gradle.kts").read_text(encoding="utf-8")
        self.assertIn("ZoneOffset.ofHours(8)", gradle)
        self.assertIn(
            "(t.year - 2026) * 100_000_000 + t.monthValue * 1_000_000 + t.dayOfMonth * 10_000 + t.hour * 100 + t.minute",
            gradle,
        )
        self.assertIn("flutter.versionCode.takeIf { it > 1 } ?: buildMinuteVersionCode()", gradle)


class BuildApkDryRunTest(unittest.TestCase):
    def run_script(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", str(SCRIPT), "--dry-run", *args], capture_output=True, text=True)

    def test_relative_script_ignores_exported_cdpath(self):
        expected = self.run_script("-n", "10251234")
        self.assertEqual(expected.returncode, 0, expected.stderr)
        result = subprocess.run(
            ["bash", "tooling/build-apk.sh", "--dry-run", "-n", "10251234"],
            cwd=ROOT, env=dict(os.environ, CDPATH="."), capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected.stdout)

    def test_both_flavors_share_one_build_number(self):
        out = self.run_script("-f", "all").stdout
        commands = [line for line in out.splitlines() if "flutter build apk" in line]
        self.assertEqual(len(commands), 2)
        codes = {re.search(r"--build-number (\d+)", c).group(1) for c in commands}
        self.assertEqual(len(codes), 1)
        code = int(codes.pop())
        now = datetime.datetime.now(UTC_OFFSET)
        self.assertLess(abs((decode(code) - now).total_seconds()), 180)
        self.assertIn("--flavor arm64 --target-platform android-arm64", commands[0])
        self.assertIn("--flavor x64 --target-platform android-x64", commands[1])
        for c in commands:
            self.assertRegex(c, rf"--build-name (\S+) --build-number {code} --dart-define=DSH_APP_VERSION=\1\+{code}")
        self.assertIn("gradlew --stop", out)

    def test_options(self):
        out = self.run_script("--debug", "-f", "x64", "-t", "lib/dev/runtime_probe_main.dart", "-n", "10251234",
                              "--build-name", "0.9.0", "--keep-daemon").stdout
        self.assertIn("flutter build apk --debug --flavor x64 --target-platform android-x64 --build-name 0.9.0 "
                      "--build-number 10251234 --dart-define=DSH_APP_VERSION=0.9.0+10251234 "
                      "-t lib/dev/runtime_probe_main.dart", out)
        self.assertNotIn("gradlew --stop", out)

    def test_refuses_bad_input(self):
        for args in [("-f", "arm"), ("-n", "0"), ("-n", "abc"), ("-n", str(MAX_VERSION_CODE + 1)),
                     ("--build-name", "1.0"), ("--", "--build-number", "5"), ("--", "--split-per-abi")]:
            result = self.run_script(*args)
            self.assertNotEqual(result.returncode, 0, args)
            self.assertNotIn("flutter build apk", result.stdout, args)


if __name__ == "__main__":
    unittest.main()
