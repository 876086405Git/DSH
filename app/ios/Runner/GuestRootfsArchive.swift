// Apple SDK compilation and device execution have not been verified.
#if canImport(CryptoKit)
import CryptoKit
#endif
#if os(Linux)
import Glibc
#endif
import Foundation
import SQLite3
import zlib

struct GuestFailure: Error {
  let code: String
  let message: String
  init(_ code: String, _ message: String) { self.code = "ios_guest_" + code; self.message = message }
}

final class GuestCancellation {
  private let lock = NSLock()
  private var cancelled = false
  private var publishing = false
  private var cancellationHandler: (() -> Void)?
  func cancel() -> Bool {
    lock.lock()
    guard !publishing else { lock.unlock(); return false }
    cancelled = true
    let handler = cancellationHandler
    lock.unlock()
    handler?()
    return true
  }
  func onCancel(_ handler: (() -> Void)?) {
    lock.lock(); cancellationHandler = handler; let callNow = cancelled; lock.unlock()
    if callNow { handler?() }
  }
  func check() throws {
    lock.lock(); defer { lock.unlock() }
    if cancelled { throw GuestFailure("cancelled", "Linux installation cancelled.") }
  }
  func beginPublish() throws {
    lock.lock(); defer { lock.unlock() }
    if cancelled { throw GuestFailure("cancelled", "Linux installation cancelled.") }
    publishing = true
  }
}

/// Accepts only the pinned GNU tar profile, not arbitrary archives. Guest links
/// are regular host files; their Linux type and ownership live in meta.db.
struct GuestRootfsArchive {
  static let version = "3.24.4"
  static let downloadURL = URL(string: "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-minirootfs-3.24.4-aarch64.tar.gz")!
  static let sha256 = "4b14c18f7e90a063b61462ea1462a5732c154bf6adad594974fe6487cd98a8de"
  static let compressedBytes: Int64 = 4_029_843
  static let tarBytes = 8_939_520
  static let memberCount = 515
  static let regularBytes = 8_652_280
  typealias Progress = (String, Int64, Int64) -> Void

  static func verify(_ url: URL, cancel: GuestCancellation, progress: Progress) throws {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var digest = SHA256()
    var count: Int64 = 0
    while let data = try file.read(upToCount: 256 * 1024), !data.isEmpty {
      try cancel.check()
      count += Int64(data.count)
      guard count <= compressedBytes else { throw GuestFailure("checksum", "Linux archive size mismatch.") }
      digest.update(data: data)
      progress("verify", count, compressedBytes)
    }
    let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()
    guard count == compressedBytes, hex == sha256 else {
      throw GuestFailure("checksum", "Linux archive checksum mismatch.")
    }
  }

