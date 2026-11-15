#!/usr/bin/env python3
"""Prepare private OHOS composition inputs from the two existing npm locks.

No hardlink clone or lifecycle scripts. Partial failures are kept for diagnosis.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def prefix_files(prefix):
    rows = []
    paths = [prefix / 'package.json', prefix / 'package-lock.json']
    paths.extend(sorted((prefix / 'node_modules').rglob('*')))
    for path in paths:
        relative = path.relative_to(prefix).as_posix()
        info = path.lstat()
        if stat.S_ISDIR(info.st_mode):
            continue
        if stat.S_ISLNK(info.st_mode):
            if '/.bin/' not in '/' + relative and relative != 'node_modules/@deepseek-ai':
                raise ValueError(f'Unexpected installed symlink: {relative}')
            continue  # development-only links are never payload inputs
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError(f'Prepared input is non-regular or shared by hardlink: {relative}')
        if path.name == '.package-lock.json':
            continue  # npm installation cache is not part of a runtime
        data = path.read_bytes()
        rows.append({'path': relative, 'size': len(data), 'sha256': digest(data)})
    return sorted(rows, key=lambda row: row['path'])


def verify_inputs(receipt_path, config, dsh, process):
    receipt = json.loads(receipt_path.read_text())
    if receipt.get('schema') != 1 or receipt.get('installation') != config['installation']:
        raise ValueError('Input installation recipe differs from composition.json')
    if receipt.get('nodeVersion') != config['nodeVersion']:
        raise ValueError('Input preparation used a different Node version')
    for name, prefix in [('dsh', dsh), ('process', process)]:
        actual = prefix_files(prefix)
        if receipt['files'][name] != actual:
            raise ValueError(f'Prepared {name} input bytes/file set changed after its recipe ran')
    return digest(encoded(receipt))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=['ohos'], required=True)
    parser.add_argument('--node', type=Path, required=True)
    parser.add_argument('--npm', type=Path, required=True)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    config = json.loads(Path(__file__).with_name('composition.json').read_text())
    output = args.out.absolute()
    if output.exists() or output.is_relative_to(repo):
        raise ValueError('Use a new input directory outside the repository')
    output.mkdir(parents=True)
    environment = os.environ.copy()
    environment['PATH'] = str(args.node.resolve().parent) + os.pathsep + environment.get('PATH', '')
    commands = []

    def run(name, command, directory):
        result = subprocess.run(command, cwd=directory, env=environment, capture_output=True, text=True)
        (output / (name + '.stdout')).write_text(result.stdout)
        (output / (name + '.stderr')).write_text(result.stderr)
        commands.append({'argv': list(map(str, command)), 'cwd': str(directory), 'exitCode': result.returncode})
        (output / 'commands.json').write_bytes(encoded(commands))
        if result.returncode:
            raise ValueError(f'{name} failed; original stdout/stderr preserved')
        return result.stdout.strip()

    if run('node-version', [str(args.node), '--version'], output) != 'v' + config['nodeVersion']:
        raise ValueError('Node version differs from the fixed composition recipe')
    if run('npm-version', [str(args.npm), '--version'], output) != config['installation']['npmVersion']:
        raise ValueError('npm version differs from the fixed composition recipe')
    for name, source in [('dsh', repo / ('runtime/locks/dsh-' + config['dshVersion'])),
                         ('process', repo / 'runtime/ohos/process')]:
        prefix = output / name
        prefix.mkdir()
        for filename in ('package.json', 'package-lock.json'):
            shutil.copyfile(source / filename, prefix / filename)
        command = [str(args.npm), *config['installation']['arguments'], '--cache', str(args.cache)]
        if args.offline:
            command.append('--offline')
        run(name + '-npm-ci', command, prefix)
    run('ohos-patches', ['python3', '-I', '-B', str(repo / 'runtime/lib/rtbuild.py'), 'patch-dsh',
        '--prefix', str(output / 'dsh'), '--dsh-version', config['dshVersion'], '--target', 'ohos',
        '--out', str(output / 'patch-results.json'), '--target-report', str(output / 'target-report.json')], repo)
    helper = output / 'dsh/node_modules/@dsh-go/ohos-native'
    helper.mkdir(parents=True)
    for filename in ('index.cjs', 'package.json'):
        shutil.copyfile(repo / 'runtime/ohos/native/hap-loader' / filename, helper / filename)
    shutil.copyfile(repo / 'LICENSE', helper / 'LICENSE')
    receipt = {'schema': 1, 'nodeVersion': config['nodeVersion'], 'installation': config['installation'],
               'files': {name: prefix_files(output / name) for name in ('dsh', 'process')}}
    (output / 'prepared-inputs.json').write_bytes(encoded(receipt))
    print(json.dumps({'status': 'PREPARED', 'receiptSha256': digest(encoded(receipt)),
                      'dshFiles': len(receipt['files']['dsh']), 'processFiles': len(receipt['files']['process'])}))


if __name__ == '__main__':
    main()
