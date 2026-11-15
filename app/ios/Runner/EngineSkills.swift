import Foundation

/// Installs the app's four own skills into the engine's home, only while the engine that
/// asked is actually ready and the Flutter engine that asked is still attached. Files are
/// replaced one by one with SKILL.md last, so a cancelled install can be repaired by the
/// next one; there is no rollback. Same contract as Android and HarmonyOS.
final class EngineSkills {
  final class Owner {
    fileprivate(set) var attached = true
  }

  private final class Scope {
    let owner: Owner
    let runtimeGeneration: Int
    let token: String
    let generation: Int
    init(owner: Owner, runtimeGeneration: Int, token: String, generation: Int) {
      self.owner = owner
      self.runtimeGeneration = runtimeGeneration
      self.token = token
      self.generation = generation
    }
  }

  private struct Request {
    let id: String
    let expectedRoot: String
    let expectedToken: String
    let expectedGeneration: Int
    let name: String
    let files: [String: String]
  }

  private struct Outcome {
    var result: String?
    var reason: String?
  }

  private final class Job {
    let owner: Owner
    let request: Request
    let scopeCurrent: () -> Bool
    let reply: ([String: Any?]) -> Void
    var cancelled = false
    var responded = false
    init(owner: Owner, request: Request, current: @escaping () -> Bool, reply: @escaping ([String: Any?]) -> Void) {
      self.owner = owner
      self.request = request
      scopeCurrent = current
      self.reply = reply
    }
    var current: Bool { !cancelled && owner.attached && scopeCurrent() }
  }

  private struct Retired: Error {}

  private static let names: Set<String> = ["dsh-go-ui", "dsh-go-plugin", "dsh-go-guide", "dsh-go-support"]
  private static let maxFiles = 64
  private static let maxFileBytes = 512 * 1024
  private static let maxBytes = 1024 * 1024

  private let guestRoot: URL
  private let isCurrent: (Int, String) -> Bool
  /// Everything here runs on the controller's queue except the file work itself.
  private let queue: DispatchQueue
  private let io = DispatchQueue(label: "dsh.engine.skills", qos: .utility)

  private var owner: Owner?
  private var active: Scope?
  private var confirmedGeneration: Int?
  private var confirmedToken: String?
  private var stoppedGeneration = -1
  private var latestGeneration = -1
  private var serial = 0
  private var running: Job?
  private var pending: Job?

  init(guestRoot: URL, queue: DispatchQueue, isCurrent: @escaping (Int, String) -> Bool) {
    self.guestRoot = guestRoot
    self.queue = queue
    self.isCurrent = isCurrent
  }

  func attachOwner() -> Owner {
    let next = Owner()
    if let previous = owner {
      previous.attached = false
      cancel(previous)
    }
    owner = next
    active = nil
    grantReady()
    return next
  }

  func detach(_ owner: Owner) {
    owner.attached = false
    if self.owner === owner {
      self.owner = nil
      active = nil
    }
    cancel(owner)
  }

  func ready(runtimeGeneration: Int, token: String) {
    guard runtimeGeneration >= 0, !token.isEmpty, runtimeGeneration > stoppedGeneration,
      runtimeGeneration >= latestGeneration
    else { return }
    latestGeneration = runtimeGeneration
    confirmedGeneration = runtimeGeneration
    confirmedToken = token
    grantReady()
  }

  func stop(runtimeGeneration: Int) {
    stoppedGeneration = max(stoppedGeneration, runtimeGeneration)
    retire()
  }

  /// Call after stop retires all jobs. Earlier file work finishes before this runs.
  func afterWrites(_ work: @escaping () -> Void) {
    io.async(qos: .userInitiated) { work() }
  }

  func retire() {
    confirmedGeneration = nil
    confirmedToken = nil
    active = nil
  }

  func generation(for token: String?) -> Int? {
    guard let active, active.owner.attached, active.token == token else { return nil }
    return active.generation
  }

