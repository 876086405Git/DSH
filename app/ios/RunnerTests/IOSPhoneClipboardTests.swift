import Foundation
import XCTest
@testable import Runner

/// Exercises the actual clipboard lease state machine with synthetic bytes only.
/// This adapter never reads UIPasteboard.general and cannot establish OS paste
/// prompts, Handoff behavior, a human approval, or destination paste consumption.
/// IOSPhoneSystemPasteboard.replace uses .localOnly: true in production source;
/// this protocol does not expose that UIKit option, so these tests do not claim
/// to have observed it on a device. Apple compile/runtime validation is separate.
@MainActor
final class IOSPhoneClipboardTests: XCTestCase {
  private static let textType = "public.utf8-plain-text"

  @MainActor
  private final class RecordingPasteboard: IOSPhonePasteboardClient {
    struct Write {
      let items: [[String: Data]]
      let expires: Date?
      let allValuesWereData: Bool
    }
    struct Read: Equatable {
      let type: String
      let item: Int
    }

    var items: [[String: Data]]
    var revision = 100
    var publishCount = true
    var ignoreWrites = false
    var reportedItemCount: Int?
    var reportedTypes: (() -> [[String]]?)?
    var unreadableTypes = Set<String>()
    var didRead: (() -> Void)?
    var didReplace: (() -> Void)?
    var foreground: () -> Bool = { true }
    private(set) var accesses: [String] = []
    private(set) var backgroundAccesses = 0
    private(set) var writes: [Write] = []
    private(set) var reads: [Read] = []
    private(set) var typeReads = 0

    init(_ items: [[String: Data]]) { self.items = items }
    private func accessed(_ name: String) {
      accesses.append(name)
      if !foreground() { backgroundAccesses += 1 }
    }
    var changeCount: Int { accessed("changeCount"); return revision }
    var itemCount: Int { accessed("itemCount"); return reportedItemCount ?? items.count }
    func types() -> [[String]]? {
      accessed("types")
      typeReads += 1
      if let reportedTypes { return reportedTypes() }
      return items.map { $0.keys.sorted() }
    }
    func data(type: String, item: Int) -> Data? {
      accessed("data")
      reads.append(Read(type: type, item: item))
      let value = items.indices.contains(item) && !unreadableTypes.contains(type)
        ? items[item][type] : nil
      // A caller may have obtained bytes just before an external writer changes
      // the board. Return that captured value to model this read boundary.
      didRead?()
      return value
    }
    func replace(_ values: [[String: Any]], expires: Date?) {
      accessed("replace")
      var onlyData = true
      let materialized = values.map { item -> [String: Data] in
        var result: [String: Data] = [:]
        for (type, value) in item {
          if let data = value as? Data { result[type] = data }
          else { onlyData = false }
        }
        return result
      }
      writes.append(Write(items: materialized, expires: expires, allValuesWereData: onlyData))
      if !ignoreWrites {
        items = materialized
        if publishCount { revision += 1 }
      }
      didReplace?()
    }
    func externalWrite(_ replacement: [[String: Data]], advanceCount: Bool = true) {
      items = replacement
      if advanceCount { revision += 1 }
    }
  }

  @MainActor
  private final class State {
    var foreground = true
    var current = true
    var clock: TimeInterval? = 100
    var onSettle: (() -> Void)?
  }

  private struct Fixture {
    let board: RecordingPasteboard
    let state: State
    let clipboard: IOSPhoneClipboard
  }

  private func originalItems() -> [[String: Data]] {
    [
      [Self.textType: Data("synthetic original text 中文".utf8),
       "public.rtf": Data([0x7b, 0x5c, 0x72, 0x74, 0x66, 0x31, 0x00, 0xff, 0x7d])],
      ["public.png": Data([0x89, 0x50, 0x4e, 0x47, 0, 0xff, 0x80, 1]),
       "org.example.synthetic-binary": Data((0...255).map(UInt8.init))],
    ]
  }

  private func fixture(_ items: [[String: Data]]? = nil) -> Fixture {
    let board = RecordingPasteboard(items ?? originalItems())
    let state = State()
    board.foreground = { state.foreground }
    let clipboard = IOSPhoneClipboard(client: board, foreground: { state.foreground },
      settle: { state.onSettle?() }, now: { state.clock })
    return Fixture(board: board, state: state, clipboard: clipboard)
  }

  private func begin(_ fixture: Fixture, text: String = "synthetic temporary 中文🙂") async throws -> UUID {
    let prepared = try await fixture.clipboard.prepare(text: text, preflight: { () },
      confirm: { true }, current: { fixture.state.current })
    return prepared.id
  }

