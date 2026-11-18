import AppIntents
import Foundation

/// Where a Siri or Shortcuts action hands over to the app. One can run as the system launches
/// the app, before the plugin exists, so it waits here. Main thread only.
enum SystemEntries {
  private static var held: [[String: String]] = []
  private static var deliver: (([String: String]) -> Void)?

  static func attach(_ handler: @escaping ([String: String]) -> Void) {
    deliver = handler
    held.forEach(handler)
    held.removeAll()
  }

  static func send(_ entry: [String: String]) {
    if let deliver {
      deliver(entry)
    } else {
      held.append(entry)
    }
  }
}

// These open the app and stop at the composer, like a share does. Sending stays the user's
// tap, so a shortcut someone else wrote can't start a turn on its own.

@available(iOS 16.0, *)
struct AskDshIntent: AppIntent {
  static var title: LocalizedStringResource = "Ask DSH Go"
  static var description = IntentDescription("Opens a new conversation with this message in the composer.")
  static var openAppWhenRun = true

  @Parameter(title: "Message", requestValueDialog: "What would you like to ask?")
  var text: String

  static var parameterSummary: some ParameterSummary {
    Summary("Ask DSH Go \(\.$text)")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    SystemEntries.send(["kind": "new", "text": text])
    return .result()
  }
}

@available(iOS 16.0, *)
struct VoiceInputIntent: AppIntent {
  static var title: LocalizedStringResource = "Voice Input"
  static var description = IntentDescription("Opens a new conversation and starts dictating.")
  static var openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    SystemEntries.send(["kind": "voice"])
    return .result()
  }
}

@available(iOS 16.0, *)
struct NewChatIntent: AppIntent {
  static var title: LocalizedStringResource = "New Conversation"
  static var description = IntentDescription("Opens a new conversation.")
  static var openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    SystemEntries.send(["kind": "new"])
    return .result()
  }
}

/// What Siri and the Shortcuts app offer without any setup. A free-text message can't be part
/// of a spoken phrase, so Siri asks for it after "Ask DSH Go".
@available(iOS 16.0, *)
struct DshShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AskDshIntent(),
      phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) something"],
      shortTitle: "Ask",
      systemImageName: "bubble.left")
    AppShortcut(
      intent: VoiceInputIntent(),
      phrases: ["Talk to \(.applicationName)", "Voice input in \(.applicationName)"],
      shortTitle: "Voice Input",
      systemImageName: "mic")
    AppShortcut(
      intent: NewChatIntent(),
      phrases: ["New conversation in \(.applicationName)"],
      shortTitle: "New Conversation",
      systemImageName: "square.and.pencil")
  }
}
