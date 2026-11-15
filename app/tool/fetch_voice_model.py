#!/usr/bin/env python3
"""Prepares the bundled dictation model (#716) for a build.

The SenseVoice weights (~228 MB) and the sherpa-onnx native libraries (~30 MB) are
too big for the repository, so they are gitignored and fetched here instead. Every
download is checked against `assets/voice/model.lock.json`, and a file that is
already present and correct is left alone, so this is safe to re-run.

    python app/tool/fetch_voice_model.py            # fill in what is missing
    python app/tool/fetch_voice_model.py --check    # verify only, download nothing

Exit codes: 0 = ready, 1 = something is missing or wrong, 2 = usage error.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import shutil
import sys
import tempfile
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)
ANDROID = os.path.join(APP, "android", "app", "src", "main")
VOICE = os.path.join(ANDROID, "assets", "voice")
JNI = os.path.join(ANDROID, "jniLibs")
LOCK = os.path.join(VOICE, "model.lock.json")

CHUNK = 1 << 20
USER_AGENT = "dsh-go-build/1.0 (+https://github.com/ccch1mneyyy/dsh-Go)"


def digest(path: str) -> str:
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(CHUNK)
            if not block:
                break
            hasher.update(block)
    return hasher.hexdigest()


def download(url: str, target: str, expected_bytes: int, expected_sha: str) -> bool:
    """Downloads url to target. Returns True when the result verifies."""
    os.makedirs(os.path.dirname(target), exist_ok=True)
    staging = target + ".part"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=60) as response, open(staging, "wb") as out:
            total = 0
            while True:
                block = response.read(CHUNK)
                if not block:
                    break
                out.write(block)
                total += len(block)
                if expected_bytes:
                    percent = min(100, total * 100 // expected_bytes)
                    sys.stdout.write("\r  %s: %d%%" % (os.path.basename(target), percent))
                    sys.stdout.flush()
        sys.stdout.write("\n")
    except Exception as error:  # noqa: BLE001 - report and let the caller decide
        print("  download failed: %s" % error)
        if os.path.exists(staging):
            os.remove(staging)
        return False

    if expected_bytes and os.path.getsize(staging) != expected_bytes:
        print("  size mismatch: got %d, want %d" % (os.path.getsize(staging), expected_bytes))
        os.remove(staging)
        return False
    if expected_sha and digest(staging) != expected_sha:
        print("  sha256 mismatch")
        os.remove(staging)
        return False
    os.replace(staging, target)
    return True


def ensure_asset(entry: dict, check_only: bool) -> bool:
    name = entry["name"]
    target = os.path.join(VOICE, name)
    if os.path.exists(target):
        if entry.get("bytes") and os.path.getsize(target) != entry["bytes"]:
            print("%s: wrong size, refetching" % name)
        elif entry.get("sha256") and digest(target) != entry["sha256"]:
            print("%s: wrong hash, refetching" % name)
        else:
            print("%s: ok" % name)
            return True
    if check_only:
        print("%s: MISSING" % name)
        return False
    for url in entry["urls"]:
        print("%s: downloading from %s" % (name, url.split("/")[-1]))
        if download(url, target, entry.get("bytes", 0), entry.get("sha256", "")):
            print("%s: ok" % name)
            return True
    print("%s: could not be fetched" % name)
    return False


def ensure_native(check_only: bool) -> bool:
    spec = json.load(io.open(LOCK, encoding="utf-8"))["sherpaOnnx"]
    wanted = [(abi, lib) for abi in spec["abis"] for lib in spec["libraries"]]
    missing = [pair for pair in wanted if not os.path.exists(os.path.join(JNI, pair[0], pair[1]))]
    if not missing:
        print("native libs: ok")
        return True
    if check_only:
        print("native libs: MISSING %s" % ", ".join("%s/%s" % pair for pair in missing))
        return False

    cache = os.path.join(tempfile.gettempdir(), "dsh-go-sherpa-%s.aar" % spec["tag"])
    if not os.path.exists(cache) or digest(cache) != spec["aarSha256"]:
        print("native libs: fetching sherpa-onnx %s" % spec["tag"])
        if not download(spec["aarUrl"], cache, 0, spec["aarSha256"]):
            print("native libs: AAR unavailable")
            return False
    with zipfile.ZipFile(cache) as archive:
        for abi, lib in missing:
            member = "jni/%s/%s" % (abi, lib)
            target = os.path.join(JNI, abi, lib)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with archive.open(member) as source, open(target, "wb") as out:
                shutil.copyfileobj(source, out)
            print("native libs: %s/%s ok" % (abi, lib))
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch the bundled dictation model.")
    parser.add_argument("--check", action="store_true", help="verify only, download nothing")
    args = parser.parse_args()

    if not os.path.exists(LOCK):
        print("missing %s" % LOCK)
        return 2
    lock = json.load(io.open(LOCK, encoding="utf-8"))

    ok = all(ensure_asset(entry, args.check) for entry in lock["assets"])
    ok = ensure_native(args.check) and ok
    print("\n%s" % ("ready" if ok else "incomplete"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
