import Foundation
import UIKit

enum IOSPhoneClipboardError: String, Error {
  case foreground = "ERR_PHONE_CLIPBOARD_FOREGROUND_REQUIRED"
  case pending = "ERR_PHONE_CLIPBOARD_RESTORE_PENDING"
  case unavailable = "ERR_PHONE_CLIPBOARD_UNAVAILABLE"
  case tooLarge = "ERR_PHONE_CLIPBOARD_TOO_LARGE"
  case changed = "ERR_PHONE_CLIPBOARD_CHANGED"
  case stale = "ERR_PHONE_CLIPBOARD_STALE"
  case denied = "ERR_PHONE_CLIPBOARD_PREPARATION_DENIED"
}

@MainActor
protocol IOSPhonePasteboardClient {
  var changeCount: Int { get }
  var itemCount: Int { get }
  func types() -> [[String]]?
  func data(type: String, item: Int) -> Data?
  func replace(_ items: [[String: Any]], expires: Date?)
}

@MainActor
private final class IOSPhoneSystemPasteboard: IOSPhonePasteboardClient {
  private var board: UIPasteboard? {
    guard UIApplication.shared.applicationState == .active,
      UIApplication.shared.isProtectedDataAvailable else { return nil }
    return UIPasteboard.general
  }
  var changeCount: Int { board?.changeCount ?? -1 }
  var itemCount: Int { board?.numberOfItems ?? -1 }
  func types() -> [[String]]? { board?.types(forItemSet: nil) }
  func data(type: String, item: Int) -> Data? {
    guard let values = board?.data(forPasteboardType: type, inItemSet: IndexSet(integer: item)),
      values.count == 1 else { return nil }
    return values[0]
  }
  func replace(_ items: [[String: Any]], expires: Date?) {
    var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
    if let expires { options[.expirationDate] = expires }
    board?.setItems(items, options: options)
  }
}

/// Saves every materializable representation of a bounded pasteboard snapshot
/// in this process only. It has no export/log/file interface. UIKit supplies no
/// cross-process compare-and-swap and no paste-consumption acknowledgement;
/// counter/marker checks are conservative observations, not an atomic guarantee.
@MainActor
final class IOSPhoneClipboard {
  static let shared = IOSPhoneClipboard(client: IOSPhoneSystemPasteboard())
  // A short dispatch window reduces exposure but cannot attest which contents
  // an external target will paste. It is separate from UIKit's item expiry.
  static let pasteLifetime: TimeInterval = 12
  struct Prepared<Focus> {
    let id: UUID
    let focus: Focus
  }
  private static let markerType = "io.github.ccch1mneyyy.dshgo.phone-paste-lease"
  private static let textType = "public.utf8-plain-text"
  private final class Lease {
    let id = UUID()
    let original: [[String: Data]]
    let temporaryText: Data
    var writtenCount: Int?
    var readyAt: TimeInterval?
    var pasteAttempted = false
    var restoreRequested = false
    init(original: [[String: Data]], text: String) {
      self.original = original; self.temporaryText = Data(text.utf8)
    }
    var marker: Data { Data(id.uuidString.utf8) }
  }
  private let client: IOSPhonePasteboardClient
  private let foreground: () -> Bool
  private let settle: () async -> Void
  private let now: () -> TimeInterval?
  private var lease: Lease?
  private var busy = false
  private var preparation: UUID?
  var onStateChanged: (() -> Void)?

  init(client: IOSPhonePasteboardClient,
       foreground: @escaping () -> Bool = {
         UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
       }, settle: @escaping () async -> Void = {
         await withCheckedContinuation { continuation in
           DispatchQueue.main.async { DispatchQueue.main.async { continuation.resume() } }
         }
       }, now: @escaping () -> TimeInterval? = IOSPhoneContinuousTime.now) {
    self.client = client; self.foreground = foreground; self.settle = settle; self.now = now
  }

