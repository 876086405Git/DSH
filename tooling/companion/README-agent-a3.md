# A3 — real-model phone replay (manual only)

Parent: **89011333285efa14b525708ff652eaf2ed1d2309**. ADD61 follows PR 1831 and retains the owner's Dart findProxy closure parentheses. It checks for the side build across the whole device, keeps the full claim secret out of bootstrap files, and records reverse creation before dispatch without deleting pre-existing mappings. The fixture remains 13 conversations / 35 user turns with its original parent metadata unchanged. PARENT and launcher-summary.json.parent identify this fixed source baseline, not an automatically detected runtime checkout; report the actual running HEAD separately. No model, device, Flutter, formatter, compiler, analyzer, or test has been run by the author. There are no replay results yet.

## Actual execution path

The target uses production CompanionAgent.say, the Messages decoder/tool loop, CompanionAgentMemoryTools, the production task_status/public_lookup bindings, a real CompanionMemoryOwner and SQLite Store, real HTTP clients, and Android clock/executor capability. It never supplies fake model responses or native channels. Every physical request and response is observed without changing its bytes; request headers and the API key are not logged.

The registry intentionally covers memory semantics and actual public lookup, the A3 cases in SPEC §6 and ADD47. Native alarm delivery, Host file tasks, 4e actions, Page widgets and the background maintenance lane are outside this replay. The target supplies no fictional Host, picker, visible room or foreground permission. Missing native clock/executor, or a lookup without an actual external report, is ENV_UNAVAILABLE/path-not-covered, not a pass.

Each conversation gets a new isolated in-memory SQLite archive and two genuine opaque character IDs. Sources use public Store APIs. Each turn receives a fresh real Android clock and zone; Store, Local and Owner use that clock plus a running Stopwatch throughout the turn. Lookup deadlines therefore consume actual elapsed time. Selection/grants, revisions, control acknowledgement, three-card budgets, receipts and result retirement come from production code. No intent regex selects actions.

The affinity case installs labelled historical replay facts through public presence/interaction APIs in its isolated archive, then uses real SDK daily settlement. Each 60-minute presence segment starts at noon on one of the previous five completed local days, using the sampled offset. A 23:59 launch therefore still seeds whole completed days. The first settlement must reach fixture tier 1 before the repeat-settlement and second-role checks can pass. The historical clock is confined to seeding/settlement; actual model turns resample the native clock and advance. These are fixture facts, not claims that the owner spent five real days with the character. The real model receives SDK relationship context.

## Owner invocation

Use an Android device without the side-build package io.github.ccch1mneyyy.dsh_app.test in any user/profile. The read-only preflight explicitly queries pm list packages --user all; a failed all-user query is not treated as a clean device. A clean selected profile alone is insufficient because install -R checks device-wide. The launcher refuses an existing side build and never clears another profile. Flutter, adb and ordinary repository Android prerequisites must already be available. The regular app package is not changed. Choose one explicit Android user with --android-user (default 0); use adb shell pm list users to find profile IDs. That same numeric user is still used for installation, Flutter launch, force-stop, run-as configuration/collection/removal, the owned-package cleanup check and uninstall. An unavailable profile is a failure, never a fallback to user 0.

Set DEEPSEEK_API_KEY in the invoking process environment. From the repository root:

~~~text
python3 tooling/companion/run_agent_a3.py --device ACTUAL_ADB_ID --android-user 0 --output /path/to/new-a3-results
~~~

A smaller selection:

~~~text
python3 tooling/companion/run_agent_a3.py --device ACTUAL_ADB_ID --android-user 0 --only forgot-umbrella --only web-then-forget --output /path/to/new-a3-sample
~~~

Use --flavor x64 for the repository's x86_64 flavor; arm64 is the default. ADD61 requires this main fix before the owner executes the existing request008 with the real device and their own key. This document does not issue a new execution request.

