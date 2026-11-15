import Compression
import CryptoKit
import Foundation

struct EngineFailure: Error {
  let code: String
  let message: String
  init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
}

struct RuntimeFile: Codable, Equatable {
  let path: String
  let size: Int
  let sha256: String
}

struct RuntimeManifest: Codable {
  let schema: Int
  let runtimeVersion: String
  let dshVersion: String
  let nodeVersion: String
  let files: [RuntimeFile]

  func validated() throws -> RuntimeManifest {
    guard schema == 1, !runtimeVersion.isEmpty, nodeVersion == "24.22.1", !files.isEmpty else {
      throw EngineFailure("ios_manifest_invalid", "运行时清单的版本或文件列表无效。")
    }
    var paths = Set<String>()
    for file in files {
      guard RuntimeManifest.safePath(file.path), file.size >= 0, RuntimeManifest.isSha256(file.sha256),
        paths.insert(file.path).inserted
      else {
        throw EngineFailure("ios_manifest_invalid", "运行时清单含无效路径、原生文件或校验字段。")
      }
    }
    for path in paths {
      var parent = Substring(path)
      while let slash = parent.lastIndex(of: "/") {
        parent = parent[..<slash]
        if paths.contains(String(parent)) {
          throw EngineFailure("ios_manifest_invalid", "运行时清单的文件与目录路径冲突。")
        }
      }
    }
    for entry in RuntimeManifest.entries where !paths.contains(entry) {
      throw EngineFailure("ios_manifest_invalid", "运行时缺少固定启动入口。")
    }
    return self
  }

  private static let entries = [
    "node_modules/@deepseek-ai/dsh/lib/bin.js", "runtime/ohos/preload.mjs",
    "runtime/ohos/process/index.mjs", "runtime/ohos/process/sandbox.mjs",
    "runtime/ohos/lifecycle/index.mjs", "runtime/ohos/capabilities/index.mjs",
    "runtime/bridge/dsh-go-bridge/lib/index.js", "runtime/ohos/process/child-process.mjs",
  ]

  static func safePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.contains("\\"), !path.contains("\0") else { return false }
    if path.split(separator: "/", omittingEmptySubsequences: false)
      .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    {
      return false
    }
    // Native code lives in the signed bundle, never in writable data.
    return path.range(of: #"(\.node|\.so(\.[0-9]+)*|\.dylib)$"#, options: [.regularExpression, .caseInsensitive]) == nil
  }

  static func isSha256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

/// The bundled archive: the fixed ZIP32 profile compose-runtime.py writes, not a general
/// extractor. The first member is a Stored manifest and the rest are Deflate.
final class RuntimeArchive {
  private struct Entry {
    let flags: UInt16
    let method: UInt16
    let packedSize: Int
    let size: Int
    let dataOffset: Int
  }

  let manifest: RuntimeManifest
  private let bytes: Data
  private let entries: [String: Entry]

  private static let maxDirectory = 32 * 1024 * 1024
  private static let maxManifest = 16 * 1024 * 1024
  private static let maxFile = 512 * 1024 * 1024
  private static let maxName = 4096

