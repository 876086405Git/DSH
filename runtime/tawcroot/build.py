#!/usr/bin/env python3
"""Build libtawcroot.so (tawcroot launcher) for the APK from a pinned tawc commit.

The pinned sources, with the local bind-oracle fix, are compiled with the
project's NDK on Linux, macOS or Windows. The archive is verified before extraction.
Output: runtime/out-tawcroot/jniLibs/<abi>/libtawcroot.so (+ manifest.json),
picked up by app/android/app/build.gradle.kts. Without it the app still builds;
the tawcroot launch option then reports itself unavailable.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
RUNTIME = HERE.parent
sys.path.insert(0, str(RUNTIME / "lib"))
from rtbuild import Elf, apply_hunks, parse_unified_diff, stream_digest  # noqa: E402


ABIS = {
    "arm64-v8a": ("aarch64", 183, 0x2000000000),
    "x86_64": ("x86_64", 62, 0x40000000),
}
COMPILE_FLAGS = [
    "-O2", "-fno-strict-aliasing", "-fno-stack-protector",
    "-fvisibility=hidden", "-fno-exceptions",
    "-fno-asynchronous-unwind-tables", "-ffreestanding",
    "-Wall", "-Wextra", "-Werror", "-Wframe-larger-than=1024", "-Iinclude",
]
LINK_FLAGS = [
    "-static", "-nostdlib", "-nostartfiles", "-Wl,--build-id=none",
    "-Wl,-z,noexecstack", "-Wl,-z,relro", "-Wl,-z,max-page-size=16384",
]
HOSTS = {"linux": "linux-x86_64", "darwin": "darwin-x86_64", "win32": "windows-x86_64"}


def sha256(path):
    with path.open("rb") as stream:
        return stream_digest(stream)[0]


def cached_archive(source, cache, supplied=None, offline=False):
    """Return the pinned archive; never keep an unverified cache entry."""
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / (source["commit"] + ".zip")
    if supplied is None and target.exists():
        if sha256(target) != source["archiveSha256"]:
            raise ValueError("cached tawc archive has the wrong SHA-256; pass the original with --archive")
        return target
    if supplied is None and offline:
        raise ValueError("no cached tawc archive; import it with --archive")
    pending = cache / (source["commit"] + ".zip.part")
    try:
        stream = Path(supplied).open("rb") if supplied is not None else \
            urllib.request.urlopen(source["archiveUrl"], timeout=60)
        with stream, pending.open("wb") as out:
            shutil.copyfileobj(stream, out)
        if sha256(pending) != source["archiveSha256"]:
            raise ValueError("tawc archive SHA-256 mismatch; cache not updated")
        os.replace(pending, target)
    finally:
        pending.unlink(missing_ok=True)
    return target


def extract_source(archive, source, destination):
    """Only the production source/include trees and the MIT notice."""
    prefix = source["archiveRoot"] + "/"
    with zipfile.ZipFile(archive) as zipped:
        for member in zipped.infolist():
            if not member.filename.startswith(prefix) or member.is_dir():
                continue
            relative = member.filename[len(prefix):]
            if relative != "LICENSE.MIT" and not relative.startswith(
                    ("tawcroot/src/", "tawcroot/include/")):
                continue
            path = destination / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            with zipped.open(member) as incoming, path.open("wb") as outgoing:
                shutil.copyfileobj(incoming, outgoing)
    return destination / "tawcroot"


def apply_source_patch(runtime, source):
    """Patch the verified extraction, using the runtime's exact old-block rule."""
    patch = runtime / "tawcroot/bind-aware-oracle.diff"
    data = patch.read_bytes()
    for name, hunks in parse_unified_diff(data.decode("utf-8")):
        target = source / name
        original = target.read_bytes().decode("utf-8")
        target.write_bytes(apply_hunks(original, hunks, patch.name).encode("utf-8"))
    return {"path": "tawcroot/" + patch.name, "sha256": hashlib.sha256(data).hexdigest()}


def toolchain(ndk, source):
    host = HOSTS.get(sys.platform)
    if host is None or platform.machine().lower() not in ("x86_64", "amd64", "arm64"):
        raise ValueError(f"unsupported build host {sys.platform}/{platform.machine()}")
    ndk = Path(ndk).resolve()
    properties = {}
    for line in (ndk / "source.properties").read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            properties[key.strip()] = value.strip()
    if properties.get("Pkg.Revision") != source["ndkVersion"]:
        raise ValueError("needs NDK " + source["ndkVersion"])
    binary = ndk / "toolchains/llvm/prebuilt" / host / "bin"
    suffix = ".exe" if sys.platform == "win32" else ""
    tools = {name: binary / (name + suffix) for name in ("clang", "llvm-strip")}
    for path in tools.values():
        if not path.is_file():
            raise ValueError("missing NDK tool: " + str(path))
    return tools


def recipe(source, abi):
    arch, _, base = ABIS[abi]
    compile_flags = [f"--target={arch}-linux-android{source['androidApi']}"] + COMPILE_FLAGS + \
        (["-mno-outline-atomics"] if arch == "aarch64" else [])
    link_flags = [f"--target={arch}-linux-android{source['androidApi']}", "-fuse-ld=lld"] + LINK_FLAGS + \
        [f"-Wl,--image-base={hex(base)}", "-Wl,-soname,libtawcroot.so"]
    return {
        "compile": compile_flags,
        "link": link_flags,
        "sources": source["cSources"] + [
            f"src/arch/{arch}_stub.S", f"src/arch/{arch}_loader_jump.S",
        ],
    }


