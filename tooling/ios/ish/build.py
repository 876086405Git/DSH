#!/usr/bin/env python3
"""Pinned iSH kernel and confined C backend. Apple compilation remains a CI gate."""
import hashlib
import json
import os
import pathlib
import plistlib
import platform
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
LOCK = json.loads((HERE / 'source.lock.json').read_text())
SDK_NAMES = ('iphoneos', 'iphonesimulator', 'linux')
CACHE = ROOT / 'app/ios/Engine/ish-cache'
NATIVE = ROOT / 'runtime/ios/guest/native'


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def output(args):
    return subprocess.check_output(args, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_key(sdk):
    inputs = [HERE.parent / 'build-ish.sh', HERE.parent / 'build-guest-addon.sh'] + sorted(p for p in HERE.rglob('*')
              if p.is_file() and '__pycache__' not in p.parts)
    inputs += sorted(p for p in NATIVE.iterdir() if p.is_file())
    data = [(str(p.relative_to(ROOT)), digest(p)) for p in inputs]
    cross = os.environ.get('DSH_ISH_LINUX_CROSS_FILE') if sdk == 'linux' else None
    if cross:
        data.append(('linux_cross', digest(pathlib.Path(cross))))
    return hashlib.sha256(json.dumps([sdk, data], sort_keys=True).encode()).hexdigest()


def target_identity(sdk):
    identity = {'schema': 2, 'inputs': source_key(sdk), 'sdk': sdk}
    if sdk != 'linux':
        identity['xcode'] = output(['xcodebuild', '-version'])
        identity['sdk_version'] = output(['xcrun', '--sdk', sdk, '--show-sdk-version'])
        compiler = output(['xcrun', '--sdk', sdk, '--find', 'clang'])
        identity['compiler'] = output([compiler, '--version'])
    return identity


def producer_identity():
    # Provenance and CI cache partitioning only. Reusing verified bytes does not
    # require the tools that originally produced them to remain installed.
    return {tool: output([tool, '--version']).splitlines()[0]
            for tool in ('clang', 'ld.lld', 'meson', 'ninja') if shutil.which(tool)}


def cache_key(sdk):
    return hashlib.sha256(json.dumps([target_identity(sdk), producer_identity()],
                                    sort_keys=True).encode()).hexdigest()


def verified_receipt(out, identity):
    try:
        saved = json.loads((out / '.ish-build.json').read_text())
        if not isinstance(saved, dict) or saved.get('identity') != identity:
            return False
        products = saved.get('products')
        required = ({'DshGuest.so', 'libvdso.so.elf'} if identity['sdk'] == 'linux' else
                    {'DshGuest.framework/' + name for name in (
                        'DshGuest', 'Info.plist', 'LICENSE.txt', 'SOURCE.txt',
                        'iSH-LICENSE.md', 'iSH-LICENSE.IOS', 'iSH-build.patch',
                        'iSH-job-runtime.patch')})
        if not isinstance(products, dict) or not required.issubset(products):
            return False
        for name, sha in products.items():
            path = pathlib.Path(name)
            if path.is_absolute() or '..' in path.parts or not isinstance(sha, str):
                return False
            if not (out / path).is_file() or digest(out / path) != sha:
                return False
        return True
    except (ValueError, OSError, TypeError):
        return False


def require_build_tools(sdk, out):
    missing = [tool for tool in ('clang', 'ld.lld', 'meson', 'ninja', 'patch')
               if not shutil.which(tool)]
    if missing:
        import shlex
        command = 'tooling/ios/build-ish.sh ' + shlex.quote(sdk) + ' ' + shlex.quote(str(out))
        remedy = ('brew install llvm lld meson ninja; '
                  'export PATH="$(brew --prefix llvm)/bin:$(brew --prefix lld)/bin:$PATH"; ' + command
                  if sdk != 'linux' else 'Install clang, lld, meson, ninja and patch; then run ' + command)
        raise RuntimeError('No valid iSH output receipt; rebuild tools missing: ' +
                           ', '.join(missing) + '. Run: ' + remedy)


def verify_vdso(path):
    data = path.read_bytes()
    if (len(data) < 64 or data[:7] != b'\x7fELF\x02\x01\x01' or
            struct.unpack_from('<HHI', data, 16) != (3, 183, 1)):
        raise RuntimeError('VDSO must be a real ELF64 AArch64 ET_DYN image')
    return digest(path)


def download():
    CACHE.mkdir(parents=True, exist_ok=True)
    archive = CACHE / (LOCK['commit'] + '.tar.gz')
    if not archive.exists():
        with tempfile.NamedTemporaryFile(dir=CACHE, delete=False) as dest:
            tmp = pathlib.Path(dest.name)
            try:
                with urllib.request.urlopen(LOCK['url'], timeout=120) as src:
                    size = 0
                    while chunk := src.read(1024 * 1024):
                        size += len(chunk)
                        if size > 100 * 1024 * 1024:
                            raise RuntimeError('iSH source exceeds 100 MiB')
                        dest.write(chunk)
                dest.flush()
                if digest(tmp) != LOCK['sha256']:
                    raise RuntimeError('iSH source SHA256 mismatch')
                tmp.replace(archive)
            finally:
                tmp.unlink(missing_ok=True)
    if digest(archive) != LOCK['sha256']:
        raise RuntimeError('cached iSH source SHA256 mismatch; remove corrupt archive')
    return archive


def extract_source(tar, destination):
    """The pinned source contains only directories and regular files (Python 3.9)."""
    destination = pathlib.Path(destination)
    if destination.is_symlink() or not destination.is_dir() or any(destination.iterdir()):
        raise RuntimeError('iSH extraction requires an empty private directory')
    root = destination.resolve()
    prefix = 'ish-arm64-' + LOCK['commit']
    members = tar.getmembers()
    paths = {}
    # Validate the whole namespace before creating anything. Never delegate link
    # handling to tarfile: the fixed upstream archive has no links or devices.
    for member in members:
        name = member.name.rstrip('/')
        parts = pathlib.PurePosixPath(name).parts
        if (not parts or parts[0] != prefix or name != '/'.join(parts) or
                any(part in ('.', '..') or ':' in part for part in parts) or
                '\\' in name or '\x00' in name or name in paths):
            raise RuntimeError('invalid or duplicate iSH source path: ' + member.name)
        if not (member.isdir() or member.isreg()) or member.issparse():
            raise RuntimeError('unsupported iSH source member: ' + member.name)
        if member.isreg() and (member.name.endswith('/') or member.size < 0):
            raise RuntimeError('invalid iSH source file: ' + member.name)
        paths[name] = member
    for name in paths:
        for parent in pathlib.PurePosixPath(name).parents:
            if str(parent) in paths and not paths[str(parent)].isdir():
                raise RuntimeError('iSH source parent is not a directory: ' + str(parent))
    for name, member in paths.items():
        target = root.joinpath(*pathlib.PurePosixPath(name).parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        # Only our regular files/directories can exist inside this initially
        # empty staging root; reject pre-existing symlinks if it was altered.
        for parent in (target, *target.parents):
            if parent == root:
                break
            if parent.is_symlink():
                raise RuntimeError('symlink in iSH extraction path')
        if member.isdir():
            target.mkdir(exist_ok=True)
        else:
            with tar.extractfile(member) as source, target.open('xb') as dest:
                shutil.copyfileobj(source, dest)
            target.chmod(member.mode & 0o777)
            os.utime(target, (member.mtime, member.mtime))
    # Set directory permissions/timestamps after children have been written.
    for name, member in reversed(list(paths.items())):
        if member.isdir():
            target = root.joinpath(*pathlib.PurePosixPath(name).parts)
            target.chmod(member.mode & 0o777)
            os.utime(target, (member.mtime, member.mtime))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--cache-key' and sys.argv[2] in SDK_NAMES:
        print(cache_key(sys.argv[2]))
        return
    if len(sys.argv) != 3 or sys.argv[1] not in SDK_NAMES:
        raise SystemExit('usage: build-ish.sh iphoneos|iphonesimulator|linux OUTPUT_DIR; --cache-key SDK')
    sdk = sys.argv[1]
    out = pathlib.Path(sys.argv[2]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    apple = sdk != 'linux'
    identity = target_identity(sdk)
    receipt = out / '.ish-build.json'
    if verified_receipt(out, identity):
        print('iSH build cache verified:', out)
        return
    require_build_tools(sdk, out)
    producer = producer_identity()
    if apple:
        sysroot = output(['xcrun', '--sdk', sdk, '--show-sdk-path'])
    archive = download()
    # Re-extract verified source on misses; never trust a previously patched tree.
    with tempfile.TemporaryDirectory(prefix='ish-build-', dir=out) as tmp:
        work = pathlib.Path(tmp)
        with tarfile.open(archive) as tar:
            extract_source(tar, work)
        source = work / ('ish-arm64-' + LOCK['commit'])
        for name, expected in LOCK['buildInputs'].items():
            if digest(source / name) != expected:
                raise RuntimeError('upstream build input mismatch: ' + name)
        for patch in ('build.patch', 'job-runtime.patch'):
            run(['patch', '--batch', '--fuzz=0', '-p1', '-i', HERE / patch], cwd=source)
        native = source / 'dsh-native'
        native.mkdir()
        for path in NATIVE.iterdir():
            if path.suffix in ('.c', '.h'):
                shutil.copy2(path, native / path.name)
        build = work / 'build'
        setup = ['meson', 'setup', build, source, '--wrap-mode=nodownload',
                 '-Ddefault_library=static', '-Dguest_arch=arm64', '-Dkernel=ish',
                 '-Djit=false', '-Dbuildtype=release', '-Db_staticpic=true']
        env = os.environ.copy()
        env['CC'] = shutil.which('clang')
        if apple:
            target = 'arm64-apple-ios15.0' + ('-simulator' if sdk == 'iphonesimulator' else '')
            compiler = output(['xcrun', '--sdk', sdk, '--find', 'clang'])
            archiver = output(['xcrun', '--sdk', sdk, '--find', 'ar'])
            cross = work / 'apple.ini'
            args = ['-target', target, '-isysroot', sysroot]
            cross.write_text('[binaries]\nc = ' + repr(compiler) + '\nar = ' + repr(archiver) +
                "\n[host_machine]\nsystem = 'darwin'\ncpu_family = 'aarch64'\ncpu = 'aarch64'\nendian = 'little'\n" +
                '[properties]\nneeds_exe_wrapper = true\n[built-in options]\nc_args = ' + repr(args) +
                '\nc_link_args = ' + repr(args) + '\n')
            setup += ['--cross-file', cross]
        if not apple:
            cross = os.environ.get('DSH_ISH_LINUX_CROSS_FILE')
            if cross:
                setup += ['--cross-file', pathlib.Path(cross).resolve()]
            elif platform.machine() not in ('aarch64', 'arm64'):
                raise RuntimeError('ARM64 guest requires a Linux ARM64 host or DSH_ISH_LINUX_CROSS_FILE')
        run(setup, env=env)
        targets = ['DshGuest']
        run(['meson', 'compile', '-C', build, *targets], env=env)
        vdso = build / 'vdso/arm64/libvdso.so.elf'
        vdso_sha = verify_vdso(vdso)
        if apple:
            framework = out / 'DshGuest.framework'
            if framework.exists():
                shutil.rmtree(framework)
            framework.mkdir()
            shutil.copy2(build / 'DshGuest.dylib', framework / 'DshGuest')
            info = dict(CFBundleExecutable='DshGuest', CFBundleIdentifier='io.github.ccch1mneyyy.dshgo.guest',
                CFBundleName='DshGuest', CFBundlePackageType='FMWK', CFBundleShortVersionString='1.0',
                CFBundleVersion='1', MinimumOSVersion='15.0',
                CFBundleSupportedPlatforms=['iPhoneOS' if sdk == 'iphoneos' else 'iPhoneSimulator'])
            (framework / 'Info.plist').write_bytes(plistlib.dumps(info))
            for name in ('LICENSE.txt', 'SOURCE.txt'):
                shutil.copy2(HERE / name, framework / name)
            shutil.copy2(source / 'LICENSE.md', framework / 'iSH-LICENSE.md')
            shutil.copy2(source / 'LICENSE.IOS', framework / 'iSH-LICENSE.IOS')
            shutil.copy2(HERE / 'build.patch', framework / 'iSH-build.patch')
            shutil.copy2(HERE / 'job-runtime.patch', framework / 'iSH-job-runtime.patch')
            products = {str(p.relative_to(out)): digest(p) for p in framework.rglob('*') if p.is_file()}
        else:
            products = {}
            for name in ('libish.a', 'libish_emu.a', 'libfakefs.a'):
                (out / name).unlink(missing_ok=True)  # Meson thin archives reference temporary objects.
            for name in ('DshGuest.so',):
                shutil.copy2(build / name, out / name)
                products[name] = digest(out / name)
            shutil.copy2(vdso, out / 'libvdso.so.elf')
            products['libvdso.so.elf'] = vdso_sha
        pending = receipt.with_suffix('.tmp')
        pending.write_text(json.dumps({'identity': identity, 'products': products,
            'producer': producer, 'upstream': LOCK, 'vdso_sha256': vdso_sha}, indent=2) + '\n')
        pending.replace(receipt)
        print('iSH build verified:', receipt)


if __name__ == '__main__':
    main()
