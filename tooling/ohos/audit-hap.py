#!/usr/bin/env python3
"""List what a packaged HAP really holds and check it against its inputs. No device claim."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
LIB_DIR = 'libs/arm64-v8a/'
LIBS = {'libapp.so', 'libflutter.so', 'libnode.so', 'libdsh_host.so', 'libdsh_flock.so',
        'libdsh_require_builtin.so', 'libc++_shared.so'}
RAWFILE = 'resources/rawfile/'
# Ark modules: they import the plain napi_* on purpose, or nothing of it at all.
OUTSIDE_NODE = {'libapp.so', 'libflutter.so'}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def data_offset(hap, info):
    """Where the entry's bytes start, from its local header."""
    hap.seek(info.header_offset)
    header = hap.read(30)
    name_length, extra_length = struct.unpack('<HH', header[26:30])
    return info.header_offset + 30 + name_length + extra_length


def changes_outside_header(old, new):
    """Differing bytes in the loaded segments, past the ELF header's section-table fields."""
    offset = struct.unpack('<Q', old[32:40])[0]
    count, size = struct.unpack('<HH', old[56:58] + old[54:56])
    total = 0
    for index in range(count):
        kind, _, start, _, _, length, *_ = struct.unpack('<IIQQQQQQ', old[offset + index * size:offset + index * size + 56])
        if kind == 1:
            first = max(start, 64)
            a, b = old[first:start + length], new[first:start + length]
            total += sum(x != y for x, y in zip(a, b)) if a != b else 0
    return total


