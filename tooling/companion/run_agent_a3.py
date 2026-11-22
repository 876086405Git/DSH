#!/usr/bin/env python3
"""Owner-only A3 launcher. Does not run as part of CI; never proxies model traffic."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import queue
import shlex
import shutil
import subprocess
import sys
import threading
import time
import uuid

PACKAGE = "io.github.ccch1mneyyy.dsh_app.test"
PARENT = "b09c6ce962a7cf4f90b651fdc14944013636e184"
CONFIG_NAME = "dsh-a3-config.json"
RESULT_NAMES = ("events.jsonl", "summary.json", "human-review.md")
CLEANUP_TIMEOUT_SECONDS = 5


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Exact adb/Flutter Android device ID")
    parser.add_argument("--flavor", choices=("arm64", "x64"), default="arm64")
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--only", action="append", default=[], help="Run one named case; repeat for several")
    parser.add_argument("--max-http", type=int, default=120)
    parser.add_argument("--turn-timeout-seconds", type=int, default=180)
    parser.add_argument("--run-timeout-seconds", type=int, default=7200)
    args = parser.parse_args()
    if min(args.max_http, args.turn_timeout_seconds, args.run_timeout_seconds) < 1:
        parser.error("Limits must be positive")
    key = os.environ.get("DEEPSEEK_API_KEY", "")
    if not key.strip():
        print("ENV_UNAVAILABLE: set DEEPSEEK_API_KEY in this process environment", file=sys.stderr)
        return 2
    flutter = shutil.which("flutter")
    adb_exe = shutil.which("adb")
    if flutter is None or adb_exe is None:
        print("ENV_UNAVAILABLE: Flutter and adb must already be installed", file=sys.stderr)
        return 2
    root = pathlib.Path(__file__).resolve().parents[2]
    fixture = root / "tooling/companion/fixtures/agent-a3-live-cases-v1.json"
    fixture_bytes = fixture.read_bytes()
    cases = json.loads(fixture_bytes)
    known = {item["id"] for item in cases["cases"]}
    if set(args.only) - known:
        parser.error("Unknown case ID: " + ", ".join(sorted(set(args.only) - known)))
    output = args.output.resolve()
    if output.exists():
        parser.error("Use a new output directory; previous runs are never overwritten")
    adb = [adb_exe, "-s", args.device]
    env = os.environ.copy()
    env.pop("DEEPSEEK_API_KEY", None)
    env.pop("ADB_TRACE", None)
    env["DSH_SIDE_BUILD"] = "1"
    deadline = time.monotonic() + args.run_timeout_seconds

    def remaining() -> float:
        seconds = deadline - time.monotonic()
        if seconds <= 0:
            raise TimeoutError("manual_run_timeout")
        return seconds

    def command(parts: list[str], *, check: bool = True, data: bytes | None = None,
                cleanup: bool = False, limit: float | None = None) -> subprocess.CompletedProcess:
        timeout = CLEANUP_TIMEOUT_SECONDS if cleanup else remaining()
        if limit is not None:
            timeout = min(timeout, limit)
        stdin = {"input": data} if data is not None else {"stdin": subprocess.DEVNULL}
        return subprocess.run(parts, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              check=check, env=env, timeout=timeout, **stdin)

    def shell(parts: list[str]) -> list[str]:
        # adb joins remote arguments without quoting; quote for Android's shell,
        # not for the host shell. -T keeps stdout/stderr and the remote exit code.
        return adb + ["shell", "-T", shlex.join(parts)]

    def safe(value: object) -> str:
        return str(value).replace(key, "[REDACTED_API_KEY]")

    try:
        command(adb + ["get-state"])
        features = command(adb + ["features"])
        if "shell_v2" not in features.stdout.decode("utf-8", errors="replace").replace(",", " ").split():
            print("ENV_UNAVAILABLE: adb shell_v2 is required for reliable artifact exit status", file=sys.stderr)
            return 2
        installed = command(shell(["pm", "list", "packages", PACKAGE]))
    except (TimeoutError, subprocess.TimeoutExpired):
        print("INCOMPLETE: setup exceeded the remaining run deadline", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("INCOMPLETE: setup interrupted", file=sys.stderr)
        return 1
    except (OSError, subprocess.CalledProcessError):
        print("ENV_UNAVAILABLE: the selected Android device is not ready", file=sys.stderr)
        return 2
    if installed.stdout.strip():
        print("ENV_UNAVAILABLE: the side-build package already exists; use a separate test device/profile", file=sys.stderr)
        return 2

    output.mkdir(parents=True)
    run_id = uuid.uuid4().hex
    payload = json.dumps({
        "key": key, "runId": run_id, "parent": PARENT,
        "fixture": {"path": str(fixture.relative_to(root)), "sha256": hashlib.sha256(fixture_bytes).hexdigest()},
        "cases": cases, "only": args.only, "maxHttp": args.max_http,
        "turnTimeoutSeconds": args.turn_timeout_seconds,
    }, ensure_ascii=False).encode("utf-8")
    configuration_delivered = False
    config_path = None
    process = None
    started = None
    finished = None
    failure = None
    model_run_started = False
    missing_results = list(RESULT_NAMES)
    collection_errors = []
    remote = None
    replay_summary = None
    replay_outcome = None
    cleanup_errors = []
    target_stopped = False

    def cleanup_command(label: str, parts: list[str]) -> subprocess.CompletedProcess | None:
        try:
            cleaned = command(parts, check=False, cleanup=True)
            if cleaned.returncode != 0:
                cleanup_errors.append(label + ": exit " + str(cleaned.returncode)
                                      + "; " + safe(cleaned.stderr.decode("utf-8", errors="replace")).strip())
            return cleaned
        except (OSError, subprocess.SubprocessError, KeyboardInterrupt) as error:
            cleanup_errors.append(label + ": " + type(error).__name__)
            return None

    log_path = output / "launcher.log"
    try:
        remaining()
        cmd = [
            flutter, "run", "--debug", "--flavor", args.flavor, "-d", args.device,
            "-t", "tool/companion_agent_a3.dart",
        ]
        process = subprocess.Popen(
            cmd, cwd=root / "app", env=env, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            encoding="utf-8", errors="replace", bufsize=1,
        )
        pending: queue.Queue[str | None] = queue.Queue()

        def read_output():
            assert process is not None and process.stdout is not None
            for line in process.stdout:
                pending.put(line)
            pending.put(None)

        threading.Thread(target=read_output, daemon=True).start()
        with log_path.open("w", encoding="utf-8", newline="\n") as log:
            while True:
                try:
                    line = pending.get(timeout=min(1, remaining()))
                except queue.Empty:
                    continue
                if line is None:
                    break
                redacted = safe(line)
                log.write(redacted)
                log.flush()
                print(redacted, end="", flush=True)
                if "A3_ENV_UNAVAILABLE" in line:
                    failure = "target_environment_unavailable"
                    break
                if "A3_STOPPED_BEFORE_START" in line:
                    failure = "manual_cancelled_before_start"
                    break
                if "A3_CONFIG_READY:" in line:
                    if config_path is not None:
                        raise RuntimeError("Configuration was already requested for this run")
                    value = json.loads(line.split("A3_CONFIG_READY:", 1)[1].strip())
                    candidate = pathlib.PurePosixPath(value["path"])
                    if (not candidate.is_absolute() or ".." in candidate.parts
                            or PACKAGE not in candidate.parts or candidate.name != CONFIG_NAME):
                        raise RuntimeError("Invalid private configuration path")
                    config_path = candidate
                    temporary = str(candidate) + ".tmp"
                    script = ("umask 077; cat > " + shlex.quote(temporary)
                              + " && chmod 600 " + shlex.quote(temporary)
                              + " && mv " + shlex.quote(temporary) + " " + shlex.quote(str(candidate)))
                    # Only paths are arguments. The key and fixture travel on stdin
                    # into a new 0600 app-private file, published by atomic rename.
                    command(shell(["run-as", PACKAGE, "sh", "-c", script]), data=payload, limit=15)
                    configuration_delivered = True
                for marker in ("A3_STARTED:", "A3_FINISHED:"):
                    if marker not in line:
                        continue
                    value = json.loads(line.split(marker, 1)[1].strip())
                    if value.get("runId") != run_id:
                        raise RuntimeError("Result belongs to another run")
                    if marker == "A3_STARTED:":
                        started = value
                        model_run_started = True
                    else:
                        finished = value
                if finished is not None:
                    break
        if finished is None:
            failure = failure or "target_did_not_finish"
    except KeyboardInterrupt:
        failure = "manual_cancelled"
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError, subprocess.SubprocessError) as error:
        failure = safe(error)

    # A cancelled/failed target has not received Dart's Stop merely because this
    # output loop ended. Stop it before any potentially blocking artifact read.
    if process is not None and finished is None:
        stopped = cleanup_command("force-stop-before-collection", shell(["am", "force-stop", PACKAGE]))
        target_stopped = stopped is not None and stopped.returncode == 0

    # Collection shares the original deadline, including after a target error.
    # A failed remote cat never becomes a local artifact, even if stdout is nonempty.
    try:
        result = finished or started
        if result is not None:
            remote = pathlib.PurePosixPath(result["directory"])
            if (not remote.is_absolute() or ".." in remote.parts or PACKAGE not in remote.parts
                    or not remote.name.startswith("dsh-a3-" + run_id + "-")):
                raise RuntimeError("Invalid result directory")
            if finished is None and not target_stopped:
                collection_errors.append("collection_skipped_after_unconfirmed_stop")
                raise RuntimeError("Cannot collect an unfinished target before it stops")
            for name in RESULT_NAMES:
                try:
                    response = command(shell(["run-as", PACKAGE, "cat", str(remote / name)]), check=False)
                    if response.returncode != 0:
                        collection_errors.append(name + ": exit " + str(response.returncode)
                                                 + "; " + safe(response.stderr.decode("utf-8", errors="replace")).strip())
                        continue
                    body = response.stdout.replace(key.encode("utf-8"), b"[REDACTED_API_KEY]")
                    (output / name).write_bytes(body)
                    missing_results.remove(name)
                except (OSError, subprocess.SubprocessError) as error:
                    collection_errors.append(name + ": " + safe(error))
            if missing_results:
                failure = failure or "result_collection_incomplete: " + ", ".join(missing_results)
            if "summary.json" not in missing_results:
                replay_summary = json.loads((output / "summary.json").read_text(encoding="utf-8"))
                if replay_summary.get("runId") != run_id:
                    raise RuntimeError("Collected summary belongs to another run")
                replay_outcome = replay_summary.get("replayOutcome")
                if replay_outcome not in ("COMPLETE", "INCOMPLETE"):
                    raise RuntimeError("Collected summary has no valid replayOutcome")
                if not isinstance(replay_summary.get("counts"), dict):
                    raise RuntimeError("Collected summary has no counts")
    except KeyboardInterrupt:
        failure = failure or "manual_cancelled_during_collection"
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError, subprocess.SubprocessError) as error:
        failure = failure or safe(error)
    finally:
        # Keep the only device copies when collection failed. Still stop the app
        # and remove any unread credential bootstrap; never erase results to hide a failure.
        recovery_required = bool(missing_results) and config_path is not None

        if process is not None and not target_stopped:
            cleanup_command("force-stop", shell(["am", "force-stop", PACKAGE]))
        if process is not None and process.poll() is None:
            for action in ("quit", "terminate", "kill"):
                if process.poll() is not None:
                    break
                try:
                    if action == "quit":
                        assert process.stdin is not None
                        process.stdin.write("q\n")
                        process.stdin.flush()
                    elif action == "terminate":
                        process.terminate()
                    else:
                        process.kill()
                    process.wait(timeout=CLEANUP_TIMEOUT_SECONDS)
                except (OSError, subprocess.SubprocessError, KeyboardInterrupt):
                    continue
            if process.poll() is None:
                cleanup_errors.append("flutter_process_did_not_stop")
        # This package was absent before this launcher started. Do not remove
        # any existing regular app, test data, build artifact, or project file.
        if process is not None:
            installed = cleanup_command("check-package", shell(["pm", "list", "packages", PACKAGE]))
            absent = installed is not None and installed.returncode == 0 and not installed.stdout.strip()
            if not absent:
                if config_path is not None:
                    cleanup_command("remove-bootstrap", shell([
                        "run-as", PACKAGE, "rm", "-f", str(config_path), str(config_path) + ".tmp",
                    ]))
                if not recovery_required:
                    cleanup_command("uninstall", adb + ["uninstall", PACKAGE])

    counts = replay_summary.get("counts", {}) if isinstance(replay_summary, dict) else {}
    if failure or replay_outcome != "COMPLETE":
        replay_exit_code = 1
    elif counts.get("FAIL", 0):
        replay_exit_code = 3
    elif counts.get("ENV_UNAVAILABLE", 0) or counts.get("PATH_NOT_EXERCISED", 0):
        replay_exit_code = 2
    else:
        replay_exit_code = 0
    exit_code = 4 if cleanup_errors else replay_exit_code
    for error in cleanup_errors:
        print("CLEANUP_FAILED: " + error, file=sys.stderr)
    members = []
    for path in sorted(output.iterdir()):
        if path.is_file():
            body = path.read_bytes()
            members.append({"path": path.name, "bytes": len(body), "sha256": hashlib.sha256(body).hexdigest()})
    report = {
        "schema": 1, "runId": run_id, "parentFixture": PARENT, "device": args.device,
        "configurationDelivered": configuration_delivered, "targetStarted": model_run_started,
        "targetFinished": finished is not None, "failure": failure, "files": members,
        "replayOutcome": replay_outcome, "replayExitCode": replay_exit_code, "exitCode": exit_code,
        "cleanupErrors": cleanup_errors,
        "collectionErrors": collection_errors, "missingResults": missing_results,
        "deviceRecoveryRequired": recovery_required,
        "deviceResultDirectory": str(remote) if remote is not None else None,
        "credentials": "environment to adb stdin to 0600 app-private bootstrap; no CLI/compiled key or HTTP handoff",
        "execution": "OWNER_MANUAL_RUN", "humanReview": "PENDING",
    }
    try:
        (output / "launcher-summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except OSError as error:
        print("INCOMPLETE: cannot save launcher summary: " + safe(error), file=sys.stderr)
        return 4 if cleanup_errors else 1
    if replay_exit_code == 1:
        print("INCOMPLETE: " + (failure or "target replayOutcome is INCOMPLETE"), file=sys.stderr)
    elif replay_exit_code == 3:
        print("STRUCTURAL_FAIL: replay completed with failed structural checks", file=sys.stderr)
    elif replay_exit_code == 2:
        print("NOT_COVERED: replay completed with environment/path-not-exercised checks", file=sys.stderr)
    if recovery_required:
        print("RECOVERY_REQUIRED: side-build data retained; recover missing results before removing the package", file=sys.stderr)
    if exit_code == 0:
        print("Raw results saved. Complete human-review.md; structural checks are not a semantic pass.")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
