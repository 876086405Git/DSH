import Foundation
import Flutter
import UIKit
import UniformTypeIdentifiers
import Darwin

/// Setup-only channel. It is never registered as a model tool, and never returns
/// pairing bytes, a Keychain value, an import URL, or a native launch credential.
@MainActor
final class IOSPhoneLink: NSObject, FlutterStreamHandler, @preconcurrency UIDocumentPickerDelegate {
  static let shared = IOSPhoneLink()
  private let pairing = IOSPhonePairingStore.shared
  private let core = IOSPhoneCoreDevice.shared
  private let cache = IOSPhoneDDICache.shared
  private let pairingReader = IOSPhonePairingFileReader()
  private let defaults = UserDefaults.standard
  private var methods: FlutterMethodChannel?
  private var events: FlutterEventChannel?
  private var sink: FlutterEventSink?
  private var presenter: () -> UIViewController? = { nil }
  private var operationID: UUID?
  private var operation: Task<Void, Never>?
  private var result: FlutterResult?
  private var modal: UIViewController?
  private var choice: CheckedContinuation<String?, Never>?
  private var pickedFile: CheckedContinuation<URL?, Never>?
  private var progress: [String: Any] = [:]
  private var lastCheck: [String: Any] = [:]
  private var observing = false
  private(set) var generation = UUID()

