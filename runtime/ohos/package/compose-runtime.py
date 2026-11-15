#!/usr/bin/env python3
"""Assemble a fixed OHOS rawfile payload; never modifies the input prefixes.

Native libraries are separate HAP libs inputs. This does not build or sign a HAP.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True

MAX_ARCHIVE = 0x7fffffff
MAX_DIRECTORY = 32 * 1024 * 1024
MAX_MANIFEST = 16 * 1024 * 1024
MAX_NAME = 4096
MAX_FILE = 512 * 1024 * 1024


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_bytes(value) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def file_digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open('rb') as source:
        while chunk := source.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


def zip_entry(name: str, method: int, size: int) -> zipfile.ZipInfo:
    entry = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
    entry.create_system = 3
    entry.external_attr = 0o100644 << 16
    entry.compress_type = method
    entry.file_size = size
    entry.extra = b''
    entry.comment = b''
    return entry


def write_zip_file(bundle: zipfile.ZipFile, name: str, source: Path, method: int):
    entry = zip_entry(name, method, source.stat().st_size)
    if method == zipfile.ZIP_DEFLATED:
        # Use the public per-member compresslevel API. ZipFile.open(ZipInfo)
        # does not inherit the archive's compresslevel on Python 3.11.
        bundle.writestr(entry, source.read_bytes(), compress_type=method, compresslevel=9)
        return
    # The output is a regular seekable file. ZIP32 headers are updated in place;
    # data descriptors, ZIP64 and encryption are never needed or permitted.
    with source.open('rb') as reader, bundle.open(entry, 'w') as writer:
        shutil.copyfileobj(reader, writer, 1024 * 1024)


def verify_zip_member(bundle: zipfile.ZipFile, entry: zipfile.ZipInfo, expected):
    if (entry.flag_bits not in (0, 0x800) or entry.extra or entry.comment or entry.is_dir() or
            entry.create_system != 3 or entry.external_attr != 0o100644 << 16 or
            entry.date_time != (2026, 1, 1, 0, 0, 0)):
        raise ValueError(f'Runtime ZIP metadata differs from the fixed ZIP32 format: {entry.filename}')
    hasher, count = hashlib.sha256(), 0
    with bundle.open(entry) as reader:
        while chunk := reader.read(1024 * 1024):
            count += len(chunk)
            if count > expected['size']:
                raise ValueError(f'Archive expanded beyond manifest size: {entry.filename}')
            hasher.update(chunk)
    if count != expected['size'] or hasher.hexdigest() != expected['sha256']:
        raise ValueError(f'Archive content differs from the manifest: {entry.filename}')


def write_runtime_archive(expanded: Path, destination: Path):
    """ZIP32: first manifest Stored; exactly its files in order, Deflate level 9."""
    manifest_path = expanded / 'manifest.json'
    manifest_bytes = manifest_path.read_bytes()
    if len(manifest_bytes) > MAX_MANIFEST:
        raise ValueError('Runtime ZIP manifest size exceeds the installer profile')
    manifest = json.loads(manifest_bytes)
    rows = manifest['files']
    names = [row['path'] for row in rows]
    if not rows or len(rows) + 1 >= 0xffff:
        raise ValueError('Runtime ZIP32 member count must be 2..65534, below the ZIP64 sentinel')
    if names != sorted(set(names)):
        raise ValueError('Runtime ZIP32 requires unique sorted manifest paths')
    expected = {'manifest.json': {'size': len(manifest_bytes), 'sha256': digest(manifest_bytes)}}
    expanded_size = len(manifest_bytes)
    directory_size = 46 + len('manifest.json')
    for row in rows:
        safe_path(row['path'])
        name = 'files/' + row['path']
        name_size = len(name.encode('utf-8'))
        if name_size > MAX_NAME:
            raise ValueError('Runtime ZIP member name exceeds the installer profile')
        if type(row['size']) is not int or not 0 <= row['size'] <= MAX_FILE:
            raise ValueError('Runtime ZIP file size exceeds the installer profile')
        expanded_size += row['size']
        directory_size += 46 + name_size
        expected[name] = row
    if expanded_size > MAX_ARCHIVE:
        raise ValueError('Runtime ZIP expanded size exceeds the installer profile')
    if directory_size > MAX_DIRECTORY:
        raise ValueError('Runtime ZIP central directory size exceeds the installer profile')
    observed = set()
    for path in records(expanded / 'files'):
        if not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError('Runtime archive input must contain only regular files')
        observed.add(path.relative_to(expanded).as_posix())
    if observed != set(expected) - {'manifest.json'}:
        raise ValueError('Runtime archive input file set differs from the manifest')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, 'x', compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9, allowZip64=False) as bundle:
        write_zip_file(bundle, 'manifest.json', manifest_path, zipfile.ZIP_STORED)
        for row in rows:
            write_zip_file(bundle, 'files/' + row['path'], expanded / 'files' / row['path'], zipfile.ZIP_DEFLATED)
    if destination.stat().st_size > MAX_ARCHIVE:
        raise ValueError('Runtime ZIP archive size exceeds the installer profile')
    with zipfile.ZipFile(destination) as bundle:
        members = bundle.infolist()
        if bundle.comment or [item.filename for item in members] != list(expected):
            raise ValueError('Runtime archive entry order or set differs from the fixed format')
        for index, entry in enumerate(members):
            method = zipfile.ZIP_STORED if index == 0 else zipfile.ZIP_DEFLATED
            if entry.compress_type != method:
                raise ValueError('Runtime archive compression method differs from the fixed format')
            verify_zip_member(bundle, entry, expected[entry.filename])
    return {'schema': 1, 'format': 'single-zip32-v1', 'path': 'dsh-runtime/runtime.zip',
            'bytes': destination.stat().st_size, 'sha256': file_digest(destination),
            'members': len(expected), 'manifestMember': 'manifest.json',
            'manifestCompression': 'Stored', 'fileCompression': 'Deflate9',
            'manifestSha256': digest(manifest_bytes), 'zip64': False,
            'dataDescriptors': False, 'memberRoundTrip': True}


def write_transport_archive(runtime_archive: Path, destination: Path):
    """The HAP rawfile input transport contains one Stored runtime.zip member."""
    name = 'dsh-runtime/runtime.zip'
    expected = {'size': runtime_archive.stat().st_size, 'sha256': file_digest(runtime_archive)}
    if expected['size'] > MAX_ARCHIVE:
        raise ValueError('Runtime ZIP archive size exceeds the installer profile')
    with zipfile.ZipFile(destination, 'x', compression=zipfile.ZIP_STORED, allowZip64=False) as bundle:
        write_zip_file(bundle, name, runtime_archive, zipfile.ZIP_STORED)
    with zipfile.ZipFile(destination) as bundle:
        members = bundle.infolist()
        if bundle.comment or len(members) != 1 or members[0].filename != name or members[0].compress_type != zipfile.ZIP_STORED:
            raise ValueError('Transport must contain exactly one Stored dsh-runtime/runtime.zip')
        verify_zip_member(bundle, members[0], expected)


def package_names(relative: str):
    parts = PurePosixPath(relative).parts
    for i, part in enumerate(parts[:-1]):
        if part == 'node_modules':
            yield '/'.join(parts[i + 1:i + 3]) if parts[i + 1].startswith('@') else parts[i + 1]


def package_path(relative: str) -> str:
    parts = PurePosixPath(relative).parts
    position = max(i for i, part in enumerate(parts) if part == 'node_modules')
    count = 3 if parts[position + 1].startswith('@') else 2
    return '/'.join(parts[:position + count])


def package_reason(relative: str, rules: dict[str, str]) -> str | None:
    for name in package_names(relative):
        for pattern, reason in rules.items():
            if fnmatch.fnmatchcase(name, pattern):
                return reason
    return None


def safe_path(relative: str) -> None:
    if ('\\' in relative or '\0' in relative or
            any(part in ('', '.', '..') for part in relative.split('/')) or
            re.search(r'(?:\.node|\.so(?:\.[0-9]+)*)$', relative, re.I)):
        raise ValueError(f'Not a P2 rawfile path: {relative}')


def records(root: Path):
    for parent, dirs, files in os.walk(root, followlinks=False):
        dirs.sort()
        files.sort()
        for name in dirs[:]:
            path = Path(parent) / name
            if path.is_symlink():
                dirs.remove(name)
                yield path
        for name in files:
            yield Path(parent) / name


class Composer:
    def __init__(self, files: Path):
        self.files = files
        self.inputs = []
        self.payload = {}
        self.removed = {}

    def add(self, source: Path, source_root: Path, label: str, destination: str,
            reason: str | None = None):
        relative = source.relative_to(source_root).as_posix()
        mode = source.lstat().st_mode
        if stat.S_ISLNK(mode):
            # npm executable links and the development-only DSH link are not a payload.
            if '/.bin/' not in '/' + relative and relative != 'node_modules/@deepseek-ai':
                raise ValueError(f'Unexpected input symlink: {label}/{relative}')
            self.inputs.append({'source': label, 'path': relative, 'link': os.readlink(source),
                                'decision': 'omit-development-link'})
            return
        if not stat.S_ISREG(mode):
            raise ValueError(f'Not a regular input: {source}')
        data = source.read_bytes()
        item = {'source': label, 'path': relative, 'size': len(data), 'sha256': digest(data)}
        if reason is not None:
            item['decision'] = 'omit'
            item['reason'] = reason
            summary = self.removed.setdefault(reason, {'files': 0, 'bytes': 0})
            summary['files'] += 1
            summary['bytes'] += len(data)
            self.inputs.append(item)
            return
        safe_path(destination)
        if data[:4] in (b'\x7fELF', b'\0asm', b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe',
                        b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe') or data[:2] == b'MZ':
            raise ValueError(f'Unclassified executable/wasm in rawfile payload: {label}/{relative}')
        if destination in self.payload:
            raise ValueError(f'Duplicate payload path: {destination}')
        target = self.files / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(0o644)
        row = {'path': destination, 'size': len(data), 'sha256': item['sha256']}
        self.payload[destination] = row
        item['decision'] = 'include'
        item['destination'] = destination
        self.inputs.append(item)

    def dependencies(self, root: Path, label: str, destination: str, packages, rules, file_rules=None):
        file_rules = file_rules or {}
        allowed = {row['path'] for row in packages}
        for source in records(root / 'node_modules'):
            relative = source.relative_to(root).as_posix()
            reason = package_reason(relative, rules) or next(
                (reason for pattern, reason in file_rules.items() if fnmatch.fnmatchcase(relative, pattern)), None)
            if reason is None and package_path(relative) not in allowed:
                reason = '不属于固定 npm 锁的额外包或开发链接；自有助手从仓库单独生成'
            if reason is None and (source.name.endswith(('.map', '.d.ts', '.d.cts', '.d.mts')) or
                                   '/.bin/' in '/' + relative or source.name == '.package-lock.json'):
                reason = '类型声明、源码映射、npm安装缓存和外部命令入口不参与设备运行'
            if reason is None and re.search(r'(?:\.node|\.so(?:\.[0-9]+)*)$', relative, re.I):
                raise ValueError(f'Native-named file was not assigned a composition rule: {label}/{relative}')
            target = '/'.join(part for part in (destination, relative) if part)
            self.add(source, root, label, target, reason)


def checked_lock(prefix: Path, expected: str):
    data = (prefix / 'package-lock.json').read_bytes()
    if digest(data) != expected:
        raise ValueError(f'Locked dependency input differs: {prefix}/package-lock.json')
    lock = json.loads(data)
    packages = []
    for relative, entry in lock['packages'].items():
        if not relative:
            continue
        manifest = prefix / relative / 'package.json'
        if entry.get('optional'):
            if manifest.exists():
                raise ValueError(f'Optional package violates the fixed --omit=optional recipe: {relative}')
            continue
        if not manifest.exists():
            raise ValueError(f'Missing locked package: {relative}')
        observed = json.loads(manifest.read_text())
        if observed.get('version') != entry.get('version'):
            raise ValueError(f'Installed package version differs: {relative}')
        packages.append({'path': relative, 'name': observed['name'], 'version': observed['version'],
                         'packageJsonSha256': digest(manifest.read_bytes()),
                         'integrity': entry.get('integrity'), 'license': observed.get('license')})
    return packages


def required_entries(repo: Path):
    host = (repo / 'app/ohos/entry/src/main/cpp/host_core.cpp').read_text()
    calls = re.findall(r'\bFile\s*\(\s*options\.runtime_root\s*,', host)
    entries = re.findall(r'\bFile\s*\(\s*options\.runtime_root\s*,\s*"([^"\n]+)"\s*\)', host)
    if not entries or len(calls) != len(entries):
        raise ValueError('Host runtime requirements are no longer the checked literal File calls')
    core = (repo / 'app/ohos/entry/src/main/ets/runtime/RuntimeCore.ets').read_text()
    match = re.search(r'for \(const entry of \[([^\]]+)\]\)', core)
    manifest_entries = re.findall(r"'([^']+)'", match[1]) if match else []
    if set(entries) != set(manifest_entries):
        raise ValueError('Host::Start and RuntimeCore required entries differ')
    return sorted(set(entries))


def check_patches(repo: Path, prefix: Path, target_report: Path):
    spec = importlib.util.spec_from_file_location('ohos_rtbuild', repo / 'runtime/lib/rtbuild.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    pins = json.loads((repo / 'runtime/patches/pins.json').read_text())
    names, _ = module.select_dsh_patches(pins, str(repo / 'runtime/patches'), 'ohos')
    version = json.loads((repo / 'runtime/ohos/package/composition.json').read_text())['dshVersion']
    _, identity = module.dsh_patch_inputs(pins, str(repo / 'runtime/patches'), names, 'ohos', version)
    report = json.loads(target_report.read_text())
    if report.get('target') != 'ohos' or report.get('dshVersion') != version or report.get('inputSha256') != identity:
        raise ValueError('Requires the current actual --target ohos patch report')
    final = {}
    for name in names:
        final.update(pins['patches'][name][version])
    for relative, pin in final.items():
        if digest((prefix / relative).read_bytes()) != pin['after']:
            raise ValueError(f'Patched input is not the final selected OHOS state: {relative}')
    for name in ('ohos-hap-native-libraries.diff', 'zzzzzzzzzzzz-ohos-composition.diff'):
        if name not in names:
            raise ValueError(f'Required OHOS seam is absent: {name}')
    return identity


def deletion_variants(repo: Path, prefix: Path, output: Path):
    """Generate only the two OH deletion variants; never rewrite shared Android inputs."""
    rows = [
        ('runtime/session-deletion/core.mjs',
         'node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/dsh-go-deletion.mjs', 'core.mjs',
         '25a4da7393ed29ec1427862796ea310c55e32368e616b6ab43e36a3a56976430',
         'db7fd228ef4190023ac37850f47a61b0a0f0e9111428fe61bec956017e295bf6'),
        ('runtime/bridge/dsh-go-bridge/lib/session-deletion.js',
         'runtime/bridge/dsh-go-bridge/lib/session-deletion.js', 'session-deletion.js',
         '8483c8265cfad03d9f4f1b5a483f0f4a300bb97eb0027d8d60016c9f09706837',
         'f94f045fd765b6dd99fc6f2a644c0eb144ace71123c7eea89d261ed32e910805'),
    ]
    patch = repo / 'runtime/ohos/package/session-deletion-ohos.diff'
    spec = importlib.util.spec_from_file_location('deletion_rtbuild', repo / 'runtime/lib/rtbuild.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    parsed = module.parse_unified_diff(patch.read_text())
    if [name for name, _ in parsed] != [row[0] for row in rows]:
        raise ValueError('OH deletion diff must contain exactly the reviewed core and bridge sources')
    generated = []
    for (source, destination, name, before, after), (_, hunks) in zip(rows, parsed):
        raw = (repo / source).read_bytes()
        if digest(raw) != before:
            raise ValueError(f'OH deletion source changed; review the new input: {source}')
        if source == rows[0][0] and (prefix / destination).read_bytes() != raw:
            raise ValueError('Prepared deletion companion differs from the shared source')
        data = module.apply_hunks(raw.decode('utf-8'), hunks, source).encode('utf-8')
        if digest(data) != after:
            raise ValueError(f'OH deletion variant differs from its reviewed output: {source}')
        generated.append((data, {'source': source, 'sourceSize': len(raw), 'sourceSha256': before,
                                'destination': destination, 'file': name,
                                'size': len(data), 'sha256': after}))
    output.mkdir(parents=True)  # a prior result is not an input
    for data, row in generated:
        target = output / row['file']
        target.write_bytes(data)
        target.chmod(0o644)
    report = {'schema': 1, 'scope': 'OH-only session deletion composition variants',
              'patch': patch.relative_to(repo).as_posix(), 'patchSha256': digest(patch.read_bytes()),
              'generatorSha256': digest(Path(__file__).read_bytes()),
              'files': [row for _, row in generated]}
    (output / 'sources.json').write_bytes(json_bytes(report))
    return report


def assemble(args):
    repo = Path(__file__).resolve().parents[3]
    required = required_entries(repo)
    config_path = Path(__file__).with_name('composition.json')
    config = json.loads(config_path.read_text())
    if config['schema'] != 1 or args.target != config['target']:
        raise ValueError('Unsupported composition target/schema')
    dsh = args.dsh_prefix.resolve(strict=True)
    process = args.process_prefix.resolve(strict=True)
    output = args.out.absolute()
    for source in (repo, dsh, process):
        if output.resolve().is_relative_to(source) or source.is_relative_to(output.resolve()):
            raise ValueError('Output must be separate from repository and input prefixes')
    if output.exists() or output.is_symlink():
        raise ValueError('Output already exists; preserved')
    packages = {'dsh': checked_lock(dsh, config['dshLockSha256']),
                'process': checked_lock(process, config['processLockSha256'])}
    input_spec = importlib.util.spec_from_file_location('ohos_prepared_inputs', Path(__file__).with_name('prepare-inputs.py'))
    input_module = importlib.util.module_from_spec(input_spec)
    input_spec.loader.exec_module(input_module)
    receipt_identity = input_module.verify_inputs(args.prepared_inputs, config, dsh, process)
    patch_identity = check_patches(repo, dsh, args.target_report)
    regex = args.regex_artifact.resolve(strict=True)
    if digest(regex.read_bytes()) != config['regexSha256']:
        raise ValueError('Private RE2 artifact differs from the locked output')
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.ohos-compose-', dir=output.parent))
    try:
        raw = staging / 'rawfile/dsh-runtime'
        composer = Composer(raw / 'files')
        deletion_root = staging / 'generated/ohos-deletion'
        deletion = deletion_variants(repo, dsh, deletion_root)
        deletion_paths = {row['destination'] for row in deletion['files']}
        deletion_reason = 'OH 原子删除使用已核源差分生成的专用模块；共享 Android 输入保持原字节'
        dsh_file_rules = {**config['dshRemoveFiles'], deletion['files'][0]['destination']: deletion_reason}
        # Only the npm prefix's node_modules, never a prior staged runtime subtree.
        composer.dependencies(dsh, 'dsh', '', packages['dsh'], config['dshRemovePackages'], dsh_file_rules)
        composer.add(dsh / 'package.json', dsh, 'dsh', 'package.json')
        composer.dependencies(process, 'process-dependencies', 'runtime/ohos/process',
                              packages['process'], config['processRemovePackages'], config['processRemoveFiles'])
        source_runtime = repo / 'runtime/ohos'
        for directory in ('net', 'publication', 'capabilities', 'lifecycle', 'process'):
            for source in sorted((source_runtime / directory).glob('*.mjs')):
                if source.name.startswith(('build-', 'link-')):
                    continue
                composer.add(source, repo, 'repository', source.relative_to(repo).as_posix())
        for name in ('preload.mjs', 'node-version.json'):
            composer.add(source_runtime / name, repo, 'repository', 'runtime/ohos/' + name)
        helper = source_runtime / 'native/hap-loader'
        for name in ('index.cjs', 'package.json'):
            composer.add(helper / name, repo, 'repository', 'node_modules/@dsh-go/ohos-native/' + name)
        composer.add(repo / 'LICENSE', repo, 'repository', 'node_modules/@dsh-go/ohos-native/LICENSE')
        bridge = repo / 'runtime/bridge/dsh-go-bridge'
        for source in records(bridge / 'lib'):
            destination = source.relative_to(repo).as_posix()
            composer.add(source, repo, 'repository', destination,
                         deletion_reason if destination in deletion_paths else None)
        for name in ('package.json', 'cordis.patch.yml'):
            composer.add(bridge / name, repo, 'repository', (bridge / name).relative_to(repo).as_posix())
        for row in deletion['files']:
            composer.add(deletion_root / row['file'], deletion_root, 'generated-ohos-deletion', row['destination'])
        for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
            composer.add(repo / name, repo, 'repository', name)
        for source in records(source_runtime / 'licenses/texts'):
            composer.add(source, repo, 'repository', source.relative_to(repo).as_posix())
        composer.add(source_runtime / 'licenses/manifest.json', repo, 'repository', 'runtime/ohos/licenses/input-manifest.json')
        built = staging / 'generated/just-bash'
        command = [sys.executable, '-I', '-B', str(source_runtime / 'process/build-just-bash.py'),
                   '--package', str(process / 'node_modules/just-bash'), '--out', str(built)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        (staging / 'build.stdout').write_text(result.stdout)
        (staging / 'build.stderr').write_text(result.stderr)
        if result.returncode:
            raise ValueError(f'Private just-bash build refused: {result.stderr}')
        for source in records(built):
            composer.add(source, built, 'generated-just-bash', 'runtime/ohos/process/build/just-bash/' + source.relative_to(built).as_posix())
        composer.add(regex, regex.parent, 'generated-regex', 'runtime/ohos/process/build/re2js-unicode.mjs')
        omissions = json.loads(Path(__file__).with_name('dynamic-omissions.json').read_text())
        provenance = json.loads((built / 'PROVENANCE.json').read_text())
        for item in omissions:
            if item['importer'] == 'runtime/ohos/process/build/just-bash/index.js':
                item['importerSha256'] = provenance['modules']['index.js']
            elif 'importerSha256' not in item:
                raise ValueError('Dynamic omission requires a reviewed exact importer hash')
        allowlist = staging / 'dynamic-omissions.json'
        allowlist.write_bytes(json_bytes(omissions))
        imports_command = [str(args.node), '--experimental-import-meta-resolve',
            str(Path(__file__).with_name('audit-imports.mjs')), str(composer.files),
            str(args.esbuild_prefix), str(allowlist), str(args.imports_report)]
        imports = subprocess.run(imports_command, capture_output=True, text=True, timeout=180)
        if imports.returncode:
            raise ValueError(f'Packaged import resolution refused; report {args.imports_report}: {imports.stdout} {imports.stderr}')
        shutil.copyfile(args.imports_report, staging / 'imports-report.json')
        payload = sorted(composer.payload.values(), key=lambda row: row['path'])
        for entry in required:
            if entry not in composer.payload:
                raise ValueError(f'Host::Start required file is absent from the payload: {entry}')
        for row in payload:
            if any(name in {'just-bash', 'sql.js', 'typescript', 'run', 'minimisted'} for name in package_names(row['path'])):
                raise ValueError(f'Excluded interpreter/CLI dependency remained: {row["path"]}')
        identity = digest(json_bytes({'target': 'ohos', 'dsh': config['dshVersion'], 'node': config['nodeVersion'], 'files': payload}))
        manifest = {'schema': 1, 'runtimeVersion': 'ohos-' + identity[:24],
                    'dshVersion': config['dshVersion'], 'nodeVersion': config['nodeVersion'], 'files': payload}
        raw.mkdir(parents=True, exist_ok=True)
        (raw / 'manifest.json').write_bytes(json_bytes(manifest))
        validator = [str(args.node), str(Path(__file__).with_name('validate-manifest.mjs')),
                     str(args.runtime_core), str(raw / 'manifest.json')]
        validated = subprocess.run(validator, capture_output=True, text=True, timeout=30)
        (staging / 'manifest-validation.json').write_bytes(json_bytes({
            'command': validator, 'code': validated.returncode,
            'stdout': validated.stdout, 'stderr': validated.stderr}))
        if validated.returncode:
            raise ValueError(f'Actual P2 manifest consumer rejected the payload: {validated.stderr}')
        (staging / 'input-files.json').write_bytes(json_bytes(composer.inputs))
        (staging / 'payload-files.json').write_bytes(json_bytes(payload))
        (staging / 'input-packages.json').write_bytes(json_bytes(packages))
        # The expanded staging tree remains outside HAP rawfile. It is deleted
        # by default after the complete archive has passed every member hash.
        expanded = staging / 'expanded/dsh-runtime'
        expanded.parent.mkdir()
        os.rename(raw, expanded)
        raw.mkdir()
        runtime_archive = raw / 'runtime.zip'
        container = write_runtime_archive(expanded, runtime_archive)
        (staging / 'manifest.json').write_bytes(json_bytes(manifest))  # build/test metadata only
        archive = staging / 'dsh-runtime-rawfile.zip'
        write_transport_archive(runtime_archive, archive)
        if not args.keep_expanded:
            shutil.rmtree(expanded.parent)
        report = {'scope': 'OHOS rawfile input archive, not a compiled/signed HAP',
                  'target': 'ohos', 'runtimeVersion': manifest['runtimeVersion'], 'payloadSha256': identity,
                  'compositionSha256': digest(config_path.read_bytes()), 'patchInputSha256': patch_identity,
                  'preparedInputsSha256': receipt_identity, 'installation': config['installation'],
                  'deletionVariants': deletion,
                  'inputBytes': sum(row.get('size', 0) for row in composer.inputs if not row['source'].startswith('generated-')),
                  'payloadBytes': sum(row['size'] for row in payload), 'payloadFiles': len(payload),
                  'archiveBytes': archive.stat().st_size, 'archiveSha256': file_digest(archive),
                  'archiveRoundTrip': True, 'runtimeArchive': container,
                  'rawfileFiles': 1, 'rawfileBytes': container['bytes'],
                  'expandedRetainedForValidation': args.keep_expanded,
                  'nativeLibraries': config['nativeLibraries'],
                  'nativeLibrariesInRawfile': False, 'ohosTargetAbi': 'NOT_RUN', 'hapInstall': 'NOT_RUN',
                  'requiredRuntimeFiles': required,
                  'removed': composer.removed, 'buildCommand': command,
                  'importsCommand': imports_command, 'importsReportSha256': digest(args.imports_report.read_bytes()),
                  'compileCache': 'HostOptions.cacheDir/node-compile-cache; never part of immutable rawfile'}
        (staging / 'composition-report.json').write_bytes(json_bytes(report))
        os.rename(staging, output)
        return report
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=['ohos'], required=True)
    for name in ('dsh-prefix', 'process-prefix', 'target-report', 'prepared-inputs', 'regex-artifact', 'esbuild-prefix', 'imports-report', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--node', type=Path, required=True)
    parser.add_argument('--runtime-core', type=Path, required=True,
                        help='Actual RuntimeCore.ets consumer; type syntax is erased for Linux validation')
    parser.add_argument('--keep-expanded', action='store_true',
                        help='Keep the verified expanded tree outside rawfile for build-time inspection only')
    args = parser.parse_args()
    try:
        report = assemble(args)
    except (OSError, ValueError, KeyError, zipfile.LargeZipFile) as error:
        print(f'OHOS composition refused: {error}', file=sys.stderr)
        raise SystemExit(2) from None
    print(json.dumps({key: report[key] for key in ('runtimeVersion', 'payloadBytes', 'payloadFiles', 'archiveBytes', 'archiveRoundTrip')}))


if __name__ == '__main__':
    main()
