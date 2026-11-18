import Foundation
import CoreFoundation
import CryptoKit
import Darwin
import UIKit

/// One bounded HTTP request, shared with source-level unit fixtures. No
/// streaming, chunking or pipelining is added by the observation protocol.
enum PhoneRunnerHTTPEnvelope {
  static let bodyLimit = 192 * 1024
  static let headerLimit = 8192
  struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
  }

  /// Nil for an incomplete or rejected request. In either case no tool runs.
  static func parse(_ data: Data) -> Request? {
    guard data.count <= bodyLimit + headerLimit,
      let end = data.range(of: Data("\r\n\r\n".utf8)),
      data.distance(from: data.startIndex, to: end.upperBound) <= headerLimit else { return nil }
    let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
    let first = head.first?.split(separator: " ").map(String.init) ?? []
    guard first.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in head.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    guard let length = Int(headers["content-length"] ?? "0") else { return nil }
    let body = data[end.upperBound...]
    guard (0...bodyLimit).contains(length), body.count == length else { return nil }
    return Request(method: first[0], path: first[1], headers: headers, body: Data(body))
  }
}

/// Sleep-inclusive monotonic time, available since iOS 10. No wall-clock
/// fallback: an unavailable or reversed clock refuses admission.
enum PhoneRunnerObservationClock {
  private static let secondsPerTick: Double? = {
    var info = mach_timebase_info_data_t(numer: 0, denom: 0)
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else { return nil }
    return Double(info.numer) / Double(info.denom) / 1_000_000_000
  }()

  static func now() -> TimeInterval? {
    guard let factor = secondsPerTick else { return nil }
    return Double(mach_continuous_time()) * factor
  }
}

enum PhoneRunnerObservationError: Error, Equatable {
  case invalid, expired, cancelled, stale, changed, app, controller, route, orientation, image, output

  var message: String {
    switch self {
    case .invalid: return "手机动作缺少有效的原生调用上下文，没有继续操作。"
    case .expired: return "手机动作已过期，已停止后续操作；若已有动作开始，请核对屏幕，不要自动重试。"
    case .cancelled: return "手机调用连接已结束，已停止后续操作；已进入 XCTest 的动作结果仍需核对。"
    case .stale: return "这个屏幕号已过期或已使用；请重新 screen，不要猜编号或重试旧动作。"
    case .changed: return "屏幕像素已变化，已停止后续输入；请重新 screen 并核对屏幕。"
    case .app: return "无法核实同一个前台应用，已停止后续输入；请核对屏幕。"
    case .controller: return "当前是控制 App 的界面，没有向它派发手机输入；请回到目标应用。"
    case .route: return "当前应用只允许 CoreDevice 路线，没有通过 XCTest 操作。"
    case .orientation: return "设备方向未知或已变化，已停止后续输入；请重新 screen。"
    case .image: return "屏幕图片无法完整核对，已停止后续操作。"
    case .output: return "手机读屏结果超过返回上限，已停止后续操作；没有截断结果，请缩小读取范围后重新发起。"
    }
  }
}

/// Match the receiving bridge before performing another collect scroll. These
/// limits apply to the whole result, including warning and JSON escaping.
enum PhoneRunnerOutputBudget {
  static let textBytes = 512 * 1024
  static let jpegBytes = 880 * 1024
  static let jsonBytes = 2 * 1024 * 1024

  static func validate(_ result: [String: Any]) throws {
    let text = result["text"] as? String ?? ""
    let warning = (result["warning"] as? String).map { "\n（注意：\($0)）" } ?? ""
    guard text.utf8.count <= textBytes, warning.utf8.count <= textBytes - text.utf8.count else {
      throw PhoneRunnerObservationError.output
    }
    if let image = result["image"] as? String {
      guard image.utf8.count <= 4 * ((jpegBytes + 2) / 3),
        let decoded = Data(base64Encoded: image), decoded.count <= jpegBytes else {
        throw PhoneRunnerObservationError.output
      }
    }
    // NaN, infinity or a non-JSON value raises an Objective-C exception that `try?` can't catch.
    guard JSONSerialization.isValidJSONObject(result),
      let data = try? JSONSerialization.data(withJSONObject: result), data.count <= jsonBytes else {
      throw PhoneRunnerObservationError.output
    }
  }
}

