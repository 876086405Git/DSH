import ActivityKit
import AppIntents
import Foundation
import Security

// The pet's live activity on the lock screen and in the Dynamic Island. Compiled into
// both Runner (Runner/IOSLiveActivity.swift tells ActivityKit what to show) and the
// widget extension (LiveActivityWidget.swift draws it).

/// Everything that changes is in the content state, nothing in the attributes: one
/// activity follows the pet from one conversation to the next while the app is in the
/// background, where iOS won't let it start another.
@available(iOS 16.2, *)
struct DSHLiveAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    /// running, waiting, done or failed: `LiveKind` in lib/notify/live_activity.dart.
    var kind: String
    /// The pet state its picture is from.
    var mood: String
    /// The conversation's title, masked. Only the Dynamic Island shows it: the lock
    /// screen is read by whoever holds the phone.
    var title: String
    /// What is going on, in words fit for the lock screen.
    var text: String
    /// A word or two: 待确认, 完成.
    var chip: String
    /// When the run started, for the clock; with [until], how long it took.
    var since: Date?
    var until: Date?
    /// The conversation a tap opens.
    var host: String
    var session: String
    var event: String?
    /// The pet's still in [LiveArtStore]; nil without a pet.
    var art: String?
    var pixelArt: Bool
    /// The theme's accent, ARGB, on light and on dark surroundings.
    var tint: UInt32
    var tintDark: UInt32
    /// 停止 can work: the conversation is on the host the app is on.
    var canStop: Bool
    /// Words the extension can't look up itself, in the app's language.
    var stopLabel: String
    var staleLabel: String

    var running: Bool { kind == "running" || kind == "waiting" }

    /// Opens the conversation, like a tap on its notification (NotifyTaps).
    var url: URL? {
      var parts = URLComponents()
      parts.scheme = "dshgo"
      parts.host = "live"
      parts.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "sessionId", value: session)]
        + (event.map { [URLQueryItem(name: "eventId", value: $0)] } ?? [])
      return parts.url
    }
  }
}

/// The pet's current still. The extension can read neither the app's assets nor its
/// files, so the app draws the picture and leaves it in the companion widget's Keychain
/// group: unlike an App Group it needs nothing more in a provisioning profile, and it
/// stays readable on the lock screen after the first unlock.
enum LiveArtStore {
  static let maxBytes = 262_144
  private static let service = "dsh.live.art.v1"

  private struct Stored: Codable {
    let key: String
    let png: Data
  }

  private static func query() -> [String: Any]? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "DSHCompanionAccessGroup") as? String,
      !group.isEmpty, !group.contains("$(") else { return nil }
    return [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: "pet",
      kSecAttrAccessGroup as String: group]
  }

  /// The still saved under [key]; nil when another one has taken its place.
  static func load(_ key: String) -> Data? {
    guard var request = query() else { return nil }
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data, data.count <= maxBytes + 4096,
      let stored = try? PropertyListDecoder().decode(Stored.self, from: data), stored.key == key
    else { return nil }
    return stored.png
  }

  @discardableResult
  static func save(key: String, png: Data) -> OSStatus {
    guard png.count <= maxBytes, var request = query() else { return errSecParam }
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    guard let data = try? encoder.encode(Stored(key: key, png: png)) else { return errSecParam }
    let attributes: [String: Any] = [kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
    guard status == errSecItemNotFound else { return status }
    request.merge(attributes) { _, new in new }
    return SecItemAdd(request as CFDictionary, nil)
  }
}

/// 停止 on the live activity. iOS runs it in the app's process, which hands it to Dart:
/// the floating pet's stop, with the same checks (the pet's conversation, on the host
/// the app is on).
@available(iOS 17.0, *)
struct DSHLiveStopIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Stop"
  static var isDiscoverable: Bool = false

  @Parameter(title: "Host")
  var host: String

  @Parameter(title: "Conversation")
  var session: String

  /// Set by the app; nil in the widget extension, where this never runs.
  static var handler: ((String, String) async -> Void)?

  init() {}

  init(host: String, session: String) {
    self.host = host
    self.session = session
  }

  func perform() async throws -> some IntentResult {
    await Self.handler?(host, session)
    return .result()
  }
}
