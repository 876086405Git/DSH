#!/usr/bin/env python3
"""Recreate the unpruned reference used for O2 size/startup measurements.

Test artifact only: contains desktop/native/wasm inputs and is not a HAP payload.
The source prefix must already have the current OH composition patch applied.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('dsh-prefix', 'process-prefix', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    root = args.out.absolute()
    root.mkdir(parents=True, exist_ok=False)
    out = root / 'prefix'
    out.mkdir()
    for name in ('package.json', 'package-lock.json'):
        shutil.copy2(args.dsh_prefix / name, out / name)
    shutil.copytree(args.dsh_prefix / 'node_modules', out / 'node_modules', symlinks=True)
    subprocess.run(['git', 'apply', '--reverse', str(repo / 'runtime/patches/zzzzzzzzzzzz-ohos-composition.diff')],
                   cwd=out, check=True)
    runtime = out / 'runtime/ohos'
    runtime.mkdir(parents=True)
    for directory in ('net', 'publication', 'capabilities', 'process'):
        source = repo / 'runtime/ohos' / directory
        if not source.exists():
            continue
        (runtime / directory).mkdir()
        for path in source.glob('*.mjs'):
            if not path.name.startswith(('build-', 'link-')):
                shutil.copy2(path, runtime / directory / path.name)
    for name in ('preload.mjs', 'node-version.json'):
        shutil.copy2(repo / 'runtime/ohos' / name, runtime / name)
    process = runtime / 'process'
    shutil.copytree(args.process_prefix / 'node_modules', process / 'node_modules', symlinks=True)
    link = process / 'node_modules/@deepseek-ai'
    if link.is_symlink():
        link.unlink()  # resolve DSH against the copied prefix, never the development tree
    shutil.copy2(args.process_prefix / 'package.json', process / 'package.json')
    filesystem = process / 'filesystem.mjs'
    text = filesystem.read_text()
    old = "from './build/just-bash/index.js'"
    if text.count(old) != 1:
        raise ValueError('Expected the current private filesystem import')
    filesystem.write_text(text.replace(old, "from 'just-bash'"))
    (process / 'build').mkdir()
    shutil.copy2(args.process_prefix / 'build/re2js-unicode.mjs', process / 'build/re2js-unicode.mjs')
    config = root / 'before-builder'
    (config / 'bash-src').mkdir(parents=True)
    shutil.copy2(repo / 'runtime/ohos/process/build-just-bash.py', config / 'build-just-bash.py')
    for name in ('rewrite.py', 'just-bash-3.6.0.json'):
        shutil.copy2(repo / 'runtime/ohos/process/bash-src' / name, config / 'bash-src' / name)
    pins = json.loads((config / 'bash-src/just-bash-3.6.0.json').read_text())
    pins['omitFromPrivateEsm'] = ['browser.js', 'index.cjs']  # exact pre-composition omission list
    (config / 'bash-src/just-bash-3.6.0.json').write_text(json.dumps(pins, indent=2) + '\n')
    command = ['python3', '-I', '-B', str(config / 'build-just-bash.py'),
        '--package', str(args.process_prefix / 'node_modules/just-bash'), '--out', str(process / 'build/just-bash')]
    built = subprocess.run(command, capture_output=True, text=True, check=True)
    shutil.copytree(repo / 'runtime/bridge/dsh-go-bridge', out / 'runtime/bridge/dsh-go-bridge',
                    ignore=shutil.ignore_patterns('node_modules', '.git'))
    for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
        shutil.copy2(repo / name, out / name)
    shutil.copytree(repo / 'runtime/ohos/licenses/texts', runtime / 'licenses/texts')
    shutil.copy2(repo / 'runtime/ohos/licenses/manifest.json', runtime / 'licenses/input-manifest.json')
    (root / 'report.json').write_text(json.dumps({'scope': __doc__, 'prefix': str(out),
        'buildCommand': command, 'build': json.loads(built.stdout)}, indent=2) + '\n')


if __name__ == '__main__':
    main()