The launcher sets the existing DSH_SIDE_BUILD=1 switch, builds the debug APK for app/tool/companion_agent_a3.dart once, and explicitly installs it with adb install -R -t --user USER. Modern Android package installation replaces by default: omitting -r is insufficient; -R forbids replacement. Only exit 0 plus the Success acknowledgement records an owned installation. It then runs that same APK with Flutter --use-application-binary and --device-user. This flag is not a claim that Flutter cannot perform another install; ownership was already established by the explicit installation. Unsupported options, timeouts or unconfirmed installation do not fall back to replacement or claim a package found later. The target is outside test/ and is not added to CI or the replay catalog. Real paid requests occur only when the owner starts it. Explicit overall/per-turn limits produce INCOMPLETE on interruption, never a correctness pass.

## Key and outputs

The key is read from the owner's environment and is never written into a host or device file. Before constructing the replay, Dart generates 32 random bytes with Random.secure, keeps their base64url claim secret in memory, and prints only SHA-256(secret) as claimHash alongside the private path in A3_CONFIG_READY. It waits up to 15 seconds for bootstrap. At that READY point, the launcher opens the existing 127.0.0.1-only service for one key claim with a 15-second expiry, bound to this commitment. Bootstrap contains the fixture, run ID, port and claimHash, never the raw secret or full key. It is delivered on adb stdin to the selected user's run-as, written as a 0600 temporary file and atomically renamed. Dart reads and deletes it in finally, checks the commitment against its own in-memory secret, then sends that secret only through the separate, unlogged loopback HTTP client. The server hashes the supplied secret and compares it with the READY commitment; it does not accept claimHash itself as the bearer. Reading bootstrap or launcher.log therefore supplies no accepted claim credential. This reuses the existing READY and loopback handoff; it is not a new model-traffic proxy.

The secret proof is checked before the existing atomic single claim; even a broken first response cannot make the key claimable again. Request logging is disabled and responses use no-store. The raw secret and key are absent from process arguments, Dart defines, the compiled APK and result logs; the public commitment may appear in READY/logs and cannot replace the secret. A fresh isolated installation and this Flutter process's first READY establish the exchange. A repeated READY aborts; a bootstrap for an old/restarted target fails the in-memory commitment comparison instead of reusing a former secret. Dart uses a direct loopback connection without redirects or a system proxy, preserving the owner's parenthesized findProxy assignment. Stop/dispose closes the configuration transport and existing model-turn transports; mounted/cancelled is rechecked after file read and key receipt and before constructing the replay. Timeout closes the actual client. No replay begins from a late response after Stop. The host retires the service on claim, expiry and normal/error/interrupted cleanup.

Before creating adb reverse, the launcher reads the device's existing mappings and refuses to touch an occupied port. It records the port as pending before --no-rebind dispatch, and marks it created only on acknowledged success. For a confirmed created mapping, cleanup first reads the current reverse list with the existing bounded cleanup command. It removes the remote port only when there is one matching entry and its local endpoint still equals the endpoint this run created. An absent entry is reported as already_absent; a changed local endpoint is reported as replaced_left_untouched. Neither is removed, and later cleanup calls do not revisit those terminal states. A failed query, malformed list or duplicate matching entry becomes unresolved with a cleanup error/exit 4. An ambiguous creation result also remains unresolved and never authorizes removal. These outcomes remain in keyReversePort/keyReverseState. The local key handoff is closed on each path. adb has no conditional remove: another client can still rebind between the read and removal, and an identical-endpoint rebind cannot be distinguished. This is a checked best effort, not atomic ownership enforcement. No remove-all operation is used.

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

Check the Success response. Do not delete build outputs, the regular app or other profiles' data as part of recovery. A fresh run needs a new output directory and a device-wide absent side-build package; switching to another profile does not establish absence.

If keyReverseState is unresolved or created after cleanup, preserve that diagnostic and use adb -s ACTUAL_ADB_ID reverse --list to inspect keyReversePort. Do not assume an ambiguous creation belongs to this run. Only after the owner establishes ownership should that exact mapping be removed with adb -s ACTUAL_ADB_ID reverse --remove tcp:ACTUAL_REPORTED_PORT; never remove an unrelated/pre-existing mapping or use --remove-all. The report and collected files remain available even when cleanup returns exit 4.

