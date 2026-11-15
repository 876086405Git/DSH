import Foundation
import CryptoKit
import XCTest
import UIKit
@testable import Runner

/// The real Swift owner with a recording transport and fresh synthetic keys.
/// No tunnel, DDI, device service or input is claimed to work by this fixture.
/// Pairing bytes and launch configurations never enter assertion messages.
@MainActor
final class IOSPhoneCoreDeviceTests: XCTestCase {
  @MainActor
  private final class MemoryKeychain: IOSPhonePairingKeychain {
    var value: Data?
    func contains() throws -> Bool { value != nil }
    func read() throws -> Data? { value }
    func write(_ data: Data) throws { value = data }
    func erase() throws { value = nil }
  }

  @MainActor
  private struct Launch {
    let runID: String
    let handle: UInt64
    let event: IOSPhoneCoreDevice.EventSink
    func ready() {
      event(handle, runID, 1, "{\"capabilities\":{\"screenshot\":true,\"tap\":true},\"vpnReachable\":true,\"pairingVerified\":true}")
    }
    func stopped() { event(handle, runID, 2, "{\"code\":\"OK\",\"cleanupConfirmed\":true}") }
  }

  @MainActor
  private struct Invocation {
    let handle: UInt64
    let id: UInt64
    let operation: String
    let parameters: [String: Any]
    let result: IOSPhoneCoreDevice.ResultSink
    func dispatched() {
      result(handle, id, 0,
        "{\"outcome\":\"dispatched\",\"code\":\"OK\",\"mayHaveActed\":true,\"cleanupConfirmed\":true,\"foregroundVerified\":false}", nil)
    }
  }

  @MainActor
  private final class Recorder {
    private(set) var launches: [Launch] = []
    private(set) var requests: [Invocation] = []
    private(set) var stops: [UInt64] = []
    private(set) var cancellations: [(UInt64, UInt64)] = []
    var returnedStartHandle: UInt64?
    var inspectStart: ((Data, Data) -> Void)?
    var beforeStartReturns: ((Launch) -> Void)?
    var beforeRequestReturns: ((Invocation) -> Void)?
    var beforeStopReturns: ((UInt64) -> Void)?
    var client: IOSPhoneCoreDevice.NativeClient {
      IOSPhoneCoreDevice.NativeClient(start: { [self] runID, metadata, pairing, callback in
        inspectStart?(metadata, pairing)
        let launch = Launch(runID: runID, handle: UInt64(launches.count) + 101, event: callback)
        launches.append(launch)
        beforeStartReturns?(launch)
        return (0, returnedStartHandle ?? launch.handle)
      }, request: { [self] handle, id, data, callback in
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let operation = object["op"] as? String else { return 1 }
        let call = Invocation(handle: handle, id: id, operation: operation, parameters: object, result: callback)
        requests.append(call)
        beforeRequestReturns?(call)
        return 0
      }, cancel: { [self] handle, id in cancellations.append((handle, id)) },
      stop: { [self] handle in stops.append(handle); beforeStopReturns?(handle) })
    }
    func finishFixture() {
      beforeStartReturns = nil; beforeRequestReturns = nil; beforeStopReturns = nil; inspectStart = nil
      for launch in launches { launch.stopped() }
    }
  }

  private struct Fixture {
    let owner: IOSPhoneCoreDevice
    let pairing: IOSPhonePairingStore
    let native: Recorder
    let lifecycle: Lifecycle
  }

  @MainActor
  private final class StopClock {
    var value: TimeInterval? = 1_000
    private(set) var reads = 0
    func read() -> TimeInterval? { reads += 1; return value }
  }

  @MainActor
  private final class Lifecycle {
    var active = true
    let notifications = NotificationCenter()
  }

  private func syntheticRecord() throws -> Data {
    let key = Curve25519.Signing.PrivateKey()
    return try PropertyListSerialization.data(fromPropertyList: [
      "private_key": key.rawRepresentation, "public_key": key.publicKey.rawRepresentation,
      "identifier": "synthetic-core-test-only",
    ], format: .binary, options: 0)
  }

  private func fixture(_ native: Recorder, port: @escaping () async -> UInt16 = { 49152 },
                       stopNow: @escaping () -> TimeInterval? = IOSPhoneContinuousTime.now,
                       lifecycle suppliedLifecycle: Lifecycle? = nil) throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("core-device-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let pairing = IOSPhonePairingStore(keychain: MemoryKeychain())
    try pairing.replace(syntheticRecord(), storage: .session)
    let lifecycle = suppliedLifecycle ?? Lifecycle()
    let owner = IOSPhoneCoreDevice(native: native.client, pairing: pairing,
      cache: IOSPhoneDDICache(root: directory), port: port, stopNow: stopNow,
      foreground: { lifecycle.active }, notifications: lifecycle.notifications)
    addTeardownBlock {
      await MainActor.run {
        pairing.willChange = nil; owner.stop(); native.finishFixture(); pairing.clearSession()
      }
      try? FileManager.default.removeItem(at: directory)
    }
    return Fixture(owner: owner, pairing: pairing, native: native, lifecycle: lifecycle)
  }

