#!/usr/bin/env python3
"""Verify exact Node source patches and unchanged non-OHOS preprocessor branches."""

import argparse
import ast
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', required=True, type=Path, help='Pristine Node 24.22.1 source')
parser.add_argument('--cxx', default='g++')
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('ohos_build', root / 'runtime/ohos/node/build-node.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
pins = json.loads((module.HERE / 'node24-ohos-pins.json').read_text())
subprocess.run([sys.executable, str(module.HERE / 'gen-napi-rename.py'), '--source', str(args.source), '--check'],
               check=True)


def suffix(filename, target, host):
    tree = ast.parse(filename.read_text())
    function = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                    and node.name == 'configure_node')
    branch = next(node for node in ast.walk(function) if isinstance(node, ast.If)
                  and any(isinstance(statement, ast.Assign)
                          and any(isinstance(value, ast.Name) and value.id == 'shlib_suffix'
                                  for value in statement.targets) for statement in node.body))
    code = compile(ast.fix_missing_locations(ast.Module(body=[branch], type_ignores=[])), str(filename), 'exec')
    namespace = {'options': SimpleNamespace(dest_os=target), 'sys': SimpleNamespace(platform=host)}
    exec(code, namespace)
    return namespace['shlib_suffix']


def preprocess(text, flags):
    # Headers stay inert text for this branch comparison, not replaced with fake SDK declarations.
    text = '\n'.join('dsh_include ' + line if line.lstrip().startswith('#include') else line
                      for line in text.splitlines())
    result = subprocess.run([args.cxx, '-E', '-P', '-x', 'c++', '-DV8_ENABLE_WEBASSEMBLY=1', *flags, '-'], input=text,
                            capture_output=True, text=True, check=True)
    return '\n'.join(line.strip() for line in result.stdout.splitlines() if line.strip())


with tempfile.TemporaryDirectory(prefix='ohos-node-source-') as temporary:
    fixture = Path(temporary)
    for name in pins:
        target = fixture / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(args.source / name, target)
    module.apply_patches(fixture)
    results = {'scope': 'Source checks only; target compile and runtime NOT_RUN', 'suffix': [], 'branches': []}
    for target, host in [('linux', 'linux'), ('android', 'linux'), ('darwin', 'darwin'), ('openharmony', 'linux')]:
        before = suffix(args.source / 'configure.py', target, host)
        after = suffix(fixture / 'configure.py', target, host)
        if target != 'openharmony':
            assert before == after
        else:
            assert before == 'so.%s' and after == 'so'
        results['suffix'].append({'target': target, 'host': host, 'before': before, 'after': after})
    for name in ['deps/uv/src/unix/linux.c', 'deps/v8/src/wasm/pgo.h', 'src/node.cc', 'src/node_main_instance.cc']:
        before, after = (args.source / name).read_text(), (fixture / name).read_text()
        for label, flags in [('linux', []), ('android', ['-D__ANDROID_API__=35']),
                             ('ohos-without-embedded-build', ['-D__OHOS__=1'])]:
            assert preprocess(before, flags) == preprocess(after, flags), (name, label)
            results['branches'].append({'file': name, 'platform': label, 'identical': True})
        flags = ['-D__OHOS__=1', '-DDSH_GO_EMBEDDED_RUNTIME=1']
        modified = preprocess(after, flags)
        assert modified != preprocess(before, flags)
        if name.endswith('linux.c'):
            start = modified.index('static int uv__use_io_uring(')
            end = modified.index('\n}', start) + 2
            assert 'return 0;' in modified[start:end] and 'getenv' not in modified[start:end]
    print(json.dumps(results, indent=2))
