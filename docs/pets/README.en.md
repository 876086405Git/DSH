# Make a dsh-go pet pack (author guide)

A dsh-go state pet is "one zip + one `pack.json` + a few tiled PNG sheets". Build it, import it into the app to test, then submit it to the Creative Workshop.

**Shortest path**

1. Draw the animations: one tiled PNG per animation, equal cells; store identical frames once and point to them again with `frames[].i`.
2. Write `pack.json` (schema 1): at least one `idle` animation and `states.idle`.
3. Pack it: `pack.json` plus the PNGs it names at the zip root, **or** in one enclosing folder.
4. Import: in the app, **Settings → Pets → the last cell in the picker, "Import"**, then choose the zip.
5. Tune states and timings; long-press an imported pet to delete and retry. The submission entry is **Creative Workshop → My submissions → Submit**.

> Note: the manifest is **`pack.json`**. `pet.json` is the Codex pet compatibility format (§7) — do not use it for native pet packs.
>
> The in-app pet and the "Show outside the app" overlay read the same pack, but the overlay's parser is stricter (integers; geometry computed with Android Float32 arithmetic). This guide follows the stricter rules, so a pack built to them runs in both places.

---

## 1. Pack format, layout and size limits

```
my-cat.zip
├─ pack.json          manifest (required, exactly one)
├─ idle.png           sheet (file names are declared by pack.json's sheet)
└─ working.png
```

A single enclosing folder also works: `my-cat.zip → my-cat/pack.json + my-cat/idle.png + …`. Only the zip root or **one** folder level; deeper layouts (`a/b/pack.json`) are not found.

**Zip rules**

- Regular files and directories only; no encryption, only store/deflate; no symlinks.
- No absolute paths, backslashes, NUL, `:`, `.` or `..` path segments.
- File names are compared by **Unicode 15 NFC + casefold**; two names that normalize equal are rejected (e.g. `idle.png` and `Idle.PNG` cannot both be present).
- Nothing is extracted by archive path. Only `pack.json` and the PNGs it names are kept; other files are dropped silently (not an error, but do not rely on them).
- When `pack.json` is present it is authoritative; **a broken pack.json never falls back** to a Codex `pet.json` in the same zip.

