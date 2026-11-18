# Native approval sheet during deactivation and backgrounding

This change implements ADDENDUM-07 section 3.10 for `IOSPhoneApproval`, the
shared native sheet used by phone, browser and system-tool confirmations.
It hides the sheet's displayed heading, operation text and screenshot preview
when the app or the owning scene loses activity, before the app-switcher
snapshot. It does not dismiss the pending request or approve it automatically.

## Ordering and ownership

The controller registers selector observers on its NotificationCenter. App
will-resign-active, did-enter-background and protected-data-will-be-unavailable
notifications immediately set a sticky visibility gate to false. Scene
will-deactivate and did-enter-background notifications do the same for the
sheet's owning UIWindowScene. Before a scene has been attached, the controller
conservatively hides on any such scene notification.

The notification handlers call the redaction method directly. They do not
create a Task, dispatch asynchronously or wait for an animation. UIKit posts
these lifecycle events on its UI lifecycle; the controller and its helpers are
MainActor-isolated. The injectable notification center and visibility predicate
are internal test seams, not model-controlled inputs.

Redaction ends editing, hides the common content stack, removes its heading and
detail from the displayed UILabel/UITextView, removes the UIImage from the
preview view, disables selection and interaction, and hides accessibility
elements. The background remains the sheet's existing system background.
The gate applies even if the view has not loaded yet: a later appearance cannot
reveal content merely because an activity query still returns a stale value.

Restoration requires a did-become-active, scene-did-activate or
protected-data-did-become-available notification plus an affirmative actual
visibility check. The default check requires an active UIApplication and
available protected data. An attached scene must also be foregroundActive.
Will-enter-foreground alone is not a reveal event. Reappearing while the gate is
closed does not reopen it. Unrelated attached scenes cannot reveal this sheet.

Both buttons check current visibility and activity before forwarding the answer.
The existing IOSPhoneActions confirmation ID, owner/current, expiry and
post-approval validation remain unchanged. Returning to the foreground does not
invoke an answer, extend the approval deadline or resume a phone operation.

## What this does and does not protect

This is protection of the current sheet's displayed UI during UIKit lifecycle
transitions. The controller retains the original immutable strings, preview
Data and decoded UIImage so the same request can be shown again when active.
Those private values are not zeroed or promised to be erased. This change does
not establish protection for all process memory, other app views, screenshots
while active, OS snapshot storage internals or arbitrary external UI overlays.

The existing preview maximum of 880 KiB and the existing wording are unchanged.
No new user-visible text or Flutter localization is introduced. The next native
bilingual change must preserve these visibility checks when moving fixed text
into its string table.

## Tests and build registration

`IOSPhoneApprovalTests` calls the production UIViewController with small
synthetic text and an 8-by-8 generated preview. Eight authored tests cover:
synchronous redaction; inactive/foreground ordering and exact restoration;
protected data gating; an initially inactive sheet; blocked buttons; scene
events before attachment; observer lifetime; and deactivation before view load.
No replacement controller/state machine is used.

The class is registered in RunnerTests PBX Sources and in the existing
`ios-compile.yml` xcodebuild class selection. Production lives in the already
compiled IOSPhoneActions.swift. This environment has no Apple SDK, swiftc,
xcrun or xcodebuild: **8 authored, 0 executed; Apple UNRUN**. Source comparison,
private-index apply and registration checks are not UIKit execution.

The actual device acceptance check remains: open a synthetic approval with text
and preview, background/lock it, inspect the app switcher, return while locked
and after unlocking, and verify no action occurs without the original explicit
approval. This check has not been performed here. Actual attached-scene
notifications, font/layout, accessibility behavior and snapshot capture are
also unverified on Apple.

## Primary platform references

- Apple, [Preparing your UI to run in the background](https://developer.apple.com/documentation/uikit/preparing-your-ui-to-run-in-the-background):
  UIKit captures the UI after the background delegate returns; sensitive view
  content should be removed and restored as appropriate on return.
- Apple, [UIScene.didEnterBackgroundNotification](https://developer.apple.com/documentation/uikit/uiscene/didenterbackgroundnotification):
  the scene snapshot follows its notification handler, supporting synchronous
  redaction rather than deferred work.
- Apple, [UIScene.willDeactivateNotification](https://developer.apple.com/documentation/uikit/uiscene/willdeactivatenotification):
  includes temporary interruptions and background transitions, and identifies
  the scene in the notification object.
- Apple, [NotificationCenter.addObserver(_:selector:name:object:)](https://developer.apple.com/documentation/foundation/notificationcenter/addobserver(_:selector:name:object:)):
  iOS 9 and later can clean stale selector registrations on a later delivery.
  The implementation does not use an observer block that retains the controller.

Read on 2026-11-07. The source receipts retain URLs, hashes and retrieval status;
full Apple webpage bodies are not included in the delivery. No third-party
implementation was copied.