  init(url: URL) throws {
    let bytes: Data
    do {
      // Mapped: the pages are file-backed, so a 50 MB archive doesn't count against the app.
      bytes = try Data(contentsOf: url, options: .alwaysMapped)
    } catch {
      throw EngineFailure("ios_payload_missing", "App 里没有运行时载荷。")
    }
    self.bytes = bytes
    let invalid = EngineFailure("ios_archive_invalid", "随包运行时归档的格式、索引或清单不一致。")
    func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    guard bytes.count >= 22, bytes.count <= 0x7fff_ffff else { throw invalid }
    let footer = bytes.count - 22
    guard u32(footer) == 0x0605_4b50, u16(footer + 4) == 0, u16(footer + 6) == 0, u16(footer + 20) == 0 else {
      throw invalid
    }
    let count = u16(footer + 10)
    let directorySize = u32(footer + 12)
    let directoryOffset = u32(footer + 16)
    guard count >= 2, count != 0xffff, u16(footer + 8) == count, directorySize <= RuntimeArchive.maxDirectory,
      directorySize >= count * 46, directoryOffset + directorySize == footer
    else { throw invalid }

    var entries: [String: Entry] = [:]
    var ordered: [(name: String, entry: Entry)] = []
    ordered.reserveCapacity(count)
    var cursor = directoryOffset
    var nextHeader = 0
    for index in 0..<count {
      guard cursor + 46 <= footer, u32(cursor) == 0x0201_4b50, u16(cursor + 6) <= 20, u16(cursor + 30) == 0,
        u16(cursor + 32) == 0, u16(cursor + 34) == 0, u16(cursor + 36) == 0
      else { throw invalid }
      let flags = UInt16(u16(cursor + 8))
      let method = UInt16(u16(cursor + 10))
      let packedSize = u32(cursor + 20)
      let size = u32(cursor + 24)
      let nameLength = u16(cursor + 28)
      let headerOffset = u32(cursor + 42)
      guard (flags == 0 || flags == 0x800), nameLength > 0, nameLength <= RuntimeArchive.maxName,
        headerOffset == nextHeader, size <= RuntimeArchive.maxFile, cursor + 46 + nameLength <= footer,
        let name = String(data: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8),
        entries[name] == nil, !name.contains("\0"), !name.contains("\\")
      else { throw invalid }
      if index == 0 {
        guard name == "manifest.json", method == 0, size <= RuntimeArchive.maxManifest, size == packedSize else {
          throw invalid
        }
      } else {
        guard name.hasPrefix("files/"), method == 8 else { throw invalid }
      }
      // Every local header too: no hidden prefix, gaps, duplicate records or extras.
      guard headerOffset + 30 + nameLength <= directoryOffset, u32(headerOffset) == 0x0403_4b50,
        u16(headerOffset + 6) == Int(flags), u16(headerOffset + 8) == Int(method),
        u32(headerOffset + 18) == packedSize, u32(headerOffset + 22) == size,
        u16(headerOffset + 26) == nameLength, u16(headerOffset + 28) == 0
      else { throw invalid }
      let dataOffset = headerOffset + 30 + nameLength
      guard dataOffset + packedSize <= directoryOffset else { throw invalid }
      nextHeader = dataOffset + packedSize
      let entry = Entry(flags: flags, method: method, packedSize: packedSize, size: size, dataOffset: dataOffset)
      entries[name] = entry
      ordered.append((name, entry))
      cursor += 46 + nameLength
    }
    guard cursor == footer, nextHeader == directoryOffset else { throw invalid }

    let first = ordered[0].entry
    let manifest: RuntimeManifest
    do {
      manifest = try JSONDecoder()
        .decode(RuntimeManifest.self, from: bytes[first.dataOffset..<(first.dataOffset + first.size)]).validated()
    } catch {
      throw invalid
    }
    guard manifest.files.count == count - 1 else { throw invalid }
    for (index, file) in manifest.files.enumerated() {
      let member = ordered[index + 1]
      guard member.name == "files/" + file.path, member.entry.size == file.size else { throw invalid }
    }
    self.manifest = manifest
    self.entries = entries
  }

  /// Inflates a member to `target`. The installer checks the digest afterwards; this
  /// checks size and that no native code gets into writable data.
  func extract(_ file: RuntimeFile, to target: URL) throws {
    guard let entry = entries["files/" + file.path], entry.size == file.size else {
      throw EngineFailure("ios_archive_invalid", "随包运行时归档缺少清单中的文件。")
    }
    FileManager.default.createFile(atPath: target.path, contents: nil)
    let output = try FileHandle(forWritingTo: target)
    defer { try? output.close() }
    let chunk = 256 * 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
    defer { buffer.deallocate() }
    let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    defer { stream.deallocate() }
    guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
      throw EngineFailure("ios_archive_inflate", "运行时解压初始化失败。")
    }
    defer { compression_stream_destroy(stream) }
    var produced = 0
    var checkedMagic = false
    try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
        throw EngineFailure("ios_archive_inflate", "运行时压缩流未正常结束。")
      }
      stream.pointee.src_ptr = UnsafePointer(base + entry.dataOffset)
      stream.pointee.src_size = entry.packedSize
      repeat {
        stream.pointee.dst_ptr = buffer
        stream.pointee.dst_size = chunk
        let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
        guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
          throw EngineFailure("ios_archive_inflate", "运行时压缩流未正常结束。")
        }
        let count = chunk - stream.pointee.dst_size
        produced += count
        guard produced <= entry.size else {
          throw EngineFailure("ios_size_mismatch", "运行时解压长度超过清单。")
        }
        if !checkedMagic, count >= 4 {
          checkedMagic = true
          let magic = UInt32(buffer[0]) | UInt32(buffer[1]) << 8 | UInt32(buffer[2]) << 16 | UInt32(buffer[3]) << 24
          if [0x464c_457f, 0xfeed_facf, 0xcefa_edfe, 0xcffa_edfe, 0xbeba_feca].contains(magic) {
            throw EngineFailure("ios_native_payload", "原生代码必须随 App 签名交付，不能落到可写目录。")
          }
        }
        if count > 0 { try output.write(contentsOf: Data(bytesNoCopy: buffer, count: count, deallocator: .none)) }
        if status == COMPRESSION_STATUS_END { break }
        guard count > 0 || stream.pointee.src_size > 0 else {
          throw EngineFailure("ios_archive_inflate", "运行时压缩流未正常结束。")
        }
      } while true
    }
    guard produced == entry.size, stream.pointee.src_size == 0 else {
      throw EngineFailure("ios_checksum_failed", "运行时归档成员的长度校验失败。")
    }
  }
}