The Android command forms above follow [run-as's user argument](https://android.googlesource.com/platform/system/core/+/c007c43335ebde667c06a56a9706b403d09c9dd6/run-as/run-as.cpp), [PackageManager's explicit -R option](https://android.googlesource.com/platform/frameworks/base/+/2bd4337f41cc3786c21bbb2df60b56771cedd5b9/services/core/java/com/android/server/pm/PackageManagerShellCommand.java), and [adb's specific reverse mapping operations](https://android.googlesource.com/platform/packages/modules/adb/+/7c2fd99d6ec7e0d2d977ba03cecc82375af1baad/client/commandline.cpp). Flutter's [device-user and prebuilt-application options](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/runner/flutter_command.dart) provide the launch arguments. These source checks are not an executed owner-device compatibility test.

## Reading results

AUTOMATED_PASS means an explicit structural rule held: an expected tool returned applied=true, a forbidden tool was not requested, or a prior card was not removed. is_error=false alone is not treated as a committed effect. A normal completed reply with no tools remains eligible for checks that only forbid calls.

Actual Agent SSE retains model requests which the Agent rejects before adapter dispatch. Adapter records show what executed. The separate lookup answer transport is not counted as an Agent tool request. A denied call is not a successful operation.

For web isolation, a real external report must precede the execution position of a destructive or existing-card-replacing request, including a later call in the same decoded batch. Passing requires the matching Agent memory_change_after_web rejection in the actual next request body and unchanged prior cards. A report without such an attempted path is PATH_NOT_EXERCISED; a turn without a report is ENV_UNAVAILABLE even if it also has a missing-tool diagnostic. Both stay outside structural accuracy.

These checks do not prove semantic equivalence, correct person resolution, or appropriate intimacy. The owner must inspect raw conversations and complete human-review.md. Report structural counts and human judgements separately. Each turn captures new local chat receipts from its own isolated Store; all must have terminal complete. A max_tokens/refusal receipt, absent completion, transport failure, Stop or timeout makes the turn INCOMPLETE before structural diagnostics, even when Agent.error is null. Prior-turn and lookup receipts do not substitute for the current Agent's completion.

Stop and the per-turn timer share a guard captured by every HTTP client in that turn. Cancellation retires the guard, closes its active transports and stops the Agent. A late search cannot send a paid fetch/answer through a new client, and a later turn does not reactivate old clients. Original production receipt settlement is retained. Missing capabilities, interrupted cases and pending manual review never count as semantic success.

Cases cover remember/edit/forget; asking a doctor or teacher; interview moved to Friday; forgotten umbrella; "don't get the time wrong"; unknown rescheduling; web-result isolation and next-turn recovery; relative dates; person aliases shared across roles; hidden role-specific our_story; quiet control versus asking once; compound-fact correction; cross-day affinity.

## ADD61 manual checks — NOT_RUN

These are owner execution plans, not new registered tests or replay conversations. Keep the original 13/35 replay and five result files unchanged.

- Selected profile clean but the side build installed in another profile: preflight must stop before build/install and preserve both profiles. A failed all-user query must also stop.
- Normal READY/claim: bootstrap and stdout contain only the commitment; sending that commitment as the header must not claim the key. The current in-memory secret may claim once; a second claim or broken first response cannot regain it.
- Old/restarted READY, Stop or timeout during configuration: retain the failure/INCOMPLETE evidence and confirm no model run starts from a late bootstrap/key response; no raw secret/key may enter files or logs.
- Reverse already present: preserve it. Reverse creation times out or fails ambiguously: retain the exact pending port as unresolved/exit 4. For confirmed creation, inspect the current mapping before cleanup: remove only an exact local-endpoint match; preserve an absent or rebound port as already_absent or replaced_left_untouched. A failed/malformed/ambiguous listing must leave the mapping untouched and report unresolved/exit 4. Later cleanup calls must not delete an absent/rebound mapping. Preserve the replay's separate outcome; the read/remove race and identical-endpoint rebind remain limitations.

## UI and boundaries

No production UI is required. The manual target shows progress and Stop. 4b/4c/4d/4e remain separate product slices. This runner adds no second controller, model loop, background service or native operation gate.