  var hasPendingRestore: Bool { lease != nil }
  var restorationID: UUID? { lease?.id }
  func status() -> [String: Any] {
    ["pendingRestore": lease != nil, "foregroundRequired": true, "memoryOnly": true,
     "pasteMayHaveBeenDispatched": lease?.pasteAttempted ?? false,
     "restoreRequested": lease?.restoreRequested ?? false]
  }

  /// The caller's real target/focus preflight must complete before any pasteboard
  /// access. It then brings the user back for a separate foreground staging tap.
  /// Closures are native implementation dependencies, never tool parameters.
  func prepare<Focus>(text: String, preflight: () async throws -> Focus,
                      confirm: () async -> Bool, current: @escaping () -> Bool) async throws -> Prepared<Focus> {
    guard preparation == nil, !busy, lease == nil else { throw IOSPhoneClipboardError.pending }
    guard current(), !Task.isCancelled else { throw IOSPhoneClipboardError.stale }
    guard !text.isEmpty, text.utf8.count <= 4096, !text.contains("\0") else { throw IOSPhoneClipboardError.tooLarge }
    let operation = UUID(); preparation = operation
    defer { if preparation == operation { preparation = nil } }
    let focus = try await preflight()
    guard current(), !Task.isCancelled else { throw IOSPhoneClipboardError.stale }
    guard await confirm() else { throw IOSPhoneClipboardError.denied }
    guard current(), !Task.isCancelled, foreground() else { throw IOSPhoneClipboardError.foreground }
    return Prepared(id: try await begin(text: text, current: current), focus: focus)
  }

  /// Only prepare's successful preflight and real foreground confirmation reach
  /// this method. A failure after replace retains the original for restoration.
  private func begin(text: String, current: @escaping () -> Bool) async throws -> UUID {
    guard !busy, lease == nil else { throw IOSPhoneClipboardError.pending }
    guard foreground(), current(), !Task.isCancelled else { throw IOSPhoneClipboardError.foreground }
    guard !text.isEmpty, text.utf8.count <= 4096, !text.contains("\0") else { throw IOSPhoneClipboardError.tooLarge }
    guard let started = now(), started.isFinite else { throw IOSPhoneClipboardError.stale }
    busy = true
    defer { busy = false }
    let count = client.changeCount
    let number = client.itemCount
    guard (0...16).contains(number) else { throw IOSPhoneClipboardError.tooLarge }
    let types: [[String]]? = number == 0 ? [] : client.types()
    guard let types, types.count == number else { throw IOSPhoneClipboardError.unavailable }
    var snapshot: [[String: Data]] = []
    var bytes = 0
    for (index, representations) in types.enumerated() {
      guard !representations.isEmpty, representations.count <= 32,
        Set(representations).count == representations.count else { throw IOSPhoneClipboardError.tooLarge }
      var item: [String: Data] = [:]
      for type in representations {
        guard !type.isEmpty, type.utf8.count <= 256, !type.contains("\0"),
          let data = client.data(type: type, item: index) else { throw IOSPhoneClipboardError.unavailable }
        // UIKit materializes a representation before returning its size. This
        // caps retained data; it cannot promise a pre-allocation OS read limit.
        guard data.count <= 4 * 1024 * 1024 - bytes else { throw IOSPhoneClipboardError.tooLarge }
        bytes += data.count; item[type] = data
      }
      snapshot.append(item)
    }
    // changeCount is published at an event-loop boundary, not necessarily by a
    // synchronous setter. This yield is not a paste ACK or a fixed-delay proof.
    await settle()
    guard foreground(), current(), !Task.isCancelled else { throw IOSPhoneClipboardError.foreground }
    guard client.changeCount == count, client.itemCount == number,
      (number == 0 || client.types() == types), matches(snapshot),
      client.changeCount == count else { throw IOSPhoneClipboardError.changed }
    let saved = Lease(original: snapshot, text: text)
    lease = saved
    client.replace([[Self.textType: saved.temporaryText, Self.markerType: saved.marker]],
      expires: Date().addingTimeInterval(10 * 60))
    await settle()
    guard lease === saved else { throw IOSPhoneClipboardError.stale }
    // Record an available foreground count even if the original caller was
    // cancelled during settle. Otherwise the retained snapshot can never pass
    // owns() during a later, separately authorized restoration. Never sample
    // in the background, and do not mistake this sample for ownership proof.
    if foreground() { saved.writtenCount = client.changeCount }
    guard current(), !Task.isCancelled, foreground() else {
      saved.restoreRequested = true; onStateChanged?()
      throw IOSPhoneClipboardError.foreground
    }
    guard saved.writtenCount != count, owns(saved) else {
      saved.restoreRequested = true; onStateChanged?()
      throw IOSPhoneClipboardError.changed
    }
    guard let ready = now(), ready.isFinite, ready >= started else {
      saved.restoreRequested = true; onStateChanged?()
      throw IOSPhoneClipboardError.stale
    }
    saved.readyAt = ready
    onStateChanged?()
    return saved.id
  }

