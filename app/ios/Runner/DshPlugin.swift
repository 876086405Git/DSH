import Flutter
import PDFKit
import Photos
import QuickLook
import UIKit
import UserNotifications

// The app's own platform channels on iOS. The Android side of each is under
// android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/. A channel nobody
// registers reaches Dart as MissingPluginException, which already means "not on
// this platform": `dsh/runtime` (no local engine), `dsh/update`, `dsh/phone`,
// `dsh/pet_overlay` and the rest stay that way until there is something to say.

final class DshPlugin: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
  private static var instance: DshPlugin?

  private let links: LinksChannel
  private let shortcuts: ShortcutsChannel
  private let shares: ShareChannel
  private let keep: [AnyObject]

  static func register(with registrar: any FlutterPluginRegistrar) {
    let plugin = DshPlugin(registrar: registrar)
    instance = plugin
    registrar.addSceneDelegate(plugin)
  }

  private init(registrar: any FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    links = LinksChannel(messenger: messenger)
    shortcuts = ShortcutsChannel(messenger: messenger)
    shares = ShareChannel(messenger: messenger)
    keep = [
      GuestChannel(messenger: messenger, kernel: NativeGuestKernelAccess.shared, support: Result {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true)
      }),
      AppChannel(messenger: messenger),
      FilesChannel(messenger: messenger),
      MediaChannel(messenger: messenger),
      NotifyChannel(messenger: messenger),
      VoiceChannel(messenger: messenger),
      IOSSpeechChannel(messenger: messenger),
      IOSCompanionWidget(messenger: messenger),
      LauncherIconChannel(messenger: messenger),
      PerformanceChannel(messenger: messenger),
      DiagnosticsChannel(messenger: messenger),
      UsageChannel(messenger: messenger),
      LaunchChannel(messenger: messenger),
      StartupChannel(messenger: messenger),
      LaunchClipChannel(messenger: messenger, textures: registrar.textures()),
      NativeFilesChannel(messenger: messenger),
      NativeMediaChannel(messenger: messenger),
      IslandsChannel(registrar: registrar),
      // In a build without the engine, the runtime controller subscribes before it learns
      // there is none, and activating a stream with no handler reports an error to Flutter.
      EngineChannel.isBundled
        ? EngineChannel(messenger: messenger) as AnyObject
        : SilentEvents(name: "dsh/runtime/events", messenger: messenger) as AnyObject,
    ]
    super.init()
  }

  // Optional requirements, called by selector: spelled out, since a Swift name that
  // missed one would compile and simply never be called.
  @objc(scene:willConnectToSession:options:)
  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    connectionOptions?.urlContexts.forEach { open($0.url) }
    if let item = connectionOptions?.shortcutItem { _ = shortcuts.perform(item) }
    return false
  }

  @objc(scene:openURLContexts:)
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    URLContexts.forEach { open($0.url) }
    return !URLContexts.isEmpty
  }

  /// A share left while the app was away; the wake-up address isn't always what brought it back.
  @objc(sceneWillEnterForeground:)
  func sceneWillEnterForeground(_ scene: UIScene) {
    shares.drain()
  }

  @objc(windowScene:performActionForShortcutItem:completionHandler:)
  func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) -> Bool {
    let handled = shortcuts.perform(shortcutItem)
    if handled { completionHandler(true) }
    return handled
  }

  private func open(_ url: URL) {
    if url == ShareInbox.wakeUp {
      shares.drain()
    } else if let tap = IOSLiveActivity.tap(url) {
      NotifyTaps.shared.deliver(tap)
    } else {
      links.open(url)
    }
  }
}

/// An event channel that never sends anything.
private final class SilentEvents: NSObject, FlutterStreamHandler {
  private let channel: FlutterEventChannel