def load_audit():
    spec = importlib.util.spec_from_file_location('build_hap_libs', ROOT / 'runtime/ohos/native/build-hap-libs.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.audit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hap', required=True, type=Path)
    parser.add_argument('--sdk', required=True, type=Path, help='Holds native/ and toolchains/')
    parser.add_argument('--aot', required=True, type=Path)
    parser.add_argument('--native', required=True, type=Path)
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--node-headers', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    problems, report = [], {'hap': str(args.hap), 'bytes': args.hap.stat().st_size,
                            'sha256': sha256(args.hap.read_bytes())}
    zipped = zipfile.ZipFile(args.hap)
    entries = {info.filename: info for info in zipped.infolist()}
    if len(entries) != len(zipped.infolist()):
        problems.append('The HAP has duplicate entries')
    read = zipped.read
    report['entries'] = len(entries)

    # Every library, as packaged, against what went in.
    libs = {name[len(LIB_DIR):] for name in entries if name.startswith(LIB_DIR)}
    if libs != LIBS:
        problems.append(f'libs: missing {sorted(LIBS - libs)}, extra {sorted(libs - LIBS)}')
    inputs = {name: args.native / name for name in ('libnode.so', 'libdsh_flock.so', 'libdsh_require_builtin.so')}
    inputs['libapp.so'] = args.aot / 'arm64-v8a/app.so'
    table = {}
    with args.hap.open('rb') as raw:
        for name in sorted(libs):
            info = entries[LIB_DIR + name]
            table[name] = {'bytes': info.file_size, 'packed': info.compress_size,
                           'stored': info.compress_type == zipfile.ZIP_STORED,
                           'offsetMod4096': data_offset(raw, info) % 4096, 'sha256': sha256(read(info))}
            if name in inputs:
                source = inputs[name].read_bytes()
                table[name].update(inputBytes=len(source), identicalToInput=sha256(source) == table[name]['sha256'],
                                   loadedBytesChanged=changes_outside_header(source, read(info)))
                if table[name]['loadedBytesChanged']:
                    problems.append(f"{name}: hvigor's pass changed {table[name]['loadedBytesChanged']} loaded bytes")
    report['libs'] = table

    with tempfile.TemporaryDirectory(prefix='audit-hap-') as temp:
        out = Path(temp) / 'all'
        out.mkdir()
        for name in libs:
            (out / name).write_bytes(read(LIB_DIR + name))
        # Node's side, under the same rules as the build; then the whole directory, where only
        # the Ark modules may break the rule that plain N-API belongs to libdsh_host.so alone.
        audit = load_audit()
        node_side = Path(temp) / 'node'
        node_side.mkdir()
        for name in libs - OUTSIDE_NODE:
            shutil.copy(out / name, node_side / name)
        found, detail = audit(node_side, args.sdk / 'native')
        problems += [f'native set: {item}' for item in found]
        report['nativeSetAudit'] = {'problems': found, **detail}
        found, detail = audit(out, args.sdk / 'native')
        expected = [f'{name} imports plain N-API, which only libdsh_host.so may do' for name in OUTSIDE_NODE]
        problems += [f'whole directory: {item}' for item in found if item not in expected]
        report['wholeDirectoryAudit'] = {'problems': found, 'expected': sorted(set(found) & set(expected)), **detail}
        # The bytes hvigor built, stripped and packaged; the audit above stops short of this gate.
        isolation = Path(temp) / 'napi-isolation.json'
        gate = subprocess.run([sys.executable, '-I', '-B', str(ROOT / 'runtime/ohos/host/napi_isolation.py'),
                               '--node-headers', str(args.node_headers),
                               '--rename-header', str(ROOT / 'runtime/ohos/node/napi-rename.h'),
                               '--libnode', str(out / 'libnode.so'),
                               '--readelf', str(args.sdk / 'native/llvm/bin/llvm-readelf'),
                               '--role', 'ark', '--consumer', str(out / 'libdsh_host.so'),
                               '--report', str(isolation)], capture_output=True, text=True)
        if gate.returncode != 0:
            problems.append(f'libdsh_host.so from the HAP fails the N-API gate: {gate.stderr.strip() or gate.stdout.strip()}')
        report['hostGate'] = json.loads(isolation.read_text()) if isolation.exists() else gate.stderr

        # What restool made of the resources, by id.
        dump = subprocess.run([str(args.sdk / 'toolchains/restool'), 'dump', str(args.hap)],
                              capture_output=True, text=True, check=True).stdout
    resources = {item['id']: item for item in json.loads(dump)['resource']}

    module = json.loads(read('module.json'))
    app, mod = module['app'], module['module']
    ability = mod['abilities'][0]
    report['moduleJson'] = {
        'bundleName': app['bundleName'], 'versionCode': app['versionCode'], 'versionName': app['versionName'],
        'debug': app['debug'], 'compileSdkType': app['compileSdkType'], 'compileSdkVersion': app['compileSdkVersion'],
        'minAPIVersion': app['minAPIVersion'], 'targetAPIVersion': app['targetAPIVersion'],
        'deviceTypes': mod['deviceTypes'], 'extractNativeLibs': mod.get('extractNativeLibs'),
        'compressNativeLibs': mod.get('compressNativeLibs', 'absent'), 'libIsolation': mod.get('libIsolation'),
        'launchType': ability['launchType'], 'requestPermissions': [item['name'] for item in mod.get('requestPermissions', [])],
    }
    if mod.get('extractNativeLibs') is not True or mod.get('libIsolation') is not False:
        problems.append('module.json must say extractNativeLibs true and libIsolation false: '
                        'RuntimeController reads applicationInfo.nativeLibraryPath as a directory')

    # Layered icon, resolved by id for both the app and the ability.
    icons = {}
    for owner, value in (('app', app.get('iconId')), ('ability', ability.get('iconId'))):
        item = resources.get(value)
        path = item['entryValues'][0]['value'] if item else None
        relative = path.split('/', 1)[1] if path else None
        icons[owner] = relative
        if not item or item['name'] != 'layered_image' or relative not in entries:
            problems.append(f'{owner} icon id {value} does not resolve to a packaged layered_image')
    report['icons'] = icons
    # restool rewrites the layers' $media:name references to $media:id.
    layered = json.loads(read('resources/base/media/layered_image.json'))['layered-image']
    report['layeredImage'] = {}
    for key in ('foreground', 'background'):
        item = resources.get(int(layered[key].split(':', 1)[1]))
        path = item['entryValues'][0]['value'].split('/', 1)[1] if item else None
        if path not in entries or read(path)[:8] != b'\x89PNG\r\n\x1a\n':
            problems.append(f'layered-image {key} {layered[key]} does not resolve to a packaged PNG')
        else:
            report['layeredImage'][key] = {'path': path, 'size': list(struct.unpack('>II', read(path)[16:24]))}

    # flutter_assets, byte for byte.
    assets = args.aot / 'flutter_assets'
    asset_files = [path for path in assets.rglob('*') if path.is_file()]
    bad = [path.relative_to(assets).as_posix() for path in asset_files
           if read(f'{RAWFILE}flutter_assets/{path.relative_to(assets).as_posix()}')
           != path.read_bytes()] if all(f'{RAWFILE}flutter_assets/{path.relative_to(assets).as_posix()}' in entries
                                        for path in asset_files) else ['entries missing']
    if bad:
        problems.append(f'flutter_assets differ: {bad[:10]}')
    report['flutterAssets'] = {'files': len(asset_files), 'bytes': sum(path.stat().st_size for path in asset_files)}
    if f'{RAWFILE}buildinfo.json5' not in entries:
        problems.append('rawfile/buildinfo.json5 is missing; FlutterLoader reads enable_impeller from it')
    report['buildinfo'] = json.loads(read(f'{RAWFILE}buildinfo.json5')) if f'{RAWFILE}buildinfo.json5' in entries else None

    # One Stored rawfile contains a bounded ZIP32 runtime. Audit the exact nested
    # bytes and every manifest member, including dotfiles hidden from restool.
    spec = importlib.util.spec_from_file_location('runtime_archive_audit', ROOT / 'tooling/ohos/runtime_archive_audit.py')
    runtime_audit = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime_audit)
    report['runtime'], runtime_problems = runtime_audit.audit_runtime(zipped, args.runtime)
    problems += runtime_problems
    rawfile = [info for info in zipped.infolist() if info.filename.startswith(RAWFILE)]
    deflated = [info.filename for info in rawfile if info.compress_type != zipfile.ZIP_STORED]
    report['rawfile'] = {'entries': len(rawfile), 'bytes': sum(info.file_size for info in rawfile), 'deflated': len(deflated)}
    if deflated:
        problems.append(f'{len(deflated)} rawfile entries are compressed; getRawFd serves them by offset')

    report['problems'] = problems
    args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print(f"HAP {report['bytes']} bytes, sha256 {report['sha256']}, {report['entries']} entries")
    for name, row in table.items():
        same = '' if 'identicalToInput' not in row else ('  identical to input' if row['identicalToInput']
                                                        else f"  from {row['inputBytes']} input bytes, "
                                                             f"{row['loadedBytesChanged']} loaded bytes changed")
        print(f"  {name}: {row['bytes']} bytes, {'stored' if row['stored'] else 'deflated'}, "
              f"offset%4096={row['offsetMod4096']}{same}")
    print(f"  module.json: {json.dumps(report['moduleJson'])}")
    print(f"  flutter_assets: {report['flutterAssets']}; runtime: {report['runtime']}; rawfile: {report['rawfile']}")
    for problem in problems:
        print(f'PROBLEM {problem}')
    print(f"audit-hap: {'OK' if not problems else 'FAILED'}; details in {args.report}; signing and the device NOT_RUN")
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
