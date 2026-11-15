import Foundation

/// The actual Node runner /result limits, applied before its HTTP POST. An
/// oversized answer becomes a small error for the same call, so a size-limit
/// rejection need not leave Node executing. It never clips or replays actions.
enum IOSPhoneResultEnvelope {
  static let textBytes = 512 * 1024
  static let imageBytes = 880 * 1024
  static let imageBase64Bytes = 1200 * 1024
  static let bodyBytes = 2 * 1024 * 1024

  static func values(requestID: String, runID: String, outcome: IOSPhoneOutcome) -> [String: Any] {
    let failure: [String: Any] = ["id": requestID, "runId": runID, "isError": true,
      "text": "手机操控结果超过完整传输边界，未截断或重做动作。本次动作可能已经发生；请核对手机，不要自动重试。"]
    guard outcome.text.utf8.count <= textBytes else { return failure }
    var result: [String: Any] = ["id": requestID, "runId": runID,
      "text": outcome.text, "isError": outcome.isError]
    if let image = outcome.image {
      guard !image.isEmpty, image.count <= imageBytes else { return failure }
      let encoded = image.base64EncodedString()
      guard encoded.utf8.count <= imageBase64Bytes else { return failure }
      result["image"] = encoded
    }
    // JSON escaping can make a legal text/image pair exceed the total body
    // limit. Count the complete envelope, including both ownership fields.
    guard let data = try? JSONSerialization.data(withJSONObject: result), data.count <= bodyBytes else {
      return failure
    }
    return result
  }
}
