import Foundation
import XCTest
@testable import Runner

/// Exercises the production result-envelope helper with complete synthetic
/// strings and Data. The bytes need not be a valid JPEG: this suite verifies the
/// transport envelope, not image decoding. It performs no HTTP request or action.
final class IOSPhoneResultEnvelopeTests: XCTestCase {
  private static let textLimit = 512 * 1024
  private static let imageLimit = 880 * 1024
  private static let base64Limit = 1200 * 1024
  private static let bodyLimit = 2 * 1024 * 1024
  private static let requestID = "synthetic-id:\"\\\n42"
  private static let runID = "synthetic-run:中文🙂"
  private static let rejectedMarker = "SYNTHETIC_REJECTED_RESULT_PAYLOAD_"

  private func values(_ text: String, isError: Bool = false, image: Data? = nil) -> [String: Any] {
    let outcome = Runner.IOSPhoneOutcome(text: text, isError: isError, image: image)
    return Runner.IOSPhoneResultEnvelope.values(requestID: Self.requestID,
      runID: Self.runID, outcome: outcome)
  }

  private func rawEnvelope(_ text: String, isError: Bool = false, image: Data? = nil) -> [String: Any] {
    var envelope: [String: Any] = ["id": Self.requestID, "runId": Self.runID,
      "text": text, "isError": isError]
    if let image { envelope["image"] = image.base64EncodedString() }
    return envelope
  }

