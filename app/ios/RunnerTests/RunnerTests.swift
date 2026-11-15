import UIKit
import WebKit
import XCTest

/// The browser and the system tools on the real frameworks, in the app's own process, with nothing
/// mocked but the person tapping the sheet. tools-check.mjs grants the permissions first and puts
/// each answer through the same checks the engine applies. The tools' sources are compiled into
/// this bundle, so it needs nothing of Flutter. photos_select isn't here: its picker runs in
/// another process, out of reach of a test in this one.
@MainActor
final class NativeToolsTests: XCTestCase {
  private enum Expect: String {
    case ok, refused, either
  }

  /// A call and its deadline: whichever finishes first decides.
  private final class Race {
    private var taken = false
    var call: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    func take() -> Bool {
      if taken { return false }
      taken = true
      return true
    }
  }

  private var tapping: Task<Void, Never>?
  private var saying = true

  static func top() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  private func ready() async throws {
    for _ in 0..<300 {
      if UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
        Self.top()?.viewIfLoaded?.window != nil
      {
        return
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTFail("the app never came to the front")
    throw CancellationError()
  }

  private static func buttons(in view: UIView) -> [UIButton] {
    view.subviews.flatMap { subview -> [UIButton] in
      if let button = subview as? UIButton { return [button] }
      return buttons(in: subview)
    }
  }

  /// Stands in for the person: answers every sheet as `saying` says, once it's fully on screen.
  private func startTapping() {
    tapping = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        if let self, let sheet = Self.top() as? IOSPhoneApproval, sheet.viewIfLoaded?.window != nil,
          !sheet.isBeingPresented, !sheet.isBeingDismissed
        {
          // Deny comes first on the sheet, allow second.
          let choices = Self.buttons(in: sheet.view)
          if let choice = self.saying ? choices.last : choices.first {
            choice.sendActions(for: .touchUpInside)
          }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
      }
    }
  }

  private func request(_ kind: String, _ fields: [String: Any], session: String) throws -> IOSPhoneRequest {
    var action = fields
    action["kind"] = kind
    let body: [String: Any] = [
      "v": 1, "runId": "tools-check", "id": UUID().uuidString,
      "owner": ["sessionId": session, "callId": UUID().uuidString],
      "action": action, "expiresAt": Date().timeIntervalSince1970 * 1000 + 300_000,
    ]
    return try JSONDecoder().decode(IOSPhoneRequest.self, from: JSONSerialization.data(withJSONObject: body))
  }

  private func note(_ row: [String: Any]) throws {
    guard let directory = ProcessInfo.processInfo.environment["DSH_TOOLS_CHECK_DIR"] else { return }
    let data = try JSONSerialization.data(withJSONObject: row)
    let file = URL(fileURLWithPath: directory).appendingPathComponent("rows.jsonl")
    if !FileManager.default.fileExists(atPath: file.path) {
      guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
      }
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: data + Data("\n".utf8))
    try handle.close()
  }

  /// A permission prompt nobody is there for would otherwise hold the whole run. Running out of
  /// time fails the test whatever answer it wanted, since a refusal can't be told from a hang.
  private func timed(
    _ group: String, _ name: String, _ args: [String: Any], _ expect: Expect, seconds: Double = 60,
    _ body: @escaping @MainActor () async -> IOSPhoneOutcome
  ) async throws -> IOSPhoneOutcome {
    let started = Date()
    let race = Race()
    defer {
      race.call?.cancel()
      race.deadline?.cancel()
    }
    let answer: IOSPhoneOutcome = try await withCheckedThrowingContinuation { continuation in
      race.call = Task { @MainActor in
        let value = await body()
        if race.take() { continuation.resume(returning: value) }
      }
      race.deadline = Task { @MainActor in
        do {
          try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
          return
        }
        if race.take() {
          race.call?.cancel()
          do {
            try self.note(["group": group, "name": name, "args": args, "expect": expect.rawValue, "isError": true,
            "timedOut": true, "text": "timed out after \(Int(seconds)) s", "ms": Int(seconds * 1000)])
          } catch {
            XCTFail("could not record \(group) \(name): \(error)")
          }
          continuation.resume(throwing: CancellationError())
        }
      }
    }
    var row: [String: Any] = [
      "group": group, "name": name, "args": args, "expect": expect.rawValue, "isError": answer.isError,
      "text": String(answer.text.prefix(8000)), "ms": Int(Date().timeIntervalSince(started) * 1000),
    ]
    if let image = answer.image { row["imageBytes"] = image.count }
    do { try note(row) }
    catch { XCTFail("could not record \(group) \(name): \(error)") }
    switch expect {
    case .ok: XCTAssertFalse(answer.isError, "\(name): \(answer.text)")
    case .refused: XCTAssertTrue(answer.isError, "\(name) should have been refused: \(answer.text)")
    case .either: break
    }
    return answer
  }

