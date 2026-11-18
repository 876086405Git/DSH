import Foundation
import UIKit
import UserNotifications

/// Selects the user-enabled route inside an explicitly granted phone task.
/// The default is the shared CoreDevice owner. XCTest is a separate opt-in;
/// uncertainty after any dispatch never authorizes switching routes or replay.
@MainActor
final class IOSPhoneRunner {
  private static let group = "group.io.github.ccch1mneyyy.dshgo"
  private static let missing =
    "手机操控没有运行，所以这一步没有执行。请告诉用户：先在 Mac 上运行 tooling/ios/phone-runner.sh，让手机操控的测试进程跑起来，再重试。不要自动反复重试。"
  static let coreStopUnconfirmed =
    "ERR_PHONE_STOP_UNCONFIRMED：开发者连接的清理尚未确认，不能继续操控或切换到 XCTest。请告诉用户：彻底关闭 DSH Go 后重新打开，再由用户发起；不要自动重试。"

  private typealias Endpoint = PhoneRunnerEndpoint

  private let actions: IOSPhoneActions
  private let session: URLSession
  private let selfRunner: IOSPhoneSelfRunner
  private let consent: IOSPhoneTaskConsent
  private let core = IOSPhoneCoreDevice.shared
  private let coreActions = IOSPhoneCoreActions()
  private enum Route { case coredevice, xctest }
  private struct Owner: Equatable {
    let runID: String
    let sessionID: String
    let settingsGeneration: UUID
  }
  private var taskOwner: Owner?
  private var lastRoute: Route?
  private var lastXCTestScreen: String?
  private var selfOwnerID = UUID().uuidString
  private var invocationID = UUID()
  private var lastEndpoint: Endpoint?
  private var targetApplication: String?

  init(actions: IOSPhoneActions, selfRunner: IOSPhoneSelfRunner? = nil) {
    self.actions = actions
    self.consent = IOSPhoneTaskConsent(actions: actions)
    self.selfRunner = selfRunner ?? .shared
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.connectionProxyDictionary = [:]
    session = URLSession(configuration: configuration)
    consent.onExpiration = { [weak self] runID, sessionID in
      guard let self, self.taskOwner?.runID == runID, self.taskOwner?.sessionID == sessionID else { return }
      self.retireConnection(ownerID: self.selfOwnerID)
    }
  }

  /// The run is over, and what the user granted was for it.
  func retire() {
    finish()
  }

  func finish() {
    consent.retire()
    taskOwner = nil
    retireConnection(ownerID: selfOwnerID)
  }

  /// An invocation refusal closes only this connection and its observations. It does
  /// not revoke or renew a still-valid task grant. A late refusal has no power
  /// over a newer invocation, even within the same engine/session tuple.
  private func retireConnection(ownerID: String, invocationID: UUID? = nil) {
    guard selfOwnerID == ownerID else { return }
    if let invocationID, self.invocationID != invocationID { return }
    selfOwnerID = UUID().uuidString; self.invocationID = UUID()
    coreActions.invalidate(); lastRoute = nil; lastXCTestScreen = nil
    lastEndpoint = nil
    targetApplication = nil
    consent.onClipboardRefusal = nil
    // Rotate local identities before either backend's synchronous status
    // callback can reenter. Never use an unowned stop for settings preflight.
    selfRunner.stop(ownerID: ownerID)
    core.stop(ownerID: ownerID)
  }

