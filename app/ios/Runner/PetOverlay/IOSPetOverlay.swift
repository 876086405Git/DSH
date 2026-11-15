import Flutter
import UIKit

/// iOS implementation of the existing dsh/pet_overlay contract. Register once
/// with the same Flutter registrar as DshPlugin. All task IDs come from the
/// authenticated IOSPhoneControl owner, never from this method channel.
@MainActor
final class IOSPetOverlay: NSObject {
  static let shared = IOSPetOverlay()

  var onTaskPauseRequested: ((Int) -> Void)?
  var onTaskStopConfirmed: ((Int) -> Void)?
  var onTaskResumeConfirmed: ((Int) -> Void)?
  var onKeepingAliveChanged: ((Bool) -> Void)?

  private let picture = PetOverlayPictureInPicture()
  private var channel: FlutterMethodChannel?
  private var renderer: PetOverlayFrameRenderer?
  private var state = PetOverlayState()
  private var policy = PetOverlayPolicy()
  private var clock = PetOverlayFrameClock()
  private var timer: Timer?
  private var notifications: [NSObjectProtocol] = []
  private weak var embeddedHost: UIView?
  private var sourceConstraints: [NSLayoutConstraint] = []
  private var failure = PetOverlayFailureState()
  private var lastError: String? {
    get { failure.code }
    set {
      if let newValue { failure.record(newValue) } else { failure.clear() }
    }
  }
  private var lastStatus: NSDictionary?
  private var lastRender: RenderKey?
  private var outputSize = CGSize(width: 480, height: 318)
  private var backpressure = 0
  private var manualAnimationPaused = false
  private var publishedKeepingAlive: Bool?
  private weak var prompt: UIAlertController?
  private var dismissPrompt: (() -> Void)?
  private var stopPromptTaskID: Int?

  private static let enabledKey = "dsh.ios.petOverlay.enabled"
  private static let alwaysKey = "dsh.ios.petOverlay.alwaysShow"
  private static let optionalDefaultsKey = "dsh.ios.petOverlay.optionalDefaultsApplied"

  /// The optional overlay starts off, including the first upgrade from the
  /// old required-PiP flow. A later explicit user choice is preserved.
  static func configuration(from defaults: UserDefaults) -> (enabled: Bool, alwaysShow: Bool) {
    if !defaults.bool(forKey: optionalDefaultsKey) {
      defaults.set(false, forKey: enabledKey)
      defaults.set(false, forKey: alwaysKey)
      defaults.set(true, forKey: optionalDefaultsKey)
    }
    return (defaults.bool(forKey: enabledKey), defaults.bool(forKey: alwaysKey))
  }

  var sourceView: UIView { picture.sourceView }

  /// Configuration/asset readiness, not a claim that iOS is running us in the
  /// background. It is an optional execution source, not phone admission.
  var isUsable: Bool {
    policy.enabled && !policy.snoozed && picture.supported && lastError == nil &&
      UIApplication.shared.isProtectedDataAvailable && picture.audioMayPrepare &&
      state.packID != nil && renderer?.pack?.id == state.packID
  }

  var isKeepingAlive: Bool {
    policy.hasDemand && isUsable && UIApplication.shared.isProtectedDataAvailable && picture.keepingAlive
  }

  var statusSnapshot: [String: Any] {
    // An if chain rather than nested `??` with ternaries, which may not type-check in time.
    let reason: String?
    if let lastError {
      reason = lastError
    } else if policy.enabled && !UIApplication.shared.isProtectedDataAvailable {
      reason = "overlay_device_locked"
    } else if policy.enabled, let blocker = picture.audioPreparationBlocker {
      reason = blocker
    } else if policy.enabled && state.packID == nil {
      reason = "overlay_pet_not_selected"
    } else if policy.hasDemand && inForeground && !picture.inlineVisible {
      // A missing/hidden inline host is current presentation state, not a
      // lasting failure that blocks a later phone task from attaching its source.
      reason = "overlay_source_missing"
    } else {
      reason = nil
    }
    return [
      "enabled": policy.enabled, "alwaysShow": policy.alwaysShow,
      // iOS has no Android overlay permission. Supported is not the same as
      // possible/active; those remain explicit, separately observable fields.
      "permission": picture.supported ? "granted" : "denied",
      "canDraw": picture.supported, "accessibility": false,
      "snoozed": policy.snoozed, "showing": picture.active && !picture.suspended,
      "sdk": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
      "manufacturer": "Apple", "platform": "ios", "backend": "pictureInPicture",
      "supported": picture.supported, "possible": picture.possible,
      "active": picture.active, "suspended": picture.suspended,
      "sourceAttached": picture.sourceView.window != nil,
      "sourceVisible": inForeground && picture.inlineVisible,
      "audioSessionConfigured": picture.audioConfigured, "usable": isUsable,
      "keepingAlive": isKeepingAlive, "paused": policy.paused,
      "phoneTaskActive": policy.task != nil,
      "taskId": policy.task.map { $0.id as Any } ?? NSNull(),
      "needsStopConfirmation": policy.needsStopConfirmation,
      "requiresForegroundConfirmation": true,
      "errorCode": reason.map { $0 as Any } ?? NSNull(),
    ]
  }

