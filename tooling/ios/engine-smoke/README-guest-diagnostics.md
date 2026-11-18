# Guest smoke diagnostics

`guest-drive.mjs` still runs the same 13 guest scenarios, requires 15 real
approval decisions, and checks their persisted audit records. This change adds
bounded diagnostics to the test driver. It does not add retries, reconnects,
synthetic approval decisions, or a shared runtime patch.

## Report contract

`guest-report.json` retains the status, stage, approval count, scenario results,
model request categories and `nativeHost` summary. It adds `diagnostics.schema=1`.
The console uses that same safe report, and `engine.log` contains safe JSON lines.

| Field | Meaning |
| --- | --- |
| `firstFailure` | First driver-observed failure; subsequent errors and close events cannot replace it. This is an observation, not a proven root cause. |
| `firstServerError`, `lastServerError` | Separately retained server error categories, allowlisted codes, stream/endpoint labels and the phase when observed. No arbitrary error message/details. |
| `rounds[].close` | Numeric close code, exact known reason category or `withheld`, reason byte count, and whether local termination had already been requested. |
| `rounds[].localTerminateRequested` | Local event sequence number, recorded before calling `socket.terminate()`. A later close cannot turn normal cleanup into a mux failure. |
| `cleanup.quit`, `cleanup.kill` | Sequence numbers of local cleanup requests. They do not claim the requested action succeeded. |
| `engine.hostExit`, `engine.childExit` | Bounded exit code/signal metadata and whether quit had already been requested. Exit zero after quit is not a failure diagnosis. |
| `beforeCleanup` | Immutable first-failure snapshot, including both stderr rings, captured before failure cleanup. It stays null when the only failure begins after quit; that case has no pre-cleanup failure snapshot. |
| `stderr.child`, `stderr.host` | Separate raw smoke pipe / native-host-event stderr records, sizes, counts, drops, EOF and incomplete-line state. |
| `engine.firstHostError`, `engine.lastHostError`, `engine.hostDroppedLines` | Safe native error categories/codes and the native host's exact fixed-template lost-log count. |
| `hostTransport` | Only bounded stdout JSON decoder state: ended, pending bytes, oversized/incomplete flags. No pending text. |
| `engineLog` | Successful bytes written, cap reached, write failure, and the number of summary records evicted. A write failure is explicit; it does not expose the filesystem exception text. |

The first and last server error are also retained per round. A received
`turn/end` error or `api-session/error` emission is recorded without changing the
existing approval-wait behavior. A logical stream `end` is distinct from a mux
close. If no server error was received, the server-error fields remain null.

The driver now reports `sessionLabel`/`callLabel` instead of echoing remote
`sessionId`/`callId` strings. These are local fixture labels, not API identifiers.
The actual identities still stay in private driver state and are passed
unchanged to `verifyApproval` and `verifyAudit`. Model/scenario/event names in
output are fixed allowlisted categories. Unknown names become `withheld`.

All sequence numbers are local observation order. A close received before local
termination is not by itself proof of which server component caused it. In
particular, code 1006 does not establish a heartbeat failure. The known fixed
reason mappings are `peer left`, `text messages required`,
`invalid Remote stream request`, and
`Remote stream failure could not be delivered`; only their static categories
are recorded. Every other reason is withheld, with its byte count.

## Text and resource limits

Arbitrary stderr, error messages/stacks, RPC details, protocol frames, tool
content, raw stdout, launch tokens, cookies, URLs and command arguments are
never copied into diagnostic output. Unknown text is deliberately withheld.
Known stderr prefixes are reduced to fixed semantic categories; their suffixes
are also withheld. A signal diagnostic retains only a validated small signal
number. Thus missing readable text does not mean there was no stderr.

This is an output allowlist, not a claim that a token regex can recognize every
possible command or credential. The native host's existing token redaction is
an additional layer; it is not the trust boundary for these reports.

| Resource | Bound |
| --- | --- |
| Each input stderr line | 4,096 UTF-8 bytes |
| Each stderr source ring | 64 records and 32 KiB of serialized records, whichever evicts first |
| `nativeHost` summary | 64 records and 16 KiB |
| `engine.log` | 256 KiB, including one fixed cap marker |
| Round metadata | 16 rounds; this harness uses 13 |
| Host JSON transport line | 64 MiB; a drain can contain 512 escaped 16 KiB native log lines |

The child stderr decoder uses `StringDecoder` across chunks and flushes a final
complete logical line at EOF. An oversized line is discarded as a whole through
its newline/EOF; it is never emitted as several fragments. The host JSON
transport decoder uses the same incremental decoder before parsing its rows.
Each host stderr row is independently checked against the 4,096-byte limit.
The report exposes only sizes/flags for pending fragments at a drain deadline.

Every record insertion follows the same ring eviction path, including repeated
lines. There is no per-unique-line deduplication Map. The first error fields and
pre-cleanup snapshot survive ring eviction or a full disk log. Both current
rings and the one frozen snapshot are bounded; the snapshot is intentionally
retained separately from later cleanup output.

Cleanup waits for child exit as before and additionally allows up to two seconds
for stdout/stderr closure. `cleanup.stdioClosed=false` or an EOF flag remaining
false means the final drain was incomplete. It must not be described as absence
of stderr. Logging failures and model/engine cleanup errors cannot replace an
already recorded first failure.

## Offline checks and CI selection

Run only the pure suite:

```sh
node --test tooling/ios/engine-smoke/guest-diagnostics.test.mjs
```

The current `ios-guest.yml` explicitly selects `guest-harness.test.mjs`, so that
file imports this suite. No workflow edit is needed. To verify that entrypoint
without running its existing loopback SSE model test:

```sh
node --test --test-name-pattern='^guest diagnostics' tooling/ios/engine-smoke/guest-harness.test.mjs
```

These tests use synthetic EventEmitters and byte chunks. They exercise the same
mux listener binding as the driver: error-before-close, the no-waiter RPC gap,
normal intentional cleanup and late events from a previous round, separate
logical-stream/turn errors, pre-cleanup snapshots, both stderr channels, UTF-8
and EOF, whole-line overflow, repeat/byte/disk bounds, and free-text omission
across all diagnostic output surfaces. They do not run an engine, simulator,
network, real approval session or an old crash baseline.

A passing pure suite does not establish that the historical intermittent mux
failure has been reproduced or fixed. Apple CI and the full 13-scenario smoke
remain separate validation steps for the maintainer.
