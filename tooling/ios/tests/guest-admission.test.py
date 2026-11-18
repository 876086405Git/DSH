"""Compile production admission with real POSIX IO and mocked Darwin IO."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
NATIVE = ROOT / "runtime/ios/guest/native"
SOURCE = Path(__file__).with_suffix("").with_suffix(".c")
CC = shutil.which(os.environ.get("CC", "cc"))


@unittest.skipUnless(CC, "C compiler unavailable")
class GuestAdmissionTest(unittest.TestCase):
    def compile_and_run(self, darwin):
        with tempfile.TemporaryDirectory(prefix="guest-admission-") as temporary:
            directory = Path(temporary)
            output = directory / "admission"
            sources = [str(SOURCE)]
            flags = []
            if darwin:
                flags.append("-DTEST_DARWIN")
            else:
                sources += [str(NATIVE / name) for name in
                            ("bound_admission.c", "bound_file.c", "bound_parent.c")]
            subprocess.run([CC, "-std=c11", "-D_GNU_SOURCE", "-Wall", "-Wextra",
                            "-Werror", "-I", str(NATIVE), *flags, *sources,
                            "-o", str(output)], check=True)
            subprocess.run([str(output), str(directory)], check=True)

    def test_darwin_descriptor_path_validation(self):
        self.compile_and_run(darwin=True)

    def test_posix_admission_boundaries(self):
        self.compile_and_run(darwin=False)


if __name__ == "__main__":
    unittest.main()