  private override init() {
    super.init()
    let defaults = UserDefaults.standard
    let configuration = Self.configuration(from: defaults)
    policy.enabled = configuration.enabled
    policy.alwaysShow = configuration.alwaysShow
    picture.onChange = { [weak self] in self?.pictureChanged() }
    picture.onRecoveryPossible = { [weak self] in self?.recoverTransientFailure() }
    picture.onFailure = { [weak self] code in
      guard let self else { return }
      self.lastError = code
      self.evaluate()
    }
    picture.onUnexpectedStop = { [weak self] in
      guard let self else { return }
      self.policy.snoozed = true
      self.evaluate()
    }
    picture.onSetPlaying = { [weak self] playing in
      guard let self else { return false }
      if self.policy.task != nil {
        if !playing { self.pauseCurrentTask() }
        // A second system play tap cannot clear the admission lock. The user
        // must return to the app and explicitly choose Continue or Stop.
        if self.policy.paused { self.policy.requestRestore(); self.presentStopConfirmation() }
        self.renderNow(force: true)
        self.emit()
        return !self.policy.paused
      }
      self.manualAnimationPaused = !playing
      self.renderNow(force: true)
      return playing
    }
    picture.onRestore = { [weak self] completion in
      guard let self else { completion(false); return }
      self.policy.requestRestore()
      self.restoreConversation()
      self.presentStopConfirmation()
      completion(self.foregroundWindow() != nil)
    }
    picture.onRenderSize = { [weak self] requested in
      guard let self else { return }
      let width = min(960, max(480, (requested.width / 2).rounded(.up) * 2))
      let height = (width * 318 / 480 / 2).rounded(.up) * 2
      let size = CGSize(width: width, height: height)
      if self.outputSize != size { self.outputSize = size; self.renderNow(force: true) }
    }
    observe(UIApplication.didBecomeActiveNotification) { [weak self] in self?.becameActive() }
    observe(UIApplication.didEnterBackgroundNotification) { [weak self] in
      guard let self else { return }
      self.cancelPrompt()
      self.updateDrawing()
      self.emit()
    }
    observe(UIApplication.protectedDataWillBecomeUnavailableNotification) { [weak self] in
      guard let self else { return }
      if self.policy.hasDemand { self.lastError = "overlay_device_locked" }
      self.pauseCurrentTask()
      self.picture.stop()
      self.stopDrawing()
      self.emit()
    }
    observe(UIApplication.protectedDataDidBecomeAvailableNotification) { [weak self] in
      self?.recoverTransientFailure()
    }
    observe(UIAccessibility.reduceMotionStatusDidChangeNotification) { [weak self] in self?.renderNow(force: true) }
    observe(UIApplication.didReceiveMemoryWarningNotification) { [weak self] in
      guard let self, !self.policy.hasDemand else { return }
      self.renderer?.clear()
      self.emit()
    }
  }

  func register(registrar: any FlutterPluginRegistrar) {
    cancelPrompt()
    channel?.setMethodCallHandler(nil)
    let next = FlutterMethodChannel(name: "dsh/pet_overlay", binaryMessenger: registrar.messenger())
    channel = next
    renderer = PetOverlayFrameRenderer { path in
      Bundle.main.url(forResource: registrar.lookupKey(forAsset: path), withExtension: nil)
    }
    state = PetOverlayState()
    lastRender = nil
    next.setMethodCallHandler { [weak self, weak next] call, result in
      guard let self, let next, self.channel === next else {
        result(FlutterError(code: "overlay_detached", message: "Pet overlay engine detached", details: nil)); return
      }
      self.handle(call, result: result)
    }
    evaluate()
  }

