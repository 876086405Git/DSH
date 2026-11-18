import Foundation
import CoreFoundation

// Fixed consent tables below are derived from Unicode 17/18 data.
// Unicode data copyright 2025 and 2026 Unicode, Inc.; Unicode-3.0.
// The full notice is shipped as the UnicodeData-LICENSE.txt app resource.

struct IOSPhoneOperationError: Error {
  let message: String
}

/// An immutable, completely validated plan shared by consent and execution.
/// Backend selection is absent from the tool arguments by construction.
struct IOSPhoneOperation {
  enum Method: String { case apps, open, screen, collect, tap, tapXY = "tap_xy", type, scroll, key }
  let method: Method
  let parameters: [String: Any]

  init(_ request: IOSPhoneRequest) throws {
    guard request.action.kind == "runner-call", let name = request.action.method,
      let method = Method(rawValue: name), let raw = request.action.params,
      raw.utf8.count <= 16_384,
      let parameters = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
      throw IOSPhoneOperationError(message: "手机动作参数无效，没有执行。")
    }
    self.method = method; self.parameters = parameters
    let allowed: Set<String>
    switch method {
    case .apps:
      allowed = ["query"]; try optionalString("query", limit: 256)
    case .open:
      allowed = ["app", "background"]
      _ = try requiredString("app", limit: 256); try optionalBool("background")
    case .screen:
      allowed = ["image", "detail", "background"]
      try optionalBool("image"); try optionalBool("detail"); try optionalBool("background")
    case .tap:
      allowed = ["screen", "id", "long"]
      _ = try requiredString("screen", limit: 96); _ = try integer("id", in: 1...400); try optionalBool("long")
    case .tapXY:
      allowed = ["observation", "x", "y"]
      _ = try requiredString("observation", limit: 96)
      _ = try integer("x", in: 0...32767); _ = try integer("y", in: 0...32767)
    case .type:
      allowed = ["screen", "id", "text", "submit"]
      _ = try requiredString("screen", limit: 96); _ = try integer("id", in: 1...400)
      let text = try requiredString("text", limit: 4096)
      // Both native ASCII and XCTest typeText can turn LF/TAB into keys. A
      // literal text argument cannot authorize Enter or move focus implicitly.
      guard !text.unicodeScalars.contains(where: Self.isConsentControl) else {
        throw IOSPhoneOperationError(message: "输入含不支持的控制或不可见字符，没有派发任何按键。")
      }
      if text.utf8.allSatisfy({ $0 < 128 }), text.utf8.count > 1024 {
        throw IOSPhoneOperationError(message: "ASCII 输入超过 1024 字节，没有截断或分批输入。")
      }
      // Short all-digit strings commonly represent OTP/PIN/CVV. Refuse this
      // conservative class even if OCR failed to recognize the nearby label.
      let numeric = text.unicodeScalars.filter { !Self.isNumericSeparator($0) }
      if (3...8).contains(numeric.count), numeric.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
        throw IOSPhoneOperationError(message: "这段输入可能是验证码或安全码，请用 handoff 交给用户。")
      }
      try optionalBool("submit")
    case .scroll:
      allowed = ["screen", "id", "direction"]
      _ = try requiredString("screen", limit: 96)
      if parameters["id"] != nil { _ = try integer("id", in: 1...400) }
      guard ["up", "down", "left", "right"].contains(try requiredString("direction", limit: 16)) else {
        throw IOSPhoneOperationError(message: "滚动方向无效。")
      }
    case .collect:
      allowed = ["screen", "list", "max_pages", "until"]
      _ = try requiredString("screen", limit: 96); _ = try integer("list", in: 1...400)
      if parameters["max_pages"] != nil { _ = try integer("max_pages", in: 1...30) }
      try optionalString("until", limit: 1024)
    case .key:
      allowed = ["key", "screen"]; try optionalString("screen", limit: 96)
      guard ["home", "back", "notifications"].contains(try requiredString("key", limit: 32)) else {
        throw IOSPhoneOperationError(message: "iOS 只支持 back、home、notifications；要切应用请用 open。")
      }
    }
    guard Set(parameters.keys).isSubset(of: allowed), parameters["background"] as? Bool != true else {
      throw IOSPhoneOperationError(message: "参数含不支持的选项；iOS 不提供隐藏后台屏幕操控。")
    }
  }

  var needsTarget: Bool { ![.apps, .open].contains(method) }
  var requiresObservation: Bool { ![.apps, .open, .screen].contains(method) }
  var wantsImage: Bool { parameters["image"] as? Bool == true }
  var detail: Bool { parameters["detail"] as? Bool == true }
  var screen: String? { (parameters["screen"] ?? parameters["observation"]) as? String }
  var text: String? { parameters["text"] as? String }
  var usesClipboard: Bool { method == .type && text?.utf8.contains(where: { $0 >= 128 }) == true }
  var submits: Bool { parameters["submit"] as? Bool == true }
  var pages: Int { parameters["max_pages"] as? Int ?? 10 }

  /// Only the conservative numeric-code heuristic ignores these separators.
  /// The immutable execution text is never normalized or rewritten.
  private static func isNumericSeparator(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.value {
    case 0x002d, 0x2010, 0x2011, 0x2013, 0x2212: return true
    default: return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
  }

  /// Identifiers are quoted and bounded; input has a complete visible rendering.
  /// Clipboard contents and pairing data are never consulted to build this text.
  func consentDescription(targetLabel: String?) -> String {
    let target = targetLabel.map { "\n上次观察中的目标：\(Self.quotedDisplay($0))" } ?? ""
    switch method {
    case .apps: return "读取可启动应用的名称和包名，并发送给本次会话。" + ((parameters["query"] as? String).map { "\n筛选：\(Self.quotedDisplay($0))" } ?? "")
    case .open: return "打开应用：\(Self.quotedDisplay(parameters["app"] as? String ?? ""))。\n可能建立屏幕控制通道并读取打开后的屏幕；系统接受启动不代表应用已到前台。"
    case .screen: return "建立本次任务的屏幕控制通道（系统可能显示共享提示），读取一张屏幕并在本机识别文字。识别出的文字" + (wantsImage ? "和标号截图" : "") + "将发送给本次会话。"
    case .tap: return (parameters["long"] as? Bool == true ? "长按" : "点击") + "屏幕 \(Self.quotedDisplay(screen ?? "")) 的编号 \(parameters["id"] as? Int ?? 0)。" + target
    case .tapXY: return "点击截图 \(Self.quotedDisplay(screen ?? "")) 中的像素坐标 (\(parameters["x"] as? Int ?? 0), \(parameters["y"] as? Int ?? 0))。"
    case .type:
      let displayedText = Self.quotedDisplay(text ?? "", scalarLimit: nil)
      var message = "在屏幕 \(Self.quotedDisplay(screen ?? "")) 的编号 \(parameters["id"] as? Int ?? 0) 输入以下全文，并替换原内容：\n\(displayedText)" + target
      message += "\n\n显示说明：连续空白显示为一个空格；反斜线转义表示原始特殊字符。实际输入保留原文。"
      if usesClipboard {
        message += "\n\nCoreDevice 路线输入非 ASCII 文字时会临时使用剪贴板：原内容只在本 App 内存保存，不发送给模型。请在粘贴后回到 DSH Go 恢复原内容；若本 App 在恢复前终止，保存内容会丢失。恢复内容仅在此设备可用。"
        message += "\nCoreDevice 的后台粘贴无法核实来源，可能粘贴其他内容；这次只返回固定状态，不回传粘贴后的读屏文字或图片，请你核对。"
      }
      if submits {
        if usesClipboard {
          message += "\n\n还请求按回车／发送。CoreDevice 的剪贴板路径不能核实完整输入文字的来源，不会自动派发回车／发送按键，请你核对完成；XCTest 路线仍须核对完整焦点值后才可能继续。"
        } else {
          message += "\n\n还请求按回车／发送。只有新的读屏能核对完整输入文字时才继续；核对不了就交给你。"
        }
      }
      return message
    case .scroll:
      return "按 \(parameters["direction"] as? String ?? "down") 方向滚动一次，再读取新屏幕。CoreDevice 的编号表示 OCR 文字框，不能证明它是一个列表。" + target
    case .collect:
      return "围绕编号 \(parameters["list"] as? Int ?? 0) 的横向位置，最多读取 \(pages) 页并向下滚动 \(max(0, pages - 1)) 次；收集文字发送给本次会话。滚动会改变界面。" + target
    case .key:
      return "执行一次系统操作：\(parameters["key"] as? String ?? "")，再读取新屏幕。"
    }
  }

  private func requiredString(_ key: String, limit: Int) throws -> String {
    guard let value = parameters[key] as? String, !value.isEmpty, value.utf8.count <= limit,
      !value.contains("\0") else { throw IOSPhoneOperationError(message: "参数 \(key) 无效。") }
    // Non-text strings also reach native consent. They must not inject lines,
    // directional controls or paragraph separators into trusted explanation.
    // The text branch uses the same predicate and preserves its specific error.
    guard key == "text" || !value.unicodeScalars.contains(where: Self.isConsentControl) else {
      throw IOSPhoneOperationError(message: "参数 \(key) 无效。")
    }
    return value
  }

  private static func isConsentControl(_ scalar: UnicodeScalar) -> Bool {
    let value = scalar.value
    if isInvisibleConsentScalar(scalar) { return true }
    return value < 0x20 || (0x7f...0x9f).contains(value)
      || [0x061c, 0x200e, 0x200f, 0x2028, 0x2029].contains(value)
      || (0x202a...0x202e).contains(value) || (0x2066...0x2069).contains(value)
  }

  /// Refuse format controls and the explicitly listed blank/annotation ranges
  /// in model arguments. Do not silently remove them from execution values.
  private static func isInvisibleConsentScalar(_ scalar: UnicodeScalar) -> Bool {
    if scalar.properties.generalCategory == .format { return true }
    // Fixed Unicode 17 Cf table plus ADD08's extra ranges: older system
    // Unicode tables must not turn an assigned format scalar into plain text.
    switch scalar.value {
    case 0x00ad, 0x0600...0x0605, 0x061c, 0x06dd: return true
    case 0x070f, 0x0890...0x0891, 0x08e2, 0x180e: return true
    case 0x200b...0x200f, 0x202a...0x202e, 0x2060...0x2064, 0x2066...0x206f: return true
    case 0x2800, 0x3164, 0xfeff, 0xfff9...0xfffb: return true
    case 0x110bd, 0x110cd, 0x13430...0x1343f, 0x1bca0...0x1bca3: return true
    case 0x1d173...0x1d17a, 0xe0000...0xe007f: return true
    default: return false
    }
  }

  private static func isConsentQuotation(_ scalar: UnicodeScalar) -> Bool {
    if scalar.properties.isQuotationMark { return true }
    // Unicode 17/18 quotation marks, quote-only confusables and ornaments.
    // This is a finite display rule, not a proof about every font or glyph.
    switch scalar.value {
    case 0x0022, 0x0027, 0x0060, 0x00ab: return true
    case 0x00b4, 0x00bb, 0x02b9...0x02be, 0x02c8: return true
    case 0x02ca...0x02cb, 0x02dd, 0x02ee, 0x02f4: return true
    case 0x02f6, 0x0374, 0x0384, 0x055a: return true
    case 0x055d, 0x05d9, 0x05f2...0x05f4, 0x07f4...0x07f5: return true
    case 0x144a, 0x16cc, 0x1cd3, 0x1fbd: return true
    case 0x1fbf, 0x1fef, 0x1ffd...0x1ffe, 0x2018...0x201f: return true
    case 0x2032...0x2037, 0x2039...0x203a, 0x2057, 0x275b...0x2760: return true
    case 0x276e...0x276f, 0x2e42, 0x3003, 0x300c...0x300f: return true
    case 0x301d...0x301f, 0xa78c, 0xfe41...0xfe44, 0xff02: return true
    case 0xff07, 0xff40, 0xff62...0xff63, 0x16f51...0x16f52: return true
    case 0x1f676...0x1f678: return true
    // Retain the 17 set and add the four new quote-only mappings in 18.
    case 0x055b, 0x2cff, 0xa78b, 0x1e94b: return true
    default: return false
    }
  }

  private static func isDefaultIgnorableForDisplay(_ scalar: UnicodeScalar) -> Bool {
    if scalar.properties.isDefaultIgnorableCodePoint { return true }
    switch scalar.value {
    case 0x00ad, 0x034f, 0x061c, 0x115f...0x1160: return true
    case 0x17b4...0x17b5, 0x180b...0x180f, 0x200b...0x200f, 0x202a...0x202e: return true
    case 0x2060...0x206f, 0x3164, 0xfe00...0xfe0f, 0xfeff: return true
    case 0xffa0, 0xfff0...0xfff8, 0x1bca0...0x1bca3, 0x1d173...0x1d17a: return true
    case 0xe0000...0xe0fff: return true
    default: return false
    }
  }

  private static func visibleScalarEscape(_ scalar: UnicodeScalar) -> String {
    let digits = String(scalar.value, radix: 16, uppercase: true)
    if scalar.value <= 0xffff {
      return "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
    }
    return "\\u{" + digits + "}"
  }

  /// Presentation only: the immutable plan retains the full validated value.
  /// OCR may still supply rejected controls: escape them instead of rendering
  /// their layout effects. Ordinary Unicode whitespace is folded for display.
  /// The scalar budget applies to identifiers only; input text is never cut.
  private static func quotedDisplay(_ value: String, scalarLimit: Int? = 80) -> String {
    let scalars = value.unicodeScalars
    var rendered = "\""
    var previousWasWhitespace = false
    for scalar in scalars.prefix(scalarLimit ?? scalars.count) {
      if isConsentControl(scalar) || isDefaultIgnorableForDisplay(scalar) {
        rendered += visibleScalarEscape(scalar)
        previousWasWhitespace = false
        continue
      }
      if scalar.properties.isWhitespace {
        if !previousWasWhitespace { rendered += " " }
        previousWasWhitespace = true
        continue
      }
      previousWasWhitespace = false
      switch scalar.value {
      case 0x22, 0x27, 0x60, 0x5c: rendered += "\\" + String(scalar)
      default:
        if isConsentQuotation(scalar) {
          rendered += visibleScalarEscape(scalar)
        } else {
          rendered += String(scalar)
        }
      }
    }
    if let scalarLimit, scalars.count > scalarLimit { rendered += "…" }
    return rendered + "\""
  }
  private func optionalString(_ key: String, limit: Int) throws {
    if parameters[key] != nil { _ = try requiredString(key, limit: limit) }
  }
  private func optionalBool(_ key: String) throws {
    guard let value = parameters[key] else { return }
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      throw IOSPhoneOperationError(message: "参数 \(key) 必须是布尔值。")
    }
  }
  private func integer(_ key: String, in range: ClosedRange<Int>) throws -> Int {
    guard let number = parameters[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
      number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else {
      throw IOSPhoneOperationError(message: "参数 \(key) 必须是范围内的整数。")
    }
    return number.intValue
  }
}
