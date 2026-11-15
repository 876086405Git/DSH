import Foundation
import Darwin

#if DSH_PHONE_SELF_RUNNER
private func phoneSelfRunnerNativeCallback(
  _ runId: UnsafePointer<CChar>?, _ kind: Int32, _ payload: UnsafePointer<CChar>?
) {
  guard let runId, let id = String(validatingCString: runId), UUID(uuidString: id) != nil else { return }
  let value = payload.flatMap { String(validatingCString: $0) } ?? ""
  guard value.utf8.count <= 8192 else { return }
  Task { @MainActor in IOSPhoneSelfRunner.deliverNativeEvent(runId: id, kind: kind, payload: value) }
}
#endif

enum IOSPhoneSelfRunnerError: Error {
  case unavailable, cancelled, timedOut, stopping, faulted, developerImageRequired, setup, failed, invalidHandshake

  var message: String {
    switch self {
    case .unavailable:
      return "此构建的手机原生组件不可用。请使用包含共享原生库的新构建；XCTest 增强还需在设置里明确启用并安装 PhoneRunner。"
    case .cancelled:
      return "这个手机操控调用已经结束，没有执行动作。"
    case .timedOut:
      return "端上 XCTest 启动超时，没有执行动作。请保持 iPhone 解锁；如手机显示 Enable UI Automation，请直接在手机输入锁屏密码确认，然后重试。若仍失败，请检查配对文件、LocalDevVPN、开发者模式、已签名的 PhoneRunner 和开发者镜像。"
    case .stopping:
      return "上一份端上 XCTest 会话还在停止，没有启动新的运行器。请等待停止完成，不要自动重复这一步。"
    case .faulted:
      return "无法确认旧 PhoneRunner 已退出，本次不会继续操控或切换后端。请先结束旧运行器，再完全退出并重新打开 DSH Go。"
    case .developerImageRequired:
      return "本机开发者镜像（DDI）尚未就绪。请回到手机连接设置，由用户选择下载并挂载；这一步不会自动安装镜像或重试操控。"
    case .setup:
      return "端上 XCTest 尚未就绪：配置不完整，或配对记录无法读取／校验。记录存在不代表可以使用；请解锁设备后检查配对记录、运行器包名和本机开发者服务端口。"
    case .failed:
      return "端上 XCTest 没有连接成功，没有执行动作。请保持 iPhone 解锁；如手机显示 Enable UI Automation，请直接在手机输入锁屏密码确认，然后重试。若仍失败，请检查配对、LocalDevVPN、开发者模式、匹配的开发者镜像和已签名安装的 PhoneRunner。"
    case .invalidHandshake:
      return "端上 XCTest 返回的就绪握手无效，没有执行动作。请重新启动运行器。"
    }
  }
}

/// Owns one optional, on-device testmanagerd session. The existing Mac runner is
/// independent: this owner prepares an endpoint, but never replays a phone action.
@MainActor
final class IOSPhoneSelfRunner {
  typealias EventSink = @MainActor (String, Int32, String) -> Void
  struct NativeClient {
    // Pairing is a separate synchronous byte input. nil is only the legacy
    // file-config seam; production supplies the in-memory store's Data.
    let start: @MainActor (String, Data, Data?, @escaping EventSink) -> UInt64
    let stop: @MainActor (UInt64) -> Void
  }

  static let shared = IOSPhoneSelfRunner()
  private static var nativeCallbacks: [String: EventSink] = [:]

  #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
  static func diagnostic(_ text: String) {
    guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let url = directory.appendingPathComponent("dsh-phone-preflight.log")
    let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let line = "\(Date().timeIntervalSince1970) \(text)\n"
    try? (String(previous.suffix(24000)) + line).write(to: url, atomically: true, encoding: .utf8)
  }
  #endif