**Hard limits** (`app/tool/pet-pack.rules.json`, rule set revision 3; the app's generated constants are in `app/lib/pets/pet_pack_rules.g.dart`)

| Item | Limit |
|---|---|
| Zip file | ≤ 64 MiB; declared expanded total also ≤ 64 MiB; entries (directories included) ≤ 256 |
| `pack.json` | ≤ 256 KiB; UTF-8 without BOM; JSON depth ≤ 64 (the import gate also adds a 60-level check); duplicate keys, non-finite numbers and isolated surrogates rejected |
| Sheets | ≤ 64 files |
| One sheet | ≤ 8 MiB compressed; each side ≤ 4096 px; decoded buffer `w×h×4` ≤ 16 MiB |
| All sheets together | ≤ 48 MiB |
| Sheet file names | Flat, no directories; end in `.png`; ≤ 120 UTF-16 code units; no leading `.`; no `/`, backslash or NUL |
| Numbers | Frame `i` ≥ 0 and `ms` ≥ 1, integers; `frameW`/`frameH`/`cols` 1–4096; `canvas` 1–2³⁰; `scale` 1–4096 — all integers (import gate) |

## 2. Smallest working pack (copy this)

Layout:

```
my-cat/
├─ pack.json
├─ idle.png      48×20: two 24×20 cells side by side
└─ working.png   48×20: same
```

`pack.json`:

```json
{
  "schema": 1,
  "id": "my-cat",
  "name": "My Cat",
  "author": "Your name",
  "license": "CC-BY-4.0",
  "source": "https://example.com/my-cat",
  "pixelArt": true,
  "scale": 1,
  "canvas": { "w": 32, "h": 32 },
  "anchor": { "x": 16, "baseline": 28 },
  "contentBox": { "x": 4, "y": 8, "w": 24, "h": 20 },
  "animations": {
    "idle": {
      "sheet": "idle.png", "frameW": 24, "frameH": 20, "cols": 2,
      "box": { "x": 4, "y": 8, "w": 24, "h": 20 },
      "frames": [ { "i": 0, "ms": 400 }, { "i": 1, "ms": 400 } ]
    },
    "working": {
      "sheet": "working.png", "frameW": 24, "frameH": 20, "cols": 2,
      "box": { "x": 4, "y": 8, "w": 24, "h": 20 },
      "frames": [ { "i": 0, "ms": 200 }, { "i": 1, "ms": 200 } ]
    }
  },
  "states": { "idle": ["idle"], "working": ["working"], "thinking": ["idle"] },
  "reactions": { "tapLeft": "idle", "tapRight": "idle" }
}
```

- `canvas` is the art canvas; `anchor.baseline = 28` is the feet line (the body stands on row 28; the 4 px below can hold a shadow).
- `contentBox` is the idle body box: the app uses it to size the pet, place bubbles and as the fallback hit box.
- Idle alone is enough to run: states you do not provide fall back to the first animation in `states.idle`.

Pack it:

```sh
cd my-cat && zip -r ../my-cat.zip pack.json idle.png working.png
```

## 3. `pack.json` fields

The app reads only the fields it knows and ignores unknown ones. **`description` is not read** (that field belongs to the Creative Workshop submission form).

### 3.1 Top level

| Field | Required | Default | Notes |
|---|---|---|---|
| `schema` | ✅ | — | Must be `1` |
| `id` | ✅ | — | Non-empty string. On import it becomes a folder name: if it matches `[a-z0-9]+(-[a-z0-9]+)*` and is ≤48 chars it is kept; otherwise it is slugified plus the first 8 hex chars of the SHA-256 of the original id. An existing `user-` prefix is not added twice. Importing the same id again replaces the pet |
| `name` | — | `id` | Shown in the pet picker |
| `author` / `license` / `source` | Optional for local import; **required for the workshop** | — | The pet page footer shows `author · license`. The workshop has its own licence allow-list, see §9 |
| `pixelArt` | — | `true` | Written into the installed manifest on import |
| `scale` | — | `1` | Sheet pixels ÷ art pixels; written into the installed manifest on import |
| `canvas` | ✅ | — | `{w,h}` in art pixels, positive integers |
| `anchor` | — | `{x: w/2, baseline: canvas.h}` | `baseline` is the feet line (the top of the perch capsule); `x` is the body centre and mirror axis; fractions like `.5` are allowed |
| `contentBox` | ✅ | — | `{x,y,w,h}`, the idle body box, `w,h > 0`; drives size, bubble placement and the default hit box |

### 3.2 `animations` (required, ≥1)

Each entry: `sheet` (PNG file name), `frameW`/`frameH` (size of one cell in sheet pixels), `cols` (cells per row), `box` (where the cell sits on the canvas, art pixels), `frames` (`[{i, ms}]`; `i` is the cell index starting at 0, `ms` is how long it shows), `loop` (optional, default `true`).

- Animation names are free-form (`idle`, `typing`, `react-left`…); `states`/`tiers`/`reactions` refer to them by name.
- Store identical frames once: `i` may repeat.
- An animation-level `ms` is **not read**; duration comes only from the per-frame `ms`.

### 3.3 `states` (required)

`state name → [animation names, …]`. The first is the main animation, the rest are variants. **Must contain a non-empty `idle`**. State names are listed in §5; unknown names are accepted but never selected.

### 3.4 Optional fields

| Field | Purpose |
|---|---|
| `tiers` | `state → [{min, anim}]`. `min` defaults to 1; busy states (working/juggling) pick the largest entry whose `min` is ≤ the current tier |
| `timings.minDisplay` | `state → ms`. Minimum time a one-off state stays on screen |
| `timings.autoReturn` | `state → ms`. When a one-off state folds back; `notification` always stays until handled, so its entry has no effect |
| `timings.playMs` | `animation → ms`. How long one play lasts; default = sum of frame durations |
| `timings.wakeMs` | Number: total waking time; default = one pass of the waking animation, or 1500 when absent |
| `reactions` | `tapLeft` / `tapRight` / `tickle` / `drag` → animation name |
| `roam` | `{anim, faces: left/right/front}`. Roam animation and which way the art faces; the opposite direction mirrors around `anchor.x`, `front` never mirrors. Legacy `flip:false` means `front` |
| `sleep` | `{afterMs}`: idle time before sleeping, default 60000 |
| `hitBoxes` | `default`/`wide`/`sleeping` rects (art pixels), per-animation `byAnim`, plus `wideAnims`/`sleepingAnims` groups; lookup order `byAnim → sleepingAnims → wideAnims → default → contentBox` |
| `idlePool` | Idle extras: `{anims: [{anim, ms, weight}], everyMs: {mean, min, max}}`; without it, `states.idle` entries after the main one are used |
| `bonus` | Easter egg for non-idle states: `state → {anims: [...], chance: 0–1}`; `chance` defaults to 0, which disables it |

**Defaults** (when omitted): `minDisplay` = attention 5200 / error 4800 / sweeping 5600 / notification 3200 / carrying 3200 / working 1000 / thinking 1000 (ms); `autoReturn` = attention 5200 / error 4800 / sweeping 300000 / carrying 3200; `sleep.afterMs` 60000; `idlePool.everyMs` mean 120000 / min 45000 / max 300000.

## 4. Sheet rules

### 4.1 Two coordinate spaces

- **Art pixels** (`canvas`, `box`, `anchor`, `contentBox`, `hitBoxes`): the authoring grid.
- **Sheet pixels** (inside the PNG): `scale` is the ratio. A 1× export uses `scale: 1`; a 5× export uses `scale: 5`.
- Cell size must be exact: `frameW = trunc(box.w × scale)` and `frameH = trunc(box.h × scale)` (the app compares after Float32 arithmetic and truncation). **Simplest: keep box sizes and scale as integers.**
- Example: `box.w = 36, scale = 5 → frameW = 180`; `box.h = 24 → frameH = 120`.

### 4.2 Grid and sheets

- One frame per cell, row-major: frame `i` sits at `col = i % cols`, `row = i ~/ cols`.
- PNG width ≥ `cols × frameW` and height ≥ `(max i ~/ cols + 1) × frameH`; exact sizes are recommended; leave empty cells transparent.
- Each side ≤ 4096 px. For many frames use `cols` to lay out a grid instead of one extremely wide strip.
- The sheet file name is declared by `animations.*.sheet`; one PNG may be shared by several animations.

### 4.3 PNG requirements

A complete, valid PNG: correct CRCs, contiguous IDAT, exact zlib end, no trailing bytes; palette + `tRNS` are allowed; **APNG is rejected** (`acTL`/`fcTL`/`fdAT`), as are unknown critical chunks and seriously damaged images. Ancillary text/ICC metadata has its own budget, and market normalization strips it — for small files prefer indexed PNG or clean RGBA.

### 4.4 Sharpness and physical pixels

- `pixelArt: true` with `scale: 1`: nearest-neighbour drawing at an integer multiple, so every art pixel occupies a whole number of physical pixels (top-left and feet line align to physical pixels).
- `scale > 1` or `pixelArt: false`: smooth scaling, no integer constraint.
- Pet size is driven by `contentBox.h` (small 22 dp / standard 30 dp / large 40 dp; people can also drag Custom to 50–300% of standard), not by canvas. To make a pet look bigger, change `contentBox`, not the canvas.
- Prefer drawing at 1× art pixels on whole pixels; use values like `anchor.x: 35.5` only when the mirror axis really sits on a half pixel.

### 4.5 Anchor and hit boxes

- `baseline`: bottom edge of the lowest opaque row of the body (the feet line), excluding the shadow; it decides where the pet stands on the capsule.
- `anchor.x`: horizontal centre of the body, also the mirror axis.
- `contentBox`: idle body box; also the default hit box.
- Hit boxes measure the body only: detached props such as thought clouds, Zzz and notes must not be included. If a lifted (drag) pose leaves the default box, give it a separate `byAnim.drag` box.

## 5. States and events

The app reduces agent activity into 11 states. **Idle alone is enough**; missing states fall back to idle.

| State | When it shows | Type |
|---|---|---|
| `idle` | Nothing runs in scope | level |
| `thinking` | Waiting for the model, reasoning, retrying | level |
| `working` | A tool runs / the reply streams; tiered by running conversations across all hosts (1 / 2 / 3+) | level, tiered |
| `juggling` | Subagents run; tiered by their count (1 / 2+) | level, tiered |
| `sweeping` | Context compaction | level (autoReturn caps it at 300 s) |
| `notification` | An approval or a question waits | level, until handled |
| `attention` | A turn finished and no new round started within 1.5 s | one-off |
| `error` | A turn failed (an engine restart is not one) | one-off |
| `carrying` | Reserved: a file upload / import; **never triggered today** | level |
| `sleeping` | Idle and untouched for 60 s (`sleep.afterMs`) | level |
| `waking` | Touched or woken by an event while asleep | one-off (`wakeMs`) |

**Priority** (higher overrides lower): `error` 8 > `notification` 7 > `sweeping` 6 > `attention` 5 > `carrying`=`juggling` 4 > `working` 3 > `thinking` 2 > `idle`=`waking` 1 > `sleeping` 0. A one-off state stays at least `minDisplay` and folds back at `autoReturn`; a lower-priority state does not interrupt a higher-priority one-off. Busy tiers step up immediately and step down only after the lower tier has held for 5 s.

**Roaming**: in the app the pet wanders while idle using `roam.anim`; the overlay does not roam. `roam.faces` decides mirroring.

**Interaction**: tapping the left/right half of the body → `tapLeft`/`tapRight`; three taps within 1.1 s → `tickle`; dragging → `drag`. Reaction animations return to the previous state; while asleep, `waking` plays first.

**What never happens**: a stopped turn quietly returns to idle (no error); compaction completion is not celebrated; a disconnect or engine restart never becomes `error`.

## 6. Import, validation and deletion

**Entry**: **Settings → Pets → the last picker cell, "Import"**, then choose the zip. Importing the same id again replaces the pet (long-press an imported pet in the picker to delete it; deleting the currently selected pet switches back to the default pet).

On failure the app shows one of a few messages; the detail carries the validator's English code:

| App message | Typical detail codes | What to fix |
|---|---|---|
| Not a zip file | `archive-invalid`, `archive-header`, `archive-type`, `archive-encoding`, `archive-duplicate`, `archive-multidisk`, etc. | Re-zip with a standard tool; check encryption, multi-disk or duplicate names. Note: `archive-path` shows as "a sheet is wrong", `archive-member-missing` as "missing sheet" |
| No pack.json in the zip | — | Put the manifest at the root or in one folder; make sure it is named `pack.json` |
| pack.json has a problem: … | `pack-schema`, `json-*`, `pack-overlay` | Follow §3; `pack-overlay` means the stricter overlay integer/geometry check failed |
| The zip is missing sheet X | `sheet-missing` | The `sheet` name does not match the actual file |
| A sheet is wrong: X | `png-*`, `sheet-name`, `sheet-alias`, `sheet-frame-bounds` | PNG incomplete/APNG/illegal name/cells outside the sheet |
| This pet pack is too large | `sheet-size`, `sheet-total-size`, `sheet-count`, `pack-size`, `pack-normalized-size`, `archive-expanded-size`, `archive-member-size`, `archive-entries` | See the limits in §1 |
| Could not store it on the phone | `storage` | Storage/permission issue; retry |

Other common details:
- `archive-pack-count` — zero or several `pack.json` files (e.g. one at the root and one in a folder).
- `json-duplicate-key` / `json-bom` / `json-depth` — duplicate keys / BOM / too deeply nested.
- `sheet-count` / `sheet-alias` — too many sheets, or two names that normalize equal.
- `pack.json: schema` / `pack.json: canvas` / `pack.json: contentBox` / `pack.json: frames of X` — the field is missing or invalid.
- `pack-overlay` detail looks like `pack.json: frameW, frameH of idle ≠ box × scale`.

## 7. Codex pet compatibility

When there is no `pack.json` but there is a Codex-format `pet.json`, the app converts it and then runs the same validation:

- `pet.json` at the zip root or in one folder, exactly one.
- `spriteVersionNumber`: `1` (default) or `2`. v1 atlas is 1536×1872 with a default grid of 8 columns × 9 rows, cell 192×208; v2 atlas is 1536×2288 with a fixed 8 × 11 grid.
- `spritesheetPath`: defaults to `spritesheet.webp`; PNG or **static** WebP (WebP is transcoded to PNG on the same pixel grid).
- v1 may override `animations` (`frames`, `fps` 1–60, `loop`, `fallback`) and the atlas `frame` grid; v2 rejects custom grids/animations.
- Result: schema 1, `pixelArt: false`, `scale: 1`. State mapping: thinking→waiting, working/juggling/sweeping/carrying→running, notification→waiting, attention→review, error→failed, sleeping→first idle frame, waking→jumping, roam→running-right (mirrored to walk left), tapLeft/tapRight→waving, tickle→jumping, drag→running-right.
- Some things degrade; the app lists them after import (also stored in the installed pack as `codexImport.warnings`): animations loop until the state changes (unlike Codex's play-three-times-to-idle), walking left mirrors the right track, dragging always uses the right track, sleeping uses the first idle frame, v2 look rows are unbound, WebP becomes PNG, custom tracks are not bound to any state, fps is rounded to milliseconds, one-shot returns are decided by DSH, missing author/license/source are reported.
- Author, licence and source are preserved from the original fields; missing ones only produce a warning and do not imply the work may be published.

## 8. Export and sharing (packaging happens on submit)

There is **no** user-facing "export pet pack" button. When submitting, the client re-exports the selected pet as a canonical zip:

- Only `pack.json` and the PNGs it references; unknown metadata, `codexImport` and local submission receipts are excluded.
- The `id` in `pack.json` is rewritten to the submission id; `author`/`license`/`source` are overridden with the form values.
- The normalized archive is fully validated again; the client upload limit is 50 MiB for the zip, and the workshop works with a 128 MiB expanded budget (the server has its own rules).

## 9. Publishing to the Creative Workshop

1. Sign in with a forum account (the first time, the app explains that it sends your forum credential to the workshop service to identify you, and only sends it after you agree). Browsing and installing need no account; submitting and viewing/withdrawing your own submissions do.
2. **Creative Workshop → My submissions → Submit**, then pick an imported pet.
3. Fill in id, version, minApp, Chinese and English titles, author, licence, source link, description, tags; tick "I confirm I have the right to share this content".
4. Use "look at the packed result" to inspect the final zip. After submitting, a reviewer checks it; only approved works appear under Discover. Rejections state a reason and you can resubmit; you can also withdraw later.

**Field rules** (`app/lib/state/workshop_publication.dart`, `app/lib/workshop/workshop_models.dart`)

| Field | Rule |
|---|---|
| `id` | Lowercase letters/digits/hyphens, ≤40, matching `^[a-z0-9]+(-[a-z0-9]+)*$`; independent of the id inside the pack (rewritten on export) |
| `version`, `minApp` | SemVer (≤80 chars); minApp is the minimum app version the work requires |
| Titles (zh/en) | Both non-empty, ≤120 characters each |
| `author` | ≤256 characters |
| `license` | One of: `CC0-1.0`, `CC-BY-4.0`, `CC-BY-SA-4.0`, `MIT`, `Apache-2.0`, `BSD-2-Clause`, `BSD-3-Clause`, `LicenseRef-Author-Permission` |
| `source` | An `https://` URL, ≤2048 characters, with no whitespace and no user info |
| `description` | Optional, ≤512 characters |
| `tags` | Optional, ≤8 tags, ≤32 characters each, no duplicates |

**Preview image**: pets default to "the first frame of the idle animation" as the preview and this can be turned off. The client only validates and declares `previewSource = pet-idle` (first cell of the first animation in `states.idle`; requires `frameW`/`frameH` ≤ 512 and `frameW×frameH` ≤ 262144); the actual preview is generated by the workshop (server side is UNVERIFIED). If it is too big the app says a preview cannot be made, and **you can still submit with the preview turned off**.

## 10. Self-check list

There is currently **no** standalone author-facing validator CLI; importing in the app is the final check, and submitting runs the full validation plus the preview check again. Only internal references exist in the repository:

| Resource | Purpose |
|---|---|
| `app/tool/pet-pack.rules.json` | Rule set (revision 3): limits, required fields, defaults, and the local/market differences in authoritative prose |
| `app/test/pets/fixtures/pet-pack-local-v1.json` | Valid/invalid pack test vectors, each tagged `parserValid` / `appImportValid` / `marketValid` |
| `app/tool/make_pet_pack.py` | Build pipeline for the two bundled pets (Clawd theme / whale-girl strips → sheets + pack.json); needs Pillow + numpy; it is not a general validator |
| `app/lib/pets/` | The actual validation, import, Codex conversion and rendering code |

**After importing, test item by item**

- [ ] Import succeeds; importing the same id replaces; long-press deletes; deleting the selected pet switches back to the default.
- [ ] All three sizes work (small/standard/large); no outline or colour shift in light or dark themes.
- [ ] Trigger each state and check the animation: send a message for `thinking`/`working`, run tools or compact the context for `sweeping`, trigger an approval for `notification`, finish a turn for `attention`, fail a turn for `error`, start subagents/Agent Teams for `juggling`, stay idle for 60 s for `sleeping`, tap while asleep for `waking`, wait while idle for roaming. `carrying` is never triggered today — no need to draw it.
- [ ] Tapping left/right, three quick taps and dragging trigger `tapLeft`/`tapRight`/`tickle`/`drag`.
- [ ] Turn on "Show outside the app": the overlay's animations and hit area (body only) work; dragging to an edge snaps; nothing remains after turning it off.
- [ ] Before submitting, use "look at the packed result" to confirm the final zip and preview.

## UNVERIFIED

- This guide was written from static code reading; no tests or builds were run locally, and the full import/submit flow was not verified on a real phone.
- Overlay permissions, snapping and per-DPR rendering on individual ROMs (vivo/Xiaomi, etc.) were not verified.
- The examples in `docs/design/pets.md` were not cross-checked one by one: its `states` example contains `"roam"`, which is never used (roaming only reads `roam.anim`; the state enum has no roam).
- Codex compatibility is written from the converter code; real Codex export packages of each version were not tested.
- Creative Workshop server behaviour (review, how the preview is actually generated) is described from the client contract and the user guide; the server implementation was not read.
