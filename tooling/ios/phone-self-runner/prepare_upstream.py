#!/usr/bin/env python3
"""Prepare verified idevice source plus the local RSD-only XCTest entry point."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

HERE = Path(__file__).resolve().parent


def digest(data):
    return hashlib.sha256(data).hexdigest()


def inventory(root):
    paths = sorted(root.rglob('*'))
    if any(path.is_symlink() for path in paths):
        raise ValueError('Prepared upstream contains an unexpected symlink')
    return {path.relative_to(root).as_posix(): digest(path.read_bytes())
            for path in paths if path.is_file() and path != root / '.dsh-source.json'}


def existing_output_error(reason, output, identity, patch, archive):
    command = [sys.executable, str(HERE / 'prepare_upstream.py')]
    if archive:
        command.extend(['--archive', str(Path(archive).absolute())])
    return ValueError(
        reason + '\nExisting output was left unchanged: ' + str(output)
        + '\nCheck source-pins.json and ' + patch.name + ' against this checkout. Expected identity: '
        + json.dumps(identity, sort_keys=True)
        + '\nPreserve and inspect the old .upstream entry, then explicitly move it to a chosen backup '
          'outside .upstream before rebuilding. No directory is removed or rebuilt automatically.'
        + '\nAfter moving it aside, rerun: ' + shlex.join(command)
        + '\nThe archive checksum, patch applicability and prepared-file checks still apply.')


def prepare(archive=None):
    pins = json.loads((HERE / 'source-pins.json').read_text())
    patch = HERE / pins['patch']
    identity = {'commit': pins['commit'], 'archiveSha256': pins['archiveSha256'],
                'patchSha256': digest(patch.read_bytes())}
    output = HERE / '.upstream'
    if output.exists() or output.is_symlink():
        if output.is_symlink():
            raise existing_output_error('Refusing a symlinked upstream output', output, identity, patch, archive)
        try:
            report = json.loads((output / '.dsh-source.json').read_text())
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise existing_output_error('Prepared upstream metadata is missing or invalid',
                                        output, identity, patch, archive) from error
        if not isinstance(report, dict) or report.get('identity') != identity:
            raise existing_output_error('Prepared upstream identity differs', output, identity, patch, archive)
        try:
            files = inventory(output)
        except (OSError, ValueError) as error:
            raise existing_output_error('Prepared upstream file inventory could not be verified',
                                        output, identity, patch, archive) from error
        if report.get('files') != files:
            raise existing_output_error('Prepared upstream differs', output, identity, patch, archive)
        return output
    if archive:
        data = Path(archive).read_bytes()
    else:
        with urllib.request.urlopen(pins['archive'], timeout=120) as response:
            data = response.read(16 * 1024 * 1024 + 1)
    if digest(data) != pins['archiveSha256']:
        raise ValueError('idevice archive SHA256 differs from the fixed source pin')
    prefix = 'idevice-' + pins['commit']
    with tempfile.TemporaryDirectory(prefix='dsh-phone-upstream-') as temporary:
        temporary = Path(temporary)
        packed = temporary / 'source.tar.gz'
        packed.write_bytes(data)
        with tarfile.open(packed, 'r:gz') as source:
            members = source.getmembers()
            if len(members) > 10000 or sum(m.size for m in members) > 64 * 1024 * 1024:
                raise ValueError('Unexpected source archive size')
            for member in members:
                path = PurePosixPath(member.name)
                if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != prefix:
                    raise ValueError('Unsafe source archive path')
                readme_link = member.issym() and member.name == prefix + '/idevice/README.md' and member.linkname == '../README.md'
                if not (member.isdir() or member.isfile() or readme_link):
                    raise ValueError('Unexpected non-regular source archive entry')
            for member in members:
                target = temporary / member.name
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    # Materialize the one pinned README symlink as a regular file;
                    # no archive-controlled filesystem links are ever created.
                    original = source.getmember(prefix + '/README.md') if member.issym() else member
                    with source.extractfile(original) as stream:
                        target.write_bytes(stream.read())
        stage = temporary / prefix
        subprocess.run(['git', 'apply', '--no-index', '--check', str(patch)], cwd=stage, check=True)
        subprocess.run(['git', 'apply', '--no-index', str(patch)], cwd=stage, check=True)
        files = inventory(stage)
        (stage / '.dsh-source.json').write_text(json.dumps({'identity': identity, 'files': files}, indent=2) + '\n')
        shutil.copytree(stage, output)  # Existing output is never overwritten.
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', help='Use a previously downloaded, checksum-verified archive')
    args = parser.parse_args()
    print(prepare(args.archive))