  init(name: String, messenger: any FlutterBinaryMessenger) {
    channel = FlutterEventChannel(name: name, binaryMessenger: messenger)
    super.init()
    channel.setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { nil }

  func onCancel(withArguments arguments: Any?) -> FlutterError? { nil }
}

func arguments(_ call: FlutterMethodCall) -> [String: Any] {
  call.arguments as? [String: Any] ?? [:]
}

func onMain(_ work: @escaping () -> Void) {
  DispatchQueue.main.async(execute: work)
}

// MARK: - dsh/app

private final class AppChannel {
  private let channel: FlutterMethodChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/app", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getTimeZoneId": result(TimeZone.current.identifier)
      // iOS doesn't let an app bring itself forward.
      case "bringToFront": result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}

// MARK: - dsh/links

/// Incoming `dshgo://` links and files opened with the app. Files are copied into
/// the cache on one serial queue, so links reach Dart in the order they arrived even
/// when a large file comes before a small one.
private final class LinksChannel {
  private let channel: FlutterMethodChannel
  private let copies = DispatchQueue(label: "dsh.links")
  private var ready = false
  private var held: [[String: String]] = []

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/links", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "ready", let self else { return result(FlutterMethodNotImplemented) }
      self.ready = true
      self.held.forEach { self.channel.invokeMethod("link", arguments: $0) }
      self.held.removeAll()
      result(true)
    }
    // New opened files queue after old cached copies are removed.
    copies.async {
      let manager = FileManager.default
      if let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first {
        try? manager.removeItem(at: caches.appendingPathComponent("links", isDirectory: true))
      }
    }
  }

  func open(_ url: URL) {
    copies.async { [weak self] in
      let link = url.isFileURL ? Self.copied(url) : ["uri": url.absoluteString]
      onMain {
        guard let self else { return }
        if self.ready {
          self.channel.invokeMethod("link", arguments: link)
        } else {
          self.held.append(link)
        }
      }
    }
  }

  /// Keeps the sender's file name in a folder of its own. The access granted for an
  /// opened file ends with this call, so the copy is what Dart gets.
  private static func copied(_ url: URL) -> [String: String] {
    let name = url.lastPathComponent
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let manager = FileManager.default
      let folder = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .appendingPathComponent("links/\(UUID().uuidString)", isDirectory: true)
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
      let copy = folder.appendingPathComponent(name)
      try manager.copyItem(at: url, to: copy)
      return ["uri": copy.absoluteString]
    } catch {
      return ["error": "unreadable", "name": name]
    }
  }
}

// MARK: - dsh/shortcuts

/// The home screen's quick actions. 新对话 and 语音输入 are declared in Info.plist, the
/// latest conversations are set from Dart, and the system shows four in all.
private final class ShortcutsChannel {
  private static let prefix = "io.github.ccch1mneyyy.dshgo."
  private static let recentShown = 2

  private let channel: FlutterMethodChannel
  private var ready = false
  private var held: [[String: String]] = []

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/shortcuts", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      switch call.method {
      case "ready":
        self.ready = true
        self.held.forEach { self.channel.invokeMethod("entry", arguments: $0) }
        self.held.removeAll()
        result(true)
      case "setRecent":
        self.setRecent(arguments(call)["items"] as? [[String: Any]] ?? [])
        result(true)
      default: result(FlutterMethodNotImplemented)
      }
    }
    SystemEntries.attach { [weak self] in self?.send($0) }
  }

  /// False for an item that isn't the app's.
  func perform(_ item: UIApplicationShortcutItem) -> Bool {
    guard let entry = Self.entry(item) else { return false }
    send(entry)
    return true
  }

  private func send(_ entry: [String: String]) {
    if ready {
      channel.invokeMethod("entry", arguments: entry)
    } else {
      held.append(entry)
    }
  }

  private static func entry(_ item: UIApplicationShortcutItem) -> [String: String]? {
    switch item.type {
    case prefix + "new": return ["kind": "new"]
    case prefix + "voice": return ["kind": "voice"]
    case prefix + "chat":
      guard let id = item.userInfo?["sessionId"] as? String else { return nil }
      return ["kind": "chat", "sessionId": id, "host": item.userInfo?["host"] as? String ?? ""]
    default: return nil
    }
  }

  private func setRecent(_ items: [[String: Any]]) {
    UIApplication.shared.shortcutItems = items.prefix(Self.recentShown).compactMap { item -> UIApplicationShortcutItem? in
      guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
      var info: [String: NSSecureCoding] = ["sessionId": id as NSString]
      if let host = item["host"] as? String { info["host"] = host as NSString }
      return UIApplicationShortcutItem(
        type: Self.prefix + "chat",
        localizedTitle: title,
        localizedSubtitle: nil,
        icon: UIApplicationShortcutIcon(systemImageName: "bubble.left"),
        userInfo: info
      )
    }
  }
}