  private func wait(until predicate: () -> Bool) async throws {
    for _ in 0..<800 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("recording transport did not reach the expected state")
    throw CancellationError()
  }

  private func bounded<Value: Sendable>(_ task: Task<Value, Never>) async -> Value {
    let deadline = Task { @MainActor in
      do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
      XCTFail("Swift owner did not settle the synthetic call within four seconds")
      task.cancel()
    }
    defer { deadline.cancel() }
    return await task.value
  }

  private func assertFailure<Value>(_ result: Result<Value, IOSPhoneCoreFailure>, code: String,
                                    acted: Bool? = nil, file: StaticString = #filePath, line: UInt = #line) {
    switch result {
    case .success: XCTFail("expected failure without publishing a native result", file: file, line: line)
    case .failure(let failure):
      XCTAssertEqual(failure.code, code, file: file, line: line)
      if let acted { XCTAssertEqual(failure.mayHaveActed, acted, file: file, line: line) }
    }
  }

  private func readyFixture(stopNow: @escaping () -> TimeInterval? = IOSPhoneContinuousTime.now,
                            lifecycle: Lifecycle? = nil) async throws -> Fixture {
    let native = Recorder()
    native.beforeStartReturns = { $0.ready() }
    let value = try fixture(native, stopNow: stopNow, lifecycle: lifecycle)
    let result = await bounded(Task { await value.owner.prepare(ownerID: "owner-a", current: { true }) })
    XCTAssertEqual(try result.get(), ["screenshot": true, "tap": true])
    return value
  }

  func testInlineReadyBeforeStartReturnsBindsTheSameHandle() async throws {
    let value = try await readyFixture()
    XCTAssertEqual(value.native.launches.count, 1)
    XCTAssertTrue(value.owner.isReady)
    XCTAssertFalse(value.owner.maySwitchBackend)
    XCTAssertEqual(value.owner.state["phase"] as? String, "ready")
    value.owner.stop(ownerID: "unrelated-owner")
    XCTAssertTrue(value.native.stops.isEmpty, "another owner stopped the active run")
    value.owner.stop(ownerID: "owner-a")
    XCTAssertEqual(value.native.stops, [101])
    XCTAssertFalse(value.owner.maySwitchBackend)
    value.native.launches[0].stopped()
    XCTAssertTrue(value.owner.maySwitchBackend)
  }

  func testCompletionReturnUsesOnlyTheOwnedConnectionAndTheContainingApp() async throws {
    let value = try await readyFixture()
    value.native.beforeRequestReturns = { $0.dispatched() }
    let accepted = await value.owner.returnToApp(ownerID: "owner-a", current: { true })
    XCTAssertTrue(accepted)
    XCTAssertEqual(value.native.launches.count, 1)
    XCTAssertEqual(value.native.requests.count, 1)
    let call = try XCTUnwrap(value.native.requests.first)
    XCTAssertEqual(call.operation, "launch")
    XCTAssertEqual(Set(call.parameters.keys), ["op", "bundleId"])
    XCTAssertEqual(call.parameters["bundleId"] as? String, Bundle.main.bundleIdentifier)
    XCTAssertTrue(value.native.stops.isEmpty)
  }

  func testCompletionReturnDoesNotPrepareOrDispatchForAnUnownedOrRetiredTask() async throws {
    let value = try await readyFixture()
    let unowned = await value.owner.returnToApp(ownerID: "other-owner", current: { true })
    let retired = await value.owner.returnToApp(ownerID: "owner-a", current: { false })
    XCTAssertFalse(unowned)
    XCTAssertFalse(retired)
    XCTAssertTrue(value.native.requests.isEmpty)
    XCTAssertEqual(value.native.launches.count, 1)
  }

  func testCompletionReturnDoesNotRecreateAStoppedConnection() async throws {
    let value = try await readyFixture()
    value.owner.stop(ownerID: "owner-a")
    value.native.launches[0].stopped()
    let accepted = await value.owner.returnToApp(ownerID: "owner-a", current: { true })
    XCTAssertFalse(accepted)
    XCTAssertTrue(value.native.requests.isEmpty)
    XCTAssertEqual(value.native.launches.count, 1)
  }

  func testStartBorrowsSeparatePairingBytesWithoutClearingTheStoredSessionRecord() async throws {
    let native = Recorder()
    let value = try fixture(native)
    let expected = try value.pairing.load()
    var inspected = false
    native.inspectStart = { data, pairing in
      XCTAssertTrue(pairing == expected, "separate synthetic record changed")
      let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      XCTAssertEqual(Set(metadata?.keys.map { $0 } ?? []), Set([
        "runId", "host", "port", "allowDDIMount", "ddiCache",
      ]))
      inspected = true
    }
    native.beforeStartReturns = { $0.ready() }
    let result = await bounded(Task { await value.owner.prepare(ownerID: "owner-a", current: { true }) })
    XCTAssertEqual(try result.get(), ["screenshot": true, "tap": true])
    XCTAssertTrue(inspected)
    XCTAssertTrue(try value.pairing.load() == expected, "session choice must keep its record")
    XCTAssertEqual(native.launches.count, 1)
  }

