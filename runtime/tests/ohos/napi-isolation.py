#!/usr/bin/env python3
"""Linux symbol-routing probe: two original-name decoys and one renamed Node substitute."""
import argparse
import ctypes
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'runtime/ohos/host'))
import napi_isolation as isolation

DSO = r'''
#include <node_api.h>
static int count = 0;
extern "C" napi_status napi_create_function(napi_env, const char*, size_t,
    napi_callback, void*, napi_value*) { ++count; return napi_ok; }
extern "C" int probe_count() { return count; }
'''
ADDON = r'''
#include <node_api.h>
extern "C" int probe_call() {
  return napi_create_function(nullptr, "probe", 5, nullptr, nullptr, nullptr);
}
napi_value Initialize(napi_env, napi_value exports) { return exports; }
NAPI_MODULE(probe, Initialize)
'''


def child(directory, order, variant):
    root = Path(directory)
    loaded = {}
    for name in [*order.split(','), 'node']:
        loaded[name] = ctypes.CDLL(str(root / (name + '.so')), mode=ctypes.RTLD_GLOBAL)
    addon = ctypes.CDLL(str(root / (variant + '.node')))
    assert addon.probe_call() == 0
    counts = {name: library.probe_count() for name, library in loaded.items()}
    expected = 'node' if variant == 'renamed' else order.split(',')[0]
    assert counts == {name: int(name == expected) for name in loaded}, counts
    print(json.dumps({'variant': variant, 'order': order, 'counts': counts}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node-headers', required=True, type=Path)
    parser.add_argument('--node-executable', required=True, type=Path)
    parser.add_argument('--compiler', default='clang++')
    parser.add_argument('--readelf', default='readelf')
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    headers, out = args.node_headers.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    names = set()
    for name in isolation.HEADERS:
        names.update(re.findall(r'\bNAPI_CDECL\s+((?:napi_|node_api_)\w+)\s*\(', (headers / name).read_text()))
    rename = ROOT / 'runtime/ohos/node/napi-rename.h'
    assert isolation.verify_header(headers, rename) == names
    (out / 'dso.cc').write_text(DSO)
    (out / 'addon.cc').write_text(ADDON)
    rows = []
    for name, source, renamed in [('ark_a', 'dso.cc', False), ('ark_b', 'dso.cc', False),
                                  ('node', 'dso.cc', True), ('renamed', 'addon.cc', True),
                                  ('unrenamed', 'addon.cc', False)]:
        binary = out / (name + ('.node' if source == 'addon.cc' else '.so'))
        command = [args.compiler, '-shared', '-fPIC', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                   '-DNAPI_VERSION=8', '-I', str(headers)]
        if renamed:
            command += ['-include', str(rename)]
        command += [str(out / source), '-o', str(binary)]
        result = subprocess.run(command, text=True, capture_output=True)
        rows.append({'kind': 'build', 'command': command, 'code': result.returncode,
                     'stdout': result.stdout, 'stderr': result.stderr})
        result.check_returncode()
    for order in ['ark_a,ark_b', 'ark_b,ark_a']:
        for variant in ['renamed', 'unrenamed']:
            command = [sys.executable, str(Path(__file__).resolve()), '--child', str(out), order, variant]
            result = subprocess.run(command, text=True, capture_output=True, timeout=10)
            rows.append({'kind': 'routing', 'command': command, 'code': result.returncode,
                         'stdout': result.stdout, 'stderr': result.stderr})
            result.check_returncode()
    exports, imports = isolation.symbols(args.readelf, out / 'node.so')
    own_exports, own_imports = isolation.symbols(args.readelf, out / 'renamed.node')
    isolation.verify_consumer('addon', own_exports, own_imports, exports)
    assert 'dsh_napi_create_function' in own_imports and 'napi_create_function' not in own_imports
    assert isolation.ENTRY_POINTS <= own_exports
    for name in ['ark_a.so', 'ark_b.so', 'node.so', 'renamed.node', 'unrenamed.node']:
        text = subprocess.check_output([args.readelf, '--dyn-syms', '--wide', str(out / name)], text=True)
        (out / (name + '.symbols.txt')).write_text(text)

    def rejected(label, fn):
        try:
            fn()
        except ValueError as error:
            rows.append({'kind': 'gate', 'case': label, 'code': 0, 'rejection': str(error)})
        else:
            raise AssertionError('Gate unexpectedly accepted: ' + label)

    incomplete = out / 'incomplete.h'
    incomplete.write_text(rename.read_text().replace('#define napi_create_function dsh_napi_create_function\n', ''))
    rejected('missing-api-mapping', lambda: isolation.verify_header(headers, incomplete))
    wrong_entry = out / 'wrong-entry.h'
    wrong_entry.write_text(rename.read_text() + '#define napi_register_module_v1 dsh_napi_register_module_v1\n')
    rejected('renamed-addon-entry', lambda: isolation.verify_header(headers, wrong_entry))
    original_exports, original_imports = isolation.symbols(args.readelf, args.node_executable)
    rejected('actual-unrenamed-Node-24.22.1', lambda: isolation.verify_node(original_exports, original_imports, names))
    rejected('actual-shared-C++-runtime', lambda: isolation.static_cpp_runtime(
        isolation.dynamic_info(args.readelf, args.node_executable)))
    bad_exports, bad_imports = isolation.symbols(args.readelf, out / 'unrenamed.node')
    rejected('actual-unrenamed-addon', lambda: isolation.verify_consumer('addon', bad_exports, bad_imports, exports))
    rejected('renamed-API-in-Ark', lambda: isolation.verify_consumer('ark', set(),
        {'napi_module_register', 'dsh_node_start', 'dsh_node_stop', 'dsh_napi_create_function'}, exports))
    start_stop = {'napi_module_register', 'dsh_node_start', 'dsh_node_stop'}
    rejected('start-stop-absent-from-libnode', lambda: isolation.verify_consumer('ark', set(), start_stop, exports))
    rejected('start-stop-not-imported-by-Ark', lambda: isolation.verify_consumer('ark', set(),
        {'napi_module_register'}, exports | isolation.C_ABI))
    rejected('other-libnode-import-in-Ark', lambda: isolation.verify_consumer('ark', set(),
        start_stop | {'dsh_private'}, exports | isolation.C_ABI | {'dsh_private'}))
    isolation.verify_consumer('ark', set(), start_stop, exports | isolation.C_ABI)
    inputs = [ROOT / 'runtime/ohos/host/napi_isolation.py', Path(__file__).resolve(),
              headers / 'node_api.h', headers / 'js_native_api.h', args.node_executable]
    report = {'scope': 'Linux ELF symbol routing with explicit fake APIs; no Ark or actual renamed Node execution',
              'functionsMapped': len(names), 'inputs': {str(p): isolation.digest(p) for p in inputs},
              'rows': rows}
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'out': str(out), 'routingCases': 4, 'gateRejections': sum(row['kind'] == 'gate' for row in rows),
                      'functionsMapped': len(names)}))


if __name__ == '__main__':
    if len(sys.argv) == 5 and sys.argv[1] == '--child':
        child(*sys.argv[2:])
    else:
        main()