  var enabled: Bool { defaults.bool(forKey: "dsh.ios.phone.link.enabled") }
  var isPreparing: Bool { operationID != nil }
  var xctestEnabled: Bool { defaults.bool(forKey: "dsh.ios.phone.xctest.enabled") }
  var appRoutes: [String: String] { defaults.dictionary(forKey: "dsh.ios.phone.app-routes") as? [String: String] ?? [:] }
  private var foreground: Bool {
    UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
  }
  private var legacy: URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("pairingFile.plist")
  }
  private var legacyPresent: Bool { legacy.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

  func register(messenger: FlutterBinaryMessenger, presenter: @escaping () -> UIViewController?) {
    methods?.setMethodCallHandler(nil)
    events?.setStreamHandler(nil)
    sink = nil
    cancelOperation()
    self.presenter = presenter
    let next = FlutterMethodChannel(name: "dsh/phone_link", binaryMessenger: messenger)
    methods = next
    events = FlutterEventChannel(name: "dsh/phone_link/events", binaryMessenger: messenger)
    next.setMethodCallHandler { [weak self, weak next] call, reply in
      guard let self, let next, self.methods === next else { reply(FlutterMethodNotImplemented); return }
      self.handle(call, reply: reply)
    }
    events?.setStreamHandler(self)
    pairing.willChange = { [weak self] in self?.invalidate() }
    core.onStateChanged = { [weak self] in self?.emit() }
    IOSPhoneClipboard.shared.onStateChanged = { [weak self] in self?.emit() }
    if !observing {
      observing = true
      NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground),
        name: UIApplication.didEnterBackgroundNotification, object: nil)
      NotificationCenter.default.addObserver(self, selector: #selector(protectedDataUnavailable),
        name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
    }
  }

  func status() -> [String: Any] {
    let available: Bool
    if #available(iOS 17.0, *) { available = core.isAvailable } else { available = false }
    return [
      "schema": 1, "enabled": enabled, "buildAvailable": available,
      "defaultBackend": "coredevice", "xctestEnabled": xctestEnabled, "appRoutes": appRoutes,
      "pairing": pairing.status(), "legacyPairingNeedsMigration": legacyPresent,
      "connection": core.state, "connected": core.isReady, "lastCheck": lastCheck,
      "ddiCache": cache.status(), "operationPending": operationID != nil, "progress": progress,
      "clipboard": IOSPhoneClipboard.shared.status(),
      "consent": ["foregroundGrantMinutes": 30, "perCallRequired": false, "notificationTapApproves": false],
    ]
  }

  private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "status": reply(status())
    case "cancelPreparation":
      cancelOperation(); reply(answer(true))
    case "restoreClipboard", "discardSavedClipboard":
      let discard = call.method == "discardSavedClipboard"
      let overwrite = args["overwriteChanged"] as? Bool == true
      begin(reply) { [weak self] id in
        guard let self, let saved = IOSPhoneClipboard.shared.restorationID else {
          return ["ok": false, "code": "ERR_PHONE_CLIPBOARD_STALE"]
        }
        let prompt: String
        if discard { prompt = "丢弃本 App 内存中保存的旧剪贴板副本，之后无法恢复它。现在的剪贴板保持原样。" }
        else if overwrite { prompt = "请先核对目标应用已完成或取消粘贴。这会用保存的旧内容覆盖现在的剪贴板，即使剪贴板已被其他操作更改。恢复内容仅此设备可用。" }
        else { prompt = "请先核对目标应用已完成或取消粘贴。只在剪贴板仍属于上次临时输入时恢复原内容；发现后续复制会停止恢复。恢复内容仅此设备可用。" }
        let selected = await self.ask(title: discard ? "丢弃保存的剪贴板？" : "恢复原剪贴板？",
          message: prompt, choices: [("confirm", discard ? "丢弃旧副本" : "已核对，恢复"), ("cancel", "取消")])
        guard selected == "confirm", self.current(id), self.foreground,
          IOSPhoneClipboard.shared.restorationID == saved else { return self.answer(false, code: "ERR_PHONE_CANCELLED") }
        do {
          if discard { try IOSPhoneClipboard.shared.discardSaved(id: saved) }
          else {
            try await IOSPhoneClipboard.shared.restore(id: saved, overwriteChanged: overwrite,
              current: { [weak self] in self?.current(id) == true })
          }
          return self.answer(true)
        } catch { return self.answer(false, code: self.safeCode(error)) }
      }
    case "clearPairing":
      guard foreground else { reply(answer(false, code: "ERR_PHONE_FOREGROUND_REQUIRED")); return }
      cancelOperation()
      defaults.set(false, forKey: "dsh.ios.phone.link.enabled")
      defaults.set(false, forKey: "dsh.ios.phone.xctest.enabled")
      do {
        try pairing.revoke()
        try removeLegacy()
        reply(answer(true))
      } catch { reply(answer(false, code: safeCode(error))) }
      emit()
    case "setEnabled":
      guard let value = args["enabled"] as? Bool else { reply(answer(false, code: "ERR_PHONE_ARGUMENTS")); return }
      if !value {
        defaults.set(false, forKey: "dsh.ios.phone.link.enabled")
        cancelOperation(); invalidate(); reply(answer(true)); emit(); return
      }
      begin(reply) { [weak self] id in
        guard let self else { return ["ok": false, "code": "ERR_PHONE_CANCELLED"] }
        let allowed = await self.ask(title: "启用这台手机的开发者连接？",
          message: "配对凭据可以连接本机开发者服务，用于读屏、触摸和输入。每个手机任务首次需要批准，授权最多 30 分钟；可随时暂停、关闭连接或清除凭据。",
          choices: [("enable", "启用"), ("cancel", "取消")])
        guard allowed == "enable", self.current(id), self.foreground else { return self.answer(false, code: "ERR_PHONE_CANCELLED") }
        guard self.pairing.hasRecord, !self.legacyPresent else { return self.answer(false, code: "ERR_PHONE_PAIRING_REQUIRED") }
        self.invalidate(); self.defaults.set(true, forKey: "dsh.ios.phone.link.enabled")
        return self.answer(true)
      }
    case "setXCTestEnabled":
      guard let value = args["enabled"] as? Bool else { reply(answer(false, code: "ERR_PHONE_ARGUMENTS")); return }
      if !value {
        defaults.set(false, forKey: "dsh.ios.phone.xctest.enabled")
        cancelOperation(); invalidate(); reply(answer(true)); emit(); return
      }
      begin(reply) { [weak self] id in
        guard let self else { return ["ok": false, "code": "ERR_PHONE_CANCELLED"] }
        let allowed = await self.ask(title: "启用 XCTest 增强？",
          message: "需要另外安装并签名 PhoneRunner。它能提供元素树；部分应用可能要求重新登录或拒绝使用。默认仍是 CoreDevice，可在应用规则中选择。",
          choices: [("enable", "启用增强"), ("cancel", "取消")])
        guard allowed == "enable", self.current(id), self.foreground else { return self.answer(false, code: "ERR_PHONE_CANCELLED") }
        self.invalidate(); self.defaults.set(true, forKey: "dsh.ios.phone.xctest.enabled")
        return self.answer(true)
      }
    case "setAppBackend":
      guard foreground, let bundle = args["app"] as? String, Self.bundleID(bundle),
        let backend = args["backend"] as? String, ["automatic", "coredevice", "xctest"].contains(backend),
        backend != "xctest" || xctestEnabled else { reply(answer(false, code: "ERR_PHONE_ARGUMENTS")); return }
      var routes = appRoutes
      if backend == "automatic" { routes.removeValue(forKey: bundle) } else { routes[bundle] = backend }
      guard routes.count <= 512 else { reply(answer(false, code: "ERR_PHONE_ARGUMENTS")); return }
      invalidate(); defaults.set(routes, forKey: "dsh.ios.phone.app-routes")
      reply(answer(true)); emit()
    case "importPairing", "migrateLegacyPairing":
      guard !pairingReader.isBusy else { reply(answer(false, code: "ERR_PHONE_BUSY")); return }
      let migrate = call.method == "migrateLegacyPairing"
      begin(reply) { [weak self] id in
        guard let self else { return ["ok": false, "code": "ERR_PHONE_CANCELLED"] }
        let selected = await self.ask(title: "怎样保存配对凭据？",
          message: "记住：保存在本机钥匙串，不同步、不备份，需设置设备解锁密码；移除密码会使记录失效。仅本次：只放内存，退出 App 后清除。" + (migrate ? "迁移成功后会删除 App 文稿中的旧配对文件。" : "原始导入文件仍由你自行保管。"),
          choices: [("device", "记住在这台手机上（推荐）"), ("session", "只用这一次"), ("cancel", "取消")])
        guard let selected, let storage = IOSPhonePairingStore.Storage(rawValue: selected), self.current(id), self.foreground else {
          return self.answer(false, code: "ERR_PHONE_CANCELLED")
        }
        let url: URL?
        if migrate { url = self.legacyPresent ? self.legacy : nil } else { url = await self.pickPairing() }
        guard let url, self.current(id), self.foreground else { return self.answer(false, code: "ERR_PHONE_CANCELLED") }
        do {
          let record = try await self.pairingReader.read(url, scoped: !migrate, ownerID: id)
          guard self.current(id), self.foreground else { return self.answer(false, code: "ERR_PHONE_CANCELLED") }
          try self.pairing.replace(record, storage: storage)
          if migrate { try self.removeLegacy() }
          return self.answer(true)
        } catch { return self.answer(false, code: self.safeCode(error)) }
      }
    case "checkConnection", "mountDDI":
      let mount = call.method == "mountDDI"
      begin(reply) { [weak self] id in
        guard let self else { return ["ok": false, "code": "ERR_PHONE_CANCELLED"] }
        let coreOwner = "settings:" + id.uuidString
        guard self.enabled, self.pairing.hasRecord, !self.legacyPresent else { return self.answer(false, code: "ERR_PHONE_LINK_DISABLED") }
        guard !IOSPhoneControl.shared.hasActivePhoneTask else { return self.answer(false, code: "ERR_PHONE_BUSY") }
        if mount {
          let allowed = await self.ask(title: "准备本机开发者镜像？",
            message: "需要时会下载约 17 MB 的固定校验镜像，并向 Apple 请求本机个性化，再挂载到这台手机。镜像来自 DeveloperDiskImage 镜像仓库；不会卸载或替换其他正在使用的镜像。",
            choices: [("mount", "下载并挂载"), ("cancel", "取消")])
          guard allowed == "mount", self.current(id), self.foreground else { return self.answer(false, code: "ERR_PHONE_CANCELLED") }
        }
        let live = { [weak self] in self?.current(id) == true && self?.enabled == true }
        var checked = await self.core.prepare(ownerID: coreOwner, allowDDIMount: mount, current: live)
        if mount, case .failure(let failure) = checked, failure.code == "ERR_PHONE_DDI_CACHE_REQUIRED",
          let name = failure.variant, let variant = IOSPhoneDDICache.Variant(rawValue: name), live() {
          do {
            try await self.cache.prepare(variant) { [weak self] done, total in
              guard let self, self.current(id) else { return }
              self.progress = ["stage": "downloading", "completedBytes": done, "totalBytes": total]
              self.emit()
            }
            guard live() else { return self.answer(false, code: "ERR_PHONE_CANCELLED") }
            checked = await self.core.prepare(ownerID: coreOwner, allowDDIMount: true, current: live)
          } catch { self.core.stop(ownerID: coreOwner); return self.answer(false, code: self.safeCode(error)) }
        }
        guard live() else { self.core.stop(ownerID: coreOwner); return self.answer(false, code: "ERR_PHONE_CANCELLED") }
        let snapshot = self.core.state
        self.lastCheck = ["time": Date().timeIntervalSince1970, "connection": snapshot]
        self.core.stop(ownerID: coreOwner)
        switch checked {
        case .success: return self.answer(true)
        case .failure(let failure): return self.answer(false, code: failure.code)
        }
      }
    default: reply(FlutterMethodNotImplemented)
    }
  }

  private func begin(_ reply: @escaping FlutterResult, work: @escaping @MainActor (UUID) async -> [String: Any]) {
    guard foreground else { reply(answer(false, code: "ERR_PHONE_FOREGROUND_REQUIRED")); return }
    guard operationID == nil else { reply(answer(false, code: "ERR_PHONE_BUSY")); return }
    let id = UUID(); operationID = id; result = reply; progress = [:]
    operation = Task { [weak self] in
      guard let self, self.current(id) else { return }
      let value = await work(id)
      guard self.operationID == id else { return }
      let callback = self.result
      self.result = nil; self.operationID = nil; self.operation = nil; self.progress = [:]
      var completed = value; completed["status"] = self.status()
      self.emit(); callback?(completed)
    }
    emit()
  }

  private func current(_ id: UUID) -> Bool { operationID == id && !Task.isCancelled }
  private func cancelOperation() {
    let retired = operationID
    let callback = result; result = nil; operationID = nil
    let oldTask = operation; operation = nil
    let selected = choice; choice = nil
    let picked = pickedFile; pickedFile = nil
    let oldModal = modal; modal = nil; progress = [:]
    // Snapshot and detach every old resource before native/status callbacks can
    // reenter and begin another setup operation.
    if let retired { pairingReader.cancel(ownerID: retired) }
    oldTask?.cancel()
    if let retired { core.stop(ownerID: "settings:" + retired.uuidString) }
    selected?.resume(returning: nil); picked?.resume(returning: nil)
    oldModal?.dismiss(animated: false)
    callback?(answer(false, code: "ERR_PHONE_CANCELLED"))
  }

  private func invalidate() {
    generation = UUID(); lastCheck = [:]
    core.stop(); IOSPhoneSelfRunner.shared.stop()
    IOSPhoneControl.shared.revokePhoneTask()
  }

  private func ask(title: String, message: String, choices: [(String, String)]) async -> String? {
    guard foreground, let host = presenter(), host.viewIfLoaded?.window != nil, host.presentedViewController == nil else { return nil }
    return await withCheckedContinuation { continuation in
      let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
      for (id, label) in choices {
        alert.addAction(UIAlertAction(title: label, style: id == "cancel" ? .cancel : .default) { [weak self, weak alert] _ in
          guard let self, self.modal === alert else { return }
          let callback = self.choice; self.choice = nil; self.modal = nil
          // The following step may present Files. Wait until this alert is
          // actually gone instead of presenting from a dismissing controller.
          alert?.dismiss(animated: true) { callback?.resume(returning: id) }
        })
      }
      choice = continuation; modal = alert
      host.present(alert, animated: true)
    }
  }

  private func pickPairing() async -> URL? {
    guard foreground, let host = presenter(), host.viewIfLoaded?.window != nil, host.presentedViewController == nil else { return nil }
    return await withCheckedContinuation { continuation in
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.propertyList, .data], asCopy: false)
      picker.allowsMultipleSelection = false; picker.delegate = self
      pickedFile = continuation; modal = picker
      host.present(picker, animated: true)
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard modal === controller else { return }
    let callback = pickedFile; pickedFile = nil; modal = nil
    callback?.resume(returning: urls.count == 1 ? urls[0] : nil)
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard modal === controller else { return }
    let callback = pickedFile; pickedFile = nil; modal = nil
    callback?.resume(returning: nil)
  }

  private func removeLegacy() throws {
    guard let legacy, FileManager.default.fileExists(atPath: legacy.path) else { return }
    // Remove only the app's historical import location; never delete the file
    // selected from Files. A symlink itself is removed, not its target.
    guard unlink(legacy.path) == 0 else { throw IOSPhonePairingError.storage }
  }
  @objc private func enteredBackground() {
    if choice != nil || pickedFile != nil { cancelOperation(); emit() }
  }
  @objc private func protectedDataUnavailable() {
    cancelOperation(); invalidate(); emit()
  }
  private static func bundleID(_ value: String) -> Bool {
    value.utf8.count <= 255 && value.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
  }
  private func safeCode(_ error: Error) -> String {
    (error as? IOSPhonePairingError)?.code ?? (error as? IOSPhoneDDIError)?.rawValue
      ?? (error as? IOSPhoneClipboardError)?.rawValue
      ?? (error as? IOSPhonePairingReadError)?.rawValue ?? "ERR_PHONE_CONFIGURATION"
  }
  private func answer(_ ok: Bool, code: String = "OK") -> [String: Any] { ["ok": ok, "code": code, "status": status()] }
  private func emit() { sink?(status()) }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events; emit(); return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
}