  func testInlineCallbackWithDifferentReturnedHandleFaultsWithoutDispatch() async throws {
    let native = Recorder()
    native.beforeStartReturns = { $0.ready() }
    native.returnedStartHandle = 909
    let value = try fixture(native)
    let result = await bounded(Task { await value.owner.prepare(ownerID: "owner-a", current: { true }) })
    assertFailure(result, code: "ERR_PHONE_CORE_PROTOCOL")
    XCTAssertFalse(value.owner.isReady)
    XCTAssertFalse(value.owner.maySwitchBackend)
    let action = await value.owner.request(["op": "tap"], ownerID: "owner-a", current: { true })
    assertFailure(action, code: "ERR_PHONE_CORE_NOT_READY")
    XCTAssertTrue(native.requests.isEmpty)
    XCTAssertEqual(native.launches.count, 1)
  }

  func testConcurrentSameOwnerPreparationStartsOnlyOnce() async throws {
    let native = Recorder()
    let value = try fixture(native)
    let first = Task { await value.owner.prepare(ownerID: "owner-a", current: { true }) }
    let second = Task { await value.owner.prepare(ownerID: "owner-a", current: { true }) }
    defer { first.cancel(); second.cancel() }
    try await wait { native.launches.count == 1 }
    try await Task.sleep(nanoseconds: 60_000_000)
    XCTAssertEqual(native.launches.count, 1)
    native.launches[0].ready()
    let firstResult = await bounded(first)
    let secondResult = await bounded(second)
    XCTAssertEqual(try firstResult.get(), ["screenshot": true, "tap": true])
    XCTAssertEqual(try secondResult.get(), ["screenshot": true, "tap": true])
    XCTAssertEqual(native.launches.count, 1)
  }

  func testNewOwnerWaitsForCleanupAndRetiredRunCannotReplaceItsCapabilities() async throws {
    let value = try await readyFixture()
    let native = value.native
    native.beforeStartReturns = nil
    let next = Task { await value.owner.prepare(ownerID: "owner-b", current: { true }) }
    defer { next.cancel() }
    try await wait { native.stops == [101] }
    XCTAssertEqual(native.launches.count, 1)
    native.launches[0].ready()
    XCTAssertFalse(value.owner.isReady)
    XCTAssertFalse(value.owner.maySwitchBackend)
    native.launches[0].stopped()
    try await wait { native.launches.count == 2 }
    native.launches[1].ready()
    let result = await bounded(next)
    XCTAssertEqual(try result.get(), ["screenshot": true, "tap": true])
    let old = native.launches[0]
    old.event(old.handle, old.runID, 1, "{\"capabilities\":{\"tap\":false}}")
    XCTAssertTrue(value.owner.isReady)
    XCTAssertEqual(value.owner.state["capabilities"] as? [String: Bool], ["screenshot": true, "tap": true])
    XCTAssertEqual(native.launches.count, 2)
  }

  func testWrongRunIDIsIgnoredAndWrongBoundHandleStopsTheCorrectRun() async throws {
    let native = Recorder()
    let value = try fixture(native)
    let pending = Task { await value.owner.prepare(ownerID: "owner-a", current: { true }) }
    defer { pending.cancel() }
    try await wait { native.launches.count == 1 }
    let launch = native.launches[0]
    launch.event(launch.handle, UUID().uuidString.lowercased(), 1, "{\"capabilities\":{\"tap\":true}}")
    XCTAssertFalse(value.owner.isReady)
    XCTAssertTrue(native.stops.isEmpty)
    launch.event(launch.handle + 1, launch.runID, 1, "{\"capabilities\":{\"tap\":true}}")
    let result = await bounded(pending)
    assertFailure(result, code: "ERR_PHONE_CORE_PROTOCOL")
    XCTAssertEqual(native.stops, [launch.handle])
    XCTAssertFalse(value.owner.maySwitchBackend)
  }

  func testCancelledPreparationRejectsLateReadyUntilCleanupIsConfirmed() async throws {
    let native = Recorder()
    let value = try fixture(native)
    let pending = Task { await value.owner.prepare(ownerID: "owner-a", current: { true }) }
    defer { pending.cancel() }
    try await wait { native.launches.count == 1 }
    pending.cancel()
    // No await here: readiness arrives before the cancelled poll can resume.
    native.launches[0].ready()
    let result = await bounded(pending)
    assertFailure(result, code: "ERR_PHONE_CANCELLED")
    XCTAssertFalse(value.owner.isReady)
    XCTAssertEqual(native.stops, [101])
    XCTAssertFalse(value.owner.maySwitchBackend)
    native.launches[0].ready()
    XCTAssertFalse(value.owner.isReady)
    native.launches[0].stopped()
    XCTAssertTrue(value.owner.maySwitchBackend)
  }