// MARK: - dsh/launcher_icon

/// 桌面图标. The default icon is the primary one and the rest are the asset catalog's
/// alternates (ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES). The system says so with
/// an alert of its own when one changes, and there's no mask to report: Dart's
/// rounded square is close enough to iOS's.
private final class LauncherIconChannel {
  private static let primary = "mist"
  private static let alternates = ["night": "AppIconNight", "frost": "AppIconFrost", "ink": "AppIconInk"]

  private let channel: FlutterMethodChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/launcher_icon", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "state": result(Self.reply())
      case "set": Self.set(arguments(call)["id"] as? String, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func reply() -> [String: String] {
    let name = UIApplication.shared.alternateIconName
    return ["current": alternates.first { $0.value == name }?.key ?? primary]
  }

  private static func set(_ id: String?, result: @escaping FlutterResult) {
    let known = id == primary || id.flatMap { alternates[$0] } != nil
    guard known, UIApplication.shared.supportsAlternateIcons else {
      return result(FlutterError(code: "unavailable", message: nil, details: nil))
    }
    UIApplication.shared.setAlternateIconName(id.flatMap { alternates[$0] }) { error in
      onMain {
        if error == nil {
          result(Self.reply())
        } else {
          result(FlutterError(code: "refused", message: nil, details: nil))
        }
      }
    }
  }
}

// MARK: - dsh/files

/// Only the engine's committed, private migration record authorizes old-root aliases.
/// No history text is rewritten, and callers still validate the resolved file.
private enum RelocatedGuestPaths {
  private struct Marker: Decodable {
    let version: Int
    let currentRoot: String
    let previousRoots: [String]
  }

  private static func validRoot(_ path: String) -> Bool {
    guard path.hasPrefix("/"), path != "/", !path.contains("\0") else { return false }
    return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
      .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  static func map(_ path: String, root: String) -> String {
    guard validRoot(root), path.hasPrefix("/"), !path.contains("\0") else { return path }
    if path == root || path.hasPrefix(root + "/") { return path }
    let home = root + "/root/.dsh"
    guard let resolved = realpath(home, nil) else { return path }
    let privateHome = String(cString: resolved)
    free(resolved)
    guard privateHome == home else { return path }
    let fd = open(home + "/ios-container-paths.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return path }
    defer { close(fd) }
    var info = stat()
    let limit = 64 * 1024
    guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      info.st_size > 0, info.st_size <= limit
    else { return path }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { return path }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= limit else { return path }
    }
    guard let marker = try? JSONDecoder().decode(Marker.self, from: data), marker.version == 1,
      validRoot(marker.currentRoot), marker.previousRoots.allSatisfy(validRoot)
    else { return path }
    // A second move can occur before JS updates currentRoot. Both it and the
    // older roots therefore map to the native root of this launch.
    let aliases = ([marker.currentRoot] + marker.previousRoots).sorted { $0.count > $1.count }
    for old in aliases where path == old || path.hasPrefix(old + "/") {
      return root + path.dropFirst(old.count)
    }
    return path
  }
}

/// iOS tool paths are already absolute sandbox paths, not Android guest paths.
/// This is a point-in-time lookup; the Dart caller opens the returned path later.
private struct LocalEngineFiles {
  let guestRoot: URL