  private func expect(_ error: IOSPhoneClipboardError,
                      file: StaticString = #filePath, line: UInt = #line,
                      operation: () async throws -> Void) async {
    do {
      try await operation()
      XCTFail("expected a clipboard error", file: file, line: line)
    } catch let actual as IOSPhoneClipboardError {
      XCTAssertEqual(actual, error, file: file, line: line)
    } catch {
      // Never interpolate arbitrary error payloads or clipboard data.
      XCTFail("unexpected error category", file: file, line: line)
    }
  }

  private func assertContentFree(_ clipboard: IOSPhoneClipboard,
                                file: StaticString = #filePath, line: UInt = #line) {
    let status = clipboard.status()
    XCTAssertEqual(Set(status.keys), Set([
      "pendingRestore", "foregroundRequired", "memoryOnly",
      "pasteMayHaveBeenDispatched", "restoreRequested",
    ]), file: file, line: line)
    XCTAssertTrue(status.values.allSatisfy { $0 is Bool }, file: file, line: line)
    XCTAssertTrue(JSONSerialization.isValidJSONObject(status), file: file, line: line)
    XCTAssertEqual(status["foregroundRequired"] as? Bool, true, file: file, line: line)
    XCTAssertEqual(status["memoryOnly"] as? Bool, true, file: file, line: line)
  }

  func testMultipleItemsAndEveryRepresentationRestoreAsExactData() async throws {
    let f = fixture()
    let original = f.board.items
    let text = "整段中文🙂\n组合 e\u{301} 与 👨‍👩‍👧‍👦\t終"
    let id = try await begin(f, text: text)

    XCTAssertEqual(f.board.writes.count, 1)
    let temporary = try XCTUnwrap(f.board.writes.first)
    XCTAssertTrue(temporary.allValuesWereData)
    XCTAssertEqual(temporary.items.count, 1)
    XCTAssertEqual(temporary.items[0].count, 2)
    XCTAssertEqual(temporary.items[0][Self.textType], Data(text.utf8))
    XCTAssertNotNil(temporary.expires)
    for (index, item) in original.enumerated() {
      for type in item.keys {
        XCTAssertTrue(f.board.reads.contains(.init(type: type, item: index)))
      }
    }

    try await f.clipboard.restore(id: id, current: { true })
    XCTAssertEqual(f.board.writes.count, 2)
    XCTAssertTrue(f.board.writes[1].allValuesWereData)
    XCTAssertNil(f.board.writes[1].expires)
    XCTAssertEqual(f.board.writes[1].items, original)
    XCTAssertEqual(f.board.items, original)
    XCTAssertFalse(f.clipboard.hasPendingRestore)
  }

  func testEmptyPasteboardRestoresToNoItems() async throws {
    let f = fixture([])
    let id = try await begin(f)
    try await f.clipboard.restore(id: id, current: { true })
    XCTAssertEqual(f.board.writes.count, 2)
    XCTAssertTrue(f.board.items.isEmpty)
    XCTAssertFalse(f.clipboard.hasPendingRestore)
  }

  func testUnmaterializableRepresentationRejectsSnapshotWithoutWriting() async {
    let f = fixture()
    f.board.unreadableTypes.insert("public.rtf")
    let original = f.board.items
    await expect(.unavailable) { _ = try await self.begin(f) }
    XCTAssertTrue(f.board.writes.isEmpty)
    XCTAssertEqual(f.board.items, original)
    XCTAssertFalse(f.clipboard.hasPendingRestore)
  }

  func testUnknownOrInconsistentTypeListingRejectsWithoutWriting() async {
    for unknown in [true, false] {
      let f = fixture()
      f.board.reportedTypes = { unknown ? nil : [[Self.textType]] }
      await expect(.unavailable) { _ = try await self.begin(f) }
      XCTAssertTrue(f.board.writes.isEmpty)
      XCTAssertFalse(f.clipboard.hasPendingRestore)
    }
  }

  func testOversizeSnapshotAndDuplicateRepresentationsRejectWithoutWriting() async {
    let oversized = fixture([["org.example.first": Data(repeating: 1, count: 4 * 1024 * 1024)],
                             ["org.example.second": Data([2])]])
    await expect(.tooLarge) { _ = try await self.begin(oversized) }
    XCTAssertTrue(oversized.board.writes.isEmpty)
    XCTAssertFalse(oversized.clipboard.hasPendingRestore)

    let tooMany = fixture()
    tooMany.board.reportedItemCount = 17
    await expect(.tooLarge) { _ = try await self.begin(tooMany) }
    XCTAssertTrue(tooMany.board.writes.isEmpty)

    let duplicate = fixture([[Self.textType: Data([1])]])
    duplicate.board.reportedTypes = { [[Self.textType, Self.textType]] }
    await expect(.tooLarge) { _ = try await self.begin(duplicate) }
    XCTAssertTrue(duplicate.board.writes.isEmpty)
  }

