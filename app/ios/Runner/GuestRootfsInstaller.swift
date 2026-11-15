// Apple SDK compilation and device execution have not been verified.
import Foundation
#if os(Linux)
import FoundationNetworking
import Glibc
#endif

/// Implemented by the process-wide I2 owner. Acquiring this lease must atomically
/// exclude task admission, and must reject once a kernel has started in this app
/// process until a later I2 implementation proves complete kernel teardown.
protocol GuestRootfsLease: AnyObject { func release() }
protocol GuestKernelAccess: AnyObject {
  var available: Bool { get }
  /// Reads only the crash gate. A marker owned by a live task is not a crash.
  func isSuspended(in directory: URL) throws -> Bool
  /// Clears the durable gate atomically against native task admission. Existing
  /// engine snapshots stay unchanged; callers must restart the engine to apply it.
  func resume(in directory: URL) throws
  func reserveRootfsMutation() throws -> GuestRootfsLease
}

struct GuestInstalled: Codable {
  let schema: Int
  let version: String
  let archiveSHA256: String
  static var current: GuestInstalled {
    GuestInstalled(schema: 1, version: GuestRootfsArchive.version, archiveSHA256: GuestRootfsArchive.sha256)
  }
  var valid: Bool { schema == 1 && version == GuestRootfsArchive.version && archiveSHA256 == GuestRootfsArchive.sha256 }
}

final class GuestRootfsInstaller {
  let base: URL
  var root: URL { base.appendingPathComponent("rootfs", isDirectory: true) }
  private var archive: URL { base.appendingPathComponent("rootfs.tar.gz") }
  private var stage: URL { base.appendingPathComponent("staging", isDirectory: true) }
  private var trash: URL { base.appendingPathComponent("trash", isDirectory: true) }
  private let files = FileManager.default

  init(base: URL) { self.base = base }
  func installed() throws -> Bool {
    guard files.fileExists(atPath: root.path) else { return false }
    let marker = root.appendingPathComponent("installed.json")
    guard let bytes = try? Data(contentsOf: marker),
      let decoded = try? JSONDecoder().decode(GuestInstalled.self, from: bytes), decoded.valid,
      files.fileExists(atPath: root.appendingPathComponent("data").path),
      files.fileExists(atPath: root.appendingPathComponent("meta.db").path) else {
      throw GuestFailure("state_invalid", "Linux installation is incomplete; uninstall it before retrying.")
    }
    return true
  }

  /// Must run while holding the kernel mutation lease, on a background worker.
  func install(cancel: GuestCancellation, progress: @escaping GuestRootfsArchive.Progress) throws {
    if try installed() { return }
    try prepareBase()
    try removeIfPresent(stage)
    try removeIfPresent(trash)
    // Retry cached bytes only if their identity is the exact fixed archive.
    var verified = false
    if files.fileExists(atPath: archive.path) {
      do { try GuestRootfsArchive.verify(archive, cancel: cancel, progress: progress); verified = true }
      catch let failure as GuestFailure where failure.code == "ios_guest_checksum" { try removeIfPresent(archive) }
    }
    if !verified {
      try cancel.check()
      let downloaded = base.appendingPathComponent("download.part")
      try removeIfPresent(downloaded)
      defer { try? removeIfPresent(downloaded) }
      try GuestDownload().run(to: downloaded, cancel: cancel, progress: progress)
      try GuestRootfsArchive.verify(downloaded, cancel: cancel, progress: progress)
      // No valid archive exists at this point. Move within the same private base.
      try files.moveItem(at: downloaded, to: archive)
    }
    try cancel.check()
    try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      try GuestRootfsArchive.extract(archive, to: stage, cancel: cancel, progress: progress)
      try JSONEncoder().encode(GuestInstalled.current).write(to: stage.appendingPathComponent("installed.json"), options: .atomic)
      try cancel.beginPublish()
      progress("publish", 0, 1)
      // Destination is absent; one rename publishes data, database and marker.
      guard rename(stage.path, root.path) == 0 else { throw posixFailure("Cannot publish Linux installation.") }
      progress("publish", 1, 1)
    } catch {
      // Preserve the original failure if best-effort staging removal also fails.
      try? removeIfPresent(stage)
      throw error
    }
  }

  func uninstall() throws {
    try prepareBase()
    // Retry an interrupted deletion before moving the current tree.
    try removeIfPresent(trash)
    if files.fileExists(atPath: root.path) {
      guard rename(root.path, trash.path) == 0 else { throw posixFailure("Cannot detach Linux installation.") }
    }
    try removeIfPresent(trash)
    try removeIfPresent(stage)
    try removeIfPresent(archive)
    try removeIfPresent(base.appendingPathComponent("download.part"))
  }

  /// Logical bytes of owned files only, never follows guest or host symlinks.
  func usage() throws -> [String: Int64] {
    let installed = try size(root)
    let staging = try size(stage) + size(trash)
    let download = try size(archive) + size(base.appendingPathComponent("download.part"))
    return ["installedBytes": installed, "stagingBytes": staging, "downloadBytes": download,
      "totalBytes": installed + staging + download]
  }
  private func size(_ url: URL) throws -> Int64 {
    var info = stat()
    if lstat(url.path, &info) != 0 {
      if errno == ENOENT { return 0 }
      throw posixFailure("Cannot inspect Linux storage.")
    }
    if info.st_mode & S_IFMT == S_IFLNK { return Int64(info.st_size) }
    if info.st_mode & S_IFMT != S_IFDIR { return Int64(info.st_size) }
    var total: Int64 = 0
    for child in try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { total += try size(child) }
    return total
  }
  private func prepareBase() throws {
    try files.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var url = base
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }
  private func removeIfPresent(_ url: URL) throws {
    var info = stat()
    if lstat(url.path, &info) == 0 { try files.removeItem(at: url) }
    else if errno != ENOENT { throw posixFailure("Cannot inspect installation state.") }
  }
}

