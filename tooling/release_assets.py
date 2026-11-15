#!/usr/bin/env python3
"""Prepare GitHub release assets for an in-app update (see docs/release.md).

Takes the version name from app/pubspec.yaml and the build number from the
APKs themselves (aapt2), copies them to dist/ under their release names, and
writes SHA256SUMS and update.json next to them. The default release contains
arm64 only; explicit flavor inputs remain available for local testing. Build
with `tooling/build-apk.sh` first. Explicit multiple inputs must share a build number.

It also makes delta patches (tooling/apk_delta.py, docs/design/delta-update.md)
from the arm64 APKs of the last --delta-from releases on GitHub (fetched with
`gh`, kept in ~/.cache/dshgo-release/apk/, checked against their SHA256SUMS),
and keeps those under 60 % of the new APK: in dist/, SHA256SUMS and update.json's
`patches`.

    python3 tooling/release_assets.py --notes notes.md
    python3 tooling/release_assets.py --notes notes.md --base-url https://cdn.example.com/dsh/1.2.0/
    python3 tooling/release_assets.py --delta-from 0        no patches, no network

--base-url makes update.json point at your own host (self-hosted feed); without
it the app derives GitHub download URLs from the tag and asset names.
"""

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import zipfile

import apk_delta
from check_apk_jni import ApkJniError, check_apk_jni
from build_number import MAX_VERSION_CODE, decode

ROOT = pathlib.Path(__file__).resolve().parent.parent
FLAVORS = ("arm64", "x64")
FLAVOR_ABI = {"arm64": "arm64-v8a", "x64": "x86_64"}
REPO = "ccch1mneyyy/dsh-go"
VERSION_RE = re.compile(r"^(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:\+(\d+))?$")
BADGING_RE = re.compile(r"^package: .*?\bversionCode='(\d*)' versionName='([^']*)'", re.MULTILINE)
CACHE = pathlib.Path.home() / ".cache" / "dshgo-release" / "apk"
# A patch this big saves too little to be worth a second download path.
PATCH_LIMIT = 0.6


class ReleaseError(Exception):
    pass


def check_abis(flavor: str, entries: list[str]) -> None:
    """A flavor's APK holds native libraries for its own ABI and no other."""
    abis = {name.split("/")[1] for name in entries if name.startswith("lib/") and name.endswith(".so")}
    if abis != {FLAVOR_ABI[flavor]}:
        raise ReleaseError(f"{flavor} APK has native libraries for {sorted(abis)}, expected only {FLAVOR_ABI[flavor]}")


def pubspec_version() -> str:
    text = (ROOT / "app" / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*(\S+)", text, re.MULTILINE)
    if not match:
        sys.exit("version: not found in app/pubspec.yaml")
    return match.group(1)


def find_aapt2() -> str | None:
    """aapt2 on PATH, else the newest one in the Android SDK's build-tools."""
    found = shutil.which("aapt2")
    if found:
        return found
    sdks = [os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT")]
    props = ROOT / "app" / "android" / "local.properties"
    if props.is_file():
        match = re.search(r"^sdk\.dir=(.+)$", props.read_text(encoding="utf-8"), re.MULTILINE)
        if match:
            # local.properties uses Java escapes; environment paths do not.
            sdks.append(re.sub(
                r"(?:\\u[0-9a-fA-F]{4})+|\\([\\: =#!])",
                lambda escaped: escaped[1] if escaped[1] is not None else
                    bytes.fromhex(escaped[0].replace(r"\u", "")).decode("utf-16-be", "surrogatepass"),
                match.group(1).strip(),
            ))
    for sdk in filter(None, sdks):
        tools = sorted(
            pathlib.Path(sdk).glob("build-tools/*/aapt2" + (".exe" if sys.platform == "win32" else "")),
            key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.parent.name)),
        )
        if tools:
            return str(tools[-1])
    return None


def apk_version(aapt2: str, path: pathlib.Path) -> tuple[str, int]:
    """(versionName, versionCode) as the APK's manifest says."""
    out = subprocess.run([aapt2, "dump", "badging", str(path)], capture_output=True, text=True).stdout
    match = BADGING_RE.search(out)
    if not match:
        raise ReleaseError(f"{path}: aapt2 could not read its manifest")
    return match.group(2), int(match.group(1) or 0)


