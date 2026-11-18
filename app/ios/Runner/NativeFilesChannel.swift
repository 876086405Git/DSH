import Flutter
import PhotosUI
import UIKit
import UniformTypeIdentifiers

// dsh/native-files, after ohos/.../NativeFilesPlugin.ets and android/.../nativefiles/: the
// system's own pickers and nothing more, so no photo library permission and no grant that
// outlives the selection. One selection at a time, five minutes at most from the pick, read
// a chunk at a time within a byte budget counted on what actually comes off the file.
//
// Unlike those two, photos can't be read in place: the picker's file is gone once its callback
// returns, so a copy goes in tmp for the life of the selection and is removed with it.

/// The hard limits, whatever a file says about itself (NativeFilePolicy.ets).
private final class FileBudget {
  private static let chunk = 64 * 1024

  let maxFiles: Int
  let maxBytes: Int
  let maxTotalBytes: Int
  private var counts: [String: Int] = [:]
  private var total = 0

  /// `own`: the app's own pick for its look, never a plugin's.
  init?(maxFiles: Int, maxBytes: Int, maxTotalBytes: Int, own: Bool) {
    let fileLimit = own ? 30 * 1024 * 1024 : 8 * 1024 * 1024
    let totalLimit = own ? fileLimit : 16 * 1024 * 1024
    guard
      maxFiles >= 1, maxFiles <= (own ? 1 : 4),
      maxBytes >= 1, maxBytes <= fileLimit,
      maxTotalBytes >= 1, maxTotalBytes <= totalLimit
    else { return nil }
    self.maxFiles = maxFiles
    self.maxBytes = maxBytes
    self.maxTotalBytes = maxTotalBytes
  }

  func allows(sizes: [Int]) -> Bool {
    sizes.allSatisfy { $0 >= 0 && $0 <= maxBytes } && sizes.reduce(0, +) <= maxTotalBytes
  }

  /// One byte past the limit is what catches a file that grew or lied, even at the exact cap.
  func chunkSize(_ handle: String) -> Int {
    min(Self.chunk, maxBytes - (counts[handle] ?? 0) + 1, maxTotalBytes - total + 1)
  }

  func accept(_ handle: String, count: Int) -> Bool {
    let next = (counts[handle] ?? 0) + count
    guard next <= maxBytes, total + count <= maxTotalBytes else { return false }
    counts[handle] = next
    total += count
    return true
  }
}

private final class SelectedFile {
  let handle = UUID().uuidString
  let url: URL
  let name: String
  let mediaType: String
  let size: Int?

  /// From the document picker: reached through its security scope, by the file coordinator.
  let scoped: Bool

  /// Only touched on the channel's io queue.
  var input: FileHandle?
  var ended = false

  init(url: URL, name: String, size: Int?, scoped: Bool) {
    self.url = url
    self.name = SelectedFile.safeName(name)
    self.size = size
    self.scoped = scoped
    self.mediaType = SelectedFile.mediaType(of: self.name)
  }

  var metadata: [String: Any] {
    var value: [String: Any] = ["handle": handle, "name": name, "mediaType": mediaType]
    if let size { value["bytes"] = size }
    return value
  }

  private static func safeName(_ raw: String) -> String {
    let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
    let cleaned = String(last.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
    let cut = String(cleaned.prefix(128))
    return cut.isEmpty || cut == "." || cut == ".." ? "file" : cut
  }

  /// What the name suggests, not a claim about the content.
  private static func mediaType(of name: String) -> String {
    let fallback = "application/octet-stream"
    let ext = (name as NSString).pathExtension
    guard !ext.isEmpty, let mime = UTType(filenameExtension: ext)?.preferredMIMEType else { return fallback }
    let shape = "^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}$"
    return mime.range(of: shape, options: .regularExpression) != nil ? mime : fallback
  }
}

private final class FileSelection {
  let owner: String
  let budget: FileBudget
  let coordinator = NSFileCoordinator()
  var files: [SelectedFile] = []
  var active = true

  /// Where this selection's copies of photos are.
  var folder: URL?
  var loads: [Progress] = []

