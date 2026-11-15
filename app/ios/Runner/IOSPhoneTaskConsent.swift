import Foundation
import UIKit
import UserNotifications

/// A bounded transition delay, not a claim that screenshot pixels are stable.
/// It owns no screen observation and never grants or dispatches a phone action.
struct IOSPhoneTargetWait {
  enum Decision: Equatable { case waiting, ready, refused }
  private let deadline: TimeInterval
  private var lastSample: TimeInterval
  private var backgroundStarted: TimeInterval?

  init?(start: TimeInterval?, requestRemaining: TimeInterval) {
    guard let start, start.isFinite, requestRemaining.isFinite, requestRemaining > 0 else { return nil }
    let deadline = start + min(45, requestRemaining)
    guard deadline.isFinite, deadline > start else { return nil }
    self.deadline = deadline; lastSample = start
  }

  mutating func sample(now: TimeInterval?, background: Bool, protectedDataAvailable: Bool,
                       eligible: Bool) -> Decision {
    guard let now, now.isFinite, now >= lastSample, now < deadline,
      protectedDataAvailable, eligible else { return .refused }
    lastSample = now
    guard background else { return backgroundStarted == nil ? .waiting : .refused }
    if backgroundStarted == nil { backgroundStarted = now }
    return now - backgroundStarted! >= 0.75 ? .ready : .waiting
  }
}

/// One native task grant, bound to this engine/session for at most thirty minutes.
/// Ordinary calls in that task keep working while the target app is foreground.
/// A new owner, expiry or explicit retirement needs a new foreground grant.
@MainActor
final class IOSPhoneTaskConsent {
  private struct Owner: Equatable {
    let runID: String
    let sessionID: String
  }
  private let actions: IOSPhoneActions
  private let now: () -> TimeInterval?
  private let foregroundCheck: () -> Bool
  private var grantOwner: Owner?
  private var grantedAt: TimeInterval?
  private var grantedUntil: TimeInterval?
  private var lastGrantSample: TimeInterval?
  private var grantID = UUID()
  private var expiryWatcher: Task<Void, Never>?
  private var generation = UUID()
  /// Called synchronously, once, after the exact current grant has been cleared.
  /// No request/presenter closure is retained for the thirty-minute lifetime.
  var onExpiration: ((String, String) -> Void)?
  /// The runner installs an exact-invocation cleanup closure. A clipboard
  /// confirmation snapshots it before awaiting UI; a later invocation cannot
  /// donate its cleanup hook to an older answer. This never revokes a grant.
  var onClipboardRefusal: (() -> Void)?
  private(set) var targetWaitFailureMessage = "等待目标界面超时，没有派发动作。"

  init(actions: IOSPhoneActions, now: @escaping () -> TimeInterval? = IOSPhoneContinuousTime.now,
       isForeground: (() -> Bool)? = nil) {
    self.actions = actions; self.now = now
    foregroundCheck = isForeground ?? {
      UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
    }
  }

  func retire() {
    expiryWatcher?.cancel(); expiryWatcher = nil; grantID = UUID()
    generation = UUID(); grantOwner = nil; grantedAt = nil; grantedUntil = nil
    lastGrantSample = nil
    onClipboardRefusal = nil
  }

  var isGranted: Bool {
    remainingSeconds > 0
  }

  var remainingSeconds: TimeInterval { checkExpiration() }

  @discardableResult
  func checkExpiration() -> TimeInterval {
    guard let owner = grantOwner, let start = grantedAt, let until = grantedUntil else { return 0 }
    if let sample = now(), let previous = lastGrantSample,
      start.isFinite, start >= 0, until.isFinite, until > start,
      previous.isFinite, previous >= start,
      sample.isFinite, sample >= previous, sample < until {
      lastGrantSample = sample
      return until - sample
    }
    // Clear identity and cancel the timer before the owner callback can reenter.
    retire()
    onExpiration?(owner.runID, owner.sessionID)
    return 0
  }