  private func canonical(_ path: String) -> String? {
    guard path.hasPrefix("/"), !path.contains("\0"), let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  func resolve(_ path: String) -> String? {
    guard
      let root = canonical(guestRoot.path),
      let file = canonical(RelocatedGuestPaths.map(path, root: root)),
      file.hasPrefix(root + "/"),
      let values = try? FileManager.default.attributesOfItem(atPath: file),
      values[.type] as? FileAttributeType == .typeRegular,
      FileManager.default.isReadableFile(atPath: file)
    else { return nil }
    return file
  }

  /// Same directory advertised by EngineChannel's managed AGENTS.md. Results
  /// carry engine-visible absolute paths and epoch milliseconds, as Dart expects.
  func outputs(depth: Int) -> [[String: Any]] {
    guard let root = canonical(guestRoot.path) else { return [] }
    let expected = root + "/root/workspace/DSH-Go"
    guard canonical(expected) == expected else { return [] }
    let manager = FileManager.default
    let maxDepth = min(max(depth, 1), 8)
    var rows: [[String: Any]] = []
    var visited = 0
    func walk(_ folder: URL, level: Int) {
      guard let entries = try? manager.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      else { return }
      for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        // Bound both returned files and work in a directory-heavy tree.
        guard rows.count < 500, visited < 5000 else { return }
        visited += 1
        guard let values = try? manager.attributesOfItem(atPath: entry.path) else { continue }
        let type = values[.type] as? FileAttributeType
        // Never recurse into or publish a symlink from the output scan.
        if type == .typeDirectory {
          if level < maxDepth { walk(entry, level: level + 1) }
        } else if type == .typeRegular, let path = resolve(entry.path),
          path.hasPrefix(expected + "/"),
          let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date
        {
          rows.append(["path": path, "bytes": size.int64Value, "modified": Int64(modified.timeIntervalSince1970 * 1000)])
        }
      }
    }
    walk(URL(fileURLWithPath: expected, isDirectory: true), level: 1)
    return rows
  }
}

/// Opening, saving and previewing the files a turn produced.
private final class FilesChannel: NSObject, QLPreviewControllerDataSource {
  private let channel: FlutterMethodChannel
  private let pdfQueue = DispatchQueue(label: "dsh.pdf")
  private var pdf: (path: String, document: PDFDocument)?
  private var previewing: URL?

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/files", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      let args = arguments(call)
      let path = args["path"] as? String ?? ""
      switch call.method {
      case "resolveGuest":
        self.pdfQueue.async {
          let path = self.localFiles.resolve(path)
          onMain { result(path) }
        }
      case "listOutputs":
        let depth = args["depth"] as? Int ?? 3
        self.pdfQueue.async {
          let rows = self.localFiles.outputs(depth: depth)
          onMain { result(rows) }
        }
      case "open":
        self.open(path: path, name: args["name"] as? String, chooser: args["chooser"] as? Bool ?? false, result: result)
      case "saveToDownloads": self.save(path: path, name: args["name"] as? String, result: result)
      case "pdfInfo": self.pdfInfo(path: path, result: result)
      case "pdfPage":
        self.pdfPage(path: path, page: args["page"] as? Int ?? 0, width: args["width"] as? Int ?? 0, result: result)
      case "pdfClose":
        self.pdfQueue.async {
          self.pdf = nil
          onMain { result(nil) }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Match EngineChannel's application-support root and fallback exactly. Resolve
  /// aliases only when reading, after the engine has prepared its root.
  private var localFiles: LocalEngineFiles {
    let base =
      (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return LocalEngineFiles(guestRoot: base.appendingPathComponent("runtime/rootfs", isDirectory: true))
  }

  // Open

  private func open(path: String, name: String?, chooser: Bool, result: FlutterResult) {
    guard FileManager.default.isReadableFile(atPath: path), let top = topViewController() else {
      return result(FlutterError(code: "missing", message: "no such file", details: nil))
    }
    let url: URL
    do {
      url = try named(URL(fileURLWithPath: path), as: name)
    } catch {
      return result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
    }
    if !chooser && QLPreviewController.canPreview(url as NSURL) {
      previewing = url
      let preview = QLPreviewController()
      preview.dataSource = self
      top.present(preview, animated: true)
    } else {
      let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      if let popover = share.popoverPresentationController {
        popover.sourceView = top.view
        popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
      }
      top.present(share, animated: true)
    }
    result(nil)
  }

  /// The preview and other apps go by the file's extension, and the cache may not
  /// have it under the name the file should show.
  private func named(_ url: URL, as name: String?) throws -> URL {
    guard let name, !name.isEmpty, name != url.lastPathComponent else { return url }
    let manager = FileManager.default
    let folder = manager.temporaryDirectory.appendingPathComponent("open/\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appendingPathComponent((name as NSString).lastPathComponent)
    try manager.copyItem(at: url, to: copy)
    return copy
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    previewing == nil ? 0 : 1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
    (previewing ?? URL(fileURLWithPath: "/")) as NSURL
  }

  // Save

  /// Into the app's Documents, which the Files app shows under the app's name
  /// (UIFileSharingEnabled, LSSupportsOpeningDocumentsInPlace). No dialog, like the
  /// save on Android; returns where it landed.
  private func save(path: String, name: String?, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let manager = FileManager.default
      guard manager.isReadableFile(atPath: path) else {
        return onMain { result(FlutterError(code: "missing", message: "no such file", details: nil)) }
      }
      do {
        let documents = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let wanted = name?.isEmpty == false ? name! : URL(fileURLWithPath: path).lastPathComponent
        let target = Self.free(in: documents, name: (wanted as NSString).lastPathComponent)
        try manager.copyItem(at: URL(fileURLWithPath: path), to: target)
        onMain { result("DSH Go/\(target.lastPathComponent)") }
      } catch {
        onMain { result(FlutterError(code: "failed", message: error.localizedDescription, details: nil)) }
      }
    }
  }

  /// `report.pdf`, then `report (1).pdf`, the first name not taken.
  private static func free(in folder: URL, name: String) -> URL {
    let manager = FileManager.default
    let plain = folder.appendingPathComponent(name)
    if !manager.fileExists(atPath: plain.path) { return plain }
    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var number = 1
    while true {
      let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)")
      if !manager.fileExists(atPath: candidate.path) { return candidate }
      number += 1
    }
  }

  // PDF preview

  private func document(_ path: String) -> PDFDocument? {
    if let pdf, pdf.path == path { return pdf.document }
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
    pdf = (path, document)
    return document
  }

  /// A page's size as it is shown: rotated pages swap width and height.
  private static func size(of page: PDFPage) -> CGSize {
    let box = page.bounds(for: .mediaBox).size
    return page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
  }

  private func pdfInfo(path: String, result: @escaping FlutterResult) {
    pdfQueue.async {
      guard let document = self.document(path) else {
        return onMain { result(FlutterError(code: "missing", message: "no such PDF", details: nil)) }
      }
      let pages: [[String: Int]] = (0..<document.pageCount).compactMap { index in
        guard let page = document.page(at: index) else { return nil }
        let size = Self.size(of: page)
        return ["width": Int(size.width.rounded()), "height": Int(size.height.rounded())]
      }
      onMain { result(pages) }
    }
  }

  private func pdfPage(path: String, page index: Int, width: Int, result: @escaping FlutterResult) {
    pdfQueue.async {
      guard width > 0, let page = self.document(path)?.page(at: index) else {
        return onMain { result(FlutterError(code: "missing", message: "no such page", details: nil)) }
      }
      let size = Self.size(of: page)
      guard size.width > 0, size.height > 0 else {
        return onMain { result(FlutterError(code: "failed", message: "empty page", details: nil)) }
      }
      let scale = CGFloat(width) / size.width
      let target = CGSize(width: CGFloat(width), height: (size.height * scale).rounded())
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let png = UIGraphicsImageRenderer(size: target, format: format).pngData { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: target))
        context.cgContext.translateBy(x: 0, y: target.height)
        context.cgContext.scaleBy(x: scale, y: -scale)
        page.draw(with: .mediaBox, to: context.cgContext)
      }
      onMain { result(FlutterStandardTypedData(bytes: png)) }
    }
  }
}

func topViewController() -> UIViewController? {
  let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
  let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
  var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
  while let presented = top?.presentedViewController { top = presented }
  return top
}

func openAppSettings(_ address: String, result: @escaping FlutterResult) {
  guard let url = URL(string: address) else { return result(false) }
  UIApplication.shared.open(url) { result($0) }
}

// MARK: - dsh/media

private final class MediaChannel {
  private let channel: FlutterMethodChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/media", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "saveImage":
        let args = arguments(call)
        guard let bytes = args["bytes"] as? FlutterStandardTypedData, let name = args["name"] as? String else {
          return result(FlutterError(code: "invalid", message: "no image", details: nil))
        }
        Self.save(bytes.data, name: name, result: result)
      case "saveVideoFile":
        let args = arguments(call)
        guard let path = args["path"] as? String, let name = args["name"] as? String,
          let file = Self.videoFile(path, name: name) else {
          return result(FlutterError(code: "invalid", message: "invalid local video", details: nil))
        }
        Self.saveVideo(file, name: name, result: result)
      case "openSettings": openAppSettings(UIApplication.openSettingsURLString, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func videoFile(_ path: String, name: String) -> URL? {
    guard path.hasPrefix("/"), !name.isEmpty, name.utf8.count <= 255,
      name == (name as NSString).lastPathComponent,
      ["mp4", "mov", "m4v"].contains((name as NSString).pathExtension.lowercased()) else { return nil }
    let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL.path
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    guard file.path.hasPrefix(root + "/"),
      ["mp4", "mov", "m4v"].contains(file.pathExtension.lowercased()),
      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
    return file
  }

  private static func saveVideo(_ file: URL, name: String, result: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        return onMain { result(FlutterError(code: "permission", message: "photos refused", details: nil)) }
      }
      PHPhotoLibrary.shared().performChanges({
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = name
        options.shouldMoveFile = false
        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: options)
      }) { saved, error in
        onMain {
          if saved { result("Photos/\(name)") }
          else { result(FlutterError(code: "failed", message: error?.localizedDescription, details: nil)) }
        }
      }
    }
  }

