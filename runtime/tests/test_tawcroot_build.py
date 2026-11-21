#!/usr/bin/env python3
"""runtime/tawcroot/build.py without a compiler: archive pinning, source filter, ELF audit, publish."""

import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock
import zipfile


RUNTIME = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("tawcroot_build", RUNTIME / "tawcroot/build.py")
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


# Original production function from the pinned tawc path.c. The fake archive
# must expose the real patch site, even when the compiler itself is mocked.
PATH_C = """static long prod_readlink(void *ctx, const char *suffix,
\t\t\t  char *out, size_t out_cap)
{
\t(void)ctx;
\tif (!suffix || suffix[0] == 0) return TAWC_EINVAL;
\tif (tawcroot_rootfs_fd < 0)    return TAWC_EBADF;
\tlong n = TAWC_RAW(TAWC_SYS_readlinkat, tawcroot_rootfs_fd,
\t\t\t  (long)suffix, (long)out, (long)out_cap, 0, 0);
\treturn n;
}
"""


def synthetic_elf(abi, *, machine=None, alignment=16384, needed=None, entry_delta=512):
    """ELF headers only; nothing executable."""
    _, expected_machine, base = BUILD.ABIS[abi]
    data = bytearray(1024)
    segments = [(1, 5, 0, base, 0, len(data), len(data), alignment)]
    if needed is not None:
        strings = b"\0" + needed.encode() + b"\0"
        data[768:768 + len(strings)] = strings
        dynamic = b"".join(struct.pack("<qQ", tag, value) for tag, value in
                           [(5, base + 768), (10, len(strings)), (1, 1), (0, 0)])
        data[640:640 + len(dynamic)] = dynamic
        segments.append((2, 4, 640, base + 640, 0, len(dynamic), len(dynamic), 8))
    ident = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8)
    struct.pack_into("<16sHHIQQQIHHHHHH", data, 0, ident, 2,
                     expected_machine if machine is None else machine, 1,
                     base + entry_delta, 64, 0, 0, 64, 56, len(segments), 0, 0, 0)
    for index, segment in enumerate(segments):
        struct.pack_into("<IIQQQQQQ", data, 64 + index * 56, *segment)
    return bytes(data)


class TawcrootBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.runtime = self.root / "runtime"
        (self.runtime / "tawcroot").mkdir(parents=True)
        self.patch = (RUNTIME / "tawcroot/bind-aware-oracle.diff").read_bytes()
        (self.runtime / "tawcroot/bind-aware-oracle.diff").write_bytes(self.patch)
        self.source = json.loads((RUNTIME / "tawcroot/source.json").read_text())
        self.archive = self.root / "fixture.zip"
        prefix = self.source["archiveRoot"] + "/"
        with zipfile.ZipFile(self.archive, "w") as zipped:
            for name in self.source["cSources"] + ["include/example.h"]:
                zipped.writestr(prefix + "tawcroot/" + name,
                                PATH_C if name == "src/path.c" else "/* fixture */\n")
            zipped.writestr(prefix + "LICENSE.MIT", "MIT fixture\n")
            zipped.writestr(prefix + "tawcroot/tests/example.c", "not production\n")
            zipped.writestr(prefix + "app/example.kt", "not part of this build\n")
        self.source["archiveSha256"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        (self.runtime / "tawcroot/source.json").write_text(json.dumps(self.source))
        self.ndk = self.root / "ndk"
        host = BUILD.HOSTS[sys.platform]
        self.bin = self.ndk / "toolchains/llvm/prebuilt" / host / "bin"
        self.bin.mkdir(parents=True)
        suffix = ".exe" if sys.platform == "win32" else ""
        for name in ("clang", "llvm-strip"):
            (self.bin / (name + suffix)).write_text("")
        (self.ndk / "source.properties").write_text("Pkg.Revision = 28.2.13676358\n")

    def fake_tools(self, elf=synthetic_elf):
        def run(argv, **kwargs):
            if "-c" in argv and argv[argv.index("-c") + 1] == "src/path.c":
                compiled = (Path(kwargs["cwd"]) / "src/path.c").read_text()
                self.assertIn("return TAWC_ENOENT;", compiled)
            out = Path(argv[argv.index("-o") + 1]) if "-o" in argv else None
            if out is not None and out.name == "libtawcroot.so":
                abi = out.parent.name
                out.write_bytes(elf(abi))
            elif out is not None:
                out.write_bytes(b"object")
            return mock.Mock(returncode=0)
        return run

    def test_archive_is_verified_and_reused_without_network(self):
        cache = self.root / "cache"
        with mock.patch.object(BUILD.urllib.request, "urlopen") as network:
            first = BUILD.cached_archive(self.source, cache, self.archive)
            again = BUILD.cached_archive(self.source, cache, offline=True)
        network.assert_not_called()
        self.assertEqual(first, again)
        bad = self.root / "bad.zip"
        bad.write_bytes(b"not the pinned archive")
        with self.assertRaises(ValueError):
            BUILD.cached_archive(self.source, self.root / "other", bad)
        self.assertEqual(list((self.root / "other").iterdir()), [])

    def test_archive_import_and_reuse_without_file_digest(self):
        # Capability simulation only; the real interpreter is unchanged.
        cache = self.root / "cache"
        with mock.patch.dict(hashlib.__dict__), \
                mock.patch.object(BUILD.urllib.request, "urlopen") as network:
            hashlib.__dict__.pop("file_digest", None)
            first = BUILD.cached_archive(self.source, cache, self.archive)
            again = BUILD.cached_archive(self.source, cache, offline=True)
        network.assert_not_called()
        self.assertEqual(first, again)
        self.assertEqual(first.read_bytes(), self.archive.read_bytes())
        self.assertEqual(hashlib.sha256(first.read_bytes()).hexdigest(), self.source["archiveSha256"])

    def test_extracts_only_production_sources_and_license(self):
        src = BUILD.extract_source(self.archive, self.source, self.root / "x")
        self.assertTrue((src / "src/main.c").is_file())
        self.assertTrue((self.root / "x/LICENSE.MIT").is_file())
        self.assertFalse((src / "tests").exists())
        self.assertFalse((self.root / "x/app").exists())

    def test_source_patch_requires_one_unchanged_old_block(self):
        src = BUILD.extract_source(self.archive, self.source, self.root / "x")
        path = src / "src/path.c"
        anchor = "\tif (tawcroot_rootfs_fd < 0)    return TAWC_EBADF;\n"
        for text in (PATH_C.replace(anchor, ""), PATH_C + PATH_C):
            with self.subTest(matches=text.count(anchor)):
                path.write_text(text)
                with self.assertRaises(SystemExit):
                    BUILD.apply_source_patch(self.runtime, src)
                self.assertEqual(path.read_text(), text)

    def test_toolchain_needs_the_pinned_ndk(self):
        self.assertIn("clang", BUILD.toolchain(self.ndk, self.source))
        (self.ndk / "source.properties").write_text("Pkg.Revision = 27.0.1\n")
        with self.assertRaises(ValueError):
            BUILD.toolchain(self.ndk, self.source)

    def test_recipe_targets_each_abi_with_the_upstream_flags(self):
        arm = BUILD.recipe(self.source, "arm64-v8a")
        self.assertEqual(arm["compile"][0], "--target=aarch64-linux-android29")
        self.assertIn("-mno-outline-atomics", arm["compile"])
        self.assertIn("-Wl,--image-base=0x2000000000", arm["link"])
        self.assertIn("src/arch/aarch64_stub.S", arm["sources"])
        x64 = BUILD.recipe(self.source, "x86_64")
        self.assertNotIn("-mno-outline-atomics", x64["compile"])

    def test_audit_rejects_wrong_machine_dependencies_alignment_and_entry(self):
        path = self.root / "lib.so"
        for bad in (dict(machine=62), dict(needed="libc.so"), dict(alignment=4096), dict(entry_delta=0x200000)):
            with self.subTest(**bad):
                path.write_bytes(synthetic_elf("arm64-v8a", **bad))
                with self.assertRaises(ValueError):
                    BUILD.audit_artifact(path, "arm64-v8a")
        path.write_bytes(synthetic_elf("arm64-v8a"))
        self.assertEqual(BUILD.audit_artifact(path, "arm64-v8a")["bytes"], 1024)

    def test_build_publishes_both_abis_and_keeps_previous_output_on_failure(self):
        out = self.root / "out-tawcroot"
        with mock.patch.object(BUILD.subprocess, "run", side_effect=self.fake_tools()):
            BUILD.build(self.runtime, self.ndk, self.archive, output=out)
        for abi in BUILD.ABIS:
            self.assertTrue((out / "jniLibs" / abi / "libtawcroot.so").is_file())
        manifest = json.loads((out / "manifest.json").read_text())
        self.assertEqual([a["abi"] for a in manifest["artifacts"]], list(BUILD.ABIS))
        self.assertEqual(manifest["source"],
                         {key: self.source[key] for key in ("repo", "commit", "archiveSha256")})
        self.assertEqual(manifest["sourcePatch"], {
            "path": "tawcroot/bind-aware-oracle.diff",
            "sha256": hashlib.sha256(self.patch).hexdigest(),
        })
        before = (out / "manifest.json").read_bytes()

        def x64_wrong(abi):
            return synthetic_elf(abi, machine=183 if abi == "x86_64" else None)
        with mock.patch.object(BUILD.subprocess, "run", side_effect=self.fake_tools(x64_wrong)), \
                self.assertRaises(ValueError):
            BUILD.build(self.runtime, self.ndk, offline=True, output=out)
        self.assertEqual((out / "manifest.json").read_bytes(), before)

    def test_default_ndk_comes_from_the_sdk(self):
        with mock.patch.dict(BUILD.os.environ, {"ANDROID_HOME": "/sdk"}, clear=True):
            self.assertEqual(Path(BUILD.default_ndk(self.runtime)), Path("/sdk/ndk/28.2.13676358"))
        with mock.patch.dict(BUILD.os.environ, {"ANDROID_NDK_HOME": "/ndk"}, clear=True):
            self.assertEqual(BUILD.default_ndk(self.runtime), "/ndk")

    def test_default_ndk_decodes_local_properties_unicode(self):
        sdk = self.root / "Android SDK 用户 🐳"
        ndk = sdk / "ndk" / self.source["ndkVersion"]
        ndk.parent.mkdir(parents=True)
        self.ndk.rename(ndk)
        props = self.runtime.parent / "app/android/local.properties"
        props.parent.mkdir(parents=True)
        plain_unicode = str(sdk).replace("\\", "\\\\")
        escaped = plain_unicode.replace(":", "\\:").replace("用户 🐳", r"\u7528\u6237 \uD83D\uDC33")
        for label, value in (("plain Unicode", plain_unicode), ("Properties.store", escaped)):
            with self.subTest(source=label):
                props.write_text("sdk.dir=" + value + "\n", encoding="utf-8")
                with mock.patch.dict(BUILD.os.environ, {}, clear=True), \
                        mock.patch.object(BUILD.subprocess, "run", side_effect=AssertionError("no compiler")):
                    selected = BUILD.default_ndk(self.runtime)
                    self.assertEqual(Path(selected), ndk)
                    BUILD.toolchain(selected, self.source)


if __name__ == "__main__":
    unittest.main()