/// Fixed code directory, a journal of what the install owns, and one atomic replace per
/// file: an upgrade writes only what changed, and an interrupted one refuses to start
/// until it has finished.
final class RuntimeInstaller {
  private struct Journal: Codable {
    let schema: Int
    let runtimeVersion: String
    let ownedPaths: [String]
    let stagingHashes: [String]
  }

  let base: URL
  let root: URL
  private let files = FileManager.default

  init(base: URL) {
    self.base = base
    root = base.appendingPathComponent("tree", isDirectory: true)
  }

  var interrupted: Bool { files.fileExists(atPath: base.appendingPathComponent("installing.json").path) }

  func installed() throws -> RuntimeManifest? {
    if interrupted { return nil }
    return try previous()
  }

  private func previous() throws -> RuntimeManifest? {
    let url = base.appendingPathComponent("installed.json")
    guard files.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: url)).validated()
  }

  func install(_ archive: RuntimeArchive, progress: (String, Int, Int) -> Void) throws {
    let manifest = archive.manifest
    let staging = base.appendingPathComponent("staging", isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    try files.createDirectory(at: staging, withIntermediateDirectories: true)

    var owned = Set(try previous()?.files.map(\.path) ?? [])
    var staged = Set<String>()
    let journalURL = base.appendingPathComponent("installing.json")
    if files.fileExists(atPath: journalURL.path) {
      let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
      guard journal.schema == 1, journal.ownedPaths.allSatisfy(RuntimeManifest.safePath),
        journal.stagingHashes.allSatisfy(RuntimeManifest.isSha256)
      else {
        throw EngineFailure("ios_install_journal_invalid", "安装归属记录损坏，未按猜测的路径删除文件。")
      }
      owned.formUnion(journal.ownedPaths)
      staged.formUnion(journal.stagingHashes)
    }
    for file in manifest.files {
      owned.insert(file.path)
      staged.insert(file.sha256)
    }
    let journal = Journal(
      schema: 1, runtimeVersion: manifest.runtimeVersion, ownedPaths: Array(owned), stagingHashes: Array(staged))
    try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)

    // An upgrade can turn a file into a directory or the other way round, so what's gone
    // takes its emptied parents with it. rmdir stops at anything this install doesn't own.
    let current = Set(manifest.files.map(\.path))
    for path in owned.lazy.filter({ !current.contains($0) }).sorted(by: { $0.count > $1.count }) {
      let file = root.appendingPathComponent(path)
      unlink(file.path)
      var parent = file.deletingLastPathComponent()
      while parent.path != root.path, rmdir(parent.path) == 0 {
        parent.deleteLastPathComponent()
      }
    }

    var changed: [RuntimeFile] = []
    for (index, file) in manifest.files.enumerated() {
      if !matches(root.appendingPathComponent(file.path), file) { changed.append(file) }
      progress("verify", index + 1, manifest.files.count)
    }
    let total = changed.reduce(0) { $0 + $1.size }
    var done = 0
    progress("extract", 0, total)
    for file in changed {
      let target = root.appendingPathComponent(file.path)
      let temporary = staging.appendingPathComponent(file.sha256 + ".tmp")
      try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try archive.extract(file, to: temporary)
      guard matches(temporary, file) else {
        throw EngineFailure("ios_checksum_failed", "随包运行时文件校验失败，安装未提交。")
      }
      guard rename(temporary.path, target.path) == 0 else {
        throw EngineFailure("ios_install_io", "运行时文件写入失败，请确认手机还有空间。")
      }
      done += file.size
      progress("extract", done, total)
    }
    progress("configure", 0, 1)
    try? files.removeItem(at: staging)
    try JSONEncoder().encode(manifest).write(to: base.appendingPathComponent("installed.json"), options: .atomic)
    try files.removeItem(at: journalURL)
    progress("configure", 1, 1)
  }

  private func matches(_ url: URL, _ file: RuntimeFile) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    var hasher = SHA256()
    var size = 0
    do {
      while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
        size += chunk.count
        if size > file.size { return false }
        hasher.update(data: chunk)
      }
    } catch {
      return false
    }
    guard size == file.size else { return false }
    let hex = Array("0123456789abcdef".utf8)
    var text: [UInt8] = []
    text.reserveCapacity(64)
    for byte in hasher.finalize() {
      text.append(hex[Int(byte >> 4)])
      text.append(hex[Int(byte & 15)])
    }
    return String(decoding: text, as: UTF8.self) == file.sha256
  }
}