  /// Background admission is local and single-use; it never reads UIPasteboard,
  /// including changeCount. Apple forbids background content access, and the
  /// cached foreground marker/count cannot detect every later external copy.
  /// The caller must recheck the focused target before this bounded handoff.
  func validateForPaste(_ id: UUID, current: () -> Bool) throws {
    guard let saved = lease, saved.id == id else { throw IOSPhoneClipboardError.stale }
    guard !busy, current(), !Task.isCancelled, !saved.restoreRequested, !saved.pasteAttempted,
      saved.writtenCount != nil, let ready = saved.readyAt, let time = now(),
      time.isFinite, time >= ready, time - ready < Self.pasteLifetime else { throw IOSPhoneClipboardError.stale }
    if foreground(), !owns(saved) { throw IOSPhoneClipboardError.changed }
    saved.pasteAttempted = true
  }

  func requestRestore(_ id: UUID) {
    guard let saved = lease, saved.id == id else { return }
    saved.restoreRequested = true; onStateChanged?()
    // If no HID paste was even attempted, foreground cancellation can restore
    // immediately. A potentially dispatched paste requires a new real user
    // confirmation after returning, rather than restoring behind the target.
    if !saved.pasteAttempted, foreground() {
      Task { [weak self, weak saved] in
        guard let self, let saved, self.lease === saved, !saved.pasteAttempted else { return }
        try? await self.restore(id: id, overwriteChanged: false, current: { self.lease === saved && !saved.pasteAttempted })
      }
    }
  }

  /// overwriteChanged may be true only following the separate foreground sheet
  /// that explicitly asks to replace a changed clipboard with the saved one.
  func restore(id: UUID? = nil, overwriteChanged: Bool = false,
               current: @escaping () -> Bool) async throws {
    guard !busy, let saved = lease, id == nil || saved.id == id else { throw IOSPhoneClipboardError.stale }
    guard foreground(), current(), !Task.isCancelled else { throw IOSPhoneClipboardError.foreground }
    busy = true
    defer { busy = false }
    await settle()
    guard lease === saved, foreground(), current(), !Task.isCancelled else { throw IOSPhoneClipboardError.stale }
    guard overwriteChanged || owns(saved) else { throw IOSPhoneClipboardError.changed }
    let items: [[String: Any]] = saved.original.map { item in item.mapValues { $0 as Any } }
    // The current marker/count are checked immediately before this write. UIKit
    // offers no atomic compare-and-swap with an external clipboard writer.
    client.replace(items, expires: nil)
    await settle()
    guard lease === saved, foreground(), current(), !Task.isCancelled else { throw IOSPhoneClipboardError.stale }
    // An ignored/failed UIKit write must not discard the only retained copy.
    // Verify the representations themselves; the counter can still be pending
    // until the event loop publishes it and is not a write acknowledgement.
    guard matches(saved.original) else { throw IOSPhoneClipboardError.unavailable }
    lease = nil
    onStateChanged?()
    // The original localOnly/expiry metadata is not readable through this API;
    // restoration preserves representations, uses localOnly=true, and does not
    // claim to reconstruct the previous Handoff or expiration policy.
  }