/// Network callbacks and the main-thread tool runner share only this flag.
/// It can stop subsequent primitives, not revoke an already-entered XCTest call.
final class PhoneRunnerCallCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  var isCancelled: Bool {
    lock.lock(); defer { lock.unlock() }
    return cancelled
  }
}

/// These values come from the authenticated RPC envelope, never model params.
/// Convert the remaining wall deadline once; wall-clock changes cannot extend it.
struct PhoneRunnerCallContext: Sendable {
  let controllerBundleID: String?
  let deniedBundleIDs: Set<String>
  let hasRoutingPolicy: Bool
  private let receivedAt: TimeInterval
  private let deadline: TimeInterval
  private let cancellation: PhoneRunnerCallCancellation

  init(envelope: [String: Any], cancellation: PhoneRunnerCallCancellation,
       wallNow: TimeInterval = Date().timeIntervalSince1970,
       continuousNow: TimeInterval? = PhoneRunnerObservationClock.now()) throws {
    guard let number = envelope["expiresAt"] as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, wallNow.isFinite,
      let continuousNow, continuousNow.isFinite else { throw PhoneRunnerObservationError.invalid }
    let remaining = number.doubleValue / 1000 - wallNow
    guard remaining.isFinite, remaining > 0 else { throw PhoneRunnerObservationError.expired }
    let boundedDeadline = continuousNow + min(remaining, 120)
    guard boundedDeadline.isFinite, boundedDeadline > continuousNow else { throw PhoneRunnerObservationError.expired }
    receivedAt = continuousNow; deadline = boundedDeadline
    self.cancellation = cancellation
    if let value = envelope["controllerBundleID"] {
      guard let value = value as? String, Self.isBundleID(value) else { throw PhoneRunnerObservationError.invalid }
      controllerBundleID = value
    } else { controllerBundleID = nil }
    if let values = envelope["xctestDeniedBundleIDs"] {
      guard let values = values as? [String], values.count <= 512,
        values.allSatisfy(Self.isBundleID) else { throw PhoneRunnerObservationError.invalid }
      deniedBundleIDs = Set(values); hasRoutingPolicy = true
    } else { deniedBundleIDs = []; hasRoutingPolicy = false }
  }

  static func isBundleID(_ value: String) -> Bool {
    value.utf8.count <= 255 && PhoneRunnerAppCatalog.bundleID(for: value) == value
  }

  func check(now: TimeInterval? = PhoneRunnerObservationClock.now()) throws {
    guard !cancellation.isCancelled else { throw PhoneRunnerObservationError.cancelled }
    guard let now, now.isFinite, now >= receivedAt, now < deadline else { throw PhoneRunnerObservationError.expired }
  }

  func checkApp(_ app: String, input: Bool, now: TimeInterval? = PhoneRunnerObservationClock.now()) throws {
    try check(now: now)
    guard Self.isBundleID(app) else { throw PhoneRunnerObservationError.app }
    guard !deniedBundleIDs.contains(app) else { throw PhoneRunnerObservationError.route }
    if input {
      guard let controllerBundleID, hasRoutingPolicy else { throw PhoneRunnerObservationError.invalid }
      guard app != controllerBundleID else { throw PhoneRunnerObservationError.controller }
    }
  }
}

