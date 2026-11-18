import Foundation
import CryptoKit
import Darwin

enum IOSPhoneDDIError: String, Error {
  case unavailable = "ERR_PHONE_DDI_DOWNLOAD"
  case integrity = "ERR_PHONE_DDI_INTEGRITY"
  case cache = "ERR_PHONE_DDI_CACHE"
  case cancelled = "ERR_PHONE_CANCELLED"
}

/// Public, fixed build assets only. Pairing records/TSS responses never enter
/// this downloader, its cache, URLSession configuration, or progress messages.
@MainActor
final class IOSPhoneDDICache {
  enum Variant: String, CaseIterable { case personalized, cryptex }
  struct Asset: Sendable {
    let key: String
    let filename: String
    let bytes: Int64
    let sha256: String
  }
  static let catalogID = "ddi-e2aaeac89ca8fa56c2fa1f144d182994e07a525b-v1"
  static let sourceCommit = "e2aaeac89ca8fa56c2fa1f144d182994e07a525b"
  static let shared = IOSPhoneDDICache()
  private let root: URL
  private let anchor: URL
  private let components: [String]
  private var verified = Set<Variant>()
  private var busy = false
  private var progressID: UUID?
  private var progressCompleted: Int64 = 0

  init(root: URL? = nil) {
    // Resolve only the trusted container prefix. Never resolve a cache-owned
    // symlink into authority to write elsewhere. Library/Caches is not backed up.
    let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath()
    if let root {
      // Test seam: an already-created, trusted directory. Never a channel input.
      self.root = root; self.anchor = root; self.components = []
    } else {
      self.anchor = container
      self.components = ["Library", "Caches", "phone-ddi", Self.catalogID]
      self.root = components.reduce(container) { $0.appendingPathComponent($1, isDirectory: true) }
    }
  }

  static func assets(_ variant: Variant) -> [Asset] {
    switch variant {
    case .personalized:
      return [
        Asset(key: "manifest", filename: "BuildManifest.plist", bytes: 801_505,
          sha256: "8edd4a2f4f4ef1fbd7bfe49785d8badc673d1395d1d94d85b132ca8ab5ecaf54"),
        Asset(key: "image", filename: "Image.dmg", bytes: 15_733_248,
          sha256: "05fd807da5e19f030fa4941f24800c965c6c77982ab572dd5d1ef778fb69f9ca"),
        Asset(key: "trustCache", filename: "Image.dmg.trustcache", bytes: 1_895,
          sha256: "36af60889ff5a737874a26daeb8e1a0139ebfebec6ec2e4d8f6a3c1bf1dce35c"),
      ]
    case .cryptex:
      return [
        Asset(key: "manifest", filename: "BuildManifest.plist", bytes: 804_946,
          sha256: "27385d7582b03b36bb3104e22b520aee0c47d72fecb4e8ecfe12ef5d966c7012"),
        Asset(key: "image", filename: "Image.dmg", bytes: 15_895_040,
          sha256: "873097f695a8b9734e2abc54f795a8874d40ff6fd11208ecb01ef29534c7c176"),
        Asset(key: "trustCache", filename: "Image.dmg.trustcache", bytes: 1_895,
          sha256: "f7f21986074eee03a215aca16ecfc78d6bf183600d8a0d2fb691f9896782e6f0"),
        Asset(key: "info", filename: "Image.dmg.cryptex_info", bytes: 430,
          sha256: "edf49aef55aacc063d4d7be05b713bb545ce2993b3f62bcc15eccd75e610ee6c"),
        Asset(key: "rootHash", filename: "Image.dmg.root_hash", bytes: 229,
          sha256: "3543fad2805b88119695c417e12679380b3b5a2742994bbcc839c8e2de5d7302"),
      ]
    }
  }

  static func source(_ variant: Variant, asset: Asset) -> URL {
    let directory = variant == .personalized ? "Xcode_iOS_DDI_Personalized" : "Xcode_iOS_DDI_Cryptex"
    // Exact commit and filenames; neither the model nor a channel argument can
    // select a host, URL, archive entry, hash, or destination path.
    return URL(string: "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/\(sourceCommit)/PersonalizedImages/\(directory)/\(asset.filename)")!
  }

  func status() -> [String: Any] {
    ["catalogId": Self.catalogID, "downloading": busy,
     "verifiedThisProcess": verified.map(\.rawValue).sorted()]
  }

