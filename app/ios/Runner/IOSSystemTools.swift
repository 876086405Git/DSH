import Contacts
import CoreLocation
import CryptoKit
import EventKit
import Foundation
import ImageIO
import PhotosUI
import Security
import UIKit
import Vision

/// The system tools: reminders, contacts, a photo the user picks, one location fix, text in an
/// image. Each asks the user first, on the real sheet, showing exactly what it will read or write,
/// and only in front of the user. Node checks the arguments and the shape of what comes back.
@MainActor
final class IOSSystemTools: NSObject, PHPickerViewControllerDelegate, CLLocationManagerDelegate {
  struct Picked {
    let session: String
    let file: URL
    let expires: Date
  }

  private struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  private static let imageBytes = 10 * 1024 * 1024
  private static let imageSide = 8192
  private static let imagePixels = 24_000_000
  private static let imageLasts: TimeInterval = 30 * 60
  private static let resultBytes = 32768

  private let actions: IOSPhoneActions
  private let presenter: () -> UIViewController?
  private lazy var eventStore = EKEventStore()
  private lazy var contactStore = CNContactStore()
  var picked: [String: Picked] = [:]
  private var pickerShown: PHPickerViewController?
  private var picking: CheckedContinuation<[PHPickerResult], Never>?
  private var locating: CheckedContinuation<CLLocation?, Never>?
  private var authorizing: CheckedContinuation<Void, Never>?
  private var locationManager: CLLocationManager?

  init(actions: IOSPhoneActions, presenter: @escaping () -> UIViewController?) {
    self.actions = actions
    self.presenter = presenter
  }