  func testInvalidOrTooLargeTemporaryTextNeverReadsOrWritesTheBoard() async {
    for text in ["", "a\0b", String(repeating: "界", count: 1366)] {
      let f = fixture()
      await expect(.tooLarge) { _ = try await self.begin(f, text: text) }
      XCTAssertTrue(f.board.writes.isEmpty)
      XCTAssertTrue(f.board.reads.isEmpty)
      XCTAssertEqual(f.board.typeReads, 0)
    }
  }

  func testExternalChangeDuringSnapshotReadRejectsWithoutWriting() async {
    let f = fixture()
    let board = f.board
    var fired = false
    board.didRead = {
      if !fired { fired = true; board.revision += 1 }
    }
    defer { board.didRead = nil }
    await expect(.changed) { _ = try await self.begin(f) }
    XCTAssertTrue(fired)
    XCTAssertTrue(board.writes.isEmpty)
    XCTAssertFalse(f.clipboard.hasPendingRestore)
  }

  func testSameTypesWithDelayedCounterCannotHideChangedSnapshotPayload() async {
    let f = fixture([[Self.textType: Data("synthetic initial copy".utf8)]])
    let board = f.board
    let external = [[Self.textType: Data("synthetic later copy".utf8)]]
    var changed = false
    f.state.onSettle = {
      if board.writes.isEmpty && !changed {
        changed = true
        board.externalWrite(external, advanceCount: false)
      }
    }
    await expect(.changed) { _ = try await self.begin(f) }
    XCTAssertTrue(changed)
    XCTAssertTrue(board.writes.isEmpty)
    XCTAssertEqual(board.items, external)
    XCTAssertFalse(f.clipboard.hasPendingRestore)
  }

  func testAlreadyCancelledTaskCannotReadOrWriteTheClipboard() async {
    let f = fixture()
    let operation = Task { @MainActor in try await self.begin(f) }
    operation.cancel()
    await expect(.stale) { _ = try await operation.value }
    XCTAssertTrue(f.board.reads.isEmpty)
    XCTAssertTrue(f.board.writes.isEmpty)
    XCTAssertFalse(f.clipboard.hasPendingRestore)
  }

  func testCallerRevocationBeforeTemporaryWriteLeavesClipboardUntouched() async {
    let f = fixture()
    let state = f.state
    state.onSettle = { [weak state] in state?.current = false }
    await expect(.foreground) { _ = try await self.begin(f) }
    XCTAssertTrue(f.board.writes.isEmpty)
    XCTAssertFalse(f.clipboard.hasPendingRestore)
  }

  func testUnpublishedTemporaryWriteCounterFailsClosedAndRetainsSnapshot() async {
    let f = fixture()
    f.board.publishCount = false
    await expect(.changed) { _ = try await self.begin(f) }
    XCTAssertEqual(f.board.writes.count, 1)
    XCTAssertTrue(f.clipboard.hasPendingRestore)
    XCTAssertEqual(f.clipboard.status()["restoreRequested"] as? Bool, true)
    XCTAssertEqual(f.clipboard.status()["pasteMayHaveBeenDispatched"] as? Bool, false)
    assertContentFree(f.clipboard)
  }

  func testBackgroundSnapshotAndRestoreIncludingOverwriteAreRefused() async throws {
    let f = fixture()
    f.state.foreground = false
    await expect(.foreground) { _ = try await self.begin(f) }
    XCTAssertTrue(f.board.writes.isEmpty)
    XCTAssertTrue(f.board.reads.isEmpty)

    f.state.foreground = true
    let id = try await begin(f)
    f.state.foreground = false
    await expect(.foreground) {
      try await f.clipboard.restore(id: id, current: { true })
    }
    await expect(.foreground) {
      try await f.clipboard.restore(id: id, overwriteChanged: true, current: { true })
    }
    XCTAssertEqual(f.board.writes.count, 1)
    XCTAssertTrue(f.clipboard.hasPendingRestore)
  }

  func testChangedCounterMarkerOrTextRefusesPasteAndDefaultRestore() async throws {
    for mutation in 0...2 {
      let f = fixture()
      let id = try await begin(f)
      switch mutation {
      case 0: f.board.revision += 1
      case 1:
        let marker = try XCTUnwrap(f.board.items[0].keys.first { $0 != Self.textType })
        f.board.items[0][marker] = Data("synthetic foreign marker".utf8)
      default: f.board.items[0][Self.textType] = Data("synthetic different text".utf8)
      }
      XCTAssertThrowsError(try f.clipboard.validateForPaste(id, current: { f.state.current })) { error in
        XCTAssertEqual(error as? IOSPhoneClipboardError, .changed)
      }
      await expect(.changed) { try await f.clipboard.restore(id: id, current: { true }) }
      XCTAssertEqual(f.board.writes.count, 1)
      XCTAssertTrue(f.clipboard.hasPendingRestore)
      XCTAssertEqual(f.clipboard.status()["pasteMayHaveBeenDispatched"] as? Bool, false)
    }
  }

