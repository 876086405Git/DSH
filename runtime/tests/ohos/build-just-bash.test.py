#!/usr/bin/env python3
"""Exercise exact input pins, private output integrity, and failure cleanup."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from unittest.mock import patch

sys.dont_write_bytecode = True


def sha(data):
    return hashlib.sha256(data).hexdigest()


def replace_bytes(path, data):
    temporary = path.with_name(path.name + ".test-new")
    temporary.write_bytes(data)
    os.replace(temporary, path)


@contextmanager
def edited(path, data):
    original = path.read_bytes()
    replace_bytes(path, data)
    try:
        yield
    finally:
        replace_bytes(path, original)


def inventory(path):
    return {p.relative_to(path).as_posix(): sha(p.read_bytes()) for p in path.rglob("*") if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--builder", type=Path, default=Path(__file__).resolve().parents[2] / "ohos/process/build-just-bash.py")
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("private_bash_builder", args.builder)
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    source = args.package.resolve(strict=True)
    config_source = args.builder.resolve().parent / "bash-src"
    pins = json.loads((config_source / "just-bash-3.6.0.json").read_text())
    source_before = {name: sha((source / name).read_bytes()) for name in ["package.json", "LICENSE", *["dist/bundle/" + name for name in pins["bundleFiles"]]]}
    cases = []

    def run(name, action):
        try:
            details = action()
            cases.append({"name": name, "pass": True, "details": details})
        except Exception as error:
            cases.append({"name": name, "pass": False, "error": repr(error)})

    with tempfile.TemporaryDirectory(prefix="ohos-private-bash-build-test-") as directory:
        root = Path(directory)
        package = root / "input"
        package.mkdir()
        # Original dependencies stay read-only. Mutations below replace clone
        # entries with new inodes; never write through these initial hardlinks.
        for name in ("package.json", "LICENSE"):
            os.link(source / name, package / name)
        shutil.copytree(source / "dist/bundle", package / "dist/bundle", copy_function=os.link)
        config = root / "config"
        shutil.copytree(config_source, config, ignore=shutil.ignore_patterns("__pycache__"))
        output = root / "output"

        def fresh():
            result = builder.build(package, output, config)
            assert result["status"] == "built"
            # The kept bundle files plus the private package.json, LICENSE and PROVENANCE.
            assert result["files"] == len(pins["bundleFiles"]) - len(pins["omitFromPrivateEsm"]) + 3
            for name, expected in pins["changedAfter"].items():
                assert sha((output / name).read_bytes()) == expected
            assert (output / "LICENSE").read_bytes() == (source / "LICENSE").read_bytes()
            assert json.loads((output / "package.json").read_text())["license"] == "Apache-2.0"
            for name in pins["changedAfter"]:
                assert (output / name).read_bytes().startswith(b"/* Modified for dsh-go OHOS:")
            assert not (output / "index.cjs").exists()
            assert not (output / "browser.js").exists()
            for name in pins["omitFromPrivateEsm"]:
                assert not (output / name).exists()
            return result

        run("fresh exact-pinned ESM build and retained license", fresh)
        baseline_output = inventory(output)

        def idempotent():
            before = {p.relative_to(output).as_posix(): (p.stat().st_ino, p.stat().st_mtime_ns) for p in output.rglob("*") if p.is_file()}
            result = builder.build(package, output, config)
            after = {p.relative_to(output).as_posix(): (p.stat().st_ino, p.stat().st_mtime_ns) for p in output.rglob("*") if p.is_file()}
            assert result["status"] == "already-built" and before == after
            return result

        run("idempotent rebuild does not rewrite files", idempotent)

        def refused(path):
            before = inventory(path) if path.is_dir() else None
            try:
                builder.build(package, path, config)
            except (OSError, ValueError):
                pass
            else:
                raise AssertionError("build unexpectedly accepted a changed input/output")
            if before is None:
                assert not path.exists()
            else:
                assert inventory(path) == before
            assert not list(root.glob(".dsh-just-bash-build-*"))

        unchanged_module = next(name for name in pins["bundleFiles"] if name.startswith("chunks/echo-"))
        path = package / "dist/bundle" / unchanged_module
        with edited(path, path.read_bytes() + b"\n// changed unchanged-module fixture\n"):
            run("drift in a copied but unpatched module rejects without replacing output", lambda: refused(output))
        with edited(package / "package.json", (package / "package.json").read_bytes() + b"\n"):
            run("package metadata drift rejects before allocating output", lambda: refused(root / "bad-package"))
        with edited(package / "LICENSE", b"unexpected license"):
            run("license drift rejects before allocating output", lambda: refused(root / "bad-license"))

        path = package / "dist/bundle/new-unregistered.js"
        path.write_text("// extra input\n")
        try:
            run("extra bundle member rejects", lambda: refused(root / "extra-member"))
        finally:
            path.unlink()

        path = package / "dist/bundle" / unchanged_module
        original = path.read_bytes()
        path.unlink()
        path.symlink_to(source / "dist/bundle" / unchanged_module)
        try:
            run("symlink bundle member rejects", lambda: refused(root / "symlink-member"))
        finally:
            path.unlink()
            path.write_bytes(original)

        with edited(config / "rewrite.py", b"def rewrite(inputs):\n    return inputs\n"):
            run("wrong transformation output rejects by after hash", lambda: refused(root / "wrong-rewrite"))

        path = output / "index.js"
        with edited(path, path.read_bytes() + b"\n// output drift\n"):
            run("existing modified private output is preserved and rejected", lambda: refused(output))
        foreign = root / "foreign"
        foreign.mkdir()
        (foreign / "keep").write_text("another owner")
        run("existing unrelated directory is preserved and rejected", lambda: refused(foreign))
        run("output inside input package rejects", lambda: refused(package / "must-not-create"))

        def write_failure():
            original_write = Path.write_bytes
            writes = 0

            def fail_third(path, data):
                nonlocal writes
                if any(part.startswith(".dsh-just-bash-build-") for part in path.parts):
                    writes += 1
                    if writes == 3:
                        raise OSError(28, "injected write failure; not a measured disk-full event")
                return original_write(path, data)

            target = root / "injected-write-failure"
            with patch.object(Path, "write_bytes", fail_third):
                refused(target)
            assert writes == 3
            return {"injection": "third real staging write; ENOSPC is injected", "staging_remaining": []}

        run("staging write failure removes only this build's temporary directory", write_failure)
        def unchanged_output():
            assert inventory(output) == baseline_output, "valid output changed after a rejected build"

        run("valid existing output still matches after every rejection", unchanged_output)
    source_after = {name: sha((source / name).read_bytes()) for name in source_before}
    cases.append({"name": "shared npm input bytes unchanged", "pass": source_before == source_after})
    report = {"schema": 1, "builder_sha256": sha(args.builder.read_bytes()),
              "test_sha256": sha(Path(__file__).read_bytes()),
              "pins_sha256": sha((config_source / "just-bash-3.6.0.json").read_bytes()),
              "scope": "Real pinned package and filesystem; third staging-write error injected explicitly", "cases": cases,
              "passed": sum(case["pass"] for case in cases), "total": len(cases)}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "total": report["total"], "out": str(args.out)}))
    if report["passed"] != report["total"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
