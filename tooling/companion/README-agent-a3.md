# A3 — real-model phone replay (manual only)

Parent: **1ba8222fd377602ca0aad124dae828044639ad90**. ADD57 follows the ADD53 fixes merged through PR 1824. It corrects the credential handoff, Android user selection, installation ownership, result retention and recovery instructions. The fixture remains 13 conversations / 35 user turns, with its original parent metadata unchanged; launcher-summary.json records the current code parent and original parentFixture separately. No model, device, Flutter, formatter, compiler, analyzer, or test has been run by the author. There are no replay results yet.

## Actual execution path

The target uses production CompanionAgent.say, the Messages decoder/tool loop, CompanionAgentMemoryTools, the production task_status/public_lookup bindings, a real CompanionMemoryOwner and SQLite Store, real HTTP clients, and Android clock/executor capability. It never supplies fake model responses or native channels. Every physical request and response is observed without changing its bytes; request headers and the API key are not logged.

The registry intentionally covers memory semantics and actual public lookup, the A3 cases in SPEC §6 and ADD47. Native alarm delivery, Host file tasks, 4e actions, Page widgets and the background maintenance lane are outside this replay. The target supplies no fictional Host, picker, visible room or foreground permission. Missing native clock/executor, or a lookup without an actual external report, is ENV_UNAVAILABLE/path-not-covered, not a pass.

Each conversation gets a new isolated in-memory SQLite archive and two genuine opaque character IDs. Sources use public Store APIs. Each turn receives a fresh real Android clock and zone; Store, Local and Owner use that clock plus a running Stopwatch throughout the turn. Lookup deadlines therefore consume actual elapsed time. Selection/grants, revisions, control acknowledgement, three-card budgets, receipts and result retirement come from production code. No intent regex selects actions.

The affinity case installs labelled historical replay facts through public presence/interaction APIs in its isolated archive, then uses real SDK daily settlement. Each 60-minute presence segment starts at noon on one of the previous five completed local days, using the sampled offset. A 23:59 launch therefore still seeds whole completed days. The first settlement must reach fixture tier 1 before the repeat-settlement and second-role checks can pass. The historical clock is confined to seeding/settlement; actual model turns resample the native clock and advance. These are fixture facts, not claims that the owner spent five real days with the character. The real model receives SDK relationship context.

## Owner invocation

Use an Android device/profile without the side-build package io.github.ccch1mneyyy.dsh_app.test. The launcher refuses to overwrite an existing side build. Flutter, adb and ordinary repository Android prerequisites must already be available. The regular app package is not changed. Choose one explicit Android user with --android-user (default 0); use adb shell pm list users to find profile IDs. That same numeric user is passed to package checks, installation, Flutter launch, force-stop, run-as configuration/collection/removal, and uninstall. An unavailable profile is a failure, never a fallback to user 0.

Set DEEPSEEK_API_KEY in the invoking process environment. From the repository root:

~~~text
python3 tooling/companion/run_agent_a3.py --device ACTUAL_ADB_ID --android-user 0 --output /path/to/new-a3-results
~~~

A smaller selection:

~~~text
python3 tooling/companion/run_agent_a3.py --device ACTUAL_ADB_ID --android-user 0 --only forgot-umbrella --only web-then-forget --output /path/to/new-a3-sample
~~~

Use --flavor x64 for the repository's x86_64 flavor; arm64 is the default. ADD57 requires the reviewed main fixes before the owner executes the existing request008 with the real device and their own key. This document does not issue a new execution request.

The launcher sets the existing DSH_SIDE_BUILD=1 switch, builds the debug APK for app/tool/companion_agent_a3.dart once, and explicitly installs it with adb install -R -t --user USER. Modern Android package installation replaces by default: omitting -r is insufficient; -R forbids replacement. Only exit 0 plus the Success acknowledgement records an owned installation. It then runs that same APK with Flutter --use-application-binary and --device-user. This flag is not a claim that Flutter cannot perform another install; ownership was already established by the explicit installation. Unsupported options, timeouts or unconfirmed installation do not fall back to replacement or claim a package found later. The target is outside test/ and is not added to CI or the replay catalog. Real paid requests occur only when the owner starts it. Explicit overall/per-turn limits produce INCOMPLETE on interruption, never a correctness pass.

## Key and outputs

The key is read from the owner's environment and is never written into a host or device file. Before constructing the replay, Dart prints A3_CONFIG_READY with its app-private temporary-directory path and waits up to 15 seconds. At that real READY point, the launcher opens a 127.0.0.1-only HTTP service for a single key claim, with a fresh random token and a 15-second expiry. An adb reverse --no-rebind mapping forwards the device loopback port to that host port; it never replaces another mapping. The private bootstrap contains the fixture, run ID, port and short-lived token only. It is delivered on adb stdin to the selected user's run-as, written as a 0600 temporary file and atomically renamed to dsh-a3-config.json. Dart reads and deletes this token file in finally, then retrieves the key directly into memory with a separate, unlogged HTTP client. This is only a key handoff, not a model-traffic proxy.

