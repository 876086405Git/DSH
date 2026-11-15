import Foundation
import UIKit
import Security
import Darwin
import Flutter

@MainActor
final class IOSPhoneBridge: NSObject, URLSessionTaskDelegate {
  private struct Endpoint: Decodable { let v: Int; let runId: String; let baseUrl: String }
  private struct Claimed: Decodable { let request: IOSPhoneRequest? }
  private typealias Arm = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
  private typealias Clear = @convention(c) (UnsafePointer<CChar>) -> Void
  private let nativeArm: Arm
  private let nativeClear: Clear
  private let actions: IOSPhoneActions
  private let browser: IOSBrowser
  private let runner: IOSPhoneRunner
  private let system: IOSSystemTools
  private let runtimeCurrent: () -> Bool
  private var directory: URL?
  private var runId: String?
  private var token: String?
  private var endpoint: URL?
  private var active: IOSPhoneRequest?
  private var poller: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  private var session: URLSession?
  private var finishingPhoneTask = false
  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.connectionProxyDictionary = [:]
    config.timeoutIntervalForRequest = 4
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }
  // nativeLibrary is the already loaded DshNodeHost framework handle, retained
  // by NativeEngine for the lifetime of the runner and its linked modules.
  init(presenter: @escaping () -> UIViewController?, runtimeCurrent: @escaping () -> Bool,
       nativeLibrary: UnsafeMutableRawPointer) throws {
    guard let arm = dlsym(nativeLibrary, "dsh_ios_phone_arm"),
      let clear = dlsym(nativeLibrary, "dsh_ios_phone_clear") else { throw CocoaError(.executableNotLoadable) }
    nativeArm = unsafeBitCast(arm, to: Arm.self)
    nativeClear = unsafeBitCast(clear, to: Clear.self)
    self.actions = IOSPhoneActions(presenter: presenter)
    self.browser = IOSBrowser(actions: actions, presenter: presenter)
    self.runner = IOSPhoneRunner(actions: actions)
    self.system = IOSSystemTools(actions: actions, presenter: presenter)
    self.runtimeCurrent = runtimeCurrent
    super.init()
    IOSPhoneControl.shared.bind(self)
  }
  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

  // Only public generation and endpoint directory go in the Cordis overlay.
  // Secret exists only in Swift, C memory and the consuming Node environment.
  func prepare(in cache: URL) throws -> (directory: URL, runId: String) {
    retire()
    let generation = UUID().uuidString.lowercased()
    var random = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
      throw CocoaError(.fileWriteUnknown)
    }
    let credential = random.map { String(format: "%02x", $0) }.joined()
    let parent = cache.appendingPathComponent("ios-phone", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let directory = parent.appendingPathComponent(generation, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    guard nativeArm(generation, credential) == 0 else {
      try? FileManager.default.removeItem(at: directory)
      throw CocoaError(.executableRuntimeMismatch)
    }
    self.directory = directory; runId = generation; token = credential
    session = makeSession()
    IOSPhoneControl.shared.bind(self)
    return (directory, generation)
  }
  // Start once the host has accepted startup. runtimeCurrent must additionally
  // bind the EngineChannel generation and running token captured for this launch.
  func startPolling() {
    guard poller == nil, let generation = runId else { return }
    poller = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.runId == generation else { return }
        await self.poll(generation)
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
    }
  }
  func retire() {
    poller?.cancel(); poller = nil
    session?.invalidateAndCancel(); session = nil
    browser.retire()
    runner.retire()
    system.retire()
    if let active { actions.cancel(active.id) }
    operation?.cancel(); operation = nil
    if let runId { nativeClear(runId) }
    active = nil; endpoint = nil; runId = nil; token = nil
    if let directory { try? FileManager.default.removeItem(at: directory) }
    directory = nil
    IOSPhoneControl.shared.retire(self)
  }

  func finishPhoneTask(reopen: Bool, current: () -> Bool) async -> [String: Any] {
    guard current(), runtimeCurrent() else { return ["current": false] }
    finishingPhoneTask = true
    defer { finishingPhoneTask = false }
    // The turn-end event can beat the final result POST's acknowledgement.
    // Allow that exact operation to retire, without claiming another request.
    let until = Date().addingTimeInterval(5)
    while active != nil, current(), runtimeCurrent(), Date() < until {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    guard current(), runtimeCurrent() else { return ["current": false] }
    guard active == nil else { return ["busy": true] }
    let launched = reopen && UIApplication.shared.applicationState != .active
      ? await runner.returnToApp(current: current) : false
    if launched {
      let activationDeadline = Date().addingTimeInterval(2)
      while UIApplication.shared.applicationState != .active, current(), Date() < activationDeadline {
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
    }
    guard current(), runtimeCurrent() else { return ["current": false] }
    guard active == nil else { return ["busy": true] }
    runner.finish()
    return ["closed": true, "opened": UIApplication.shared.applicationState == .active,
      "launched": launched, "current": true]
  }

  func stopPhoneTask() {
    if let request = active, request.action.kind.hasPrefix("runner-") {
      operation?.cancel(); operation = nil
      actions.cancel(request.id)
      active = nil
      Task { [weak self] in
        guard let self, self.runId == request.runId else { return }
        _ = try? await self.post("result", ["id": request.id, "text": "用户停止了手机操控。不要重试。", "isError": true])
      }
    }
    runner.retire()
  }
  func pausePhoneTask() {
    if let request = active, request.action.kind.hasPrefix("runner-") {
      operation?.cancel(); operation = nil
      actions.cancel(request.id); active = nil
      Task { [weak self] in
        guard let self, self.runId == request.runId else { return }
        _ = try? await self.post("result", ["id": request.id,
          "text": "用户已暂停手机操控；已经派发的动作结果可能尚未确认，请核对屏幕，不要自动重试。", "isError": true])
      }
    }
    runner.finish()
  }
  // Called directly from didEnterBackground. No pending consent crosses a background hop.
  func enteredBackground() {
    browser.enteredBackground()
    guard let request = active else { return }
    actions.cancel(request.id)
  }
  private func current(_ request: IOSPhoneRequest) -> Bool {
    runId == request.runId && active?.id == request.id && runtimeCurrent()
  }
  private func readEndpoint() throws -> URL? {
    guard let directory, let runId else { return nil }
    let path = directory.appendingPathComponent("endpoint.json")
    guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
    defer { try? handle.close() }
    guard let bytes = try handle.read(upToCount: 4097), bytes.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
    let value = try JSONDecoder().decode(Endpoint.self, from: bytes)
    guard value.v == 1, value.runId == runId,
      value.baseUrl.range(of: #"^http://127\.0\.0\.1:[0-9]+$"#, options: .regularExpression) != nil,
      let url = URL(string: value.baseUrl), let port = url.port, (1...65535).contains(port) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return url
  }
  private func post(_ route: String, _ values: [String: Any] = [:]) async throws -> (Int, Data) {
    guard let endpoint, let runId, let token, let session else { throw URLError(.cancelled) }
    var body = values; body["runId"] = runId
    var request = URLRequest(url: endpoint.appendingPathComponent(route))
    request.httpMethod = "POST"
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (bytes, response) = try await session.data(for: request)
    guard bytes.count <= 32768, let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (http.statusCode, bytes)
  }
  private func poll(_ generation: String) async {
    guard !finishingPhoneTask || active != nil else { return }
    guard runtimeCurrent(), runId == generation else { return }
    do {
      if endpoint == nil { endpoint = try readEndpoint() }
      guard endpoint != nil else { return }
      if let request = active {
        let (status, _) = try await post("status", ["id": request.id])
        guard runId == generation, active?.id == request.id else { return }
        if status == 410 || request.expiresAt <= Date().timeIntervalSince1970 * 1000 {
          active = nil
          operation?.cancel(); operation = nil
          runner.cancelPreparation()
          if request.action.kind.hasPrefix("runner-") { runner.finish() }
          actions.cancel(request.id)
          browser.enteredBackground()
          system.stopAsking()
        }
        return
      }
      // With the app away, only what needs nobody on screen: a turn the system is letting go on
      // can keep browsing a site already approved. The rest waits for the app to come back.
      let inFront = UIApplication.shared.applicationState == .active
      let (status, bytes) = try await post("claim", ["background": !inFront])
      guard runId == generation, runtimeCurrent(), status == 200,
        let request = try JSONDecoder().decode(Claimed.self, from: bytes).request else { return }
      guard request.v == 1, request.runId == generation, UUID(uuidString: request.id) != nil,
        !request.owner.sessionId.isEmpty, !request.owner.callId.isEmpty else { return }
      active = request
      operation = Task { [weak self] in
        guard let self else { return }
        let kind = request.action.kind
        if kind.hasPrefix("system-") {
          let current = { [weak self] in
            self?.current(request) == true && request.expiresAt > Date().timeIntervalSince1970 * 1000
          }
          let result = await self.system.run(request, authorize: { [weak self] in
            guard let self else { return false }
            return (try? await self.post("begin", ["id": request.id]))?.0 == 200
          }, current: current)
          guard self.current(request) else { return }
          _ = try? await self.post("result", ["id": request.id, "text": result.text, "isError": result.isError])
          guard self.active?.id == request.id else { return }
          self.active = nil; self.operation = nil
          return
        }
        if kind.hasPrefix("browser-") || kind.hasPrefix("runner-") {
          if kind.hasPrefix("runner-"), !IOSPhoneControl.shared.enabled || IOSPhoneControl.shared.isPaused {
            _ = try? await self.post("result", ["id": request.id,
              "text": IOSPhoneControl.shared.isPaused ? "手机操控已暂停；请回到 App，由用户确认继续。" : "手机操控已关闭，请在 DSH Go 设置中开启。", "isError": true])
            self.active = nil; self.operation = nil
            return
          }
          // The tool call has to still be waiting for this, now and after any question to the user.
          let current = { [weak self] in
            self?.current(request) == true && request.expiresAt > Date().timeIntervalSince1970 * 1000
          }
          let result: IOSPhoneOutcome
          if kind.hasPrefix("runner-") {
            IOSPhoneControl.shared.begin(request, bridge: self)
            // The runner checks its native task grant before beginning each
            // still-live call; ordinary calls need no foreground round trip.
            result = await self.runner.run(request, authorize: { [weak self] in
              guard let self, self.current(request) else { return false }
              let begun = (try? await self.post("begin", ["id": request.id]))?.0 == 200
              return begun && self.current(request)
                && request.expiresAt > Date().timeIntervalSince1970 * 1000
            }, progress: { [weak self] phase in
              guard let self, self.current(request) else { return }
              IOSPhoneControl.shared.update(phase, request: request, bridge: self)
            }, current: current)
          } else {
            let begun = (try? await self.post("begin", ["id": request.id]))?.0 == 200
            guard begun, current() else {
              if self.current(request) {
                _ = try? await self.post("result", ["id": request.id, "text": "这个工具调用已经结束，没有执行。", "isError": true])
                guard self.active?.id == request.id else { return }
                self.active = nil; self.operation = nil
              }
              return
            }
            result = await self.browser.run(request, current: current)
          }
          guard self.current(request) else { return }
          var values: [String: Any]
          if kind.hasPrefix("runner-") {
            IOSPhoneControl.shared.update(.reviewResult, request: request, bridge: self)
            values = IOSPhoneResultEnvelope.values(requestID: request.id, runID: request.runId, outcome: result)
          } else {
            values = ["id": request.id, "text": result.text, "isError": result.isError]
            if let image = result.image { values["image"] = image.base64EncodedString() }
          }
          _ = try? await self.post("result", values)
          guard self.active?.id == request.id else { return }
          self.active = nil; self.operation = nil
          return
        }
        let result = await self.actions.run(request, current: { [weak self] in self?.current(request) == true }, authorize: { [weak self] in
          guard let self, self.current(request) else { return false }
          do {
            let (status, _) = try await self.post("begin", ["id": request.id])
            return status == 200 && self.current(request)
          } catch { return false }
        }, validate: { [weak self] in
          guard let self, self.current(request) else { return false }
          do {
            let (status, bytes) = try await self.post("status", ["id": request.id])
            let state = try JSONDecoder().decode([String: String].self, from: bytes)
            return status == 200 && state["state"] == "executing" && self.current(request)
          } catch { return false }
        })
        guard self.current(request) else { return }
        // A failed result upload is never permission to repeat a system action.
        _ = try? await self.post("result", ["id": request.id, "text": result.text, "isError": result.isError])
        guard self.active?.id == request.id else { return }
        self.active = nil; self.operation = nil
      }
    } catch {
      // Socket loss cannot authorize or replay anything. The per-call deadline and
      // EngineChannel's runtime stop/restart retire the outstanding request.
      if let request = active, request.expiresAt <= Date().timeIntervalSince1970 * 1000 { actions.cancel(request.id) }
    }
  }
}

/// Shares the iOS task lifecycle with the existing Flutter turn-end controller.
/// Task ownership comes from the authenticated engine request, not the visible chat.
@MainActor
final class IOSPhoneControl: NSObject, FlutterStreamHandler {
  enum Phase {
    case awaitingConfirmation, connecting, executing, reviewResult
    var line: String {
      switch self {
      case .awaitingConfirmation: return "等待本次确认"
      case .connecting: return "正在准备连接"
      case .executing: return "正在处理本次调用"
      case .reviewResult: return "请核对手机结果"
      }
    }
  }
  static let shared = IOSPhoneControl()
  private weak var bridge: IOSPhoneBridge?
  private var methods: FlutterMethodChannel?
  private var events: FlutterEventChannel?
  private var sink: FlutterEventSink?
  var onTaskActivityChanged: ((Bool) -> Void)?
  private var taskID = 0
  private var owner: String?
  private var ownerRunID: String?
  private var requestID: String?
  private var active = false
  private var stopped = false
  private var finishing = false
  private var paused = false
  var enabled: Bool { UserDefaults.standard.object(forKey: "dsh.ios.phone.enabled") as? Bool ?? true }
  var hasActivePhoneTask: Bool { active }
  var isPaused: Bool { paused }
  func revokePhoneTask() { stop() }
  func pausePhoneTask(id: Int) {
    guard id == taskID, active, !paused else { return }
    paused = true; requestID = nil
    IOSPetOverlay.shared.updatePhoneTask(id: id, line: "已暂停，回 App 继续")
    bridge?.pausePhoneTask(); emit()
  }
  func resumePhoneTask(id: Int) {
    guard id == taskID, active, paused, UIApplication.shared.applicationState == .active,
      UIApplication.shared.isProtectedDataAvailable else { return }
    paused = false
    IOSPetOverlay.shared.updatePhoneTask(id: id, line: "等待下一次确认")
    emit()
  }
  func stopPhoneTaskConfirmed(id: Int) { if id == taskID, active { stop() } }

  func register(messenger: any FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "dsh/phone", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "dsh/phone/events", binaryMessenger: messenger)
    methods?.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "status": result(self.status())
      case "setEnabled":
        guard let value = args["enabled"] as? Bool else { return result(false) }
        UserDefaults.standard.set(value, forKey: "dsh.ios.phone.enabled")
        if !value { self.stop() }
        self.emit(); result(true)
      case "stopTask": self.stop(); result(true)
      case "finishTask":
        guard let id = args["taskId"] as? Int, id == self.taskID, self.active,
          let owner = self.owner,
          (args["sessionId"] as? String).map({ $0 == owner }) ?? true,
          let bridge = self.bridge else { return result(["current": false]) }
        guard !self.finishing else { return result(["busy": true]) }
        self.finishing = true
        #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
        IOSPhoneSelfRunner.diagnostic("phone task finish id=\(id) reopen=\(args["reopen"] as? Bool == true)")
        #endif
        Task { @MainActor in
          let current = { [weak self, weak bridge] in
            self?.taskID == id && self?.active == true && self?.bridge === bridge
          }
          let reply = await bridge.finishPhoneTask(reopen: args["reopen"] as? Bool == true, current: current)
          #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
          IOSPhoneSelfRunner.diagnostic("phone task finished id=\(id) closed=\(reply["closed"] as? Bool == true) opened=\(reply["opened"] as? Bool == true) launched=\(reply["launched"] as? Bool == true)")
          #endif
          if current() {
            self.finishing = false
            if reply["closed"] as? Bool == true {
              self.active = false; self.paused = false; self.requestID = nil
              IOSPetOverlay.shared.endPhoneTask(id: id)
              self.emit()
            }
          }
          result(reply)
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
    events?.setStreamHandler(self)
  }

  func bind(_ bridge: IOSPhoneBridge) { self.bridge = bridge; emit() }
  func begin(_ request: IOSPhoneRequest, bridge: IOSPhoneBridge) {
    guard self.bridge === bridge else { return }
    if !active || owner != request.owner.sessionId || ownerRunID != request.runId {
      taskID += 1; owner = request.owner.sessionId; ownerRunID = request.runId
      active = true; stopped = false; finishing = false; paused = false
      IOSPetOverlay.shared.beginPhoneTask(id: taskID, sessionID: request.owner.sessionId,
        line: Phase.awaitingConfirmation.line)
      #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
      IOSPhoneSelfRunner.diagnostic("phone task begin id=\(taskID)")
      #endif
      emit()
    }
    requestID = request.id
    update(.awaitingConfirmation, request: request, bridge: bridge)
  }
  /// Only native fixed phases enter PiP; never tool arguments or clipboard data.
  /// A late callback cannot update a newer request, task, or runtime owner.
  func update(_ phase: Phase, request: IOSPhoneRequest, bridge: IOSPhoneBridge) {
    guard self.bridge === bridge, active, !paused,
      owner == request.owner.sessionId, ownerRunID == request.runId,
      requestID == request.id else { return }
    IOSPetOverlay.shared.updatePhoneTask(id: taskID, line: phase.line)
  }
  func retire(_ bridge: IOSPhoneBridge) {
    guard self.bridge === bridge else { return }
    active = false; stopped = false; finishing = false; paused = false; requestID = nil
    IOSPetOverlay.shared.endPhoneTask(id: taskID)
    self.bridge = nil
    emit()
  }
  private func stop() {
    bridge?.stopPhoneTask()
    active = false; stopped = true; finishing = false; paused = false; requestID = nil
    IOSPetOverlay.shared.endPhoneTask(id: taskID)
    emit()
  }
  private func status() -> [String: Any] {
    var task: [String: Any] = ["id": taskID, "active": active, "stopped": stopped, "paused": paused]
    if let owner { task["ownerSessionId"] = owner }
    return ["enabled": enabled, "bridgeListening": bridge != nil && IOSPhoneSelfRunner.shared.isConfigured,
      "task": task]
  }
  private func emit() {
    onTaskActivityChanged?(active && !paused && !stopped)
    sink?(status())
  }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events; emit(); return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
}
