# Four selected receipts to one new workbook — finite source candidate

This candidate is bound to owner `a3a9502be336a2d1e3891db5cf86511e52dc6677`,
which already contains G/H/I, followed by J files and the dependency-based J PDF layer.
It is not complete phone or native/device acceptance. The earlier PDF vendor
layer is blocked by the task's no-assets rule and must not be applied.

## Fixed operation

`host.receipts_to_sheet` consumes exactly four explicit original file bindings
and versions. It does not enumerate a folder or search for a fifth receipt. The
output is a single chosen `.xlsx` basename in an already bound directory, with
`writeMode:createNew`. Duplicate bindings and duplicate directory/name/version
selections are rejected. Existing output is never overwritten or renamed.

Receipt binding uses the existing `POST /dsh-go/v1/companion/tasks/inputs` with
the explicit J kind. Text/Markdown and supported PDF inputs have a 4 MiB byte
limit. The old comparison binding shape and two-draft 64 KiB limit remain. A
receipt binding cannot enlarge the I comparison limits.

The internal Domain descriptor is version 3, compatible with versions 1 and 2.
HTTP remains version 1. Real old-source migration tests check that opening does
not rewrite a medium, first publication stamps version 3 even when it is merely
an old-task cancellation, and the old v1/v2 code subsequently refuses a downgrade
without changing bytes. Phone storage has no new DDL in this candidate family.

## Observable facts and local field rules

J uses **zero model attempts**. The two steps are `readInputs` and `writeSheet`.
No paid model, ordinary chat prompt, tool-generating model, OCR purchase, or
external search is involved. The local extraction rules accept explicit whole
line labels with a colon; unmatched or ambiguous fields are `unverified`, never
`not_present`.

* Dates accept a full valid year/month/day in year-first numeric or Chinese
  notation. No missing year, filename, modification time or locale guess is used.
* Items accept explicit `项目`, `品名`, `品目`, or `Item` labels with bounded text.
* Amounts require a decimal and explicit supported currency fact on the same
  labelled line. Supported aliases normalize to CNY, USD, EUR, GBP, JPY, HKD or
  SGD. A bare currency symbol, grouping comma, negative value, more than two
  decimal places, conflicting candidates or arithmetic expression stays
  unverified. Exact string normalization performs no floating-point sum or
  currency conversion. These are conservative supported formats, not a claim
  that other valid receipts contain no amount.

Each verified field retains an exact contiguous source line and its real text
line or PDF extraction-page/line position. A PDF extraction line is not a visual
line, OCR result or claim about image content. `readComplete` describes the raw
bounded file read; `parseComplete` describes completion of the supported text
extraction. A scan can have both true while all fields remain unverified and
`reason:pdf_empty_text`. The report and workbook explicitly say no text layer was
read. A mixed PDF with an amount in text and a date only in pixels retains that
amount and leaves the date unverified.

Source bytes/text are task-private. The public report contains four sources,
four rows, short field evidence and derived coverage counts/gaps. It does not
include the four originals or put their details into chat memory/notifications.
The first observed version is retained. Changing originals before write-time
verification removes their unsupported fields from the candidate; changing a
source again after staging stops publication. These checks are observed points,
not an atomic filesystem lock against unrelated writers.

If no row has a verified field, there is no empty workbook. A read report with
no usable fields can terminate before a write claim. If previously read fields
all become invalid at write-time verification, the failed write retains a new
zero-field report beside the immutable earlier read report. Consumers must not
erase either observation or reject this valid failed result.

## PDF and workbook implementation

`receipt-pdf.js` imports no PDF.js module until requested. Its capability gate
checks the actual Node version/module hook API and installed dependency version.
A dedicated worker inherits the runtime's existing preloads/flags, denies optional
native canvas resolution, and uses the exact locked pdfjs-dist 6.5.438 dependency
with Wasm disabled. It receives only original bytes and approved fixed local resources.
It does not render images or execute PDF actions. Limits cover 5 pages, 4 MiB
extracted text, item count and worker V8 heap. Worker resource limits are not a
hard bound on all ArrayBuffers or total process RSS. See the separately reviewed
PDF component for its exact dependency, licenses, preparation and test records.