  private final class Run {
    let id: String
    let ownerID: String
    let deadline: Date
    var handshake: PhoneRunnerHandshake?
    var handle: UInt64 = 0
    var endpoint: PhoneRunnerEndpoint?
    var accepted = false
    var failure: IOSPhoneSelfRunnerError?
    var stopRequested = false
    var stopDeadline: Date?
    var terminal = false
    var waiters = Set<UUID>()

    init(id: String, ownerID: String, deadline: Date, handshake: PhoneRunnerHandshake) {
      self.id = id
      self.ownerID = ownerID
      self.deadline = deadline
      self.handshake = handshake
    }
  }

  private struct Configuration: Encodable {
    let runId: String
    let pairingFile: String?
    let host: String
    let port: UInt16
    let runnerBundleId: String
    let targetBundleId: String
    let publicKeyBase64: String
  }

  private let native: NativeClient?
  private let pairingURL: URL
  private let pairingData: (() throws -> Data)?
  private let pairingAvailable: (() -> Bool)?
  private let runnerBundleId: String
  private let targetBundleId: String
  private let configuredPort: UInt16?
  private let configurationValid: Bool
  private let startupTimeout: TimeInterval
  private let stopTimeout: TimeInterval
  private let resolvePort: () async -> UInt16
  private let now: () -> Date
  private var active: Run?
  private var starter: Task<Void, Never>?

  convenience init() {
    let bundle = Bundle.main
    let target = bundle.bundleIdentifier ?? ""
    let configuredRunner = bundle.object(forInfoDictionaryKey: "DSHPhoneRunnerBundleIdentifier") as? String
    let runner = configuredRunner ?? target + ".PhoneRunner.xctrunner"
    let rawPort = bundle.object(forInfoDictionaryKey: "DSHPhoneRemotePairingPort")
    let number = (rawPort as? NSNumber)?.intValue ?? (rawPort as? String).flatMap(Int.init)
    let validPort = rawPort == nil || number.map { (1...65535).contains($0) } == true
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    self.init(native: Self.makeNativeClient(), pairingURL: documents.appendingPathComponent("pairingFile.plist"),
      runnerBundleId: runner, targetBundleId: target,
      configuredPort: number.flatMap(UInt16.init(exactly:)), configurationValid: validPort,
      pairingData: { try IOSPhonePairingStore.shared.load() },
      pairingAvailable: { IOSPhonePairingStore.shared.hasRecord })
  }

  /// Internal test seam: the production client is nil unless the build opted in.
  init(native: NativeClient?, pairingURL: URL, runnerBundleId: String, targetBundleId: String,
       configuredPort: UInt16? = nil, configurationValid: Bool = true,
       startupTimeout: TimeInterval = 95, stopTimeout: TimeInterval = 12,
       resolvePort: @escaping () async -> UInt16 = { await PhoneRemotePairingPort.resolve() },
       now: @escaping () -> Date = Date.init, pairingData: (() throws -> Data)? = nil,
       pairingAvailable: (() -> Bool)? = nil) {
    self.native = native
    self.pairingURL = pairingURL
    self.pairingData = pairingData
    self.pairingAvailable = pairingAvailable
    self.runnerBundleId = runnerBundleId
    self.targetBundleId = targetBundleId
    self.configuredPort = configuredPort
    self.configurationValid = configurationValid
    self.startupTimeout = startupTimeout
    self.stopTimeout = stopTimeout
    self.resolvePort = resolvePort
    self.now = now
  }