  init(owner: String, budget: FileBudget) {
    self.owner = owner
    self.budget = budget
  }
}

private struct NativeFileFailure: Error {
  let code: String
}

/// What the picker's callbacks gather, on whatever queue each one comes.
private final class PhotoCopies {
  private let lock = NSLock()
  private var files: [Int: SelectedFile] = [:]
  private var over = false

  func add(_ file: SelectedFile, at index: Int) {
    lock.lock()
    files[index] = file
    lock.unlock()
  }

  func markTooLarge() {
    lock.lock()
    over = true
    lock.unlock()
  }

  var tooLarge: Bool {
    lock.lock()
    defer { lock.unlock() }
    return over
  }

  var inOrder: [SelectedFile] {
    lock.lock()
    defer { lock.unlock() }
    return files.keys.sorted().compactMap { files[$0] }
  }
}

final class NativeFilesChannel: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate,
  UIAdaptivePresentationControllerDelegate
{
  private static let lifetime: TimeInterval = 5 * 60
  private static let copiesFolder = "native-files"

  private let channel: FlutterMethodChannel

  /// One read or one close at a time; nothing queues up behind them.
  private let io = DispatchQueue(label: "dsh.native-files")
  private var selection: FileSelection?
  private var pending: FlutterResult?
  private var shownPicker: UIViewController?
  private var expiry: DispatchWorkItem?
  private var ioBusy = false
  private var closing = false

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/native-files", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      let args = arguments(call)
      switch call.method {
      case "capabilities": result(["files": true])
      case "pick": self.pick(args, result: result)
      case "read": self.read(args, result: result)
      case "cancel":
        if let owner = args["owner"] as? String, owner == self.selection?.owner { self.revoke() }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    // Left by a process that died mid-selection.
    io.async { try? FileManager.default.removeItem(at: Self.copiesRoot) }
  }

  private static var copiesRoot: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(copiesFolder, isDirectory: true)
  }

  private static func failure(_ code: String) -> FlutterError {
    FlutterError(code: code, message: "file selection: \(code)", details: nil)
  }

  // MARK: Picking

  private func pick(_ args: [String: Any], result: @escaping FlutterResult) {
    guard
      UIApplication.shared.applicationState == .active,
      args["userGesture"] as? Bool == true,
      let top = topViewController()
    else { return result(Self.failure("unavailable")) }
    guard pending == nil, selection == nil, !ioBusy, !closing else {
      return result(Self.failure("busy"))
    }
    guard
      let owner = args["owner"] as? String,
      owner.range(of: "^[A-Za-z0-9_-]{32}$", options: .regularExpression) != nil,
      let budget = FileBudget(
        maxFiles: args["maxFiles"] as? Int ?? 1,
        maxBytes: args["maxBytes"] as? Int ?? 0,
        maxTotalBytes: args["maxTotalBytes"] as? Int ?? 0,
        own: args["own"] as? Bool == true
      )
    else { return result(Self.failure("invalid")) }

    selection = FileSelection(owner: owner, budget: budget)
    pending = result
    let lapse = DispatchWorkItem { [weak self] in self?.revoke() }
    expiry = lapse
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime, execute: lapse)