  func testFaultedRunCannotBecomeReadyRestartOrPermitBackendFallback() async throws {
    let native = Recorder()
    let value = try fixture(native)
    let pending = Task { await value.owner.prepare(ownerID: "owner-a", current: { true }) }
    defer { pending.cancel() }
    try await wait { native.launches.count == 1 }
    let launch = native.launches[0]
    launch.event(launch.handle, launch.runID, 4,
      "{\"code\":\"ERR_PHONE_STOP_UNCONFIRMED\",\"cleanupConfirmed\":false,\"mayHaveActed\":true}")
    let result = await bounded(pending)
    assertFailure(result, code: "ERR_PHONE_STOP_UNCONFIRMED", acted: true)
    XCTAssertFalse(value.owner.maySwitchBackend)
    launch.ready()
    launch.stopped() // A retained sink must not clear an already faulted owner.
    XCTAssertFalse(value.owner.isReady)
    XCTAssertFalse(value.owner.maySwitchBackend)
    let next = await bounded(Task { await value.owner.prepare(ownerID: "owner-b", current: { true }) })
    assertFailure(next, code: "ERR_PHONE_STOP_UNCONFIRMED")
    XCTAssertEqual(native.launches.count, 1)
    XCTAssertTrue(native.requests.isEmpty)
  }

  func testSingleFlightAndStaleRequestIdentifiersCannotCompleteAnotherCall() async throws {
    let value = try await readyFixture()
    var completed = false
    let first = Task {
      let result = await value.owner.request(["op": "tap"], ownerID: "owner-a", current: { true })
      completed = true
      return result
    }
    defer { first.cancel() }
    try await wait { value.native.requests.count == 1 }
    let second = await value.owner.request(["op": "tap"], ownerID: "owner-a", current: { true })
    assertFailure(second, code: "ERR_PHONE_BUSY")
    let call = value.native.requests[0]
    let text = "{\"outcome\":\"dispatched\",\"code\":\"OK\"}"
    call.result(call.handle, call.id + 1, 0, text, nil)
    call.result(call.handle + 1, call.id, 0, text, nil)
    try await Task.sleep(nanoseconds: 35_000_000)
    XCTAssertFalse(completed)
    XCTAssertEqual(value.native.requests.count, 1)
    call.dispatched()
    let firstResult = await bounded(first)
    XCTAssertEqual(try firstResult.get().metadata.outcome, "dispatched")
    call.dispatched() // Duplicate completion is inert.
    XCTAssertTrue(value.owner.isReady)
    XCTAssertEqual(value.native.requests.count, 1)
  }

  func testStopThenInlineResultCannotPublishSuccess() async throws {
    let value = try await readyFixture()
    let owner = value.owner
    value.native.beforeRequestReturns = { [weak owner] call in
      owner?.stop(ownerID: "owner-a")
      call.dispatched()
    }
    let result = await bounded(Task { await owner.request(["op": "tap"], ownerID: "owner-a", current: { true }) })
    assertFailure(result, code: "ERR_PHONE_ACTION_UNCONFIRMED", acted: true)
    XCTAssertFalse(owner.isReady)
    XCTAssertFalse(owner.maySwitchBackend)
    XCTAssertEqual(value.native.requests.count, 1)
    XCTAssertEqual(value.native.stops, [101])
  }

  func testCallerInvalidationBeforeInlineResultCannotPublishSuccess() async throws {
    let value = try await readyFixture()
    var current = true
    value.native.beforeRequestReturns = { call in current = false; call.dispatched() }
    let result = await bounded(Task {
      await value.owner.request(["op": "tap"], ownerID: "owner-a", current: { current })
    })
    assertFailure(result, code: "ERR_PHONE_ACTION_UNCONFIRMED", acted: true)
    XCTAssertEqual(value.native.requests.count, 1)
    XCTAssertEqual(value.native.cancellations.count, 1)
    XCTAssertEqual(value.native.cancellations.first?.0, 101)
    XCTAssertEqual(value.native.cancellations.first?.1, 1)
    XCTAssertFalse(value.owner.maySwitchBackend)
  }

  func testPairingGenerationChangeBeforeInlineResultCannotPublishSuccess() async throws {
    let value = try await readyFixture()
    let replacement = try syntheticRecord()
    let previous = value.pairing.generation
    value.native.beforeRequestReturns = { [weak pairing = value.pairing] call in
      do { try pairing?.replace(replacement, storage: .session) }
      catch { XCTFail("synthetic pairing replacement unexpectedly failed") }
      call.dispatched()
    }
    let result = await bounded(Task { await value.owner.request(["op": "tap"], ownerID: "owner-a", current: { true }) })
    XCTAssertNotEqual(value.pairing.generation, previous)
    assertFailure(result, code: "ERR_PHONE_ACTION_UNCONFIRMED", acted: true)
    XCTAssertEqual(value.native.requests.count, 1)
    XCTAssertEqual(value.native.launches.count, 1, "uncertain input was replayed on a new owner")
    XCTAssertFalse(value.owner.maySwitchBackend)
  }

  func testTaskCancellationWinsOverResultBeforeThePollResumes() async throws {
    let value = try await readyFixture()
    let pending = Task { await value.owner.request(["op": "tap"], ownerID: "owner-a", current: { true }) }
    defer { pending.cancel() }
    try await wait { value.native.requests.count == 1 }
    pending.cancel()
    value.native.requests[0].dispatched()
    let result = await bounded(pending)
    assertFailure(result, code: "ERR_PHONE_ACTION_UNCONFIRMED", acted: true)
    XCTAssertEqual(value.native.requests.count, 1)
    XCTAssertFalse(value.owner.isReady)
    XCTAssertFalse(value.owner.maySwitchBackend)
  }

