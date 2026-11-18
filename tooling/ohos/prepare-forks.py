#!/usr/bin/env python3
"""Prepare pinned OHOS plugin packages without editing a pub cache or an SDK.

Both OHOS build entry points use this file. A package is identified by the paths,
sizes and SHA256 of every regular file (including licenses, Dart and ArkTS).
Extra files and symlinks fail closed. No network access or dependency resolution.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
from urllib.parse import urljoin, urlparse
from urllib.request import url2pathname


FIXES = Path(__file__).resolve().parent / 'fork-fixes'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def tree(root, ignored=()):
    if not root.is_dir() or root.is_symlink():
        raise ValueError('package root must be an ordinary directory: ' + str(root))
    rows = []
    pending = [root]
    while pending:
        for path in pending.pop().iterdir():
            relative = path.relative_to(root).as_posix()
            if relative in ignored:
                continue  # Do not traverse generated dependency or build directories.
            mode = path.lstat().st_mode
            if stat.S_ISDIR(mode):
                pending.append(path)
                continue
            if not stat.S_ISREG(mode):
                raise ValueError('non-regular package member: ' + str(path))
            data = path.read_bytes()
            rows.append({'path': relative, 'bytes': len(data), 'sha256': sha(data)})
    rows.sort(key=lambda row: Path(row['path']))
    data = json.dumps(rows, ensure_ascii=False, separators=(',', ':')).encode()
    return rows, sha(data)


def configs():
    data = (FIXES / 'patches.json').read_bytes()
    value = json.loads(data)
    if value['schema'] != 1 or not value['packages']:
        raise ValueError('unsupported or empty fork patch manifest')
    return value['packages'], sha(data)


def package_roots(path):
    result = {}
    for package in json.loads(path.read_bytes())['packages']:
        name = package['name']
        if name in result:
            raise ValueError('duplicate resolved package: ' + name)
        uri = urlparse(urljoin(path.resolve().as_uri(), package['rootUri']))
        if uri.scheme != 'file' or uri.netloc not in ('', 'localhost') or uri.query or uri.fragment:
            raise ValueError('resolved package is not a local file URI: ' + name)
        result[name] = Path(url2pathname(uri.path)).resolve(strict=True)
    return result


def prepare(name, source, output, config, config_sha):
    if source.is_symlink():
        raise ValueError('input package must not be a symlink')
    source = source.resolve(strict=True)
    output = output.parent.resolve() / output.name
    if output == source or source in output.parents:
        raise ValueError('output must not be inside the input package')
    if os.path.lexists(output):
        raise FileExistsError('output must be a new directory: ' + str(output))
    before, before_sha = tree(source)
    if before_sha != config['inputTreeSha256']:
        raise ValueError('input package SHA256 mismatch: ' + name)
    for row in before:
        if any(row['path'] == prefix or row['path'].startswith(prefix + '/')
               for prefix in config.get('buildOutputs', [])):
            raise ValueError('build-output allowance would hide a pinned source file')
    patch = FIXES / config['patch']
    patch_data = patch.read_bytes()
    if sha(patch_data) != config['patchSha256']:
        raise ValueError('patch SHA256 mismatch: ' + name)
    for target, hashes in config['targets'].items():
        if sha((source / target).read_bytes()) != hashes['beforeSha256']:
            raise ValueError('input target SHA256 mismatch: ' + target)
    # git apply runs outside every repository and checks the entire patch before
    # applying it. The only mutable input is this fresh private package copy.
    with tempfile.TemporaryDirectory(prefix='dsh-ohos-fork-') as temporary:
        temporary = Path(temporary)
        package = temporary / 'package'
        shutil.copytree(source, package)
        for action in (['--check'], []):
            subprocess.run(['git', 'apply', *action, '--directory=package', str(patch)],
                           cwd=temporary, check=True, capture_output=True)
        after, after_sha = tree(package)
        if after_sha != config['outputTreeSha256']:
            raise ValueError('output package SHA256 mismatch: ' + name)
        old = {row['path']: row['sha256'] for row in before}
        new = {row['path']: row['sha256'] for row in after}
        changed = sorted(path for path in old.keys() | new.keys() if old.get(path) != new.get(path))
        if changed != sorted(config['targets']):
            raise ValueError('unexpected changed package files: ' + name)
        for target, hashes in config['targets'].items():
            if new[target] != hashes['afterSha256']:
                raise ValueError('output target SHA256 mismatch: ' + target)
        if tree(source) != (before, before_sha):
            raise ValueError('input package changed while preparing: ' + name)
        report = {'schema': 1, 'package': name, 'upstream': config['upstream'],
                  'inputTreeSha256': before_sha, 'outputTreeSha256': after_sha,
                  'configSha256': config_sha, 'patchSha256': sha(patch_data),
                  'preparerSha256': sha(Path(__file__).read_bytes()),
                  'before': before, 'after': after, 'changedFiles': changed,
                  'status': 'PREPARED_ONLY; compiler and device results are separate'}
        output.parent.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix='.fork-stage-', dir=output.parent))
        try:
            shutil.copytree(package, stage / 'package')
            (stage / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
            if os.path.lexists(output):
                raise FileExistsError('output appeared while preparing')
            stage.rename(output)
        finally:
            if stage.exists():
                shutil.rmtree(stage)
    return report


def verify_resolved(path, output, entries, after_build=False):
    roots = package_roots(path)
    result = []
    for name, config in entries.items():
        expected = (output / name / 'package').resolve(strict=True)
        if roots.get(name) != expected:
            raise ValueError('pub did not select the prepared package: ' + name)
        _, actual = tree(expected, config.get('buildOutputs', []) if after_build else ())
        if actual != config['outputTreeSha256']:
            raise ValueError('resolved package SHA256 mismatch: ' + name)
        result.append({'package': name, 'root': str(expected), 'sha256': actual,
                       'afterBuild': after_build,
                       'allowedBuildOutputs': config.get('buildOutputs', []) if after_build else []})
    return result


def installed_root(project, package):
    # Match hvigor's OHPM resolver: the first visible package alias wins,
    # starting at the importing entry module, then its ancestors. Do not scan
    # .ohpm for a copy whose contents happen to match our pins.
    importer = project.resolve(strict=True) / 'entry'
    searched = []
    for directory in (importer, *importer.parents):
        if directory == directory.parent:
            break
        if directory.name.lower() == 'oh_modules':
            continue
        alias = directory / 'oh_modules' / package
        searched.append(str(alias))
        if alias.exists():
            native = alias.resolve(strict=True)
            if not (native / 'oh-package.json5').is_file():
                raise ValueError('resolved native plugin has no oh-package.json5: '
                                 + str(alias) + ' -> ' + str(native))
            return native, alias
    raise ValueError('native plugin was not installed: ' + package
                     + '; searched ' + ', '.join(searched)
                     + '; run ohpm install for this project and rebuild; '
                     'the installed package alias must resolve to native sources')


def verify_installed(project, entries):
    result = []
    for name, config in entries.items():
        native, alias = installed_root(project, config['nativePackage'])
        for target, hashes in config['targets'].items():
            relative = Path(target).relative_to(config['nativeSubdir'])
            path = native / relative
            try:
                actual = sha(path.read_bytes())
            except OSError as error:
                raise ValueError('installed native target unavailable: ' + str(path)
                                 + '; selected alias ' + str(alias)
                                 + '; native sources are required for SHA256 verification') from error
            if actual != hashes['afterSha256']:
                raise ValueError('installed native target SHA256 mismatch: ' + str(path)
                                 + '; expected ' + hashes['afterSha256'] + ', got ' + actual)
            result.append({'package': name, 'target': str(path), 'alias': str(alias),
                           'sha256': hashes['afterSha256']})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--input', type=Path, help='one pristine package directory')
    mode.add_argument('--package-config', type=Path, help='prepare all configured resolved forks')
    mode.add_argument('--verify-package-config', type=Path, help='verify actual post-pub-get package roots')
    mode.add_argument('--verify-installed', type=Path, help='OHOS project after its native build')
    mode.add_argument('--list-packages', action='store_true', help='configured package names for build integration')
    parser.add_argument('--package', help='manifest package name, with --input')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--overrides', type=Path)
    parser.add_argument('--after-build', action='store_true', help='allow only declared generated paths after a build')
    args = parser.parse_args()
    if args.after_build and not args.verify_package_config:
        parser.error('--after-build requires --verify-package-config')
    entries, config_sha = configs()
    if args.list_packages:
        print(' '.join(entries))
        return
    if args.verify_installed:
        print(json.dumps(verify_installed(args.verify_installed, entries), indent=2))
        return
    if args.output is None:
        parser.error('--output is required')
    if args.verify_package_config:
        print(json.dumps(verify_resolved(args.verify_package_config, args.output, entries, args.after_build), indent=2))
        return
    if args.input:
        if args.package not in entries or args.overrides:
            parser.error('--input requires a configured --package and no --overrides')
        report = prepare(args.package, args.input, args.output, entries[args.package], config_sha)
        print(json.dumps({key: report[key] for key in ('package', 'inputTreeSha256', 'outputTreeSha256', 'changedFiles')}, indent=2))
        return
    if args.overrides is None or args.package:
        parser.error('--package-config requires --overrides and no --package')
    original = args.overrides.read_text()
    if len(re.findall(r'^dependency_overrides:\s*$', original, re.M)) != 1:
        raise ValueError('expected one dependency_overrides mapping')
    roots = package_roots(args.package_config)
    additions = []
    for name, config in entries.items():
        if re.search(r'^  ' + re.escape(name) + r'\s*:', original, re.M):
            raise ValueError('fork override already exists: ' + name)
        if name not in roots:
            raise ValueError('fork missing from package config: ' + name)
        output = args.output / name
        prepare(name, roots[name], output, config, config_sha)
        relative = os.path.relpath(output / 'package', args.overrides.parent)
        additions.append(f'  {name}:\n    path: {json.dumps(relative)}\n')
    if args.overrides.read_text() != original:
        raise ValueError('overrides changed while preparing')
    args.overrides.write_text(original.rstrip('\n') + '\n' + ''.join(additions))
    print(json.dumps({'prepared': list(entries), 'overrides': str(args.overrides)}, indent=2))


if __name__ == '__main__':
    main()