  /// A mainline status card can host the same source, replacing the temporary
  /// visible native preview. Call on the main thread with an onscreen view.
  func attachSource(to host: UIView) {
    embeddedHost = host
    detachSource()
    if policy.hasDemand { attachVisibleSource() }
    evaluate()
  }

  func beginPhoneTask(id: Int, sessionID: String, line: String? = nil) {
    let previous = policy.task?.id
    guard policy.begin(id: id, sessionID: sessionID, line: line) else { return }
    if previous != id {
      manualAnimationPaused = false
      if stopPromptTaskID != nil {
        prompt?.dismiss(animated: false)
        prompt = nil
        stopPromptTaskID = nil
        dismissPrompt = nil
      }
    }
    evaluate()
  }

  func updatePhoneTask(id: Int, line: String?, progress: Double? = nil) {
    policy.update(id: id, line: line, progress: progress)
    renderNow(force: true)
    emit()
  }

  func endPhoneTask(id: Int) {
    guard policy.end(id: id) else { return }
    if stopPromptTaskID == id {
      prompt?.dismiss(animated: false)
      prompt = nil
      stopPromptTaskID = nil
      dismissPrompt = nil
    }
    picture.setPaused(false)
    // Immediate release unless the user separately selected alwaysShow.
    evaluate()
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "push":
      state = PetOverlayState(args)
      evaluate()
      result(nil)
    case "status", "permissionStatus": result(statusSnapshot)
    case "setEnabled":
      guard let enabled = args["enabled"] as? Bool else { return badArguments(result) }
      if !enabled {
        cancelPrompt()
        policy.enabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        evaluate(); result(statusSnapshot)
      } else if policy.enabled {
        result(statusSnapshot)
      } else {
        changeWithConsent(always: false, result: result)
      }
    case "setAlwaysShow":
      guard let on = args["on"] as? Bool else { return badArguments(result) }
      if !on {
        cancelPrompt()
        policy.alwaysShow = false
        UserDefaults.standard.set(false, forKey: Self.alwaysKey)
        evaluate(); result(statusSnapshot)
      } else if policy.alwaysShow {
        result(statusSnapshot)
      } else {
        changeWithConsent(always: true, result: result)
      }
    case "unsnooze":
      guard inForeground else { return foregroundRequired(result) }
      picture.retryFromUser()
      policy.snoozed = false
      lastError = nil
      evaluate(); result(statusSnapshot)
    case "requestPermission": result(picture.supported)
    case "openAppDetails": result(false) // No app-specific Android-style PiP permission page.
    case "startPictureInPicture":
      guard inForeground else { return foregroundRequired(result) }
      evaluate()
      guard policy.hasDemand, isUsable, picture.inlineVisible else { result(false); return }
      result(picture.startFromUser())
    case "reviewPausedTask":
      guard inForeground else { return foregroundRequired(result) }
      policy.requestRestore()
      restoreConversation()
      presentStopConfirmation()
      result(statusSnapshot)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func changeWithConsent(always: Bool, result: @escaping FlutterResult) {
    guard inForeground else { return foregroundRequired(result) }
    guard picture.supported else { lastError = "overlay_unsupported"; result(statusSnapshot); return }
    guard !always || policy.enabled else {
      result(FlutterError(code: "overlay_disabled", message: "Enable the pet overlay first", details: nil)); return
    }
    guard prompt == nil, let presenter = presenter(), presenter.presentedViewController == nil else {
      result(FlutterError(code: "overlay_busy", message: "A foreground dialog is already open", details: nil)); return
    }
    let title = words(always ? "Always show the pet?" : "Enable the picture-in-picture pet?",
      always ? "始终显示宠物？" : "开启宠物画中画？")
    let message = always
      ? words("The pet may keep its video and audio session active after phone control ends, allowing the local engine to continue while Picture in Picture is playing. iOS may interrupt it. This uses more battery; you can turn it off at any time.",
          "手机操控任务结束后，宠物可以继续播放画中画，让本机引擎在画中画有效时继续运行。系统仍可能中断，会增加耗电；你随时可以关闭。")
      : words("While a phone-control task is running, a visible pet video can continue in Picture in Picture when you leave DSH Go. iOS may interrupt it. This uses an audio session and may affect other audio. It stops when the task ends unless you separately choose Always show.",
          "手机操控任务进行时，离开 DSH Go 后可以在画中画里继续显示宠物。系统仍可能中断。它会使用音频会话，可能影响其他音频；任务结束即收起，除非另行选择始终显示。")
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    prompt = alert
    var answered = false
    let finish: (Bool) -> Void = { [weak self, weak alert] accepted in
      guard !answered else { return }; answered = true
      guard let self else { result(nil); return }
      let ownsPrompt = self.prompt === alert
      if ownsPrompt { self.dismissPrompt = nil; self.prompt = nil }
      if accepted && ownsPrompt && self.inForeground {
        if always { self.policy.alwaysShow = true; UserDefaults.standard.set(true, forKey: Self.alwaysKey) }
        else { self.policy.enabled = true; UserDefaults.standard.set(true, forKey: Self.enabledKey) }
        self.policy.snoozed = false
        self.picture.retryFromUser()
        self.lastError = nil
        self.evaluate()
      }
      result(self.statusSnapshot)
    }
    dismissPrompt = { finish(false) }
    alert.addAction(UIAlertAction(title: words("Cancel", "取消"), style: .cancel) { _ in finish(false) })
    alert.addAction(UIAlertAction(title: words("Enable", "开启"), style: .default) { _ in finish(true) })
    presenter.present(alert, animated: true)
  }

  private func evaluate() {
    // Keep the visible PiP running, but exclude its animated video and task
    // text from system captures during phone control. Normal pet screenshots
    // remain available after the task ends.
    picture.sourceView.displayLayer.preventsCapture = policy.task != nil
    if policy.enabled, let id = state.packID, let renderer {
      do {
        _ = try renderer.load(packID: id)
        if lastError == "overlay_pack_invalid" || lastError == "overlay_pack_missing" || lastError == "overlay_sheet_invalid" {
          lastError = nil
        }
      }
      catch { lastError = (error as? PetOverlayPackFailure)?.code ?? "overlay_pack_invalid" }
    }
    guard policy.hasDemand, isUsable else {
      stopDrawing()
      picture.stop()
      detachSource()
      if !policy.enabled || state.packID == nil { renderer?.clear() }
      lastRender = nil
      emit()
      return
    }
    attachVisibleSource()
    if inForeground && !picture.inlineVisible {
      // Intentional for alwaysShow without an onscreen embedded host. Do not
      // prepare from an invisible source or retain overlay_source_missing.
      stopDrawing()
      picture.stop()
      lastRender = nil
      emit()
      return
    }
    picture.setPaused(policy.paused || manualAnimationPaused)
    renderNow(force: true)
    if inForeground {
      do { try picture.prepareInline() }
      catch {
        let code = (error as? PetOverlayPackFailure)?.code ?? "overlay_pip_unavailable"
        if code != "overlay_source_missing" { lastError = code }
        picture.stop()
        stopDrawing()
      }
    }
    emit()
  }

  private func pictureChanged() {
    updateDrawing()
    emit()
  }

  private var drawingAllowed: Bool {
    policy.hasDemand && isUsable &&
      ((inForeground && picture.inlineVisible) || (picture.active && !picture.suspended))
  }

  private func updateDrawing() {
    if drawingAllowed { renderNow(force: false) } else { stopDrawing() }
  }

  private func stopDrawing() {
    timer?.invalidate(); timer = nil
    clock.setPaused(true, now: monotonicMilliseconds)
  }

  private func renderNow(force: Bool) {
    timer?.invalidate(); timer = nil
    guard drawingAllowed, let renderer, let pack = renderer.pack else { return }
    let now = monotonicMilliseconds
    let paused = policy.paused || manualAnimationPaused
    clock.setPaused(paused, now: now)
    var viewState = state
    viewState.reduceMotion = state.reduceMotion || UIAccessibility.isReduceMotionEnabled
    let frame = clock.frame(pack: pack, state: viewState, now: now)
    let wallClock = Date().timeIntervalSince1970 * 1_000
    let dark = picture.sourceView.traitCollection.userInterfaceStyle == .dark
    let key = RenderKey(pack: pack.id, animation: frame.animation.name,
      cell: frame.animation.frames[frame.index].cell, size: state.size,
      bubble: state.visibleBubble(at: wallClock), line: state.quiet ? nil : policy.task?.line,
      progress: policy.task?.progress, paused: paused, dark: dark,
      width: Int(outputSize.width), height: Int(outputSize.height))
    var next = paused ? nil : frame.nextMilliseconds
    if !state.quiet, let bubble = state.bubble, bubble.untilMilliseconds > wallClock {
      let expiry = Int(min(86_400_000, max(1, bubble.untilMilliseconds - wallClock)))
      next = min(next ?? expiry, expiry)
    }
    if force || key != lastRender {
      do {
        let image = try renderer.render(state: viewState, frame: frame, phoneTask: policy.task,
          paused: policy.paused, nowMilliseconds: wallClock, size: outputSize, dark: dark)
        if try picture.enqueue(image) {
          lastRender = key
          backpressure = 0
        } else {
          backpressure += 1
          guard backpressure < 20 else { throw PetOverlayPackFailure("overlay_display_stalled") }
          next = min(next ?? 50, 50)
        }
      } catch {
        lastError = (error as? PetOverlayPackFailure)?.code ?? "overlay_render_failed"
        picture.stop()
        emit()
        return
      }
    }
    if let next {
      timer = Timer.scheduledTimer(withTimeInterval: Double(max(1, next)) / 1_000,
        repeats: false) { [weak self] _ in
          Task { @MainActor in self?.renderNow(force: false) }
        }
    }
  }

  private func pauseCurrentTask() {
    guard let id = policy.requestPause() else { return }
    onTaskPauseRequested?(id)
    picture.setPaused(true)
  }

  private func becameActive() {
    picture.retryAfterForeground()
    failure.recover(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
      audioMayPrepare: picture.audioMayPrepare)
    if picture.active { picture.stop(keepInline: policy.hasDemand && isUsable) }
    evaluate()
    restoreConversation()
    // Keep paused still permits a later foreground confirmation, independently
    // of the one navigation request already consumed for this pause.
    presentStopConfirmation()
  }

  private func recoverTransientFailure() {
    let recovered = failure.recover(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
      audioMayPrepare: picture.audioMayPrepare)
    if recovered || (policy.hasDemand && isUsable) {
      // With no demand this only restores configuration readiness. If a task
      // was paused, evaluate cannot clear that policy or confirm another action.
      evaluate()
    } else {
      emit()
    }
  }

  private func restoreConversation() {
    // Consume before the external navigation callback, including reentrancy.
    guard policy.consumeRestore() else { return }
    if let task = policy.task {
      // Phone requests are owned by the local embedded engine; this is the
      // verified owner session, not whichever chat happens to be visible.
      SystemEntries.send(["kind": "chat", "host": "{\"kind\":\"local\",\"id\":\"local\"}",
        "sessionId": task.sessionID])
    } else if let target = state.target {
      var entry = target.arguments; entry["kind"] = "chat"; SystemEntries.send(entry)
    }
  }

  private func presentStopConfirmation() {
    guard inForeground, policy.needsStopConfirmation, let task = policy.task,
      prompt == nil, let presenter = presenter(), presenter.presentedViewController == nil else { return }
    let id = task.id
    let alert = UIAlertController(title: words("Phone control paused", "手机操控已暂停"),
      message: words("Choose whether to continue this task or stop it. Returning to DSH Go is not approval for another action.",
        "请选择继续或停止本次任务。返回 DSH Go 不会批准新的操作。"), preferredStyle: .alert)
    prompt = alert
    stopPromptTaskID = id
    let finish: () -> Bool = { [weak self, weak alert] in
      guard let self, let alert, self.prompt === alert, self.stopPromptTaskID == id else { return false }
      self.prompt = nil
      self.stopPromptTaskID = nil
      self.dismissPrompt = nil
      return true
    }
    dismissPrompt = { _ = finish() }
    alert.addAction(UIAlertAction(title: words("Keep paused", "保持暂停"), style: .cancel) { _ in _ = finish() })
    alert.addAction(UIAlertAction(title: words("Continue", "继续"), style: .default) { [weak self] _ in
      guard finish(), let self, self.inForeground, let resume = self.onTaskResumeConfirmed,
        self.policy.confirmResume(id: id) else { return }
      self.lastError = nil
      self.picture.retryFromUser()
      self.policy.snoozed = false
      resume(id)
      self.evaluate()
    })
    alert.addAction(UIAlertAction(title: words("Stop task", "停止任务"), style: .destructive) { [weak self] _ in
      guard finish(), let self, self.inForeground, self.policy.mayConfirmStop(id: id) else { return }
      self.policy.consumeRestore()
      self.onTaskStopConfirmed?(id)
      // The phone owner ends the exact task through endPhoneTask; a failed or
      // stale callback cannot make us pretend its task has ended.
      self.emit()
    })
    presenter.present(alert, animated: true)
  }

  private func attachVisibleSource() {
    guard inForeground else { return }
    let source = picture.sourceView
    if let embeddedHost {
      if source.superview !== embeddedHost {
        detachSource()
        embeddedHost.addSubview(source)
        source.translatesAutoresizingMaskIntoConstraints = false
        sourceConstraints = [source.leadingAnchor.constraint(equalTo: embeddedHost.leadingAnchor),
          source.trailingAnchor.constraint(equalTo: embeddedHost.trailingAnchor),
          source.topAnchor.constraint(equalTo: embeddedHost.topAnchor),
          source.bottomAnchor.constraint(equalTo: embeddedHost.bottomAnchor)]
        NSLayoutConstraint.activate(sourceConstraints)
      }
    } else if policy.allowsTemporarySource, let window = foregroundWindow() {
      if source.superview !== window {
        detachSource()
        window.addSubview(source)
        source.translatesAutoresizingMaskIntoConstraints = false
        // Task-only transitional preview, below the top bar. The final visible
        // status-card placement remains owned by mainline through attachSource.
        sourceConstraints = [source.widthAnchor.constraint(equalToConstant: 160),
          source.heightAnchor.constraint(equalToConstant: 106),
          source.trailingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -12),
          source.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 60)]
        NSLayoutConstraint.activate(sourceConstraints)
      }
    } else {
      detachSource()
    }
    source.superview?.layoutIfNeeded()
  }

  private func detachSource() {
    NSLayoutConstraint.deactivate(sourceConstraints)
    sourceConstraints.removeAll()
    picture.sourceView.removeFromSuperview()
  }

  private func cancelPrompt() {
    let visible = prompt
    let cancel = dismissPrompt
    dismissPrompt = nil
    prompt = nil
    stopPromptTaskID = nil
    visible?.dismiss(animated: false)
    // Result callbacks can re-enter a method handler. Do not erase a new
    // prompt's cleanup hook after delivering the old prompt's result.
    cancel?()
  }

  private var inForeground: Bool { UIApplication.shared.applicationState == .active }
  private var monotonicMilliseconds: Int { Int(ProcessInfo.processInfo.systemUptime * 1_000) }

  private func foregroundWindow() -> UIWindow? {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
      .flatMap { $0.windows }.first { $0.isKeyWindow }
  }

  private func presenter() -> UIViewController? {
    var view = foregroundWindow()?.rootViewController
    while let presented = view?.presentedViewController, !(presented is UIAlertController) { view = presented }
    return view
  }

  private func emit() {
    let keepingAlive = isKeepingAlive
    if publishedKeepingAlive != keepingAlive {
      publishedKeepingAlive = keepingAlive
      onKeepingAliveChanged?(keepingAlive)
    }
    let snapshot = statusSnapshot as NSDictionary
    guard lastStatus?.isEqual(snapshot) != true else { return }
    lastStatus = snapshot
    channel?.invokeMethod("status", arguments: statusSnapshot)
  }

  private func observe(_ name: Notification.Name, action: @escaping @MainActor () -> Void) {
    notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil,
      queue: .main) { _ in Task { @MainActor in action() } })
  }

  private func words(_ english: String, _ chinese: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
  }
  private func badArguments(_ result: FlutterResult) {
    result(FlutterError(code: "overlay_arguments", message: "Invalid pet overlay arguments", details: nil))
  }
  private func foregroundRequired(_ result: FlutterResult) {
    result(FlutterError(code: "overlay_foreground_required", message: "Return to DSH Go to confirm", details: nil))
  }

  private struct RenderKey: Equatable {
    let pack: String
    let animation: String
    let cell: Int
    let size: PetOverlaySize
    let bubble: String?
    let line: String?
    let progress: Double?
    let paused: Bool
    let dark: Bool
    let width: Int
    let height: Int
  }
}