  func testChangedPairingGenerationRejectsNewRequestBeforeNativeDispatch() async throws {
    let value = try await readyFixture()
    try value.pairing.replace(syntheticRecord(), storage: .session)
    let result = await value.owner.request(["op": "tap"], ownerID: "owner-a", current: { true })
    assertFailure(result, code: "ERR_PHONE_CORE_NOT_READY")
    XCTAssertTrue(value.native.requests.isEmpty)
  }

  func testDispatchedInputIsNotRewrittenAsCompletedOrForegroundVerified() async throws {
    let value = try await readyFixture()
    value.native.beforeRequestReturns = { $0.dispatched() }
    let result = await bounded(Task { await value.owner.request(["op": "tap"], ownerID: "owner-a", current: { true }) })
    let reply = try result.get()
    XCTAssertEqual(reply.status, 0)
    XCTAssertEqual(reply.metadata.outcome, "dispatched")
    XCTAssertEqual(reply.metadata.mayHaveActed, true)
    XCTAssertEqual(reply.metadata.foregroundVerified, false)
    XCTAssertTrue(reply.bytes == nil)
    XCTAssertEqual(value.native.requests.count, 1)
  }

  func testUnrecognizedCompletedOutcomeRetiresOwnerWithoutRetry() async throws {
    let value = try await readyFixture()
    value.native.beforeRequestReturns = { call in
      call.result(call.handle, call.id, 0, "{\"outcome\":\"completed\",\"code\":\"OK\"}", nil)
    }
    let result = await bounded(Task { await value.owner.request(["op": "tap"], ownerID: "owner-a", current: { true }) })
    // Protocol failure retires the owner; delivery's cancellation fence then
    // returns the conservative unconfirmed outcome rather than any success.
    assertFailure(result, code: "ERR_PHONE_ACTION_UNCONFIRMED", acted: true)
    XCTAssertEqual(value.native.requests.count, 1)
    XCTAssertEqual(value.native.stops, [101])
    XCTAssertFalse(value.owner.maySwitchBackend)
  }

  func testCancelledReadNeverClaimsThatInputMayHaveActed() async throws {
    let value = try await readyFixture()
    var current = true
    value.native.beforeRequestReturns = { call in
      current = false
      call.result(call.handle, call.id, 0, "{\"outcome\":\"read\",\"code\":\"OK\"}", Data([1, 2, 3]))
    }
    let result = await bounded(Task {
      await value.owner.request(["op": "screenshot"], ownerID: "owner-a", current: { current })
    })
    assertFailure(result, code: "ERR_PHONE_ACTION_UNCONFIRMED", acted: false)
    XCTAssertEqual(value.native.requests.count, 1)
  }

  func testPortResolutionFinishingAfterCancellationNeverStartsNative() async throws {
    let native = Recorder()
    var resolution: CheckedContinuation<UInt16, Never>?
    let value = try fixture(native, port: { await withCheckedContinuation { resolution = $0 } })
    let pending = Task { await value.owner.prepare(ownerID: "owner-a", current: { true }) }
    defer { pending.cancel(); resolution?.resume(returning: 0) }
    try await wait { resolution != nil }
    pending.cancel()
    let result = await bounded(pending)
    assertFailure(result, code: "ERR_PHONE_CANCELLED")
    resolution?.resume(returning: 49152)
    resolution = nil
    try await Task.sleep(nanoseconds: 60_000_000)
    XCTAssertTrue(native.launches.isEmpty)
    XCTAssertTrue(value.owner.maySwitchBackend)
  }

  func testStopUsesFortyFiveActiveSecondsWithoutAnotherCall() async throws {
    let clock = StopClock()
    let value = try await readyFixture(stopNow: { clock.read() })
    var phases: [String] = []
    value.owner.onStateChanged = { [weak owner = value.owner] in
      if let phase = owner?.state["phase"] as? String { phases.append(phase) }
    }
    value.owner.stop(ownerID: "owner-a")
    clock.value = 1_044.999
    try await wait { clock.reads >= 2 }
    XCTAssertEqual(value.owner.state["phase"] as? String, "stopping")
    XCTAssertEqual(phases, ["stopping"])
    clock.value = 1_045
    try await wait { value.owner.isFaulted }
    XCTAssertEqual(phases, ["stopping", "faulted"])
    XCTAssertEqual(value.owner.state["code"] as? String, "ERR_PHONE_STOP_UNCONFIRMED")
    XCTAssertFalse(value.owner.isReady)
    XCTAssertFalse(value.owner.maySwitchBackend)
    XCTAssertEqual(value.native.stops, [101])
  }

