#!/usr/bin/env python3
"""Cross-build the HAP's libsqlite3.so from a pinned SQLite amalgamation; no device claim.

The Dart sqlite3 package's build hook bundles a prebuilt glibc libsqlite3.so, which
HarmonyOS (musl) cannot load. The AOT's NativeAssetsManifest.json maps that asset to a
plain dlopen of libsqlite3.so from the app's lib directory, so an OH build with the same
name replaces it. Defines and exported symbols come from the sqlite3 package the app
locks, as its hook uses them for a Linux source build; the amalgamation is never fetched.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[3]
AMALGAMATION_SHA256 = '0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9'
VERSION, VERSION_DIR = '3.54.1', 'sqlite-amalgamation-3540100'
# The package's defaults minus what only Windows means: localtime_s is the MSVC CRT form
# (musl has localtime_r); defaults(windows) adds SQLITE_API=__declspec(dllexport) there.
WINDOWS_ONLY = {'SQLITE_HAVE_LOCALTIME_S', 'SQLITE_API'}
# Used symbols a define gates. The package asks sqlite3_compileoption_used before calling
# them, and its own prebuilt libraries leave the define off too.
GATED = {'sqlite3_column_table_name': 'SQLITE_ENABLE_COLUMN_METADATA'}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def locked_version(lock):
    """The sqlite3 version app/pubspec.lock resolves."""
    block = re.search(r'^  sqlite3:\n((?:    .*\n)+)', lock, re.M)
    version = block and re.search(r'^    version: "([^"]+)"', block.group(1), re.M)
    if not version:
        raise ValueError('app/pubspec.lock does not lock sqlite3')
    return version.group(1)


def package_inputs(package):
    """(version, defines, used symbols) of the Dart sqlite3 package's hook."""
    pubspec = (package / 'pubspec.yaml').read_text()
    if not re.search(r'^name: sqlite3$', pubspec, re.M):
        raise ValueError(f'{package} is not the sqlite3 package')
    version = re.search(r'^version: (\S+)$', pubspec, re.M).group(1)
    description = (package / 'lib/src/hook/compile/description.dart').read_text()
    block = re.search(r"^const _defaultDefines = '''\n(.*?)''';", description, re.M | re.S)
    used = re.search(r'^const usedSqliteSymbols = \{\n(.*?)\};',
                     (package / 'lib/src/hook/compile/used_symbols.dart').read_text(), re.M | re.S)
    if not block or not used:
        raise ValueError('The package no longer has _defaultDefines and usedSqliteSymbols where its hook reads them')
    defines = []
    for line in filter(None, (line.strip() for line in block.group(1).splitlines())):
        name, _, value = line.partition('=')
        defines.append((name, value if '=' in line else None))
    return version, defines, sorted(re.findall(r"^\s*'(\w+)',$", used.group(1), re.M))


def declared(header):
    """What sqlite3.h declares as API: functions and the two SQLITE_EXTERN variables."""
    text = re.sub(r'/\*.*?\*/', ' ', header, flags=re.S)
    names = set(re.findall(r'\bSQLITE_API\b[^;{}]*?\b(sqlite3\w*)\s*\(', text))
    return names | set(re.findall(r'\bSQLITE_API\s+SQLITE_EXTERN\b[^;]*?\b(sqlite3\w*)\s*;', text))


