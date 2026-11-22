# A3 — real-model phone replay (manual only)

Parent: **b09c6ce962a7cf4f90b651fdc14944013636e184**. ADD53 corrects the manual target and launcher merged in PR 1807. The fixture remains 13 conversations / 35 user turns. No model, device, Flutter, formatter, compiler, analyzer, or test has been run by the author. There are no replay results yet.

## Actual execution path

The target uses production CompanionAgent.say, the Messages decoder/tool loop, CompanionAgentMemoryTools, the production task_status/public_lookup bindings, a real CompanionMemoryOwner and SQLite Store, real HTTP clients, and Android clock/executor capability. It never supplies fake model responses or native channels. Every physical request and response is observed without changing its bytes; request headers and the API key are not logged.

The registry intentionally covers memory semantics and actual public lookup, the A3 cases in SPEC §6 and ADD47. Native alarm delivery, Host file tasks, 4e actions, Page widgets and the background maintenance lane are outside this replay. The target supplies no fictional Host, picker, visible room or foreground permission. Missing native clock/executor, or a lookup without an actual external report, is ENV_UNAVAILABLE/path-not-covered, not a pass.

Each conversation gets a new isolated in-memory SQLite archive and two genuine opaque character IDs. Sources use public Store APIs. Each turn receives a fresh real Android clock and zone; Store, Local and Owner use that clock plus a running Stopwatch throughout the turn. Lookup deadlines therefore consume actual elapsed time. Selection/grants, revisions, control acknowledgement, three-card budgets, receipts and result retirement come from production code. No intent regex selects actions.

The affinity case installs labelled historical replay facts through public presence/interaction APIs in its isolated archive, then uses real SDK daily settlement. Each 60-minute presence segment starts at noon on one of the previous five completed local days, using the sampled offset. A 23:59 launch therefore still seeds whole completed days. The first settlement must reach fixture tier 1 before the repeat-settlement and second-role checks can pass. The historical clock is confined to seeding/settlement; actual model turns resample the native clock and advance. These are fixture facts, not claims that the owner spent five real days with the character. The real model receives SDK relationship context.

## Owner invocation

Use an Android device/profile without the side-build package io.github.ccch1mneyyy.dsh_app.test. The launcher refuses to overwrite an existing side build. Flutter, adb and ordinary repository Android prerequisites must already be available. The regular app package is not changed.

Set DEEPSEEK_API_KEY in the invoking process environment. From the repository root:

~~~text
python3 tooling/companion/run_agent_a3.py --device ACTUAL_ADB_ID --output /path/to/new-a3-results
~~~

A smaller selection:

~~~text
python3 tooling/companion/run_agent_a3.py --device ACTUAL_ADB_ID --only forgot-umbrella --only web-then-forget --output /path/to/new-a3-sample
~~~

Use --flavor x64 for the repository's x86_64 flavor; arm64 is the default. ADD53 requires these fixes before the owner executes the existing request008 with the real device and their own key. This document does not issue a new execution request.

The launcher sets the existing DSH_SIDE_BUILD=1 switch and runs app/tool/companion_agent_a3.dart. This target is outside test/ and is not added to CI or the replay catalog. Real paid requests occur only when the owner starts it. Explicit overall/per-turn limits produce INCOMPLETE on interruption, never a correctness pass.

## Key and outputs

The key is read from the owner's environment. Before constructing the replay, Dart prints A3_CONFIG_READY with its app-private temporary-directory path and waits up to 15 seconds. The launcher validates that path and sends the configuration only on adb stdin to run-as, which writes a 0600 temporary file and atomically renames it to dsh-a3-config.json. Dart reads and deletes that file in finally before starting the replay. The key and any bearer-equivalent handoff credential are absent from process arguments, Dart defines and the compiled APK. There is no configuration HTTP endpoint or adb reverse mapping.

The launcher strips DEEPSEEK_API_KEY and ADB_TRACE from Flutter/adb subprocesses. No host configuration file is written. Cleanup force-stops the fresh side build and removes any unread private bootstrap. It uninstalls only the side-build package that was absent at preflight, and only when result collection did not leave missing artifacts. If collection fails, the side build and its remaining results stay available for recovery; launcher-summary.json records deviceRecoveryRequired and the device result directory. Recover those files before manually removing that side build. A cleanup failure is printed on stderr and returns exit 4 while retaining collected files.

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

## Reading results

AUTOMATED_PASS means an explicit structural rule held: an expected tool returned applied=true, a forbidden tool was not requested, or a prior card was not removed. is_error=false alone is not treated as a committed effect. A normal completed reply with no tools remains eligible for checks that only forbid calls.

Actual Agent SSE retains model requests which the Agent rejects before adapter dispatch. Adapter records show what executed. The separate lookup answer transport is not counted as an Agent tool request. A denied call is not a successful operation.

For web isolation, a real external report must precede the execution position of a destructive or existing-card-replacing request, including a later call in the same decoded batch. Passing requires the matching Agent memory_change_after_web rejection in the actual next request body and unchanged prior cards. A report without such an attempted path is PATH_NOT_EXERCISED; a turn without a report is ENV_UNAVAILABLE even if it also has a missing-tool diagnostic. Both stay outside structural accuracy.

These checks do not prove semantic equivalence, correct person resolution, or appropriate intimacy. The owner must inspect raw conversations and complete human-review.md. Report structural counts and human judgements separately. Each turn captures new local chat receipts from its own isolated Store; all must have terminal complete. A max_tokens/refusal receipt, absent completion, transport failure, Stop or timeout makes the turn INCOMPLETE before structural diagnostics, even when Agent.error is null. Prior-turn and lookup receipts do not substitute for the current Agent's completion.

Stop and the per-turn timer share a guard captured by every HTTP client in that turn. Cancellation retires the guard, closes its active transports and stops the Agent. A late search cannot send a paid fetch/answer through a new client, and a later turn does not reactivate old clients. Original production receipt settlement is retained. Missing capabilities, interrupted cases and pending manual review never count as semantic success.

Cases cover remember/edit/forget; asking a doctor or teacher; interview moved to Friday; forgotten umbrella; "don't get the time wrong"; unknown rescheduling; web-result isolation and next-turn recovery; relative dates; person aliases shared across roles; hidden role-specific our_story; quiet control versus asking once; compound-fact correction; cross-day affinity.

## UI and boundaries

No production UI is required. The manual target shows progress and Stop. 4b/4c/4d/4e remain separate product slices. This runner adds no second controller, model loop, background service or native operation gate.
