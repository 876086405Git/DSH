# iPhone development checkpoint — 2026-11-07

Progress checkpoint on `feat/ios-foundation`, based on `75ab577806d8cdbaa948e97b363df0877ff235ea`.
This is an experimental development build, not a completed release validation.

## Changes

- Use the authenticated RPPairing transport without requiring a legacy lockdown heartbeat.
- Resolve custom XCTest archive UID fields and accept iOS 26's contextless activities only after the selected test starts. The app still decrypts a fresh per-run payload and checks its run ID.
- Correlate process termination and process-status replies; do not release the native owner without confirming its exact PID exited.
- Expose the iOS phone-control settings and connect authenticated conversation ownership to task completion, service shutdown and the existing return-to-app preference.
- Allow the last tool result to retire before completion; stop the owned runner when its active call is cancelled.
- Resolve Settings aliases and names from a private, setup-time app inventory. Reject unknown names before activation and check that the target app entered the foreground.
- Wait briefly for DSH Go's foreground transition before stopping the runner on return.
- Disable release LTO for the Apple native library to avoid linking newer Rust LLVM bitcode with an older Xcode linker.

## Validation completed

- iPhone 13, iOS 26.0; Xcode 26.2; Rust 1.99.1; Flutter 3.47.7.
- Native start → encrypted readiness → confirmed exit, twice consecutively in one app process.
- Device installation and signature verification of the main app and XCTest helper.
- Settings entry and return preference visible on the device.
- Settings opened and screen read using its bundle ID. Pinduoduo opened, read and operated using its bundle ID.
- Private app inventory retained in the helper's data container; Pinduoduo's name mapping checked against the installed device inventory.
- 48 Flutter phone channel, ownership, completion, visibility and iOS settings checks passed.
- Changed Dart files: analyzer reported no issues.
- 11 native Rust tests, 1 upstream archive regression test, 8 build-input checks and 7 Swift app-name resolution checks passed.
- Main app and helper rebuilt after the final foreground-wait changes.

## Still pending on the device

- A fresh conversation opening both Settings and Pinduoduo by their Chinese names after the inventory fix. Earlier conversations contain cancelled calls and stale screen identifiers from app updates.
- A complete task automatically returning to the correct conversation with the final foreground-wait implementation. Earlier logs show a return request accepted and runner exit confirmed, but do not prove the app had completed its foreground transition.
- Behavior after device reboot, developer-image remounting, VPN reconnect and development-profile expiration.

## Reproduction and privacy

Use the existing native build and helper setup instructions in [README.md](README.md).
On systems where helper-side app enumeration is unavailable, upload a local app-name inventory with `tooling/ios/install-phone-app-catalog.py` and refresh it after installing new apps.

`DSH_PHONE_SELF_RUNNER_DIAGNOSTICS` enables bounded local startup/task-stage logs.
`DSH_PHONE_PREFLIGHT=1` runs two bootstrap-and-stop checks without issuing phone UI actions.
Normal launches do not run that preflight; actual phone control still requires the in-app user grant.

Pairing records, private keys, signing profiles, developer account details, device identifiers, app inventories, conversations, screenshots, logs, IPAs and build caches are intentionally excluded from this checkpoint.

## Task-level authorization and foreground activation — 2026-11-13

- A subsequent physical test produced two successful XCTest observations of Settings, followed by a foreground-admission refusal after returning to DSH Go. This distinguished a real approval/activation round trip from the model merely recognizing a pet in pixels. It did not complete the phone-control acceptance check.
- Adapted the working task-grant workflow and private foreground-activation helper from Menghuan1918's `feat/ios-phone-self-runner` implementation, with attribution in `THIRD_PARTY_NOTICES.md`. CoreDevice AppService launch is now followed by a native `LSApplicationWorkspace` activation request. Known XCTest targets and the protected return-to-DSH path also request actual foreground activation instead of relying only on XCTest application-state shortcuts.
- Replaced the extra per-call native sheet with one explicit task grant, lasting at most thirty minutes and bound to the current engine, conversation and connection-settings generation. Ordinary reads and inputs reuse it in the background without extending the deadline. Another owner or changed settings needs a new grant; pause, stop, task completion and expiry retire it. System actions, sensitive handoff and temporary clipboard staging retain their separate treatment. Existing grants are memory-only and do not survive an app replacement/restart.
- Removed unconditional foreground preparation from normal phone calls; pending clipboard restoration still requires foreground review. XCTest open can establish its target from DSH Go, and its result is admitted only after background/PiP readiness. A failed post-open transition discards its screen and reports that opening may already have happened rather than claiming no action was dispatched.
- Validation: 161 selected Swift cases passed, including 33 production-UIKit task-grant/expiry/clipboard cases. Background-state cases inject the foreground probe and do not claim an actual suspended-app test. The remaining cases cover CoreDevice ownership, RPC dispatch, screenshots, helper startup and XCTest observation checks. Explicit iOS tool-description checks, guide synchronization and the rebuilt runtime/archive checks passed. The optimized Release build succeeded; its asynchronous controller snapshots immutable operation flags before awaiting work to avoid an Apple Swift 6.2.3 optimization ownership crash.
- The revised signed 1.0.16+1 development build was installed over the existing app and launched successfully. The actual single-grant multi-action phone flow and automatic return remain physical-device follow-ups; no branch commit or push is claimed yet. PiP keep-alive preferences and its system-managed size were preserved.