  func testCounterChangeDuringOwnershipReadRefusesPaste() async throws {
    let f = fixture()
    let id = try await begin(f)
    let board = f.board
    var changed = false
    board.didRead = {
      if !changed && board.reads.last?.type == Self.textType {
        changed = true
        board.externalWrite([[Self.textType: Data("synthetic intervening copy".utf8)]])
      }
    }
    defer { board.didRead = nil }
    XCTAssertThrowsError(try f.clipboard.validateForPaste(id, current: { f.state.current })) { error in
      XCTAssertEqual(error as? IOSPhoneClipboardError, .changed)
    }
    XCTAssertTrue(changed)
    XCTAssertEqual(board.writes.count, 1)
    XCTAssertEqual(f.clipboard.status()["pasteMayHaveBeenDispatched"] as? Bool, false)
    XCTAssertTrue(f.clipboard.hasPendingRestore)
  }

  func testExtraRepresentationWithSameMarkerAndTextRefusesPasteAndRestore() async throws {
    let f = fixture()
    let id = try await begin(f)
    // A target could choose an HTML representation instead of the approved
    // plain text. A lagging counter must not permit this extra representation.
    f.board.items[0]["public.html"] = Data("<b>synthetic external payload</b>".utf8)
    XCTAssertThrowsError(try f.clipboard.validateForPaste(id, current: { f.state.current })) { error in
      XCTAssertEqual(error as? IOSPhoneClipboardError, .changed)
    }
    await expect(.changed) { try await f.clipboard.restore(id: id, current: { true }) }
    XCTAssertEqual(f.board.writes.count, 1)
    XCTAssertTrue(f.clipboard.hasPendingRestore)
  }

  func testOldLeaseCannotRestoreOrRequestRestorationOfNewLease() async throws {
    let f = fixture()
    let old = try await begin(f, text: "synthetic first lease")
    try await f.clipboard.restore(id: old, current: { true })
    let fresh = try await begin(f, text: "synthetic second lease")
    XCTAssertNotEqual(old, fresh)
    let newContents = f.board.items
    await expect(.stale) { try await f.clipboard.restore(id: old, current: { true }) }
    XCTAssertThrowsError(try f.clipboard.validateForPaste(old, current: { f.state.current })) { error in
      XCTAssertEqual(error as? IOSPhoneClipboardError, .stale)
    }
    f.clipboard.requestRestore(old)
    XCTAssertEqual(f.board.writes.count, 3)
    XCTAssertEqual(f.board.items, newContents)
    XCTAssertEqual(f.clipboard.status()["restoreRequested"] as? Bool, false)
    XCTAssertTrue(f.clipboard.hasPendingRestore)
    try await f.clipboard.restore(id: fresh, current: { true })
    XCTAssertFalse(f.clipboard.hasPendingRestore)
  }

  func testQueuedOldCancellationCannotRestoreAReplacementLease() async throws {
    let f = fixture()
    let old = try await begin(f)
    f.clipboard.requestRestore(old)
    // Synchronously retire the old lease before its scheduled task can run.
    // This is an explicit fixture call, not a simulated human discard choice.
    try f.clipboard.discardSaved(id: old)
    let fresh = try await begin(f, text: "synthetic replacement lease")
    let currentContents = f.board.items
    let unexpected = expectation(description: "old cancellation cannot write")
    unexpected.isInverted = true
    f.board.didReplace = { unexpected.fulfill() }
    await fulfillment(of: [unexpected], timeout: 0.05)
    f.board.didReplace = nil
    XCTAssertEqual(f.board.writes.count, 2)
    XCTAssertEqual(f.board.items, currentContents)
    XCTAssertTrue(f.clipboard.hasPendingRestore)
    XCTAssertEqual(f.clipboard.status()["restoreRequested"] as? Bool, false)
    try await f.clipboard.restore(id: fresh, current: { true })
  }

