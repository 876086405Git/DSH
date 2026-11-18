import UIKit
import UniformTypeIdentifiers

// The share sheet's target, after android/.../share/ShareActivity.kt: no sheet of its
// own, it copies what was shared into the inbox and brings the app forward. The app
// finds the inbox again whenever it comes to the front, so a share isn't lost if that
// last step doesn't happen.

@objc(ShareViewController)
final class ShareViewController: UIViewController {
  /// The same limits as SharePlugin.kt.
  private static let maxItems = 9
  private static let maxFileBytes: Int64 = 200 * 1024 * 1024
  private static let maxTotalBytes: Int64 = 400 * 1024 * 1024
  private static let maxTextCharacters = 200_000

  private let work = DispatchQueue(label: "dsh.share.extension")
  private var started = false
  private var manifest = ShareInbox.Manifest()
  private var texts: [String] = []
  private var total: Int64 = 0

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }
    started = true
    let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
    guard let inbox = ShareInbox.folder else { return finish(open: false) }
    collect(items, in: inbox) { self.finish(open: $0) }
  }

  func collect(_ items: [NSExtensionItem], in inbox: URL, then done: @escaping (Bool) -> Void) {
    work.async { [self] in
      let unfinished = inbox.appendingPathComponent(ShareInbox.unfinishedPrefix + UUID().uuidString, isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
      } catch {
        return done(false)
      }
      manifest.subject = Self.trimmed(items.first?.attributedTitle?.string)
      items.compactMap { Self.trimmed($0.attributedContentText?.string) }.forEach(addText)
      read(items.flatMap { $0.attachments ?? [] }[...], into: unfinished) { [self] in
        seal(unfinished, in: inbox, then: done)
      }
    }
  }

  /// One at a time, so the items keep their order and the limits hold.
  private func read(_ providers: ArraySlice<NSItemProvider>, into folder: URL, then done: @escaping () -> Void) {
    guard let provider = providers.first else { return done() }
    let rest = providers.dropFirst()
    let next = { [self] in
      work.async { self.read(rest, into: folder, then: done) }
    }
    if manifest.files.count >= Self.maxItems {
      manifest.skipped.append(.init(name: provider.suggestedName, reason: "too_many"))
      return next()
    }
    if let type = Self.textType(provider) {
      provider.loadItem(forTypeIdentifier: type, options: nil) { [self] value, _ in
        work.async {
          self.take(value, from: provider, into: folder)
          next()
        }
      }
      return
    }
    guard let type = Self.fileType(provider) else {
      manifest.skipped.append(.init(name: provider.suggestedName, reason: "unreadable"))
      return next()
    }
    readFile(provider, type: type, into: folder, then: next)
  }

  /// A web address or plain text; a file offered under those types is still a file.
  private func take(_ value: NSSecureCoding?, from provider: NSItemProvider, into folder: URL) {
    switch value {
    case let url as URL where url.isFileURL:
      copy(url, name: provider.suggestedName, type: nil, into: folder)
    case let url as URL: addText(url.absoluteString)
    case let text as String: addText(text)
    case let data as Data:
      if let text = String(data: data, encoding: .utf8) {
        addText(text)
      } else {
        manifest.skipped.append(.init(name: provider.suggestedName, reason: "unreadable"))
      }
    default: manifest.skipped.append(.init(name: provider.suggestedName, reason: "unreadable"))
    }
  }

  private func readFile(
    _ provider: NSItemProvider,
    type: String,
    into folder: URL,
    then next: @escaping () -> Void
  ) {
    // The file is only there during this call: copied here, not on the work queue.
    provider.loadFileRepresentation(forTypeIdentifier: type) { [self] url, _ in
      work.sync {
        if let url {
          copy(url, name: provider.suggestedName, type: type, into: folder)
        } else {
          manifest.skipped.append(.init(name: provider.suggestedName, reason: "unreadable"))
        }
      }
      next()
    }
  }

  private func copy(_ url: URL, name suggested: String?, type: String?, into folder: URL) {
    let manager = FileManager.default
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let name = Self.fileName(url, suggested: suggested, type: type)
    guard let size = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? Int64 else {
      return manifest.skipped.append(.init(name: name, reason: "unreadable"))
    }
    guard size <= Self.maxFileBytes, total + size <= Self.maxTotalBytes else {
      return manifest.skipped.append(.init(name: name, reason: "too_large"))
    }
    let target = ShareInbox.unique(name, in: folder)
    do {
      try manager.copyItem(at: url, to: target)
      total += size
      let content = type.flatMap { UTType($0) } ?? UTType(filenameExtension: url.pathExtension)
      manifest.files.append(.init(name: target.lastPathComponent, mime: content?.preferredMIMEType))
    } catch {
      manifest.skipped.append(.init(name: name, reason: "unreadable"))
    }
  }

  private func addText(_ text: String) {
    guard !text.isEmpty, !texts.contains(text) else { return }
    texts.append(text)
  }

  private func seal(_ unfinished: URL, in inbox: URL, then done: (Bool) -> Void) {
    manifest.text = texts.isEmpty ? nil : String(texts.joined(separator: "\n\n").prefix(Self.maxTextCharacters))
    let finished = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      let data = try JSONEncoder().encode(manifest)
      try data.write(to: unfinished.appendingPathComponent(ShareInbox.manifestName), options: .atomic)
      try FileManager.default.moveItem(at: unfinished, to: finished)
      done(true)
    } catch {
      try? FileManager.default.removeItem(at: unfinished)
      done(false)
    }
  }

  private func finish(open: Bool) {
    DispatchQueue.main.async { [self] in
      guard open else { return complete() }
      bringAppForward { self.complete() }
    }
  }

  /// A share extension has no API for this and must build with extension-safe APIs
  /// only, so UIApplication's method is found on the responder chain at run time. If
  /// it isn't there or does nothing, the share still waits in the inbox.
  private func bringAppForward(then done: @escaping () -> Void) {
    typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, @convention(block) (Bool) -> Void) -> Void
    let selector = NSSelectorFromString("openURL:options:completionHandler:")
    var responder: UIResponder? = self
    while let current = responder, !current.responds(to: selector) {
      responder = current.next
    }
    guard let application = responder else { return done() }
    let open = unsafeBitCast(application.method(for: selector), to: Open.self)
    open(application, selector, ShareInbox.wakeUp as NSURL, NSDictionary()) { _ in done() }
  }

  private func complete() {
    extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
  }

  private static func trimmed(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return text
  }

  /// The type to read as text, for an item with no file of its own to offer.
  private static func textType(_ provider: NSItemProvider) -> String? {
    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) { return UTType.url.identifier }
    let files = provider.registeredTypeIdentifiers.compactMap { UTType($0) }.filter { !$0.conforms(to: .text) }
    if files.isEmpty, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      return UTType.plainText.identifier
    }
    return nil
  }

  private static func fileType(_ provider: NSItemProvider) -> String? {
    provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true }
      ?? provider.registeredTypeIdentifiers.first
  }

  /// The sender's name without any folders, with the extension its type calls for.
  private static func fileName(_ url: URL, suggested: String?, type: String?) -> String {
    let own = url.lastPathComponent
    let base = suggested.map { ($0 as NSString).lastPathComponent } ?? own
    let name = base.isEmpty ? "file" : base
    guard (name as NSString).pathExtension.isEmpty else { return name }
    let fallback = url.pathExtension.isEmpty
      ? type.flatMap { UTType($0)?.preferredFilenameExtension } : url.pathExtension
    return fallback.map { "\(name).\($0)" } ?? name
  }
}
