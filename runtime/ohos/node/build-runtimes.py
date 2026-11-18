#!/usr/bin/env python3
"""Build the static LLVM C++ runtimes libnode.so links for aarch64-linux-ohos."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile


LLVM_VERSION = '23.1.1'
LLVM_SOURCE_SHA256 = 'ebe9be46fe8756d58c5b198ffad0fa2a766257add81a4dc52179bfacc7888ee6'
TARGET = 'aarch64-linux-ohos'
TRIPLE = 'aarch64-unknown-linux-ohos'
# The runtimes build reads only these trees; the rest of llvm-project is about 2 GB of tests and tools.
SOURCE_TREES = ('cmake', 'compiler-rt', 'libc', 'libcxx', 'libcxxabi', 'libunwind',
                'llvm/cmake', 'llvm/utils/llvm-lit', 'runtimes', 'third-party')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-native', required=True, type=Path)
    parser.add_argument('--clang', required=True, type=Path,
                        help=f'clang {LLVM_VERSION} on the Linux build host; clang++ must sit beside it')
    parser.add_argument('--source-archive', required=True, type=Path,
                        help=f'Official llvm-project-{LLVM_VERSION}.src.tar.xz')
    parser.add_argument('--work', required=True, type=Path, help='Fresh build directory')
    parser.add_argument('--output', required=True, type=Path, help='Fresh install directory')
    parser.add_argument('--jobs', default=4, type=int)
    args = parser.parse_args()
    clang = args.clang.absolute()
    sdk, archive, work, output = (p.resolve() for p in
        (args.sdk_native, args.source_archive, args.work, args.output))
    if sys.platform != 'linux':
        parser.error('This reproducible recipe currently supports a Linux build host')
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    for file in [clang, clang.with_name('clang++'), sdk / 'sysroot/usr/include/stdio.h',
                 *(sdk / 'llvm/bin' / name for name in ['llvm-ar', 'llvm-nm', 'llvm-ranlib'])]:
        if not file.is_file():
            parser.error(f'Missing input: {file}')
    if work.exists() or output.exists():
        parser.error('--work and --output must be fresh; an interrupted build is kept for diagnosis')
    version = subprocess.check_output([str(clang), '-dumpversion'], text=True).strip()
    if version != LLVM_VERSION:
        parser.error(f'--clang must be clang {LLVM_VERSION}, found {version}')
    if digest(archive) != LLVM_SOURCE_SHA256:
        parser.error(f'Source archive must be official llvm-project-{LLVM_VERSION}.src.tar.xz with the pinned SHA256')
    for command in ['cmake', 'ninja']:
        if shutil.which(command) is None:
            parser.error(f'Missing host build tool: {command}')

    work.mkdir(parents=True)
    root = f'llvm-project-{LLVM_VERSION}.src/'
    prefixes = tuple(root + tree + '/' for tree in SOURCE_TREES)
    with tarfile.open(archive, 'r:xz') as source_tar:
        source_tar.extractall(work, members=(member for member in source_tar if member.name.startswith(prefixes)),
                              filter='data')
    source = work / root
    build = work / 'build'
    flags = f'-fPIC -D__MUSL__=1 -ffile-prefix-map={source}=/{root}'
    tools = sdk / 'llvm/bin'
    configure = ['cmake', '-G', 'Ninja', '-S', str(source / 'runtimes'), '-B', str(build),
        '-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_INSTALL_PREFIX={work / "install"}',
        '-DCMAKE_SYSTEM_NAME=Linux', '-DCMAKE_SYSTEM_PROCESSOR=aarch64',
        f'-DCMAKE_SYSROOT={sdk / "sysroot"}',
        f'-DCMAKE_C_COMPILER={clang}', f'-DCMAKE_CXX_COMPILER={clang.with_name("clang++")}',
        f'-DCMAKE_ASM_COMPILER={clang}', f'-DCMAKE_C_COMPILER_TARGET={TARGET}',
        f'-DCMAKE_CXX_COMPILER_TARGET={TARGET}', f'-DCMAKE_ASM_COMPILER_TARGET={TARGET}',
        f'-DCMAKE_AR={tools / "llvm-ar"}', f'-DCMAKE_NM={tools / "llvm-nm"}',
        f'-DCMAKE_RANLIB={tools / "llvm-ranlib"}',
        f'-DCMAKE_C_FLAGS={flags}', f'-DCMAKE_CXX_FLAGS={flags}', f'-DCMAKE_ASM_FLAGS={flags}',
        # Nothing can link for the target before these libraries exist.
        '-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY',
        '-DLLVM_ENABLE_RUNTIMES=compiler-rt;libunwind;libcxxabi;libcxx',
        '-DLLVM_INCLUDE_TESTS=OFF', '-DLLVM_INCLUDE_DOCS=OFF',
        f'-DLLVM_DEFAULT_TARGET_TRIPLE={TRIPLE}', '-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON',
        '-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON', '-DCOMPILER_RT_BUILD_BUILTINS=ON', '-DCOMPILER_RT_BUILD_CRT=ON',
        *(f'-DCOMPILER_RT_BUILD_{name}=OFF' for name in ['SANITIZERS', 'XRAY', 'LIBFUZZER', 'PROFILE',
                                                         'CTX_PROFILE', 'MEMPROF', 'ORC', 'GWP_ASAN']),
        '-DLIBUNWIND_ENABLE_SHARED=OFF', '-DLIBUNWIND_USE_COMPILER_RT=ON', '-DLIBUNWIND_HIDE_SYMBOLS=ON',
        '-DLIBUNWIND_INCLUDE_TESTS=OFF',
        '-DLIBCXXABI_ENABLE_SHARED=OFF', '-DLIBCXXABI_USE_COMPILER_RT=ON', '-DLIBCXXABI_USE_LLVM_UNWINDER=ON',
        '-DLIBCXXABI_HERMETIC_STATIC_LIBRARY=ON', '-DLIBCXXABI_INCLUDE_TESTS=OFF',
        # The static try-compile cannot tell this is missing from the SDK libc; libc++abi then falls back to a weak reference.
        '-DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF',
        '-DLIBCXX_ENABLE_SHARED=OFF', '-DLIBCXX_USE_COMPILER_RT=ON', '-DLIBCXX_HAS_MUSL_LIBC=ON',
        '-DLIBCXX_CXX_ABI=libcxxabi', '-DLIBCXX_HERMETIC_STATIC_LIBRARY=ON',
        '-DLIBCXX_INCLUDE_TESTS=OFF', '-DLIBCXX_INCLUDE_BENCHMARKS=OFF']
    environment = {**os.environ, 'LC_ALL': 'C', 'TZ': 'UTC', 'SOURCE_DATE_EPOCH': '0'}
    plan = {'llvmVersion': LLVM_VERSION, 'llvmSourceSha256': LLVM_SOURCE_SHA256, 'target': TARGET,
            'configure': configure, 'compilerSha256': digest(clang),
            'compilerVersion': subprocess.check_output([str(clang), '--version'], text=True),
            'sdkManifest': json.loads((sdk / 'oh-uni-package.json').read_text())}
    (work / 'build-plan.json').write_text(json.dumps(plan, indent=2) + '\n')
    with (work / 'configure.log').open('w') as log:
        subprocess.run(configure, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    with (work / 'build.log').open('w') as log:
        subprocess.run(['ninja', '-C', str(build), f'-j{args.jobs}', 'install-compiler-rt', 'install-unwind',
                        'install-cxxabi', 'install-cxx'],
                       env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)

    # The layout the OHOS clang driver searches: resource dir for builtins, -L/-stdlib++-isystem for the rest.
    install = work / 'install'
    resource = output / 'clang-resource'
    target_lib = resource / 'lib' / TARGET
    target_lib.mkdir(parents=True)
    (output / 'lib').mkdir()
    (resource / 'include').symlink_to(Path(subprocess.check_output(
        [str(clang), '-print-resource-dir'], text=True).strip()) / 'include')
    for name in ['libclang_rt.builtins.a', 'clang_rt.crtbegin.o', 'clang_rt.crtend.o']:
        shutil.copyfile(install / 'lib' / TRIPLE / name, target_lib / name)
    for name in ['libc++.a', 'libc++abi.a', 'libunwind.a']:
        shutil.copyfile(install / 'lib' / TRIPLE / name, output / 'lib' / name)
    shutil.copytree(install / 'include/c++/v1', output / 'include/c++/v1')
    shutil.copyfile(install / 'include' / TRIPLE / 'c++/v1/__config_site', output / 'include/c++/v1/__config_site')
    shutil.copyfile(source / 'libcxx/LICENSE.TXT', output / 'LLVM-LICENSE.txt')
    plan['artifacts'] = {str(p.relative_to(output)): {'bytes': p.stat().st_size, 'sha256': digest(p)}
                         for p in [*target_lib.iterdir(), *(output / 'lib').iterdir()]}
    (output / 'runtimes.json').write_text(json.dumps(plan, indent=2) + '\n')
    print(json.dumps({'output': str(output), 'artifacts': plan['artifacts']}, indent=2))


if __name__ == '__main__':
    main()
