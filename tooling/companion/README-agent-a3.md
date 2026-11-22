# A3 — real-model phone replay (manual only)

Parent: **6e4e0baf877c13cae8b71b64a0bc5569885583ba**. This slice adds a manual Android target, its launcher, and 13 conversations / 35 user turns. No model, device, Flutter, formatter, compiler, analyzer, or test has been run by the author. There are no results yet.

## Actual execution path

The target uses production CompanionAgent.say, the Messages decoder/tool loop, CompanionAgentMemoryTools, the production task_status/public_lookup bindings, a real CompanionMemoryOwner and SQLite Store, real HTTP clients, and Android clock/executor capability. It never supplies fake model responses or native channels. Every physical request and response is observed without changing its bytes; request headers and the API key are not logged.

The registry intentionally covers memory semantics and actual public lookup, the A3 cases in SPEC §6 and ADD47. Native alarm delivery, Host file tasks, 4e actions, Page widgets and the background maintenance lane are outside this replay. The target supplies no fictional Host, picker, visible room or foreground permission. Missing native clock/executor, or a lookup without an actual external report, is ENV_UNAVAILABLE/path-not-covered, not a pass.

Each conversation gets a new isolated in-memory SQLite archive and two genuine opaque character IDs. Sources use public Store APIs. Each turn receives a fresh real Android clock and zone. Selection/grants, revisions, control acknowledgement, three-card budgets, receipts and result retirement come from production code. No intent regex selects actions.

The affinity case installs labelled historical replay facts through public presence/interaction APIs in its isolated archive, then uses real SDK daily settlement. These are fixture facts, not claims that the owner spent five real days with the character. Repeated settlement and a second role are checked separately. The real model receives SDK relationship context.

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

Use --flavor x64 for the repository's x86_64 flavor; arm64 is the default. The owner decides whether to execute; this document is not a new request number or a duplicate of request007. ADD49 permits this already-authored 6e4 slice to be merged onto the newer main; it does not change this slice's captured source identity.

The launcher sets the existing DSH_SIDE_BUILD=1 switch and runs app/tool/companion_agent_a3.dart. This target is outside test/ and is not added to CI or the replay catalog. Real paid requests occur only when the owner starts it. Explicit overall/per-turn limits produce INCOMPLETE on interruption, never a correctness pass.

## Key and outputs

The key is read only from the owner's environment. A one-use random token on a localhost HTTP server, reached through adb reverse, delivers it to target RAM. The existing Android network security configuration permits that exact loopback route. Dart defines contain only the ephemeral port/token. This configuration service is not a model proxy; model traffic goes through the production client.

The launcher strips DEEPSEEK_API_KEY from Flutter/adb subprocesses, writes no key configuration file, and compiles no key into an APK. In finally it closes the local service, removes its reverse mapping, and force-stops/removes only the fresh side-build package that was absent at preflight. Existing project artifacts and the ordinary app are retained.

The target writes:

- events.jsonl: sources, context clocks, pre/post cards, dispatched arguments/results, requested tool blocks from real Messages SSE, physical request/response bodies, and settled receipts.
- summary.json: structural checks and their eligible-turn accuracy, attempted HTTP count, model call and adapter dispatch/error counts, unavailable/incomplete cases. It does not invent a human tool-call accuracy.
- human-review.md: every semantic rubric and an actual requested-tool table, with reviewer/verdict/evidence fields pending.

The launcher retrieves these files with run-as and saves a redacted launcher log and file hash inventory. A normal FINISHED marker is successful only when all three result files were actually retrieved; a missing file is recorded as INCOMPLETE and returns a nonzero launcher exit. If stopped, it tries to retain an already-created events.jsonl. It does not invent a completed summary. Stop/dispose while configuration is pending prevents the late configuration from starting a model run. Return only the explicit result directory; no key, build output or APK is requested.

## Reading results

AUTOMATED_PASS means an explicit structural rule held: an expected tool returned applied=true, a forbidden tool was not requested, a prior card was not removed, or no destructive change followed a real web report. is_error=false alone is not treated as a committed effect.

Complete SSE retains model requests which the Agent rejects before adapter dispatch. Adapter records show what executed. A denied call is not a successful operation.

These checks do not prove semantic equivalence, correct person resolution, or appropriate intimacy. The owner must inspect raw conversations and complete human-review.md. Report structural counts and human judgements separately. Transport failures, stops and timeouts are classified INCOMPLETE before checking missing required tools; the failures list remains diagnostic and the turn stays outside the structural accuracy denominator. Missing capabilities, interrupted cases and pending manual review never count as semantic success.

Cases cover remember/edit/forget; asking a doctor or teacher; interview moved to Friday; forgotten umbrella; "don't get the time wrong"; unknown rescheduling; web-result isolation and next-turn recovery; relative dates; person aliases shared across roles; hidden role-specific our_story; quiet control versus asking once; compound-fact correction; cross-day affinity.

## UI and boundaries

No production UI is required. The manual target shows progress and Stop. 4b/4c/4d/4e remain separate product slices. This runner adds no second controller, model loop, background service or native operation gate.