/// The runner repeats the immutable plan's whole-string refusal at its input
/// boundary. No prefix is ever typed before discovering an unsupported scalar.
enum PhoneRunnerTextRules {
  static func permits(_ text: String) -> Bool {
    guard !text.isEmpty, text.utf8.count <= 4096,
      text.unicodeScalars.allSatisfy({ scalar in
        let value = scalar.value
        return value >= 32 && !(0x7f...0x9f).contains(value)
          && ![0x061c, 0x200e, 0x200f].contains(value)
          && !(0x202a...0x202e).contains(value) && !(0x2066...0x2069).contains(value)
      }) else { return false }
    if text.utf8.allSatisfy({ $0 < 128 }), text.utf8.count > 1024 { return false }
    let numeric = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "-" }
    return !((3...8).contains(numeric.count) && numeric.allSatisfy { CharacterSet.decimalDigits.contains($0) })
  }

  /// Conservative hints only. No match is not a claim that a field is safe.
  static func hasSensitiveHint(_ text: String) -> Bool {
    let lower = text.lowercased()
    let words = ["密码", "口令", "验证码", "动态码", "安全码", "校验码", "一次性", "支付", "付款", "银行卡", "卡号",
      "password", "passcode", "verification code", "one-time code", "one time code", "security code",
      "two-factor", "card number", "payment", "autofill", "auto-fill", "passkey", "keychain"]
    return words.contains(where: lower.contains)
      || lower.range(of: #"(?:^|[^a-z])(?:pin|otp|cvv|cvc|2fa)(?:[^a-z]|$)"#, options: .regularExpression) != nil
      || lower.range(of: #"(?:[•●∙◦·*]\s*){3,}"#, options: .regularExpression) != nil
  }
}

/// Latest observation only, kept in memory. Main thread only in PhoneTools.
/// Pixel equality is a conservative change detector, not proof of a frozen UI.
final class PhoneRunnerObservation {
  struct Frame: Equatable {
    let appBundleID: String
    let orientation: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let imageOrientation: Int
    let scale: Double
    let pointSize: CGSize
    let digest: Data
    /// Per-pixel luminance, kept to tell a real change from a fading scroll indicator (see [matches]).
    let luma: [UInt8]

    /// Below this many pixels (test images) only identical pixels match.
    static let tolerantPixels = 100_000

    init(appBundleID: String, orientation: Int, image: UIImage) throws {
      guard PhoneRunnerCallContext.isBundleID(appBundleID), let pixels = image.cgImage,
        (1...8192).contains(pixels.width), (1...8192).contains(pixels.height),
        pixels.width <= 12_000_000 / pixels.height,
        image.scale.isFinite, image.scale > 0, image.scale <= 8,
        image.size.width.isFinite, image.size.height.isFinite,
        image.size.width > 0, image.size.height > 0,
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw PhoneRunnerObservationError.image }
      self.appBundleID = appBundleID
      self.orientation = PhoneRunnerObservation.interfaceOrientation(device: orientation,
        pixelWidth: pixels.width, pixelHeight: pixels.height)
      pixelWidth = pixels.width; pixelHeight = pixels.height
      imageOrientation = image.imageOrientation.rawValue
      scale = Double(image.scale); pointSize = image.size
      var rgba = Data(count: pixels.width * pixels.height * 4)
      let drew = rgba.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(data: raw.baseAddress, width: pixels.width, height: pixels.height,
          bitsPerComponent: 8, bytesPerRow: pixels.width * 4, space: colorSpace,
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        return true
      }
      guard drew else { throw PhoneRunnerObservationError.image }
      digest = Data(SHA256.hash(data: rgba))
      luma = rgba.withUnsafeBytes { raw -> [UInt8] in
        let bytes = raw.bindMemory(to: UInt8.self)
        let count = bytes.count / 4
        return [UInt8](unsafeUninitializedCapacity: count) {
          (buffer: inout UnsafeMutableBufferPointer<UInt8>, initialized: inout Int) in
          for i in 0..<count {
            let base = i * 4
            let red: Int = 77 * Int(bytes[base])
            let green: Int = 150 * Int(bytes[base + 1])
            let blue: Int = 29 * Int(bytes[base + 2])
            buffer[i] = UInt8((red + green + blue) >> 8)
          }
          initialized = count
        }
      }
    }

    /// How two same-sized frames differ: pixels changed by more than a faint shade, the largest
    /// change, and the box around them (in pixels). For diagnostics.
    func difference(_ other: Frame) -> String {
      guard pixelWidth == other.pixelWidth, pixelHeight == other.pixelHeight,
        luma.count == other.luma.count, !luma.isEmpty else {
        return "size \(pixelWidth)x\(pixelHeight) vs \(other.pixelWidth)x\(other.pixelHeight)"
      }
      var changed = 0, largest = 0
      var minX = pixelWidth, minY = pixelHeight, maxX = -1, maxY = -1
      for i in 0..<luma.count {
        let delta: Int = abs(Int(luma[i]) - Int(other.luma[i]))
        largest = max(largest, delta)
        guard delta > 24 else { continue }
        changed += 1
        let x = i % pixelWidth, y = i / pixelWidth
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
      }
      let box = changed == 0 ? "none" : "\(minX),\(minY)-\(maxX),\(maxY)"
      return "\(changed)/\(luma.count) pixels, largest \(largest), box \(box), size \(pixelWidth)x\(pixelHeight)"
    }

    /// The same screen to act on: the same app, direction and geometry, and either identical
    /// pixels or, on a screen-sized image, at most 1% of pixels changed by more than a faint
    /// shade. That lets a scroll indicator fade, the clock tick or a caret blink; a dialog, a
    /// banner, the keyboard or anything that moves the layout changes far more.
    func matches(_ other: Frame) -> Bool {
      guard appBundleID == other.appBundleID, orientation == other.orientation,
        pixelWidth == other.pixelWidth, pixelHeight == other.pixelHeight,
        imageOrientation == other.imageOrientation, scale == other.scale,
        pointSize == other.pointSize else { return false }
      if digest == other.digest { return true }
      let count = luma.count
      guard count >= Frame.tolerantPixels, other.luma.count == count else { return false }
      let allowed = count / 100
      var changed = 0
      return luma.withUnsafeBufferPointer { (mine: UnsafeBufferPointer<UInt8>) -> Bool in
        other.luma.withUnsafeBufferPointer { (theirs: UnsafeBufferPointer<UInt8>) -> Bool in
          for i in 0..<count {
            let delta = Int(mine[i]) - Int(theirs[i])
            if delta > 24 || delta < -24 {
              changed += 1
              if changed > allowed { return false }
            }
          }
          return true
        }
      }
    }
  }

  struct Record {
    let screen: String
    let frame: Frame
    let controllerBundleID: String?
    let hasRoutingPolicy: Bool
    let capturedAt: TimeInterval
  }

  private let now: () -> TimeInterval?
  private(set) var latest: Record?

  /// XCUIDevice reports the device's physical orientation: face up or down for a phone lying
  /// flat, and unknown on the simulator. The interface keeps its last orientation then, so those
  /// readings fall back to the screenshot's shape (portrait 1, landscape 3). A rotation between
  /// observation and action still changes the shape or the reading and is refused.
  static func interfaceOrientation(device: Int, pixelWidth: Int, pixelHeight: Int) -> Int {
    (1...4).contains(device) ? device : (pixelHeight >= pixelWidth ? 1 : 3)
  }

  init(now: @escaping () -> TimeInterval? = PhoneRunnerObservationClock.now) { self.now = now }

  func invalidate() { latest = nil }

  func remember(screen: String, frame: Frame, context: PhoneRunnerCallContext,
                capturedAt: TimeInterval) throws {
    latest = nil
    let current = now()
    try context.checkApp(frame.appBundleID, input: false, now: current)
    guard screen.utf8.count <= 96, let sequence = Int(screen.dropFirst()), sequence > 0, screen == "s\(sequence)",
      validAge(capturedAt, current: current) else { throw PhoneRunnerObservationError.stale }
    latest = Record(screen: screen, frame: frame, controllerBundleID: context.controllerBundleID,
      hasRoutingPolicy: context.hasRoutingPolicy, capturedAt: capturedAt)
  }

  /// consume=true retires the matching observation BEFORE any fallible checks;
  /// failure never puts it back. A stale token cannot consume a newer screen.
  @discardableResult
  func validate(screen: String, fresh: Frame, context: PhoneRunnerCallContext, consume: Bool) throws -> Record {
    guard let record = latest, record.screen == screen else { throw PhoneRunnerObservationError.stale }
    if consume { latest = nil }
    let current = now()
    try context.checkApp(fresh.appBundleID, input: true, now: current)
    guard record.hasRoutingPolicy, record.controllerBundleID == context.controllerBundleID else {
      throw PhoneRunnerObservationError.invalid
    }
    guard validAge(record.capturedAt, current: current) else { throw PhoneRunnerObservationError.stale }
    guard record.frame.appBundleID == fresh.appBundleID else { throw PhoneRunnerObservationError.app }
    guard (1...4).contains(fresh.orientation), record.frame.orientation == fresh.orientation else {
      throw PhoneRunnerObservationError.orientation
    }
    guard record.frame.matches(fresh) else {
      // Numbers only, for working out what moves on a real screen; never pixels or text.
      print("[phone-runner] frame changed: \(record.frame.difference(fresh))")
      throw PhoneRunnerObservationError.changed
    }
    return record
  }

  private func validAge(_ created: TimeInterval, current: TimeInterval?) -> Bool {
    guard created.isFinite, let current, current.isFinite else { return false }
    let age = current - created
    return age >= 0 && age < 120
  }
}