  /// Only the already-authorized runner may return to this app; never launch a
  /// new runner, repeat an unknown action, or choose another destination here.
  func returnToApp(current: () -> Bool) async -> Bool {
    guard let grantedOwner = taskOwner else { return false }
    func permitted() -> Bool {
      current() && self.taskOwner == grantedOwner && self.consent.isGranted
        && IOSPhoneLink.shared.generation == grantedOwner.settingsGeneration
    }
    guard permitted() else { return false }
    if lastRoute == .coredevice {
      let ownerID = selfOwnerID
      let owner = taskOwner
      guard owner != nil, IOSPhoneLink.shared.enabled else { return false }
      let launched = await core.returnToApp(ownerID: ownerID, current: {
        permitted() && self.selfOwnerID == ownerID && self.taskOwner == owner
          && IOSPhoneLink.shared.enabled
      })
      guard launched, permitted(), self.selfOwnerID == ownerID, self.taskOwner == owner,
        let bundle = Bundle.main.bundleIdentifier else { return false }
      return UIApplication.shared.applicationState == .active || IOSPhoneCoreActions.requestForeground(bundle)
    }
    guard permitted(), let endpoint = lastEndpoint,
      endpoint.runId == nil || selfRunner.owns(endpoint),
      let bundle = Bundle.main.bundleIdentifier,
      let url = URL(string: "http://127.0.0.1:\(endpoint.port)/rpc") else { return false }
    var values: [String: Any] = ["method": "open", "params": ["app": bundle],
      "expiresAt": Date().addingTimeInterval(8).timeIntervalSince1970 * 1000]
    if let runId = endpoint.runId { values["runId"] = runId }
    var http = URLRequest(url: url)
    http.httpMethod = "POST"
    http.timeoutInterval = 8
    http.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
    http.httpBody = try? JSONSerialization.data(withJSONObject: values)
    guard let (data, response) = try? await session.data(for: http), permitted(),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      result["ok"] as? Bool == true else { return false }
    return UIApplication.shared.applicationState == .active || IOSPhoneCoreActions.requestForeground(bundle)
  }

  func cancelPreparation() {
    selfRunner.cancelPreparation(ownerID: selfOwnerID)
    IOSPhoneCoreDevice.shared.stop(ownerID: selfOwnerID)
  }