  func discardSaved(id: UUID? = nil) throws {
    guard !busy, foreground(), let saved = lease, id == nil || saved.id == id else {
      throw IOSPhoneClipboardError.foreground
    }
    lease = nil; onStateChanged?()
    // No attempt to overwrite the current clipboard. Swift/Data copies prevent
    // a truthful promise of universal memory zeroization here.
  }

  /// Run before a later phone call. This sheet is separate from that call's own
  /// approval and cannot donate its tap as permission to operate another app.
  func resolvePending(_ request: IOSPhoneRequest, actions: IOSPhoneActions,
                      current: @escaping () -> Bool) async -> Bool {
    guard let saved = lease else { return true }
    guard foreground(), current() else { return false }
    let prompt = saved.pasteAttempted
      ? "请先核对目标应用已经完成或取消粘贴。恢复原剪贴板前不会再发送粘贴；原内容仅保存在本 App 内存，不发送给模型。"
      : "上次没有派发粘贴；恢复临时保存的原剪贴板后，才会另行询问新的手机动作。"
    let allowed = await actions.confirm(request, title: "恢复原剪贴板？", detail: prompt,
      allow: "已核对，恢复", deny: "暂不恢复")
    guard allowed, current(), foreground(), lease === saved else { return false }
    do {
      try await restore(id: saved.id, current: current)
      return current()
    } catch IOSPhoneClipboardError.changed {
      let replace = await actions.confirm(request, title: "剪贴板已经变化",
        detail: "现在的剪贴板已不属于上次临时粘贴。是否用保存的旧内容覆盖它？暂不恢复会保留现在的剪贴板和本 App 中的旧副本；可到设置中另行决定。",
        allow: "覆盖并恢复旧内容", deny: "暂不恢复")
      guard replace, current(), foreground(), lease === saved else { return false }
      do {
        try await restore(id: saved.id, overwriteChanged: true, current: current)
        return current()
      } catch { return false }
    } catch { return false }
  }

  private func owns(_ saved: Lease) -> Bool {
    guard foreground(), let count = saved.writtenCount, client.changeCount == count, client.itemCount == 1,
      let types = client.types(), types.count == 1,
      Set(types[0]) == Set([Self.markerType, Self.textType]), types[0].count == 2,
      client.data(type: Self.markerType, item: 0) == saved.marker,
      client.data(type: Self.textType, item: 0) == saved.temporaryText,
      client.changeCount == count, client.itemCount == 1,
      let finalTypes = client.types(), finalTypes.count == 1 else { return false }
    return finalTypes[0].count == 2 && Set(finalTypes[0]) == Set([Self.markerType, Self.textType])
  }

  /// Content read-back also narrows the interval before changeCount publishes.
  /// No sequence of these reads is a cross-process atomic snapshot or CAS.
  private func matches(_ original: [[String: Data]]) -> Bool {
    guard foreground() else { return false }
    let count = client.changeCount
    guard client.itemCount == original.count else { return false }
    if original.isEmpty { return client.changeCount == count && client.itemCount == 0 }
    guard let types = client.types(), types.count == original.count else { return false }
    for (index, item) in original.enumerated() {
      guard types[index].count == item.count, Set(types[index]) == Set(item.keys) else { return false }
      for (type, data) in item where client.data(type: type, item: index) != data { return false }
    }
    guard client.changeCount == count, client.itemCount == original.count,
      let finalTypes = client.types(), finalTypes.count == original.count else { return false }
    return zip(finalTypes, original).allSatisfy { $0.0.count == $0.1.count && Set($0.0) == Set($0.1.keys) }
  }
}