func posixFailure(_ message: String) -> GuestFailure {
  GuestFailure(errno == ENOSPC ? "no_space" : "io", message)
}
func guestFailure(_ error: Error) -> GuestFailure {
  if let failure = error as? GuestFailure { return failure }
  let ns = error as NSError
  if (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) ||
    (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError) {
    return GuestFailure("no_space", "Not enough space for Linux installation.")
  }
  if let nested = ns.userInfo[NSUnderlyingErrorKey] as? Error {
    let mapped = guestFailure(nested)
    if mapped.code == "ios_guest_no_space" { return mapped }
  }
  if ns.domain == NSURLErrorDomain {
    return GuestFailure(ns.code == NSURLErrorCancelled ? "cancelled" : "network", "Linux download did not complete.")
  }
  return GuestFailure("io", "Linux installation storage operation failed.")
}

/// A worker-blocking adapter around a serial delegate queue. The UI/state queue
/// stays available for status/cancel; all mutable download state is delegate-owned.
private final class GuestDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private var destination: URL!
  private var progress: GuestRootfsArchive.Progress!
  private var failure: Error?
  private var received = false
  private let done = DispatchSemaphore(value: 0)

  func run(to destination: URL, cancel: GuestCancellation, progress: @escaping GuestRootfsArchive.Progress) throws {
    self.destination = destination; self.progress = progress
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 300
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    let task = session.downloadTask(with: GuestRootfsArchive.downloadURL)
    cancel.onCancel { task.cancel() }
    defer { cancel.onCancel(nil); session.invalidateAndCancel() }
    try cancel.check()
    progress("download", 0, GuestRootfsArchive.compressedBytes)
    task.resume()
    done.wait()
    try cancel.check()
    if let failure { throw failure }
    guard received else { throw GuestFailure("network", "No Linux archive was downloaded.") }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) {
    guard request.url?.scheme == "https", request.url?.host == GuestRootfsArchive.downloadURL.host else {
      failure = GuestFailure("network", "Linux download redirected to an unexpected host.")
      completionHandler(nil); return
    }
    completionHandler(request)
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    if totalBytesWritten > GuestRootfsArchive.compressedBytes {
      failure = GuestFailure("checksum", "Linux download exceeds the fixed archive size.")
      downloadTask.cancel(); return
    }
    progress("download", totalBytesWritten, GuestRootfsArchive.compressedBytes)
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard failure == nil else { return }
    guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
      failure = GuestFailure("network", "Linux download returned an unsuccessful HTTP response."); return
    }
    do {
      try FileManager.default.moveItem(at: location, to: destination)
      received = true
    } catch { failure = error }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if failure == nil { failure = error }
    done.signal()
  }
}