  func testOverwriteOfExternalContentsRequiresExplicitMethodArgument() async throws {
    let f = fixture()
    let original = f.board.items
    let id = try await begin(f)
    f.board.externalWrite([[Self.textType: Data("synthetic external copy".utf8)]])
    await expect(.changed) { try await f.clipboard.restore(id: id, current: { true }) }
    XCTAssertEqual(f.board.writes.count, 1)

    // This explicitly exercises the internal parameter. It is NOT a simulated
    // human tap, and does not validate resolvePending's real native sheets.
    try await f.clipboard.restore(id: id, overwriteChanged: true, current: { true })
    XCTAssertEqual(f.board.items, original)
    XCTAssertEqual(f.board.writes.count, 2)
    XCTAssertFalse(f.clipboard.hasPendingRestore)
  }

  func testIgnoredRestoreWriteRetainsSnapshotAndReportsUnavailable() async throws {
    let f = fixture()
    let id = try await begin(f)
    let temporary = f.board.items
    f.board.ignoreWrites = true
    await expect(.unavailable) { try await f.clipboard.restore(id: id, current: { true }) }
    XCTAssertEqual(f.board.writes.count, 2)
    XCTAssertEqual(f.board.items, temporary)
    XCTAssertTrue(f.clipboard.hasPendingRestore)
    assertContentFree(f.clipboard)
  }

  func testExternalChangeAfterRestoreWriteDoesNotDiscardSavedSnapshot() async throws {
    let f = fixture()
    let id = try await begin(f)
    let board = f.board
    var fired = false
    f.state.onSettle = {
      if board.writes.count == 2 && !fired {
        fired = true
        board.externalWrite([[Self.textType: Data("synthetic post-restore copy".utf8)]])
      }
    }
    await expect(.unavailable) { try await f.clipboard.restore(id: id, current: { true }) }
    XCTAssertTrue(fired)
    XCTAssertTrue(f.clipboard.hasPendingRestore)
    XCTAssertEqual(board.writes.count, 2)
  }

  func testExternalChangeDuringRestoreReadbackRetainsSavedSnapshot() async throws {
    let f = fixture([[Self.textType: Data("synthetic original".utf8)]])
    let id = try await begin(f)
    let board = f.board
    var changed = false
    board.didRead = {
      if board.writes.count == 2 && !changed {
        changed = true
        board.externalWrite([[Self.textType: Data("synthetic changed during readback".utf8)]])
      }
    }
    defer { board.didRead = nil }
    await expect(.unavailable) { try await f.clipboard.restore(id: id, current: { true }) }
    XCTAssertTrue(changed)
    XCTAssertEqual(board.writes.count, 2)
    XCTAssertTrue(f.clipboard.hasPendingRestore)
  }

  func testConfirmedRestorationDoesNotRequireImmediateCounterPublication() async throws {
    let f = fixture()
    let original = f.board.items
    let id = try await begin(f)
    let writtenCount = f.board.revision
    f.board.publishCount = false
    try await f.clipboard.restore(id: id, current: { true })
    XCTAssertEqual(f.board.revision, writtenCount)
    XCTAssertEqual(f.board.items, original)
    XCTAssertFalse(f.clipboard.hasPendingRestore)
  }

  func testCancellationBeforePasteCanScheduleForegroundRestoration() async throws {
    let f = fixture()
    let original = f.board.items
    let id = try await begin(f)
    let restored = expectation(description: "foreground restoration completed")
    let clipboard = f.clipboard
    clipboard.onStateChanged = { [weak clipboard] in
      if clipboard?.hasPendingRestore == false { restored.fulfill() }
    }
    defer { clipboard.onStateChanged = nil }
    clipboard.requestRestore(id)
    await fulfillment(of: [restored], timeout: 1)
    XCTAssertEqual(f.board.writes.count, 2)
    XCTAssertEqual(f.board.items, original)
    XCTAssertFalse(clipboard.hasPendingRestore)
  }

  func testBackgroundCancellationWaitsForForegroundRestoreRequest() async throws {
    let f = fixture()
    let id = try await begin(f)
    f.state.foreground = false
    f.clipboard.requestRestore(id)
    XCTAssertEqual(f.board.writes.count, 1)
    XCTAssertTrue(f.clipboard.hasPendingRestore)
    XCTAssertEqual(f.clipboard.status()["restoreRequested"] as? Bool, true)

    let restored = expectation(description: "later foreground restoration completed")
    let clipboard = f.clipboard
    clipboard.onStateChanged = { [weak clipboard] in
      if clipboard?.hasPendingRestore == false { restored.fulfill() }
    }
    defer { clipboard.onStateChanged = nil }
    f.state.foreground = true
    clipboard.requestRestore(id)
    await fulfillment(of: [restored], timeout: 1)
    XCTAssertFalse(clipboard.hasPendingRestore)
    XCTAssertEqual(f.board.writes.count, 2)
  }