## Main 1.0.16 integration — 2026-11-13

- Updated the pending main integration to `ddaff424b9fa1ed1d0cca389823facc046135dae` (1.0.16). Preserved the iOS native implementation, task ownership, widget and constrained WebKit rendering while incorporating main's shared UI, client and engine changes. The branch remains uncommitted and unpushed pending the physical phone-control check.
- Fixed a session-ownership mismatch in the stop watcher: iOS reports its authenticated owner on the singleton `task`, whereas the Android path uses a task list/caller capability. The old fallback cancelled both concurrent local chats in two regression cases. The updated watcher recognizes the iOS owner and leaves cancellation of phone work to native; it never falls back to cancel-all after that owner retires.
- Rebased the platform overlays onto all 145 authoritative common patches and retained 19 necessary overlays. Removed two overlays superseded by main's rejected-discovery response cancellation and EACCES fallback. Kept main's newer cascade-deletion/retry logic, Direct storage boundaries and provider headers. Reviewed and refreshed exact composition/import pins; import resolution and archive round-trip checks passed.
- Fixed AppleDouble metadata handling in patch enumeration for exFAT source checkouts. Added a regression fixture without changing CI workflows or weakening actual patch registration/hash checks. Corrected the bilingual optional-Linux introduction and guide: install Alpine, restart the local engine, install Python/pip separately with apk and approve the system write for that call.
- Validation passed: full app analysis; 139 Flutter phone/runtime/recovery/file-chooser cases; 80 client communication cases; 35 deletion core/route cases; 28 patch cases with one additional external-fixture case skipped; three canvas-allocation cases. The stop-owner regression was observed failing on the previous watcher before the fix. Canvas allocation preserves main's native-density float mode and still honors an explicit iOS budget; it is not a physical GPU-quality measurement.
- The final iOS archive passed real simulator integration with isolated synthetic data: 13 iSH scenarios and 15 approvals; six engine scenarios and eight approvals, including stop/restart and stored-session continuation; nine ImageIO attachment round-trip cases. These checks do not use user accounts or conversations.
- Built the complete 1.0.16+1 Release app, verified all nested signatures and installed it and the matching renewed helper over the existing iPhone app without clearing data. The main app launched successfully. The Personal Team package keeps the companion widget and omits the App Group share extension. Fresh repeated-screen captures, pet exclusion, on-device Python installation and automatic return to the owning chat remain physical-device follow-ups.

## Main integration and capture follow-up — 2026-11-12

- Integrated main through `e7808dafacba4e07904e615c8f985f12279dbf78`, preserving the iOS native transport, guest, widget and adaptive Live2D changes. Rebased the platform overlays onto the new ordered common patch series and rebuilt the shared composition and iOS specialization. Companion result sanitization now precedes lifecycle outcome storage and runs once per committed result.
- Phone tasks request capture protection on the pet's sample-buffer video layer. The window stays visible locally; capture protection does not reconstruct target pixels behind it. The helper excludes the controller and its own bundle from foreground candidates, while retaining ambiguity checks for actual target apps. These changes still require a fresh physical-device capture test.
- The complete unsigned Release build succeeded with the merged runtime. Version `1.0.15+1` and the rebuilt matching helper were signed and installed over the existing iPhone installation without uninstalling or clearing user data. The main app launched and remained present in the subsequent process check. This Personal Team package retains the previously installed companion widget and omits ShareExtension, which has no matching App Group profile.
- Targeted checks passed: 100 Flutter phone/runtime/recovery cases; 119 Swift CoreDevice, screenshot, XCTest-observation and runner cases on iOS Simulator; 77 guest routing/permission cases; 28 shared deletion core/route cases; eight real patched-engine companion cases; two companion/lifecycle ordering cases; five engine-embedding fixtures; guide and localization synchronization checks. Swift transport tests use recorded native transports, not a physical CoreDevice connection. The Linux-linked OHOS deletion-publication fixture was not run on macOS.
- Follow-up checks against the merged inputs passed all 22 real tool/approval/Worker fixture cases in both JIT and jitless modes. The final iOS archive passed the real iSH simulator smoke: 13 scenarios and 15 approval decisions, including rejection, per-call root access, cancellation and subsequent execution. The separate engine smoke passed six scenarios, eight approval decisions, stop/restart and continuation of stored sessions in the same process. These use an isolated local scripted model and disposable simulator files, not account credentials or user conversations.
- The physical-device pet-capture and full phone-task/return checks remain pending. After the Mac was unlocked, Xcode captured the current phone screen; it still showed the earlier failed conversation. The before/after journal snapshots contained no fresh phone invocation. The owner was asked to run a fresh read-only Settings task with the normal per-call approvals. Desktop/simulator results do not establish successful end-to-end phone operation. The merge remains uncommitted and unpushed pending that validation.