def dynamic(nm, library):
    """(defined, undefined) dynamic symbol names."""
    lines = subprocess.check_output([str(nm), '-D', str(library)], text=True).splitlines()
    rows = [line.split() for line in lines if line.strip()]
    return {row[-1] for row in rows if len(row) == 3}, {row[-1] for row in rows if len(row) == 2}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-native', required=True, type=Path,
                        help='Extracted SDK native directory (llvm/ and sysroot/)')
    parser.add_argument('--amalgamation', required=True, type=Path,
                        help=f'{VERSION_DIR}.zip from sqlite.org, SHA-256 {AMALGAMATION_SHA256}')
    parser.add_argument('--sqlite3-package', required=True, type=Path,
                        help='The Dart sqlite3 package app/pubspec.lock resolves, e.g. ~/.pub-cache/hosted/pub.dev/sqlite3-3.9.1')
    parser.add_argument('--output', required=True, type=Path,
                        help='Output directory; libsqlite3.so and build.json must not exist')
    args = parser.parse_args()
    sdk, zipped, package, output = (path.resolve() for path in
                                    (args.sdk_native, args.amalgamation, args.sqlite3_package, args.output))
    clang, nm, readelf, strip = (sdk / 'llvm/bin' / tool for tool in ('clang', 'llvm-nm', 'llvm-readelf', 'llvm-strip'))
    sdk_manifest = sdk / 'oh-uni-package.json'
    for path in [clang, nm, readelf, strip, sdk_manifest, sdk / 'sysroot/usr/lib/aarch64-linux-ohos/libc.so', zipped]:
        if not path.is_file():
            parser.error(f'Missing input: {path}')
    if digest(zipped) != AMALGAMATION_SHA256:
        parser.error(f'{zipped} is not the pinned {VERSION_DIR}.zip (SHA-256 {AMALGAMATION_SHA256})')
    try:
        version, package_defines, used = package_inputs(package)
        lock_version = locked_version((ROOT / 'app/pubspec.lock').read_text())
    except (OSError, ValueError, AttributeError) as error:
        parser.error(str(error))
    if version != lock_version:
        parser.error(f'--sqlite3-package is sqlite3 {version}; app/pubspec.lock locks {lock_version}')
    defines = [(name, value) for name, value in package_defines if name not in WINDOWS_ONLY]
    dropped = [name for name, _ in package_defines if name in WINDOWS_ONLY]
    names = {name for name, _ in defines}
    gated_off = {symbol: define for symbol, define in GATED.items() if symbol in used and define not in names}
    output.mkdir(parents=True, exist_ok=True)
    if any((output / name).exists() for name in ('libsqlite3.so', 'build.json')):
        parser.error('Output already exists; choose a fresh directory')

    with tempfile.TemporaryDirectory(prefix='sqlite-', dir=output) as temporary:
        work = Path(temporary)
        source = work / VERSION_DIR
        source.mkdir()
        # Only the two files the build reads, by exact name; nothing else leaves the archive.
        with zipfile.ZipFile(zipped) as archive:
            for name in ('sqlite3.c', 'sqlite3.h'):
                (source / name).write_bytes(archive.read(f'{VERSION_DIR}/{name}'))
        header = (source / 'sqlite3.h').read_text()
        if f'#define SQLITE_VERSION        "{VERSION}"' not in header:
            raise SystemExit(f'build-sqlite: the archive is not SQLite {VERSION}')
        source_id = re.search(r'#define SQLITE_SOURCE_ID\s+"([^"]+)"', header).group(1)
        missing = sorted(set(used) - declared(header))
        if missing:
            raise SystemExit(f'build-sqlite: SQLite {VERSION} does not provide {missing}, which sqlite3 {version} uses')

        # The hook's Linux version script: every used symbol global, everything else local.
        script = work / 'sqlite.map'
        script.write_text('{\n  global:\n' + ''.join(f'    {name};\n' for name in used) + '  local:\n    *;\n};\n')
        binary = work / 'libsqlite3.so'
        command = [str(clang), '--target=aarch64-linux-ohos', f'--sysroot={sdk / "sysroot"}',
                   '-shared', '-fPIC', '-O2', '-g0', f'-ffile-prefix-map={work}=.',
                   *[f'-D{name}' if value is None else f'-D{name}={value}' for name, value in defines],
                   # The hook's Linux hardening and section flags, as native_toolchain_c passes them.
                   '-ffunction-sections', '-fdata-sections', '-fstack-protector-strong',
                   '-fstack-clash-protection', '-D_FORTIFY_SOURCE=2', '-mbranch-protection=standard',
                   '-Wl,-Bsymbolic', f'-Wl,--version-script={script}', '-Wl,--undefined-version',
                   '-Wl,--no-undefined', '-Wl,--gc-sections', '-Wl,-z,relro,-z,noexecstack',
                   '-Wl,-soname,libsqlite3.so', '-I', str(source), str(source / 'sqlite3.c'), '-lm',
                   '-o', str(binary)]
        subprocess.run(command, check=True, cwd=work)
        subprocess.run([str(strip), str(binary)], check=True)
        # hvigor strips every library again with --keep-section=.permission; audit-hap holds the
        # HAP's copy to these exact bytes, so that pass has to be a no-op.
        again = work / 'restripped.so'
        subprocess.run([str(strip), '--keep-section=.permission', str(binary), '-o', str(again)], check=True)
        if again.read_bytes() != binary.read_bytes():
            raise SystemExit("build-sqlite: hvigor's strip pass would change the library")

        elf = subprocess.check_output([str(readelf), '-h', '-l', '-d', str(binary)], text=True)
        needed = re.findall(r'\(NEEDED\).*\[(.+)\]', elf)
        problems = []
        if 'AArch64' not in elf or 'DYN (Shared object file)' not in elf or 'INTERP' in elf:
            problems.append('not an AArch64 shared object without PT_INTERP')
        if re.findall(r'\(SONAME\).*\[(.+)\]', elf) != ['libsqlite3.so']:
            problems.append('SONAME is not libsqlite3.so')
        if 'RPATH' in elf or 'RUNPATH' in elf:
            problems.append('carries an RPATH or RUNPATH')
        if set(needed) - {'libc.so'}:
            problems.append(f'needs {needed}; only the sysroot libc.so is expected')
        defined, undefined = dynamic(nm, binary)
        if any('@' in name for name in defined | undefined):
            problems.append('has versioned (glibc-style) symbols')
        expected = set(used) - set(gated_off)
        if defined != expected:
            problems.append(f'exports differ from sqlite3 {version}: missing {sorted(expected - defined)}, '
                            f'extra {sorted(defined - expected)}')
        if problems:
            raise SystemExit('build-sqlite: libsqlite3.so ' + '; '.join(problems))

        manifest = {
            'target': 'aarch64-linux-ohos', 'scope': 'cross-compiled; device load NOT_RUN',
            'sqlite': {'version': VERSION, 'sourceId': source_id, 'amalgamation': zipped.name,
                       'amalgamationSha256': AMALGAMATION_SHA256},
            'dartPackage': {'name': 'sqlite3', 'version': version,
                            'descriptionSha256': digest(package / 'lib/src/hook/compile/description.dart'),
                            'usedSymbolsSha256': digest(package / 'lib/src/hook/compile/used_symbols.dart')},
            'defines': [name if value is None else f'{name}={value}' for name, value in defines],
            'droppedWindowsDefines': dropped,
            'usedSymbols': len(used), 'exported': len(defined), 'gatedOff': gated_off,
            'needed': needed, 'undefined': sorted(undefined),
            'sdkManifest': json.loads(sdk_manifest.read_text()), 'sdkManifestSha256': digest(sdk_manifest),
            'compilerSha256': digest(clang),
            'compilerVersion': subprocess.check_output([str(clang), '--version'], text=True).splitlines()[0],
            'command': [part.replace(str(work), '<work>').replace(str(sdk), '<sdk-native>') for part in command],
            'strip': 'llvm-strip (all); a second hvigor-style pass leaves the bytes unchanged',
            'bytes': binary.stat().st_size, 'sha256': digest(binary),
        }
        report = work / 'build.json'
        report.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
        os.replace(binary, output / 'libsqlite3.so')
        os.replace(report, output / 'build.json')
    print(json.dumps({'output': str(output / 'libsqlite3.so'), 'sha256': manifest['sha256'],
                      'bytes': manifest['bytes'], 'exported': manifest['exported'],
                      'gatedOff': gated_off}, ensure_ascii=False))


if __name__ == '__main__':
    main()
