#!/usr/bin/env python3
"""非官方，只为检查调用方逻辑。Prepare a private SDK; never edit the input SDK."""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile

sdk, work, stubs = (Path(value).resolve() for value in sys.argv[1:])
fingerprint = hashlib.sha256(str(sdk).encode())
fingerprint.update(Path(__file__).read_bytes())
def files(directory, ancestors=()):
    resolved = directory.resolve(strict=True)
    if resolved in ancestors:
        raise RuntimeError(f'Cyclic SDK directory: {directory}')
    for entry in sorted(directory.iterdir()):
        if entry.is_dir():
            yield from files(entry, (*ancestors, resolved))
        elif entry.is_file():
            yield entry
        else:
            raise RuntimeError(f'Invalid SDK entry: {entry}')

public_files = {}
for source in files(sdk / 'ets'):
    relative = source.relative_to(sdk / 'ets').as_posix()
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    public_files[relative] = digest
    fingerprint.update(relative.encode())
    fingerprint.update(bytes.fromhex(digest))
sdk_digest = fingerprint.hexdigest()
inputs = []
for directory, destination in (('api', 'api'), ('kits', 'kits'),
                               ('kit_configs', 'build-tools/ets-loader/kit_configs')):
    entries = sorted((stubs / directory).iterdir())
    if not entries:
        raise RuntimeError(f'Missing HMS declarations: {stubs / directory}')
    for entry in entries:
        if not entry.is_file() or entry.is_symlink():
            raise RuntimeError(f'Invalid HMS declaration: {entry}')
        relative = Path(destination) / entry.name
        if (sdk / 'ets' / relative).exists():
            raise RuntimeError(f'Refusing to replace an SDK declaration: {relative}')
        digest = hashlib.sha256(entry.read_bytes()).hexdigest()
        fingerprint.update(str(entry.relative_to(stubs)).encode())
        fingerprint.update(bytes.fromhex(digest))
        inputs.append((entry, relative, digest))
key = fingerprint.hexdigest()
target = work / ('sdk-hms-' + key[:20])
marker = target / 'prepared.json'
if not target.exists():
    temporary = Path(tempfile.mkdtemp(prefix='sdk-hms-preparing-', dir=work))
    version = temporary / '26.0.0'
    version.mkdir()
    # Copy tools, not symlinks to their directories: the kit resolver uses its
    # own real __dirname. Keep this prepared tree across repeated builds.
    shutil.copytree(sdk / 'ets', version / 'ets', symlinks=False)
    for part in ('js', 'native', 'toolchains'):
        (version / part).symlink_to(sdk / part, target_is_directory=True)
    for entry, relative, digest in inputs:
        shutil.copyfile(entry, version / 'ets' / relative)
    previewer = version / 'previewer'
    previewer.mkdir()
    description = (sdk / 'ets/oh-uni-package.json').read_text()
    (previewer / 'oh-uni-package.json').write_text(
        description.replace('"Ets"', '"Previewer"').replace('"path": "ets"', '"path": "previewer"'))
    (temporary / 'prepared.json').write_text(json.dumps({'key': key, 'sdk_digest': sdk_digest}) + '\n')
    temporary.rename(target)
if json.loads(marker.read_text())['key'] != key:
    raise RuntimeError(f'Incomplete private SDK: {target}')
private_ets = target / '26.0.0/ets'
# All copied public declarations/tools are part of this identity, not just stubs.
expected = dict(public_files)
expected.update({relative.as_posix(): digest for entry, relative, digest in inputs})
actual = {}
for source in files(private_ets):
    if source.is_symlink() or any(parent.is_symlink() for parent in source.parents
                                  if parent.is_relative_to(private_ets)):
        raise RuntimeError(f'Private SDK must not contain links: {source}')
    actual[source.relative_to(private_ets).as_posix()] = hashlib.sha256(source.read_bytes()).hexdigest()
if actual != expected:
    raise RuntimeError(f'Private SDK content changed: {target}')
(work / 'hms-stubs.json').write_text(json.dumps({
    'status': 'UNCOMPILED_HMS',
    'notice': '非官方，只为检查调用方逻辑；不证明 HMS SDK 类型、链接或真机可用性',
    'sdk_digest': sdk_digest, 'private_sdk': str(target),
    'files': {str(entry.relative_to(stubs)): digest for entry, relative, digest in inputs},
}, ensure_ascii=False, indent=2) + '\n')
print(target)