  func run(_ request: IOSPhoneRequest, authorize: @escaping () async -> Bool,
           progress: @escaping (IOSPhoneControl.Phase) -> Void = { _ in },
           current: @escaping () -> Bool) async -> IOSPhoneOutcome {
    guard current(), !Task.isCancelled else { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
    // Consume an old expiry before capturing this call's identities, so a fresh
    // explicit request can ask for a new grant after the old connection closes.
    consent.checkExpiration()
    guard current(), !Task.isCancelled else { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
    let incomingOwner = Owner(runID: request.runId, sessionID: request.owner.sessionId,
      settingsGeneration: IOSPhoneLink.shared.generation)
    if taskOwner != incomingOwner {
      // A different conversation cannot inherit either backend's observations,
      // the previous grant, or its native owner, even when the helper endpoint
      // remains available. This does not cancel the newly claimed bridge call.
      finish()
      taskOwner = incomingOwner
    }
    let invocationID = UUID(); self.invocationID = invocationID
    consent.onClipboardRefusal = nil
    if request.action.kind == "runner-handoff" {
      let result = await handOver(request)
      guard !result.isError, current(), !Task.isCancelled, await authorize(), current() else {
        return .failure("接手调用已结束或未确认，没有执行自动动作。")
      }
      return result
    }
    let link = IOSPhoneLink.shared
    let settingsGeneration = link.generation
    let ownerID = selfOwnerID
    consent.onClipboardRefusal = { [weak self] in
      self?.retireConnection(ownerID: ownerID, invocationID: invocationID)
    }
    let live = { !Task.isCancelled && current() && self.selfOwnerID == ownerID && self.invocationID == invocationID
      && link.generation == settingsGeneration && IOSPhoneControl.shared.enabled
      && !IOSPhoneControl.shared.isPaused
      && request.expiresAt > Date().timeIntervalSince1970 * 1000 }
    guard live() else { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
    guard !link.isPreparing else {
      return .failure("连接设置正在处理另一项准备，请等待完成后重新发起；不是增强开关未开启。")
    }
    guard link.enabled || link.xctestEnabled else {
      return .failure("手机连接和 XCTest 增强均未启用。请由用户在设置中选择；已保存配对不等于授权操控。")
    }
    let plan: IOSPhoneOperation
    do { plan = try IOSPhoneOperation(request) }
    catch { return .failure((error as? IOSPhoneOperationError)?.message ?? "手机动作参数无效。") }
    let method = plan.method
    let needsTarget = plan.needsTarget
    let requiresObservation = plan.requiresObservation
    if method == .open { targetApplication = nil }
    if requiresObservation, lastRoute == nil {
      return .failure("没有本次任务的有效屏幕观察。先用 screen，不要猜编号或重放旧动作。")
    }
    let explicitApp = (plan.parameters["app"] as? String).flatMap { PhoneRunnerAppCatalog.bundleID(for: $0) }
    let preference = explicitApp.flatMap { link.appRoutes[$0] }
    let mustCore = preference == "coredevice"
    let mustXCTest = preference == "xctest"
    let chooseXCTest = mustXCTest || ((requiresObservation || method == .screen) && lastRoute == .xctest)
    guard !chooseXCTest || link.xctestEnabled else { return .failure("XCTest 增强已关闭，没有启动或调用运行器。") }
    guard !mustCore || link.enabled else { return .failure("这个应用固定使用 CoreDevice，但本机连接已关闭。") }
    let returnTarget = needsTarget ? targetApplication : nil
    let returnDescription = returnTarget.map {
      "\n\n本任务已选择目标应用：\($0)。需要离开 DSH Go 时会请求系统将它置于前台，再重新核对画面；不会重复已经派发的动作。"
    } ?? ""
    let description = plan.consentDescription(targetLabel: coreActions.targetLabel(plan, ownerID: ownerID,
      sessionID: request.owner.sessionId))
      + "\n\n路线由你的设置和可用性决定；XCTest 只在已启用时使用。已经派发或结果不明时不切换重试。"
      + returnDescription
    if IOSPhoneClipboard.shared.hasPendingRestore {
      guard await consent.prepareForeground(request, current: live), live(),
        await IOSPhoneClipboard.shared.resolvePending(request, actions: actions, current: live), live() else {
        retireConnection(ownerID: ownerID, invocationID: invocationID)
        return .failure("请先回到 DSH Go 处理上次剪贴板恢复；没有执行新动作。")
      }
    }
    let preview = coreActions.approvalPreview(plan, ownerID: ownerID, sessionID: request.owner.sessionId)
    guard await consent.approve(request, detail: description,
      needsTarget: returnTarget == nil && (needsTarget || method == .open), preview: preview, current: live),
      live(), await authorize(), live(), consent.isGranted else {
      retireConnection(ownerID: ownerID, invocationID: invocationID)
      return .failure("本次任务没有取得仍有效的授权，没有派发手机动作。不要自动重试。")
    }
    progress(.connecting)

    if !chooseXCTest, link.enabled {
      // A new backend cannot race an owner whose teardown is still unknown.
      selfRunner.stop(ownerID: ownerID)
      let stopDeadline = Date().addingTimeInterval(12)
      while !selfRunner.mayUseMacFallback, live(), Date() < stopDeadline {
        do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
      }
      guard live(), selfRunner.mayUseMacFallback else { return .failure(IOSPhoneSelfRunnerError.faulted.message) }
      let prepared = await core.prepare(ownerID: ownerID, current: live)
      guard live(), consent.isGranted else { core.stop(ownerID: ownerID); return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
      switch prepared {
      case .success(let capabilities):
        // A fresh screen has not captured or dispatched anything yet. When
        // the native probe reports no input, an already enabled enhancement
        // can prepare a NEW XCTest observation, with normal approval below.
        // Never carry a CoreDevice element ID into an XCTest input request.
        let mayEnhance = link.xctestEnabled && !mustCore
          && (explicitApp != nil || !link.appRoutes.values.contains("coredevice"))
        if capabilities["touch"] == false, mayEnhance, method == .screen || method == .open { break }
        if capabilities["touch"] == false, link.xctestEnabled, requiresObservation {
          return .failure(mayEnhance
            ? "XCTest 增强已开启。当前编号来自 CoreDevice 的只读观察；请先调用 screen 获取新的 XCTest 屏幕和编号，再操作。本次没有点击、滚动或输入，不需要重复开启开关。"
            : "XCTest 增强已开启，但当前应用规则不允许自动切换。这次没有派发输入；请用户核对应用后端规则，或 handoff。")
        }
        if lastRoute != .coredevice { coreActions.invalidate(); lastXCTestScreen = nil }
        lastRoute = .coredevice; lastEndpoint = nil
        progress(.executing)
        if needsTarget, let target = targetApplication, UIApplication.shared.applicationState == .active {
          guard live(), consent.isGranted, IOSPhoneCoreActions.requestForeground(target) else {
            return .failure("无法返回本任务的目标应用，没有派发读屏或输入。")
          }
        }
        let outcome = await coreActions.run(plan, request: request, ownerID: ownerID, consent: consent, current: live)
        if !outcome.isError, method == .open { targetApplication = coreActions.lastOpenedApplication }
        return outcome
      case .failure(let failure):
        if failure.code == "ERR_PHONE_STOP_UNCONFIRMED" || core.isFaulted {
          return .failure(Self.coreStopUnconfirmed)
        }
        // Preparing transport is the ONLY automatic fallback point. A screen
        // sharing start or any input is never retried on another backend.
        guard !mustCore, !failure.mayHaveActed, core.maySwitchBackend,
          link.xctestEnabled, !link.appRoutes.values.contains("coredevice"),
          !requiresObservation else {
          return .failure(failure.code + "：本次未完成连接；不自动重复动作。需要镜像时请到连接设置明确准备。")
        }
      }
    }
    guard live(), consent.isGranted else { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
    guard link.xctestEnabled else { return .failure("XCTest 增强已关闭，没有启动或调用运行器。") }
    // A fresh, unknown route is not guessed. The XCTest server also checks the
    // exact live bundle ID against these rules before every observed input.
    if explicitApp == nil, link.appRoutes.values.contains("coredevice"), lastRoute != .xctest {
      return .failure("当前应用身份未核实，不能保证遵守 CoreDevice 专用规则；请先用 CoreDevice，或按准确包名打开目标。")
    }
    switch await Self.stopCoreForXCTest(core, ownerID: ownerID, current: live) {
    case .success: break
    case .failure(let failure):
      if failure.code == "ERR_PHONE_STOP_UNCONFIRMED" { return .failure(Self.coreStopUnconfirmed) }
      if failure.code == "ERR_PHONE_CANCELLED" { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
      return .failure("开发者连接尚未确认停止，不启动 XCTest。")
    }
    guard live(), core.maySwitchBackend else {
      return .failure(core.isFaulted ? Self.coreStopUnconfirmed : "开发者连接尚未确认停止，不启动 XCTest。")
    }
    let useSelfRunner = link.enabled && selfRunner.isConfigured
    var endpoint = useSelfRunner ? nil : readEndpoint()
    if useSelfRunner {
      let prepared = await selfRunner.prepare(ownerID: ownerID, current: live)
      guard live(), consent.isGranted, link.xctestEnabled else { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
      switch prepared {
      case .success(let ready): endpoint = ready
      case .failure(let error):
        // A terminal owner can already have launched a test process. Confirmed
        // teardown is not proof that bootstrap was free of side effects.
        return .failure(error.message + "\n不会在这次失败后自动转向 Mac 运行器；请核对运行器状态后由用户重新发起。")
      }
    }
    guard let endpoint, live(), consent.isGranted else { return .failure(Self.missing) }
    if lastRoute != .xctest { coreActions.invalidate(); lastXCTestScreen = nil }
    lastRoute = .xctest; lastEndpoint = endpoint
    progress(.executing)
    if let returnTarget {
      guard live(), consent.isGranted else { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
      // PiP can make XCTest's controller state look foreground. Request the
      // actual scene activation instead of relying only on activate()'s state shortcut.
      _ = IOSPhoneCoreActions.requestForeground(returnTarget)
      #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
      IOSPhoneSelfRunner.diagnostic("target return begin")
      #endif
      let returned = await call(endpoint, request: request, current: live,
        method: "activate", parameters: ["app": returnTarget])
      guard !returned.isError, live(), consent.isGranted else {
        return .failure("返回已批准目标的结果未确认，未继续派发读屏或输入。\n" + returned.text)
      }
      #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
      IOSPhoneSelfRunner.diagnostic("target return confirmed")
      #endif
    }
    if needsTarget {
      guard await consent.waitForTarget(request, current: live), live(), consent.isGranted else {
        return .failure(consent.targetWaitFailureMessage)
      }
    }
    var arguments = plan.parameters
    if requiresObservation {
      guard let screen = plan.screen ?? lastXCTestScreen, screen == lastXCTestScreen else {
        return .failure("XCTest 屏幕号已过期；请重新 screen。")
      }
      let checked = await call(endpoint, request: request, current: live,
        method: "validate", parameters: ["screen": screen])
      guard !checked.isError, live(), consent.isGranted else {
        return .failure("批准后未能重新核对 XCTest 屏幕，未派发该动作；请重新 screen。")
      }
      // key accepts an omitted screen in the public API, but the actual RPC
      // must carry the exact observation validated in this invocation.
      if method == .key { arguments["screen"] = screen }
      lastXCTestScreen = nil
    }
    if method == .open, let application = explicitApp {
      guard live(), consent.isGranted else { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
      _ = IOSPhoneCoreActions.requestForeground(application)
    }
    let outcome = await call(endpoint, request: request, current: live, parameters: arguments)
    if method == .open, !outcome.isError {
      guard await consent.waitForTarget(request, current: live), live(), consent.isGranted else {
        lastXCTestScreen = nil
        return .failure("应用打开请求已派发，但未确认目标画面和后台接续状态。请核对手机；这次不会自动重复打开。")
      }
    }
    return outcome
  }

  /// The short route-selection wait never creates a fault. A native or local
  /// cleanup fault already blocks switching, so fail before sleeping and on
  /// every iteration rather than spending another twelve seconds on it.
  static func stopCoreForXCTest(_ core: IOSPhoneCoreDevice, ownerID: String,
                               current: () -> Bool) async -> Result<Void, IOSPhoneCoreFailure> {
    guard !Task.isCancelled, current() else { return .failure(.init(code: "ERR_PHONE_CANCELLED")) }
    guard !core.isFaulted else { return .failure(.init(code: "ERR_PHONE_STOP_UNCONFIRMED")) }
    core.stop(ownerID: ownerID)
    let deadline = Date().addingTimeInterval(12)
    while true {
      guard !Task.isCancelled, current() else { return .failure(.init(code: "ERR_PHONE_CANCELLED")) }
      if core.isFaulted { return .failure(.init(code: "ERR_PHONE_STOP_UNCONFIRMED")) }
      if core.maySwitchBackend { return .success(()) }
      if Date() >= deadline { return .failure(.init(code: "ERR_PHONE_STOPPING")) }
      do { try await Task.sleep(nanoseconds: 50_000_000) }
      catch { return .failure(.init(code: "ERR_PHONE_CANCELLED")) }
    }
  }

  private func readEndpoint() -> Endpoint? {
    guard
      let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group),
      let data = try? Data(contentsOf: directory.appendingPathComponent("phone-runner/endpoint.json")),
      data.count <= 4096, let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data), endpoint.isValid(),
      endpoint.runId == nil
    else { return nil }
    return endpoint
  }

  private func call(_ endpoint: Endpoint, request: IOSPhoneRequest, current: @escaping () -> Bool,
                    method: String? = nil, parameters: [String: Any]? = nil) async -> IOSPhoneOutcome {
    let operation = method ?? request.action.method ?? ""
    // Open/activate establish the target and can start from our foreground.
    // Other screen/input RPCs require this controller to be in the background. The open result
    // reaches its caller only after run() verifies that background transition.
    // Internal activation stays outside the model tool catalog.
    let needsTarget = operation != "apps" && operation != "activate" && operation != "open"
    let permitted = { !Task.isCancelled && current() && self.consent.isGranted
      && IOSPhoneLink.shared.xctestEnabled && UIApplication.shared.isProtectedDataAvailable
      && request.expiresAt > Date().timeIntervalSince1970 * 1000
      && (endpoint.runId == nil || self.selfRunner.owns(endpoint))
      && (!needsTarget || UIApplication.shared.applicationState == .background) }
    guard permitted() else {
      return .failure(IOSPhoneSelfRunnerError.cancelled.message)
    }
    guard let url = URL(string: "http://127.0.0.1:\(endpoint.port)/rpc"),
      let controller = Bundle.main.bundleIdentifier, !controller.isEmpty,
      let arguments = parameters ?? (try? JSONSerialization.jsonObject(with: Data((request.action.params ?? "{}").utf8)) as? [String: Any])
    else { return .failure("参数无效。") }
    // This envelope is native-owned; model parameters cannot select a backend,
    // change the controlling app, or remove a user's CoreDevice-only route.
    let now = Date().timeIntervalSince1970 * 1000
    let deadline = min(request.expiresAt, now + min(110, consent.remainingSeconds) * 1000)
    guard deadline > now else { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
    let denied = IOSPhoneLink.shared.appRoutes.filter { $0.value == "coredevice" }.map { $0.key }.sorted()
    var values: [String: Any] = ["method": operation, "params": arguments, "expiresAt": deadline,
      "controllerBundleID": controller, "xctestDeniedBundleIDs": denied]
    if let runId = endpoint.runId { values["runId"] = runId }
    guard let body = try? JSONSerialization.data(withJSONObject: values), body.count <= 192 * 1024 else {
      return .failure("手机调用上下文或应用规则超过大小边界，没有派发动作。")
    }
    var http = URLRequest(url: url)
    http.httpMethod = "POST"
    http.timeoutInterval = max(0.001, (deadline - now) / 1000)
    http.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
    http.httpBody = body
    do {
      let (data, response) = try await IOSPhoneRPCDispatch.perform(http, permitted: permitted,
        send: { [session] request in try await session.data(for: request) })
      guard permitted() else {
        return .failure("动作结果抵达时原调用已失效；结果不明，请核对屏幕，不要自动重试。")
      }
      guard data.count <= 2 * 1024 * 1024 else {
        return .failure("运行器结果超过大小边界；请核对屏幕，不要自动重试。")
      }
      guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return .failure("手机操控返回了无效结果，请核对屏幕，不要自动重试。")
      }
      guard (response as? HTTPURLResponse)?.statusCode == 200, result["ok"] as? Bool == true else {
        let message = result["error"] as? String ?? "手机操控没有完成这一步。"
        return .failure(message + "\n这一步不会自动重试。")
      }
      if let app = result["appBundleID"] as? String, app != Bundle.main.bundleIdentifier,
        PhoneRunnerAppCatalog.bundleID(for: app) == app {
        targetApplication = app
      }
      var text = result["text"] as? String ?? ""
      if method != "validate", let screen = result["screen"] as? String {
        lastXCTestScreen = screen
        text = "XCTest 增强观察（编号仅属于本后端）：\n" + text
      }
      if let warning = result["warning"] as? String { text += "\n（注意：\(warning)）" }
      guard text.utf8.count <= IOSPhoneResultEnvelope.textBytes else {
        lastXCTestScreen = nil
        return .failure("运行器文字结果超过完整返回边界；本次动作可能已经发生，请核对手机，不要自动重试。")
      }
      let image: Data?
      if let encoded = result["image"] as? String {
        guard encoded.utf8.count <= 1200 * 1024, let decoded = Data(base64Encoded: encoded), !decoded.isEmpty,
          decoded.count <= 880 * 1024 else {
          lastXCTestScreen = nil
          return .failure("运行器图片超过完整返回边界；没有截断图片，请重新观察。")
        }
        image = decoded
      } else { image = nil }
      return IOSPhoneOutcome(text: text, isError: false, image: image)
    } catch let error as URLError where error.code == .cannotConnectToHost {
      return .failure(endpoint.runId == nil ? Self.missing : "端上 XCTest 运行器已经不可连接。请检查运行器，不要自动重复这一步。")
    } catch {
      return .failure("手机操控这一步的结果未知，请核对屏幕，不要自动重试。")
    }
  }

  /// The user does something themselves, likely in another app, and comes back to say they did.
  /// A notification is how they find out when DSH Go isn't in front. Tapping it only opens the app.
  private func handOver(_ request: IOSPhoneRequest) async -> IOSPhoneOutcome {
    let reason = request.action.text ?? ""
    if UIApplication.shared.applicationState != .active {
      let content = UNMutableNotificationContent()
      content.title = "AI 请你接手"
      content.body = reason
      try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
    }
    while !Task.isCancelled, request.expiresAt > Date().timeIntervalSince1970 * 1000 {
      if UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable {
        let finished = await actions.confirm(
          request, title: "AI 请你接手", detail: "\(reason)\n\n可以先切到别的应用去做，做完回来点「继续」。",
          allow: "继续", deny: "停止", waitsForever: true)
        if finished { return .success("用户说做完了。先用 screen 看一下现在的屏幕。") }
        // Leaving the app dismisses the sheet, which isn't an answer. Asked again on the way back.
        if UIApplication.shared.applicationState == .active { return .failure("用户选择停止。不要自动重试。") }
      }
      try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    return .failure("用户没有在时间内回来。")
  }
}
