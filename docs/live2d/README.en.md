# Companion room · Live2D model guide

> For model authors and anyone who wants to import their own model. By the end you should know how to make an asset pack that loads, stands on the stage, turns its head, blinks and reacts to touch — and exactly what a fitting (adapter) can and cannot do.

The Companion room is a fixed Live2D stage: the app owns the stage code and the procedural motion, and models come in as **asset packs**. Fitting happens on two levels:

- **Deterministic compatibility is the app's job**: rendering, file structure, texture limits, masks, size limits, safety checks.
- **Judgement is left to the user's AI or to you, the author**: which parameter turns the head, which expression means shy, where a head pat lands. The AI only produces data (an adapter); the app still executes and validates it.

## 1. Supported range

| Item | Conclusion | Source |
|---|---|---|
| Runtime | Official **Cubism Web Framework 5-r.5 + Core 6.0.1**, shipped with the pack/app. Authors cannot replace or bundle their own | `docs/design/companion.md` §3, `app/assets/companion/stage.js` |
| Model format | **.moc3 only**; anything exported by Cubism 3 or later goes through this path | `app/lib/companion/companion_pack.dart` |
| moc version | moc3 format enum **1–6** (Core 6.0.1 has latestMocVersion 6). Newer versions fail to load with "newer Cubism… reads up to N" | `stage.js` header check, `tooling/companion/fixtures/live2d-core-sources-v1.json`, `docs/design/workshop-worker.md` |
| Cubism 2 | **Not supported**. `.moc` + `model.json` is rejected with a message to re-export as moc3 | `companion_zh.arb` / `companion_en.arb`, `companionPackLegacyModel` |
| Outfits/switches | Model parameters; the AI fitting never drives clothing, watermarks, visibility switches | fitting contract and `stage.js` protected names |
| Multiple models | A pack may hold several models; the stage uses the one `character.json`'s `model` names (else the first `.model3.json`) | `stage.js` `resolveModelFile` |

**Never ship a runtime of your own.** If a pack contains `runtime/`, its SHA-256 must match the one pinned in the app, or the whole pack is refused ("the runtime in this pack doesn't match this version of the app"). Authors only provide `character/`.

## 2. Preparing an importable model pack

### 2.1 The smallest usable pack

Zip one model folder. Either the zip root is the model's contents (recommended), or the folder itself is the only top-level directory (the installer strips it):

```
my-model.zip
├─ my.model3.json
├─ my.moc3
├─ textures/ …
└─ optional: *.exp3.json, *.motion3.json, *.physics3.json, *.pose3.json, *.wav, *.mp3
```

