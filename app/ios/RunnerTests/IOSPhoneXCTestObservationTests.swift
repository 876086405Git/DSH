import Foundation
import UIKit
import XCTest
@testable import Runner

/// Synthetic pixels and injected times exercise the production helper. These
/// are not screenshots, real foreground-app evidence or a device control run.
@MainActor
final class IOSPhoneXCTestObservationTests: XCTestCase {
  private let target = "test.synthetic.target"
  private let controller = "test.synthetic.controller"

  private final class Clock { var value: TimeInterval? = 100 }

  private func context(at time: TimeInterval = 100, duration: TimeInterval = 120,
                       controller: String? = "test.synthetic.controller", denied: [String]? = [],
                       cancellation: PhoneRunnerCallCancellation = PhoneRunnerCallCancellation()) throws -> PhoneRunnerCallContext {
    var envelope: [String: Any] = ["expiresAt": (1000 + duration) * 1000]
    if let controller { envelope["controllerBundleID"] = controller }
    if let denied { envelope["xctestDeniedBundleIDs"] = denied }
    return try PhoneRunnerCallContext(envelope: envelope, cancellation: cancellation, wallNow: 1000, continuousNow: time)
  }

  private func image(width: Int = 16, height: Int = 12, changedPixel: Int? = nil,
                     scale: CGFloat = 1, orientation: UIImage.Orientation = .up) throws -> UIImage {
    var pixels = Data(repeating: 255, count: width * height * 4)
    if let changedPixel { pixels[changedPixel * 4] = 0 }
    let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let cg = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    return UIImage(cgImage: cg, scale: scale, orientation: orientation)
  }

  private func frame(app: String? = nil, orientation: Int = 1, changedPixel: Int? = nil,
                     scale: CGFloat = 1, imageOrientation: UIImage.Orientation = .up) throws -> PhoneRunnerObservation.Frame {
    try PhoneRunnerObservation.Frame(appBundleID: app ?? target, orientation: orientation,
      image: image(changedPixel: changedPixel, scale: scale, orientation: imageOrientation))
  }