## Latest branch validation — 2026-11-08

Updated to `edb3bdc128a26b180758c2b431903560c026fa22` and rebuilt the composed runtime, iSH and N-API frameworks with Xcode 26.2.

- Fixed the generated runtime test's temporary-directory handling on macOS: resolve `/var` aliases before passing inherited preload paths to Node. Without this, the exact module-path check disables the Node Worker route and three cases fail. The unchanged production runtime passes all 22 cases with both JIT and jitless after this fixture correction.
- Extended the real iOS Simulator guest smoke from 9 to 13 scenarios. All 15 approval decisions passed, including independent workspace and Linux-root decisions in the same persisted turn. Real iSH rejects a default root write, does not create a file when root permission is rejected, permits an approved one-call write, then rejects another write while preserving the approved contents.
- Passed 74 routing/cancellation/root-grant/suspension checks, 10 POSIX crash-marker cases, the production Swift channel/installer contract with the verified Alpine archive, 6 standalone Dart guest contracts, 48 Flutter phone regressions and full Flutter analysis. The smoke driver's 4 oracle/model checks also passed. These targeted checks do not represent the full repository suite.
- Built, signed, installed and launched version `1.0.12+1` on iPhone 13 / iOS 26.0 without uninstalling the existing app. Local Flutter required Swift Package Manager to be enabled and plugin metadata regenerated before this build.
- The new device phone preflight launched PhoneRunner but timed out waiting for XCTest readiness (`ERR_PHONE_XCTEST_SESSION`). Cleanup confirmed the launched PID exited. A normal app launch succeeded afterwards. The Mac was locked when the computer-control tool tried to inspect device UI; fresh Settings/Pinduoduo and automatic-return checks remain pending. Simulator results do not establish that phone control works on this device.

The runtime fixture still requires a separately installed, OHOS-patched locked DSH prefix via `IOS_GUEST_TEST_PREFIX`, plus generated process dependencies. The simulator smoke uses the production Swift-installed fixed Alpine fixture and an isolated local scripted model; it does not use account credentials or user conversations. Use a fresh installation copy for each smoke run because the approved root-write scenario intentionally persists a synthetic file.

## Device follow-up — 2026-11-09

After unlocking the Mac, the device screenshot showed iOS waiting for the owner to enter the lock-screen passcode to **Enable UI Automation** for XCTest. PhoneRunner had launched but could not finish readiness while that system prompt was pending. Once the owner completed it on the phone, the existing build completed both consecutive native preflight cycles, including encrypted readiness and confirmed process exit. No pairing or transport change was needed for that successful retry.

The timeout and connection-failure messages now mention this conditional system confirmation before listing other setup checks. The optional backend's setup notes explain the same requirement. The updated app was built, signed and installed, passed both preflight cycles again, and was relaunched normally. The passcode remains exclusively in the iOS system interface; it is not supplied to the app or recorded by these diagnostics. These successful preflight cycles do not by themselves verify a conversation's UI actions or automatic return to DSH Go.

A fresh conversation on that earlier XCTest build completed its phone task and returned to DSH Go, with native logs confirming runner exit. The conversation used the Settings bundle ID after the name “系统设置” failed; name resolution and return triggered solely by task completion remain distinct follow-up checks.

The branch subsequently advanced to `05a17e43b20c1ae9121e59939d910d83c18eb49e`, adding the CoreDevice default route and picture-in-picture pet. After integrating the confirmation-message change, the device-arm64 Rust library and main app were rebuilt, signed, installed and launched normally on the same iPhone. The installed executable contains the CoreDevice entry points and declares the PiP audio background mode. Target-specific Cargo notices were generated and verified for this device-only build. At the user's request, extended automated checks were paused in favor of delivering this build for manual testing. The earlier XCTest result does not validate CoreDevice/PiP behavior. Legacy pairing migration and feature activation still require the user's native setup confirmations; they were not enabled automatically.

