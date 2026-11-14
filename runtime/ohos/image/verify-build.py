#!/usr/bin/env python3
"""Read SDK/Node inputs and ELF ownership; never load the target library."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


# Exact headers in the owner-provided SDK 26.0.0.38 small source packages.
# These pins do not certify every file in a separately installed full SDK.
SDK_HEADERS = {
    'multimedia/image_framework/image/image_common.h': '17af7d879f65f4d02354b1f0a456f767f256aeafbc2f336908443fa405245698',
    'multimedia/image_framework/image/image_source_native.h': '9a5ac06dcfc6e6b53cbc5b9e1a80b9551cec2b0dbbcdc865ac17fbf0b0c0289f',
    'multimedia/image_framework/image/image_packer_native.h': 'e253e51a7887f5658a8e34a56ffb209aa7f687cd1f3fadf4a3eb55129aabaddd',
    'multimedia/image_framework/image/pixelmap_native.h': '079e7ac4247d473a0a415b1c06bf14d4b9c0a09664c99ea28633bff20ff3318e',
    'native_color_space_manager/native_color_space_manager.h': '89c5b8bcc8d3d843a6ab0f422edb278382a0168fd7a8de4321231d79a120fea2',
}
ENTRIES = {'napi_register_module_v1', 'node_api_module_get_api_version_v1'}
NODE_SOURCE_SHA256 = '4f5379796280cdaeb0c2f358fd04b6a16cc4fb7dfa83b5a8c91a9d963b435231'
LLVM_VERSION = '23.1.1'
LLVM_SOURCE_SHA256 = 'ebe9be46fe8756d58c5b198ffad0fa2a766257add81a4dc52179bfacc7888ee6'
RUNTIME_ARTIFACTS = {
    'lib/libc++.a', 'lib/libc++abi.a', 'lib/libunwind.a',
    'clang-resource/lib/aarch64-linux-ohos/libclang_rt.builtins.a',
    'clang-resource/lib/aarch64-linux-ohos/clang_rt.crtbegin.o',
    'clang-resource/lib/aarch64-linux-ohos/clang_rt.crtend.o',
}


def identity(path):
    path = Path(path).resolve(strict=True)
    if not path.is_file():
        raise ValueError(f'Not a regular file: {path}')
    return {'path': str(path), 'bytes': path.stat().st_size,
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def elf(readelf, path, soname):
    text = subprocess.check_output([str(readelf), '-h', '-l', '-d', str(path)], text=True)
    if not re.search(r'Class:\s+ELF64\b', text) or not re.search(r'Machine:\s+AArch64\b', text):
        raise ValueError(f'Expected SDK arm64 ELF64: {path}')
    if not re.search(r'Type:\s+DYN\b', text) or re.search(r'^\s*INTERP\s', text, re.M):
        raise ValueError(f'Expected shared object without an interpreter: {path}')
    if not re.search(r'\(SONAME\).*\[' + re.escape(soname) + r'\]', text):
        raise ValueError(f'Expected SONAME {soname}: {path}')
    return text


def exported(readelf, path):
    text = subprocess.check_output([str(readelf), '--dyn-syms', '--wide', str(path)], text=True)
    result = set()
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 8 and fields[0].rstrip(':').isdigit() and fields[6] != 'UND':
            if fields[4] in ('GLOBAL', 'WEAK') and fields[5] in ('DEFAULT', 'PROTECTED'):
                result.add(fields[7].split('@', 1)[0])
    return result


def paired_toolchain(a, sdk):
    """Bind the fixed build-node/build-runtimes records to actual build inputs.

    Their compiler hash is for the underlying Clang executable. Accept its
    clang++ invocation name only when the executable bytes match that hash;
    arbitrary wrappers are not attested by those historical records.
    """
    driver = a.node_cxx_driver.absolute()  # Preserve clang++ argv[0], not the symlink's basename.
    if not re.fullmatch(r'clang\+\+(?:-[0-9.]+)?', driver.name):
        raise ValueError('Use the paired clang++ invocation path, not a compiler wrapper or SDK fallback')
    driver_id = identity(driver)
    node_record_id = identity(a.node_build_json)
    node = json.loads(a.node_build_json.read_text())
    runtime = a.node_cxx_runtime.resolve(strict=True)
    runtime_record_id = identity(runtime / 'runtimes.json')
    rt = json.loads((runtime / 'runtimes.json').read_text())
    library = identity(a.libnode)
    if node.get('nodeSourceSha256') != NODE_SOURCE_SHA256:
        raise ValueError('libnode build.json must bind the pinned Node 24.22.1 source')
    recorded_library = node.get('artifacts', {}).get('libnode.so', {})
    if any(recorded_library.get(k) != library[k] for k in ('bytes', 'sha256')):
        raise ValueError('libnode/build.json do not bind the same actual library bytes')
    for option in ('--dest-os=openharmony', '--dest-cpu=arm64', '--cross-compiling', '--shared'):
        if option not in node.get('configure', []):
            raise ValueError(f'libnode build report lacks {option}')
    if (driver_id['sha256'] != node.get('compilerSha256') or
            driver_id['sha256'] != rt.get('compilerSha256')):
        raise ValueError('The clang++ executable must match the compiler hash in BOTH Node and runtime records')
    if (rt.get('llvmVersion'), rt.get('llvmSourceSha256')) != (LLVM_VERSION, LLVM_SOURCE_SHA256):
        raise ValueError('Requires the fixed LLVM 23.1.1 build-runtimes.py output')
    recorded_runtime = {k: rt.get(k) for k in ('llvmVersion', 'llvmSourceSha256', 'artifacts')}
    if node.get('cxxRuntime') != recorded_runtime:
        raise ValueError('Node cxxRuntime and runtimes.json describe different static runtime inputs')
    if node.get('napiRenameSha256') != identity(a.rename_header)['sha256']:
        raise ValueError('Node build record uses a different full N-API rename header')
    sdk_manifest_id = identity(sdk / 'oh-uni-package.json')
    sdk_manifest = json.loads((sdk / 'oh-uni-package.json').read_text())
    if sdk_manifest.get('version') != '26.0.0.38':
        raise ValueError('The full SDK must declare version 26.0.0.38')
    if (node.get('sdkManifestSha256') != sdk_manifest_id['sha256'] or
            node.get('sdkManifest') != sdk_manifest or rt.get('sdkManifest') != sdk_manifest):
        raise ValueError('Node/runtime records and current SDK manifest do not agree')
    artifact_records = rt.get('artifacts')
    if not isinstance(artifact_records, dict) or set(artifact_records) != RUNTIME_ARTIFACTS:
        raise ValueError('Expected exactly the six static runtime / builtins / CRT artifacts')
    artifacts = []
    for relative in sorted(RUNTIME_ARTIFACTS):
        item = identity(runtime / relative)
        Path(item['path']).relative_to(runtime)
        if any(artifact_records[relative].get(k) != item[k] for k in ('bytes', 'sha256')):
            raise ValueError(f'Static runtime artifact differs from both build records: {relative}')
        artifacts.append(item)
    # The historical records pin the runtime binaries and LLVM source archive,
    # not every installed C++ header. Record the actual configuration headers;
    # do not invent historical header digests or claim complete ABI proof.
    runtime_headers = [identity(runtime / 'include/c++/v1' / name)
                       for name in ('__config', '__config_site', 'version')]
    version = subprocess.check_output([str(driver), '-dumpversion'], text=True).strip()
    if version != LLVM_VERSION:
        raise ValueError(f'The actual paired driver must report {LLVM_VERSION}, found {version}')
    resource = Path(subprocess.check_output([str(driver), '-print-resource-dir'], text=True).strip())
    resource_include = (runtime / 'clang-resource/include').resolve(strict=True)
    if not resource_include.is_dir() or resource_include != (resource / 'include').resolve(strict=True):
        raise ValueError('Runtime compiler-rt include link does not point to the paired driver resource headers')
    linker = sdk / 'llvm/bin/ld.lld'
    linker_id = identity(linker)
    linker_version = subprocess.check_output([str(linker), '--version'], text=True)
    if linker_version != node.get('linkerVersion'):
        raise ValueError('Current SDK linker version differs from the actual libnode build record')
    c_driver = identity(a.sdk_c_compiler)
    Path(c_driver['path']).relative_to((sdk / 'llvm/bin').resolve(strict=True))
    inputs = [node_record_id, runtime_record_id, driver_id, sdk_manifest_id,
              linker_id, c_driver, *artifacts, *runtime_headers]
    pair = {'status': 'EXPLICIT_DRIVER_AND_STATIC_RUNTIME_BOUND_TO_NODE_BUILD',
            'driverInvocationPath': str(driver), 'driverSHA256': driver_id['sha256'],
            'driverVersion': version, 'nodeBuildRecordSHA256': node_record_id['sha256'],
            'runtimeRecordSHA256': runtime_record_id['sha256'],
            'target': 'aarch64-linux-ohos', 'runtimeRoot': str(runtime),
            'runtimeArtifacts': artifacts, 'runtimeConfigurationHeaders': runtime_headers,
            'runtimeCompilerResourceInclude': str(resource_include),
            'headerLimit': 'Current header identities recorded; historical records have no full header inventory',
            'scope': 'Exact recorded compiler/runtime/Node inputs, not full ABI, target-load or device proof'}
    return pair, inputs


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for key in ('sdk-native', 'node-headers', 'rename-header', 'libnode', 'readelf',
                'isolation-verifier', 'image-source', 'pixelmap', 'image-packer', 'color-space',
                'node-build-json', 'node-cxx-driver', 'node-cxx-runtime', 'sdk-c-compiler'):
        p.add_argument('--' + key, required=True, type=Path)
    p.add_argument('--getter-policy', required=True, choices=('0', '1'))
    p.add_argument('--baseline-inputs', type=Path)
    p.add_argument('--consumer', type=Path)
    p.add_argument('--report', required=True, type=Path)
    a = p.parse_args()
    sdk = a.sdk_native.resolve(strict=True)
    sysroot = sdk / 'sysroot'
    readelf = a.readelf.absolute()  # llvm-readelf may link to llvm-readobj, which prints another format.
    readelf.resolve(strict=True).relative_to((sdk / 'llvm/bin').resolve(strict=True))
    inputs = [identity(sdk / 'build/cmake/ohos.toolchain.cmake'), identity(readelf)]
    for name, expected in SDK_HEADERS.items():
        item = identity(sysroot / 'usr/include' / name)
        if item['sha256'] != expected:
            raise ValueError(f'SDK 26.0.0.38 header mismatch: {name}')
        inputs.append(item)
    node_version = a.node_headers / 'node_version.h'
    version = node_version.read_text()
    for key, expected in (('MAJOR', 24), ('MINOR', 22), ('PATCH', 1)):
        found = re.search(r'^#define NODE_' + key + r'_VERSION\s+(\d+)\s*$', version, re.M)
        if not found or int(found.group(1)) != expected:
            raise ValueError('The actual Node headers must be version 24.22.1')
    inputs.extend(identity(x) for x in (node_version, a.node_headers / 'node_api.h',
                                      a.node_headers / 'js_native_api.h', a.node_headers / 'node_api_types.h',
                                      a.node_headers / 'js_native_api_types.h', a.rename_header,
                                      a.isolation_verifier, a.libnode))
    pair, paired_inputs = paired_toolchain(a, sdk)
    inputs.extend(paired_inputs)
    if a.baseline_inputs is not None:
        baseline = json.loads(a.baseline_inputs.read_text())
        # SDK image-library inputs are added below before the final comparison.
    node_dynamic = elf(readelf, a.libnode, 'libnode.so')
    if re.search(r'\((?:RUNPATH|RPATH)\)', node_dynamic):
        raise ValueError('The actual libnode must not have a runtime search path')
    libraries = ((a.image_source, 'libimage_source.so'), (a.pixelmap, 'libpixelmap.so'),
                 (a.image_packer, 'libimage_packer.so'), (a.color_space, 'libnative_color_space_manager.so'))
    for path, name in libraries:
        actual = path.resolve(strict=True)
        actual.relative_to((sysroot / 'usr/lib/aarch64-linux-ohos').resolve(strict=True))
        if path.name != name:
            raise ValueError(f'Expected explicit SDK input named {name}')
        inputs.append(identity(actual))
        elf(readelf, actual, name)
    if a.baseline_inputs is not None and (baseline.get('inputs') != inputs or
                                          baseline.get('toolchainPair') != pair):
        raise ValueError('Selected inputs changed between configure and post-link verification')
    isolation = [sys.executable, '-I', '-B', str(a.isolation_verifier),
                 '--node-headers', str(a.node_headers), '--rename-header', str(a.rename_header),
                 '--libnode', str(a.libnode), '--readelf', str(readelf)]
    consumer = None
    if a.consumer is not None:
        consumer = identity(a.consumer)
        dynamic = elf(readelf, a.consumer, 'libdsh_image_codec.so')
        if re.search(r'\((?:RUNPATH|RPATH)\)', dynamic):
            raise ValueError('The image addon must not have a build/install runtime search path')
        if exported(readelf, a.consumer) != ENTRIES:
            raise ValueError('The image addon must export exactly the two Node addon entry points')
        needed = set(re.findall(r'\(NEEDED\).*\[([^\]]+)\]', dynamic))
        required = {'libnode.so', *(name for _, name in libraries)}
        if not required <= needed:
            raise ValueError('Missing required ELF dependencies: ' + ', '.join(sorted(required - needed)))
        isolation.extend(['--role', 'addon', '--consumer', str(a.consumer)])
    audit = json.loads(subprocess.check_output(isolation, text=True))
    report = {'status': 'ELF_STATIC_CHECKS_PASSED' if consumer else 'BUILD_INPUTS_CHECKED',
              'scope': 'Header/ELF checks only; target loading and device behavior NOT_RUN',
              'nodeVersion': '24.22.1', 'sdkHeaderReference': '26.0.0.38',
              'getterPolicy': 'destroy' if a.getter_policy == '1' else 'borrow',
              'toolchainPair': pair,
              'staticCxxConfigurationMatch': 'Recorded compiler/runtime/Node inputs agree; header and ELF checks are not full ABI proof',
              'inputs': inputs, 'consumer': consumer, 'napiIsolationArgv': isolation,
              'napiIsolation': audit}
    a.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f'image build verification failed: {exc}', file=sys.stderr)
        sys.exit(1)