Rules (enforced in `companion_pack.dart`'s install path):

- A `.model3.json` is **required**; without it you get "No Live2D model (.model3.json) found in the pack."
- `character/` accepts only: `.json .moc3 .png .jpg .jpeg .webp .wav .mp3 .txt .md`. `.cmo3`, `.psd`, `.clip` etc. are skipped silently (not refused, not kept).
- Paths must be safe relative paths: no `..`, no leading `/`, no backslashes or NUL bytes; symlinks are refused.
- File names must not collide after normalisation (case, Unicode aliases). Avoid `A.png` and `a.PNG` in one pack.
- Limits: **400 MB expanded, 4000 files** for local import. Over that: "This asset pack is too large."
- Images are accepted by extension, but **make sure PNG/JPEG/WebP really decode**: a broken texture makes the stage fail.

### 2.2 Character-only packs

This is the standard authoring form, and the format of a "Companion" entry in the Workshop. It carries no runtime and reuses the one already installed on the phone. Therefore:

- The user's phone must already have a full asset pack (bundled or official) installed; otherwise: "This pack only has a character and there's no runtime on this phone yet."
- Full packs (with `runtime/`) are built only by the official pipeline; authors ship `character/` content only.

### 2.3 Optional `character.json` (strongly recommended)

Put `character.json` at the model folder root. Every field is optional; with none, the stage falls back to standard parameter names and default zones — and the AI cannot fix the zones for you (see §4).

| Field | Type | Meaning |
|---|---|---|
| `schema` | int | `1` |
| `model` | string | Model path relative to `character/`; defaults to the first `.model3.json` |
| `name`/`author`/`license`/`source` | string | Shown at the bottom of the character menu; checked when publishing to the Workshop |
| `framing` | `{zoom, y}` | Default framing; zoom ~0.3–3, y is a vertical offset |
| `mark` | `[x, y]` | Where emotes (hearts, sweat drops) appear, model coordinates |
| `tail` | string[] | Tail parameter ids, root to tip |
| `zones` | array | Touch zones, see below |
| `emotions` | object | emotion → `{expression, face, gaze}`, merged onto the built-in table |
| `actions` | object | action name → `{ms, tracks}` curves, merged onto the built-in table |

Each `zones` item: `{"id":"head|face|body|tail|legs","from":number,"to":number,"xFrom"?:number,"xTo"?:number}`.

- Coordinates are in **model-matrix space, before the camera**: `from = (1 - top) / 2`, `to = (1 - bottom) / 2`, with `0 ≤ from < to ≤ 1`.
- `xFrom`/`xTo` are an optional horizontal band (say a tail on the right), always paired and `xFrom < xTo`; not screen percentages.
- Part names do **not** become coordinates. Without `zones`, only the model's HitAreas can help; otherwise default zones (head/face/body/legs) are used. The AI fitting can only copy existing geometry, never invent it.

`emotions` example (structure from `tooling/companion/whale-girl.character.json`; **do not reuse that model's assets**):

```json
{
  "happy": { "expression": "02 grin", "face": { "ParamEyeSmile": 0.7 } },
  "shy":   { "expression": "04 blush", "face": { "ParamEyeSmile": 0.2 }, "gaze": [0.45, -0.35] }
}
```

`expression` is the loaded name of a `.exp3.json`; `face` is an additive delta on standard parameters (not an absolute pose); `gaze` offsets the eyes. `actions` example:

```json
{ "wave": { "ms": 1900, "tracks": { "Param_arm_R1": [[0, 0], [0.18, 26], [1, 0]] } } }
```

Each `tracks` entry is a `[time 0–1, parameter value]` polyline added on top of the base pose. Action names may be the 12 built-ins (`nod`, `nodSmall`, `shake`, `tilt`, `tiltLeft`, `lookUp`, `recoil`, `duck`, `sway`, `stretch`, `yawn`, `wave`) or your own.

### 2.4 Optional `adapter.json`

`adapter.json` is the fitting (the app's AI fitting writes it). Authors may pre-ship one to skip the user's first fitting. Rules:

- `moc` must be the **SHA-256 of the moc3 bytes** (lowercase hex, hashing file content, not the path). The app compares it with `sha256(moc3)`; on mismatch the whole fitting is removed and re-fitted.
- Fields follow `app-local-adapter-v1` (§4). Invalid items are dropped, but **import does not validate it** — the stage will apply what it can, so check it yourself.

## 3. Importing into the app

Path: **Switch host → Companion room**.

1. On first entry (or after removing assets) you get the "Bring her home" page; tap **Import asset pack** and pick your zip.
2. The app checks, in order: zip opens, paths safe, file types, size/count, runtime digest (if present), a `.model3.json` exists. Only then it writes into app-private storage (installation is transactional; a failure keeps the old pack).
3. The stage loads and probes the model: whether it loads, moc version, parameter table, expression/motion/part names, standard-parameter coverage, zone sources. The report goes to the app and to fitting only; it contains no model files or textures.
4. If fitting is needed, an offer appears (§4); otherwise the model is ready.
5. To switch packs: menu **More → Remove assets** (deletes the character assets on this phone; chats are unaffected), then import again from the "Bring her home" page.

Common errors:

| Message | Cause | Fix |
|---|---|---|
| This file can't be opened… | Corrupt zip / not a zip | Re-zip; avoid archivers that add junk files |
| No Live2D model (.model3.json) found | Model folder missing, or nested one level too deep | Make the zip root the model contents |
| This is an old Cubism 2 model | `.moc` + `model.json` | Re-export as moc3 in Cubism Editor |
| … exported by a newer Cubism (moc version N) | moc enum above the Core limit (6) | Export an older version in the editor |
| This pack only has a character and there's no runtime… | character-only pack, no full pack installed | Install the full/official pack first |
| The runtime in this pack doesn't match… | Bundled runtime digest differs | Remove `runtime/`; ship `character/` only |
| The pack has files or paths that aren't allowed | `..`, absolute paths, symlinks, non-whitelisted files under `character/` | Clean up and re-zip |
| This asset pack is too large | > 400 MB or > 4000 files | Trim unused assets, compress textures |
| Couldn't write the files… | Storage full / permissions | Free space |

## 4. The fitting (app-local-adapter-v1)

### 4.1 What it does

A fitting wires the stage's standard vocabulary to your model's parameters: which axis turns the head (`ParamAngleX`), which expression and face deltas make `happy`, which vertical band is a head pat. The stage executes it as data only — no code.

It can be produced in two ways:

The app only offers fitting when judgement is actually needed — any of: one of the four core parameters is missing (`ParamAngleX`, `ParamAngleY`, `ParamEyeLOpen`, `ParamMouthOpenY`), zones are still the defaults, there is no emotion table while the model has at least 2 expressions, or tail-like parameters exist but no `tail` was registered. Configure all of that in `character.json` and no fitting is needed.

1. **AI fitting** (the normal user path): the app sends the model name, the parameter list (id/display name/range/group), expression/motion/part names, the user's one-line "what's off", and the current fitting to the user's own model (light mode, DeepSeek API, billed per request). The answer is validated in the app, then written to `character/adapter.json`.
2. **Authored fitting**: you write `adapter.json` into the pack (§2.4).

Before the first automatic fitting, the app shows a card explaining what would be sent; nothing goes out until the user taps **Fit**. After that, new models are fitted automatically, and **Fit new models when they're imported** in the menu turns that off. What's sent: the model name, parameter ids/display names/ranges, expression/motion/part names, the user's note and the current fitting. **Fit this model** accepts a what's-off note and retries; **Undo the fitting** removes the current one.

### 4.2 Fields

```json
{
  "adapter": 1,
  "moc": "<sha256 of the moc3>",
  "params": {
    "ParamAngleX": { "id": "PARAM_ANGLE_X" },
    "ParamEyeLOpen": { "id": "EyeL", "scale": -1, "offset": 1 }
  },
  "emotions": {
    "happy": { "face": { "ParamEyeSmile": 1 }, "expression": "02 grin" }
  },
  "actions": { "wave": { "motion": "wave-hand" } },
  "zones": [{ "id": "head", "from": 0.02, "to": 0.19 }],
  "tail": ["Param_Angle_Rotation_2"],
  "notes": "One line saying what was done"
}
```

| Field | Accepted | Bounds |
|---|---|---|
| `adapter` | Only `1` | Anything else drops the whole adapter |
| `params` | One of 18 standard names → `{id, scale?, offset?}`; `id` is a string or a list of co-driven ids | ids must exist in the probe and not be protected; `scale` finite non-zero, \|scale\|≤1000; `offset` finite, \|offset\|≤1000; invalid values drop that item; lists are de-duplicated |
| `emotions` | `calm/happy/shy/sad/angry/surprised/confused/smug/sleepy/worried` → `{face?, expression?, ...}` | `face` only the 18 standard parameters, clamped to their semantic ranges; `ParamEyeLOpen/ROpen` are **not** accepted (the blink pass overwrites them); `expression` needs an app-verified effect and the default evidence list is empty, so it won't be written |
| `actions` | 12 action names → `{motion}` | `motion` likewise needs verified evidence; empty by default |
| `zones` | `{id, from, to, xFrom?, xTo?}` | Only copies of geometry already in the probe; `zones: []` is refused (an empty array cannot turn the default zones off) |
| `tail` | Parameter ids | Must exist, and be on the tail list or named like a tail (`tail`/尾巴/尻尾) |
| `notes` | One Chinese sentence | Up to 60 Unicode characters |

Semantics: `set(v) = clamp(v*scale + offset, nativeMin, nativeMax)`; `add(d) = clamp(currentNative + d*scale, …)` — **add doesn't apply offset**. Defaults `scale=1, offset=0`. An eye maximum of 2 means it can open wider; a normal open eye is still 1, so don't convert ranges mechanically. An `id` list is only for targets that share semantics, direction and unit under one affine transform; mixing a closing and an opening eye in one list is refused.

### 4.3 What the AI fitting will **not** do (avoid these when authoring by hand)

- AI fitting does not write the `moc` fingerprint (the app computes it). A hand-written `adapter.json` must still include `moc` as described in §2.4.
- No `framing`, `pose`, `toggles`, code, URLs or unknown top-level fields — unknown fields are recorded as `dropped` and discarded.
- No arbitrary native parameter names or virtual eyelids; `face` takes only the 18 standard names; `gaze`/`eyelid` are not part of the AI contract (they exist only in `character.json`'s `emotions`, executed by the stage).
- No guessing effects from names: a successful load or a name like "happy" proves nothing; without `verifiedEffects` no new expression/motion resource is bound.
- No control over clothing, watermarks, signatures, opacity, sound or events; parameters whose names contain watermark/signature/outfit/opacity/hide/switch are excluded.
- No inventing touch zones, no guessing head/tail/legs by human proportions, no hair/cloth parameters pretending to be a tail.
- No guaranteed "three rounds": the page doesn't retry automatically; the user can retry once with a note under **Fit this model**, or **Undo the fitting**.
- No screenshot/pixel verification: the app validates structure only; visual correctness needs the real device.

**An empty result is a normal result**: when nothing can be done, the adapter is empty (notes only) and the app says "the model found nothing to match" — it won't pretend to succeed.

## 5. The model's own expressions and motions (no fitting needed)

`.exp3.json` and `.motion3.json` files are listed on the app's **Moves and faces** page:

- Each one can be switched on/off, **renamed**, and previewed with **Try it**.
- Switched-on ones are taught to the AI as marks: `[表情:name]` / `[动作:name]` (up to 24 expressions and 24 motions, in list order), and she uses them in replies.
- Default-on heuristics: the name reads as a word (at least two letters/Han characters), an expression name doesn't look like watermark/hide/switch, and a motion name doesn't start with `idle`.

**Author advice**: give `.exp3.json`/`.motion3.json` meaningful file names and `Name`s (`wave`, `blush`, `挥手`), not `01` or `X X`; don't turn outfit/visibility switches into expressions; keep idle loops out of the expression/motion lists.

## 6. Author self-checks

**In the app (all authors)**

1. After import, check the default pose and framing (`framing`).
2. Open **Moves and faces** and **Try it** on each entry.
3. Menu **Fit this model**: optionally write what's off, review the AI result; **Undo the fitting** and retry if needed.
4. Pat the head, tap face/body/tail and confirm `zones` behave as intended.

**Repo tools (need a checkout + Dart/Node; maintainer-facing)**

| Command | Purpose | Usable by a third-party author? |
|---|---|---|
| `dart tooling/companion/check-adapt-contract.dart` | Runs the real pure-Dart contract as a self-test | Validates format understanding only, **not your model** |
| `dart tooling/companion/adapt-dry-run.dart probe.json [candidate.json]` | Generates the real request / checks a candidate | Needs `probe.json` (the stage report); the app offers no export for authors and repo fixtures aren't third-party-facing → **practically unavailable** (UNVERIFIED) |
| `node --test tooling/companion/replay-model-corpus.test.mjs` | Replays rule bindings against historical 24-model facts with a pinned stage SHA | **Developer evaluation**; doesn't evaluate new models, produces no adapter |
| `node tooling/companion/sync-adapt-skill.mjs --check` | Checks the `companion-adapt` skill prompt matches the in-app contract byte for byte | Maintainer tool |

## 7. Publishing and sharing

- **Workshop (implemented in code, not live)**: Companion room menu **Workshop** → **My submissions** → **Submit**, then pick the current companion under **Choose what to submit**. Fill in name, author, license, source; optionally pick a cover PNG (≤2 MiB, ≤512 px per side, ≤262144 px area); tick **I confirm I have the right to share this**; wait for review. Only approved entries go public, and a submission can be withdrawn. Submitting needs a forum account, and no companion is listed locally when the phone has none installed.
- **Workshop companion packs are `character/` only**: no runtime; the installer must already have one on the phone (otherwise an error, no auto-download). Server limits: ≤1000 files, ≤16 MiB per file, ≤128 MiB expanded, ≤50 MiB zipped; moc3 must have the `MOC3` header with enum 1–6; `character.json` must have `name`/`model`, with consistent `author`/`license`/`source`; every reference in every model3 must exist in the character directory.
- **Workshop export rebuilds data**: only referenced files and known fields are kept; unknown config, UserData, motion event text, audio and Sound references are dropped; explicitly named `LICENSE`/`COPYING`/`NOTICE` texts are kept. The fitting keeps params/emotions/actions/zones/tail/pose/framing.
- **Sharing the zip directly** also works: the other person imports it manually. Model copyrights, permissions and Live2D terms remain the sharer's responsibility.
- **Status caveat**: the Workshop is deployed at `go.dshtui.com` and the app uses it by default, but a full submission hasn't been run on a real device yet. No "Workshop" entry means the build predates that default or was built with `DSH_WORKSHOP_ORIGIN` set to an empty string.
- **Live2D terms**: an application that can load arbitrary user models falls under Live2D's Expandable Application terms; Live2D states that fully free applications are in principle not approved. The bundled whale-girl was separately licensed from its author. Before publicly distributing third-party models, clarify the terms with Live2D (the repo still lists this as unconfirmed).

## 8. Explicitly unsupported / refused

- Cubism 2 (`.moc`/`model.json`), custom or replaced runtimes, any scripts or HTML (`character/` accepts data files only).
- Pixel-level automatic verification, screenshot-based multi-round repair, automatic "up to three rounds" scheduling: not implemented.
- Full-mode (host agent) fitting page wiring: the contract and skill exist, page orchestration doesn't; current AI fitting runs in light mode (app calls DeepSeek directly).
- Online model validation/upload service: none.
- Workshop going live and real-device verification: not done.

## 9. UNVERIFIED

- Workshop launch timing, review details and real-device behaviour: compiled from code/design docs, not measured.
- Final Live2D Expandable Application terms: still marked unconfirmed in the repo.
- Exact mapping between moc enum 1–6 and Cubism Editor product versions: the repo only records latestMocVersion 6; no version table.
- Whether authors will ever get a probe export for `adapt-dry-run.dart`: no export exists today, so this guide treats it as unavailable.
- End-to-end behaviour of a hand-written `adapter.json` (Workshop export rebuilds fields; the server adds stricter validation): not tested end to end.
