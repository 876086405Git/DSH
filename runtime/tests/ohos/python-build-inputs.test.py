#!/usr/bin/env python3
"""Exercise the Python ELF preflight; stop at a controlled compiler boundary."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
MODULES = ('_ssl', '_hashlib', '_sqlite3', '_ctypes', 'zlib')


class PythonBuildInputs(unittest.TestCase):
    def check(self, needed=('libc.so', 'libz.so'), modules=MODULES,
              soname='libpython3.14.so', extra=''):
        with tempfile.TemporaryDirectory(prefix='python-build-inputs-') as temporary:
            root = Path(temporary)
            tools = root / 'sdk/llvm/bin'
            tools.mkdir(parents=True)
            output = '\n'.join(f' 0x1 (NEEDED) Shared library: [{name}]' for name in needed)
            output += f'\n 0xe (SONAME) Library soname: [{soname}]\n' + extra
            output += '\n'.join(f' 1: 0001 8 FUNC GLOBAL DEFAULT 12 PyInit_{name}' for name in modules)
            readelf = tools / 'llvm-readelf'
            readelf.write_text('#!' + sys.executable + '\nprint(' + repr(output) + ')\n')
            readelf.chmod(0o755)
            compiler = tools / 'aarch64-unknown-linux-ohos-clang'
            compiler.write_text('#!' + sys.executable + '\nimport json,sys\n'
                                'sys.stderr.write("COMPILER_BOUNDARY " + json.dumps(sys.argv[1:]) + "\\n")\n'
                                'sys.exit(73)\n')
            compiler.chmod(0o755)
            result = subprocess.run([sys.executable, '-I', '-B', str(ROOT / 'runtime/ohos/python/build-host.py'),
                                     '--sdk-native', str(root / 'sdk'), '--python-source', str(root / 'source'),
                                     '--python-build', str(root / 'python'), '--libnode', str(root / 'libnode.so'),
                                     '--node-headers', str(root / 'node'), '--output', str(root / 'output')],
                                    capture_output=True, text=True, timeout=10)
            return result

    def test_system_zlib_reaches_compiler(self):
        result = self.check()
        self.assertIn('COMPILER_BOUNDARY ', result.stderr)
        line = next(line for line in result.stderr.splitlines() if line.startswith('COMPILER_BOUNDARY '))
        self.assertIn('-DDSH_PYTHON_SSL_CERT_DIR="/etc/security/certificates"',
                      json.loads(line.removeprefix('COMPILER_BOUNDARY ')))

    def test_extension_libraries_and_versioned_zlib_stay_rejected(self):
        for library in ('libssl.so', 'libcrypto.so', 'libffi.so', 'libsqlite3.so', 'libz.so.1'):
            with self.subTest(library=library):
                result = self.check(needed=('libc.so', library))
                self.assertNotIn('COMPILER_BOUNDARY ', result.stderr)
                self.assertIn('Python extension dependencies must be static', result.stderr)

    def test_missing_module_stays_rejected(self):
        for module in MODULES:
            with self.subTest(module=module):
                result = self.check(needed=('libc.so',), modules=tuple(name for name in MODULES if name != module))
                self.assertNotIn('COMPILER_BOUNDARY ', result.stderr)
                self.assertIn('Missing mandatory builtin extension: ' + module, result.stderr)

    def test_soname_and_search_paths_stay_rejected(self):
        for options in ({'soname': 'libpython3.14.so.1.0'},
                        {'extra': '0x1d (RUNPATH) Library runpath: [/build/lib]\n'},
                        {'extra': '0xf (RPATH) Library rpath: [/build/lib]\n'}):
            with self.subTest(options=options):
                result = self.check(needed=('libc.so',), **options)
                self.assertNotIn('COMPILER_BOUNDARY ', result.stderr)
                self.assertIn('unversioned SONAME and no runtime search path', result.stderr)


if __name__ == '__main__':
    unittest.main()
