import Foundation

/// What the share extension leaves for the app, in the App Group's container: one
/// folder per share, renamed into place once it's whole. Compiled into both targets.
enum ShareInbox {
  static let group = "group.io.github.ccch1mneyyy.dshgo"

  /// Brings the app forward; what it opens with is the folder, not this address.
  static let wakeUp = URL(string: "dshgo://ios-share-inbox")!

  static let manifestName = "manifest.json"

  /// A folder still being written, which the app leaves alone.
  static let unfinishedPrefix = "."

  static var folder: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
      .appendingPathComponent("share-inbox", isDirectory: true)
  }

  /// [name] in [folder], numbered if it's taken. The manifest's name is never free.
  static func unique(_ name: String, in folder: URL) -> URL {
    let stem = (name as NSString).deletingPathExtension
    let suffix = (name as NSString).pathExtension
    var candidate = name
    var count = 1
    while candidate == manifestName
      || FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path)
    {
      count += 1
      candidate = suffix.isEmpty ? "\(stem) \(count)" : "\(stem) \(count).\(suffix)"
    }
    return folder.appendingPathComponent(candidate)
  }

  struct Manifest: Codable {
    struct File: Codable {
      /// The file's name inside the share's folder, and as the sender named it.
      var name: String
      var mime: String?
    }

    struct Skipped: Codable {
      var name: String?

      /// `too_large`, `too_many` or `unreadable`, as `dsh/share` reports them.
      var reason: String
    }

    var text: String?
    var subject: String?
    var files: [File] = []
    var skipped: [Skipped] = []
  }
}
