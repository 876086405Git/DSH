// Apple SDK compilation and device execution have not been verified.
import Flutter
import Foundation

final class GuestChannel: NSObject, FlutterStreamHandler {
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private let kernel: GuestKernelAccess
  private let installer: GuestRootfsInstaller?
  private let supportFailure: GuestFailure?
  private let queue = DispatchQueue(label: "dsh.guest.installation")
  // sink is used only on the main thread. All other mutable state lives on queue.
  private var sink: FlutterEventSink?
  private var operation: String?
  private var phase: String?
  private var cancellation: GuestCancellation?
  private var lastError: GuestFailure?

  /// I2 must supply a process-wide capability/admission owner; no file-presence
  /// probe and no product switch is substituted for that owner.
  init(messenger: FlutterBinaryMessenger, kernel: GuestKernelAccess, support: Result<URL, Error>) {
    self.kernel = kernel
    switch support {
    case .success(let url):
      installer = GuestRootfsInstaller(base: url.appendingPathComponent("dsh-guest", isDirectory: true))
      supportFailure = nil
    case .failure:
      installer = nil
      supportFailure = GuestFailure("storage_unavailable", "The app support directory is unavailable.")
    }
    methods = FlutterMethodChannel(name: "dsh/guest", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "dsh/guest/events", binaryMessenger: messenger)
    super.init()
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      self.queue.async { self.handle(call, result: result) }
    }
    events.setStreamHandler(self)
  }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    queue.async { self.emitStatus() }
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
  private func emit(_ value: [String: Any]) {
    DispatchQueue.main.async { [weak self] in self?.sink?(value) }
  }
  private func reply(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }
  private func snapshot() -> [String: Any] {
    var installed = false
    var suspended = false
    var crashGateKnown = false
    var error = lastError ?? supportFailure
    do { installed = try installer?.installed() ?? false }
    catch let failure { if error == nil { error = guestFailure(failure) } }
    let available = installer != nil && kernel.available
    if let installer {
      do {
        suspended = try kernel.isSuspended(in: installer.base)
        crashGateKnown = true
      } catch let failure { if error == nil { error = guestFailure(failure) } }
    }
    return ["schema": 1, "phase": phase ?? (error != nil ? "error" : installed ? "installed" : "notInstalled"),
      "version": installed ? GuestRootfsArchive.version as Any : NSNull(),
      "available": available, "installed": installed, "usable": installed && available && crashGateKnown && !suspended && operation == nil,
      "suspended": suspended, "suspendedReason": suspended ? "crashed" as Any : NSNull(),
      "busy": operation != nil,
      "error": error.map { ["code": $0.code, "message": $0.message] } as Any? ?? NSNull()]
  }
  private func emitStatus() { emit(["type": "status", "status": snapshot()]) }
  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      if let args = call.arguments, !(args is NSNull) {
        guard let map = args as? [String: Any], map.isEmpty else {
          throw GuestFailure("arguments", "This method accepts no arguments.")
        }
      }
      if call.method != "status" && call.method != "cancel", let supportFailure { throw supportFailure }
      switch call.method {
      case "status": reply(result, snapshot())
      case "cancel":
        reply(result, ["cancelled": cancellation?.cancel() ?? false])
      case "resume":
        guard operation == nil else { throw GuestFailure("busy", "Linux installation is busy.") }
        guard let installer else { throw GuestFailure("storage_unavailable", "The app support directory is unavailable.") }
        try kernel.resume(in: installer.base)
        lastError = nil
        emitStatus()
        reply(result, snapshot())
      case "install":
        guard operation == nil else { throw GuestFailure("busy", "Linux installation is busy.") }
        guard kernel.available else { throw GuestFailure("unavailable", "The Linux backend is unavailable in this build.") }
        if try installer?.installed() == true { lastError = nil; reply(result, snapshot()); return }
        try mutate("install", result: result)
      case "uninstall":
        guard operation == nil else { throw GuestFailure("busy", "Linux installation is busy.") }
        try mutate("uninstall", result: result)
      case "usage":
        guard operation == nil else { throw GuestFailure("busy", "Linux storage is changing; retry usage after completion.") }
        // Keep enumeration off the state queue. Reserve the mutation slot so the
        // installer cannot replace the tree during traversal. Guest writes can still
        // change file sizes; usage is an observation, not a storage transaction.
        guard let installer else { throw GuestFailure("storage_unavailable", "The app support directory is unavailable.") }
        operation = "usage"
        DispatchQueue.global(qos: .utility).async { [self] in
          let value = Result { try installer.usage() }
          queue.async {
            self.operation = nil
            switch value {
            case .success(let usage): self.reply(result, usage)
            case .failure(let error): self.replyError(result, error)
            }
          }
        }
      default: reply(result, FlutterMethodNotImplemented)
      }
    } catch { replyError(result, error) }
  }
  private func mutate(_ name: String, result: @escaping FlutterResult) throws {
    guard let installer else { throw GuestFailure("storage_unavailable", "The app support directory is unavailable.") }
    let lease = try kernel.reserveRootfsMutation()
    let token = GuestCancellation()
    operation = name; phase = name == "install" ? "verifying" : "uninstalling"
    cancellation = name == "install" ? token : nil
    lastError = nil
    emitStatus()
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      var failure: Error?
      var previousStep = ""
      var previousPercent: Int64 = -1
      do {
        if name == "install" {
          try installer.install(cancel: token) { step, done, total in
            let percent = total == 0 ? 100 : done * 100 / total
            guard step != previousStep || percent != previousPercent else { return }
            previousStep = step; previousPercent = percent
            queue.async {
              self.phase = ["download": "downloading", "verify": "verifying", "extract": "extracting", "publish": "publishing"][step]
              self.emit(["type": "progress", "step": step, "done": done, "total": total])
              self.emitStatus()
            }
          }
        } else { try installer.uninstall() }
      } catch { failure = error }
      lease.release()
      let completedFailure = failure
      queue.async {
        self.operation = nil; self.phase = nil; self.cancellation = nil
        self.lastError = completedFailure.map(guestFailure)
        self.emitStatus()
        if let completedFailure { self.replyError(result, completedFailure) }
        else { self.reply(result, self.snapshot()) }
      }
    }
  }
  private func replyError(_ result: @escaping FlutterResult, _ error: Error) {
    let failure = guestFailure(error)
    reply(result, FlutterError(code: failure.code, message: failure.message, details: nil))
  }
}