  private func watchGrant() {
    expiryWatcher?.cancel()
    let id = UUID(); grantID = id
    // This runs only while the app/actor is scheduled. The continuous clock
    // includes sleep; every admission also checks it synchronously on return.
    expiryWatcher = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        guard !Task.isCancelled, let self, self.grantID == id else { return }
        if self.checkExpiration() <= 0 { return }
      }
    }
  }

  func approve(_ request: IOSPhoneRequest, detail: String, needsTarget: Bool, preview: Data? = nil,
               current: @escaping () -> Bool) async -> Bool {
    checkExpiration()
    let operation = generation
    let owner = Owner(runID: request.runId, sessionID: request.owner.sessionId)
    let live = { !Task.isCancelled && current() && self.generation == operation
      && request.expiresAt > Date().timeIntervalSince1970 * 1000 }
    guard live(), detail.utf8.count <= 16_384 else { return false }
    if grantOwner == owner && isGranted {
      return live() && UIApplication.shared.isProtectedDataAvailable
    }
    // Only the first grant requires our UI. Reusing an owned task must not
    // wait for this app and pull the person out of the target again.
    guard live(), await waitForForeground(request, current: live), live() else { return false }
    let granted = await actions.confirm(request, title: "允许 AI 操控这台手机？",
      detail: "授权本次对话接下来最多 30 分钟的手机操控任务。AI 可读取屏幕、打开应用、点击、滚动和输入普通文字；本任务内不再逐次弹窗，也不需要反复返回 DSH Go。\n\n密码、验证码和支付步骤仍交给你处理。关闭连接、暂停或结束任务会撤销授权；切到其他 App 后由系统持续任务接续，系统仍可能中断后台工作。\n\n首次动作：\n" + detail,
      allow: "允许 30 分钟", deny: "拒绝", preview: preview)
    guard granted, live(), foreground, let now = self.now(), now.isFinite, now >= 0,
      (now + 30 * 60).isFinite, now + 30 * 60 > now else { return false }
    grantOwner = owner; grantedAt = now; grantedUntil = now + 30 * 60; lastGrantSample = now
    watchGrant()
    return live() && isGranted && grantOwner == owner
  }

  func prepareForeground(_ request: IOSPhoneRequest, current: () -> Bool) async -> Bool {
    await waitForForeground(request, current: current)
  }

  /// A focus check in the target must precede this additional staging sheet.
  /// Returning to DSH Go alone does not authorize a clipboard replacement.
  func prepareClipboard(_ request: IOSPhoneRequest, current: @escaping () -> Bool) async -> Bool {
    guard (try? IOSPhoneOperation(request))?.usesClipboard == true else { return false }
    let operation = generation
    let owner = Owner(runID: request.runId, sessionID: request.owner.sessionId)
    let live = { !Task.isCancelled && current() && self.generation == operation
      && self.grantOwner == owner && self.isGranted
      && request.expiresAt > Date().timeIntervalSince1970 * 1000 }
    guard live() else { return false }
    let refused = onClipboardRefusal
    var admitted = false
    defer { if !admitted { refused?() } }
    guard await waitForForeground(request, current: live,
      notificationBody: "已检查本次输入目标的键盘线索。请回到 DSH Go 确认临时剪贴板；尚未修改剪贴板或输入文字。"),
      live(), foreground else { return false }
    let windowSeconds = Int(IOSPhoneClipboard.pasteLifetime)
    let allowed = await actions.confirm(request, title: "准备本次非 ASCII 粘贴？",
      detail: "刚才已复核目标画面并检查键盘和敏感输入线索；这些线索不是输入焦点或安全性的证明。\n\n现在会在前台保存原剪贴板，并临时写入本次已批准的全文。原内容只保存在本 App 内存，不发送给模型。\n\n允许后请在 \(windowSeconds) 秒内自行切回刚才的输入界面，期间不要复制其他内容。DSH Go 会再次核对画面；后台无法回读剪贴板，不能保证发现其他 App 的并发复制。\n\n粘贴后只返回固定状态，不回传新的读屏文字或图片，也不会自动派发回车／发送按键；请你核对目标应用的实际结果。\n\n粘贴后请回到 DSH Go 核对并恢复原剪贴板；App 终止会丢失保存的原内容。取消不会撤回已派发的焦点点击。",
      allow: "准备剪贴板", deny: "取消输入")
    admitted = allowed && live() && foreground
    return admitted
  }

  /// Waiting for the user to choose a target is not an automatic app switch.
  /// A protected-data lock or retired task stops admission immediately.
  func waitForTarget(_ request: IOSPhoneRequest, current: () -> Bool) async -> Bool {
    let operation = generation
    targetWaitFailureMessage = "等待目标界面超时，没有派发动作。"
    guard var wait = IOSPhoneTargetWait(start: now(),
      requestRemaining: request.expiresAt / 1000 - Date().timeIntervalSince1970) else { return false }
    #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
    var previousGate = ""
    #endif
    while true {
      let background = UIApplication.shared.applicationState == .background
      let unlocked = UIApplication.shared.isProtectedDataAvailable
      let eligible = !Task.isCancelled && current() && generation == operation && isGranted
        && request.expiresAt > Date().timeIntervalSince1970 * 1000
      #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
      let gate = "target wait bg=\(background) unlocked=\(unlocked) eligible=\(eligible)"
      if gate != previousGate { previousGate = gate; IOSPhoneSelfRunner.diagnostic(gate) }
      #endif
      let decision = wait.sample(now: now(), background: background,
        protectedDataAvailable: unlocked, eligible: eligible)
      switch decision {
      case .refused:
        if !unlocked { targetWaitFailureMessage = "手机已锁定，没有派发动作；请解锁后重新发起。" }
        else if !eligible { targetWaitFailureMessage = "本次请求已取消、过期或暂停，没有派发动作；这不表示增强开关关闭。" }
        else if !background { targetWaitFailureMessage = "DSH Go 仍在前台，未取得目标画面，没有派发动作。" }
        #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
        IOSPhoneSelfRunner.diagnostic("target wait refused bg=\(background) eligible=\(eligible)")
        #endif
        return false
      case .ready:
        // Core/XCTest must still capture and validate a fresh frame after this
        // delay. Do not consume or replace the approved observation here.
        return true
      case .waiting:
        do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return false }
      }
    }
  }

  private var foreground: Bool {
    foregroundCheck() && UIApplication.shared.isProtectedDataAvailable
  }

  private func waitForForeground(_ request: IOSPhoneRequest, current: () -> Bool,
                                notificationBody: String = "请回到 DSH Go 授权本次手机操控任务。点这条通知只打开 App，不会批准或执行。") async -> Bool {
    if foreground { return current() }
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    if current(), [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
      let content = UNMutableNotificationContent()
      content.title = "手机操控等待你确认"
      content.body = notificationBody
      // No action/category identifiers and no tool arguments or clipboard data.
      try? await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
    }
    defer { center.removeDeliveredNotifications(withIdentifiers: [request.id]) }
    while !Task.isCancelled, current() {
      if foreground { return true }
      do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
    }
    return false
  }
}
