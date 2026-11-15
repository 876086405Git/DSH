# Bounded screen annotation and cached DDI verification away from MainActor

## Screen annotations

`IOSPhoneScreen.observe` requests the existing serial-by-owner analysis path to
produce its numbered elements and local JPEG preview before returning to
MainActor. PNG decoding, canonical RGBA, SHA, Vision, pixel matching and the
annotation now all run in the same dispatched user-initiated closure and
`autoreleasepool`. The renderer is a synchronous nonisolated helper; there is
no actor hop between the optional test observation and the real drawing call.
Only owned `Data`, text and geometry return. The prior CGImage field and
unchecked Sendable conformance are removed from the analysis result.

The renderer's drawing body is unchanged: scale one, opaque standard range,
1280 maximum long edge, the same numbered boxes, quality ladder and 880 KiB
JPEG ceiling. This preserves the recipe and coordinate contract, not a promise
of identical compressed bytes or dynamic trait resolution on every system.
No UIView, window, layer hierarchy or live screen snapshot is drawn by this
worker. All UIKit drawing objects are created locally and are not shared with
another worker or the main actor.

`processing` remains held until the complete analysis/annotation continuation
returns. A newer attempt still invalidates the old ticket even when it receives
BUSY. The existing cancellation/current-owner/ticket/continuous-age checks run
after the entire worker result and again before publishing. Cancellation does
not forcibly interrupt Vision or JPEG compression; their bounded work may
finish, after which the stale result is discarded. At most one such analysis
can run for this IOSPhoneScreen instance. This is not a process-wide queue cap.

The text-only request still attempts a local preview for native approval,
returns no model image, and grants no tap_xy authority. Only its existing JPEG
size-limit failure is best-effort; other errors keep their refusal behavior.
Input inspection and pixel revalidation do not request annotations at all.
No raw frames, recognized text or hashes are persisted or logged.

## Cached DDI verification

The fixed-catalog cache hit check now uses `verifyOnWorker`. A detached utility
task owns the actual synchronous anchored-directory verification. Cancellation
is explicitly forwarded, the caller awaits the worker's completion, and both
worker and caller check cancellation around the result. The digest loop checks
between its existing 64 KiB reads. A cancelled or throwing check cannot silently
become a cache miss that starts a download: `prepare` checks its own cancellation
immediately after the optional cached result.

The MainActor busy gate, preparation identity and original owned directory FD
remain live until the worker has completed. Catalog URLs, filenames, sizes and
SHA-256 values are unchanged. The same `openat`/no-follow regular-file checks
remain in place, as do the anchored temporary-file publication and fsync path.
The existing URLSession delegate verification was already off MainActor and is
not moved. Rust still independently opens and verifies every DDI input; a
Swift verification result grants no file authority.

Cancellation is cooperative. An in-progress filesystem read can complete
before the next check; this is not immediate I/O abortion or a deadline.
Small directory operations and final publication are still on the original
actor path. No whole-application responsiveness guarantee is claimed.

## Verification scope

Four new Screen XCTest methods use a bounded, synthetic gate immediately before
the real annotation, then run its actual renderer: main-actor progress and
worker thread entry, real JPEG dimensions/budget, single-analysis ownership,
late cancellation and continuous observation expiry. The new optional
`annotationWillRender` observer receives no pixels/text; production leaves it
nil. The existing 34 Screen tests are unchanged.

Four DDI XCTest methods use only an owned three-byte `abc` file and the known
SHA-256, an incorrect digest, or a bounded synthetic worker: actual off-main
verification, integrity error preservation, joining a cancelled worker and
rejection before starting an already cancelled call. No network or catalog
asset download is needed. These target the production helper and verifier;
there is no translated substitute implementation.

The new DDI class is registered in RunnerTests and the existing CI selector
list; Screen's class already participates. There are 38 Screen and 4 DDI
methods after this patch, **0 executed here / Swift and Apple UNRUN**. Source
placement, exact preserved methods, file identities and actual patch application
are checked separately; those checks cannot establish SDK typechecking,
framework threading behavior, on-device latency or successful cancellation
under every OS schedule. Apple validation must run these real XCTest classes
and inspect the relevant main-thread work in Instruments.

## Primary basis and inference boundary

- [Swift structured concurrency, detached tasks](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md): detached tasks do not inherit the caller actor context.
- [Task cancellation handler](https://developer.apple.com/documentation/swift/withtaskcancellationhandler(operation:oncancel:)): operation still runs for an already-cancelled caller and the handler can run concurrently. The explicit checks and retained worker handle follow from that contract.
- [Task.cancel](https://developer.apple.com/documentation/swift/task/cancel()): cancellation is cooperative and may synchronously invoke handlers.
- [UIGraphicsImageRenderer](https://developer.apple.com/documentation/uikit/uigraphicsimagerenderer) and [image(actions:)](https://developer.apple.com/documentation/uikit/uigraphicsimagerenderer/image(actions:)): a local graphics context creates the image from the synchronous drawing instructions.
- [Legacy bitmap context](https://developer.apple.com/documentation/uikit/uigraphicsbeginimagecontext(_:)): Apple explicitly allows that context API on any thread and recommends ImageRenderer instead. This supports the local offscreen-drawing design; it is not a blanket guarantee for every UIKit method or a substitute for the project's Apple SDK/runtime validation.