    let images = args["images"] as? Bool == true
    let visual = args["visual"] as? Bool == true
    let shown = images || visual ? makePhotoPicker(limit: budget.maxFiles, videos: visual) : makeDocumentPicker(limit: budget.maxFiles)
    shown.presentationController?.delegate = self
    shownPicker = shown
    top.present(shown, animated: true)
  }

  /// No photo library given, so no permission and no way to the rest of the library.
  private func makePhotoPicker(limit: Int, videos: Bool) -> UIViewController {
    var configuration = PHPickerConfiguration()
    configuration.selectionLimit = limit
    configuration.filter = videos ? PHPickerFilter.any(of: [.images, .videos]) : PHPickerFilter.images
    // HEIC as JPEG, HEVC as H.264: what the launch screen's import and a plugin's host can read.
    configuration.preferredAssetRepresentationMode = .compatible
    let photos = PHPickerViewController(configuration: configuration)
    photos.delegate = self
    return photos
  }

  private func makeDocumentPicker(limit: Int) -> UIViewController {
    let documents = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
    documents.allowsMultipleSelection = limit > 1
    documents.delegate = self
    return documents
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    shownPicker = nil
    guard let picked = selection, pending != nil else { return }
    guard !results.isEmpty else { return revoke() }
    guard results.count <= picked.budget.maxFiles else { return refuse("too-large") }
    copyPhotos(results, for: picked)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    shownPicker = nil
    guard let picked = selection, pending != nil else { return }
    guard !urls.isEmpty else { return revoke() }
    guard urls.count <= picked.budget.maxFiles else { return refuse("too-large") }
    ioBusy = true
    io.async {
      let outcome = Result { try Self.documents(urls) }
      onMain { [weak self] in self?.documentsRead(outcome, for: picked) }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    shownPicker = nil
    revoke()
  }

  /// A swipe down on the sheet doesn't reach either picker's delegate on every iOS.
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    shownPicker = nil
    revoke()
  }

  /// A file refused partway through a selection mustn't leave the earlier ones' scopes open.
  private static func documents(_ urls: [URL]) throws -> [SelectedFile] {
    var files: [SelectedFile] = []
    do {
      for url in urls { files.append(try document(url)) }
    } catch {
      files.filter(\.scoped).forEach { $0.url.stopAccessingSecurityScopedResource() }
      throw error
    }
    return files
  }

  private static func document(_ url: URL) throws -> SelectedFile {
    guard url.isFileURL else { throw NativeFileFailure(code: "invalid") }
    let scoped = url.startAccessingSecurityScopedResource()
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .nameKey])
    if values?.isRegularFile == false {
      if scoped { url.stopAccessingSecurityScopedResource() }
      throw NativeFileFailure(code: "invalid")
    }
    return SelectedFile(url: url, name: values?.name ?? url.lastPathComponent, size: values?.fileSize, scoped: scoped)
  }

  private func documentsRead(_ outcome: Result<[SelectedFile], Error>, for picked: FileSelection) {
    ioBusy = false
    guard selection === picked, picked.active else {
      if case .success(let files) = outcome {
        files.filter(\.scoped).forEach { $0.url.stopAccessingSecurityScopedResource() }
      }
      return
    }
    switch outcome {
    case .success(let files): deliver(files, to: picked)
    case .failure(let error): refuse((error as? NativeFileFailure)?.code ?? "failed")
    }
  }

  /// Each load's callback has to copy before it returns.
  private func copyPhotos(_ results: [PHPickerResult], for picked: FileSelection) {
    let folder = Self.copiesRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    picked.folder = folder
    let budget = picked.budget
    let copies = PhotoCopies()
    let group = DispatchGroup()
    for (index, result) in results.enumerated() {
      let provider = result.itemProvider
      let name = provider.suggestedName
      let kind = provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ? UTType.image : UTType.movie
      group.enter()
      let load = provider.loadFileRepresentation(forTypeIdentifier: kind.identifier) { url, _ in
        defer { group.leave() }
        guard let url else { return }
        do {
          let copy = try Self.copyPhoto(url, suggested: name, into: folder, limit: budget.maxBytes)
          copies.add(copy, at: index)
        } catch is NativeFileFailure {
          copies.markTooLarge()
        } catch {}
      }
      picked.loads.append(load)
    }
    group.notify(queue: .main) { [weak self] in
      self?.photosCopied(copies, expected: results.count, for: picked)
    }
  }

  private static func copyPhoto(_ url: URL, suggested: String?, into folder: URL, limit: Int) throws -> SelectedFile {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    if let size, size > limit { throw NativeFileFailure(code: "too-large") }
    let manager = FileManager.default
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appendingPathComponent(UUID().uuidString)
    try manager.copyItem(at: url, to: copy)
    // The picker's own file name says nothing a person would know; the photo's has no extension.
    let ext = url.pathExtension
    let base = suggested ?? "file"
    let name = ext.isEmpty || (base as NSString).pathExtension.caseInsensitiveCompare(ext) == .orderedSame ? base : "\(base).\(ext)"
    return SelectedFile(url: copy, name: name, size: size, scoped: false)
  }

  private func photosCopied(_ copies: PhotoCopies, expected: Int, for picked: FileSelection) {
    guard selection === picked, picked.active else {
      // Cancelled while a load was still writing.
      if let folder = picked.folder { io.async { try? FileManager.default.removeItem(at: folder) } }
      return
    }
    if copies.tooLarge { return refuse("too-large") }
    let files = copies.inOrder
    guard files.count == expected else { return refuse("failed") }
    deliver(files, to: picked)
  }

  private func deliver(_ files: [SelectedFile], to picked: FileSelection) {
    picked.files = files
    guard picked.budget.allows(sizes: files.compactMap(\.size)) else { return refuse("too-large") }
    let reply = pending
    pending = nil
    reply?(files.map(\.metadata))
  }

  // MARK: Reading

  private func read(_ args: [String: Any], result: @escaping FlutterResult) {
    guard
      let picked = selection, picked.active,
      args["owner"] as? String == picked.owner,
      let handle = args["handle"] as? String,
      let file = picked.files.first(where: { $0.handle == handle })
    else { return result(Self.failure("cancelled")) }
    guard !ioBusy, !closing else { return result(Self.failure("busy")) }
    ioBusy = true
    io.async {
      let outcome = Result { try Self.chunk(of: file, in: picked) }
      onMain { [weak self] in
        guard let self else { return }
        self.ioBusy = false
        guard self.selection === picked, picked.active else { return result(Self.failure("cancelled")) }
        switch outcome {
        case .success(let data): result(data.map { FlutterStandardTypedData(bytes: $0) })
        case .failure(let error):
          self.revoke()
          result(Self.failure((error as? NativeFileFailure)?.code ?? "failed"))
        }
      }
    }
  }

  /// Bytes, or nil at the end. Never empty: Dart takes an empty chunk as a broken provider.
  private static func chunk(of file: SelectedFile, in picked: FileSelection) throws -> Data? {
    if file.ended { return nil }
    let input = try file.input ?? openFile(file, in: picked)
    file.input = input
    guard let data = try input.read(upToCount: picked.budget.chunkSize(file.handle)), !data.isEmpty else {
      try? input.close()
      file.input = nil
      file.ended = true
      return nil
    }
    guard picked.budget.accept(file.handle, count: data.count) else { throw NativeFileFailure(code: "too-large") }
    return data
  }

  /// A document may only exist in the cloud so far: the coordinator waits for it, and `revoke`
  /// can cancel the wait. The size is checked again here, on the file that's actually open.
  private static func openFile(_ file: SelectedFile, in picked: FileSelection) throws -> FileHandle {
    let input: FileHandle
    if file.scoped {
      var failure: NSError?
      var opened: Result<FileHandle, Error>?
      picked.coordinator.coordinate(readingItemAt: file.url, options: [], error: &failure) { url in
        opened = Result { try FileHandle(forReadingFrom: url) }
      }
      if let failure { throw failure }
      guard let opened else { throw NativeFileFailure(code: "failed") }
      input = try opened.get()
    } else {
      input = try FileHandle(forReadingFrom: file.url)
    }
    var info = stat()
    guard fstat(input.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      try? input.close()
      throw NativeFileFailure(code: "invalid")
    }
    guard Int(info.st_size) <= picked.budget.maxBytes else {
      try? input.close()
      throw NativeFileFailure(code: "too-large")
    }
    return input
  }

  // MARK: Ending

  private func refuse(_ code: String) {
    let reply = pending
    pending = nil
    revoke()
    reply?(Self.failure(code))
  }

  /// Ends the selection now: a picker still up goes away with no answer but "nothing chosen", and
  /// what it opened is closed once the read in progress is done.
  private func revoke() {
    expiry?.cancel()
    expiry = nil
    let reply = pending
    pending = nil
    let shown = shownPicker
    shownPicker = nil
    shown?.dismiss(animated: true)
    if let picked = selection {
      selection = nil
      picked.active = false
      picked.coordinator.cancel()
      picked.loads.forEach { $0.cancel() }
      closing = true
      io.async {
        for file in picked.files {
          try? file.input?.close()
          file.input = nil
          if file.scoped { file.url.stopAccessingSecurityScopedResource() }
        }
        if let folder = picked.folder { try? FileManager.default.removeItem(at: folder) }
        onMain { [weak self] in self?.closing = false }
      }
    }
    reply?(nil)
  }
}
