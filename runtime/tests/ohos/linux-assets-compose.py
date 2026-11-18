#!/usr/bin/env python3
"""Run the actual composer with real prepared inputs and the Linux assets option.

The baseline is an earlier no-assets composition from the same sources/inputs.
No receipts, npm installs, images or SDK results are synthesized by this test.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time
import zipfile

ROOT = Path(__file__).resolve().parents[3]


def encoded(value):
    return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('prepared', 'regex-artifact', 'esbuild-prefix', 'assets', 'baseline', 'node', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    args.out = args.out.absolute()
    args.out.mkdir(parents=True, exist_ok=False)
    baseline = json.loads((args.baseline / 'composition-report.json').read_text())
    baseline_files = json.loads((args.baseline / 'payload-files.json').read_text())
    assert 'linuxAssets' not in baseline
    spec = importlib.util.spec_from_file_location('linux_assets', ROOT / 'runtime/ohos/package/linux-assets.py')
    assets = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(assets)
    expected = assets.verify_assets(args.assets)
    commands = []
    identity = {'scope': 'real compiler-independent composition and archive tests; no guest/SDK/HAP/device build',
                'sourceSha256': {name: sha(ROOT / name) for name in [
                    'runtime/ohos/package/compose-runtime.py', 'runtime/ohos/package/linux-assets.py',
                    'runtime/ohos/package/prepare-inputs.py', 'runtime/tests/ohos/linux-assets-compose.py']},
                'preparedInputsSha256': sha(args.prepared / 'prepared-inputs.json'),
                'inputAssets': expected, 'baselineRuntimeVersion': baseline['runtimeVersion']}
    (args.out / 'INPUTS.json').write_bytes(encoded(identity))

    def run(label, directory, receipt):
        output = args.out / label
        argv = [sys.executable, '-I', '-B', str(ROOT / 'runtime/ohos/package/compose-runtime.py'),
                '--target', 'ohos', '--dsh-prefix', str(args.prepared / 'dsh'),
                '--process-prefix', str(args.prepared / 'process'),
                '--target-report', str(args.prepared / 'target-report.json'),
                '--prepared-inputs', str(receipt), '--regex-artifact', str(args.regex_artifact),
                '--esbuild-prefix', str(args.esbuild_prefix), '--imports-report', str(args.out / (label + '-imports.json')),
                '--node', str(args.node), '--runtime-core', str(ROOT / 'app/ohos/entry/src/main/ets/runtime/RuntimeCore.ets'),
                '--linux-assets', str(directory), '--out', str(output)]
        record = {'argv': argv, 'cwd': str(ROOT), 'started': time.time()}
        commands.append(record)
        (args.out / 'commands.json').write_bytes(encoded(commands))
        with (args.out / (label + '.stdout')).open('wb') as stdout, (args.out / (label + '.stderr')).open('wb') as stderr:
            result = subprocess.run(argv, cwd=ROOT, stdout=stdout, stderr=stderr, timeout=360)
        record.update(exitCode=result.returncode, ended=time.time(), outputExists=output.exists())
        (args.out / 'commands.json').write_bytes(encoded(commands))
        return result.returncode, output

    receipt = args.prepared / 'prepared-inputs.json'
    code, output = run('with-assets', args.assets, receipt)
    assert code == 0, (args.out / 'with-assets.stderr').read_text()
    report = json.loads((output / 'composition-report.json').read_text())
    assert report['linuxAssets'] == expected
    assert report['preparedInputsSha256'] == baseline['preparedInputsSha256'] == identity['preparedInputsSha256']
    assert report['nativeLibraries']['linux'] == 'libdsh_linux.so'
    assert report['runtimeVersion'] != baseline['runtimeVersion']
    prefix = assets.DIRECTORY + '/'
    rows = json.loads((output / 'payload-files.json').read_text())
    assert [row for row in rows if not row['path'].startswith(prefix)] == baseline_files
    selected = [row for row in rows if row['path'].startswith(prefix)]
    assert selected == [{'path': prefix + row['path'], 'size': row['size'], 'sha256': row['sha256']}
                        for row in expected['files']]
    inputs = json.loads((output / 'input-files.json').read_text())
    assert len([row for row in inputs if row['source'] == 'linux-assets' and row['decision'] == 'include']) == 6
    inner = output / 'rawfile/dsh-runtime/runtime.zip'
    with zipfile.ZipFile(inner) as bundle:
        assert assets.verify_runtime_archive(bundle, {'libdsh_linux.so'}) == expected
        for name in assets.NAMES:
            assert hashlib.sha256(bundle.read('files/' + prefix + name)).hexdigest() == sha(args.assets / name)

    # A changed trusted-input receipt must still fail even when assets are valid.
    changed = json.loads(receipt.read_text())
    changed['files']['dsh'][0]['sha256'] = '0' * 64
    bad_receipt = args.out / 'changed-prepared-inputs.json'
    bad_receipt.write_bytes(encoded(changed))
    code, failed = run('changed-receipt', args.assets, bad_receipt)
    assert code != 0 and not failed.exists()
    assert 'changed after its recipe ran' in (args.out / 'changed-receipt.stderr').read_text()

    # A well-formed runtime composition must not publish a partial/redirected asset input.
    bad_assets = args.out / 'changed-assets'
    shutil.copytree(args.assets, bad_assets)
    changed = json.loads((bad_assets / 'install-manifest.json').read_text())
    changed['bios']['path'] = '../bbl64.bin'
    (bad_assets / 'install-manifest.json').write_bytes(encoded(changed))
    code, failed = run('changed-assets-refused', bad_assets, receipt)
    assert code != 0 and not failed.exists()
    assert 'fixed asset and fields' in (args.out / 'changed-assets-refused.stderr').read_text()
    assert not list(args.out.glob('.ohos-compose-*'))
    assert sha(receipt) == identity['preparedInputsSha256']
    assert assets.verify_assets(args.assets) == expected
    result = {'status': 'PASS', 'checks': ['six actual input files copied into ZIP',
              'six input and payload identity rows', 'unchanged non-Linux payload',
              'runtimeVersion changed with assets', 'original prepared receipt retained',
              'changed receipt rejected without output', 'unsafe assets rejected without output',
              'no leftover publication staging', 'input bytes preserved'],
              'runtimeVersion': report['runtimeVersion'], 'archiveSha256': report['archiveSha256'],
              'scope': identity['scope']}
    (args.out / 'RESULT.json').write_bytes(encoded(result))
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
