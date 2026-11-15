#!/usr/bin/env python3
"""Android recipe suffix input, preserving the reviewed baseline's identity.

locks/android-recipe-compat.json names the baseline; merging a newer one means
regenerating that table. It aliases only exact reviewed source digests. Unknown
source changes use their actual digest; it is not a fixed runtime version.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def recipe_inputs(runtime, version):
    compatibility = json.loads((runtime / "locks/android-recipe-compat.json").read_text())
    spec = importlib.util.spec_from_file_location("rtbuild", runtime / "lib/rtbuild.py")
    rtbuild = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rtbuild)
    pins = json.loads((runtime / "patches/pins.json").read_text())
    names, _ = rtbuild.select_dsh_patches(pins, str(runtime / "patches"), "android")
    selected = {"version": version, "patches": {
        name: pins["patches"][name][version] for name in names}}
    pins_digest = hashlib.sha256(json.dumps(selected, sort_keys=True,
                                           separators=(",", ":")).encode()).hexdigest()
    if pins_digest == compatibility["pinsCanonicalSha256"]:
        pins_digest = compatibility["pinsLegacySha256"]

    out = []
    for name in ("build-runtime.sh", "lib/rtbuild.py"):
        actual = digest(runtime / name)
        approved = compatibility["sources"][name]
        out.append((approved["legacySha256"] if actual == approved["sha256"] else actual) + "\n")

    # Recreate GNU find/sort/sha256sum's legacy path order, with only Android
    # diffs and their active-version pins. Documentation and OHOS inputs do not
    # affect an Android image. Keep sha256sum's own filename escaping.
    paths = {"patches/" + name for name in names}
    paths.add("patches/pins.json")
    paths.add("patches/series")
    for directory in ("bridge", "boot", "direct"):
        root = runtime / directory
        if not root.is_dir():
            raise FileNotFoundError(root)
        paths.update(path.relative_to(runtime).as_posix() for path in root.rglob("*")
                     if path.is_file() and not path.is_symlink())

    # These were absent from the old recipe. Preserve its baseline, but never
    # hide a changed helper or a changed source-owned companion in a future build.
    if digest(runtime / "lib/android_recipe.py") != compatibility["helperSha256"]:
        paths.add("lib/android_recipe.py")
    if "zzzzzz-session-deletion.diff" in names:
        name = "session-deletion/core.mjs"
        if digest(runtime / name) != compatibility["companionSha256"]:
            paths.add(name)
    for name in sorted(paths, key=os.fsencode):
        if name == "patches/pins.json":
            out.append(pins_digest + "  patches/pins.json\n")
        else:
            out.append(subprocess.check_output(["sha256sum", "--", name],
                                              cwd=runtime).decode())
    return "".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dsh-version", required=True)
    args = parser.parse_args()
    print(recipe_inputs(Path(__file__).resolve().parents[1], args.dsh_version), end="")


if __name__ == "__main__":
    main()
