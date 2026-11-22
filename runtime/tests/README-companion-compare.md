# Fixed two-draft comparison source tests

These tests execute the production comparison runner, task store/routes and the
locked Domain/JSON/filesystem code against temporary synthetic originals. They
do not start the complete engine or a device. The supported-statfs branch and
Cordis service identities are explicitly supplied by the fixtures. Model
semantics are synthetic; no paid model is called.

Prepare the exact task and file-source prefixes using the instructions in
`README-companion-notes.md` and the existing find-source tests. The task
preparation command must receive the runtime **after**
`companion-compare-output-window.diff`; an older 3000-token auxiliary source is
rejected by its hash. The new patch admits at most 4000 output tokens. The E and
F callers continue to request their original 3000-token limits.

With `COMPANION_TASK_HARNESS`, `DSH_PREFIX` and `DSH_FS_NOTES_SOURCE` pointing to
those exact prepared prefixes, run the finite modules:

```sh
node --test --test-reporter=spec runtime/tests/companion-compare-content.test.mjs runtime/tests/companion-compare-runner-source.test.mjs runtime/tests/companion-compare-model-source.test.mjs
```

The runner fixture uses real loopback task HTTP, actual selected files and
durable storage. Its model owner/stream is a controlled peer. The separate
model-source module uses the production `createNotesExecutionOwner.openModel`,
locked `LlmRuntime` and DeepSeek serializer/fetch/SSE translator with a synthetic
loopback server. It checks light/default and full/original-session selections,
the complete two-input body, no tools/history/Agent creation, raw cumulative
usage omissions, and both preliminary and final request-window boundaries.

The recovery cases deliberately interrupt before a durable report commit or
close the actual owner during original-file verification, then close and reopen
the actual Domain on the same storage. They are **not SIGKILL, power-loss, or
native filesystem crash tests**. An owner stop preserves its unpublished
attempt and permits a new report attempt under the unchanged agreement. A
cancel, changed agreement, expired deadline or ordinary unpublished completion
does not grant this retry. Every task keeps its one model-attempt limit and its
cumulative spent/held budget, across amendments and restarts.

When `I_COMPARE_WIRE_FIXTURE` is set to a path, tests may export the actual
synthetic HTTP snapshots alongside that path. Owner-stop exports include the
before/after snapshots with the same store/task/execution/revision and immutable
old report attempt. SDK/App consumers must retain that history and accept the
new report only after the explicit `report_owner_stopped` predecessor. The
fixture IDs and versions are produced by the actual host; consumer tests must
not rewrite them and still claim to consume the same wire.

Known scope: the deterministic comparator groups losslessly by unique-line
anchors; it does not promise minimal edit distance or semantic ranking. Runtime
source passes do not establish Dart/Flutter compilation, phone/desktop UI,
native Android/OHOS execution, model recommendation quality, or an unsupported
filesystem/approval path. Those results require their own evidence.