  func testLifecyclePauseExcludesSleepAndResumesTheRemainingBudget() async throws {
    let clock = StopClock()
    let value = try await readyFixture(stopNow: { clock.read() })
    let lifecycle = value.lifecycle
    value.owner.stop(ownerID: "owner-a")
    clock.value = 1_010
    // The notification itself must pause accounting, even while the injected
    // applicationState query still says active during willResignActive.
    lifecycle.notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
    let pausedReads = clock.reads
    clock.value = 1_000_000
    try await Task.sleep(nanoseconds: 250_000_000)
    XCTAssertEqual(clock.reads, pausedReads)
    XCTAssertEqual(value.owner.state["phase"] as? String, "stopping")
    lifecycle.active = false
    lifecycle.notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    lifecycle.notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
    clock.value = nil
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(clock.reads, pausedReads, "background time and unavailable samples are not charged")
    XCTAssertFalse(value.owner.isFaulted)
    lifecycle.active = true
    clock.value = 2_000
    lifecycle.notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    let resumedReads = clock.reads
    clock.value = 2_034.999
    try await wait { clock.reads > resumedReads }
    XCTAssertEqual(value.owner.state["phase"] as? String, "stopping")
    clock.value = 2_035
    // A duplicate active notification must not throw away the last interval.
    lifecycle.notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    try await wait { value.owner.isFaulted }
    XCTAssertFalse(value.owner.maySwitchBackend)
    XCTAssertEqual(value.native.stops, [101])
  }

  func testStopStartedInactiveDoesNotReadClockUntilResume() async throws {
    let clock = StopClock()
    let lifecycle = Lifecycle()
    let value = try await readyFixture(stopNow: { clock.read() }, lifecycle: lifecycle)
    lifecycle.notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
    lifecycle.active = false
    clock.value = nil
    value.owner.stop(ownerID: "owner-a")
    try await Task.sleep(nanoseconds: 250_000_000)
    XCTAssertEqual(clock.reads, 0)
    XCTAssertEqual(value.owner.state["phase"] as? String, "stopping")
    clock.value = 5_000
    lifecycle.active = true
    lifecycle.notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    clock.value = 5_045
    try await wait { value.owner.isFaulted }
    XCTAssertFalse(value.owner.maySwitchBackend)
  }

  func testLateConfirmedKindTwoOrThreeReleasesOnlyTheTimedOutOwner() async throws {
    for kind in [Int32(2), Int32(3)] {
      let clock = StopClock()
      let value = try await readyFixture(stopNow: { clock.read() })
      let first = value.native.launches[0]
      value.owner.stop(ownerID: "owner-a")
      clock.value = 1_045
      try await wait { value.owner.isFaulted }
      first.ready()
      first.event(first.handle + 1, first.runID, kind, "{\"cleanupConfirmed\":true}")
      first.event(first.handle, UUID().uuidString.lowercased(), kind, "{\"cleanupConfirmed\":true}")
      first.event(first.handle, first.runID, kind, "{\"cleanupConfirmed\":false}")
      first.event(first.handle, first.runID, kind, "{}")
      XCTAssertTrue(value.owner.isFaulted)
      XCTAssertFalse(value.owner.isReady)
      XCTAssertFalse(value.owner.maySwitchBackend)
      XCTAssertEqual(value.native.launches.count, 1)
      first.event(first.handle, first.runID, kind,
        "{\"code\":\"ERR_PHONE_CANCELLED\",\"cleanupConfirmed\":true}")
      XCTAssertFalse(value.owner.isFaulted)
      XCTAssertFalse(value.owner.isReady, "a terminal ACK is not new readiness")
      XCTAssertTrue(value.owner.maySwitchBackend)
      XCTAssertEqual(value.owner.state["phase"] as? String, kind == 2 ? "idle" : "failed")
      XCTAssertEqual(value.native.launches.count, 1, "cleanup must not automatically restart")
      if kind == 3 { XCTAssertEqual(value.owner.state["code"] as? String, "ERR_PHONE_CANCELLED") }
      let next = await bounded(Task { await value.owner.prepare(ownerID: "owner-b", current: { true }) })
      XCTAssertEqual(try next.get(), ["screenshot": true, "tap": true])
      let nextID = value.owner.currentRunID(ownerID: "owner-b")
      first.ready()
      first.stopped()
      XCTAssertTrue(value.owner.isReady)
      XCTAssertEqual(value.owner.currentRunID(ownerID: "owner-b"), nextID)
      XCTAssertEqual(value.native.launches.count, 2)
    }
  }

  func testValidTerminalAtDeadlineWinsBeforeDelayedWatchdogTick() async throws {
    for kind in [Int32(2), Int32(3)] {
      let clock = StopClock()
      let value = try await readyFixture(stopNow: { clock.read() })
      var phases: [String] = []
      value.owner.onStateChanged = { [weak owner = value.owner] in
        if let phase = owner?.state["phase"] as? String { phases.append(phase) }
      }
      value.owner.stop(ownerID: "owner-a")
      clock.value = 1_045
      // No await: the watcher has not had a turn at the boundary.
      let first = value.native.launches[0]
      first.event(first.handle, first.runID, kind, "{\"cleanupConfirmed\":true}")
      XCTAssertTrue(value.owner.maySwitchBackend)
      XCTAssertFalse(value.owner.isFaulted)
      XCTAssertFalse(phases.contains("faulted"))
    }
  }