### iOS 26 compatibility, background execution and model instructions

- A bounded, read-only USB RSD check on the iPhone found 74 advertised services. AppService, SpringBoard and testmanagerd were present, but the direct CoreDevice capture and display services were absent despite a compatible, usable mounted developer image. A real Instruments/DVT screenshot succeeded. The CoreDevice owner now probes and uses that screenshot service over its existing owned RSD adapter when direct capture is absent, without starting XCTest for that capture. Image/orientation/observation limits remain enforced.
- Input capabilities remain independent. This phone's CoreDevice route can read screens and open apps, but cannot supply its missing HID/display services by downloading another image. Settings and tool results explicitly report the limited connection; service failures are no longer described as a VPN failure or simply a missing image.
- A playing, unsuspended PiP with valid owned audio now contributes to the local engine's lifecycle permission independently of BGContinuedProcessingTask. Closing/pausing it withdraws that source without clearing another valid source. The user confirmed setup and a device screenshot showed the pet PiP on the home screen. This does not establish indefinite background uptime or survival after lock/audio interruption.
- CoreDevice-only observations cannot be replayed as XCTest input. When enhancement is already enabled and a new `screen` preparation reports no CoreDevice input capability, it may prepare a fresh XCTest observation after confirmed CoreDevice cleanup and the normal native approval, subject to app rules. An input carrying an old CoreDevice observation returns a request to obtain a new screen; it is not dispatched on the other route. Expired calls and pending setup operations are no longer reported as disabled enhancement switches.
- The canonical shared catalog bytes and input schemas are preserved, while iOS registration uses explicit iOS tool descriptions. Android accessibility, separate background screens, unsupported intents, and treating scrolling collection as read-only are not advertised as iOS behavior. The bilingual phone, engine, pet and FAQ guide pages, skill routing and generated in-app guide were updated together. The generators now ignore AppleDouble metadata on external disks.
- Validation: 81 Rust tests passed (the real pinned-DDI cache fixture remained ignored); 9 actual production lifecycle HTTP/acknowledgement transitions passed; 2461 production Swift pet policy/pack/frame assertions passed; 48 existing Flutter phone regressions and 23 setup/PiP widget checks passed; Flutter analysis reported no issues. The 13 phone Node checks and real ToolRuntime/MCP registration fixture passed, including jitless with the production-compatible test networking preload. Guide/l10n generator suites passed 17 and 34 tests respectively; generated guide and l10n checks passed.
- The main app and matching XCTest helper were rebuilt, signed and installed without uninstalling user data. The user confirmed CoreDevice app opening. The latest enhancement-routing change was rebuilt and installed for the fresh-screen/scroll device check; its end-to-end XCTest input result was still pending at this checkpoint. No claim is made that this phone supports CoreDevice-only tapping or typing.

### Follow-up: approval return and app inventory — 2026-11-09

- The stalled conversation reached encrypted XCTest readiness successfully. It then failed target admission while DSH Go remained foreground or PiP was unavailable. Later inputs used stale observations; these were rejected rather than dispatched. This is distinct from an enhancement switch being disabled.
- The native per-call sheet now discloses the known target from this same task. On the XCTest route, an internal, authenticated activation returns to that target before waiting for actual background PiP and validating the original observation. Activation does not capture, replace or invalidate the observation and never replays the requested input. Unknown targets and CoreDevice-only rules retain manual selection. Private activation/validation methods and native routing fields remain inaccessible through the model operation plan.
- Target-wait diagnostics now record bounded state flags and distinguish request expiry, foreground state, locked data and inactive PiP. Tool descriptions and both guide languages clarify automatic XCTest return, per-call confirmation and the correct response to app-query failures.
- A read-only device inventory check returned 118 entries including one invalid launch identifier. The old code rejected the entire list. The native catalog now excludes invalid entries while preserving valid apps and refusing count/output overflows; it does not expose invalid launch targets. Added Settings name aliases include 系统设置 and System Settings.
- Validation: 83 native Rust tests passed, with one pinned-DDI cache fixture still ignored; the device-arm64 library built successfully. Two production Swift handshake/model-plan checks and nine app-name checks passed. Thirteen jitless phone/description checks and the generated guide check passed. The main app and matching XCTest helper built, signed and installed without uninstalling user data. The latest main app launched normally.
- End-to-end scrolling after this return change remains pending: the latest copied device log contains the updated launch but no fresh phone task. Earlier readiness and desktop tests are not evidence of successful input. No private app inventory, conversation, screenshot, pairing or signing material is committed.