  /// Internal FFI input. Rust independently opens anchored, no-follow FDs and
  /// verifies every byte; a previous Swift cache check grants no file authority.
  func nativeConfiguration() -> [String: Any] {
    var result: [String: Any] = ["catalogId": Self.catalogID, "directory": root.path]
    for variant in Variant.allCases {
      let directory = root.appendingPathComponent(variant.rawValue, isDirectory: true)
      if Self.assets(variant).allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.filename).path) }) {
        result[variant.rawValue] = Dictionary(uniqueKeysWithValues: Self.assets(variant).map { ($0.key, $0.sha256) })
      }
    }
    return result
  }

  func prepare(_ variant: Variant,
               progress: @escaping @MainActor (Int64, Int64) -> Void) async throws {
    guard !busy else { throw IOSPhoneDDIError.unavailable }
    busy = true
    let preparation = UUID()
    progressID = preparation; progressCompleted = 0
    defer { busy = false; if progressID == preparation { progressID = nil } }
    let directory = try IOSPhoneDDIDirectory.openPath(anchor: anchor, components: components + [variant.rawValue])
    let assets = Self.assets(variant)
    let total = assets.reduce(Int64(0)) { $0 + $1.bytes }
    var completed: Int64 = 0
    report(completed, total: total, id: preparation, sink: progress)
    for asset in assets {
      try Task.checkCancellation()
      let cached = try? await Self.verifyOnWorker { try directory.verify(asset) }
      // A cancelled verifier is not a cache miss that may start a download.
      try Task.checkCancellation()
      if cached == true {
        completed += asset.bytes; report(completed, total: total, id: preparation, sink: progress); continue
      }
      let temporary = ".download-" + UUID().uuidString
      defer { directory.remove(temporary) }
      let before = completed
      let transfer = IOSPhoneDDITransfer(source: Self.source(variant, asset: asset), directory: directory, temporary: temporary,
        asset: asset, progress: { [weak self] received in
          Task { @MainActor in self?.report(before + received, total: total, id: preparation, sink: progress) }
        })
      try await transfer.run()
      try Task.checkCancellation()
      // Each immutable catalog file is individually published atomically. A
      // cancelled partial bundle is never accepted by Rust's all-file checks.
      try directory.publish(temporary, as: asset.filename)
      completed += asset.bytes; report(completed, total: total, id: preparation, sink: progress)
    }
    verified.insert(variant)
  }

  private func report(_ completed: Int64, total: Int64, id: UUID,
                      sink: @MainActor (Int64, Int64) -> Void) {
    guard progressID == id else { return }
    progressCompleted = max(progressCompleted, min(total, completed))
    sink(progressCompleted, total)
  }

  /// The caller retains its busy gate and directory capability until this
  /// worker has joined, including cancellation. No verification result is
  /// accepted after cancellation; a blocking filesystem call can still finish
  /// before the next cooperative check. This never grants Rust file authority.
  nonisolated static func verifyOnWorker(_ work: @escaping @Sendable () throws -> Bool) async throws -> Bool {
    try Task.checkCancellation()
    let worker = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      let verified = try work()
      try Task.checkCancellation()
      return verified
    }
    let verified = try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
    try Task.checkCancellation()
    return verified
  }

  nonisolated static func verify(_ url: URL, asset: Asset) throws -> Bool {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw IOSPhoneDDIError.cache }
    defer { close(descriptor) }
    return try verifyDescriptor(descriptor, asset: asset)
  }

  nonisolated static func verifyDescriptor(_ descriptor: Int32, asset: Asset, copyTo output: Int32? = nil) throws -> Bool {
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size == asset.bytes else { throw IOSPhoneDDIError.integrity }
    var digest = SHA256()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    var received: Int64 = 0
    while true {
      try Task.checkCancellation()
      let count = buffer.withUnsafeMutableBytes { raw in
        Darwin.read(descriptor, raw.baseAddress, raw.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw IOSPhoneDDIError.cache
      }
      received += Int64(count)
      guard received <= asset.bytes else { throw IOSPhoneDDIError.integrity }
      digest.update(data: Data(buffer.prefix(count)))
      if let output {
        try buffer.withUnsafeBytes { raw in
          var offset = 0
          while offset < count {
            let written = Darwin.write(output, raw.baseAddress!.advanced(by: offset), count - offset)
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw IOSPhoneDDIError.cache }
            offset += written
          }
        }
      }
    }
    let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    guard received == asset.bytes, hash == asset.sha256 else { throw IOSPhoneDDIError.integrity }
    return true
  }
}

/// Retained across every await and delegate callback. All cache mutations use
/// this directory capability, never a path re-resolved after network activity.
/// A swapped ancestor/symlink cannot redirect writes into another directory.
private final class IOSPhoneDDIDirectory: @unchecked Sendable {
  private let descriptor: Int32
  private init(_ descriptor: Int32) { self.descriptor = descriptor }
  deinit { close(descriptor) }