  func testNativeKindFourPermanentlyUpgradesATimeoutFault() async throws {
    for confirmed in [false, true] {
      let clock = StopClock()
      let value = try await readyFixture(stopNow: { clock.read() })
      value.owner.stop(ownerID: "owner-a")
      clock.value = 1_045
      try await wait { value.owner.isFaulted }
      let first = value.native.launches[0]
      let text = "{\"code\":\"ERR_PHONE_STOP_UNCONFIRMED\",\"cleanupConfirmed\":\(confirmed)}"
      first.event(first.handle, first.runID, 4, text)
      first.stopped()
      first.event(first.handle, first.runID, 3, "{\"cleanupConfirmed\":true}")
      first.ready()
      XCTAssertTrue(value.owner.isFaulted)
      XCTAssertFalse(value.owner.maySwitchBackend)
      XCTAssertFalse(value.owner.isReady)
      let next = await bounded(Task { await value.owner.prepare(ownerID: "owner-b", current: { true }) })
      assertFailure(next, code: "ERR_PHONE_STOP_UNCONFIRMED")
      XCTAssertEqual(value.native.launches.count, 1)
      XCTAssertTrue(value.native.requests.isEmpty)
    }
  }

  func testRepeatedStopAndWaitingPrepareDoNotRenewTheBudget() async throws {
    let clock = StopClock()
    let value = try await readyFixture(stopNow: { clock.read() })
    value.owner.stop(ownerID: "owner-a")
    clock.value = 1_030
    value.owner.stop(ownerID: "owner-a")
    let next = Task { await value.owner.prepare(ownerID: "owner-b", current: { true }) }
    defer { next.cancel() }
    try await wait { clock.reads >= 2 }
    clock.value = 1_045
    let result = await bounded(next)
    assertFailure(result, code: "ERR_PHONE_STOP_UNCONFIRMED")
    XCTAssertEqual(value.native.stops, [101])
    XCTAssertEqual(value.native.launches.count, 1)
    XCTAssertFalse(value.owner.maySwitchBackend)
  }

  func testInvalidActiveClockFaultsButStillAcceptsConfirmedCleanup() async throws {
    let readings: [TimeInterval?] = [nil, Double.nan, Double.infinity, -Double.infinity, -1]
    for reading in readings {
      let value = try await readyFixture(stopNow: { reading })
      value.owner.stop(ownerID: "owner-a")
      XCTAssertEqual(value.native.stops, [101])
      XCTAssertTrue(value.owner.isFaulted)
      XCTAssertFalse(value.owner.maySwitchBackend)
      value.native.launches[0].ready()
      XCTAssertFalse(value.owner.isReady)
      value.native.launches[0].stopped()
      XCTAssertFalse(value.owner.isFaulted)
      XCTAssertTrue(value.owner.maySwitchBackend)
    }
  }

  func testBackwardsClockInActiveSegmentOrAtResumeCannotReleaseBarrier() async throws {
    for atResume in [false, true] {
      let clock = StopClock()
      let value = try await readyFixture(stopNow: { clock.read() })
      value.owner.stop(ownerID: "owner-a")
      clock.value = 1_010
      try await wait { clock.reads >= 2 }
      if atResume {
        value.lifecycle.notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
        value.lifecycle.active = false
        value.lifecycle.notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
      }
      clock.value = 1_009
      if atResume {
        value.lifecycle.active = true
        value.lifecycle.notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
      }
      try await wait { value.owner.isFaulted }
      XCTAssertFalse(value.owner.maySwitchBackend)
      XCTAssertEqual(value.native.stops, [101])
    }
  }

  func testConfirmedStopCancelsOldWatcherBeforeANewRun() async throws {
    let clock = StopClock()
    let value = try await readyFixture(stopNow: { clock.read() })
    let first = value.native.launches[0]
    value.owner.stop(ownerID: "owner-a")
    clock.value = 1_005
    first.stopped()
    let second = await bounded(Task { await value.owner.prepare(ownerID: "owner-b", current: { true }) })
    XCTAssertEqual(try second.get(), ["screenshot": true, "tap": true])
    let nextID = value.owner.currentRunID(ownerID: "owner-b")
    clock.value = 50_000
    first.ready()
    first.stopped()
    value.lifecycle.notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
    value.lifecycle.active = false
    value.lifecycle.notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    value.lifecycle.active = true
    value.lifecycle.notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    try await Task.sleep(nanoseconds: 250_000_000)
    XCTAssertTrue(value.owner.isReady)
    XCTAssertEqual(value.owner.currentRunID(ownerID: "owner-b"), nextID)
    XCTAssertEqual(value.native.stops, [101])
  }

  func testTimeoutAndLateCleanupNeverReviveAnOldRequest() async throws {
    let clock = StopClock()
    let value = try await readyFixture(stopNow: { clock.read() })
    let request = Task { await value.owner.request(["op": "tap"], ownerID: "owner-a", current: { true }) }
    defer { request.cancel() }
    try await wait { value.native.requests.count == 1 }
    let oldRequest = value.native.requests[0]
    let oldRun = value.native.launches[0]
    value.owner.stop(ownerID: "owner-a")
    clock.value = 1_045
    try await wait { value.owner.isFaulted }
    oldRequest.dispatched()
    let result = await bounded(request)
    assertFailure(result, code: "ERR_PHONE_ACTION_UNCONFIRMED", acted: true)
    oldRun.stopped()
    XCTAssertTrue(value.owner.maySwitchBackend)
    XCTAssertFalse(value.owner.isReady)
    XCTAssertEqual(value.native.requests.count, 1, "cleanup must not replay the input")
    let next = await bounded(Task { await value.owner.prepare(ownerID: "owner-b", current: { true }) })
    XCTAssertEqual(try next.get(), ["screenshot": true, "tap": true])
    oldRequest.dispatched()
    XCTAssertEqual(value.native.requests.count, 1)
    XCTAssertEqual(value.native.launches.count, 2)
  }

