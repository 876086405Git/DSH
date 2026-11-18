#!/usr/bin/env python3
"""Verify the pinned Node API rename header and actual ELF symbol ownership."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


HEADERS = {
    'js_native_api.h': '82d3708ce120f8000ec34d72e1aa70b0d7d8a43027986293681374a71b2cb840',
    'node_api.h': '2d4560831e525b47b060ec8a0864ab73993df9e20215ce9f0fe7b24cd31af32a',
}
ENTRY_POINTS = {'napi_register_module_v1', 'node_api_module_get_api_version_v1'}
C_ABI = {'dsh_node_start', 'dsh_node_stop'}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def verify_header(headers, rename):
    functions = set()
    for name, expected in HEADERS.items():
        path = Path(headers) / name
        if digest(path) != expected:
            raise ValueError(f'Requires the exact Node 24.22.1 header: {name}')
        functions.update(re.findall(r'\bNAPI_CDECL\s+((?:napi_|node_api_)\w+)\s*\(', path.read_text()))
    definitions = dict(re.findall(r'^\s*#\s*define\s+((?:napi_|node_api_)\w+)\s+(\w+)\s*$',
                                  Path(rename).read_text(), re.M))
    missing = sorted(name for name in functions if definitions.get(name) != 'dsh_' + name)
    if missing:
        raise ValueError('Incomplete or incorrect N-API rename header: ' + ', '.join(missing))
    if ENTRY_POINTS.intersection(definitions):
        raise ValueError('Addon dlsym entry points must keep their original names')
    return functions


def symbols(readelf, binary):
    text = subprocess.check_output([str(readelf), '--dyn-syms', '--wide', str(binary)], text=True)
    exports, imports = set(), set()
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 8 or not fields[0].rstrip(':').isdigit():
            continue
        name = fields[7].split('@', 1)[0]
        if fields[6] == 'UND':
            imports.add(name)
        elif fields[4] in ('GLOBAL', 'WEAK') and fields[5] in ('DEFAULT', 'PROTECTED'):
            exports.add(name)
    return exports, imports


def api(name):
    return name.startswith(('napi_', 'node_api_'))


def renamed(name):
    return name.startswith(('dsh_napi_', 'dsh_node_api_'))


def dynamic_info(readelf, binary):
    return subprocess.check_output([str(readelf), '-d', str(binary)], text=True)


def static_cpp_runtime(text):
    needed = re.findall(r'\(NEEDED\).*\[([^\]]+)\]', text)
    if any(name.startswith(('libc++.', 'libc++abi.', 'libc++_shared.', 'libstdc++.')) for name in needed):
        raise ValueError('Node-facing libraries must use the matching static C++ runtime, not a second shared libc++')


def verify_node(exports, imports, functions):
    forbidden = sorted(name for name in exports | imports if api(name) or name.startswith('uv_'))
    if forbidden:
        raise ValueError('libnode still exposes/imports unisolated N-API or bundled libuv: ' + ', '.join(forbidden))
    missing = sorted('dsh_' + name for name in functions if 'dsh_' + name not in exports)
    if missing:
        raise ValueError('libnode lacks renamed API exports: ' + ', '.join(missing))
    if not C_ABI <= exports:
        raise ValueError('libnode must export the C ABI start/stop pair: ' + ', '.join(sorted(C_ABI - exports)))


def verify_consumer(role, exports, imports, node_exports):
    if role == 'ark':
        forbidden = sorted(name for name in exports | imports if renamed(name) or
                           name.startswith(('_ZN4node', '_ZN2v8', '_ZNK4node', '_ZNK2v8')))
        if forbidden or 'napi_module_register' not in imports:
            raise ValueError('Ark module must use only the real Ark N-API: ' + ', '.join(forbidden))
        if not C_ABI <= imports:
            raise ValueError('Ark module must import the C ABI start/stop pair')
        if not C_ABI <= node_exports:
            raise ValueError('The supplied libnode does not provide the Ark module\'s C ABI start/stop pair')
        crossing = sorted((imports & node_exports) - C_ABI)
        if crossing:
            raise ValueError('Ark module may import only the C ABI from libnode: ' + ', '.join(crossing))
        return
    forbidden = sorted(name for name in imports if api(name) or name.startswith('uv_'))
    if forbidden:
        raise ValueError('Node consumer imports unisolated API symbols: ' + ', '.join(forbidden))
    required = {name for name in imports if renamed(name)}
    if not required or not required <= node_exports:
        raise ValueError('Renamed consumer API imports do not resolve in the supplied libnode: ' +
                         ', '.join(sorted(required - node_exports)))
    if role == 'addon' and not ENTRY_POINTS <= exports:
        raise ValueError('Addon must retain both original dlsym entry points')


def verify(headers, rename, libnode, readelf, consumer=None, role=None):
    functions = verify_header(headers, rename)
    exports, imports = symbols(readelf, libnode)
    verify_node(exports, imports, functions)
    node_dynamic = dynamic_info(readelf, libnode)
    static_cpp_runtime(node_dynamic)
    if 'NODELETE' not in node_dynamic:
        raise ValueError('libnode holds the embedded runner and must be linked with -z nodelete')
    report = {'nodeApiVersionSource': 'Node 24.22.1', 'renamedFunctions': len(functions),
              'renameHeaderSHA256': digest(rename), 'libnodeSHA256': digest(libnode),
              'scope': 'header and ELF ownership only; target loading NOT_RUN'}
    if consumer is not None:
        own_exports, own_imports = symbols(readelf, consumer)
        verify_consumer(role, own_exports, own_imports, exports)
        dynamic = dynamic_info(readelf, consumer)
        if role != 'ark':
            static_cpp_runtime(dynamic)
        if role == 'ark' and 'NODELETE' not in dynamic:
            raise ValueError('The embedded host must be linked with -z nodelete')
        if not re.search(r'\(NEEDED\).*\[libnode\.so\]', dynamic):
            raise ValueError('Consumer imports must come from libnode.so, but it is not a dependency')
        report.update({'consumerRole': role, 'consumerSHA256': digest(consumer),
                       'renamedImports': sorted(name for name in own_imports if renamed(name))})
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node-headers', required=True, type=Path)
    parser.add_argument('--rename-header', required=True, type=Path)
    parser.add_argument('--libnode', required=True, type=Path)
    parser.add_argument('--readelf', required=True, type=Path)
    parser.add_argument('--consumer', type=Path)
    parser.add_argument('--role', choices=['addon', 'ark'])
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if bool(args.consumer) != bool(args.role):
        parser.error('--consumer and --role are required together')
    try:
        report = verify(args.node_headers, args.rename_header, args.libnode, args.readelf,
                        args.consumer, args.role)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.error(str(error))
    text = json.dumps(report, indent=2) + '\n'
    if args.report:
        args.report.write_text(text)
    print(text, end='')


if __name__ == '__main__':
    main()
