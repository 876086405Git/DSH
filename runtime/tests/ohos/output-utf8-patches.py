#!/usr/bin/env python3
"""Exercise real patch-dsh target selection on the locked npm file closure.

Only private copies are patched. This does not build Android/APK/HAP or claim
that a sparse verification prefix is the complete runtime payload.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(root):
    return {
        path.relative_to(root).as_posix(): {
            "bytes": path.stat().st_size,
            "sha256": digest(path),
            "mode": path.stat().st_mode & 0o777,
        }
        for path in sorted(root.rglob("*")) if path.is_file()
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-repo", required=True, type=Path)
    parser.add_argument("--candidate-repo", required=True, type=Path)
    parser.add_argument("--pristine-prefix", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    version = "0.2.1-rc.4"
    patch_name = "ohos-output-utf8.diff"
    relative = "node_modules/@deepseek-ai/dsh-subprocess-local/lib/output.js"
    base = json.loads((args.base_repo / "runtime/patches/pins.json").read_text())
    candidate = json.loads((args.candidate_repo / "runtime/patches/pins.json").read_text())
    assert candidate["targetSets"]["android"] == base["targetSets"]["android"]
    assert patch_name not in candidate["targetSets"]["android"]
    assert patch_name in candidate["targetSets"]["ohos"]
    assert set(candidate["patches"]) - set(base["patches"]) == {patch_name}
    for name in base["patches"]:
        assert candidate["patches"][name] == base["patches"][name], name
        assert (args.candidate_repo / "runtime/patches" / name).read_bytes() == (args.base_repo / "runtime/patches" / name).read_bytes(), name
    pins = candidate["patches"][patch_name][version][relative]
    assert pins["before"] == "4f77ef6da608d36df168c99177e9b527e7145df1418845eba567635e64a4c2a3"
    paths = sorted({
        path for versions in candidate["patches"].values()
        for path in versions.get(version, {})
    })
    originals = {path: {
        "bytes": (args.pristine_prefix / path).stat().st_size,
        "sha256": digest(args.pristine_prefix / path),
    } for path in paths}
    commands = []

    def new_prefix(name):
        prefix = args.out / name
        for relative_path in paths:
            target = prefix / relative_path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(args.pristine_prefix / relative_path, target)
        return prefix

    def run(repo, prefix, target, label, expected=0):
        argv = [sys.executable, "-I", "-B", str(repo / "runtime/lib/rtbuild.py"),
                "patch-dsh", "--prefix", str(prefix), "--patches", str(repo / "runtime/patches"),
                "--dsh-version", version, "--target", target,
                "--out", str(args.out / (label + "-patches.json")),
                "--target-report", str(args.out / (label + "-target.json"))]
        result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        (args.out / (label + ".stdout.log")).write_bytes(result.stdout)
        (args.out / (label + ".stderr.log")).write_bytes(result.stderr)
        commands.append({"label": label, "argv": argv, "exitCode": result.returncode})
        (args.out / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        if expected == 0:
            assert result.returncode == 0, (label, result.stderr.decode())
            return json.loads((args.out / (label + "-target.json")).read_text())
        assert result.returncode != 0, label
        return None

    android_base = new_prefix("android-base")
    android_candidate = new_prefix("android-candidate")
    ohos = new_prefix("ohos-candidate")
    a = run(args.base_repo, android_base, "android", "android-base")
    b = run(args.candidate_repo, android_candidate, "android", "android-candidate")
    assert a["selected"] == b["selected"]
    assert a["inputs"] == b["inputs"]
    assert a["inputSha256"] == b["inputSha256"]
    android_before = inventory(android_base)
    android_after = inventory(android_candidate)
    assert android_before == android_after
    assert digest(android_candidate / relative) == pins["before"]
    c = run(args.candidate_repo, ohos, "ohos", "ohos-first")
    assert patch_name in c["selected"]
    assert digest(ohos / relative) == pins["after"]
    ohos_first = inventory(ohos)
    run(args.candidate_repo, ohos, "ohos", "ohos-idempotent")
    assert inventory(ohos) == ohos_first
    run(args.candidate_repo, ohos, "android", "wrong-target-rejected", expected=1)
    assert inventory(ohos) == ohos_first
    # Android's set is no longer a subset of OHOS's, and real builds use fresh prefixes.
    run(args.candidate_repo, android_candidate, "ohos", "android-to-ohos", expected=1)
    refusal = (args.out / "android-to-ohos.stderr.log").read_text()
    assert re.fullmatch(r"target ohos: node_modules/\S+ sha256 [0-9a-f]{64} differs from the vetted DSH "
                        + re.escape(version) + r" patch chain\n", refusal), refusal
    assert inventory(android_candidate) == android_after
    for path, row in originals.items():
        assert (args.pristine_prefix / path).stat().st_size == row["bytes"]
        assert digest(args.pristine_prefix / path) == row["sha256"]
    report = {
        "schema": 1, "status": "PASSED_AUTHOR_PATCH_TARGET_GATES",
        "scope": "Real strict patcher, sparse closure of all registered rc.4 patch inputs; not a complete runtime, APK or HAP build.",
        "baseRepo": str(args.base_repo), "candidateRepo": str(args.candidate_repo),
        "pristinePrefix": str(args.pristine_prefix),
        "originalFiles": originals,
        "androidFiles": android_before,
        "androidTargetInputSha256": a["inputSha256"],
        "androidTargetInputsIdentical": True,
        "androidClosureFilesIdentical": True,
        "ohosAfter": pins["after"],
        "ohosIdempotent": True,
        "wrongTargetRejectedWithoutMutation": True,
        "androidToOhosRefusedWithoutMutation": True,
        "sharedInputUnchanged": True,
        "commands": commands,
    }
    (args.out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "commands": len(commands), "inputFiles": len(paths),
                      "androidFiles": len(android_before), "androidInputSha256": a["inputSha256"], "ohosAfter": pins["after"]}))


if __name__ == "__main__":
    main()