private enum IOSPhonePairingReadError: String, Error {
  case busy = "ERR_PHONE_BUSY"
  case cancelled = "ERR_PHONE_CANCELLED"
}

/// One physical file-provider read at a time. Cancellation releases only the
/// awaiting UI operation; the slot remains occupied until the synchronous
/// coordinator and its scoped read actually return. No credentials are written
/// here, and a cancelled job's late Data never resumes a new operation.
@MainActor
private final class IOSPhonePairingFileReader {
  @MainActor
  private final class Read {
    let ownerID: UUID
    var continuation: CheckedContinuation<Data, Error>?
    var cancelled = false
    init(ownerID: UUID) { self.ownerID = ownerID }
  }

  private let queue = DispatchQueue(label: "io.github.ccch1mneyyy.dshgo.pairing-read", qos: .userInitiated)
  private var active: Read?
  var isBusy: Bool { active != nil }

  func read(_ url: URL, scoped: Bool, ownerID: UUID) async throws -> Data {
    guard !Task.isCancelled else { throw IOSPhonePairingReadError.cancelled }
    guard active == nil else { throw IOSPhonePairingReadError.busy }
    let pending = Read(ownerID: ownerID)
    active = pending
    let data = try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
        guard !Task.isCancelled, !pending.cancelled else {
          if active === pending { active = nil }
          continuation.resume(throwing: IOSPhonePairingReadError.cancelled)
          return
        }
        pending.continuation = continuation
        queue.async { [self, pending] in
          let result = Result { try Self.readOnWorker(url, scoped: scoped) }
          Task { @MainActor in self.finished(pending, result: result) }
        }
      }
    }, onCancel: { [weak self, weak pending] in
      Task { @MainActor in
        guard let self, let pending else { return }
        self.cancel(pending)
      }
    })
    // The task flag is checked as well as the per-job latch: a worker return
    // and the queued cancellation callback may race on the main actor.
    guard !Task.isCancelled, !pending.cancelled else { throw IOSPhonePairingReadError.cancelled }
    return data
  }

  func cancel(ownerID: UUID) {
    guard let pending = active, pending.ownerID == ownerID else { return }
    cancel(pending)
  }

  private func cancel(_ pending: Read) {
    guard active === pending else { return }
    pending.cancelled = true
    let continuation = pending.continuation
    pending.continuation = nil
    continuation?.resume(throwing: IOSPhonePairingReadError.cancelled)
    // Keep `active`: cancelling this waiter does not stop NSFileCoordinator.
  }

  private func finished(_ pending: Read, result: Result<Data, Error>) {
    guard active === pending else { return }
    active = nil
    let continuation = pending.continuation
    pending.continuation = nil
    guard !pending.cancelled else { return }
    continuation?.resume(with: result)
  }

  nonisolated private static func readOnWorker(_ url: URL, scoped: Bool) throws -> Data {
    let accessed = scoped && url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    var coordinationError: NSError?
    var result: Result<Data, Error> = .failure(IOSPhonePairingError.invalid)
    // A new coordinator is created and used only on this worker invocation.
    // It may wait on a provider/download; no main-thread work waits synchronously
    // for it, and no second physical read starts while it remains in flight.
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { selected in
      do {
        let descriptor = open(selected.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw IOSPhonePairingError.invalid }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_size > 0, info.st_size <= IOSPhonePairingRecord.maximumBytes else { throw IOSPhonePairingError.tooLarge }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: IOSPhonePairingRecord.maximumBytes + 1),
          !data.isEmpty, data.count <= IOSPhonePairingRecord.maximumBytes else { throw IOSPhonePairingError.tooLarge }
        result = .success(try IOSPhonePairingRecord.normalized(data))
      } catch { result = .failure(error) }
    }
    guard coordinationError == nil else { throw IOSPhonePairingError.invalid }
    return try result.get()
  }
}
