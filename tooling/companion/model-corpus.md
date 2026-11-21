# Current stage replay against historical Live2D facts

This is a developer evaluation tool. It reuses the current repository's actual
`StageModel.fitParams`, `has`, `range`, `set` and `add` methods. It does not add an
adapter algorithm, install a skill, write an adapter, or change the stage/App.

```sh
node --test tooling/companion/replay-model-corpus.test.mjs
node tooling/companion/replay-model-corpus.mjs --out /tmp/new-model-report.json
```

The output path must not exist. Omitting `--out` writes the whole report to stdout.
No network, package installation, Core binary, model binary, texture or browser
is needed. The JSON has a developer-report format, not the App adapter format.

## Exact code and input provenance

The default stage is `app/assets/companion/stage.js`, pinned to the reviewed
SHA-256 `3e2a0516e7f3c433bc2556f1702964e6ccb10cf94331233b824c3412acc83260`
(the companion performance pass: render rate, the water's motion and the float
window's bounds; the replayed `STANDARD`…`encodePath` slice is byte-identical to
C906's stage `157acf7397e604e53184ee93fa217af11909b91ed29c102b9b4571d6fed56f67`,
which added complete rule-alias facts and preserved numeric probe precision;
fit/set/add routing is unchanged. The earlier PR #753 stage was
`25e103c70b5fffa9ebab580d645bd8cb9f0dcc3f818f16a33c47a65db448b22a`; the facts were first replayed against c76's
`270b4721f5458cb75faf89ea2cb9321c404aa3800366cf0544e23b2830b22a8b`, with the
same 356/432 result). Update the pin and this line together whenever the stage
changes.
A byte change fails before evaluation. After inspecting a different trusted
stage, a maintainer can explicitly provide its SHA:

```sh
node tooling/companion/replay-model-corpus.mjs \
  --stage /path/to/reviewed/stage.js \
  --expected-stage-sha256 FULL_REVIEWED_SHA256 \
  --out /tmp/new-model-report.json
```

The runner requires unique ordered source boundaries from `const STANDARD` to
the next `const encodePath`, then evaluates that exact slice. It does not copy
the fitting method into a second implementation. Changed boundaries or missing
methods fail for inspection. Both whole-file and slice SHA appear in the report.
Node's VM is an isolation convenience, not a security sandbox: use trusted,
reviewed source. No browser boot or model `load()` method is invoked.

`fixtures/live2d-core-facts-v1.json` and `live2d-core-sources-v1.json` are exact
metadata files from the final C720 patch, whose SHA is
`b680a925e6effca5b0bdb3eb5f201709e79f514dbd1beee35cb3b62ec55f86f7`, based on
`98d4628746e2a37f09ebfb05530a718622357982` after C710. Their own SHA values are
checked in the runner before parsing:

| File | SHA-256 |
| --- | --- |
| `live2d-core-facts-v1.json` | `26b3df74c076d20e44e6fff9c4d813a22fef1b92d650ed91b6671aeefe43d8c7` |
| `live2d-core-sources-v1.json` | `483df289fb8c5d0f50dc1e284504d458d5912a9159a7d09a3eaac2a052378e06` |

The corpus has 24 distinct raw `.moc3` hashes and 18 character/source families.
Different variants remain separate binary samples: five Nito variants, two
Epsilon editions, and current/historical Mao. Tororo and Hijiki share a raw moc
hash and are counted once. Source URLs, archive hashes, Git identities where
available, and original model3/cdi3 hashes are preserved per sample. The sources
file records the original license/terms references; the tool makes no new grant.
No original model binary, Core, texture, audio, mesh array or motion curve is
distributed by this change.

The facts were measured on 2026-11-07 with official SDK Core 6.0.1, exact Core
SHA `8741f739779b5d5210872bd3d7d99f0f1e56e6c87409e7d26d6bb4b80aa1ef47`.
Those historical CPU load/update results are read, not remeasured. The original
record's App aggregate runtime digest is retained only inside historical
provenance, with its original **not verified** status. It is never used as a pin
or an identity claim for the current installed App runtime. Current Core/runtime
verification remains false in every new report.

## What is actually replayed

Measured parameter ids/min/max/default and original model3 blink/lip groups are
presented to the actual stage methods by small metadata accessors. The fixture
model is not a Cubism Core implementation. Its setters only capture arguments:
they do not simulate native range clamping, draw pixels, execute an expression,
run physics or play a motion. The report records calls at each standard domain's
low/high values and zero additive delta, along with the measured target range.
This can expose a stage call outside a native range without claiming what the
actual Core would subsequently render.

The c76 replay produces **356/432 rule bindings (82.4074%)**: 18 current standard
semantic parameters times 24 distinct moc hashes. All emitted native targets
exist in their measured parameter tables. This is rule coverage, not semantic
correctness or visual accuracy. C720's historical 339/432 used its different
adapter algorithm/schema; the difference is not evidence that 17 visual errors
were fixed. That algorithm and its generated adapters are not imported here.

All historical `frameworkResourcesLoaded` values are false. Every replay row
therefore has empty `verifiedEffects.expressions` and `verifiedEffects.motions`,
even when the model3 inventory lists resources. Names and file references do not
prove successful Framework loading or harmless effects. No automatic execution
permission or same-snapshot App adapter approval is produced.

Compact bounds are insufficient to replay hit testing, framing, texture alpha,
or action extremes; those paths are deliberately unmeasured. Frame rate, visual
accuracy, AI requests and AI tokens stay null. The recorded mask maximum is a
historical count, not a new renderer-capacity test. This tool is compatible with
C810 as separate developer evidence; it does not change C810's contract/skill or
claim that its page orchestration is complete.

## Optional future remeasurement

Offline replay is the only default and the only implemented path here. No
downloader or Core evaluator is silently started. A new actual measurement is a
separate explicit workflow: obtain permitted original inputs from the preserved
source manifest, verify the archive/file fingerprints, supply an independently
reviewed and licensed Core with an explicit hash, and record new metadata and
the actual installed runtime's identity if claiming a match. Keep original
third-party inputs outside release/evidence artifacts.

The original C720 `companion_adapter_evaluation_fetch.py` and
`companion_adapter_evaluation_probe.cjs` remain historical optional tools in
that delivery. They are not included or invoked by C904: the old probe hardcodes
an old App aggregate digest and cannot certify today's runtime. A maintainer
porting it must remove that assumption, preserve real output-byte budgets and
source checks, and distinguish CPU-only measurements from Framework/GPU/App
measurements. The old evaluation/compaction runners depend on `adapter_rules.js`
and must not be introduced as a parallel runtime for this repository.