The token is checked before an atomic single claim; even a broken first response cannot make the key claimable again. Request logging is disabled, responses use no-store, and the token and key are absent from process arguments, Dart defines, the compiled APK and result logs. Dart uses a direct loopback connection without redirects or a system proxy. Stop/dispose closes the pending configuration transport as well as the existing model-turn transports, and current/mounted/cancelled is checked again before starting any model replay. Timeout closes the actual configuration client. The host retires the service after a claim or expiry and on normal/error/interrupted cleanup; only this run's successfully created reverse mapping is removed. No remove-all operation is used.

The launcher strips DEEPSEEK_API_KEY and ADB_TRACE from Flutter/adb subprocesses. Only an installation confirmed as performed by this run authorizes force-stop, private-bootstrap removal or uninstall; preflight absence, a later package listing or a configuration marker alone does not authorize them. An installation with an unknown result is left untouched and reported as unconfirmed. For an owned installation, missing files or an invalid summary preserve device results. Summary validation must confirm the run ID, COMPLETE/INCOMPLETE outcome and counts structure before cleanup is allowed; three successful copies alone are insufficient. A valid INCOMPLETE summary with all three files copied may be cleaned up, but its replay exit code remains 1. launcher-summary.json records androidUser, installationState, ownedInstallation, summaryValidated, deviceRecoveryRequired and deviceResultDirectory. A cleanup failure is printed on stderr and returns exit 4 while retaining collected files.

The target writes:

- events.jsonl: sources, context clocks, pre/post cards, dispatched arguments/results, requested tool blocks from real Messages SSE, physical request/response bodies, and settled receipts.
- summary.json: replayOutcome, structural checks and their eligible-turn accuracy, attempted HTTP count, model call and adapter dispatch/error counts, unavailable/unexercised/incomplete cases. It does not invent a human tool-call accuracy.
- human-review.md: every semantic rubric and an actual requested-tool table, with reviewer/verdict/evidence fields pending.

The launcher requires adb shell_v2 and retrieves these files using adb shell -T with run-as, preserving the remote exit status and separate stdout/stderr. A failed remote cat never becomes a local artifact. Setup and collection share the remaining overall deadline; each cleanup command has a separate five-second timeout. The five-second cleanup bound is an implementation choice.

A3_FINISHED means the files were written; its replayOutcome matches summary.json. The launcher reads the collected summary to distinguish COMPLETE from INCOMPLETE even when all three files exist. Stop/dispose while configuration is pending prevents the late configuration from starting a model run. If stopped after starting, collection still attempts to retain actual files without inventing a completed summary. Return only the explicit result directory; no key, build output or APK is requested.

| Exit | Meaning |
| --- | --- |
| 0 | COMPLETE, all structural checks eligible for passing, files collected and cleanup completed; human review is still pending. |
| 1 | Interrupted/incomplete replay, startup failure or missing/invalid collection. |
| 2 | Environment unavailable or a completed replay with an unexercised required path. |
| 3 | COMPLETE with a failed structural check. |
| 4 | Cleanup failed; replayExitCode in the launcher report preserves the replay's separate outcome. |

INCOMPLETE takes priority over structural failures; for completed replays, a structural FAIL takes priority over unavailable/unexercised cases. Cleanup failure takes priority in the process exit status.

## Recovering a retained side build

Do not rerun the normal launcher against a retained package: its refusal to overwrite it is intentional. First read launcher-summary.json from the failed run. Use its exact device, androidUser and deviceResultDirectory. If installationState is unconfirmed or ownedInstallation is false, the report does not establish that the package belongs to this run: inspect the installation situation before stopping or removing it. Do not infer ownership merely from pm list packages.

For a confirmed owned installation, stop the same user's side build before collecting a still-running target:

~~~text
adb -s ACTUAL_ADB_ID shell -T am force-stop --user ACTUAL_USER_ID io.github.ccch1mneyyy.dsh_app.test
~~~

The following Python 3 snippet can be saved and run on the owner's host, including Windows. Set report_path to the failed run's actual launcher-summary.json. It keeps binary stdout unchanged and writes a file only after that individual remote cat succeeds; it avoids shell-redirection encoding differences.

~~~python
import json
import pathlib
import shlex
import subprocess

report_path = pathlib.Path("PATH_TO_FAILED_RUN/launcher-summary.json")
report = json.loads(report_path.read_text(encoding="utf-8"))
if not report.get("ownedInstallation") or not report.get("deviceResultDirectory"):
    raise SystemExit("Resolve installation ownership and the result directory first")
remote = pathlib.PurePosixPath(report["deviceResultDirectory"])
recovered = report_path.parent / "recovered"
recovered.mkdir(exist_ok=False)