  /// Caller must provide a newly created, unpublished and exclusively owned stage.
  static func extract(_ url: URL, to stage: URL, cancel: GuestCancellation, progress: Progress) throws {
    let files = FileManager.default
    let dataRoot = stage.appendingPathComponent("data", isDirectory: true)
    try files.createDirectory(at: dataRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let database = try GuestMetadata(stage.appendingPathComponent("meta.db"))
    defer { database.close() }
    let input = try GuestGzipReader(url)
    defer { input.close() }
    var paths: [String: UInt32] = [:]
    var count = 0
    var ordinaryBytes = 0
    while true {
      try cancel.check()
      let header = try input.readExactly(512)
      if header.allSatisfy({ $0 == 0 }) {
        guard try input.readExactly(512).allSatisfy({ $0 == 0 }) else {
          throw GuestFailure("archive", "Invalid tar end marker.")
        }
        try input.requireEnd()
        break
      }
      let h = [UInt8](header)
      guard Array(h[257..<265]) == Array("ustar  \0".utf8) else {
        throw GuestFailure("archive", "Unsupported tar format.")
      }
      let checksum = try number(h, 148..<156)
      let actual = h.enumerated().reduce(UInt64(0)) { $0 + UInt64((148..<156).contains($1.offset) ? 32 : $1.element) }
      guard checksum == actual else { throw GuestFailure("archive", "Invalid tar header checksum.") }
      // This GNU profile has no USTAR prefix field (the bytes have GNU meaning).
      let name = try field(h, 0..<100)
      let path = try normalized(name)
      guard paths[path] == nil else { throw GuestFailure("archive", "Duplicate tar member.") }
      let size = try number(h, 124..<136)
      let permission = try number(h, 100..<108)
      let uid = try number(h, 108..<116)
      let gid = try number(h, 116..<124)
      let mtime = try number(h, 136..<148)
      guard size <= UInt64(regularBytes), permission <= 0o7777,
        uid <= UInt32.max, gid <= UInt32.max, mtime <= UInt64(Int64.max) else {
        throw GuestFailure("archive", "Tar member metadata exceeds limits.")
      }
      let type: UInt32
      switch h[156] {
      case 48: type = 0o100000
      case 53: type = 0o040000
      case 50: type = 0o120000
      default: throw GuestFailure("archive", "Unsupported tar member type.")
      }
      guard type == 0o100000 || size == 0, !path.isEmpty || type == 0o040000 else {
        throw GuestFailure("archive", "Invalid tar member size or root type.")
      }
      // The pinned archive lists parents first. No symlinks are made on the host.
      if !path.isEmpty {
        let parent = path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
        guard paths[parent] == 0o040000 else { throw GuestFailure("archive", "Missing directory parent.") }
      }
      let target = path.isEmpty ? dataRoot : dataRoot.appendingPathComponent(String(path.dropFirst()))
      if type == 0o040000 {
        if !path.isEmpty {
          try files.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
      } else {
        let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw posixFailure("Cannot create Linux image member.") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
          if type == 0o120000 {
            let link = try field(h, 157..<257)
            guard !link.isEmpty else { throw GuestFailure("archive", "Empty guest symbolic link.") }
            try output.write(contentsOf: Data(link.utf8))
          } else {
            var remaining = Int(size)
            ordinaryBytes += remaining
            guard ordinaryBytes <= regularBytes else { throw GuestFailure("archive", "Excessive extracted data.") }
            while remaining > 0 {
              try cancel.check()
              let bytes = try input.readExactly(min(remaining, 64 * 1024))
              try output.write(contentsOf: bytes)
              remaining -= bytes.count
            }
            let padding = (512 - Int(size) % 512) % 512
            if padding > 0 { _ = try input.readExactly(padding) }
          }
          try output.close()
        } catch {
          try? output.close()
          throw error
        }
      }
      try files.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(mtime))], ofItemAtPath: target.path)
      try database.insert(path: path, mode: type | UInt32(permission), uid: UInt32(uid), gid: UInt32(gid))
      paths[path] = type
      count += 1
      guard count <= memberCount else { throw GuestFailure("archive", "Too many tar members.") }
      progress("extract", Int64(count), Int64(memberCount))
    }
    guard count == memberCount, ordinaryBytes == regularBytes, paths[""] == 0o040000,
      input.produced == tarBytes else { throw GuestFailure("archive", "Incomplete Linux image.") }
    try cancel.check()
    try database.commit()
  }

  private static func field(_ h: [UInt8], _ range: Range<Int>) throws -> String {
    let bytes = h[range].prefix { $0 != 0 }
    guard let text = String(bytes: bytes, encoding: .utf8) else { throw GuestFailure("archive", "Invalid tar text.") }
    return text
  }
  private static func number(_ h: [UInt8], _ range: Range<Int>) throws -> UInt64 {
    let bytes = h[range]
    var value: UInt64 = 0
    var ended = false
    var begun = false
    for byte in bytes {
      if byte == 0 || byte == 32 {
        if begun { ended = true }
        continue
      }
      guard !ended, byte >= 48, byte <= 55, value <= (UInt64.max - UInt64(byte - 48)) / 8 else {
        throw GuestFailure("archive", "Invalid tar numeric field.")
      }
      begun = true
      value = value * 8 + UInt64(byte - 48)
    }
    return value
  }
  private static func normalized(_ name: String) throws -> String {
    guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else {
      throw GuestFailure("archive", "Invalid tar path.")
    }
    var name = name
    if name.hasPrefix("./") { name.removeFirst(2) }
    if name == "." { name = "" }
    if name.hasSuffix("/") { name.removeLast() }
    if name.isEmpty { return "" }
    let pieces = name.split(separator: "/", omittingEmptySubsequences: false)
    guard pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), name.utf8.count < 4095 else {
      throw GuestFailure("archive", "Invalid tar path components.")
    }
    return "/" + name
  }
}

