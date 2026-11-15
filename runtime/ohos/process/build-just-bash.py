#!/usr/bin/env python3
"""Build the private OH ESM entry from pinned just-bash 3.6.0 npm bytes.

No network, npm install, shared package mutation, or TypeScript rebuild.
The caller owns this build output directory and runs one builder at a time.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile

sys.dont_write_bytecode = True


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def inside(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def plain_file(path: Path) -> bytes:
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError(f"Expected a regular input file: {path}")
    return path.read_bytes()


def output_matches(path: Path, expected: dict[str, bytes]) -> bool:
    if not path.is_dir() or path.is_symlink():
        return False
    actual = {}
    for item in path.rglob("*"):
        mode = item.lstat().st_mode
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode) or stat.S_IMODE(mode) != 0o644:
            return False
        actual[item.relative_to(path).as_posix()] = digest(item.read_bytes())
    return actual == {name: digest(data) for name, data in expected.items()}


def build(package: Path, output: Path, config: Path) -> dict:
    package = package.resolve(strict=True)
    output = output.absolute()
    # Resolve parents as well, so an output alias cannot write into the npm input.
    resolved_output = output.resolve(strict=False)
    if inside(resolved_output, package) or inside(package, resolved_output):
        raise ValueError("The private output must be separate from the npm input package")
    pins_bytes = plain_file(config / "just-bash-3.6.0.json")
    pins = json.loads(pins_bytes)
    if pins["schema"] != 1:
        raise ValueError("Unknown source pin schema")
    package_bytes = plain_file(package / "package.json")
    metadata = json.loads(package_bytes)
    if (metadata.get("name") != pins["package"] or metadata.get("version") != pins["version"]
            or metadata.get("license") != pins["license"]):
        raise ValueError("Expected the fixed just-bash 3.6.0 package")
    if digest(package_bytes) != pins["packageJsonSha256"]:
        raise ValueError("package.json differs from the pinned npm package")
    license_bytes = plain_file(package / "LICENSE")
    if digest(license_bytes) != pins["licenseSha256"]:
        raise ValueError("Pinned license differs")
    bundle = package / "dist/bundle"
    actual_names = set()
    for item in bundle.rglob("*"):
        mode = item.lstat().st_mode
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            raise ValueError(f"Non-regular npm bundle input: {item}")
        actual_names.add(item.relative_to(bundle).as_posix())
    if actual_names != set(pins["bundleFiles"]):
        raise ValueError("The complete npm bundle file set differs from the pin")
    # Keep the verified byte objects for writing; do not reread mutable sources.
    inputs = {}
    for name, identity in pins["bundleFiles"].items():
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Unsafe pinned relative path")
        data = plain_file(bundle / relative)
        if digest(data) != identity["sha256"] or len(data) != identity["bytes"]:
            raise ValueError(f"Pinned npm input differs: {name}")
        inputs[name] = data
    for name, expected in pins["changedBefore"].items():
        if digest(inputs[name]) != expected:
            raise ValueError(f"Changed-module before hash differs: {name}")

    rewrite_path = config / "rewrite.py"
    rewrite_bytes = plain_file(rewrite_path)
    # Execute the same local source bytes recorded in provenance, without a
    # second read between hashing and execution. This is repository-owned code.
    namespace = {}
    exec(compile(rewrite_bytes, str(rewrite_path), "exec"), namespace)
    transformed = namespace["rewrite"]({name: inputs[name] for name in pins["changedBefore"]})
    if set(transformed) != set(pins["changedAfter"]):
        raise ValueError("Unexpected rewritten module set")
    for name, expected in pins["changedAfter"].items():
        if digest(transformed[name]) != expected:
            raise ValueError(f"Changed-module after hash differs: {name}")
    files = {name: data for name, data in inputs.items() if name not in pins["omitFromPrivateEsm"]}
    if not set(transformed).issubset(files):
        raise ValueError("An omitted entry cannot receive a private ESM patch")
    files.update(transformed)
    files["LICENSE"] = license_bytes
    files["package.json"] = (json.dumps({
        "name": "dsh-go-ohos-just-bash", "version": "3.6.0-ohos.1",
        "private": True, "type": "module", "license": "Apache-2.0",
        "exports": "./index.js",
    }, sort_keys=True, indent=2) + "\n").encode()
    provenance = {
        "schema": 1, "upstream": {"package": pins["package"], "version": pins["version"], "integrity": pins["integrity"]},
        "scope": "OH private ESM; exact npm published-JS inputs with local fixes; not a full upstream TS rebuild",
        "sourcePinsSha256": digest(pins_bytes), "rewriteSha256": digest(rewrite_bytes),
        "modules": {name: digest(data) for name, data in sorted(files.items())},
        "changedBefore": pins["changedBefore"], "changedAfter": pins["changedAfter"],
    }
    files["PROVENANCE.json"] = (json.dumps(provenance, sort_keys=True, indent=2) + "\n").encode()
    output_digest = digest(json.dumps({name: digest(data) for name, data in sorted(files.items())},
                                     sort_keys=True, separators=(",", ":")).encode())
    result = {"output": str(output), "files": len(files), "manifestSha256": output_digest,
              "bytes": sum(map(len, files.values()))}
    if output.exists() or output.is_symlink():
        if not output_matches(output, files):
            raise ValueError("Existing private output differs; preserved without modification")
        return {"status": "already-built", **result}

    # All source checks and transformations finish before any output allocation.
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".dsh-just-bash-build-", dir=output.parent))
    try:
        for name, data in files.items():
            target = staging / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(0o644)
        if not output_matches(staging, files):
            raise ValueError("Written private output differs from verified bytes")
        if output.exists() or output.is_symlink():
            raise ValueError("Private output appeared during this build; preserved")
        os.rename(staging, output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return {"status": "built", **result}


def main() -> None:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, default=here / "node_modules/just-bash")
    parser.add_argument("--out", type=Path, default=here / "build/just-bash")
    args = parser.parse_args()
    try:
        result = build(args.package, args.out, here / "bash-src")
    except (OSError, ValueError, KeyError) as error:
        print(f"just-bash private build refused: {error}", file=sys.stderr)
        raise SystemExit(2) from None
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
