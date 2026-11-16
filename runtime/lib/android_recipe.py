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


def canonical(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def recipe_inputs(runtime, version):
    compatibility = json.loads((runtime / "locks/android-recipe-compat.json").read_text())
    spec = importlib.util.spec_from_file_location("rtbuild", runtime / "lib/rtbuild.py")
    rtbuild = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rtbuild)
    pins = json.loads((runtime / "patches/pins.json").read_text())
    names, _ = rtbuild.select_dsh_patches(pins, str(runtime / "patches"), "android")

    def source(name):
        """An exact reviewed source keeps the baseline's digest; anything else is itself."""
        actual = digest(runtime / name)
        approved = compatibility["sources"].get(name)
        return approved["legacySha256"] if approved and actual == approved["sha256"] else actual

    # What Android takes from pins.json and series: its active-version pins and its
    # application order. OHOS entries and lines, other versions and JSON layout don't count.
    pins_digest = canonical({"version": version, "patches": {
        name: pins["patches"][name][version] for name in names}})
    if pins_digest == compatibility["pinsCanonicalSha256"]:
        pins_digest = compatibility["pinsLegacySha256"]
    series_digest = canonical(names)
    if series_digest == compatibility["seriesCanonicalSha256"]:
        series_digest = compatibility["seriesLegacySha256"]

    out = [source("build-runtime.sh") + "\n", source("lib/rtbuild.py") + "\n"]

    # Recreate GNU find/sort/sha256sum over `patches bridge boot direct session-deletion`,
    # with only Android diffs. Documentation and OHOS inputs do not affect an Android
    # image. Keep sha256sum's own filename escaping.
    paths = {"patches/" + name for name in names}
    paths.update(("patches/pins.json", "patches/series"))
    for directory in ("bridge", "boot", "direct", "session-deletion"):
        root = runtime / directory
        if not root.is_dir():
            raise FileNotFoundError(root)
        paths.update(path.relative_to(runtime).as_posix() for path in root.rglob("*")
                     if path.is_file() and not path.is_symlink())

    # Absent from the baseline recipe. Preserve it, but never hide a changed helper.
    if digest(runtime / "lib/android_recipe.py") != compatibility["helperSha256"]:
        paths.add("lib/android_recipe.py")
    for name in sorted(paths, key=os.fsencode):
        if name == "patches/pins.json":
            out.append(pins_digest + "  patches/pins.json\n")
        elif name == "patches/series":
            out.append(series_digest + "  patches/series\n")
        elif name in compatibility["sources"]:
            out.append(source(name) + "  " + name + "\n")
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
