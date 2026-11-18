#!/usr/bin/env python3
"""Collect Cargo license/notice originals and verify the packaged byte ranges."""
import hashlib
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
NOTICE_NAME = re.compile(r'^(licen[cs]e|copying|notice|copyright|authors|patents?)([._-].*)?$', re.I)
# Auto-discovery is a filename heuristic, not source-code or license parsing.
# Keep suffixes such as .txt/.md/.rst and license identifiers such as .APACHE.
SOURCE_SUFFIXES = {'.rs', '.c', '.cc', '.cpp', '.cxx', '.h', '.hpp', '.py',
                   '.js', '.jsx', '.ts', '.tsx', '.go', '.java', '.kt', '.swift'}
MAX_NOTICE_BYTES = 2 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def automatic_notice_path(relative):
    if relative.suffix.lower() in SOURCE_SUFFIXES:
        return False
    in_license_directory = any(part.lower() in {'licenses', 'licences'} for part in relative.parts[:-1])
    return bool(NOTICE_NAME.fullmatch(relative.name) or in_license_directory)


def inventory(metadata):
    pin = json.loads((HERE / 'source-pins.json').read_text())
    result = []
    for package in metadata['packages']:
        source = package.get('source')
        if source is None:
            if package['name'] == 'idevice':
                source = pin['repository'] + '@' + pin['commit'] + ' + local RSD XCTest patch'
            elif package['name'] == 'dsh-phone-self-runner':
                source = 'dsh-Go repository: tooling/ios/phone-self-runner'
            else:
                raise ValueError('Unexpected local path dependency')
        if not (source.startswith('registry+') or source.startswith('git+') or source.startswith('https://github.com/jkcoxson/idevice@') or source.startswith('dsh-Go repository:')):
            raise ValueError('Unexpected dependency source')
        result.append({'name': package['name'], 'version': package['version'],
                       'license': package.get('license'), 'source': source})
    result.sort(key=lambda value: (value['name'], value['version']))
    return {'schema': 1, 'scope': 'Locked Cargo package inventory. NOTICES.txt reproduces available license and attribution texts; curated supplements are identified separately.',
            'packages': result}