  private var scratch: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("dsh-picked-images", isDirectory: true)
  }

  /// The tool call is over, so a picker still open for it has nothing to answer.
  func stopAsking() {
    pickerShown?.dismiss(animated: true)
    pickerShown = nil
    picking?.resume(returning: [])
    picking = nil
    // Detach first so queued delegate callbacks cannot revive this call.
    locationManager?.delegate = nil
    locationManager = nil
    let pendingLocation = locating
    locating = nil
    let pendingAuthorization = authorizing
    authorizing = nil
    pendingLocation?.resume(returning: nil)
    pendingAuthorization?.resume()
  }

  /// Images the user picked are good for this run and no longer.
  func retire() {
    stopAsking()
    picked = [:]
    try? FileManager.default.removeItem(at: scratch)
  }

  func run(_ request: IOSPhoneRequest, authorize: () async -> Bool, current: () -> Bool) async -> IOSPhoneOutcome {
    guard UIApplication.shared.applicationState == .active, current() else {
      return .failure("系统工具要用户在 DSH Go 里才能用。没有执行。")
    }
    let kind = String(request.action.kind.dropFirst("system-".count))
    guard let data = request.action.params?.data(using: .utf8),
      let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return .failure("参数无效。") }
    do {
      let value: [String: Any]
      switch kind {
      case "reminders_list": value = try await remindersList(args, request, authorize, current)
      case "reminders_create": value = try await remindersCreate(args, request, authorize, current)
      case "reminders_complete": value = try await remindersComplete(args, request, authorize, current)
      case "contacts_search": value = try await contactsSearch(args, request, authorize, current)
      case "contacts_create": value = try await contactsCreate(args, request, authorize, current)
      case "photos_select": value = try await photosSelect(args, request, authorize, current)
      case "location_current": value = try await locationCurrent(request, authorize, current)
      case "vision_ocr": value = try await visionText(args, request, authorize, current)
      default: throw Failure("没有这个系统工具。")
      }
      let json = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes, .sortedKeys])
      guard json.count <= Self.resultBytes else { return .failure("结果太长了，缩小范围再试。") }
      return .success(String(decoding: json, as: UTF8.self))
    } catch let failure as Failure {
      return .failure(failure.message)
    } catch {
      return .failure("系统没有完成这一步；请用户检查，不要自动重试。")
    }
  }

  /// The user says yes, the tool call is still waiting, and nothing has happened yet.
  private func asked(
    _ request: IOSPhoneRequest, _ title: String, _ detail: String, _ authorize: () async -> Bool, _ current: () -> Bool
  ) async throws {
    guard await actions.confirm(request, title: title, detail: detail) else {
      throw Failure("用户没有同意。不要自动重试。")
    }
    guard current(), await authorize(), current() else { throw Failure("这个工具调用已经结束，没有执行。") }
  }

  /// A system permission prompt can sit there longer than the tool call waits.
  private func stillWanted(_ current: () -> Bool) throws {
    guard current() else { throw Failure("这个工具调用已经结束，没有执行。") }
    guard UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable else {
      throw Failure("请先解锁并打开 DSH Go；没有继续读取或写入。")
    }
  }

  /// The app stays inactive for a moment after a system prompt is answered, and what comes next
  /// only runs in front of the user. Someone who really left is still caught by those checks.
  private func backInFront() async {
    var tries = 0
    while UIApplication.shared.applicationState != .active, tries < 40 {
      try? await Task.sleep(nanoseconds: 50_000_000)
      tries += 1
    }
  }

  nonisolated private static func instant(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter.string(from: date)
  }

  nonisolated private static func date(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter.date(from: value)
  }

  nonisolated private static func base64url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  nonisolated private static func opaque(_ value: String) -> String { base64url(Data(value.utf8)) }

  nonisolated private static func unopaque(_ value: String) -> String? {
    var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while text.count % 4 != 0 { text += "=" }
    return Data(base64Encoded: text).map { String(decoding: $0, as: UTF8.self) }
  }

  /// Cut to fit in bytes, on a character boundary.
  nonisolated private static func clip(_ text: String, _ bytes: Int) -> String {
    guard text.utf8.count > bytes else { return text }
    var result = ""
    for character in text {
      if result.utf8.count + character.utf8.count > bytes { break }
      result.append(character)
    }
    return result
  }

  /// A name fit to hand back: never blank, never over the limit.
  nonisolated private static func label(_ text: String?, _ fallback: String, _ bytes: Int) -> String {
    let cleaned = (text ?? "").replacingOccurrences(of: "\0", with: "")
    let clipped = clip(cleaned, bytes)
    return clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : clipped
  }

  // MARK: Reminders

  private func reminderAccess() async throws {
    let granted: Bool
    if #available(iOS 17.0, *) {
      granted = (try? await eventStore.requestFullAccessToReminders()) ?? false
    } else {
      granted = (try? await eventStore.requestAccess(to: .reminder)) ?? false
    }
    await backInFront()
    guard granted else { throw Failure("用户没有给提醒事项权限。可以到系统设置里打开。") }
  }

  /// A reminder made elsewhere can carry its date without saying which calendar that's in.
  nonisolated private static func due(_ reminder: EKReminder) -> Date? {
    guard let parts = reminder.dueDateComponents else { return nil }
    return parts.date ?? Calendar(identifier: .gregorian).date(from: parts)
  }

  nonisolated private static func version(_ reminder: EKReminder) -> String {
    let seen = [
      reminder.calendarItemIdentifier, reminder.title ?? "", reminder.notes ?? "", "\(reminder.isCompleted)",
      "\(reminder.lastModifiedDate?.timeIntervalSince1970 ?? 0)", "\(due(reminder)?.timeIntervalSince1970 ?? 0)",
    ].joined(separator: "\u{1F}")
    return SHA256.hash(data: Data(seen.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  nonisolated private static func row(_ reminder: EKReminder) -> [String: Any] {
    var row: [String: Any] = [
      "id": opaque(reminder.calendarItemIdentifier), "version": version(reminder),
      "title": label(reminder.title, "（无标题）", 256), "completed": reminder.isCompleted,
    ]
    if let due = due(reminder) { row["due"] = instant(due) }
    return row
  }

  private func remindersList(
    _ args: [String: Any], _ request: IOSPhoneRequest, _ authorize: () async -> Bool, _ current: () -> Bool
  ) async throws -> [String: Any] {
    let query = args["query"] as? String
    let limit = args["limit"] as? Int ?? 20
    let completed = args["include_completed"] as? Bool ?? false
    let scope = query.map { "标题含「\($0)」的" } ?? "全部"
    try await asked(
      request, "允许 AI 读取提醒事项？", "\(scope)\(completed ? "提醒（含已完成）" : "未完成提醒")，最多 \(limit) 条，只有标题和日期。", authorize, current)
    try await reminderAccess()
    try stillWanted(current)
    let predicate = eventStore.predicateForReminders(in: nil)
    let store = eventStore
    let found: [EKReminder] = await withCheckedContinuation { continuation in
      store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
    }
    let matching = found.filter { reminder in
      (completed || !reminder.isCompleted) && (query.map { (reminder.title ?? "").localizedCaseInsensitiveContains($0) } ?? true)
    }.map { (reminder: $0, due: Self.due($0) ?? .distantFuture) }.sorted { $0.due < $1.due }
    return ["scope": "full", "items": matching.prefix(limit).map { Self.row($0.reminder) }, "truncated": matching.count > limit]
  }

  private func remindersCreate(
    _ args: [String: Any], _ request: IOSPhoneRequest, _ authorize: () async -> Bool, _ current: () -> Bool
  ) async throws -> [String: Any] {
    guard let title = args["title"] as? String else { throw Failure("要给标题。") }
    let notes = args["notes"] as? String
    let due = (args["due"] as? String).flatMap { Self.date($0) }
    if args["due"] != nil, due == nil { throw Failure("时间格式不对。") }
    // Asked first, so the sheet can say which list it's going in.
    try await reminderAccess()
    let target: EKCalendar?
    if let id = args["list_id"] as? String {
      target = Self.unopaque(id).flatMap { eventStore.calendar(withIdentifier: $0) }
      if target == nil { throw Failure("没有这个提醒列表，没有新建。") }
    } else {
      target = eventStore.defaultCalendarForNewReminders()
    }
    guard let list = target else { throw Failure("没有可用的提醒列表。") }
    var detail = "标题：\(title)\n列表：\(list.title)"
    if let due { detail += "\n时间：\(due.formatted(date: .abbreviated, time: .shortened))" }
    if let notes, !notes.isEmpty { detail += "\n备注：\(notes)" }
    try await asked(request, "允许 AI 新建这条提醒？", detail, authorize, current)
    let reminder = EKReminder(eventStore: eventStore)
    reminder.title = title
    reminder.notes = notes
    reminder.calendar = list
    if let due {
      // EventKit takes these in the Gregorian calendar whatever the phone is set to.
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = .current
      reminder.dueDateComponents = calendar.dateComponents(
        [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: due)
    }
    try eventStore.save(reminder, commit: true)
    return ["committed": true, "item": Self.row(reminder)]
  }

  private func remindersComplete(
    _ args: [String: Any], _ request: IOSPhoneRequest, _ authorize: () async -> Bool, _ current: () -> Bool
  ) async throws -> [String: Any] {
    guard let id = (args["id"] as? String).flatMap({ Self.unopaque($0) }), let version = args["version"] as? String,
      let completed = args["completed"] as? Bool
    else { throw Failure("参数不对。") }
    try await reminderAccess()
    guard let shown = eventStore.calendarItem(withIdentifier: id) as? EKReminder else { throw Failure("这条提醒已经不在了。") }
    guard Self.version(shown) == version else { throw Failure("这条提醒已经改过了。先重新列一遍。") }
    try await asked(
      request, "允许 AI 改这条提醒？", "把「\(shown.title ?? "")」标为\(completed ? "已完成" : "未完成")。", authorize, current)
    // It can have changed while the user read the sheet.
    guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder, Self.version(reminder) == version else {
      throw Failure("这条提醒刚刚改过了，没有动它。先重新列一遍。")
    }
    reminder.isCompleted = completed
    try eventStore.save(reminder, commit: true)
    return ["committed": true, "item": Self.row(reminder)]
  }

  // MARK: Contacts

  private func contactAccess() async throws -> String {
    let granted = (try? await contactStore.requestAccess(for: .contacts)) ?? false
    await backInFront()
    guard granted else { throw Failure("用户没有给通讯录权限。可以到系统设置里打开。") }
    if #available(iOS 18.0, *), CNContactStore.authorizationStatus(for: .contacts) == .limited { return "limited" }
    return "full"
  }

  private func contactsSearch(
    _ args: [String: Any], _ request: IOSPhoneRequest, _ authorize: () async -> Bool, _ current: () -> Bool
  ) async throws -> [String: Any] {
    guard let query = args["query"] as? String else { throw Failure("要给查找内容。") }
    let limit = args["limit"] as? Int ?? 10
    let fields = args["fields"] as? [String] ?? []
    let extra = fields.isEmpty ? "只有姓名" : "姓名和" + fields.map { $0 == "phone" ? "电话" : "邮箱" }.joined(separator: "、")
    try await asked(request, "允许 AI 查找联系人？", "姓名匹配「\(query)」的联系人，最多 \(limit) 个，\(extra)。", authorize, current)
    let scope = try await contactAccess()
    try stillWanted(current)
    var keys: [CNKeyDescriptor] = [
      CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactIdentifierKey as CNKeyDescriptor,
    ]
    if fields.contains("phone") { keys.append(CNContactPhoneNumbersKey as CNKeyDescriptor) }
    if fields.contains("email") { keys.append(CNContactEmailAddressesKey as CNKeyDescriptor) }
    let wanted = keys
    let store = contactStore
    // Apple says this one mustn't run on the main thread.
    let found: [CNContact] = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          continuation.resume(returning: try store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: wanted))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
    let items: [[String: Any]] = found.prefix(limit).map { contact in
      var row: [String: Any] = [
        "id": Self.opaque(contact.identifier),
        "display_name": Self.label(CNContactFormatter.string(from: contact, style: .fullName), "（无姓名）", 256),
      ]
      if fields.contains("phone") {
        row["phone"] = contact.phoneNumbers.map { Self.clip($0.value.stringValue, 64) }.filter { !$0.isEmpty }.prefix(3).map { $0 }
      }
      if fields.contains("email") {
        row["email"] = contact.emailAddresses.map { Self.clip($0.value as String, 254) }.filter { !$0.isEmpty }.prefix(3).map { $0 }
      }
      return row
    }
    return ["scope": scope, "items": items, "truncated": found.count > limit]
  }

  private func contactsCreate(
    _ args: [String: Any], _ request: IOSPhoneRequest, _ authorize: () async -> Bool, _ current: () -> Bool
  ) async throws -> [String: Any] {
    guard let given = args["given_name"] as? String else { throw Failure("要给名字。") }
    let family = args["family_name"] as? String
    let phone = args["phone"] as? String
    let email = args["email"] as? String
    var detail = "姓名：\([family, given].compactMap { $0 }.joined(separator: " "))"
    if let phone { detail += "\n电话：\(phone)" }
    if let email { detail += "\n邮箱：\(email)" }
    try await asked(request, "允许 AI 新建这个联系人？", detail + "\n\n不会合并或改动已有联系人。", authorize, current)
    _ = try await contactAccess()
    try stillWanted(current)
    let contact = CNMutableContact()
    contact.givenName = given
    contact.familyName = family ?? ""
    if let phone { contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))] }
    if let email { contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)] }
    let save = CNSaveRequest()
    save.add(contact, toContainerWithIdentifier: nil)
    try contactStore.execute(save)
    return ["committed": true, "id": Self.opaque(contact.identifier)]
  }

  // MARK: Photos

  /// The picker runs outside the app's process and hands over only what the user picks, so it's
  /// its own consent, and the library is never read.
  private func photosSelect(
    _ args: [String: Any], _ request: IOSPhoneRequest, _ authorize: () async -> Bool, _ current: () -> Bool
  ) async throws -> [String: Any] {
    guard let host = presenter(), host.viewIfLoaded?.window != nil, host.presentedViewController == nil else {
      throw Failure("现在弹不出选择器。")
    }
    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = min(max(args["limit"] as? Int ?? 1, 1), 5)
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    // Swiping it away wouldn't tell us, and the tool call would wait on it until it timed out.
    picker.isModalInPresentation = true
    let results: [PHPickerResult] = await withCheckedContinuation { continuation in
      picking = continuation
      pickerShown = picker
      host.present(picker, animated: true)
    }
    guard !results.isEmpty else { throw Failure("用户没有选图片。") }
    guard current(), await authorize(), current() else { throw Failure("这个工具调用已经结束，没有执行。") }
    forgetExpired()
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    var items: [[String: Any]] = []
    do {
      for result in results {
        items.append(try await keep(result, session: request.owner.sessionId, current: current))
      }
    } catch {
      // No handles from this call were delivered. Keep earlier successful calls intact.
      for item in items {
        guard let handle = item["handle"] as? String, let image = picked.removeValue(forKey: handle) else { continue }
        try? FileManager.default.removeItem(at: image.file)
      }
      throw error
    }
    return ["items": items]
  }

  private func forgetExpired() {
    let now = Date()
    for (handle, image) in picked where image.expires <= now {
      try? FileManager.default.removeItem(at: image.file)
      picked[handle] = nil
    }
  }

  nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        guard self.pickerShown === picker else { return }
        picker.dismiss(animated: true)
        self.pickerShown = nil
        self.picking?.resume(returning: results)
        self.picking = nil
      }
    }
  }

  private func keep(_ result: PHPickerResult, session: String, current: () -> Bool) async throws -> [String: Any] {
    guard !Task.isCancelled, current() else { throw Failure("这个工具调用已经结束，没有保留图片。") }
    var bytes = [UInt8](repeating: 0, count: 24)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure("没有存下这张图片。") }
    let handle = Self.base64url(Data(bytes))
    let target = scratch.appendingPathComponent(handle)
    // The provider's file is gone once this callback returns.
    let copied: Bool = await withCheckedContinuation { continuation in
      result.itemProvider.loadFileRepresentation(forTypeIdentifier: "public.image") { url, _ in
        guard let url else { return continuation.resume(returning: false) }
        continuation.resume(returning: (try? FileManager.default.copyItem(at: url, to: target)) != nil)
      }
    }
    guard copied else { throw Failure("这张图片读不出来。可能还在 iCloud 上没有下载。") }
    guard !Task.isCancelled, current() else {
      try? FileManager.default.removeItem(at: target)
      throw Failure("这个工具调用已经结束，没有保留图片。")
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
    guard let source = CGImageSourceCreateWithURL(target as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
      size > 0, size <= Self.imageBytes, width <= Self.imageSide, height <= Self.imageSide, width * height <= Self.imagePixels
    else {
      try? FileManager.default.removeItem(at: target)
      throw Failure("这张图片太大了，最多 10 MB、边长 8192、2400 万像素。")
    }
    let expires = Date().addingTimeInterval(Self.imageLasts)
    picked[handle] = Picked(session: session, file: target, expires: expires)
    return ["handle": handle, "width": width, "height": height, "bytes": size, "expires_at": Self.instant(expires)]
  }

  // MARK: Location

  private func locationCurrent(
    _ request: IOSPhoneRequest, _ authorize: () async -> Bool, _ current: () -> Bool
  ) async throws -> [String: Any] {
    try await asked(request, "允许 AI 读取当前位置？", "这一次的位置。不会持续跟踪，也不会在后台读取。", authorize, current)
    let manager = CLLocationManager()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    locationManager = manager
    defer {
      if locationManager === manager {
        manager.delegate = nil
        locationManager = nil
      }
    }
    if manager.authorizationStatus == .notDetermined {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        authorizing = continuation
        manager.requestWhenInUseAuthorization()
      }
      await backInFront()
    }
    guard !Task.isCancelled, current(), locationManager === manager,
      UIApplication.shared.applicationState == .active
    else { throw Failure("原定位调用已结束或 App 已离开前台，没有继续读取。") }
    guard [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) else {
      throw Failure("用户没有给定位权限。可以到系统设置里打开。")
    }
    let located: CLLocation? = await withCheckedContinuation { continuation in
      locating = continuation
      manager.requestLocation()
    }
    guard !Task.isCancelled, current(), locationManager === manager,
      UIApplication.shared.applicationState == .active
    else { throw Failure("原定位调用已结束或 App 已离开前台，没有继续读取。") }
    guard let fix = located else { throw Failure("这次没有定位到。") }
    return [
      "latitude": fix.coordinate.latitude, "longitude": fix.coordinate.longitude,
      "horizontal_accuracy_m": max(fix.horizontalAccuracy, 0),
      "accuracy_authorization": manager.accuracyAuthorization == .fullAccuracy ? "full" : "reduced",
      "timestamp": Self.instant(fix.timestamp),
    ]
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        guard manager === self.locationManager, manager.authorizationStatus != .notDetermined else { return }
        self.authorizing?.resume()
        self.authorizing = nil
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    let last = locations.last
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        guard manager === self.locationManager else { return }
        self.locating?.resume(returning: last)
        self.locating = nil
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        guard manager === self.locationManager else { return }
        self.locating?.resume(returning: nil)
        self.locating = nil
      }
    }
  }

  // MARK: Text in an image

  /// On an image the user already picked for this conversation, so there's nothing new to ask.
  private func visionText(
    _ args: [String: Any], _ request: IOSPhoneRequest, _ authorize: () async -> Bool, _ current: () -> Bool
  ) async throws -> [String: Any] {
    guard let handle = args["image_handle"] as? String, let image = picked[handle], image.session == request.owner.sessionId,
      image.expires > Date()
    else { throw Failure("这张图片已经过期，或者不是这个对话选的。让用户重新选。") }
    guard current(), await authorize(), current() else { throw Failure("这个工具调用已经结束，没有执行。") }
    let asked = args["languages"] as? [String] ?? []
    // Left to itself it only reads English.
    let languages = asked.isEmpty ? ["zh-Hans", "zh-Hant", "en-US"] : asked
    let limit = args["max_bytes"] as? Int ?? 8192
    let file = image.file
    let lines: [String] = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.recognitionLanguages = languages
        do {
          try VNImageRequestHandler(url: file).perform([text])
          continuation.resume(returning: (text.results ?? []).compactMap { $0.topCandidates(1).first?.string })
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
    let all = lines.joined(separator: "\n").replacingOccurrences(of: "\0", with: "")
    let clipped = Self.clip(all, limit)
    return ["text": clipped, "truncated": clipped.utf8.count < all.utf8.count]
  }
}