private final class GuestGzipReader {
  private var file: gzFile?
  private(set) var produced = 0
  init(_ url: URL) throws {
    file = gzopen(url.path, "rb")
    guard file != nil else { throw GuestFailure("archive", "Cannot open compressed Linux image.") }
  }
  func close() { if let file { gzclose(file); self.file = nil } }
  func readExactly(_ count: Int) throws -> Data {
    guard let file, produced <= GuestRootfsArchive.tarBytes - count else {
      throw GuestFailure("archive", "Linux image exceeds its size limit.")
    }
    var data = Data(count: count)
    var offset = 0
    try data.withUnsafeMutableBytes { raw in
      while offset < count {
        let n = gzread(file, raw.baseAddress!.advanced(by: offset), UInt32(count - offset))
        guard n > 0 else { throw GuestFailure("archive", "Truncated or invalid gzip stream.") }
        offset += Int(n)
      }
    }
    produced += count
    return data
  }
  func requireEnd() throws {
    guard let file else { throw GuestFailure("archive", "Closed gzip stream.") }
    var byte: UInt8 = 0
    let n = gzread(file, &byte, 1)
    guard n == 0, gzeof(file) != 0 else { throw GuestFailure("archive", "Unexpected gzip trailer or tar data.") }
    var error: Int32 = 0
    _ = gzerror(file, &error)
    guard error == Z_OK || error == Z_STREAM_END else { throw GuestFailure("archive", "Invalid gzip checksum.") }
  }
}

private final class GuestMetadata {
  private var db: OpaquePointer?
  private var stat: OpaquePointer?
  private var path: OpaquePointer?
  private var committed = false
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  init(_ url: URL) throws {
    let opened = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    guard opened == SQLITE_OK else {
      let noSpace = opened & 0xff == SQLITE_FULL || db.map { sqlite3_system_errno($0) == ENOSPC } == true
      if let db { sqlite3_close(db) }; db = nil
      throw GuestFailure(noSpace ? "no_space" : "io", "Cannot create Linux metadata database.")
    }
    do {
      try execute("PRAGMA journal_mode=DELETE; PRAGMA foreign_keys=ON; BEGIN IMMEDIATE; CREATE TABLE meta(id INTEGER UNIQUE DEFAULT 0, db_inode INTEGER); INSERT INTO meta(db_inode) VALUES(0); CREATE TABLE stats(inode INTEGER PRIMARY KEY, stat BLOB); CREATE TABLE paths(path BLOB PRIMARY KEY, inode INTEGER REFERENCES stats(inode)); CREATE INDEX inode_to_path ON paths(inode,path); PRAGMA user_version=3;")
      try checked(sqlite3_prepare_v2(db, "INSERT INTO stats(stat) VALUES(?)", -1, &stat, nil))
      try checked(sqlite3_prepare_v2(db, "INSERT INTO paths(path,inode) VALUES(?,?)", -1, &path, nil))
    } catch { close(); throw error }
  }
  private func checked(_ code: Int32) throws {
    guard code == SQLITE_OK || code == SQLITE_DONE else {
      let noSpace = code & 0xff == SQLITE_FULL || sqlite3_system_errno(db) == ENOSPC
      throw GuestFailure(noSpace ? "no_space" : "io", "Cannot write Linux metadata database.")
    }
  }
  private func execute(_ sql: String) throws { try checked(sqlite3_exec(db, sql, nil, nil, nil)) }
  func insert(path name: String, mode: UInt32, uid: UInt32, gid: UInt32) throws {
    var bytes = [UInt8]()
    for value in [mode, uid, gid, UInt32(0)] {
      for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    try bytes.withUnsafeBytes { try checked(sqlite3_bind_blob(stat, 1, $0.baseAddress, 16, transient)) }
    try checked(sqlite3_step(stat)); try checked(sqlite3_reset(stat))
    let inode = sqlite3_last_insert_rowid(db)
    if name.isEmpty { try checked(sqlite3_bind_zeroblob(path, 1, 0)) }
    else {
      let encoded = Array(name.utf8)
      try encoded.withUnsafeBytes { try checked(sqlite3_bind_blob(path, 1, $0.baseAddress, Int32($0.count), transient)) }
    }
    try checked(sqlite3_bind_int64(path, 2, inode))
    try checked(sqlite3_step(path)); try checked(sqlite3_reset(path))
  }
  func commit() throws {
    try execute("COMMIT")
    committed = true
    sqlite3_finalize(stat); stat = nil
    sqlite3_finalize(path); path = nil
    try checked(sqlite3_close(db)); db = nil
  }
  func close() {
    sqlite3_finalize(stat); stat = nil
    sqlite3_finalize(path); path = nil
    if let db {
      if !committed { _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
      sqlite3_close(db); self.db = nil
    }
  }
}
