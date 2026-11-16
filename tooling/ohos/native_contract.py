#!/usr/bin/env python3
"""Whether the native libraries going into a HAP are as new as the sources around them.

audit-hap compares the HAP with its inputs, and a stale input matches itself. Every name
here is read from the sources on each run, so nothing can go out of date: what the
publication binding registers and the runtime calls has to be in libnode.so, and what the
host registers, exports and declares to ArkTS has to be in libdsh_host.so.
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
BINDING = 'runtime/ohos/host/publication_binding.cc'
HOST = 'app/ohos/entry/src/main/cpp/napi_host.cpp'
DECLARATIONS = 'app/ohos/entry/src/main/cpp/types/libdsh_host/index.d.ts'


def binding_names(source):
    """What Initialize puts on the binding's exports, by literal or through a name array."""
    names = set()
    for target in re.findall(r'napi_set_named_property\(\s*env\s*,\s*exports\s*,\s*([^,]+?)\s*,', source):
        if target.startswith('"'):
            names.add(target.strip('"'))
            continue
        array = re.fullmatch(r'(\w+)\[\w+\]', target)
        values = array and re.search(rf'\b{array.group(1)}\[\]\s*=\s*\{{([^}}]*)\}}', source)
        if not values:
            raise ValueError(f'cannot read a binding name from {target!r} in {BINDING}')
        names.update(re.findall(r'"(\w+)"', values.group(1)))
    if not names:
        raise ValueError(f'found no binding names in {BINDING}')
    return names


def runtime_binding_uses(root):
    """What the runtime's own modules call on that binding."""
    used = {}
    for path in sorted((root / 'runtime/ohos').rglob('*.mjs')):
        if {'node_modules', 'build'} & set(path.relative_to(root).parts):
            continue
        text = path.read_text()
        if "_linkedBinding('dsh_ohos_publication')" not in text:
            continue
        for name in re.findall(r"\bbinding\.(\w+)|_linkedBinding\('dsh_ohos_publication'\)\.(\w+)", text):
            used.setdefault(name[0] or name[1], path.relative_to(root).as_posix())
    return used


def host_methods(source):
    """The module's napi_property_descriptor rows."""
    names = set(re.findall(r'\{"(\w+)",\s*nullptr,\s*\w+,', source))
    if not names:
        raise ValueError(f'found no host methods in {HOST}')
    return names


def host_exports(source):
    """The C entries other libraries look up."""
    names = set(re.findall(r'extern "C" __attribute__\(\(visibility\("default"\)\)\)\s*[\w\s*]*?\b(\w+)\(', source))
    if not names:
        raise ValueError(f'found no C entries in {HOST}')
    return names


def declared_methods(declarations):
    names = set(re.findall(r'^export const (\w+):', declarations, re.M))
    if not names:
        raise ValueError(f'found no declarations in {DECLARATIONS}')
    return names


def has_string(image, name):
    # A NUL ends every C string; the linker may share a tail, so the front stays open.
    return name.encode() + b'\0' in image


def check(libnode, host, exported, root=ROOT):
    """Problems for the libnode.so and libdsh_host.so bytes and the host's dynamic symbols."""
    binding_source = (root / BINDING).read_text()
    host_source = (root / HOST).read_text()
    registered = binding_names(binding_source)
    methods = host_methods(host_source)
    problems = [f'libnode.so has no binding entry {name}: it is older than {BINDING}, rebuild it'
                for name in sorted(registered) if not has_string(libnode, name)]
    problems += [f'{where} calls binding.{name}, which {BINDING} does not register'
                 for name, where in sorted(runtime_binding_uses(root).items()) if name not in registered]
    problems += [f'libdsh_host.so has no method {name}: it is older than {HOST}, rebuild it'
                 for name in sorted(methods) if not has_string(host, name)]
    problems += [f'libdsh_host.so does not export {name}, which {HOST} declares'
                 for name in sorted(host_exports(host_source)) if name not in exported]
    problems += [f'{DECLARATIONS} declares {name}, which {HOST} does not register'
                 for name in sorted(declared_methods((root / DECLARATIONS).read_text())) if name not in methods]
    return problems


def dynamic_symbols(library, nm):
    output = subprocess.check_output([str(nm), '-D', '--defined-only', str(library)], text=True)
    return {line.split()[-1] for line in output.splitlines() if line.strip()}


def check_files(libnode, host, nm, root=ROOT):
    return check(libnode.read_bytes(), host.read_bytes(), dynamic_symbols(host, nm), root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libnode', required=True, type=Path)
    parser.add_argument('--host', required=True, type=Path)
    parser.add_argument('--nm', required=True, type=Path, help='llvm-nm from the SDK')
    args = parser.parse_args()
    problems = check_files(args.libnode, args.host, args.nm)
    for problem in problems:
        print(problem)
    print(f"native-contract: {'OK' if not problems else 'FAILED'}")
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