  private func grantReady() {
    guard let owner, owner.attached, let generation = confirmedGeneration, let token = confirmedToken else { return }
    if let active, active.owner === owner, active.runtimeGeneration == generation, active.token == token { return }
    serial += 1
    active = Scope(owner: owner, runtimeGeneration: generation, token: token, generation: serial)
  }

  func install(owner: Owner, arguments: [String: Any], reply: @escaping ([String: Any?]) -> Void) {
    guard let request = EngineSkills.parse(arguments) else {
      reply(["result": nil, "current": false, "reason": "invalid"])
      return
    }
    guard let scope = active, scope.owner === owner, owner.attached, scope.token == request.expectedToken,
      scope.generation == request.expectedGeneration
    else {
      reply(["result": nil, "current": false, "reason": "stale"])
      return
    }
    let job = Job(owner: owner, request: request, current: { [weak self, weak scope] in
      guard let self, let scope else { return false }
      return self.active === scope && scope.owner.attached && self.isCurrent(scope.runtimeGeneration, scope.token)
    }, reply: reply)
    guard job.current else {
      respond(job, Outcome(result: nil, reason: "stale"))
      return
    }
    if (running?.owner === owner && running?.request.id == request.id)
      || (pending?.owner === owner && pending?.request.id == request.id)
    {
      respond(job, Outcome(result: nil, reason: "duplicate"))
      return
    }
    if running == nil {
      running = job
      schedule(job)
    } else {
      let replaced = pending
      pending = job
      if let replaced {
        replaced.cancelled = true
        respond(replaced, Outcome(result: nil, reason: "cancelled"))
      }
    }
  }

  func cancel(_ owner: Owner, requestId: String? = nil) {
    if let job = running, job.owner === owner, requestId == nil || job.request.id == requestId {
      job.cancelled = true
      respond(job, Outcome(result: nil, reason: "cancelled"))
    }
    if let job = pending, job.owner === owner, requestId == nil || job.request.id == requestId {
      job.cancelled = true
      pending = nil
      respond(job, Outcome(result: nil, reason: "cancelled"))
    }
  }

  private func schedule(_ job: Job) {
    // The permission check hops back to the controller's queue, so a stop that arrives
    // during the IO retires the next write, not only the next job.
    let current: () -> Bool = { [queue] in queue.sync { job.current } }
    io.async { [self] in
      let outcome = run(job.request, current: current)
      queue.async { [self] in
        respond(job, outcome)
        if running === job {
          running = pending
          pending = nil
          if let next = running { schedule(next) }
        }
      }
    }
  }

  private func respond(_ job: Job, _ outcome: Outcome) {
    guard !job.responded else { return }
    job.responded = true
    let current = job.current && outcome.reason != "stale" && outcome.reason != "cancelled"
    job.reply(["result": outcome.result, "current": current, "reason": current ? outcome.reason : "stale"])
  }

  private static func parse(_ raw: [String: Any]) -> Request? {
    guard let id = raw["requestId"] as? String, !id.isEmpty, id.utf16.count <= 200,
      let root = raw["expectedRoot"] as? String, !root.isEmpty, root.utf16.count <= 4096,
      let token = raw["expectedToken"] as? String, !token.isEmpty, token.utf16.count <= 4096,
      let generation = (raw["expectedGeneration"] as? NSNumber)?.intValue, generation >= 1,
      let name = raw["name"] as? String, names.contains(name),
      let files = raw["files"] as? [String: Any], !files.isEmpty, files.count <= maxFiles
    else { return nil }
    var checked: [String: String] = [:]
    var units = 0
    for (path, value) in files {
      guard let text = value as? String, path.utf16.count <= 512,
        path.range(of: #"^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$"#, options: .regularExpression)
          != nil,
        text.utf16.count <= maxFileBytes
      else { return nil }
      units += text.utf16.count
      if units > maxBytes { return nil }
      checked[path] = text
    }
    guard checked["SKILL.md"] != nil else { return nil }
    return Request(
      id: id, expectedRoot: root, expectedToken: token, expectedGeneration: generation, name: name, files: checked)
  }

  private static func managed(_ text: String) -> Bool {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard normalized.hasPrefix("---\n"), let end = normalized.range(of: "\n---", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex)
    else { return false }
    return normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<end.lowerBound]
      .split(separator: "\n", omittingEmptySubsequences: false)
      .contains { $0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("# dsh-go:managed") }
  }

