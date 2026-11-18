import Foundation
import Security

/// The widget receives only this bounded display snapshot, never a host,
/// conversation ID, token or pairing record. Missing fields preserve the last
/// displayed line; explicit null clears it, matching the Dart channel contract.
struct CompanionSnapshot: Codable, Equatable {
  var name = ""
  var status = ""
  var activity = "idle"
  var statusAsleep = ""
  var statusWaiting = ""
  var line = ""
  var bond = 0
  var untilMs: Double?
  var saidAt: Double?

  mutating func update(_ values: [String: Any]) {
    func text(_ key: String, _ old: String, limit: Int = 256) -> String {
      guard let value = values[key] else { return old }
      if value is NSNull { return "" }
      guard let string = value as? String, !string.contains("\0") else { return old }
      return String(string.prefix(limit))
    }
    name = text("name", name, limit: 80)
    status = text("status", status)
    activity = text("activity", activity, limit: 32)
    statusAsleep = text("statusAsleep", statusAsleep)
    statusWaiting = text("statusWaiting", statusWaiting)
    line = text("line", line, limit: 512)
    if let value = values["bond"] {
      bond = (value as? Int).map { min(3, max(0, $0)) } ?? 0
    }
    for key in ["untilMs", "saidAt"] where values[key] != nil {
      let value = (values[key] as? NSNumber)?.doubleValue
      let time = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
      if key == "untilMs" { untilMs = time } else { saidAt = time }
    }
  }

  func displayStatus(at date: Date) -> String {
    if let untilMs, date.timeIntervalSince1970 * 1000 >= untilMs {
      return statusWaiting
    }
    return status
  }
}

/// A dedicated shared Keychain group works for both development and release
/// signing, without granting the widget access to the app's credential group.
enum CompanionSnapshotStore {
  static let kind = "DSHCompanionWidget"
  private static let service = "dsh.companion.widget.snapshot.v1"

  private static func query() -> [String: Any]? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "DSHCompanionAccessGroup") as? String,
      !group.isEmpty, !group.contains("$(") else { return nil }
    return [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: "display",
      kSecAttrAccessGroup as String: group]
  }

  static func load() -> CompanionSnapshot {
    guard var request = query() else { return CompanionSnapshot() }
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data, data.count <= 16_384,
      let value = try? JSONDecoder().decode(CompanionSnapshot.self, from: data) else { return CompanionSnapshot() }
    return value
  }

  static func save(_ value: CompanionSnapshot) -> OSStatus {
    guard var request = query(), let data = try? JSONEncoder().encode(value), data.count <= 16_384 else {
      return errSecParam
    }
    let attributes: [String: Any] = [kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
    guard status == errSecItemNotFound else { return status }
    request.merge(attributes) { _, new in new }
    return SecItemAdd(request as CFDictionary, nil)
  }
}