  private func serialized(_ envelope: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: envelope)
  }

  private func boundedImage(_ count: Int) -> Data {
    var bytes = Data(repeating: 0x23, count: count)
    let tail = Data([0x00, 0xff, 0x80, 0x01, 0x7f, 0xfe, 0x55, 0xaa])
    if count >= tail.count { bytes.replaceSubrange((count - tail.count)..<count, with: tail) }
    return bytes
  }

  private func assertOwners(_ envelope: [String: Any],
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(envelope["id"] as? String, Self.requestID, file: file, line: line)
    XCTAssertEqual(envelope["runId"] as? String, Self.runID, file: file, line: line)
  }

  private func assertFullImage(_ envelope: [String: Any], original: Data,
                               file: StaticString = #filePath, line: UInt = #line) throws {
    let encoded = try XCTUnwrap(envelope["image"] as? String, file: file, line: line)
    let decoded = try XCTUnwrap(Data(base64Encoded: encoded), file: file, line: line)
    XCTAssertEqual(decoded.count, original.count, file: file, line: line)
    // Compare every byte without making a failed assertion print a large body.
    XCTAssertTrue(decoded == original, "the image must remain complete", file: file, line: line)
    XCTAssertTrue(encoded == original.base64EncodedString(),
      "the original Data must be encoded without truncation", file: file, line: line)
  }

  private func assertSmallFailure(_ envelope: [String: Any], forbiddenMarker: String? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
    assertOwners(envelope, file: file, line: line)
    XCTAssertEqual(Set(envelope.keys), Set(["id", "runId", "text", "isError"]),
                   file: file, line: line)
    XCTAssertEqual(envelope["isError"] as? Bool, true, file: file, line: line)
    XCTAssertNil(envelope["image"], file: file, line: line)
    let text = try XCTUnwrap(envelope["text"] as? String, file: file, line: line)
    XCTAssertLessThan(text.utf8.count, 4096, file: file, line: line)
    XCTAssertTrue(text.contains("不要自动重试"), file: file, line: line)
    if let forbiddenMarker {
      XCTAssertFalse(text.contains(forbiddenMarker),
        "the replacement error must not embed the rejected payload", file: file, line: line)
    }
    let body = try serialized(envelope)
    XCTAssertLessThan(body.count, 8192, file: file, line: line)
    let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any],
                               file: file, line: line)
    assertOwners(decoded, file: file, line: line)
    XCTAssertNil(decoded["image"], file: file, line: line)
  }

  func testTextAtExactly512KiBIsPreservedWithOwnershipFields() throws {
    let text = String(repeating: "A", count: Self.textLimit - 8) + "TAIL-END"
    XCTAssertEqual(text.utf8.count, Self.textLimit)
    let envelope = values(text)
    assertOwners(envelope)
    XCTAssertEqual(envelope["isError"] as? Bool, false)
    XCTAssertNil(envelope["image"])
    let returned = try XCTUnwrap(envelope["text"] as? String)
    XCTAssertTrue(returned == text, "all text bytes, including the tail, must survive")
    let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: serialized(envelope)) as? [String: Any])
    XCTAssertTrue((decoded["text"] as? String) == text)
    assertOwners(decoded)
  }

  func testTextOneByteOver512KiBBecomesSmallErrorWithoutOriginalTextOrImage() throws {
    let text = Self.rejectedMarker + String(repeating: "x",
      count: Self.textLimit + 1 - Self.rejectedMarker.utf8.count)
    XCTAssertEqual(text.utf8.count, Self.textLimit + 1)
    let envelope = values(text, image: boundedImage(128))
    try assertSmallFailure(envelope, forbiddenMarker: Self.rejectedMarker)
  }

  func testUnicodeLimitCountsUTF8BytesAndNeverCutsAScalarOrGrapheme() throws {
    let emoji = String(repeating: "🙂", count: Self.textLimit / 4)
    let combining = String(repeating: "e\u{301}", count: Self.textLimit / 3)
      + String(repeating: "a", count: Self.textLimit % 3)
    for text in [emoji, combining] {
      XCTAssertEqual(text.utf8.count, Self.textLimit)
      XCTAssertLessThan(text.count, Self.textLimit)
      let accepted = values(text)
      XCTAssertEqual(accepted["isError"] as? Bool, false)
      XCTAssertTrue((accepted["text"] as? String) == text,
        "the accepted Unicode string must remain exact")
      let rejected = text + "a"
      XCTAssertEqual(rejected.utf8.count, Self.textLimit + 1)
      XCTAssertLessThan(rejected.count, Self.textLimit)
      try assertSmallFailure(values(rejected), forbiddenMarker: String(text.prefix(16)))
    }
  }

  func testImageAtExactly880KiBPreservesEveryOriginalByte() throws {
    let original = boundedImage(Self.imageLimit)
    XCTAssertEqual(original.count, Self.imageLimit)
    XCTAssertLessThanOrEqual(original.base64EncodedString().utf8.count, Self.base64Limit)
    let envelope = values("synthetic complete image", image: original)
    assertOwners(envelope)
    XCTAssertEqual(envelope["isError"] as? Bool, false)
    try assertFullImage(envelope, original: original)
    XCTAssertLessThanOrEqual(try serialized(envelope).count, Self.bodyLimit)
  }

  func testImageOneByteOver880KiBBecomesSmallErrorAndDropsOriginalPayload() throws {
    let original = boundedImage(Self.imageLimit + 1)
    XCTAssertEqual(original.count, Self.imageLimit + 1)
    try assertSmallFailure(values(Self.rejectedMarker, image: original),
                           forbiddenMarker: Self.rejectedMarker)
  }

  func testEmptyImageIsRejectedWhileAbsentImagePreservesTheAnswer() throws {
    try assertSmallFailure(values(Self.rejectedMarker, image: Data()),
                           forbiddenMarker: Self.rejectedMarker)
    let absent = values(Self.rejectedMarker, image: nil)
    assertOwners(absent)
    XCTAssertEqual(absent["isError"] as? Bool, false)
    XCTAssertTrue((absent["text"] as? String) == Self.rejectedMarker)
    XCTAssertNil(absent["image"])
  }

  func testCompleteBinaryDataAndExistingErrorFlagArePreserved() throws {
    let original = Data((0...255).map(UInt8.init))
      + Data("synthetic binary tail\u{0000}中文🙂".utf8)
    let text = "original synthetic failure: \"quoted\" \\ newline\n中文🙂"
    let envelope = values(text, isError: true, image: original)
    assertOwners(envelope)
    XCTAssertEqual(envelope["isError"] as? Bool, true)
    XCTAssertTrue((envelope["text"] as? String) == text)
    try assertFullImage(envelope, original: original)
    let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: serialized(envelope)) as? [String: Any])
    XCTAssertTrue((decoded["text"] as? String) == text)
    try assertFullImage(decoded, original: original)
  }

  func testIndividuallyLegalEscapedTextAndImageCanExceedTheCompleteBodyLimit() throws {
    let text = Self.rejectedMarker + String(repeating: "\\",
      count: Self.textLimit - Self.rejectedMarker.utf8.count)
    let image = boundedImage(Self.imageLimit)
    XCTAssertEqual(text.utf8.count, Self.textLimit)
    XCTAssertEqual(image.count, Self.imageLimit)
    XCTAssertLessThanOrEqual(image.base64EncodedString().utf8.count, Self.base64Limit)
    // JSON backslash escaping, base64, and both owner fields are counted by the
    // same Foundation serializer used for the actual HTTP request body.
    XCTAssertGreaterThan(try serialized(rawEnvelope(text, image: image)).count, Self.bodyLimit)
    try assertSmallFailure(values(text, image: image), forbiddenMarker: Self.rejectedMarker)
  }

  func testCompleteJSONBodyAt2MiBIsAcceptedAndOneExtraByteIsRejected() throws {
    let image = boundedImage(Self.imageLimit)
    let baseline = try serialized(rawEnvelope("", image: image)).count
    let wireBytesForText = Self.bodyLimit - baseline
    guard wireBytesForText > 0 else {
      XCTFail("the exact-boundary fixture needs room for its text")
      return
    }
    // Every literal backslash occupies two bytes inside its JSON string. An
    // optional ASCII byte supplies an odd remainder. Ownership and image JSON
    // overhead come from serializing this exact fixture, not a hand estimate.
    let text = String(repeating: "\\", count: wireBytesForText / 2)
      + String(repeating: "a", count: wireBytesForText % 2)
    XCTAssertLessThan(text.utf8.count, Self.textLimit)
    XCTAssertEqual(try serialized(rawEnvelope(text, image: image)).count, Self.bodyLimit)

    let accepted = values(text, image: image)
    assertOwners(accepted)
    XCTAssertEqual(accepted["isError"] as? Bool, false)
    XCTAssertTrue((accepted["text"] as? String) == text)
    try assertFullImage(accepted, original: image)
    XCTAssertEqual(try serialized(accepted).count, Self.bodyLimit)

    let over = text + "a"
    XCTAssertLessThanOrEqual(over.utf8.count, Self.textLimit)
    XCTAssertEqual(try serialized(rawEnvelope(over, image: image)).count, Self.bodyLimit + 1)
    try assertSmallFailure(values(over, image: image), forbiddenMarker: String(text.prefix(16)))
  }
}