  func testAttemptedPasteIsNeverAutomaticallyRestoredOnCancellation() async throws {
    let f = fixture()
    let id = try await begin(f)
    try f.clipboard.validateForPaste(id, current: { f.state.current })
    XCTAssertEqual(f.clipboard.status()["pasteMayHaveBeenDispatched"] as? Bool, true)
    let unsolicited = expectation(description: "no automatic restore write")
    unsolicited.isInverted = true
    f.board.didReplace = { unsolicited.fulfill() }
    f.state.foreground = false
    f.clipboard.requestRestore(id)
    f.state.foreground = true
    f.clipboard.requestRestore(id)
    // A short negative-test deadline catches a scheduled restore task. It is
    // not a device timing argument and never stands in for a paste ACK.
    await fulfillment(of: [unsolicited], timeout: 0.05)
    f.board.didReplace = nil
    XCTAssertTrue(f.clipboard.hasPendingRestore)
    XCTAssertEqual(f.board.writes.count, 1)
    XCTAssertEqual(f.clipboard.status()["restoreRequested"] as? Bool, true)
    try await f.clipboard.restore(id: id, current: { true })
    XCTAssertFalse(f.clipboard.hasPendingRestore)
  }

  func testStatusContainsOnlyFlagsThroughoutLeaseLifecycle() async throws {
    let f = fixture()
    assertContentFree(f.clipboard)
    let id = try await begin(f)
    assertContentFree(f.clipboard)
    try f.clipboard.validateForPaste(id, current: { f.state.current })
    assertContentFree(f.clipboard)
    f.state.foreground = false
    f.clipboard.requestRestore(id)
    assertContentFree(f.clipboard)
    f.state.foreground = true
    try await f.clipboard.restore(id: id, current: { true })
    assertContentFree(f.clipboard)
  }

  func testFailedTargetFocusPreflightCannotReadOrChangeClipboardOrAskForStaging() async {
    enum SyntheticFailure: Error { case noKeyboard }
    let f = fixture()
    f.state.foreground = false
    var asked = false
    do {
      let _: IOSPhoneClipboard.Prepared<String> = try await f.clipboard.prepare(text: "合成文字", preflight: {
        XCTAssertTrue(f.board.accesses.isEmpty)
        throw SyntheticFailure.noKeyboard
      }, confirm: {
        asked = true; return true
      }, current: { f.state.current })
      XCTFail("a failed focus preflight must terminate preparation")
    } catch SyntheticFailure.noKeyboard { /* The production flow propagates the failed preflight. */ }
    catch { XCTFail("unexpected error category") }
    XCTAssertFalse(asked)
    XCTAssertTrue(f.board.accesses.isEmpty)
    XCTAssertFalse(f.clipboard.hasPendingRestore)
  }

  func testForegroundStagingFollowsSuccessfulTargetPreflightAndNewConfirmation() async throws {
    let f = fixture()
    f.state.foreground = false
    var stages: [String] = []
    let prepared = try await f.clipboard.prepare(text: "合成文字", preflight: {
      stages.append("target-focus")
      XCTAssertTrue(f.board.accesses.isEmpty)
      return "synthetic-focus-observation"
    }, confirm: {
      stages.append("foreground-confirmation")
      XCTAssertEqual(stages, ["target-focus", "foreground-confirmation"])
      XCTAssertTrue(f.board.accesses.isEmpty)
      f.state.foreground = true
      return true // An injected gate result, not a simulated human authorization.
    }, current: { f.state.current })
    XCTAssertEqual(prepared.focus, "synthetic-focus-observation")
    XCTAssertEqual(f.board.writes.count, 1)
    XCTAssertEqual(f.board.backgroundAccesses, 0)
    XCTAssertTrue(f.clipboard.hasPendingRestore)
  }

  func testRefusedStagingAndRevokedPreflightLeaveClipboardUntouched() async {
    for revoked in [false, true] {
      let f = fixture()
      var asked = false
      await expect(revoked ? .stale : .denied) {
        _ = try await f.clipboard.prepare(text: "合成文字", preflight: {
          if revoked { f.state.current = false }
        }, confirm: {
          asked = true; return false
        }, current: { f.state.current })
      }
      XCTAssertEqual(asked, !revoked)
      XCTAssertTrue(f.board.accesses.isEmpty)
      XCTAssertFalse(f.clipboard.hasPendingRestore)
    }
  }

  func testPreparationCannotReenterWhileAwaitingFocusOrConfirmation() async throws {
    let f = fixture()
    let prepared = try await f.clipboard.prepare(text: "合成文字", preflight: {
      await self.expect(.pending) { _ = try await self.begin(f) }
      XCTAssertTrue(f.board.accesses.isEmpty)
      return "first-focus"
    }, confirm: {
      await self.expect(.pending) { _ = try await self.begin(f) }
      XCTAssertTrue(f.board.accesses.isEmpty)
      return true
    }, current: { f.state.current })
    XCTAssertEqual(prepared.focus, "first-focus")
    XCTAssertEqual(f.board.writes.count, 1)
  }