def release_build(name: str, expected: int | None, apks: dict[str, tuple[str, int]]) -> int:
    """The build number (versionCode) of the release, once the APKs agree with
    [name], with each other and with [expected] (`--version X.Y.Z+N`)."""
    for flavor, (apk_name, _) in sorted(apks.items()):
        if apk_name != name:
            raise ReleaseError(f"{flavor}: the APK is version {apk_name!r}, the release is {name!r}")
    codes = sorted({code for _, code in apks.values()})
    if len(codes) != 1:
        found = ", ".join(f"{flavor} {code}" for flavor, (_, code) in sorted(apks.items()))
        raise ReleaseError(f"flavors have different build numbers ({found}); rebuild with tooling/build-apk.sh -f all")
    code = codes[0]
    if not 1 < code <= MAX_VERSION_CODE:
        raise ReleaseError(f"versionCode {code} is a placeholder; build with tooling/build-apk.sh")
    if expected is not None and expected != code:
        raise ReleaseError(f"--version says +{expected} but the APKs are {code}")
    return code


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def gh(*args: str) -> str:
    run = subprocess.run(["gh", *args, "--repo", REPO], capture_output=True, text=True)
    if run.returncode:
        raise ReleaseError(f"gh {' '.join(args[:2])} failed: {run.stderr.strip()} (--delta-from 0 makes no patches)")
    return run.stdout


def previous_releases(tag: str, count: int) -> list[str]:
    """The tags of the [count] newest published releases other than [tag]."""
    releases = json.loads(gh("release", "list", "--exclude-drafts", "--limit", "50", "--json", "tagName,publishedAt"))
    releases.sort(key=lambda r: r["publishedAt"], reverse=True)
    return [r["tagName"] for r in releases if r["tagName"] != tag][:count]


def listed(sums: pathlib.Path, name: str) -> str | None:
    """The SHA-256 that the SHA256SUMS file [sums] gives [name]."""
    if sums.is_file():
        for line in sums.read_text(encoding="utf-8").splitlines():
            digest, _, file = line.partition(" ")
            if file.lstrip(" *") == name:
                return digest.lower()
    return None


def published_apk(tag: str, cache: pathlib.Path) -> pathlib.Path:
    """[tag]'s arm64 APK from its GitHub release, kept in [cache], as the
    release's SHA256SUMS says it is."""
    name = f"dsh-go-{tag.removeprefix('v')}-arm64.apk"
    apk, sums = cache / tag / name, cache / tag / "SHA256SUMS"
    if not (apk.is_file() and listed(sums, name) == sha256(apk)):
        gh("release", "download", tag, "--pattern", name, "--pattern", "SHA256SUMS", "--dir", str(cache / tag), "--clobber")
        if listed(sums, name) != sha256(apk):
            raise ReleaseError(f"{tag}: {name} doesn't match the release's SHA256SUMS")
    return apk


def base_layer_sha256(path: pathlib.Path) -> str | None:
    """The actual base archive digest; legacy APKs have no separate base to compare."""
    with zipfile.ZipFile(path) as apk:
        manifest = "assets/runtime/manifest.json"
        if manifest not in apk.namelist():
            return None
        manifest = json.loads(apk.read(manifest))
        if manifest.get("schema") != 2:
            return None
        digest = hashlib.sha256()
        with apk.open("assets/runtime/" + manifest["layers"]["base"]["asset"]) as stream:
            for chunk in iter(lambda: stream.read(1 << 20), b""):
                digest.update(chunk)
        return digest.hexdigest()


