import Foundation

// Consumes PetState.toMap(). Dart remains the only reducer of chat/approval
// signals. Native phone-task ownership affects lifetime, never the pet's mood.
struct PetOverlayTarget: Equatable {
  let host: String
  let sessionID: String

  init?(_ raw: Any?) {
    guard let value = raw as? [String: Any],
      let host = value["host"] as? String, !host.isEmpty, host.utf8.count <= 8_192,
      let session = value["sessionId"] as? String, !session.isEmpty,
      session.utf8.count <= 2_048 else { return nil }
    self.host = host
    sessionID = session
  }

  var arguments: [String: String] { ["host": host, "sessionId": sessionID] }
}

struct PetOverlayBubble: Equatable {
  let id: String
  let text: String
  let untilMilliseconds: Double

  init?(_ raw: Any?) {
    guard let value = raw as? [String: Any],
      let id = value["id"] as? String, !id.isEmpty,
      let text = value["text"] as? String, !text.isEmpty,
      let until = value["untilMs"] as? NSNumber,
      until.doubleValue.isFinite else { return nil }
    self.id = String(id.prefix(256))
    // Only the already masked, localized title. Ignore ask, choices, detail.
    self.text = String(text.prefix(160))
    untilMilliseconds = until.doubleValue
  }
}

enum PetOverlaySize: String {
  case small, medium, large
  var bodyHeight: Double {
    switch self {
    case .small: return 22
    case .medium: return 30
    case .large: return 40
    }
  }
}

struct PetOverlayState: Equatable {
  static let names: Set<String> = [
    "idle", "thinking", "working", "juggling", "sweeping", "notification",
    "attention", "error", "carrying", "sleeping", "waking",
  ]
  var state = "idle"
  var tier = 0
  var packID: String?
  var size = PetOverlaySize.medium
  var quiet = false
  var reduceMotion = false
  var canStop = false
  var active = false
  var bubble: PetOverlayBubble?
  var target: PetOverlayTarget?

  init(_ values: [String: Any] = [:]) {
    if let name = values["state"] as? String, Self.names.contains(name) { state = name }
    tier = min(3, max(0, values["tier"] as? Int ?? 0))
    if let id = values["packId"] as? String, id != "none", Self.safeAssetComponent(id) { packID = id }
    size = PetOverlaySize(rawValue: values["size"] as? String ?? "") ?? .medium
    quiet = values["quiet"] as? Bool == true
    reduceMotion = values["reduceMotion"] as? Bool == true
    canStop = values["canStop"] as? Bool == true
    active = values["active"] as? Bool == true
    bubble = PetOverlayBubble(values["bubble"])
    target = PetOverlayTarget(values["target"])
    // `foreground` comes from UIApplication. A stale push cannot open a
    // background confirmation or make a hidden source count as visible.
  }

  static func safeAssetComponent(_ name: String) -> Bool {
    guard !name.isEmpty, name.utf8.count <= 96 else { return false }
    return name.utf8.allSatisfy {
      ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
        ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
    }
  }

  func visibleBubble(at milliseconds: Double) -> String? {
    guard !quiet, let bubble, bubble.untilMilliseconds > milliseconds else { return nil }
    return bubble.text
  }
}

struct PetOverlayPhoneTask: Equatable {
  let id: Int
  let sessionID: String
  var line: String?
  var progress: Double?

  init(id: Int, sessionID: String, line: String?) {
    self.id = id
    self.sessionID = sessionID
    self.line = line.map { String($0.prefix(160)) }
  }
}

/// A temporary environment failure must not become a permanent admission
/// latch, or hide an asset/render failure that still needs attention. Recovery
/// changes readiness only; task pause, snooze and approval belong to the policy.
struct PetOverlayFailureState {
  private(set) var code: String?

  mutating func record(_ next: String) {
    if let code, !Self.isTransient(code), Self.isTransient(next) { return }
    code = next
  }

  mutating func clear() { code = nil }