  func testForegroundLossAfterTemporaryWriteNeverReadsBackgroundCounterOrMarker() async {
    let f = fixture()
    f.state.onSettle = {
      if f.board.writes.count == 1 { f.state.foreground = false }
    }
    await expect(.foreground) { _ = try await self.begin(f) }
    XCTAssertEqual(f.board.writes.count, 1)
    XCTAssertEqual(f.board.backgroundAccesses, 0)
    XCTAssertEqual(f.board.accesses.last, "replace")
    XCTAssertTrue(f.clipboard.hasPendingRestore)
    XCTAssertEqual(f.clipboard.status()["restoreRequested"] as? Bool, true)
    XCTAssertEqual(f.clipboard.status()["pasteMayHaveBeenDispatched"] as? Bool, false)
  }

  func testRevokedCallerAfterWriteStillRecordsCountForLaterAuthorizedRestore() async throws {
    let f = fixture()
    let original = f.board.items
    f.state.onSettle = {
      if f.board.writes.count == 1 { f.state.current = false }
    }
    await expect(.foreground) { _ = try await self.begin(f) }
    f.state.onSettle = nil
    XCTAssertFalse(f.state.current)
    XCTAssertTrue(f.state.foreground)
    XCTAssertEqual(f.board.accesses.last, "changeCount")
    XCTAssertEqual(f.board.backgroundAccesses, 0)
    XCTAssertEqual(f.clipboard.status()["restoreRequested"] as? Bool, true)
    XCTAssertEqual(f.clipboard.status()["pasteMayHaveBeenDispatched"] as? Bool, false)
    let id = try XCTUnwrap(f.clipboard.restorationID)
    // A new authorized restore, not reuse of the revoked input authorization.
    try await f.clipboard.restore(id: id, current: { true })
    XCTAssertEqual(f.board.items, original)
    XCTAssertEqual(f.board.writes.count, 2)
    XCTAssertFalse(f.clipboard.hasPendingRestore)
  }

  func testTaskCancellationAfterWriteStillAllowsLaterForegroundRestore() async throws {
    let f = fixture()
    let original = f.board.items
    let operation = Task { @MainActor in try await self.begin(f) }
    f.state.onSettle = {
      if f.board.writes.count == 1 { operation.cancel() }
    }
    await expect(.foreground) { _ = try await operation.value }
    f.state.onSettle = nil
    XCTAssertTrue(operation.isCancelled)
    XCTAssertTrue(f.state.current)
    XCTAssertEqual(f.board.accesses.last, "changeCount")
    XCTAssertEqual(f.board.backgroundAccesses, 0)
    XCTAssertEqual(f.clipboard.status()["pasteMayHaveBeenDispatched"] as? Bool, false)
    let id = try XCTUnwrap(f.clipboard.restorationID)
    try await f.clipboard.restore(id: id, current: { true })
    XCTAssertEqual(f.board.items, original)
    XCTAssertEqual(f.board.writes.count, 2)
    XCTAssertFalse(f.clipboard.hasPendingRestore)
  }

  func testSavedCountAfterRevocationStillRejectsAnExternalReplacement() async throws {
    let f = fixture()
    f.state.onSettle = {
      if f.board.writes.count == 1 { f.state.current = false }
    }
    await expect(.foreground) { _ = try await self.begin(f) }
    f.state.onSettle = nil
    let id = try XCTUnwrap(f.clipboard.restorationID)
    let external = [[Self.textType: Data("synthetic later external copy".utf8)]]
    f.board.externalWrite(external)
    await expect(.changed) { try await f.clipboard.restore(id: id, current: { true }) }
    XCTAssertEqual(f.board.items, external)
    XCTAssertEqual(f.board.writes.count, 1)
    XCTAssertTrue(f.clipboard.hasPendingRestore)
  }

  func testBackgroundPasteUsesOneShortLocalLeaseWithoutAnyPasteboardGetter() async throws {
    let f = fixture()
    let id = try await begin(f)
    let accesses = f.board.accesses
    f.state.foreground = false
    f.state.clock = 111.999
    try f.clipboard.validateForPaste(id, current: { f.state.current })
    XCTAssertEqual(f.board.accesses, accesses)
    XCTAssertEqual(f.board.backgroundAccesses, 0)
    XCTAssertTrue(f.clipboard.hasPendingRestore)
    XCTAssertEqual(f.clipboard.status()["pasteMayHaveBeenDispatched"] as? Bool, true)
    XCTAssertThrowsError(try f.clipboard.validateForPaste(id, current: { f.state.current })) { error in
      XCTAssertEqual(error as? IOSPhoneClipboardError, .stale)
    }
    XCTAssertEqual(f.board.accesses, accesses)
  }