  var isConfigured: Bool {
    guard native != nil else { return false }
    // Status must not read/normalize private-key bytes. In-memory providers
    // supply an independent availability query; only begin() loads the record.
    // Presence is a route-selection hint, not proof of loadability or readiness.
    // A later load failure remains .setup; Runner does not retry it on the Mac.
    if pairingData != nil { return pairingAvailable?() ?? false }
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: pairingURL.path, isDirectory: &directory) && !directory.boolValue
  }

  var mayUseMacFallback: Bool { active == nil || active?.terminal == true }

  func owns(_ endpoint: PhoneRunnerEndpoint) -> Bool {
    guard let run = active, !run.stopRequested, !run.terminal else { return false }
    return run.endpoint == endpoint && endpoint.isValid(for: run.id)
  }

  func prepare(ownerID: String = "default", current: () -> Bool) async -> Result<PhoneRunnerEndpoint, IOSPhoneSelfRunnerError> {
    guard native != nil else { return .failure(.unavailable) }
    guard configurationValid, isConfigured, Self.bundleIdentifier(runnerBundleId), Self.bundleIdentifier(targetBundleId),
      startupTimeout.isFinite, startupTimeout > 0, stopTimeout.isFinite, stopTimeout > 0 else {
      return .failure(.setup)
    }
    let waiter = UUID()
    var observed: Run?
    defer {
      if let run = observed {
        run.waiters.remove(waiter)
        // A cancelled caller does not take down a startup another live caller needs.
        let abandonedReady = !run.accepted && (Task.isCancelled || !current())
        if run.waiters.isEmpty, run.endpoint == nil || abandonedReady, !run.terminal, !run.stopRequested {
          stop(run, reason: .cancelled)
        }
      }
    }
    while true {
      guard !Task.isCancelled, current() else { return .failure(.cancelled) }
      if let run = observed {
        if let failure = run.failure { return .failure(failure) }
        guard active === run, !run.stopRequested, !run.terminal else { return .failure(.cancelled) }
        if let endpoint = run.endpoint {
          run.accepted = true
          return .success(endpoint)
        }
        if now() >= run.deadline {
          stop(run, reason: .timedOut)
          return .failure(.timedOut)
        }
      } else if let run = active {
        // A new engine generation takes over only after the old native owner
        // has stopped. Late retire/cancel calls remain bound to their owner ID.
        if run.ownerID != ownerID, !run.stopRequested, !run.terminal { stop(run, reason: .cancelled) }
        if run.stopRequested, !run.terminal {
          if case .faulted? = run.failure { return .failure(.faulted) }
          if let until = run.stopDeadline, now() >= until { return .failure(.stopping) }
        } else if run.terminal {
          active = nil
        } else {
          observed = run
          run.waiters.insert(waiter)
        }
      } else {
        do {
          let id = UUID().uuidString.lowercased()
          let run = Run(id: id, ownerID: ownerID, deadline: now().addingTimeInterval(startupTimeout),
            handshake: try PhoneRunnerHandshake(runId: id))
          active = run
          observed = run
          run.waiters.insert(waiter)
          begin(run)
        } catch { return .failure(.setup) }
      }
      do { try await Task.sleep(nanoseconds: 50_000_000) }
      catch { return .failure(.cancelled) }
    }
  }

  /// Cancelling a tool waiting for startup must not leave a later ready callback actionable.
  func cancelPreparation(ownerID: String? = nil) {
    guard let run = active, run.endpoint == nil, ownerID == nil || run.ownerID == ownerID else { return }
    stop(run, reason: .cancelled)
  }

  func stop(ownerID: String? = nil) {
    guard let run = active, ownerID == nil || run.ownerID == ownerID else { return }
    stop(run, reason: .cancelled)
  }

  private func stop(_ run: Run, reason: IOSPhoneSelfRunnerError) {
    guard active === run, !run.stopRequested else { return }
    run.stopRequested = true
    run.failure = reason
    run.endpoint = nil
    run.handshake = nil
    run.stopDeadline = now().addingTimeInterval(stopTimeout)
    starter?.cancel()
    starter = nil
    if run.handle != 0 {
      native?.stop(run.handle)
      // The native terminal event is the resource barrier before any new start.
    } else {
      run.terminal = true
      active = nil
    }
  }

  private func begin(_ run: Run) {
    starter = Task { [weak self, weak run] in
      guard let self, let run else { return }
      let port: UInt16
      if let configured = self.configuredPort { port = configured }
      else { port = await self.resolvePort() }
      guard !Task.isCancelled, self.active === run, !run.stopRequested,
        let handshake = run.handshake, let native = self.native else { return }
      guard self.now() < run.deadline else { self.stop(run, reason: .timedOut); return }
      do {
        let config = Configuration(runId: run.id, pairingFile: self.pairingData == nil ? self.pairingURL.path : nil,
          host: "10.7.0.1", port: port, runnerBundleId: self.runnerBundleId,
          targetBundleId: self.targetBundleId, publicKeyBase64: handshake.publicKeyBase64)
        let bytes = try JSONEncoder().encode(config)
        guard bytes.count <= 96 * 1024 else { throw IOSPhonePairingError.tooLarge }
        let handle = try { () throws -> UInt64 in
          let record = try self.pairingData?()
          if let count = record?.count, count == 0 || count > IOSPhonePairingRecord.maximumBytes {
            throw IOSPhonePairingError.tooLarge
          }
          // Do not base64/JSON encode the record or reset a possibly shared
          // Data value (which can allocate another CoW copy). Native borrows it
          // only until this call returns; store/Keychain retention is separate.
          return native.start(run.id, bytes, record) { [weak self] id, kind, payload in
            self?.receive(runId: id, kind: kind, payload: payload)
          }
        }()
        run.handle = handle
        if handle == 0 {
          run.failure = .failed
          run.handshake = nil
          run.terminal = true
        }
      } catch {
        run.failure = .setup
        run.handshake = nil
        run.terminal = true
      }
    }
  }

  private func receive(runId: String, kind: Int32, payload: String) {
    guard let run = active, run.id == runId else { return }
    #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
    if kind == 1 {
      print("DSH_SELF_EVENT ready")
      Self.diagnostic("event ready")
    } else {
      let code = String(payload.split(separator: ":", maxSplits: 1).first ?? "")
      let safe = code.utf8.count <= 96 && code.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }
      print("DSH_SELF_EVENT kind=\(kind) code=\(safe ? code : "redacted")")
      Self.diagnostic("event kind=\(kind) code=\(safe ? code : "redacted")")
    }
    fflush(stdout)
    #endif
    switch kind {
    case 1:
      guard !run.stopRequested, !run.terminal, run.endpoint == nil, let handshake = run.handshake else { return }
      do {
        let endpoint = try handshake.decodeReady(payload)
        guard self.now() < run.deadline else { stop(run, reason: .timedOut); return }
        run.endpoint = endpoint
        run.handshake = nil
      } catch { stop(run, reason: .invalidHandshake) }
    case 4:
      // Native transport ended without proving the device Runner exited. The
      // poisoned native slot can only be reset by restarting this app process.
      run.failure = .faulted
      run.stopRequested = true
      run.stopDeadline = now()
      run.handle = 0
      run.endpoint = nil
      run.handshake = nil
    case 2, 3:
      run.terminal = true
      run.handle = 0
      run.handshake = nil
      run.endpoint = nil
      if run.failure == nil {
        let code = payload.split(separator: ":", maxSplits: 1).first
        run.failure = code == "ERR_PHONE_DDI_REQUIRED" ? .developerImageRequired : .failed
      }
      if run.stopRequested { active = nil }
    default:
      break
    }
  }

  private static func bundleIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 255 && value.contains(".") &&
      value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
        (97...122).contains($0) || $0 == 45 || $0 == 46 }
  }

  private static func makeNativeClient() -> NativeClient? {
    #if DSH_PHONE_SELF_RUNNER
    guard #available(iOS 17.0, *) else { return nil }
    return NativeClient(start: { runId, config, pairing, sink in
      nativeCallbacks[runId] = sink
      let handle: UInt64
      if let pairing {
        handle = config.withUnsafeBytes { raw in
          pairing.withUnsafeBytes { record in
            dsh_phone_xctest_start_bytes(raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
              record.bindMemory(to: UInt8.self).baseAddress, record.count, phoneSelfRunnerNativeCallback)
          }
        }
      } else {
        // Existing file-only callers remain compatible. This metadata contains
        // a path and public launch fields, never the pairing record itself.
        guard let text = String(data: config, encoding: .utf8) else {
          nativeCallbacks.removeValue(forKey: runId)
          return 0
        }
        handle = text.withCString { dsh_phone_xctest_start($0, phoneSelfRunnerNativeCallback) }
      }
      if handle == 0 { nativeCallbacks.removeValue(forKey: runId) }
      return handle
    }, stop: { dsh_phone_xctest_stop($0) })
    #else
    return nil
    #endif
  }

  #if DSH_PHONE_SELF_RUNNER
  fileprivate static func deliverNativeEvent(runId: String, kind: Int32, payload: String) {
    let callback = nativeCallbacks[runId]
    if kind == 2 || kind == 3 || kind == 4 { nativeCallbacks.removeValue(forKey: runId) }
    callback?(runId, kind, payload)
  }
  #endif
}