  func testInlineCleanupAndReentrantStopDoNotArmAnotherWatcher() async throws {
    let clock = StopClock()
    let value = try await readyFixture(stopNow: { clock.read() })
    let first = value.native.launches[0]
    value.native.beforeStopReturns = { _ in first.stopped() }
    value.owner.onStateChanged = { [weak owner = value.owner] in
      if owner?.state["phase"] as? String == "stopping" { owner?.stop(ownerID: "owner-a") }
    }
    value.owner.stop(ownerID: "owner-a")
    XCTAssertTrue(value.owner.maySwitchBackend)
    XCTAssertFalse(value.owner.isFaulted)
    let reads = clock.reads
    clock.value = 50_000
    try await Task.sleep(nanoseconds: 250_000_000)
    XCTAssertEqual(clock.reads, reads)
    XCTAssertEqual(value.native.stops, [101])
    XCTAssertEqual(value.owner.state["phase"] as? String, "idle")
  }

  func testRunnerRejectsAnExistingNativeFaultWithoutItsRouteWait() async throws {
    let value = try await readyFixture()
    let first = value.native.launches[0]
    first.event(first.handle, first.runID, 4,
      "{\"code\":\"ERR_PHONE_STOP_UNCONFIRMED\",\"cleanupConfirmed\":false}")
    // The four-second harness bound would fail if the production function
    // spent its twelve-second transition wait on an already faulted owner.
    let result = await bounded(Task {
      await IOSPhoneRunner.stopCoreForXCTest(value.owner, ownerID: "owner-a", current: { true })
    })
    assertFailure(result, code: "ERR_PHONE_STOP_UNCONFIRMED")
    XCTAssertTrue(value.native.stops.isEmpty)
    XCTAssertEqual(value.native.launches.count, 1)
    XCTAssertTrue(IOSPhoneRunner.coreStopUnconfirmed.contains("彻底关闭 DSH Go"))
    XCTAssertTrue(IOSPhoneRunner.coreStopUnconfirmed.contains("不要自动重试"))
  }

  func testRunnerStopsWaitingAsSoonAsLocalOrNativeFaultAppears() async throws {
    for nativeFault in [false, true] {
      let clock = StopClock()
      let value = try await readyFixture(stopNow: { clock.read() })
      let task = Task {
        await IOSPhoneRunner.stopCoreForXCTest(value.owner, ownerID: "owner-a", current: { true })
      }
      defer { task.cancel() }
      try await wait { value.native.stops == [101] }
      if nativeFault {
        let first = value.native.launches[0]
        first.event(first.handle, first.runID, 4,
          "{\"code\":\"ERR_PHONE_STOP_UNCONFIRMED\",\"cleanupConfirmed\":false}")
      } else {
        clock.value = 1_045
      }
      let result = await bounded(task)
      assertFailure(result, code: "ERR_PHONE_STOP_UNCONFIRMED")
      XCTAssertFalse(value.owner.maySwitchBackend)
      XCTAssertEqual(value.native.launches.count, 1)
      XCTAssertTrue(value.native.requests.isEmpty)
    }
  }

  func testInlineConfirmedCleanupWinsOverAnInvalidInitialClock() async throws {
    let readings: [TimeInterval?] = [nil, Double.nan]
    for reading in readings {
      let value = try await readyFixture(stopNow: { reading })
      let first = value.native.launches[0]
      var phases: [String] = []
      value.owner.onStateChanged = { [weak owner = value.owner] in
        if let phase = owner?.state["phase"] as? String { phases.append(phase) }
      }
      value.native.beforeStopReturns = { _ in first.stopped() }
      value.owner.stop(ownerID: "owner-a")
      XCTAssertEqual(phases, ["stopping", "idle"])
      XCTAssertFalse(value.owner.isFaulted)
      XCTAssertTrue(value.owner.maySwitchBackend)
      XCTAssertEqual(value.native.stops, [101])
    }
  }

  func testSynchronousStateNotificationPausesBeforeNativeStop() async throws {
    let clock = StopClock()
    clock.value = nil
    let value = try await readyFixture(stopNow: { clock.read() })
    let notifications = value.lifecycle.notifications
    value.owner.onStateChanged = { [weak owner = value.owner] in
      if owner?.state["phase"] as? String == "stopping" {
        notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
      }
    }
    value.owner.stop(ownerID: "owner-a")
    XCTAssertEqual(value.native.stops, [101])
    XCTAssertEqual(clock.reads, 0)
    XCTAssertFalse(value.owner.isFaulted)
    XCTAssertEqual(value.owner.state["phase"] as? String, "stopping")
    // An ACK is accepted while inactive without consulting a broken clock.
    value.native.launches[0].stopped()
    XCTAssertTrue(value.owner.maySwitchBackend)
    XCTAssertEqual(value.owner.state["phase"] as? String, "idle")
  }
}
