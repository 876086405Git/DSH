#!/usr/bin/env python3
"""Owner-only A3 launcher. Does not run as part of CI; never proxies model traffic."""
from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import os
import pathlib
import queue
import secrets
import shutil
import subprocess
import sys
import threading
import time
import uuid

PACKAGE = "io.github.ccch1mneyyy.dsh_app.test"
PARENT = "6e4e0baf877c13cae8b71b64a0bc5569885583ba"


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
    env["DSH_SIDE_BUILD"] = "1"

    def command(parts: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run(parts, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check, env=env)

    try:
        command(adb + ["get-state"])
        installed = command(adb + ["shell", "pm", "list", "packages", PACKAGE])
    except subprocess.CalledProcessError:
        print("ENV_UNAVAILABLE: the selected Android device is not ready", file=sys.stderr)
        return 2
    if installed.stdout.strip():
        print("ENV_UNAVAILABLE: the side-build package already exists; use a separate test device/profile", file=sys.stderr)
        return 2

    output.mkdir(parents=True)
    run_id = uuid.uuid4().hex
    token = secrets.token_urlsafe(32)
    payload = json.dumps({
        "key": key, "runId": run_id, "parent": PARENT,
        "fixture": {"path": str(fixture.relative_to(root)), "sha256": hashlib.sha256(fixture_bytes).hexdigest()},
        "cases": cases, "only": args.only, "maxHttp": args.max_http,
        "turnTimeoutSeconds": args.turn_timeout_seconds,
    }, ensure_ascii=False).encode("utf-8")
    issued = threading.Event()

    class Config(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            if self.path != "/config/" + token or issued.is_set():
                self.send_error(410)
                return
            issued.set()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)

    server = http.server.HTTPServer(("127.0.0.1", 0), Config)
    port = server.server_address[1]
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    process = None
    started = None
    finished = None
    failure = None
    model_run_started = False
    missing_results = []
    log_path = output / "launcher.log"
    try:
        command(adb + ["reverse", f"tcp:{port}", f"tcp:{port}"])
        cmd = [
            flutter, "run", "--debug", "--flavor", args.flavor, "-d", args.device,
            "-t", "tool/companion_agent_a3.dart",
            f"--dart-define=A3_CONFIG_PORT={port}", f"--dart-define=A3_CONFIG_TOKEN={token}",
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
        deadline = time.monotonic() + args.run_timeout_seconds
        with log_path.open("w", encoding="utf-8", newline="\n") as log:
            while time.monotonic() < deadline:
                try:
                    line = pending.get(timeout=1)
                except queue.Empty:
                    continue
                if line is None:
                    break
                safe = line.replace(key, "[REDACTED_API_KEY]").replace(token, "[ONE_USE_CONFIG_TOKEN]")
                log.write(safe)
                log.flush()
                print(safe, end="", flush=True)
                if "A3_ENV_UNAVAILABLE" in line:
                    failure = "target_environment_unavailable"
                    break
                if "A3_STOPPED_BEFORE_START" in line:
                    failure = "manual_cancelled_before_start"
                    break
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
            else:
                failure = "manual_run_timeout"
        result = finished or started
        if result is not None:
            remote = pathlib.PurePosixPath(result["directory"])
            if ".." in remote.parts or PACKAGE not in str(remote) or not remote.name.startswith("dsh-a3-" + run_id + "-"):
                raise RuntimeError("Invalid result directory")
            for name in ("events.jsonl", "summary.json", "human-review.md"):
                response = command(adb + ["exec-out", "run-as", PACKAGE, "cat", str(remote / name)], check=False)
                if response.returncode == 0:
                    body = response.stdout.replace(key.encode(), b"[REDACTED_API_KEY]")
                    (output / name).write_bytes(body)
                else:
                    missing_results.append(name)
            if finished is not None and missing_results:
                failure = "result_collection_incomplete: " + ", ".join(missing_results)
        if finished is None:
            failure = failure or "target_did_not_finish"
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        failure = str(error).replace(key, "[REDACTED_API_KEY]").replace(token, "[ONE_USE_CONFIG_TOKEN]")
    finally:
        if process is not None and process.poll() is None:
            try:
                assert process.stdin is not None
                process.stdin.write("q\n")
                process.stdin.flush()
                process.wait(timeout=30)
            except (OSError, subprocess.TimeoutExpired):
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        # This package was absent before this launcher started. Do not remove
        # any existing regular app, test data, build artifact, or project file.
        cleanup_errors = []
        for parts in (
            ["shell", "am", "force-stop", PACKAGE],
            ["uninstall", PACKAGE],
            ["reverse", "--remove", f"tcp:{port}"],
        ):
            try:
                cleaned = command(adb + parts, check=False)
                if cleaned.returncode != 0:
                    cleanup_errors.append(parts[0] + ": exit " + str(cleaned.returncode))
            except (OSError, subprocess.SubprocessError) as error:
                cleanup_errors.append(parts[0] + ": " + type(error).__name__)
        server.shutdown()
        server.server_close()
    members = []
    for path in sorted(output.iterdir()):
        if path.is_file():
            body = path.read_bytes()
            members.append({"path": path.name, "bytes": len(body), "sha256": hashlib.sha256(body).hexdigest()})
    report = {
        "schema": 1, "runId": run_id, "parentFixture": PARENT, "device": args.device,
        "configurationDelivered": issued.is_set(), "targetStarted": model_run_started,
        "targetFinished": finished is not None, "failure": failure, "files": members,
        "cleanupErrors": cleanup_errors,
        "missingResults": missing_results,
        "credentials": "environment-only; one-use localhost delivery; no compiled key; no request headers logged",
        "execution": "OWNER_MANUAL_RUN", "humanReview": "PENDING",
    }
    (output / "launcher-summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if failure:
        print("INCOMPLETE: " + failure, file=sys.stderr)
        return 1
    print("Raw results saved. Complete human-review.md; structural checks are not a semantic pass.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