/// Resolves the developer-service advertisement on the main run loop. The
/// address remains the device's LocalDevVPN loopback; only the port is discovered.
@MainActor
final class PhoneRemotePairingPort: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
  private let browser = NetServiceBrowser()
  private var services: [NetService] = []
  private var continuation: CheckedContinuation<UInt16, Never>?

  static func resolve() async -> UInt16 {
    let resolver = PhoneRemotePairingPort()
    return await withCheckedContinuation { continuation in
      resolver.continuation = continuation
      resolver.browser.delegate = resolver
      resolver.browser.schedule(in: .main, forMode: .default)
      resolver.browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
      // Retain through the deadline even when the advertisement arrives early.
      DispatchQueue.main.asyncAfter(deadline: .now() + 4) { resolver.finish(49152) }
    }
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    services.append(service)
    service.delegate = self
    service.resolve(withTimeout: 3)
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    // A nearby iPhone can advertise the same service. Its port says nothing
    // about this device's 10.7.0.1 endpoint, so only accept local addresses.
    let local = Self.localAddresses()
    guard (1...65535).contains(sender.port), sender.addresses?.contains(where: { data in
      guard data.count >= MemoryLayout<sockaddr>.size, data.count <= MemoryLayout<sockaddr_storage>.size else { return false }
      var storage = sockaddr_storage()
      _ = withUnsafeMutableBytes(of: &storage) { data.copyBytes(to: $0) }
      return withUnsafePointer(to: &storage) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
          guard Int(address.pointee.sa_len) <= data.count else { return false }
          return Self.numericAddress(address).map { local.contains($0) } == true
        }
      }
    }) == true else { return }
    finish(UInt16(sender.port))
  }

  private static func localAddresses() -> Set<String> {
    var result: Set<String> = ["127.0.0.1", "::1", "10.7.0.1"]
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0 else { return result }
    defer { freeifaddrs(interfaces) }
    var entry = interfaces
    while let current = entry {
      if let address = current.pointee.ifa_addr, let value = numericAddress(address) { result.insert(value) }
      entry = current.pointee.ifa_next
    }
    return result
  }

  private static func numericAddress(_ address: UnsafePointer<sockaddr>) -> String? {
    guard address.pointee.sa_family == sa_family_t(AF_INET) || address.pointee.sa_family == sa_family_t(AF_INET6),
      address.pointee.sa_len > 0 else { return nil }
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let capacity = socklen_t(host.count)
    guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, capacity,
      nil, 0, NI_NUMERICHOST) == 0 else { return nil }
    return String(cString: host).split(separator: "%", maxSplits: 1).first.map(String.init)
  }

  private func finish(_ port: UInt16) {
    guard let continuation else { return }
    self.continuation = nil
    browser.stop()
    services.forEach { $0.stop() }
    services.removeAll()
    continuation.resume(returning: port)
  }
}
