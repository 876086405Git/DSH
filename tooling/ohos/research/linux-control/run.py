#!/usr/bin/env python3
"""Narrow real-guest control test. Does not build HAP or run the unified gate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--node', required=True)
parser.add_argument('--dsh-prefix', type=Path, required=True)
parser.add_argument('--native-library-dir', type=Path, required=True)
parser.add_argument('--publication-fixture', type=Path, required=True)
parser.add_argument('--assets', type=Path, required=True)
parser.add_argument('--archive', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


assets = args.assets.resolve()
manifest = json.loads((assets / 'install-manifest.json').read_text())
names = {'bios': 'bbl64.bin', 'kernel': 'kernel-riscv64.bin', 'tools': 'tools.block',
         'bootstrap': 'bootstrap.ext4.gz', 'empty': 'empty.ext4.gz'}
assert {p.name for p in assets.iterdir()} == {'install-manifest.json', *names.values()}
for key, name in names.items():
    entry = manifest[key]
    assert entry['path'] == name and not (assets / name).is_symlink()
    assert (assets / name).stat().st_size == entry['bytes'] and sha(assets / name) == entry['sha256']
archive = args.archive.resolve()
assert archive.stat().st_size == manifest['archive']['bytes'] and sha(archive) == manifest['archive']['sha256']
source = output / 'source/runtime/ohos/linux'
source.mkdir(parents=True)
for module in sorted((ROOT / 'runtime/ohos/linux').glob('*.mjs')):
    shutil.copy2(module, source / module.name)
shutil.copytree(ROOT / 'runtime/ohos/net', output / 'source/runtime/ohos/net')
shutil.copytree(assets, source / 'assets')
# Host-side fixture preparation only. No symlink operation is enabled in the
# constrained child, and the locked dependency prefix is never modified.
(output / 'node_modules').symlink_to(args.dsh_prefix.resolve() / 'node_modules', target_is_directory=True)
shutil.copy2(HERE / 'guest-control.mjs', output / 'guest-control.mjs')
auth_path = args.dsh_prefix.resolve() / 'node_modules/@deepseek-ai/dsh-client-connection/lib/index.js'
auth_source = auth_path.read_text()
(output / 'actual-browser-auth.mjs').write_text(auth_source + '\nexport { BrowserAuth };\n')
native = args.native_library_dir.resolve() / 'libdsh_linux.so'
inputs = {
    'source': {str(p.relative_to(output / 'source')): sha(p) for p in (output / 'source').rglob('*') if p.is_file()},
    'nativeLibrarySha256': sha(native), 'publicationFixtureSha256': sha(args.publication_fixture), 'archiveSha256': sha(archive),
    'manifestSha256': sha(assets / 'install-manifest.json'),
    'dependencyLockSha256': sha(args.dsh_prefix / 'package-lock.json'),
    'actualBrowserAuthSha256': sha(auth_path),
    'collectorSha256': sha(args.dsh_prefix / 'node_modules/@deepseek-ai/dsh-subprocess-local/lib/output.js'),
    'driverSha256': sha(HERE / 'guest-control.mjs'),
    'scope': 'Real LinuxControl HTTP/BrowserAuth + owner/backend + native TinyEMU guest. Only download fetch streams a verified local archive; no Huawei network, HAP or phone assertion.',
}
(output / 'INPUTS.json').write_text(json.dumps(inputs, ensure_ascii=False, indent=2) + '\n')
argv = [args.node, '--jitless', '--import', str(ROOT / 'runtime/ohos/sim/preload.mjs'),
        str(output / 'guest-control.mjs'), str(args.native_library_dir.resolve()),
        str(source / 'assets'), str(archive), str(output / 'private-linux'), str(output / 'RESULT.json')]
env = {key: value for key, value in os.environ.items()
       if key not in {'NODE_OPTIONS', 'NODE_PATH', 'LD_PRELOAD'} and not key.startswith('DSH_GO_OHOS_')}
env.update(LD_PRELOAD=str(args.publication_fixture.resolve()), DSH_GO_OHOS_SIM_PLATFORM='openharmony', DSH_GO_OHOS_SIM_ADDONS=json.dumps([str(native)]))
started = time.monotonic()
with (output / 'guest.stdout').open('wb') as stdout, (output / 'guest.stderr').open('wb') as stderr:
    result = subprocess.run(argv, env=env, stdout=stdout, stderr=stderr, timeout=360)
record = {'argv': argv, 'exitCode': result.returncode, 'seconds': time.monotonic() - started,
          'environment': {key: env[key] for key in ['LD_PRELOAD', 'DSH_GO_OHOS_SIM_PLATFORM', 'DSH_GO_OHOS_SIM_ADDONS']}}
(output / 'COMMAND.json').write_text(json.dumps(record, indent=2) + '\n')
assert inputs['source'] == {str(p.relative_to(output / 'source')): sha(p)
                            for p in (output / 'source').rglob('*') if p.is_file()}, 'frozen runtime inputs changed'
assert result.returncode == 0, (result.returncode, str(output / 'guest.stderr'))
summary = json.loads((output / 'RESULT.json').read_text())
assert summary['passed'] and summary['shutdown']['shutdownComplete']
print(json.dumps({'passed': True, 'checks': len(summary['checks']), 'seconds': record['seconds'], 'result': str(output / 'RESULT.json')}), flush=True)