def patch_from(old: pathlib.Path, old_version: str, new: pathlib.Path, name: str, out: pathlib.Path) -> dict | None:
    """The patch from [old] (version X.Y.Z+N) to the arm64 APK [new] of
    version [name], written to [out]; None, and nothing written, unless it's
    under PATCH_LIMIT of [new]."""
    old_base = base_layer_sha256(old)
    if old_base is not None:
        new_base = base_layer_sha256(new)
        if new_base is not None and old_base != new_base:
            print(f"WARNING: base layer SHA-256 changed from {old_version}: {old_base} -> {new_base}; delta savings may be reduced")
    patch = out / f"dsh-go-{name}-from-{old_version.partition('+')[0]}-arm64.dshdelta"
    apk_delta.make(old, new, patch)
    size = patch.stat().st_size
    share = size / new.stat().st_size
    print(f"patch from {old_version}: {size} bytes, {share:.0%} of the APK{'' if share < PATCH_LIMIT else ', left out'}")
    if share >= PATCH_LIMIT:
        patch.unlink()
        return None
    return {"from": sha256(old), "fromVersion": old_version, "name": patch.name, "size": size, "sha256": sha256(patch)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--version",
        help="X.Y.Z[-pre][+build]; default: app/pubspec.yaml's name. The build number is read from the APKs; "
        "a +build given here must match them.",
    )
    parser.add_argument("--notes", type=pathlib.Path, help="Markdown release notes (shown in the app)")
    parser.add_argument("--out", type=pathlib.Path, default=ROOT / "dist")
    parser.add_argument("--base-url", help="absolute or relative URL prefix for the APKs in update.json")
    parser.add_argument(
        "--delta-from",
        type=int,
        default=3,
        metavar="N",
        help="patches from the arm64 APKs of the N newest releases on GitHub (default 3; 0: none)",
    )
    parser.add_argument(
        "apks",
        nargs="*",
        metavar="FLAVOR=PATH",
        help="default: arm64 only, app/build/app/outputs/flutter-apk/app-arm64-release.apk",
    )
    args = parser.parse_args()

    full = args.version or pubspec_version()
    match = VERSION_RE.match(full)
    if not match:
        sys.exit(f"not a release version: {full}")
    name = match.group(1)
    # pubspec's +N is a placeholder; only an explicit --version's +N is an expectation.
    expected = int(match.group(2)) if args.version and match.group(2) else None

    sources = {}
    for item in args.apks:
        flavor, _, path = item.partition("=")
        if flavor not in FLAVORS or not path:
            sys.exit(f"expected FLAVOR=PATH with FLAVOR in {FLAVORS}: {item}")
        sources[flavor] = pathlib.Path(path)
    if not sources:
        sources["arm64"] = ROOT / "app" / "build" / "app" / "outputs" / "flutter-apk" / "app-arm64-release.apk"
    for flavor, path in sources.items():
        if not path.is_file():
            sys.exit(f"{flavor}: {path} not found (build that flavor with tooling/build-apk.sh first)")

    aapt2 = find_aapt2()
    if not aapt2:
        sys.exit("aapt2 not found (Android SDK build-tools): it reads versionName and versionCode from the APKs")
    try:
        build = release_build(name, expected, {flavor: apk_version(aapt2, path) for flavor, path in sources.items()})
        for flavor, path in sources.items():
            with zipfile.ZipFile(path) as apk:
                check_abis(flavor, apk.namelist())
            check_apk_jni(path)
    except (ReleaseError, ApkJniError) as e:
        sys.exit(str(e))

    args.out.mkdir(parents=True, exist_ok=True)
    assets = {}
    sums = []
    for flavor, path in sources.items():
        asset = f"dsh-go-{name}-{flavor}.apk"
        target = args.out / asset
        shutil.copyfile(path, target)
        digest = sha256(target)
        sums.append(f"{digest}  {asset}")
        entry = {"name": asset, "size": target.stat().st_size, "sha256": digest}
        if args.base_url:
            entry["url"] = args.base_url.rstrip("/") + "/" + asset
        assets[flavor] = entry

    tag = f"v{name}"
    for stale in args.out.glob("*.dshdelta"):
        stale.unlink()
    patches = []
    if args.delta_from and "arm64" in assets:
        try:
            for old_tag in previous_releases(tag, args.delta_from):
                old = published_apk(old_tag, CACHE)
                old_name, old_code = apk_version(aapt2, old)
                patch = patch_from(old, f"{old_name}+{old_code}", args.out / assets["arm64"]["name"], name, args.out)
                if patch:
                    patches.append(patch)
        except (ReleaseError, apk_delta.DeltaError) as e:
            sys.exit(str(e))
    sums += [f"{patch['sha256']}  {patch['name']}" for patch in patches]
    (args.out / "SHA256SUMS").write_text("\n".join(sums) + "\n", encoding="utf-8", newline="\n")

    manifest = {
        "schema": 1,
        "version": f"{name}+{build}",
        "tag": tag,
        "title": f"DSH Go {name}",
        "publishedAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "notes": args.notes.read_text(encoding="utf-8").strip() if args.notes else "",
        "page": f"https://github.com/{REPO}/releases/tag/{tag}",
        "assets": assets,
    }
    if patches:
        manifest["patches"] = {"arm64": patches}
    (args.out / "update.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")

    try:
        built = f"{decode(build):%Y-%m-%d %H:%M} UTC+8"
    except ValueError:
        built = "custom build number"
    print(f"DSH Go {name}+{build} ({built})")
    print(f"{args.out}:")
    for line in sums:
        print("  " + line)
    print("  update.json")
    notes = f" --notes-file {args.notes}" if args.notes else ""
    print(f"\ngh release create {tag} {args.out}/* --repo {REPO} --title 'DSH Go {name}'{notes}")


if __name__ == "__main__":
    main()
