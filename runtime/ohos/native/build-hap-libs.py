#!/usr/bin/env python3
"""Build the HAP's native set beside a built libnode, then audit it as a whole. No device claim."""

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
ADDON_ENTRY_POINTS = {'napi_register_module_v1', 'node_api_module_get_api_version_v1'}


def plain_api(name):
    return name.startswith(('napi_', 'node_api_'))


def renamed_api(name):
    return name.startswith(('dsh_napi_', 'dsh_node_api_'))


class Elf:
    def __init__(self, path, tools):
        self.path = path
        dynamic = subprocess.check_output([str(tools / 'llvm-readelf'), '-d', str(path)], text=True)
        self.needed = re.findall(r'\(NEEDED\).*\[(.+)\]', dynamic)
        self.runpath = 'RUNPATH' in dynamic or 'RPATH' in dynamic
        self.defined, self.strong, self.weak = set(), set(), set()
        for line in subprocess.check_output([str(tools / 'llvm-nm'), '-D', str(path)], text=True).splitlines():
            kind, name = line.split()[-2:]
            (self.strong if kind == 'U' else self.weak if kind in 'wv' and len(line.split()) == 2 else self.defined).add(name)


def audit(libraries, sdk):
    tools, sysroot = sdk / 'llvm/bin', sdk / 'sysroot/usr/lib/aarch64-linux-ohos'
    elves = {path.name: Elf(path, tools) for path in sorted(libraries.glob('*.so'))}
    platform = {}

    def provider(name):
        if name in elves:
            return elves[name]
        if name not in platform and (sysroot / name).is_file():
            platform[name] = Elf(sysroot / name, tools)
        return platform.get(name)

    problems, report = [], {}
    for name, elf in elves.items():
        if elf.runpath:
            problems.append(f'{name} carries a RUNPATH')
        glibc = sorted(symbol for symbol in elf.strong | elf.weak | elf.defined if '@GLIBC_' in symbol)
        if glibc:
            problems.append(f'{name} has {len(glibc)} glibc-versioned symbols, e.g. {glibc[:3]}')
        closure, pending = {}, list(elf.needed)
        while pending:
            dependency = pending.pop()
            if dependency in closure:
                continue
            closure[dependency] = provider(dependency)
            if closure[dependency] is None:
                problems.append(f'{name} needs {dependency}, outside the set and the SDK sysroot')
            else:
                pending += closure[dependency].needed
        visible = {symbol for dep in closure.values() if dep for symbol in dep.defined}
        unresolved = sorted(elf.strong - visible)
        if unresolved:
            problems.append(f'{name} has unresolved strong imports: {unresolved}')
        report[name] = {'bytes': elf.path.stat().st_size, 'needed': elf.needed, 'exports': len(elf.defined),
                        'strongImports': len(elf.strong), 'weakImports': sorted(elf.weak),
                        'plainApiImports': sum(map(plain_api, elf.strong)),
                        'renamedApiImports': sum(map(renamed_api, elf.strong))}

    host, node = elves.get('libdsh_host.so'), elves.get('libnode.so')
    if host is None or node is None:
        problems.append('The set needs libdsh_host.so and libnode.so')
    else:
        ark = provider('libace_napi.z.so')
        if 'libace_napi.z.so' not in host.needed or not {n for n in host.strong if plain_api(n)} <= ark.defined:
            problems.append('libdsh_host.so plain N-API imports must resolve in libace_napi.z.so')
        if not {'dsh_node_start', 'dsh_node_stop'} <= host.strong:
            problems.append('libdsh_host.so must import the C ABI start/stop pair')
        for name, elf in elves.items():
            if elf is not host and any(map(plain_api, elf.strong)):
                problems.append(f'{name} imports plain N-API, which only libdsh_host.so may do')
            if elf is not node and any(map(renamed_api, elf.defined)):
                problems.append(f'{name} defines renamed N-API, which only libnode.so may do')
            if elf is host and any(map(renamed_api, elf.strong)):
                problems.append('libdsh_host.so imports renamed N-API')
            if elf is not node and any(map(renamed_api, elf.strong)) and 'libnode.so' not in elf.needed:
                problems.append(f'{name} imports renamed N-API without depending on libnode.so')
            if any(plain_api(symbol) and symbol not in ADDON_ENTRY_POINTS for symbol in elf.defined):
                problems.append(f'{name} defines plain N-API functions')
    return problems, {'libraries': report, 'totalBytes': sum(entry['bytes'] for entry in report.values()),
                      'scope': 'ELF symbols and dependencies only; HAP load and device behavior NOT_RUN'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-native', required=True, type=Path)
    parser.add_argument('--clang', required=True, type=Path, help='The clang++ --cxx-runtime was built with')
    parser.add_argument('--cxx-runtime', required=True, type=Path, help='Output of build-runtimes.py')
    parser.add_argument('--libnode-output', required=True, type=Path, help='Output of build-node.py')
    parser.add_argument('--node-source', required=True, type=Path, help='Pristine Node 24.22.1 source')
    parser.add_argument('--flock-package', required=True, type=Path,
                        help='Locked @deepseek-ai/node-addon-system 0.1.2 directory')
    parser.add_argument('--loader-source', required=True, type=Path,
                        help='Extracted upstream archive listed in loader/source-pins.json')
    parser.add_argument('--node-addon-api', required=True, type=Path, help='node-addon-api 8.9.2 directory')
    parser.add_argument('--work', required=True, type=Path, help='Fresh build directory')
    parser.add_argument('--output', required=True, type=Path, help='Fresh arm64-v8a directory')
    parser.add_argument('--tinyemu-source', type=Path, help='Optional fixed TinyEMU archive; builds signed Linux backend into this HAP set')
    parser.add_argument('--workspace-grants', action='store_true', help='Build the optional native directory-lease Node consumer')
    parser.add_argument('--sqlite-amalgamation', type=Path,
                        help="Pinned SQLite amalgamation zip; builds the OH libsqlite3.so the AOT's sqlite3 asset needs")
    parser.add_argument('--sqlite3-package', type=Path, help='With --sqlite-amalgamation: the locked Dart sqlite3 package')
    args = parser.parse_args()
    if (args.sqlite_amalgamation is None) != (args.sqlite3_package is None):
        parser.error('--sqlite-amalgamation and --sqlite3-package go together')
    clang = args.clang.absolute()
    sdk, runtimes, built, source, flock, loader, api, work, output = (path.resolve() for path in
        (args.sdk_native, args.cxx_runtime, args.libnode_output, args.node_source, args.flock_package,
         args.loader_source, args.node_addon_api, args.work, args.output))
    if work.exists() or output.exists():
        parser.error('--work and --output must be fresh')
    work.mkdir(parents=True)
    output.mkdir(parents=True)
    headers, rename = source / 'src', ROOT / 'runtime/ohos/node/napi-rename.h'
    strip = sdk / 'llvm/bin/llvm-strip'
    shutil.copyfile(built / 'libnode.so', output / 'libnode.so')
    subprocess.run([sys.executable, '-B', str(HERE / 'build-flock.py'), '--sdk-native', str(sdk), '--package', str(flock),
                    '--node-headers', str(headers), '--compiler', str(sdk / 'llvm/bin/clang'),
                    '--napi-rename-header', str(rename), '--libnode', str(output / 'libnode.so'),
                    '--output', str(work / 'flock')], check=True)
    subprocess.run([sys.executable, '-B', str(HERE / 'loader/build-loader.py'), '--sdk-native', str(sdk),
                    '--source', str(loader), '--node-headers', str(headers), '--node-addon-api', str(api),
                    '--compiler', str(clang), f'--cxx-flag=-resource-dir={runtimes / "clang-resource"}',
                    f'--cxx-flag=-stdlib++-isystem{runtimes / "include/c++/v1"}', '--cxx-flag=-D__MUSL__=1',
                    f'--ld-flag=-L{runtimes / "lib"}', f'--ld-flag=--ld-path={sdk / "llvm/bin/ld.lld"}',
                    '--napi-rename-header', str(rename), '--libnode', str(output / 'libnode.so'),
                    '--libnode-build-json', str(built / 'build.json'), '--output', str(work / 'loader')], check=True)
    if args.workspace_grants:
        subprocess.run([sys.executable, '-B', str(ROOT / 'runtime/ohos/process/files/build-addon.py'),
                        '--sdk-native', str(sdk), '--compiler', str(clang), '--node-headers', str(headers),
                        '--napi-rename-header', str(rename), '--libnode', str(output / 'libnode.so'),
                        f'--cxx-flag=-resource-dir={runtimes / "clang-resource"}',
                        f'--cxx-flag=-stdlib++-isystem{runtimes / "include/c++/v1"}', '--cxx-flag=-D__MUSL__=1',
                        f'--ld-flag=-L{runtimes / "lib"}', f'--ld-flag=--ld-path={sdk / "llvm/bin/ld.lld"}',
                        '--output', str(work / 'workspace-grants')], check=True)
        shutil.copyfile(work / 'workspace-grants/libdsh_workspace_grants.so', output / 'libdsh_workspace_grants.so')
    subprocess.run(['cmake', '-S', str(ROOT / 'app/ohos/entry/src/main/cpp'), '-B', str(work / 'host'), '-G', 'Ninja',
                    f'-DCMAKE_TOOLCHAIN_FILE={sdk / "build/cmake/ohos.toolchain.cmake"}', '-DOHOS_ARCH=arm64-v8a',
                    '-DCMAKE_BUILD_TYPE=Release', f'-DDSH_NODE_LIBRARY_DIR={output}', f'-DDSH_NODE_HEADERS={headers}',
                    f'-DCMAKE_READELF={sdk / "llvm/bin/llvm-readelf"}'], check=True)
    subprocess.run(['ninja', '-C', str(work / 'host')], check=True)
    prebuilt = 'node_modules/node-addon-require-builtin-openharmony-arm64/prebuilt/openharmony-arm64-napi-v9.node'
    for built_file, name in [(work / 'flock/system.node', 'libdsh_flock.so'),
                             (work / 'loader' / prebuilt, 'libdsh_require_builtin.so'),
                             (work / 'host/libdsh_host.so', 'libdsh_host.so')]:
        shutil.copyfile(built_file, output / name)
        subprocess.run([str(strip), '--strip-unneeded', str(output / name)], check=True)
    if args.tinyemu_source:
        linux = ROOT / 'runtime/ohos/linux/native'
        subprocess.run(['cmake', '-S', str(linux), '-B', str(work / 'linux'), '-G', 'Ninja',
                        f'-DCMAKE_TOOLCHAIN_FILE={sdk / "build/cmake/ohos.toolchain.cmake"}',
                        '-DOHOS_ARCH=arm64-v8a', f'-DDSH_TINYEMU_ARCHIVE={args.tinyemu_source.resolve()}',
                        f'-DDSH_NODE_HEADERS={headers}', f'-DDSH_NODE_LIBRARY={output / "libnode.so"}',
                        f'-DDSH_NODE_RENAME_HEADER={rename}', f'-DDSH_OH_SDK_NATIVE={sdk}'], check=True)
        subprocess.run(['ninja', '-C', str(work / 'linux')], check=True)
        shutil.copyfile(work / 'linux/generated-linux/libdsh_linux.so', output / 'libdsh_linux.so')
        subprocess.run([str(strip), '--strip-unneeded', str(output / 'libdsh_linux.so')], check=True)
    if args.sqlite_amalgamation:
        subprocess.run([sys.executable, '-B', str(HERE / 'build-sqlite.py'), '--sdk-native', str(sdk),
                        '--amalgamation', str(args.sqlite_amalgamation.resolve()),
                        '--sqlite3-package', str(args.sqlite3_package.resolve()), '--output', str(work / 'sqlite')],
                       check=True)
        shutil.copyfile(work / 'sqlite/libsqlite3.so', output / 'libsqlite3.so')
    # Not in the sysroot: the SDK ships it beside its compiler. Only needed if something in the set says so.
    shared = 'libc++_shared.so'
    if any(shared in Elf(path, sdk / 'llvm/bin').needed for path in output.glob('*.so')):
        shutil.copyfile(sdk / 'llvm/lib/aarch64-linux-ohos' / shared, output / shared)
    problems, report = audit(output, sdk)
    (output.parent / 'audit.json').write_text(json.dumps({'problems': problems, **report}, indent=2) + '\n')
    if problems:
        sys.exit('\n'.join(problems))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