def read_notice(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('Notice must be a regular, non-symlink file')
    if path.stat().st_size > MAX_NOTICE_BYTES:
        raise ValueError('Empty, binary or oversized notice')
    with path.open('rb') as stream:
        data = stream.read(MAX_NOTICE_BYTES + 1)
    if not data.strip() or len(data) > MAX_NOTICE_BYTES or b'\0' in data:
        raise ValueError('Empty, binary or oversized notice')
    data.decode('utf-8')
    return data


def license_inputs(package):
    root = Path(package['manifest_path']).resolve(strict=True).parent
    name, version = package['name'], package['version']
    paths = set()
    if package.get('source') is None:
        if name == 'dsh-phone-self-runner':
            return [('LICENSE', read_notice(HERE.parents[2] / 'LICENSE'), 'repository-original')]
        if name == 'idevice':
            return [('LICENSE.txt', read_notice(root.parent / 'LICENSE.txt'), 'upstream-original')]
        raise ValueError('Unexpected local path dependency')
    for path in root.rglob('*'):
        relative = path.relative_to(root)
        if path.is_file() and automatic_notice_path(relative):
            paths.add(path)
    if package.get('license_file'):
        path = root / package['license_file']
        if path.is_symlink() or not path.resolve(strict=True).is_relative_to(root):
            raise ValueError('Declared license file escapes package')
        paths.add(path)
    result = [(path.relative_to(root).as_posix(), read_notice(path), 'crate-original')
              for path in sorted(paths)]
    supplements = json.loads((HERE / 'notice-supplements.json').read_text())
    supplement = supplements.get(name + '@' + version)
    if supplement:
        # A missing upstream file is not silently replaced for a later version.
        # Bind every exception to the exact published manifest and VCS identity.
        original = (root / 'Cargo.toml.orig').read_bytes()
        vcs = json.loads((root / '.cargo_vcs_info.json').read_text())
        if (digest(original) != supplement['manifest_sha256']
                or vcs.get('git', {}).get('sha1') != supplement['commit']
                or package.get('license') != supplement['license']):
            raise ValueError('Notice supplement does not match the published package')
        for filename in supplement.get('originals', []):
            path = root / filename
            if path.is_symlink() or not path.resolve(strict=True).is_relative_to(root):
                raise ValueError('Supplement original escapes package')
            result.append((filename, read_notice(path), 'crate-original'))
        # Both sides resolved: a temporary directory under /var is /private/var on macOS.
        texts = (HERE / 'notice-texts').resolve(strict=True)
        for document in supplement['documents']:
            path = HERE / 'notice-texts' / document['file']
            if path.is_symlink() or not path.resolve(strict=True).is_relative_to(texts):
                raise ValueError('Supplement document escapes notice-texts')
            data = read_notice(path)
            if digest(data) != document['sha256']:
                raise ValueError('Notice supplement SHA256 mismatch')
            result.append((document['file'], data, document['provenance']))
    if not result:
        raise ValueError('No license or notice text for ' + name + '@' + version)
    return result


def generate(metadata):
    report = inventory(metadata)
    packages = metadata['packages']
    by_id = {package['id']: package for package in packages}
    graph = metadata.get('resolve')
    if (len(by_id) != len(packages) or not graph or not graph.get('nodes')
            or graph.get('root') not in by_id
            or by_id[graph['root']]['name'] != 'dsh-phone-self-runner'
            or any(node['id'] not in by_id for node in graph['nodes'])):
        raise ValueError('Full resolved Cargo metadata is required; --no-deps is not sufficient')
    identities = [(p['name'], p['version']) for p in packages]
    if len(set(identities)) != len(identities):
        raise ValueError('Duplicate package name/version')
    output = bytearray(b'DSH Go phone native third-party notices\n'
                       b'Generated from locked Cargo metadata. Source texts below are copied verbatim.\n'
                       b'Curated upstream or standard-license supplements identify their provenance.\n'
                       b'No build-machine paths, pairing records or credentials are included.\n')
    entries = []
    public = {(p['name'], p['version']): p for p in report['packages']}
    for package in sorted(packages, key=lambda p: (p['name'], p['version'])):
        identity = public[(package['name'], package['version'])]
        output.extend(('\n' + '=' * 72 + '\n' + json.dumps(identity, ensure_ascii=True, sort_keys=True)
                       + '\nAuthors declared by package: '
                       + json.dumps(package.get('authors', []), ensure_ascii=True) + '\n').encode('utf-8'))
        files = []
        for filename, data, provenance in license_inputs(package):
            output.extend(('\n--- ' + filename + ' (' + provenance + ') ---\n').encode('utf-8'))
            offset = len(output)
            output.extend(data)
            files.append({'path': filename, 'provenance': provenance, 'offset': offset,
                          'bytes': len(data), 'sha256': digest(data)})
            output.extend(b'\n')
        entries.append({'name': package['name'], 'version': package['version'], 'files': files})
    notices = bytes(output)
    report['notices'] = {'file': 'NOTICES.txt', 'bytes': len(notices), 'sha256': digest(notices),
                         'packages': entries}
    verify(report, notices)
    return report, notices


def verify(report, notices):
    if report.get('schema') != 1 or not isinstance(report.get('packages'), list) or not report['packages']:
        raise ValueError('Invalid or empty Cargo inventory')
    if any(not isinstance(package, dict) or any(
            not isinstance(package.get(field), str) or not package[field]
            for field in ['name', 'version', 'source']) for package in report['packages']):
        raise ValueError('Invalid package name, version or source')
    index = report.get('notices', {})
    if (index.get('file') != 'NOTICES.txt' or index.get('bytes') != len(notices)
            or index.get('sha256') != digest(notices)):
        raise ValueError('NOTICES.txt identity mismatch')
    expected = [(p['name'], p['version']) for p in report['packages']]
    entries = index.get('packages', [])
    actual = [(p['name'], p['version']) for p in entries]
    if (len(set(expected)) != len(expected) or len(set(actual)) != len(actual)
            or sorted(expected) != sorted(actual)):
        raise ValueError('Notice coverage does not match all Cargo packages')
    previous_end = 0
    for package in entries:
        if not package.get('files'):
            raise ValueError('Package has no notice text')
        for item in package['files']:
            start, size = item.get('offset'), item.get('bytes')
            if (type(start) is not int or type(size) is not int or start < previous_end
                    or size <= 0 or start + size > len(notices)):
                raise ValueError('Invalid or overlapping notice byte range')
            content = notices[start:start + size]
            if digest(content) != item.get('sha256') or not content.strip() or b'\0' in content:
                raise ValueError('Notice source text identity mismatch')
            content.decode('utf-8')
            previous_end = start + size


def verify_bundle(root):
    report = json.loads((root / 'THIRD_PARTY_CRATES.json').read_text())
    verify(report, (root / 'NOTICES.txt').read_bytes())
    source = json.loads((root / 'SOURCE.json').read_text())
    pin = json.loads((HERE / 'source-pins.json').read_text())
    if source.get('commit') != pin['commit']:
        raise ValueError('Phone native source pin mismatch')
    packages = report['packages']
    if not any(p['name'] == 'dsh-phone-self-runner' for p in packages):
        raise ValueError('Missing phone native package')
    if not any(p['name'] == 'idevice' and pin['commit'] in p['source'] for p in packages):
        raise ValueError('Missing pinned idevice attribution')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--verify':
        verify_bundle(Path(sys.argv[2]))
    elif len(sys.argv) == 4:
        report, notices = generate(json.loads(Path(sys.argv[1]).read_text()))
        Path(sys.argv[3]).write_bytes(notices)
        Path(sys.argv[2]).write_text(json.dumps(report, indent=2, ensure_ascii=True) + '\n')
    else:
        raise SystemExit('Usage: license_inventory.py METADATA INVENTORY NOTICES | --verify BUNDLE_DIRECTORY')
