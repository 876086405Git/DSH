# Remote pairing scanner regression (#802)

## Cause and scope

[Issue #802](https://github.com/ccch1mneyyy/dsh-Go/issues/802) reports a blank camera preview and failed gallery decoding despite granted camera permission, with `MlKitContext has not been initialized`. The Android manifest deliberately removes `MlKitInitProvider` so disabled local OCR cannot initialize ML Kit at process startup. The Remote barcode scanner also needs that shared SDK, but previously only an admitted OCR job initialized it.

Remote now prepares ML Kit through `dsh/app.initializePairingScanner` before mounting `MobileScanner` or analyzing a selected image. OCR and Remote share a synchronized, process-wide initialization gate. Success is reused; a failed attempt is not retried because the SDK may have partially initialized global state. Preparation errors return `scanner_initialization_failed` without native exception details.

The provider stays disabled. App startup, settings reads and disabled OCR requests do not initialize ML Kit. Opening the Remote scanner is a separate on-demand use of the shared SDK; it does not enable local OCR or create a text recognizer. Camera permission is still handled by Android/mobile_scanner. Gallery decoding does not require camera permission. Pairing protocol, fingerprints, confirmation and credentials are unchanged.

## Automated coverage

- `app/test/remote/pairing_scanner_test.dart`: pending preparation blocks camera and photo decoding; success starts the camera once; gallery decoding works despite denied camera permission; SDK/decoder errors are not called a missing QR code; leaving during preparation cannot start a camera, decode a selected photo or report a code later.
- `app/test/remote/pairing_test.dart`: existing pairing flow, sign-in requirement, fingerprint confirmation, cancellation and server-switch confirmation.
- `MlKitInitializationTest`: scanner/OCR initialization in either order and on reopen, concurrent callers, sticky failure. The callback gate is real production code, not an alternative initialization algorithm.
- `LocalOcrBoundaryTest`: existing no-request/privacy-denial, cancellation/deadline, result budget and failure-is-not-success protections.

Normal project commands:

```sh
(cd app && flutter pub get && flutter analyze)
(cd app && flutter test --concurrency=1 test/remote/pairing_test.dart test/remote/pairing_scanner_test.dart)
(cd app/android && gradle :app:testArm64DebugUnitTest)
python3 app/tool/l10n_merge.py --check
python3 app/tool/guide_sync.py --check
git diff --check
```

## Local verification (2026-11-09)

Environment: aarch64 Ubuntu/PRoot, Flutter 3.47.7 with ARM64 Dart 3.13.5 and ARM64 headless test engine, real Noto Sans CJK test fonts; Kotlin 2.2.20 and OpenJDK 17.

- Dependency resolution: passed using pub.dev after the configured mirror reported an unavailable package. No dependency version changes.
- JVM: compiled the production initialization gate and OCR boundary plus their JUnit tests with `K2JVMCompiler -jvm-target 17`, then ran `JUnitCore`: **12 tests passed**. This does not execute ML Kit or Android camera code.
- Flutter pairing and scanner tests: **16 tests passed**, using `DSH_TEST_FONT_DIR=/root/.cache/dsh-test-fonts /root/dev/flutter-arm64/flutter test --no-pub --concurrency=1 test/remote/pairing_test.dart test/remote/pairing_scanner_test.dart` from `app/`. Six tests exercise the real scanner widget/controller against fake platform boundaries; ten cover the existing pairing flow.
- Targeted Flutter analysis of the pairing page and scanner test: **passed**. App-wide `flutter analyze --no-pub` from `app/`: **passed, no issues**. A first repository-root analysis included separate packages without their own package configs and failed on unresolved package/test imports; it is not recorded as a passing app analysis.
- Localization/guide generation and both `--check` commands: passed. `git diff --check`: passed.
- Shared Android runtime entry: **compiled** with Kotlin against Android API 36 and the published ML Kit common 18.11.0 AAR. This checks API references only, not runtime initialization or the final Gradle-selected APK dependency.
- Full Gradle/Android compilation: **not run**; this guest has no complete Android SDK/Gradle toolchain.
- APK installation and real-device scan/OCR: **not run**. No app was installed, restarted or granted additional permissions.

## Required real-device verification

Use a test installation; do not clear an existing user's data or test with real pairing secrets in recordings/logs.

1. Cold-start with local OCR off and without having run phone control. Open Remote pairing, grant camera permission and scan a fresh pairing code. Verify fingerprint and confirmation still precede pairing.
2. Cold-start again, deny camera permission, then select a QR screenshot from photos. It must reach the same confirmation step. Canceling the photo picker must not start pairing.
3. Exercise scanner -> enabled OCR and enabled OCR -> scanner in the same process. Neither order should throw either `not initialized` or `already initialized`. Turning OCR off still prevents new text recognition.
4. Exit during scanner preparation/selection and return. There must be no late camera start, pairing callback or disposed-controller error.
5. Check genuine permission denial remains distinguishable from SDK failure; an undecodable image may say no code, while a decoder exception must report reader unavailability.
6. Include the reported Redmi K80/HyperOS Android 16 and another OEM/Android version. Automated ARM64 tests do not establish device compatibility.

## HarmonyOS: system scan page

mobile_scanner has no HarmonyOS implementation, so on HarmonyOS the box holds a **扫码** button that calls `dsh/app.scanQrCode`. `AppLinksPlugin.ets` opens Scan Kit's default view (`scanBarcode.startScanForResult`, QR only, single code, album on) with the foreground UIAbility context; Scan Kit loads on the first scan only. The system page owns the camera, so the app asks for no camera permission, and its album entry replaces 从相册识别, which is not shown. Closing the page (1000500002) answers null and nothing happens; `no_ability`, `unavailable` and `failed` show the reader-unavailable line that points to 粘贴配对链接.

Automated: `app/test/remote/pairing_system_scanner_test.dart` (the box, cancel, errors, one scan at a time, Android keeps the camera) and `tooling/ohos/tests/scan-channel.test.mjs` (the ETS options, cancel code and error codes against doubles). Scan Kit itself is UNCOMPILED_HMS: the module names come from Huawei's Scan Kit reference, not an HMS SDK compile.

On a device: scan a fresh pairing code from the camera; scan one from a screenshot through the page's album entry; close the page with back and check nothing happens and 扫码 works again; check the confirmation step follows each scan as on Android.