  private func parsed(_ answer: IOSPhoneOutcome) -> [String: Any] {
    guard !answer.isError, let brace = answer.text.firstIndex(of: "{"),
      let data = String(answer.text[brace...]).data(using: .utf8),
      let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return [:] }
    return value
  }

  // Compiles the actual intent implementation into this test bundle. The receiver observes
  // the handoff consumed by DshPlugin; this does not exercise Siri dispatch or Flutter.
  func testSiriPerformHandoff() async throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("AppIntents requires iOS 16") }
    defer { SystemEntries.attach { _ in } }
    var received: [[String: String]] = []
    var ask = AskDshIntent()
    ask.text = "测试 DSH\nsecond line"
    // Nothing has attached to this bundle's SystemEntries yet: a cold app launch.
    _ = try await ask.perform()
    _ = try await ask.perform()
    _ = try await VoiceInputIntent().perform()
    _ = try await NewChatIntent().perform()
    XCTAssertTrue(received.isEmpty)
    SystemEntries.attach { received.append($0) }
    let queued = received
    let expected: [[String: String]] = [
      ["kind": "new", "text": ask.text], ["kind": "new", "text": ask.text],
      ["kind": "voice"], ["kind": "new"],
    ]
    XCTAssertEqual(queued, expected)
    try note(["group": "siri", "name": "queued", "args": [String: String](), "expect": "ok",
      "isError": queued != expected, "text": "perform before attach", "ms": 0, "entries": queued])

    // Attaching again must not replay the drained queue.
    received.removeAll()
    SystemEntries.attach { received.append($0) }
    XCTAssertTrue(received.isEmpty)
    _ = try await ask.perform()
    _ = try await ask.perform()
    _ = try await VoiceInputIntent().perform()
    _ = try await NewChatIntent().perform()
    XCTAssertEqual(received, expected)
    try note(["group": "siri", "name": "attached", "args": [String: String](), "expect": "ok",
      "isError": received != expected, "text": "perform after attach; no replay", "ms": 0, "entries": received])
  }

  /// Real NSItemProvider file loading and the extension's original copy/seal path, without UI.
  func testShareFileCollection() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("share-test-" + UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let source = root.appendingPathComponent("payload.bin")
    try Data("share payload 中文".utf8).write(to: source)
    let large = root.appendingPathComponent("large.bin")
    XCTAssertTrue(manager.createFile(atPath: large.path, contents: nil))
    let handle = try FileHandle(forWritingTo: large)
    try handle.truncate(atOffset: 200 * 1024 * 1024 + 1)
    try handle.close()

    func provider(_ url: URL, name: String) -> NSItemProvider {
      let item = NSItemProvider()
      item.suggestedName = name
      item.registerFileRepresentation(forTypeIdentifier: "public.data", fileOptions: [], visibility: .all) { completion in
        completion(url, false, nil)
        return nil
      }
      return item
    }
    let input = NSExtensionItem()
    input.attributedTitle = NSAttributedString(string: "  Shared files  ")
    input.attributedContentText = NSAttributedString(string: "synthetic share")
    // Oversized rejection must not use an accepted-file slot. Duplicate names must
    // remain distinct, and the reserved manifest filename must not overwrite metadata.
    input.attachments = [provider(large, name: "large.bin")]
      + (0..<10).map { provider(source, name: $0 == 0 ? "manifest.json" : "same.bin") }
    let inbox = root.appendingPathComponent("inbox")
    let collected = expectation(description: "extension sealed files")
    let collector = ShareViewController()
    collector.collect([input], in: inbox) { ok in
      XCTAssertTrue(ok)
      collected.fulfill()
    }
    await fulfillment(of: [collected], timeout: 120)
    let folders = try manager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
    XCTAssertEqual(folders.count, 1)
    let folder = try XCTUnwrap(folders.first)
    XCTAssertFalse(folder.lastPathComponent.hasPrefix(ShareInbox.unfinishedPrefix))
    // Decode from disk after collection, just as a later app launch must do.
    let manifest = try JSONDecoder().decode(ShareInbox.Manifest.self,
      from: Data(contentsOf: folder.appendingPathComponent(ShareInbox.manifestName)))
    XCTAssertEqual(manifest.subject, "Shared files")
    XCTAssertEqual(manifest.text, "synthetic share")
    XCTAssertEqual(manifest.files.count, 9)
    XCTAssertEqual(Set(manifest.files.map(\.name)).count, 9)
    XCTAssertFalse(manifest.files.contains { $0.name == ShareInbox.manifestName })
    XCTAssertEqual(manifest.skipped.map(\.reason), ["too_large", "too_many"])
    for file in manifest.files {
      XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(file.name)), try Data(contentsOf: source))
    }
    try note(["group": "share", "name": "file-collection", "args": [String: String](), "expect": "ok", "isError": false,
      "text": "real file providers and sealed inbox", "ms": 0, "files": manifest.files.count,
      "uniqueNames": Set(manifest.files.map(\.name)).count, "skipped": manifest.skipped.map(\.reason)])
  }

  func testShareTotalByteLimit() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("share-total-" + UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let source = root.appendingPathComponent("boundary.bin")
    XCTAssertTrue(manager.createFile(atPath: source.path, contents: nil))
    let handle = try FileHandle(forWritingTo: source)
    try handle.truncate(atOffset: 200 * 1024 * 1024)
    try handle.close()
    let small = root.appendingPathComponent("one.bin")
    try Data([42]).write(to: small)
    let input = NSExtensionItem()
    input.attachments = [source, source, small].map { url in
      let item = NSItemProvider()
      item.suggestedName = url.lastPathComponent
      item.registerFileRepresentation(forTypeIdentifier: "public.data", fileOptions: [], visibility: .all) { completion in
        completion(url, false, nil)
        return nil
      }
      return item
    }
    let inbox = root.appendingPathComponent("inbox")
    let collected = expectation(description: "extension enforced total bytes")
    let collector = ShareViewController()
    collector.collect([input], in: inbox) { ok in
      XCTAssertTrue(ok)
      collected.fulfill()
    }
    await fulfillment(of: [collected], timeout: 120)
    let folders = try manager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
    XCTAssertEqual(folders.count, 1)
    let folder = try XCTUnwrap(folders.first)
    let manifest = try JSONDecoder().decode(ShareInbox.Manifest.self,
      from: Data(contentsOf: folder.appendingPathComponent(ShareInbox.manifestName)))
    XCTAssertEqual(manifest.files.count, 2)
    XCTAssertEqual(manifest.skipped.map(\.reason), ["too_large"])
    var total: Int64 = 0
    for file in manifest.files {
      let size = try manager.attributesOfItem(atPath: folder.appendingPathComponent(file.name).path)[.size] as? Int64
      XCTAssertEqual(size, 200 * 1024 * 1024)
      total += size ?? 0
    }
    try note(["group": "share", "name": "total-byte-limit", "args": [String: String](), "expect": "ok", "isError": false,
      "text": "two boundary-sized files, one byte beyond total refused", "ms": 0,
      "files": manifest.files.count, "bytes": total, "skipped": manifest.skipped.map(\.reason)])
  }

  // MARK: The system tools

  @discardableResult
  private func system(
    _ tools: IOSSystemTools, _ name: String, _ args: [String: Any] = [:], session: String = "session-a", expect: Expect = .ok
  ) async throws -> [String: Any] {
    let params = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
    let call = try request("system-\(name)", ["params": params], session: session)
    let answer = try await timed("system", name, args, expect) {
      await tools.run(call, authorize: { true }, current: { !Task.isCancelled })
    }
    return parsed(answer)
  }

  private func ids(_ value: [String: Any]) -> [String] {
    ((value["items"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
  }

  func testSystemTools() async throws {
    try await ready()
    startTapping()
    defer { tapping?.cancel() }
    let actions = IOSPhoneActions(presenter: { NativeToolsTests.top() })
    let tools = IOSSystemTools(actions: actions, presenter: { NativeToolsTests.top() })
    defer { tools.retire() }

    // Saying no writes nothing.
    let declined = "DSH tools check declined \(UUID().uuidString.prefix(8))"
    saying = false
    try await system(tools, "reminders_create", ["title": declined], expect: .refused)
    saying = true
    let afterDecline = try await system(tools, "reminders_list", ["query": declined, "limit": 5, "include_completed": true])
    XCTAssertEqual(ids(afterDecline), [])

    let title = "DSH tools check \(UUID().uuidString.prefix(8))"
    let due = "2031-03-04T05:06:07.000Z"
    let created = try await system(tools, "reminders_create", ["title": title, "notes": "from the check", "due": due])
    let item = created["item"] as? [String: Any]
    XCTAssertEqual(item?["title"] as? String, title)
    XCTAssertEqual(item?["due"] as? String, due)
    let listed = try await system(tools, "reminders_list", ["query": title, "limit": 5, "include_completed": false])
    let row = (listed["items"] as? [[String: Any]])?.first
    XCTAssertEqual(row?["id"] as? String, item?["id"] as? String)
    XCTAssertEqual(row?["version"] as? String, item?["version"] as? String, "a reminder's version changed with nothing touching it")
    if let id = row?["id"] as? String, let version = row?["version"] as? String {
      let done = try await system(tools, "reminders_complete", ["id": id, "version": version, "completed": true])
      XCTAssertEqual((done["item"] as? [String: Any])?["completed"] as? Bool, true)
      // The version it was checked against has gone, so a second go at the same one is refused.
      try await system(tools, "reminders_complete", ["id": id, "version": version, "completed": false], expect: .refused)
      let open = try await system(tools, "reminders_list", ["query": title, "limit": 5, "include_completed": false])
      XCTAssertEqual(ids(open), [])
      let all = try await system(tools, "reminders_list", ["query": title, "limit": 5, "include_completed": true])
      XCTAssertEqual(ids(all), [id])
    }

    let name = "Toolcheck\(UUID().uuidString.prefix(6))"
    let contact = try await system(
      tools, "contacts_create", ["given_name": name, "family_name": "Check", "phone": "+86 138 0000 0000", "email": "tool.check@example.com"])
    XCTAssertEqual(contact["committed"] as? Bool, true)
    let found = try await system(tools, "contacts_search", ["query": name, "limit": 5, "fields": ["email", "phone"]])
    XCTAssertEqual(ids(found), [contact["id"] as? String ?? ""])
    let person = (found["items"] as? [[String: Any]])?.first
    XCTAssertEqual(person?["email"] as? [String], ["tool.check@example.com"])

    let place = try await system(tools, "location_current")
    XCTAssertEqual(place["latitude"] as? Double ?? 0, 31.2304, accuracy: 0.01)
    XCTAssertEqual(place["longitude"] as? Double ?? 0, 121.4737, accuracy: 0.01)

    // What photos_select leaves behind, from a picture with text on it.
    let picture = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 300)).pngData { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 900, height: 300))
      NSString(string: "DSH Go 工具检查 12345").draw(
        at: CGPoint(x: 40, y: 100),
        withAttributes: [.font: UIFont.systemFont(ofSize: 72), .foregroundColor: UIColor.black])
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try picture.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let handle = "abcdefghijklmnopqrstuvwxyz012345"
    tools.picked[handle] = IOSSystemTools.Picked(session: "session-a", file: file, expires: Date().addingTimeInterval(600))
    let read = try await system(tools, "vision_ocr", ["image_handle": handle, "max_bytes": 8192])
    let text = read["text"] as? String ?? ""
    XCTAssertTrue(text.contains("DSH"), "read: \(text)")
    XCTAssertTrue(text.contains("工具"), "read: \(text)")
    try await system(tools, "vision_ocr", ["image_handle": handle, "max_bytes": 8192], session: "session-b", expect: .refused)
  }

  // MARK: The browser tools

  @discardableResult
  private func web(
    _ browser: IOSBrowser, _ name: String, _ args: [String: Any] = [:], expect: Expect = .ok, seconds: Double = 90
  ) async throws -> IOSPhoneOutcome {
    let call = try request("browser-\(name)", args, session: "session-a")
    return try await timed("browser", name, args, expect, seconds: seconds) {
      await browser.run(call, current: { !Task.isCancelled })
    }
  }

  private func read(_ browser: IOSBrowser) async throws -> [String: Any] {
    parsed(try await web(browser, "read", ["maxBytes": 49152]))
  }

  private func element(_ page: [String: Any], _ test: ([String: Any]) -> Bool) -> [String: Any]? {
    (page["elements"] as? [[String: Any]])?.first(where: test)
  }

  private func target(_ element: [String: Any]?, _ page: [String: Any]) throws -> [String: Any] {
    [
      "ref": try XCTUnwrap(element?["ref"] as? String, "no such element in \(page["url"] ?? "?")"),
      "epoch": try XCTUnwrap(page["epoch"] as? Int, "no epoch"),
    ]
  }

  private func named(_ name: String, _ page: [String: Any]) -> [String: Any]? {
    element(page) { $0["name"] as? String == name }
  }

  /// Picks the second choice in a list, by what the model is told to call it.
  private func choose(_ browser: IOSBrowser, _ name: String, in page: [String: Any]) async throws {
    let list = named(name, page)
    let options = (list?["state"] as? [String: Any])?["options"] as? [[String: Any]] ?? []
    XCTAssertEqual(options.count, 2, "\(name): \(list ?? [:])")
    var select = try target(list, page)
    select["text"] = try XCTUnwrap(options.last?["ref"] as? String, "no option to choose")
    try await web(browser, "select", select)
  }

  private func script(_ view: WKWebView, _ source: String) async throws -> Any? {
    try await view.callAsyncJavaScript("return eval(source)", arguments: ["source": source], in: nil, contentWorld: .page)
  }

  /// Exercise the real handoff sheet and its Done action, then wait for UIKit to dismiss it.
  /// As with approval sheets, only the person's tap is supplied by the test.
  private func completeHandoff(_ browser: IOSBrowser, view: WKWebView) async throws {
    let home = try XCTUnwrap(view.superview, "the agent web view is not attached")
    let host = try XCTUnwrap(Self.top(), "no presenter for handoff")
    let frame = view.frame
    let translates = view.translatesAutoresizingMaskIntoConstraints
    XCTAssertFalse(view.isUserInteractionEnabled)
    let doneTap = Task { @MainActor in
      for _ in 0..<100 {
        if Task.isCancelled { return false }
        if let sheet = Self.top() as? IOSBrowserSheet, sheet.viewIfLoaded?.window != nil,
          !sheet.isBeingPresented, !sheet.isBeingDismissed
        {
          // Never complete a fake sheet or a replacement web view.
          guard browser.webView === view, view.isDescendant(of: sheet.view),
            view.isUserInteractionEnabled
          else { return false }
          let choices = Self.buttons(in: sheet.view).filter { $0.currentTitle == "完成" }
          guard choices.count == 1, let done = choices.first else { return false }
          done.sendActions(for: .touchUpInside)
          return true
        }
        do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
      }
      return false
    }
    defer {
      doneTap.cancel()
      // Failure cleanup only: a timed-out handoff must not leave its continuation or sheet live.
      browser.enteredBackground()
    }
    try await web(browser, "handoff", ["text": "Synthetic fixture: finish the handoff without entering personal data."], seconds: 15)
    let tapped = await doneTap.value
    XCTAssertTrue(tapped, "the real handoff sheet and its unique Done button were not observed")
    // handOver resumes when Done is handled, before the dismissal animation finishes.
    for _ in 0..<50 {
      if Self.top() === host, host.presentedViewController == nil { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertTrue(Self.top() === host, "handoff did not return to its presenter")
    XCTAssertNil(host.presentedViewController)
    XCTAssertTrue(browser.webView === view, "handoff replaced the WKWebView")
    XCTAssertTrue(view.superview === home, "handoff did not return the WKWebView to its original container")
    XCTAssertNotNil(view.window)
    XCTAssertFalse(view.isUserInteractionEnabled)
    XCTAssertEqual(view.translatesAutoresizingMaskIntoConstraints, translates)
    XCTAssertEqual(view.frame, frame)
  }

  private func fixture(_ browser: IOSBrowser) async throws {
    let view = try XCTUnwrap(browser.webView)
    let html = """
      <!doctype html><html><head><title>Tools fixture</title><meta name="viewport" content="width=device-width"></head><body>
      <h1>Fixture</h1><p id="tick">0</p>
      <p style="display:none">hidden-text-one</p><p style="opacity:0">hidden-text-two</p>
      <label for="q">Search</label><input id="q" type="text">
      <select id="plain" aria-label="Plain"><option value="a">Alpha</option><option value="b">Beta</option></select>
      <div style="position:relative;height:40px"><span>Language</span>
      <select id="veiled" aria-label="Veiled" style="opacity:0;position:absolute;left:0;top:0;width:100%;height:100%">
      <option value="x">Xray</option><option value="y">Yankee</option></select></div>
      <label><input id="box" type="checkbox" style="opacity:0">Agree</label>
      <button id="go" onclick="document.title='clicked'">Go</button>
      <button id="renamed">Before</button>
      <ul><li><span id="who">Row A</span><button>Remove</button></li></ul>
      <form><label for="pw">Code</label><input id="pw" type="password"><label for="other">Other</label><input id="other" type="text"></form>
      <div style="height:3000px"></div>
      <script>setInterval(() => { tick.textContent = Date.now(); document.body.dataset.tick = tick.textContent; }, 40);</script>
      </body></html>
      """
    view.loadHTMLString(html, baseURL: URL(string: "https://example.com/fixture"))
    for _ in 0..<50 {
      try await Task.sleep(nanoseconds: 200_000_000)
      let title = try await script(view, "document.title") as? String
      if title == "Tools fixture" { return }
    }
    XCTFail("the fixture never loaded")
  }

  func testBrowser() async throws {
    try await ready()
    startTapping()
    defer { tapping?.cancel() }
    let actions = IOSPhoneActions(presenter: { NativeToolsTests.top() })
    let browser = IOSBrowser(actions: actions, presenter: { NativeToolsTests.top() })
    defer { browser.retire() }

    try await web(browser, "read", expect: .refused)
    try await web(browser, "open", ["url": "http://127.0.0.1:8080/"], expect: .refused)
    saying = false
    try await web(browser, "open", ["url": "https://example.com/"], expect: .refused)
    saying = true
    try await web(browser, "open", ["url": "https://example.com/"])

    var page = try await read(browser)
    XCTAssertEqual(page["title"] as? String, "Example Domain")
    XCTAssertTrue((page["text"] as? String ?? "").contains("domain"), "read: \(page["text"] ?? "nothing")")

    let shot = try await web(browser, "screenshot")
    XCTAssertGreaterThan(shot.image?.count ?? 0, 1000)
    XCTAssertLessThanOrEqual(shot.image.flatMap { UIImage(data: $0)?.cgImage?.width } ?? .max, 720)

    let document = element(page) { $0["role"] as? String == "document" }
    var scroll = try target(document, page)
    scroll["direction"] = "down"
    try await web(browser, "scroll", scroll)

    // The one link leaves for a site nobody has approved: it stays put and says so.
    page = try await read(browser)
    let clicked = try await web(browser, "click", try target(element(page) { $0["role"] as? String == "link" }, page))
    try await Task.sleep(nanoseconds: 3_000_000_000)
    let answer = try await web(browser, "read", ["maxBytes": 49152])
    // Whichever call comes next after the blocked jump carries the note, and only that one.
    XCTAssertTrue((clicked.text + answer.text).contains("还没有批准"), "no note about the blocked link: \(clicked.text.prefix(300))")
    XCTAssertEqual(parsed(answer)["title"] as? String, "Example Domain")

    // A page of ours, with a clock ticking in it the way ads and tickers do.
    try await fixture(browser)
    let view = try XCTUnwrap(browser.webView)
    try await completeHandoff(browser, view: view)
    // The same page and the agent's isolated content world still work after the sheet returns.
    page = try await read(browser)
    let seen = page["text"] as? String ?? ""
    XCTAssertTrue(seen.contains("Fixture"), "read: \(seen.prefix(400))")
    XCTAssertFalse(seen.contains("hidden-text"), "text nobody can see reached the model: \(seen.prefix(400))")

    var fill = try target(named("Search", page), page)
    fill["text"] = "hello"
    try await web(browser, "fill", fill)
    let typed = try await script(view, "document.getElementById('q').value") as? String
    XCTAssertEqual(typed, "hello")

    page = try await read(browser)
    try await choose(browser, "Plain", in: page)
    let plain = try await script(view, "document.getElementById('plain').value") as? String
    XCTAssertEqual(plain, "b")

    // Native controls laid invisibly over something the page draws are what a person taps.
    page = try await read(browser)
    try await choose(browser, "Veiled", in: page)
    let veiled = try await script(view, "document.getElementById('veiled').value") as? String
    XCTAssertEqual(veiled, "y")
    page = try await read(browser)
    try await web(browser, "click", try target(named("Agree", page), page))
    let checked = try await script(view, "document.getElementById('box').checked") as? Bool
    XCTAssertEqual(checked, true)

    // Something else on the page changing, and scrolling, leave the rest of it usable.
    page = try await read(browser)
    _ = try await script(view, "document.body.insertAdjacentHTML('beforeend', '<p>arrived late</p>'); window.scrollTo(0, 40); 1")
    try await web(browser, "click", try target(named("Go", page), page))
    let title = try await script(view, "document.title") as? String
    XCTAssertEqual(title, "clicked")
    page = try await read(browser)
    var down = try target(element(page) { $0["role"] as? String == "document" }, page)
    down["direction"] = "down"
    try await web(browser, "scroll", down)

    // What the model was told about the thing it's acting on has to still be true.
    page = try await read(browser)
    _ = try await script(view, "document.getElementById('renamed').textContent = 'After'; 1")
    let renamed = try await web(browser, "click", try target(named("Before", page), page), expect: .refused)
    XCTAssertEqual(renamed.text, "TARGET_CHANGED")
    page = try await read(browser)
    _ = try await script(view, "document.getElementById('who').textContent = 'Row B'; 1")
    let reused = try await web(browser, "click", try target(named("Remove", page), page), expect: .refused)
    XCTAssertEqual(reused.text, "TARGET_CHANGED")

    page = try await read(browser)
    var secret = try target(named("Other", page), page)
    secret["text"] = "x"
    let kept = try await web(browser, "fill", secret, expect: .refused)
    XCTAssertEqual(kept.text, "SENSITIVE_TARGET")

    // A person can't tap through a dialog, so neither can the model; off screen it has to scroll.
    _ = try await script(view, "window.scrollTo(0, 0); document.body.insertAdjacentHTML('beforeend', '<div id=\"cover\" style=\"position:fixed;inset:0;background:#0003\"></div>'); 1")
    page = try await read(browser)
    let covered = try await web(browser, "click", try target(named("Go", page), page), expect: .refused)
    XCTAssertEqual(covered.text, "TARGET_OBSCURED_OR_NOT_IN_VIEW")
    _ = try await script(view, "document.getElementById('cover').remove(); 1")
    page = try await read(browser)
    var away = try target(element(page) { $0["role"] as? String == "document" }, page)
    away["direction"] = "down"
    try await web(browser, "scroll", away)
    // The web view does the scrolling, and the page only hears of it a moment later.
    var scrolled = 0.0
    for _ in 0..<25 where scrolled < 300 {
      try await Task.sleep(nanoseconds: 200_000_000)
      scrolled = try await script(view, "window.scrollY") as? Double ?? 0
    }
    XCTAssertGreaterThanOrEqual(scrolled, 300, "the scroll tool didn't move the page")
    page = try await read(browser)
    let gone = try await web(browser, "click", try target(named("Go", page), page), expect: .refused)
    XCTAssertEqual(gone.text, "TARGET_OBSCURED_OR_NOT_IN_VIEW")
    _ = try await script(view, "window.scrollTo(0, 0); 1")

    // Another address in the same page is another page.
    page = try await read(browser)
    _ = try await script(view, "history.pushState({}, '', '#moved'); 1")
    let moved = try await web(browser, "click", try target(named("Go", page), page), expect: .refused)
    XCTAssertEqual(moved.text, "STALE_SNAPSHOT")

    // Someone else's site, live. Being unable to reach it isn't a failure.
    let opened = try await web(browser, "open", ["url": "https://www.wikipedia.org/"], expect: .either)
    if !opened.isError {
      let isBox: ([String: Any]) -> Bool = { ($0["role"] as? String) == "searchbox" || ($0["role"] as? String) == "textbox" }
      page = try await read(browser)
      if let box = element(page, isBox) {
        var search = try target(box, page)
        search["text"] = "Swift"
        try await web(browser, "fill", search)
        page = try await read(browser)
        var press = try target(element(page, isBox), page)
        press["key"] = "Escape"
        try await web(browser, "press", press)
      }
      try await web(browser, "back")
      try await web(browser, "read", ["maxBytes": 49152])
    }

    try await web(browser, "close")
    try await web(browser, "read", expect: .refused)
  }
}