  private static func canonical(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private func run(_ request: Request, current: () -> Bool) -> Outcome {
    do {
      guard current() else { throw Retired() }
      guard let root = EngineSkills.canonical(guestRoot.path), root != "/" else {
        return Outcome(result: nil, reason: "io")
      }
      guard EngineSkills.canonical(request.expectedRoot) == root else { return Outcome(result: nil, reason: "stale") }
      var encoded: [(path: String, text: String, bytes: Data)] = []
      var total = 0
      for (path, text) in request.files {
        let bytes = Data(text.utf8)
        total += bytes.count
        if bytes.count > EngineSkills.maxFileBytes || total > EngineSkills.maxBytes {
          return Outcome(result: nil, reason: "invalid")
        }
        encoded.append((path, text, bytes))
      }
      guard let skill = request.files["SKILL.md"], EngineSkills.managed(skill) else {
        return Outcome(result: nil, reason: "invalid")
      }
      guard current() else { throw Retired() }
      let home = root + "/root/.dsh"
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory), isDirectory.boolValue else {
        return Outcome(result: "noHome", reason: nil)
      }
      let directory = home + "/skills/" + request.name
      for path in [directory + "/SKILL.md"] + encoded.map({ directory + "/" + $0.path }) {
        if !permits(path, under: root) { return Outcome(result: "userOwned", reason: nil) }
      }
      let skillPath = directory + "/SKILL.md"
      let existed = FileManager.default.fileExists(atPath: skillPath)
      if existed {
        guard let previous = readText(skillPath, limit: EngineSkills.maxFileBytes), EngineSkills.managed(previous) else {
          return Outcome(result: "userOwned", reason: nil)
        }
      }
      let ordered = encoded.filter { $0.path != "SKILL.md" }.sorted { $0.path < $1.path } + encoded.filter { $0.path == "SKILL.md" }
      var changed = false
      for file in ordered {
        guard current() else { throw Retired() }
        let path = directory + "/" + file.path
        if readText(path, limit: file.bytes.count + 3) == file.text { continue }
        guard current() else { throw Retired() }
        try write(file.bytes, to: path, current: current)
        changed = true
      }
      return Outcome(result: !existed ? "installed" : changed ? "updated" : "unchanged", reason: nil)
    } catch is Retired {
      return Outcome(result: nil, reason: "cancelled")
    } catch {
      return Outcome(result: nil, reason: "io")
    }
  }

  /// No symbolic link on the way down, including the file itself.
  private func permits(_ path: String, under root: String) -> Bool {
    guard path.hasPrefix(root + "/") else { return false }
    var walked = root
    for part in path.dropFirst(root.count + 1).split(separator: "/") {
      walked += "/\(part)"
      var info = stat()
      if lstat(walked, &info) != 0 { return true }
      if info.st_mode & S_IFMT == S_IFLNK { return false }
    }
    return true
  }

  private func readText(_ path: String, limit: Int) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
    return String(data: data, encoding: .utf8).map { $0.hasPrefix("\u{FEFF}") ? String($0.dropFirst()) : $0 }
  }

  private func write(_ bytes: Data, to path: String, current: () -> Bool) throws {
    let target = URL(fileURLWithPath: path)
    let directory = target.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(".dsh-go-tmp-" + target.lastPathComponent)
    defer { unlink(temporary.path) }
    // Atomic, so a link left at the temporary name is replaced rather than written through.
    try bytes.write(to: temporary, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    guard current() else { throw Retired() }
    guard rename(temporary.path, path) == 0 else { throw POSIXError(.EIO) }
  }
}