  /// Add-only access: saving doesn't need to read the rest of the library.
  private static func save(_ data: Data, name: String, result: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        return onMain { result(FlutterError(code: "permission", message: "photos refused", details: nil)) }
      }
      PHPhotoLibrary.shared().performChanges({
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = name
        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
      }) { saved, error in
        onMain {
          if saved {
            result("Photos/\(name)")
          } else {
            result(FlutterError(code: "failed", message: error?.localizedDescription, details: nil))
          }
        }
      }
    }
  }
}

// MARK: - dsh/notify

/// Notifications posted by the app itself. They only cover what happens while the
/// app is running: once iOS suspends it nothing here runs, and telling the person a
/// turn ended then takes a push from the host.
///
/// Approving from a notification isn't offered: the person opens the conversation and
/// approves there, against what the host says now. The live activity (`live`) is
/// IOSLiveActivity's.
private final class NotifyChannel {
  private let channel: FlutterMethodChannel
  private let actions: SilentEvents
  private let taps: FlutterEventChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/notify", binaryMessenger: messenger)
    actions = SilentEvents(name: "dsh/notify/actions", messenger: messenger)
    taps = FlutterEventChannel(name: "dsh/notify/taps", binaryMessenger: messenger)
    taps.setStreamHandler(NotifyTaps.shared)
    channel.setMethodCallHandler { call, result in
      Self.handle(call, result: result)
    }
    IOSLiveActivity.shared.channel = channel
  }

  private static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    let args = arguments(call)
    switch call.method {
    case "status": status(center, result: result)
    case "requestPermission":
      center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
        onMain { result(granted) }
      }
    case "show": show(center, args, result: result)
    case "cancel":
      let id = identifier(args)
      center.removeDeliveredNotifications(withIdentifiers: [id])
      center.removePendingNotificationRequests(withIdentifiers: [id])
      result(nil)
    case "cancelGroup":
      let group = args["group"] as? String
      center.getDeliveredNotifications { delivered in
        let ids = delivered.filter { $0.request.content.threadIdentifier == group }.map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        onMain { result(nil) }
      }
    case "cancelAll":
      center.removeAllDeliveredNotifications()
      center.removeAllPendingNotificationRequests()
      result(nil)
    case "openSettings": openNotificationSettings(center, result: result)
    // The 实时活动 switch is on the app's own page in Settings, not under notifications.
    case "openLiveSettings": openAppSettings(UIApplication.openSettingsURLString, result: result)
    case "live":
      IOSLiveActivity.shared.live(args)
      result(nil)
    case "actionResult": result(nil)
    case "liveStatus": result(IOSLiveActivity.shared.status())
    default: result(FlutterMethodNotImplemented)
    }
  }

  private static func identifier(_ args: [String: Any]) -> String {
    "\(args["group"] as? String ?? "")|\(args["key"] as? String ?? "")"
  }

  /// Not asked yet reads as off: nothing can post, and first run's dialog is what
  /// [requestPermission] is for.
  private static func status(_ center: UNUserNotificationCenter, result: @escaping FlutterResult) {
    center.getNotificationSettings { settings in
      let status = settings.authorizationStatus
      let on = status != .denied && status != .notDetermined
      onMain { result(["enabled": on, "done": true, "attention": true]) }
    }
  }

  /// Settings has no notifications page for an app that hasn't asked yet, so the
  /// first time this is the question itself.
  private static func openNotificationSettings(
    _ center: UNUserNotificationCenter,
    result: @escaping FlutterResult
  ) {
    center.getNotificationSettings { settings in
      guard settings.authorizationStatus != .notDetermined else {
        return center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
          onMain { result(true) }
        }
      }
      onMain {
        if #available(iOS 16.0, *) {
          openAppSettings(UIApplication.openNotificationSettingsURLString, result: result)
        } else {
          openAppSettings(UIApplication.openSettingsURLString, result: result)
        }
      }
    }
  }

  private static func show(_ center: UNUserNotificationCenter, _ args: [String: Any], result: @escaping FlutterResult) {
    let content = UNMutableNotificationContent()
    content.title = args["title"] as? String ?? ""
    content.body = args["text"] as? String ?? ""
    content.threadIdentifier = args["group"] as? String ?? ""
    content.sound = .default
    content.userInfo = ["sessionId", "host", "kind", "eventId"].reduce(into: [String: String]()) { info, key in
      if let value = args[key] as? String { info[key] = value }
    }
    center.add(UNNotificationRequest(identifier: identifier(args), content: content, trigger: nil)) { error in
      onMain {
        if let error {
          result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
        } else {
          result(nil)
        }
      }
    }
  }
}

/// Set as the notification center's delegate at launch, before there is a Flutter
/// engine, so the tap that launched the app is held until Dart listens.
final class NotifyTaps: NSObject, UNUserNotificationCenterDelegate, FlutterStreamHandler {
  static let shared = NotifyTaps()

  private var sink: FlutterEventSink?
  private var held: [[AnyHashable: Any]] = []

  /// On screen, Dart shows its own banner.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    deliver(response.notification.request.content.userInfo, then: completionHandler)
  }

  /// A tap to open a conversation: a notification's, or the live activity's.
  func deliver(_ tap: [AnyHashable: Any], then done: (() -> Void)? = nil) {
    onMain {
      if let sink = self.sink {
        sink(tap)
      } else {
        self.held.append(tap)
      }
      done?()
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    held.forEach { events($0) }
    held.removeAll()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}
