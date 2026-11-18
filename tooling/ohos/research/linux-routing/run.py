#!/usr/bin/env python3
"""Agent shell commands routed into a real guest. Does not build HAP or run the unified gate."""
import argparse
import hashlib
import json
from pathlib import Path
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
    assert manifest[key]['path'] == name and (assets / name).stat().st_size == manifest[key]['bytes']
    assert sha(assets / name) == manifest[key]['sha256']
archive = args.archive.resolve()
assert archive.stat().st_size == manifest['archive']['bytes'] and sha(archive) == manifest['archive']['sha256']
native = args.native_library_dir.resolve() / 'libdsh_linux.so'
# The driver imports the runtime in place: process modules need their composed
# node_modules and the built just-bash, exactly as the router tests do.
sources = sorted([*(ROOT / 'runtime/ohos/linux').glob('*.mjs'), *(ROOT / 'runtime/ohos/process').glob('*.mjs'),
                  ROOT / 'runtime/ohos/linux/guest-agent.py', ROOT / 'runtime/ohos/process/build/just-bash/index.js',
                  HERE / 'guest-routing.mjs'])
identity = lambda: {str(p.relative_to(ROOT)): sha(p) for p in sources}
inputs = {'source': identity(), 'nativeLibrarySha256': sha(native), 'publicationFixtureSha256': sha(args.publication_fixture),
          'archiveSha256': sha(archive), 'manifestSha256': sha(assets / 'install-manifest.json'),
          'toolsSha256': manifest['tools']['sha256'], 'dependencyLockSha256': sha(args.dsh_prefix / 'package-lock.json'),
          'scope': 'Production router/virtual shell/Linux command backend, LinuxControl/owner/backend and native TinyEMU guest with 9P exports. Only the pinned archive download is a local file. No HAP, phone or Huawei network.'}
(output / 'INPUTS.json').write_text(json.dumps(inputs, ensure_ascii=False, indent=2) + '\n')
home, temporary = output / 'child-home', output / 'child-tmp'
for directory in [home, temporary]:
    directory.mkdir(mode=0o700)
argv = [args.node, '--jitless', '--import', str(ROOT / 'runtime/ohos/sim/preload.mjs'),
        '--import', str(ROOT / 'runtime/ohos/process/node-worker-preload.mjs'), str(HERE / 'guest-routing.mjs'),
        str(args.native_library_dir.resolve()), str(assets), str(archive), str(output / 'private-linux'),
        str(output / 'workspace'), str(output / 'RESULT.json')]
# An explicit, non-secret environment: guest jobs inherit no coordinator proxy or token.
env = {'PATH': str(Path(args.node).resolve().parent) + ':/usr/bin:/bin', 'HOME': str(home), 'TMPDIR': str(temporary),
       'LANG': 'C.UTF-8', 'LD_PRELOAD': str(args.publication_fixture.resolve()), 'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony',
       'DSH_GO_OHOS_SIM_ADDONS': json.dumps([str(native)])}
started = time.monotonic()
with (output / 'guest.stdout').open('wb') as stdout, (output / 'guest.stderr').open('wb') as stderr:
    result = subprocess.run(argv, env=env, cwd=ROOT, stdout=stdout, stderr=stderr, timeout=870)
record = {'argv': argv, 'environment': env, 'exitCode': result.returncode, 'seconds': time.monotonic() - started}
(output / 'COMMAND.json').write_text(json.dumps(record, indent=2) + '\n')
assert identity() == inputs['source'], 'runtime inputs changed during the run'
assert result.returncode == 0, (result.returncode, str(output / 'guest.stderr'))
summary = json.loads((output / 'RESULT.json').read_text())
assert summary['passed'] and summary['shutdown']['shutdownComplete']
print(json.dumps({'passed': True, 'checks': len(summary['checks']), 'timings': summary['timings'], 'result': str(output / 'RESULT.json')}), flush=True)
