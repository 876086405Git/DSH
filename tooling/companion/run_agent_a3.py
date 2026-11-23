#!/usr/bin/env python3
"""Owner-only A3 launcher. Does not run as part of CI; never proxies model traffic."""
from __future__ import annotations

import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import pathlib
import queue
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import threading
import time
import uuid

PACKAGE = "io.github.ccch1mneyyy.dsh_app.test"
PARENT = "89011333285efa14b525708ff652eaf2ed1d2309"
CONFIG_NAME = "dsh-a3-config.json"
RESULT_NAMES = ("events.jsonl", "summary.json", "human-review.md")
CLEANUP_TIMEOUT_SECONDS = 5
KEY_HANDOFF_SECONDS = 15


class _KeyHandoff:
    """One in-memory response, authorized by the target's in-memory secret."""

    def __init__(self, key: str, run_id: str, claim_hash: str):
        self.claim_hash = claim_hash
        self._key = key
        self.run_id = run_id
        self.expires = time.monotonic() + KEY_HANDOFF_SECONDS
        self.consumed = False
        self.done = threading.Event()
        self.stopping = threading.Event()
        self.thread = None
        self._connection = None
        self._connection_lock = threading.Lock()
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass  # Neither request headers nor the one-use token are logged.

            def do_POST(self):
                claim_hash = hashlib.sha256(
                    self.headers.get("X-DSH-A3-Token", "").encode("utf-8")).hexdigest()
                if (self.path != "/a3-key" or owner.stopping.is_set()
                        or owner.consumed or time.monotonic() >= owner.expires
                        or not secrets.compare_digest(claim_hash, owner.claim_hash)):
                    self.send_response(403)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                # HTTPServer handles requests serially. Consume before writing:
                # even a failed response must never make the key claimable twice.
                owner.consumed = True
                body = json.dumps({"runId": owner.run_id, "key": owner._key}).encode("utf-8")
                owner._key = ""
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()

        class Server(HTTPServer):
            def get_request(self):
                connection, address = super().get_request()
                connection.settimeout(2)
                with owner._connection_lock:
                    if owner.stopping.is_set():
                        connection.close()
                        raise OSError("Local key handoff stopped")
                    owner._connection = connection
                return connection, address

            def close_request(self, request):
                with owner._connection_lock:
                    if owner._connection is request:
                        owner._connection = None
                super().close_request(request)

            def handle_error(self, *_args):
                pass  # A failed local handoff is reported without request data.

        self.server = Server(("127.0.0.1", 0), Handler)
        self.server.timeout = 0.2
        self.port = self.server.server_address[1]

    def start(self):
        def serve():
            try:
                while (not self.stopping.is_set() and not self.consumed
                       and time.monotonic() < self.expires):
                    self.server.handle_request()
            finally:
                self._key = ""
                self.done.set()
                # Keep the host port reserved until its adb reverse is removed.
        self.thread = threading.Thread(target=serve, daemon=True)
        self.thread.start()

    def close(self):
        self.stopping.set()
        with self._connection_lock:
            if self._connection is not None:
                try:
                    self._connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                self._connection.close()
                self._connection = None
        if self.thread is not None:
            self.thread.join(timeout=3)
        self.server.server_close()
        self._key = ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Exact adb/Flutter Android device ID")
    parser.add_argument("--android-user", type=int, default=0, help="One Android user/profile ID for every device operation")
    parser.add_argument("--flavor", choices=("arm64", "x64"), default="arm64")
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--only", action="append", default=[], help="Run one named case; repeat for several")
    parser.add_argument("--max-http", type=int, default=120)
    parser.add_argument("--turn-timeout-seconds", type=int, default=180)
    parser.add_argument("--run-timeout-seconds", type=int, default=7200)
    args = parser.parse_args()
    if min(args.max_http, args.turn_timeout_seconds, args.run_timeout_seconds) < 1:
        parser.error("Limits must be positive")
    if args.android_user < 0:
        parser.error("Android user must be non-negative")
    android_user = str(args.android_user)
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
                cleanup: bool = False, limit: float | None = None,
                cwd: pathlib.Path | None = None) -> subprocess.CompletedProcess:
        timeout = CLEANUP_TIMEOUT_SECONDS if cleanup else remaining()
        if limit is not None:
            timeout = min(timeout, limit)
        stdin = {"input": data} if data is not None else {"stdin": subprocess.DEVNULL}
        return subprocess.run(parts, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              check=check, env=env, timeout=timeout, cwd=cwd, **stdin)

    def shell(parts: list[str]) -> list[str]:
        # adb joins remote arguments without quoting; quote for Android's shell,
        # not for the host shell. -T keeps stdout/stderr and the remote exit code.
        return adb + ["shell", "-T", shlex.join(parts)]

    def safe(value: object) -> str:
        return str(value).replace(key, "[REDACTED_API_KEY]")

    def run_as(parts: list[str]) -> list[str]:
        return shell(["run-as", PACKAGE, "--user", android_user, *parts])

    try:
        command(adb + ["get-state"])
        features = command(adb + ["features"])
        if "shell_v2" not in features.stdout.decode("utf-8", errors="replace").replace(",", " ").split():
            print("ENV_UNAVAILABLE: adb shell_v2 is required for reliable artifact exit status", file=sys.stderr)
            return 2
        # install -R checks the whole device, not only the selected profile.
        installed = command(shell(["pm", "list", "packages", "--user", "all", PACKAGE]))
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
        print("ENV_UNAVAILABLE: the side build exists on this device; another profile is not a clean device", file=sys.stderr)
        return 2

    output.mkdir(parents=True)
    run_id = uuid.uuid4().hex
    config = {
        "runId": run_id, "parent": PARENT,
        "fixture": {"path": str(fixture.relative_to(root)), "sha256": hashlib.sha256(fixture_bytes).hexdigest()},
        "cases": cases, "only": args.only, "maxHttp": args.max_http,
        "turnTimeoutSeconds": args.turn_timeout_seconds,
    }
    owned_install = False
    installation_state = "not_attempted"
    key_handoff = None
    reverse_port = None
    reverse_state = "not_attempted"
    key_claimed = False
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
    summary_validated = False
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

    def finish_handoff():
        nonlocal key_handoff, reverse_state, key_claimed
        if key_handoff is not None:
            key_handoff.stopping.set()
            key_claimed = key_claimed or key_handoff.consumed
        if reverse_state == "created":
            mappings = cleanup_command("list-key-reverse", adb + ["reverse", "--list"])
            if mappings is None or mappings.returncode != 0:
                reverse_state = "unresolved"
            else:
                try:
                    rows = [line.split() for line in mappings.stdout.decode("utf-8").splitlines()
                            if line.strip()]
                except UnicodeDecodeError:
                    rows = None
                if rows is None or any(len(row) != 3 for row in rows):
                    reverse_state = "unresolved"
                    cleanup_errors.append("key_reverse_list_invalid")
                else:
                    current = [row for row in rows if row[1] == reverse_port]
                    if len(current) > 1:
                        reverse_state = "unresolved"
                        cleanup_errors.append("key_reverse_list_ambiguous: " + reverse_port)
                    elif not current:
                        reverse_state = "already_absent"
                    elif current[0][2] != reverse_port:
                        # This run created port -> port. Another local endpoint
                        # now owns the remote port; do not remove its mapping.
                        reverse_state = "replaced_left_untouched"
                    else:
                        # adb has no conditional remove. This check cannot close
                        # the read/remove race or identify an identical rebind.
                        removed = cleanup_command(
                            "remove-key-reverse", adb + ["reverse", "--remove", reverse_port])
                        if removed is not None and removed.returncode == 0:
                            reverse_state = "removed"
        elif reverse_state == "pending":
            # A timeout/error does not establish ownership. A competing client
            # may have won --no-rebind; keep the port for explicit recovery.
            reverse_state = "unresolved"
            cleanup_errors.append("key_reverse_creation_unresolved: " + reverse_port)
        if key_handoff is not None:
            try:
                key_handoff.close()
                if key_handoff.thread is not None and key_handoff.thread.is_alive():
                    cleanup_errors.append("key_handoff_thread_did_not_stop")
            except (OSError, KeyboardInterrupt) as error:
                cleanup_errors.append("close-key-handoff: " + type(error).__name__)
            key_handoff = None

    log_path = output / "launcher.log"
    try:
        remaining()
        # Build once, then record an explicit no-replace installation result.
        # Flutter's prebuilt run may install again; it is entered only after we
        # own the initial installation, never merely because pm later sees it.
        build = command([
            flutter, "build", "apk", "--debug", "--flavor", args.flavor,
            "-t", "tool/companion_agent_a3.dart",
        ], cwd=root / "app", check=False)
        (output / "build.log").write_text(
            safe(build.stdout.decode("utf-8", errors="replace"))
            + safe(build.stderr.decode("utf-8", errors="replace")), encoding="utf-8")
        if build.returncode != 0:
            raise RuntimeError("Side-build compilation failed; see build.log")
        apk = root / "app/build/app/outputs/flutter-apk" / ("app-" + args.flavor + "-debug.apk")
        if not apk.is_file():
            raise RuntimeError("Expected side-build APK was not produced")
        installation_state = "unconfirmed"
        # Modern pm replaces by default; omitting -r is not enough. -R is the
        # explicit no-replace option. An unsupported option must fail closed.
        install = command(adb + ["install", "-R", "-t", "--user", android_user, str(apk)], check=False)
        install_confirmed = (install.returncode == 0
                             and "Success" in install.stdout.decode("utf-8", errors="replace").splitlines())
        if install_confirmed:
            owned_install = True
            installation_state = "installed"
        (output / "install.log").write_text(
            safe(install.stdout.decode("utf-8", errors="replace"))
            + safe(install.stderr.decode("utf-8", errors="replace")), encoding="utf-8")
        if not install_confirmed:
            raise RuntimeError("Side-build install was not confirmed; its package is left untouched")
        cmd = [
            flutter, "run", "--debug", "--flavor", args.flavor, "-d", args.device,
            "--device-user", android_user, "--use-application-binary", str(apk),
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
                if key_handoff is not None and key_handoff.done.is_set():
                    finish_handoff()
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
                    key_handoff = _KeyHandoff(key, run_id, value["claimHash"])
                    port = "tcp:" + str(key_handoff.port)
                    mappings = command(adb + ["reverse", "--list"], limit=5)
                    rows = [line.split() for line in mappings.stdout.decode("utf-8").splitlines() if line.strip()]
                    if any(len(row) != 3 for row in rows):
                        raise RuntimeError("Cannot establish existing reverse mappings")
                    if any(row[1] == port for row in rows):
                        raise RuntimeError("Key reverse port already exists; left untouched")
                    # Register before dispatch: a timed-out adb client may have
                    # installed a listener, but does not prove that we own it.
                    reverse_port = port
                    reverse_state = "pending"
                    command(adb + ["reverse", "--no-rebind", port, port], limit=5)
                    reverse_state = "created"
                    key_handoff.start()
                    config["keyHandoff"] = {"port": key_handoff.port, "claimHash": key_handoff.claim_hash}
                    payload = json.dumps(config, ensure_ascii=False).encode("utf-8")
                    temporary = str(candidate) + ".tmp"
                    script = ("umask 077; cat > " + shlex.quote(temporary)
                              + " && chmod 600 " + shlex.quote(temporary)
                              + " && mv " + shlex.quote(temporary) + " " + shlex.quote(str(candidate)))
                    # The file contains only a public commitment to the target's
                    # secret. Sending that commitment cannot claim the key.
                    command(run_as(["sh", "-c", script]), data=payload, limit=5)
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
    if key_handoff is not None:
        key_handoff.stopping.set()
    if owned_install and process is not None and finished is None:
        stopped = cleanup_command("force-stop-before-collection", shell([
            "am", "force-stop", "--user", android_user, PACKAGE,
        ]))
        target_stopped = stopped is not None and stopped.returncode == 0
    finish_handoff()

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
                    response = command(run_as(["cat", str(remote / name)]), check=False)
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
                summary_validated = True
    except KeyboardInterrupt:
        failure = failure or "manual_cancelled_during_collection"
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError, subprocess.SubprocessError) as error:
        failure = failure or safe(error)
    finally:
        # Keep the only device copies when collection failed. Still stop the app
        # and remove any unread credential bootstrap; never erase results to hide a failure.
        recovery_required = (installation_state == "unconfirmed"
                             or (owned_install and config_path is not None
                                 and (bool(missing_results) or not summary_validated)))

        finish_handoff()
        if owned_install and process is not None and not target_stopped:
            cleanup_command("force-stop", shell(["am", "force-stop", "--user", android_user, PACKAGE]))
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
        # Absence at preflight is not ownership. Only a confirmed no-replace
        # install by this run authorizes touching this user's side-build data.
        if owned_install:
            installed = cleanup_command("check-package", shell([
                "pm", "list", "packages", "--user", android_user, PACKAGE,
            ]))
            absent = installed is not None and installed.returncode == 0 and not installed.stdout.strip()
            if not absent:
                if config_path is not None:
                    cleanup_command("remove-bootstrap", run_as([
                        "rm", "-f", str(config_path), str(config_path) + ".tmp",
                    ]))
                if not recovery_required:
                    removed = cleanup_command("uninstall", shell(["pm", "uninstall", "--user", android_user, PACKAGE]))
                    if (removed is not None and removed.returncode == 0
                            and removed.stdout.strip() != b"Success"):
                        cleanup_errors.append("uninstall: no success acknowledgement")

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
        "schema": 1, "runId": run_id, "parent": PARENT,
        "parentFixture": cases.get("parent"), "device": args.device,
        "androidUser": args.android_user, "installationState": installation_state,
        "ownedInstallation": owned_install, "keyHandoffConsumed": key_claimed,
        "keyReversePort": reverse_port, "keyReverseState": reverse_state,
        "configurationDelivered": configuration_delivered, "targetStarted": model_run_started,
        "targetFinished": finished is not None, "failure": failure, "files": members,
        "replayOutcome": replay_outcome, "replayExitCode": replay_exit_code, "exitCode": exit_code,
        "cleanupErrors": cleanup_errors,
        "collectionErrors": collection_errors, "missingResults": missing_results,
        "deviceRecoveryRequired": recovery_required,
        "deviceResultDirectory": str(remote) if remote is not None else None,
        "summaryValidated": summary_validated,
        "credentials": "environment to one-use loopback response over adb reverse; only SHA-256 commitment in bootstrap/READY; raw claim secret and full key stay in memory",
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
        print("RECOVERY_REQUIRED: side-build data left in place; recover results or resolve unconfirmed install ownership before cleanup", file=sys.stderr)
    if exit_code == 0:
        print("Raw results saved. Complete human-review.md; structural checks are not a semantic pass.")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
