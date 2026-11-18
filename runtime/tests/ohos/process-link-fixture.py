#!/usr/bin/env python3
"""Run a test command with an external, bounded real-link fixture actor.

The strict Node process keeps its fs.link and fs.symlink prohibitions. This parent
creates links, within its fresh owned workspace, to model pre-existing files
or an outside actor at an explicit test handshake. This is not product code.
"""
from pathlib import Path
import argparse
import errno
import json
import os
import shutil
import stat
import subprocess
import tempfile
import time


def identity(path):
    value = path.stat()
    return {"dev": value.st_dev, "ino": value.st_ino, "nlink": value.st_nlink,
            "bytes": value.st_size, "mode": stat.S_IMODE(value.st_mode)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a real test command is required")
    root = Path(tempfile.mkdtemp(prefix="ohos-link-host-fixture-"))
    workspace = root / "workspaces"
    requests, responses = root / "requests", root / "responses"
    for path in [workspace, requests, responses]:
        path.mkdir()
    env = os.environ.copy()
    linked = env.pop('OHOS_TEST_LINK_LD_PRELOAD', None)
    if linked is not None:
        env['LD_PRELOAD'] = linked
    env.update(TMPDIR=str(workspace), OHOS_TEST_LINK_WORKSPACE=str(workspace), OHOS_TEST_LINK_REQUESTS=str(requests),
               OHOS_TEST_LINK_RESPONSES=str(responses))
    report = {"scope": "real Python os.link/os.symlink outside strict Node; no Node capability restored",
              "argv": command, "requests": []}
    child = None
    start = time.monotonic()
    try:
        child = subprocess.Popen(command, env=env)
        while child.poll() is None:
            for request in sorted(requests.glob("*.json")):
                record = {"id": request.stem}
                try:
                    value = json.loads(request.read_text())
                    operation = value.get("operation", "link")
                    if operation not in {"link", "symlink"} or set(value) != ({"source", "destination"} if "operation" not in value else {"operation", "source", "destination"}):
                        raise ValueError("unexpected request shape")
                    source, destination = Path(value["source"]), Path(value["destination"])
                    record.update(operation=operation, source=str(source), destination=str(destination))
                    if not destination.is_absolute():
                        raise ValueError("absolute fixture destination required")
                    if workspace not in destination.parent.resolve(strict=True).parents and destination.parent != workspace:
                        raise ValueError("destination escaped owned fixture workspace")
                    if operation == "symlink":
                        # Target bytes are input, including dangling paths or a
                        # dependency prefix. Never follow or modify that target.
                        os.symlink(value["source"], destination)
                        record["target"] = os.readlink(destination)
                    else:
                        if not source.is_absolute() or workspace not in source.resolve(strict=True).parents:
                            raise ValueError("source escaped owned fixture workspace")
                        if not stat.S_ISREG(source.lstat().st_mode):
                            raise ValueError("only a regular fixture file can be linked")
                        record["sourceBefore"] = identity(source)
                        os.link(source, destination, follow_symlinks=False)
                        record.update(sourceAfter=identity(source), destinationAfter=identity(destination))
                    answer = {"ok": True}
                except Exception as error:
                    answer = {"ok": False, "message": str(error),
                              "code": errno.errorcode.get(getattr(error, "errno", None), "FIXTURE_ERROR")}
                record["answer"] = answer
                report["requests"].append(record)
                temp = responses / (request.stem + ".tmp")
                temp.write_text(json.dumps(answer) + "\n")
                temp.replace(responses / request.name)
                request.unlink()
            time.sleep(0.01)
        report.update(exitCode=child.returncode, elapsedSeconds=time.monotonic() - start,
                      pendingRequests=len(list(requests.glob("*.json"))))
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        shutil.rmtree(root)
    raise SystemExit(report["exitCode"])


if __name__ == "__main__":
    main()