def audit_artifact(path, abi):
    data = path.read_bytes()
    elf = Elf(data)
    _, machine, base = ABIS[abi]
    if elf.bits != 64 or elf.type != 2 or elf.machine != machine:
        raise ValueError(abi + ": expected a 64-bit ET_EXEC for this ABI")
    interpreter = elf.interp()
    needed = elf.dyn_strings()["needed"]
    if interpreter is not None or needed:
        raise ValueError(abi + ": must have no PT_INTERP and no DT_NEEDED")
    loads = [segment for segment in elf.phdrs if segment["type"] == 1]
    if not loads or any(segment["align"] < 16384 or
                        segment["align"] % 16384 or
                        (segment["vaddr"] - segment["offset"]) % 16384
                        for segment in loads):
        raise ValueError(abi + ": PT_LOAD is not 16 KiB aligned")
    entry = struct.unpack_from("<Q", data, 24)[0]
    if not base <= entry <= base + 0x100000:
        raise ValueError(abi + ": entry point is not near the upstream image base")
    return {"abi": abi, "path": f"jniLibs/{abi}/libtawcroot.so",
            "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}


def publish(staged, output):
    """Replace the whole output at once; keep the previous one if that fails."""
    previous = output.with_name(output.name + ".previous")
    shutil.rmtree(previous, ignore_errors=True)
    if output.exists():
        os.replace(output, previous)
    try:
        os.replace(staged, output)
    except BaseException:
        if previous.exists() and not output.exists():
            os.replace(previous, output)
        raise
    shutil.rmtree(previous, ignore_errors=True)


def build(runtime, ndk, supplied=None, offline=False, output=None):
    source = json.loads((runtime / "tawcroot/source.json").read_text())
    tools = toolchain(ndk, source)
    archive = cached_archive(source, runtime / ".cache/tawcroot", supplied, offline)
    output = output or runtime / "out-tawcroot"
    work = runtime / ".work"
    work.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tawcroot-", dir=work) as scratch:
        scratch = Path(scratch)
        src = extract_source(archive, source, scratch / "source")
        source_patch = apply_source_patch(runtime, src)
        staged = scratch / "out"
        artifacts = []
        for abi in ABIS:
            selected = recipe(source, abi)
            objects = scratch / "objects" / abi
            objects.mkdir(parents=True)
            object_paths = []
            for name in selected["sources"]:
                obj = objects / (Path(name).name + ".o")
                subprocess.run([str(tools["clang"]), *selected["compile"], "-c", name, "-o", str(obj)],
                               cwd=src, check=True)
                object_paths.append(str(obj))
            artifact = staged / "jniLibs" / abi / "libtawcroot.so"
            artifact.parent.mkdir(parents=True)
            subprocess.run([str(tools["clang"]), *selected["link"], *object_paths, "-o", str(artifact)],
                           cwd=src, check=True)
            subprocess.run([str(tools["llvm-strip"]), str(artifact)], check=True)
            artifacts.append(audit_artifact(artifact, abi))
        manifest = {
            "schema": 1,
            "source": {key: source[key] for key in ("repo", "commit", "archiveSha256")},
            "sourcePatch": source_patch,
            "ndkVersion": source["ndkVersion"],
            "artifacts": artifacts,
        }
        (staged / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        publish(staged, output)
    return output


def default_ndk(runtime):
    """ANDROID_NDK_HOME, else <Android SDK>/ndk/<pinned version> (SDK from the environment or local.properties)."""
    if os.environ.get("ANDROID_NDK_HOME"):
        return os.environ["ANDROID_NDK_HOME"]
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    properties = runtime.parent / "app/android/local.properties"
    if not sdk and properties.is_file():
        for line in properties.read_text(encoding="utf-8").splitlines():
            if line.startswith("sdk.dir="):
                # local.properties uses Java escapes; environment paths do not.
                sdk = re.sub(
                    r"(?:\\u[0-9a-fA-F]{4})+|\\([\\: =#!])",
                    lambda escaped: escaped[1] if escaped[1] is not None else
                        bytes.fromhex(escaped[0].replace(r"\u", "")).decode("utf-16-be", "surrogatepass"),
                    line[len("sdk.dir="):],
                )
    if not sdk:
        return None
    return str(Path(sdk) / "ndk" / json.loads((runtime / "tawcroot/source.json").read_text())["ndkVersion"])


def main():
    parser = argparse.ArgumentParser(description="Build libtawcroot.so from the pinned tawc commit")
    parser.add_argument("--ndk", default=default_ndk(RUNTIME),
                        help="NDK 28.2.13676358 (default: ANDROID_NDK_HOME, else the Android SDK's ndk/)")
    parser.add_argument("--archive", type=Path, help="import the pinned source ZIP (SHA-256 checked)")
    parser.add_argument("--offline", action="store_true", help="never download; use the cache or --archive")
    args = parser.parse_args()
    if not args.ndk:
        parser.error("no NDK: pass --ndk, or set ANDROID_NDK_HOME or ANDROID_HOME")
    try:
        output = build(RUNTIME, args.ndk, args.archive, args.offline)
    except (OSError, ValueError, struct.error, zipfile.BadZipFile,
            subprocess.CalledProcessError) as error:
        print("tawcroot build failed: " + str(error), file=sys.stderr)
        return 1
    print("tawcroot: " + str(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