  private func expect(_ expected: PhoneRunnerObservationError, _ work: () throws -> Void,
                      file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try work(), file: file, line: line) { error in
      XCTAssertEqual(error as? PhoneRunnerObservationError, expected, file: file, line: line)
    }
  }

  private func packet(_ body: Data, length: Int? = nil, extraHeader: String = "") -> Data {
    let header = "POST /rpc HTTP/1.1\r\nAuthorization: Bearer synthetic\r\nContent-Length: \(length ?? body.count)\r\n\(extraHeader)\r\n"
    return Data(header.utf8) + body
  }

  func testHTTPParserRequiresTheCompleteExactBodyAndRejectsTrailingBytes() throws {
    let body = Data(#"{"method":"screen","params":{}}"#.utf8)
    let full = packet(body)
    XCTAssertNil(PhoneRunnerHTTPEnvelope.parse(Data(full.dropLast())))
    let parsed = try XCTUnwrap(PhoneRunnerHTTPEnvelope.parse(full))
    XCTAssertEqual(parsed.method, "POST")
    XCTAssertEqual(parsed.path, "/rpc")
    XCTAssertEqual(parsed.body, body)
    XCTAssertNil(PhoneRunnerHTTPEnvelope.parse(full + Data([0])))
    XCTAssertNil(PhoneRunnerHTTPEnvelope.parse(packet(body, length: body.count - 1)))
    XCTAssertNil(PhoneRunnerHTTPEnvelope.parse(packet(body, length: -1)))
  }

  func testHTTPParserKeepsBothFixedSizeBounds() throws {
    XCTAssertEqual(PhoneRunnerHTTPEnvelope.bodyLimit, 192 * 1024)
    XCTAssertEqual(PhoneRunnerHTTPEnvelope.headerLimit, 8192)
    let maximum = Data(repeating: 0x61, count: PhoneRunnerHTTPEnvelope.bodyLimit)
    XCTAssertNotNil(PhoneRunnerHTTPEnvelope.parse(packet(maximum)))
    XCTAssertNil(PhoneRunnerHTTPEnvelope.parse(packet(maximum + Data([0x61]))))
    XCTAssertNil(PhoneRunnerHTTPEnvelope.parse(packet(Data(), extraHeader: "X-Large: " + String(repeating: "a", count: 8192) + "\r\n")))
    let basic = packet(Data())
    let pad = 8192 - basic.count - "X: \r\n".utf8.count
    let exact = packet(Data(), extraHeader: "X: " + String(repeating: "a", count: pad) + "\r\n")
    XCTAssertEqual(exact.count, 8192)
    XCTAssertNotNil(PhoneRunnerHTTPEnvelope.parse(exact))
    XCTAssertNil(PhoneRunnerHTTPEnvelope.parse(packet(Data(), extraHeader: "X: " + String(repeating: "a", count: pad + 1) + "\r\n")))
  }

  func testDeadlineMustBeFiniteNumericAndStillLiveAtReceipt() throws {
    let invalid: [Any] = [true, "1120000", NSNull(), Double.infinity, Double.nan]
    for value in invalid {
      expect(.invalid) {
        _ = try PhoneRunnerCallContext(envelope: ["expiresAt": value], cancellation: PhoneRunnerCallCancellation(),
          wallNow: 1000, continuousNow: 100)
      }
    }
    expect(.invalid) {
      _ = try PhoneRunnerCallContext(envelope: [:], cancellation: PhoneRunnerCallCancellation(), wallNow: 1000, continuousNow: 100)
    }
    expect(.expired) { _ = try context(duration: 0) }
    expect(.expired) { _ = try context(duration: -1) }
  }

  func testReceiptConvertsToASleepInclusiveDeadlineAndCapsFutureWallDates() throws {
    let short = try context(duration: 2)
    XCTAssertNoThrow(try short.check(now: 101.999))
    expect(.expired) { try short.check(now: 102) }
    let far = try context(duration: 86_400)
    XCTAssertNoThrow(try far.check(now: 219.999))
    expect(.expired) { try far.check(now: 220) }
    // No Date is consulted again by check: even a sleeping process expires.
    expect(.expired) { try far.check(now: 1000) }
    expect(.expired) { try far.check(now: 99) }
    expect(.expired) { try far.check(now: nil) }
    expect(.expired) { try far.check(now: Double.nan) }
  }

  func testObservedConnectionCancellationStopsFutureChecksIdempotently() throws {
    let cancellation = PhoneRunnerCallCancellation()
    let call = try context(cancellation: cancellation)
    XCTAssertNoThrow(try call.check(now: 100))
    cancellation.cancel(); cancellation.cancel()
    expect(.cancelled) { try call.check(now: 100) }
    expect(.cancelled) { try call.checkApp(target, input: true, now: 101) }
  }

  func testEnvelopeMetadataCannotBeSuppliedThroughModelParams() throws {
    let raw = #"{"expiresAt":1120000,"params":{"controllerBundleID":"test.synthetic.controller","xctestDeniedBundleIDs":[]}}"#
    let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    let call = try PhoneRunnerCallContext(envelope: envelope, cancellation: PhoneRunnerCallCancellation(), wallNow: 1000, continuousNow: 100)
    XCTAssertNil(call.controllerBundleID)
    XCTAssertFalse(call.hasRoutingPolicy)
    XCTAssertNoThrow(try call.checkApp(target, input: false, now: 100))
    expect(.invalid) { try call.checkApp(target, input: true, now: 100) }
  }

  func testControllerAndDeniedAppsCannotReceiveInput() throws {
    let call = try context(denied: [target])
    XCTAssertNoThrow(try call.checkApp(controller, input: false, now: 100))
    expect(.controller) { try call.checkApp(controller, input: true, now: 100) }
    expect(.route) { try call.checkApp(target, input: false, now: 100) }
    expect(.route) { try call.checkApp(target, input: true, now: 100) }
    XCTAssertNoThrow(try call.checkApp("test.synthetic.other", input: true, now: 100))
  }

  func testAppMetadataRequiresExactBundleIdentifiersAndBoundedLists() throws {
    for invalid in ["设置", "settings", "test", " test.app", "test.app\n", "test..app", "test/app", "test.app\0", "test." + String(repeating: "x", count: 251)] {
      XCTAssertFalse(PhoneRunnerCallContext.isBundleID(invalid))
      expect(.invalid) { _ = try context(controller: invalid) }
      expect(.invalid) { _ = try context(denied: [invalid]) }
    }
    XCTAssertTrue(PhoneRunnerCallContext.isBundleID("test." + String(repeating: "x", count: 250)))
    XCTAssertNoThrow(try context(denied: (0..<512).map { "test.app\($0)" }))
    expect(.invalid) { _ = try context(denied: (0..<513).map { "test.app\($0)" }) }
    let noPolicy = try context(denied: nil)
    expect(.invalid) { try noPolicy.checkApp(target, input: true, now: 100) }
  }

  func testFingerprintUsesEveryOriginalPixelAndExactGeometry() throws {
    let original = try frame()
    XCTAssertEqual(original, try frame())
    let changed = try frame(changedPixel: 191)
    XCTAssertNotEqual(original.digest, changed.digest)
    XCTAssertEqual(original.digest.count, 32)
    let scaled = try frame(scale: 2)
    XCTAssertEqual(original.digest, scaled.digest)
    XCTAssertNotEqual(original, scaled)
    XCTAssertNotEqual(original, try frame(imageOrientation: .down))
    let dimensions = try PhoneRunnerObservation.Frame(appBundleID: target, orientation: 1, image: image(width: 8, height: 24))
    XCTAssertNotEqual(original, dimensions)
    XCTAssertEqual(original.pointSize, CGSize(width: 16, height: 12))
  }

  func testInvalidOrOversizedImageIsRefusedBeforeRemembering() throws {
    expect(.image) { _ = try PhoneRunnerObservation.Frame(appBundleID: target, orientation: 1, image: UIImage()) }
    expect(.image) { _ = try PhoneRunnerObservation.Frame(appBundleID: target, orientation: 1, image: image(width: 8193, height: 1)) }
    expect(.image) { _ = try frame(scale: 9) }
  }

  func testReadOnlyValidationDoesNotSpendTheObservationAndFinalUseDoes() throws {
    let clock = Clock(), observed = try frame(), call = try context()
    let cache = PhoneRunnerObservation(now: { clock.value })
    try cache.remember(screen: "s1", frame: observed, context: call, capturedAt: 100)
    for _ in 0..<2 { XCTAssertNoThrow(try cache.validate(screen: "s1", fresh: observed, context: call, consume: false)) }
    XCTAssertEqual(cache.latest?.screen, "s1")
    XCTAssertNoThrow(try cache.validate(screen: "s1", fresh: observed, context: call, consume: true))
    XCTAssertNil(cache.latest)
    expect(.stale) { _ = try cache.validate(screen: "s1", fresh: observed, context: call, consume: true) }
  }

  func testChangeBetweenReadOnlyValidationAndFinalActionIsCaughtAndSpent() throws {
    let clock = Clock(), observed = try frame(), call = try context()
    let cache = PhoneRunnerObservation(now: { clock.value })
    try cache.remember(screen: "s1", frame: observed, context: call, capturedAt: 100)
    try cache.validate(screen: "s1", fresh: observed, context: call, consume: false)
    expect(.changed) { _ = try cache.validate(screen: "s1", fresh: frame(changedPixel: 0), context: call, consume: true) }
    XCTAssertNil(cache.latest)
    // Returning the old pixels afterwards cannot put a consumed grant back.
    expect(.stale) { _ = try cache.validate(screen: "s1", fresh: observed, context: call, consume: true) }
  }

  func testLatestScreenReplacesOldScreenButOldTokenCannotSpendTheNewOne() throws {
    let clock = Clock(), observed = try frame(), call = try context()
    let cache = PhoneRunnerObservation(now: { clock.value })
    try cache.remember(screen: "s1", frame: observed, context: call, capturedAt: 100)
    try cache.remember(screen: "s2", frame: observed, context: call, capturedAt: 100)
    expect(.stale) { _ = try cache.validate(screen: "s1", fresh: observed, context: call, consume: true) }
    XCTAssertEqual(cache.latest?.screen, "s2")
    XCTAssertNoThrow(try cache.validate(screen: "s2", fresh: observed, context: call, consume: true))
  }

  func testInvalidateAndFailedRememberNeverRestoreAnEarlierScreen() throws {
    let clock = Clock(), observed = try frame(), call = try context()
    let cache = PhoneRunnerObservation(now: { clock.value })
    try cache.remember(screen: "s1", frame: observed, context: call, capturedAt: 100)
    cache.invalidate(); cache.invalidate()
    XCTAssertNil(cache.latest)
    for token in ["s0", "s01", "s1\n", "s-1", "s+1", "S1", "1", "s"] {
      try cache.remember(screen: "s2", frame: observed, context: call, capturedAt: 100)
      expect(.stale) { try cache.remember(screen: token, frame: observed, context: call, capturedAt: 100) }
      XCTAssertNil(cache.latest)
    }
  }

  func testObservationExpiresAt120SecondsIncludingSleepWithAFreshActionDeadline() throws {
    let clock = Clock(), observed = try frame()
    let cache = PhoneRunnerObservation(now: { clock.value })
    try cache.remember(screen: "s1", frame: observed, context: context(), capturedAt: 100)
    clock.value = 219.999
    XCTAssertNoThrow(try cache.validate(screen: "s1", fresh: observed, context: context(at: 219.999), consume: false))
    clock.value = 220
    expect(.stale) { _ = try cache.validate(screen: "s1", fresh: observed, context: context(at: 220), consume: true) }
    XCTAssertNil(cache.latest)
  }

  func testUnavailableBackwardAndFutureCaptureTimesRefuseTheObservation() throws {
    let clock = Clock(), observed = try frame(), call = try context()
    let cache = PhoneRunnerObservation(now: { clock.value })
    expect(.stale) { try cache.remember(screen: "s1", frame: observed, context: call, capturedAt: 101) }
    expect(.stale) { try cache.remember(screen: "s1", frame: observed, context: call, capturedAt: .nan) }
    try cache.remember(screen: "s1", frame: observed, context: call, capturedAt: 100)
    clock.value = nil
    expect(.expired) { _ = try cache.validate(screen: "s1", fresh: observed, context: call, consume: true) }
    XCTAssertNil(cache.latest)
    clock.value = 100
    try cache.remember(screen: "s2", frame: observed, context: call, capturedAt: 100)
    clock.value = 99
    expect(.stale) { _ = try cache.validate(screen: "s2", fresh: observed, context: context(at: 99), consume: true) }
  }

  func testSwitchingAppControllerOrRouteCannotReuseAPreviouslyCheckedScreen() throws {
    let clock = Clock(), observed = try frame(), call = try context()
    let cache = PhoneRunnerObservation(now: { clock.value })
    try cache.remember(screen: "s1", frame: observed, context: call, capturedAt: 100)
    expect(.app) { _ = try cache.validate(screen: "s1", fresh: frame(app: "test.synthetic.other"), context: call, consume: true) }
    XCTAssertNil(cache.latest)
    try cache.remember(screen: "s2", frame: observed, context: call, capturedAt: 100)
    expect(.invalid) { _ = try cache.validate(screen: "s2", fresh: observed, context: context(controller: "test.synthetic.second"), consume: true) }
    try cache.remember(screen: "s3", frame: observed, context: call, capturedAt: 100)
    expect(.route) { _ = try cache.validate(screen: "s3", fresh: observed, context: context(denied: [target]), consume: true) }
    XCTAssertNil(cache.latest)
  }

  func testControllerScreenCannotBecomeAnInputTicket() throws {
    let clock = Clock(), call = try context(), own = try frame(app: controller)
    let cache = PhoneRunnerObservation(now: { clock.value })
    try cache.remember(screen: "s1", frame: own, context: call, capturedAt: 100)
    expect(.controller) { _ = try cache.validate(screen: "s1", fresh: own, context: call, consume: true) }
    XCTAssertNil(cache.latest)
  }

  func testLegacyReturnToAppReadWithoutMetadataDoesNotAuthorizeInput() throws {
    let clock = Clock(), observed = try frame()
    let cache = PhoneRunnerObservation(now: { clock.value })
    let legacy = try context(controller: nil, denied: nil)
    try cache.remember(screen: "s1", frame: observed, context: legacy, capturedAt: 100)
    expect(.invalid) { _ = try cache.validate(screen: "s1", fresh: observed, context: context(), consume: true) }
    XCTAssertNil(cache.latest)
  }

  func testEachDirectionMustMatchAndAFlatReadingFollowsTheScreenshotShape() throws {
    let clock = Clock(), call = try context()
    let cache = PhoneRunnerObservation(now: { clock.value })
    for direction in 1...4 {
      let observed = try frame(orientation: direction)
      try cache.remember(screen: "s1", frame: observed, context: call, capturedAt: 100)
      XCTAssertNoThrow(try cache.validate(screen: "s1", fresh: observed, context: call, consume: true))
    }
    // The test image is 16x12 (landscape): unknown, face up and face down read as landscape (3),
    // so against a portrait observation they are a change, as is any other direction.
    for direction in [0, 2, 5, 6] {
      try cache.remember(screen: "s2", frame: frame(), context: call, capturedAt: 100)
      expect(.orientation) { _ = try cache.validate(screen: "s2", fresh: frame(orientation: direction), context: call, consume: true) }
      XCTAssertNil(cache.latest)
    }
    // Lying flat while the interface stays landscape is the same frame.
    for direction in [0, 5, 6] {
      try cache.remember(screen: "s3", frame: frame(orientation: 3), context: call, capturedAt: 100)
      XCTAssertNoThrow(try cache.validate(screen: "s3", fresh: frame(orientation: direction), context: call, consume: true))
    }
    XCTAssertEqual(PhoneRunnerObservation.interfaceOrientation(device: 5, pixelWidth: 12, pixelHeight: 16), 1)
    XCTAssertEqual(PhoneRunnerObservation.interfaceOrientation(device: 0, pixelWidth: 16, pixelHeight: 12), 3)
    XCTAssertEqual(PhoneRunnerObservation.interfaceOrientation(device: 4, pixelWidth: 12, pixelHeight: 16), 4)
  }

  func testACompletedReadConnectionMayCloseWithoutCancellingTheLaterApprovedCall() throws {
    let clock = Clock(), cancellation = PhoneRunnerCallCancellation(), observed = try frame()
    let cache = PhoneRunnerObservation(now: { clock.value })
    let read = try context(cancellation: cancellation)
    try cache.remember(screen: "s1", frame: observed, context: read, capturedAt: 100)
    cancellation.cancel()
    // The record retains binding data, not the already-completed HTTP context.
    XCTAssertNoThrow(try cache.validate(screen: "s1", fresh: observed, context: context(), consume: true))
  }

  func testCancellationBeforeFinalConsumptionDoesNotReturnTheTicket() throws {
    let clock = Clock(), cancellation = PhoneRunnerCallCancellation(), observed = try frame()
    let cache = PhoneRunnerObservation(now: { clock.value })
    try cache.remember(screen: "s1", frame: observed, context: context(), capturedAt: 100)
    let action = try context(cancellation: cancellation)
    try cache.validate(screen: "s1", fresh: observed, context: action, consume: false)
    cancellation.cancel()
    expect(.cancelled) { _ = try cache.validate(screen: "s1", fresh: observed, context: action, consume: true) }
    XCTAssertNil(cache.latest)
  }

  func testTextBoundaryRejectsTheWholeUnsupportedInputBeforeAnyPrimitive() throws {
    XCTAssertTrue(PhoneRunnerTextRules.permits(String(repeating: "a", count: 1024)))
    XCTAssertFalse(PhoneRunnerTextRules.permits(String(repeating: "a", count: 1025)))
    let maximum = String(repeating: "中", count: 1365) + "A"
    XCTAssertEqual(maximum.utf8.count, 4096)
    XCTAssertTrue(PhoneRunnerTextRules.permits(maximum))
    XCTAssertFalse(PhoneRunnerTextRules.permits(maximum + "B"))
    for value in ["", "safe\nsubmit", "safe\tother", "中文\n提交", "中文\t焦点", "123", " 12-34-56 ", "１２３４５６", "١٢٣٤٥٦"] {
      XCTAssertFalse(PhoneRunnerTextRules.permits(value))
    }
    for scalar in [0, 1, 8, 9, 10, 13, 27, 31, 0x7f, 0x85, 0x9f, 0x061c, 0x200e, 0x200f,
                   0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069] {
      let character = try XCTUnwrap(UnicodeScalar(scalar))
      XCTAssertFalse(PhoneRunnerTextRules.permits("approved prefix" + String(character) + "suffix"))
    }
    XCTAssertTrue(PhoneRunnerTextRules.permits("synthetic ordinary value"))
  }

  func testSensitiveHintsIncludeMasksAndBilingualSecurityLabels() {
    for value in ["密码自动填充", "短信验证码", "银行卡号", "支付", "Password", "Security code", "PIN", "PIN码", "OTP", "CVV", "AutoFill", "passkey", "Keychain", "•••", "* * *", "●●●"] {
      XCTAssertTrue(PhoneRunnerTextRules.hasSensitiveHint(value), value)
    }
    // Negative examples check the heuristic's exact behavior, not field safety.
    for value in ["Display name", "shipping address", "普通备注", "a.b", "*", "●●"] {
      XCTAssertFalse(PhoneRunnerTextRules.hasSensitiveHint(value), value)
    }
  }

  func testTextBudgetCountsUTF8AndTheAppendedWarning() throws {
    let full = String(repeating: "a", count: PhoneRunnerOutputBudget.textBytes)
    XCTAssertNoThrow(try PhoneRunnerOutputBudget.validate(["text": full, "ok": true]))
    expect(.output) { try PhoneRunnerOutputBudget.validate(["text": full + "b"]) }
    expect(.output) { try PhoneRunnerOutputBudget.validate(["text": full, "warning": "synthetic warning"]) }
    let multibyte = String(repeating: "中", count: PhoneRunnerOutputBudget.textBytes / 3)
    XCTAssertNoThrow(try PhoneRunnerOutputBudget.validate(["text": multibyte]))
    expect(.output) { try PhoneRunnerOutputBudget.validate(["text": multibyte + "中"]) }
  }

  func testResultBudgetCountsJSONEscapingAndRawImageBytesWithoutTruncation() throws {
    let escaping = String(repeating: "\0", count: PhoneRunnerOutputBudget.textBytes)
    XCTAssertEqual(escaping.utf8.count, PhoneRunnerOutputBudget.textBytes)
    expect(.output) { try PhoneRunnerOutputBudget.validate(["text": escaping]) }
    // Synthetic bytes exercise only transport limits, not JPEG validity.
    let maximum = Data(repeating: 0, count: PhoneRunnerOutputBudget.jpegBytes)
    XCTAssertNoThrow(try PhoneRunnerOutputBudget.validate(["text": "synthetic", "image": maximum.base64EncodedString()]))
    expect(.output) { try PhoneRunnerOutputBudget.validate(["image": (maximum + Data([0])).base64EncodedString()]) }
    expect(.output) { try PhoneRunnerOutputBudget.validate(["image": "%%% invalid base64"]) }
    expect(.output) { try PhoneRunnerOutputBudget.validate(["text": "synthetic", "nonJSON": Double.nan]) }
  }

  private func screenFrame(darkBlock side: (width: Int, height: Int)?) throws -> PhoneRunnerObservation.Frame {
    let width = 400, height = 300
    var pixels = Data(repeating: 255, count: width * height * 4)
    if let side {
      for y in 0..<side.height {
        for x in 0..<side.width {
          let base = (y * width + x) * 4
          pixels[base] = 0; pixels[base + 1] = 0; pixels[base + 2] = 0
        }
      }
    }
    let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let cg = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    return try PhoneRunnerObservation.Frame(appBundleID: target, orientation: 3, image: UIImage(cgImage: cg))
  }

  func testAScreenSizedFrameToleratesAFadingIndicatorButNotALayoutChange() throws {
    let clock = Clock(), call = try context()
    let cache = PhoneRunnerObservation(now: { clock.value })
    let observed = try screenFrame(darkBlock: nil)
    // 400 of 120,000 pixels: a scroll indicator, a caret, the clock.
    let faded = try screenFrame(darkBlock: (20, 20))
    XCTAssertNotEqual(observed.digest, faded.digest)
    XCTAssertTrue(observed.matches(faded))
    try cache.remember(screen: "s1", frame: observed, context: call, capturedAt: 100)
    XCTAssertNoThrow(try cache.validate(screen: "s1", fresh: faded, context: call, consume: true))
    // 2,400 pixels (2%): something appeared.
    let covered = try screenFrame(darkBlock: (60, 40))
    XCTAssertFalse(observed.matches(covered))
    try cache.remember(screen: "s2", frame: observed, context: call, capturedAt: 100)
    expect(.changed) { _ = try cache.validate(screen: "s2", fresh: covered, context: call, consume: true) }
    // Test-sized images stay exact.
    XCTAssertFalse(try frame().matches(try frame(changedPixel: 0)))
  }

  func testMaximumTrustedRouteListFitsTheBoundedRequestEnvelope() throws {
    let identifiers = (0..<512).map { "test." + String(repeating: "x", count: 246) + String(format: "%04d", $0) }
    XCTAssertTrue(identifiers.allSatisfy { $0.utf8.count == 255 })
    let envelope: [String: Any] = [
      "method": "type", "expiresAt": 1_120_000, "controllerBundleID": controller,
      "xctestDeniedBundleIDs": identifiers,
      "params": ["screen": "s1", "id": 1, "text": String(repeating: "中", count: 1365) + "A"],
    ]
    let bytes = try JSONSerialization.data(withJSONObject: envelope)
    XCTAssertLessThan(bytes.count, PhoneRunnerHTTPEnvelope.bodyLimit)
    XCTAssertNotNil(PhoneRunnerHTTPEnvelope.parse(packet(bytes)))
    let call = try PhoneRunnerCallContext(envelope: envelope, cancellation: PhoneRunnerCallCancellation(), wallNow: 1000, continuousNow: 100)
    XCTAssertEqual(call.deniedBundleIDs.count, 512)
  }
}