  func testCachedForegroundLeaseDoesNotClaimBackgroundExternalChangeDetection() async throws {
    let f = fixture()
    let id = try await begin(f)
    f.state.foreground = false
    let accesses = f.board.accesses
    f.board.externalWrite([[Self.textType: Data("synthetic external copy".utf8)]])
    // This deliberately records the limit of the local lease: no supported
    // background read establishes what a target will paste. The native staging
    // sheet discloses that boundary; this fixture is not a CAS or HID test.
    XCTAssertNoThrow(try f.clipboard.validateForPaste(id, current: { f.state.current }))
    XCTAssertEqual(f.board.accesses, accesses)
    XCTAssertEqual(f.board.backgroundAccesses, 0)
    f.state.foreground = true
    await expect(.changed) { try await f.clipboard.restore(id: id, current: { true }) }
    XCTAssertEqual(f.board.writes.count, 1)
  }

  func testExactExpiryInvalidClockOrBackwardClockRefusesWithoutBackgroundReads() async throws {
    let samples: [TimeInterval?] = [112, 112.001, 130, 99, nil,
      TimeInterval.nan, TimeInterval.infinity, -TimeInterval.infinity]
    for sample in samples {
      let f = fixture()
      let id = try await begin(f)
      let accesses = f.board.accesses
      f.state.foreground = false; f.state.clock = sample
      XCTAssertThrowsError(try f.clipboard.validateForPaste(id, current: { f.state.current })) { error in
        XCTAssertEqual(error as? IOSPhoneClipboardError, .stale)
      }
      XCTAssertEqual(f.board.accesses, accesses)
      XCTAssertEqual(f.board.backgroundAccesses, 0)
      XCTAssertEqual(f.clipboard.status()["pasteMayHaveBeenDispatched"] as? Bool, false)
    }
  }

  func testMissingClockBeforeSnapshotNeverReadsOrWritesClipboard() async {
    let f = fixture()
    f.state.clock = nil
    await expect(.stale) { _ = try await self.begin(f) }
    XCTAssertTrue(f.board.accesses.isEmpty)
    XCTAssertFalse(f.clipboard.hasPendingRestore)
  }

  func testClipboardPasteReceiptIsFixedAndRetiresObservationWithoutAnImage() {
    var retireCount = 0
    let outcome = IOSPhoneCoreActions.clipboardPasteOutcome(submitRequested: false) {
      retireCount += 1
    }
    XCTAssertEqual(retireCount, 1)
    XCTAssertFalse(outcome.isError)
    XCTAssertNil(outcome.image)
    XCTAssertTrue(outcome.text.contains("可能粘贴了其他内容，请用户核对"))
    XCTAssertTrue(outcome.text.contains("不回传粘贴后的读屏文字或图片"))
    XCTAssertTrue(outcome.text.contains("不要自动重试"))
    XCTAssertFalse(outcome.text.contains("screen="))
    XCTAssertFalse(outcome.text.contains("OCR 看到了"))
  }

  func testRequestedSubmitAfterClipboardPasteReturnsIncompleteContentFreeReceipt() {
    var retired = false
    let outcome = IOSPhoneCoreActions.clipboardPasteOutcome(submitRequested: true) {
      retired = true
    }
    XCTAssertTrue(retired)
    XCTAssertTrue(outcome.isError)
    XCTAssertNil(outcome.image)
    XCTAssertTrue(outcome.text.contains("本次未派发回车／发送按键"))
    XCTAssertTrue(outcome.text.contains("目标应用也可能自行处理粘贴"))
    XCTAssertTrue(outcome.text.contains("handoff"))
    XCTAssertTrue(outcome.text.contains("可能粘贴了其他内容，请用户核对"))
  }

  func testRestoreRequestOrCurrentRevocationDisablesBackgroundLeaseWithoutReads() async throws {
    for restore in [false, true] {
      let f = fixture()
      let id = try await begin(f)
      let accesses = f.board.accesses
      f.state.foreground = false
      if restore { f.clipboard.requestRestore(id) } else { f.state.current = false }
      XCTAssertThrowsError(try f.clipboard.validateForPaste(id, current: { f.state.current })) { error in
        XCTAssertEqual(error as? IOSPhoneClipboardError, .stale)
      }
      XCTAssertEqual(f.board.accesses, accesses)
      XCTAssertEqual(f.board.backgroundAccesses, 0)
      XCTAssertEqual(f.clipboard.status()["pasteMayHaveBeenDispatched"] as? Bool, false)
    }
  }
}