  @discardableResult
  mutating func recover(protectedDataAvailable: Bool, audioMayPrepare: Bool) -> Bool {
    guard protectedDataAvailable, let code else { return false }
    switch code {
    case "overlay_device_locked": break
    case "overlay_audio_busy", "overlay_audio_failed", "overlay_audio_replaced",
      "overlay_audio_interrupted":
      guard audioMayPrepare else { return false }
    default: return false
    }
    self.code = nil
    return true
  }

  private static func isTransient(_ code: String) -> Bool {
    switch code {
    case "overlay_device_locked", "overlay_audio_busy", "overlay_audio_failed",
      "overlay_audio_replaced", "overlay_audio_interrupted": return true
    default: return false
    }
  }
}

/// Apple QA1749 requires a later user action before setActive after media reset.
/// Keep that gate independent of the displayed error: another failure or a
/// foreground/route/stop callback must not accidentally authorize activation.
struct PetOverlayAudioRecoveryState {
  var interrupted = false
  private(set) var requiresUserAction = false

  var blocker: String? {
    if requiresUserAction { return "overlay_media_reset" }
    return interrupted ? "overlay_audio_interrupted" : nil
  }

  mutating func mediaServicesReset() {
    interrupted = false
    requiresUserAction = true
  }

  mutating func retry(userInitiated: Bool) {
    interrupted = false
    if userInitiated { requiresUserAction = false }
  }
}

/// Independent of UIKit/AVKit so stale lifecycle callbacks and explicit
/// consent can be tested against the production policy on a Swift host.
struct PetOverlayPolicy {
  var enabled = false
  var alwaysShow = false
  var snoozed = false
  private(set) var task: PetOverlayPhoneTask?
  private(set) var paused = false
  private(set) var needsStopConfirmation = false
  private(set) var wantsRestore = false
  private var lastTaskID = -1

  // ADDENDUM-01: task-only unless alwaysShow was separately chosen. End has
  // no five-minute grace and a Dart `active` push cannot extend the lease.
  var hasDemand: Bool { enabled && !snoozed && (task != nil || alwaysShow) }
  // alwaysShow can use a real embedded source, but must not leave a temporary
  // native preview over unrelated Flutter screens after the phone task ends.
  var allowsTemporarySource: Bool { hasDemand && task != nil }

  mutating func requestRestore() { wantsRestore = true }

  @discardableResult
  mutating func consumeRestore() -> Bool {
    let requested = wantsRestore
    wantsRestore = false
    return requested
  }

  @discardableResult
  mutating func begin(id: Int, sessionID: String, line: String?) -> Bool {
    guard id >= 0, !sessionID.isEmpty else { return false }
    if task?.id == id {
      guard task?.sessionID == sessionID else { return false }
      task?.line = line.map { String($0.prefix(160)) }
      return true
    }
    guard id > lastTaskID else { return false }
    lastTaskID = id
    task = PetOverlayPhoneTask(id: id, sessionID: sessionID, line: line)
    paused = false
    needsStopConfirmation = false
    wantsRestore = false
    return true
  }

  mutating func update(id: Int, line: String?, progress: Double?) {
    guard task?.id == id else { return }
    task?.line = line.map { String($0.prefix(160)) }
    task?.progress = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
  }

  @discardableResult
  mutating func end(id: Int) -> Bool {
    guard task?.id == id else { return false }
    task = nil
    paused = false
    needsStopConfirmation = false
    wantsRestore = false
    return true
  }

  mutating func requestPause() -> Int? {
    guard let task, !paused else { return nil }
    paused = true
    needsStopConfirmation = true
    wantsRestore = true
    return task.id
  }

  @discardableResult
  mutating func confirmResume(id: Int) -> Bool {
    guard task?.id == id, paused, needsStopConfirmation else { return false }
    paused = false
    needsStopConfirmation = false
    wantsRestore = false
    return true
  }

  func mayConfirmStop(id: Int) -> Bool {
    task?.id == id && paused && needsStopConfirmation
  }
}
