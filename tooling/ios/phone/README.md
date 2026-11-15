# iOS phone tools

The app registers these tools through `runtime/ios/phone/plugin.mjs` and the
native `IOSPhoneBridge`. `embed-engine.sh` ships the phone modules separately
from the shared OHOS runtime archive. The on-device developer connection is
CoreDevice by default; XCTest is a separately enabled enhancement.

## What is available

- App lookup and launch use the actual developer services. Screen reading uses
  the direct CoreDevice capture service when advertised, or Instruments/DVT
  capture over the same owned RSD tunnel on older systems. DVT capture does not
  start a UI test. Swift performs local OCR, not accessibility-tree enumeration.
- A successful connection does not promise touch or typing. Those capabilities
  require the actual HID/display services. On a limited connection, results and
  the settings page say so; an input request is rejected before dispatch. The
  user may choose XCTest for the target app and obtain a new observation, or
  take over. No uncertain action or old observation is replayed across routes.
- Every phone call requires its own native foreground approval. A task grant,
  notification tap or PiP restoration does not approve the next action.
- The pet's actually playing, unsuspended PiP is an independent source of local
  engine background execution. Closing or pausing it withdraws that source;
  a separate accepted continued-processing task remains independent. An enabled
  switch is not proof that iOS is executing the app.

See the [native setup contract](../phone-control/UI-CONTRACT.md),
[backend README](../phone-self-runner/README.md), and the bilingual user guide
in `docs/guide/`. User-guide changes must be regenerated with
`python3 app/tool/guide_sync.py` so the bundled `dsh-go-guide` skill agrees.

## Shared schemas and iOS descriptions

`catalog.json` retains the pinned Android tool names/input schemas and exact
asset bytes (`ec04e096af7d632e86f9b0e39a28fbf7f74042e1df7b46db825b5cb7bbfe810e`).
Registration uses `descriptions.mjs` for iOS-specific instructions instead of
advertising Android accessibility, a separate background display, Shizuku/ADB,
or unsupported Android intents. A new catalog tool without an explicit iOS
description fails registration. `background:true` remains unsupported on iOS.

The system-action subset includes calendar editing, dial confirmation, SMS
drafts, the system share sheet, destination-based Apple Maps navigation, and
DSH Go's own system-settings page. Alarm/timer, arbitrary settings pages, an
Android share target/map selection, and GCJ-02 coordinates are not supported.
The final save/send/share remains with the user. Clipboard access is foreground
only, with a separate restore flow for temporary CoreDevice text input.

## Validation

```sh
node --test runtime/ios/phone/bridge.test.mjs runtime/tests/ios-phone-descriptions.test.mjs
python3 tooling/ios/engine-smoke/test-engine-background.py  # macOS Foundation
bash tooling/ios/pet-overlay-tests/contract.sh
```

`registry-check.mjs` exercises the actual ToolRuntime/MCP adapter with the
native linked-binding fixture prepared by `build-native-check.py`; it requires
that fixture and the locked DSH dependencies. `check-catalog.py` separately
compiles the unchanged Android catalog inputs with Kotlin/JRE and verifies the
static JSON bytes; it does not assert that iOS has Android's capabilities.

A desktop DVT screenshot or a fixture pass does not establish on-device
RPPairing/PiP/input operation. Record device results separately in
[DEVICE_TEST_PROGRESS.md](../phone-self-runner/DEVICE_TEST_PROGRESS.md). Never
publish pairing records, credentials, user screenshots, clipboard contents or
conversation logs as test evidence.
