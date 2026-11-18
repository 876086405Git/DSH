#!/usr/bin/env python3
"""Generate this patch from official source output, preserving previous runtime patches."""
import argparse
import difflib
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
RUNTIME = HERE.parent
NAME = 'provider-discovery-headers.diff'
FILES = {
    'llm-index.js': 'dsh-llm/lib/index.js',
    'llm-types-index.js': 'dsh-llm/lib/types/index.js',
    'llm-index.d.ts': 'dsh-llm/lib/types/index.d.ts',
    'types.d.ts': 'dsh-llm/lib/types/types.d.ts',
    'typert.host.js': 'dsh-llm/lib/typert.host.js',
    'typert.remote-client.js': 'dsh-llm/lib/typert.remote-client.js',
    'typert.remote-client.d.ts': 'dsh-llm/lib/typert.remote-client.d.ts',
    'piai-index.js': 'dsh-llm-pi-ai/lib/index.js',
    'remotes-client.js': 'dsh-api-remotes/lib/client.js',
}


def publish_patch(path, text):
    pending = path.with_name(path.name + '.tmp')
    pending.write_text(text)
    pending.replace(path)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--prefix', type=Path, required=True, help='rc1 prefix with preceding patches, without this patch')
parser.add_argument('--tools', type=Path, required=True, help='parent of source, with pinned generator/build npm dependencies')
parser.add_argument('--node', default='node')
args = parser.parse_args()
spec = importlib.util.spec_from_file_location('rtbuild', RUNTIME / 'lib/rtbuild.py')
rt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rt)
patches = RUNTIME / 'patches'
pins = json.loads((patches / 'pins.json').read_text())
preceding = rt.patch_names(patches)
if NAME in preceding:
    preceding = preceding[:preceding.index(NAME)]

with tempfile.TemporaryDirectory(prefix='dsh-provider-headers-') as directory:
    temp = Path(directory)
    subprocess.run([args.node, str(HERE / 'build.mjs'), str(args.source.resolve()),
                    str(args.prefix.resolve()), str(args.tools.resolve()), str(temp / 'build')], check=True)
    diff = []
    for output, relative in FILES.items():
        relative = 'node_modules/@deepseek-ai/' + relative
        original = (temp / 'build/pristine' / output).read_text()
        candidate = (temp / 'build/candidate' / output).read_text()
        current = (args.prefix / relative).read_text()
        chain = [pins['patches'][name]['0.2.2-rc.1'][relative] for name in preceding
                 if relative in pins['patches'][name].get('0.2.2-rc.1', {})]
        digest = lambda text: hashlib.sha256(text.encode()).hexdigest()
        if chain:
            assert digest(original) == chain[0]['before'], relative + ': upstream output changed'
            assert digest(current) == chain[-1]['after'], relative + ': preceding patches differ'
        else:
            assert original == current, relative + ': upstream output differs'
        delta = ''.join(difflib.unified_diff(original.splitlines(True), candidate.splitlines(True),
                                            'a/' + relative, 'b/' + relative, n=8))
        [(name, hunks)] = rt.parse_unified_diff(delta)
        updated = rt.apply_hunks(current, hunks, name)
        diff.extend(difflib.unified_diff(current.splitlines(True), updated.splitlines(True),
                                         'a/' + relative, 'b/' + relative, n=8))
        baseline = temp / 'prefix' / relative
        baseline.parent.mkdir(parents=True, exist_ok=True)
        baseline.write_text(current)
    record = temp / 'patches'
    record.mkdir()
    (record / NAME).write_text(''.join(diff))
    (record / 'series').write_text(NAME + '\n')
    subprocess.run([sys.executable, '-I', str(RUNTIME / 'lib/rtbuild.py'), 'patch-dsh', '--target', 'android',
                    '--prefix', str(temp / 'prefix'), '--patches', str(record),
                    '--dsh-version', '0.2.2-rc.1', '--record'], check=True)
    publish_patch(patches / NAME, ''.join(diff))
    pins['patches'][NAME] = json.loads((record / 'pins.json').read_text())['patches'][NAME]
    (patches / 'pins.json').write_text(json.dumps(pins, indent=2, sort_keys=True) + '\n')
    series = patches / 'series'
    if NAME not in series.read_text().splitlines():
        series.write_text(series.read_text() + NAME + '\n')