The new workbook uses the existing locked fflate 0.8.3 official browser ESM source
and MIT license, vendored explicitly to avoid reliance on undeclared transitive
dependencies. Only synchronous ZIP APIs are used. The writer emits exactly five
OOXML package parts, one visible sheet, the four agreed columns and four source
rows. All twenty cells are explicit strings. No formula, macro, external link,
hidden sheet or total is generated. Formula-looking input remains literal text.
XML and ST_Xstring escaping preserve supported Unicode/control sequences; the
phone's text-cell reader needs the corresponding single-pass ST_Xstring decode.

The finite verifier is not a general workbook importer. It unpacks bounded
members, checks the complete static parts and exact cell structure, decodes all
twenty strings and compares every value with the recorded candidate grid. The
runner calls it on actual bytes reopened through the original filesystem
artifact identity/hash/size path. Checking the in-memory grid alone never
registers an artifact. The output is at most 256 KiB.

## Approval, budget and publication recovery

The existing fixed-task Agent/Session and actual approval path are reused. J can
create/resume that owner with empty agent options and no configured model. An
unused default-model change does not invalidate the local operation; original
filesystem, source session, agent, sandbox policy and approval-policy guards
remain. F still requires its configured selection, even if another caller tries
to request the optional path. The local output choice grants no sandbox rights.

Read, parse, generation and publication use the same cumulative 300000 ms
spent/held budget. Explicit waits for the original approval card have no active
execution hold. Deadlines and elapsed execution time are checked at guarded
boundaries, and parser workers receive the execution signal. Unknown holds after
a lost process remain consumed; neither a restart nor amendment resets them.

The original retained stage, durable publication intent, possible-send marker,
hardlink and identity-based inspection are the same publication aggregate used
by F. Before the possible-send marker, a narrowly proven unattempted write can
claim new remaining time; an existing stage is reused. Once the marker exists,
recovery only inspects and reopens that original object. It cannot relink, choose
another name, or adopt another inode with identical bytes.

An owner stop during reading retains individual observations and can later read
only the remaining originals. Previous completed report attempts remain
immutable. An owner stop after write claim but before intent can also resume,
because the durable possible-send boundary has not been crossed. The old claim
and any unknown elapsed hold are retained.

An artifact already registered on a task prevents a later same-task amendment.
An amendment or cancellation can instead be accepted while an earlier physical
publication is still unconfirmed. If later read-only reconciliation finds that
old effect, the old artifact remains: a newer amended head is
`partial/prior_revision_effect`, and a cancelled head stays cancelled. Neither
means that the newer agreement executed. No new workbook is produced.

## Original workbook route

`GET /dsh-go/v1/companion/tasks/{taskId}/artifacts/{artifactId}/content`
requires exactly one `hostStoreId` and one `hostExecutionId` query value. The
paired owner and original store/execution/task/artifact are checked before IO.
It only serves registered J workbooks with original identity/hash/size. It does
not accept a client path or expose receipt originals through this route.

Success has the exact XLSX MIME, actual Content-Length and `Cache-Control:
no-store`. Missing originals return 404, changed objects 409, and currently
unverifiable originals 503, using the existing task JSON error shape. Metadata
that the task wrote a workbook is preserved when it later cannot be opened.
The old JSON text-artifact route refuses XLSX and has no generic-file fallback.

## Finite actual execution and its limits

The source harness refuses missing or mismatched locked source dependencies. It
copies and hashes every used production/test/resource file, captures immutable
logs and shared real task wires, and asserts sources do not change while running.
Actual Node IO, Domain/JSON, local HTTP, PDF worker, ZIP bytes, hardlinks and
SIGKILL/reopen operations execute on Linux as a non-root user. The supported
statfs branch is explicitly supplied because this environment's real overlay
filesystem is rejected by production. The framework/factory/Session services in
focused tests are explicitly controlled peers; this is not a full engine boot.

The related suite contains the existing F/H/I regressions, actual adapter/HTTP
model evidence for F/I, J's local field/workbook and Host cases, zero-model
approval cases and v1/v2 migrations. Android and OHOS refer to exact locked JS
source variants exercised here, not device execution. Shared fixtures come from
actual successful cases, and producer runs that contained unrelated failures
remain labelled as such in their records.

Not run here: Dart, Flutter, the whole engine, Android/OHOS native builds or
devices, paid models, unsupported filesystem behavior or power loss. SIGKILL is
actual process death, not a power-loss claim. Separate SDK and App review, final owner-head rebase and complete feature
acceptance remain distinct gates. See the session's `J-source-*.json`, immutable logs, provenance
ledger and component review manifests for exact executed versions and results.