  static func openPath(anchor: URL, components: [String]) throws -> IOSPhoneDDIDirectory {
    guard anchor.isFileURL, anchor.path.hasPrefix("/"), !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") }) else {
      throw IOSPhoneDDIError.cache
    }
    // Start at the app container itself. Opening its ancestors would ask for
    // directory access that the iOS sandbox does not grant to the application.
    var parent = open(anchor.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard parent >= 0 else { throw IOSPhoneDDIError.cache }
    do {
      for name in components {
        var child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if child < 0, errno == ENOENT {
          guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw IOSPhoneDDIError.cache }
          child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard child >= 0 else { throw IOSPhoneDDIError.cache }
        close(parent); parent = child
      }
      return IOSPhoneDDIDirectory(parent)
    } catch { close(parent); throw error }
  }

  func verify(_ asset: IOSPhoneDDICache.Asset) throws -> Bool {
    let input = openat(descriptor, asset.filename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard input >= 0 else { throw IOSPhoneDDIError.cache }
    defer { close(input) }
    return try IOSPhoneDDICache.verifyDescriptor(input, asset: asset)
  }

  func create(_ temporary: String) throws -> Int32 {
    let output = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard output >= 0 else { throw IOSPhoneDDIError.cache }
    return output
  }

  func publish(_ temporary: String, as name: String) throws {
    guard renameat(descriptor, temporary, descriptor, name) == 0, fsync(descriptor) == 0 else {
      throw IOSPhoneDDIError.cache
    }
  }

  func remove(_ temporary: String) { _ = unlinkat(descriptor, temporary, 0) }
}

/// URLSession owns the temporary public-asset file. No unbounded in-memory
/// response and no redirects/cookies/credentials; progress is actual bytes.
private final class IOSPhoneDDITransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let source: URL
  private let directory: IOSPhoneDDIDirectory
  private let temporary: String
  private let asset: IOSPhoneDDICache.Asset
  private let progress: @Sendable (Int64) -> Void
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  private var task: URLSessionDownloadTask?
  private var cancelled = false
  private var completed = false
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 600
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }()

  init(source: URL, directory: IOSPhoneDDIDirectory, temporary: String, asset: IOSPhoneDDICache.Asset,
       progress: @escaping @Sendable (Int64) -> Void) {
    self.source = source; self.directory = directory; self.temporary = temporary
    self.asset = asset; self.progress = progress
    super.init()
  }

  func run() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (value: CheckedContinuation<Void, Error>) in
        lock.lock()
        if cancelled {
          lock.unlock(); value.resume(throwing: IOSPhoneDDIError.cancelled); return
        }
        continuation = value
        let download = session.downloadTask(with: source)
        task = download
        lock.unlock()
        download.resume()
      }
    } onCancel: { self.cancel() }
  }

  private func cancel() {
    lock.lock(); cancelled = true; let active = task; lock.unlock()
    active?.cancel()
    finish(.failure(IOSPhoneDDIError.cancelled))
  }

  private func finish(_ result: Result<Void, Error>) {
    lock.lock()
    guard !completed, let callback = continuation else { lock.unlock(); return }
    completed = true; continuation = nil; task = nil
    lock.unlock()
    session.invalidateAndCancel()
    callback.resume(with: result)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                  totalBytesExpectedToWrite: Int64) {
    lock.lock(); let inactive = cancelled || completed; lock.unlock()
    guard !inactive else { return }
    guard totalBytesWritten <= asset.bytes,
      totalBytesExpectedToWrite < 0 || totalBytesExpectedToWrite == asset.bytes else {
      downloadTask.cancel(); finish(.failure(IOSPhoneDDIError.integrity)); return
    }
    progress(totalBytesWritten)
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didFinishDownloadingTo location: URL) {
    do {
      guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
        response.url == source else { throw IOSPhoneDDIError.unavailable }
      lock.lock(); let wasCancelled = cancelled || completed; lock.unlock()
      guard !wasCancelled else { throw IOSPhoneDDIError.cancelled }
      lock.lock()
      if cancelled || completed { lock.unlock(); throw IOSPhoneDDIError.cancelled }
      let output: Int32
      do { output = try directory.create(temporary) }
      catch { lock.unlock(); throw error }
      lock.unlock()
      defer { close(output) }
      let input = open(location.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      guard input >= 0 else { throw IOSPhoneDDIError.cache }
      defer { close(input) }
      _ = try IOSPhoneDDICache.verifyDescriptor(input, asset: asset, copyTo: output)
      guard fsync(output) == 0 else { throw IOSPhoneDDIError.cache }
      lock.lock(); let abandoned = cancelled || completed; lock.unlock()
      if abandoned { directory.remove(temporary); throw IOSPhoneDDIError.cancelled }
      finish(.success(()))
    } catch {
      directory.remove(temporary)
      finish(.failure(error as? IOSPhoneDDIError ?? IOSPhoneDDIError.unavailable))
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if error != nil { finish(.failure(IOSPhoneDDIError.unavailable)) }
  }
}