def read(parts):
    command = ["run-as", "io.github.ccch1mneyyy.dsh_app.test",
               "--user", str(report["androidUser"]), *parts]
    return subprocess.run(["adb", "-s", report["device"], "shell", "-T",
                           shlex.join(command)], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=30)

listing = read(["ls", "-la", str(remote)])
if listing.returncode != 0:
    raise SystemExit("Cannot inspect device results: " + listing.stderr.decode(errors="replace"))
print(listing.stdout.decode(errors="replace"))
for name in ("events.jsonl", "summary.json", "human-review.md"):
    result = read(["cat", str(remote / name)])
    if result.returncode == 0:
        (recovered / name).write_bytes(result.stdout)
        print(name, "COPIED", len(result.stdout), "bytes")
    else:
        print(name, "NOT COPIED", result.stderr.decode(errors="replace"))
~~~

A successful directory listing that lacks a requested file means there was no such device artifact to recover at that time (for example, Stop happened before the target wrote its final summary). A file present in that listing whose cat fails is a failed copy. A failed directory listing cannot establish that a file was never written. Keep the command failures and the original incomplete-run status; do not create substitute empty files or claim a successful replay.

Confirm each requested copy succeeded and inspect the recovered files, including the expected summary runId/outcome/counts when a summary exists. Preserve an invalid summary as diagnostic evidence; it is not a valid replay result. Only after the needed files or failure evidence are safely retained should the owner remove this confirmed run's package for the same user:

~~~text
adb -s ACTUAL_ADB_ID shell -T pm uninstall --user ACTUAL_USER_ID io.github.ccch1mneyyy.dsh_app.test
~~~

Check the Success response. Do not delete build outputs, the regular app or other profiles' data as part of recovery. A fresh run needs a new output directory and a now-absent side-build package.

The Android command forms above follow [run-as's user argument](https://android.googlesource.com/platform/system/core/+/c007c43335ebde667c06a56a9706b403d09c9dd6/run-as/run-as.cpp), [PackageManager's explicit -R option](https://android.googlesource.com/platform/frameworks/base/+/2bd4337f41cc3786c21bbb2df60b56771cedd5b9/services/core/java/com/android/server/pm/PackageManagerShellCommand.java), and [adb's specific reverse mapping operations](https://android.googlesource.com/platform/packages/modules/adb/+/7c2fd99d6ec7e0d2d977ba03cecc82375af1baad/client/commandline.cpp). Flutter's [device-user and prebuilt-application options](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/runner/flutter_command.dart) provide the launch arguments. These source checks are not an executed owner-device compatibility test.

## Reading results

AUTOMATED_PASS means an explicit structural rule held: an expected tool returned applied=true, a forbidden tool was not requested, or a prior card was not removed. is_error=false alone is not treated as a committed effect. A normal completed reply with no tools remains eligible for checks that only forbid calls.

Actual Agent SSE retains model requests which the Agent rejects before adapter dispatch. Adapter records show what executed. The separate lookup answer transport is not counted as an Agent tool request. A denied call is not a successful operation.

For web isolation, a real external report must precede the execution position of a destructive or existing-card-replacing request, including a later call in the same decoded batch. Passing requires the matching Agent memory_change_after_web rejection in the actual next request body and unchanged prior cards. A report without such an attempted path is PATH_NOT_EXERCISED; a turn without a report is ENV_UNAVAILABLE even if it also has a missing-tool diagnostic. Both stay outside structural accuracy.

These checks do not prove semantic equivalence, correct person resolution, or appropriate intimacy. The owner must inspect raw conversations and complete human-review.md. Report structural counts and human judgements separately. Each turn captures new local chat receipts from its own isolated Store; all must have terminal complete. A max_tokens/refusal receipt, absent completion, transport failure, Stop or timeout makes the turn INCOMPLETE before structural diagnostics, even when Agent.error is null. Prior-turn and lookup receipts do not substitute for the current Agent's completion.

Stop and the per-turn timer share a guard captured by every HTTP client in that turn. Cancellation retires the guard, closes its active transports and stops the Agent. A late search cannot send a paid fetch/answer through a new client, and a later turn does not reactivate old clients. Original production receipt settlement is retained. Missing capabilities, interrupted cases and pending manual review never count as semantic success.

Cases cover remember/edit/forget; asking a doctor or teacher; interview moved to Friday; forgotten umbrella; "don't get the time wrong"; unknown rescheduling; web-result isolation and next-turn recovery; relative dates; person aliases shared across roles; hidden role-specific our_story; quiet control versus asking once; compound-fact correction; cross-day affinity.

## UI and boundaries

No production UI is required. The manual target shows progress and Stop. 4b/4c/4d/4e remain separate product slices. This runner adds no second controller, model loop, background service or native operation gate.
