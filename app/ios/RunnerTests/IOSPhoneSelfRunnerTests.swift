import Foundation
import CryptoKit
import XCTest
@testable import Runner

/// Exercises the actual Swift owner with a recording native transport. No DDI,
/// XCTest service or phone action is simulated as having succeeded by these tests.
@MainActor
final class IOSPhoneSelfRunnerTests: XCTestCase {
  private struct Config: Decodable {
    let runId: String
    let publicKeyBase64: String
    let host: String
    let port: UInt16
    let runnerBundleId: String
  }

  @MainActor
  private final class Recorder {
    var configurations: [Config] = []
    var rawConfigurations: [[String: Any]] = []
    var callbacks: [IOSPhoneSelfRunner.EventSink] = []
    var stops: [UInt64] = []
    var rejectStart = false
    var inspectStart: ((Data, Data?) -> Void)?

    var client: IOSPhoneSelfRunner.NativeClient {
      IOSPhoneSelfRunner.NativeClient(start: { [self] _, data, pairing, callback in
        inspectStart?(data, pairing)
        guard let config = try? JSONDecoder().decode(Config.self, from: data),
          let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        configurations.append(config)
        rawConfigurations.append(dictionary)
        callbacks.append(callback)
        return rejectStart ? 0 : UInt64(configurations.count)
      }, stop: { [self] in stops.append($0) })
    }

    func ready(_ index: Int = 0) throws -> PhoneRunnerEndpoint {
      let config = configurations[index]
      let endpoint = PhoneRunnerEndpoint(port: 32100 + index, token: String(repeating: "a", count: 64), runId: config.runId)
      let encrypted = try PhoneRunnerHandshake.seal(endpoint, publicKeyBase64: config.publicKeyBase64)
      callbacks[index](config.runId, 1, encrypted)
      return endpoint
    }

    func stopped(_ index: Int = 0) {
      callbacks[index](configurations[index].runId, 2, "")
    }
  }

  private func fixture(recorder: Recorder, timeout: TimeInterval = 5,
                       resolvePort: @escaping () async -> UInt16 = { 49152 },
                       configuredPort: UInt16? = 49152,
                       now: @escaping () -> Date = Date.init,
                       pairingData: (() throws -> Data)? = nil,
                       pairingAvailable: (() -> Bool)? = nil) throws -> IOSPhoneSelfRunner {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("self-runner-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let pairing = directory.appendingPathComponent("pairingFile.plist")
    try Data("test-only-placeholder".utf8).write(to: pairing)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return IOSPhoneSelfRunner(native: recorder.client, pairingURL: pairing,
      runnerBundleId: "test.dsh.PhoneRunner.xctrunner", targetBundleId: "test.dsh",
      configuredPort: configuredPort, startupTimeout: timeout, stopTimeout: 5, resolvePort: resolvePort, now: now,
      pairingData: pairingData, pairingAvailable: pairingAvailable)
  }

  private func wait(until predicate: () -> Bool) async throws {
    for _ in 0..<2000 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("owner did not reach the expected state")
    throw CancellationError()
  }

  func testReadyUsesRealEncryptedHandshakeAndOnlyPublicLaunchConfiguration() async throws {
    let native = Recorder()
    let owner = try fixture(recorder: native)
    let pending = Task { await owner.prepare(current: { true }) }
    try await wait { native.configurations.count == 1 }
    let ready = try native.ready()
    let result = await pending.value
    XCTAssertEqual(try result.get(), ready)
    XCTAssertTrue(owner.owns(ready))
    XCTAssertEqual(native.configurations[0].host, "10.7.0.1")
    XCTAssertEqual(native.configurations[0].port, 49152)
    XCTAssertEqual(native.configurations[0].runnerBundleId, "test.dsh.PhoneRunner.xctrunner")
    XCTAssertEqual(Set(native.rawConfigurations[0].keys), Set([
      "runId", "pairingFile", "host", "port", "runnerBundleId", "targetBundleId", "publicKeyBase64",
    ]))
    owner.stop()
    XCTAssertFalse(owner.owns(ready))
    XCTAssertEqual(native.stops, [1])
    native.stopped()
    XCTAssertTrue(owner.mayUseMacFallback)
  }

  func testMemoryStartupBorrowsSeparateBytesAndStatusDoesNotLoadTheRecord() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let record = try PropertyListSerialization.data(fromPropertyList: [
      "private_key": key.rawRepresentation, "public_key": key.publicKey.rawRepresentation,
      "identifier": "synthetic-byte-abi-only",
    ], format: .binary, options: 0)
    let native = Recorder()
    native.rejectStart = true
    var inspected = false
    native.inspectStart = { data, pairing in
      // Only fresh synthetic bytes are compared; no credential bytes are used
      // as assertion messages or copied into recorded launch metadata.
      XCTAssertTrue(pairing == record, "separate byte input changed")
      let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      XCTAssertEqual(Set(metadata?.keys.map { $0 } ?? []), Set([
        "runId", "host", "port", "runnerBundleId", "targetBundleId", "publicKeyBase64",
      ]))
      inspected = true
    }
    var loads = 0
    var available = true
    let owner = try fixture(recorder: native,
      pairingData: { loads += 1; return record }, pairingAvailable: { available })
    for _ in 0..<8 { XCTAssertTrue(owner.isConfigured) }
    XCTAssertEqual(loads, 0)
    available = false
    XCTAssertFalse(owner.isConfigured)
    XCTAssertEqual(loads, 0)
    available = true
    let result = await owner.prepare(current: { true })
    if case .failure(.failed) = result {} else { XCTFail("recording rejection was ignored") }
    XCTAssertTrue(inspected)
    XCTAssertEqual(loads, 1)
    XCTAssertEqual(native.configurations.count, 1)
    XCTAssertTrue(owner.isConfigured)
    XCTAssertEqual(loads, 1)
  }

  func testMemoryStartupRejectsEmptyOrOversizedBytesBeforeNativeAdmission() async throws {
    for count in [0, IOSPhonePairingRecord.maximumBytes + 1] {
      let native = Recorder()
      let owner = try fixture(recorder: native,
        pairingData: { Data(repeating: 0, count: count) }, pairingAvailable: { true })
      let result = await owner.prepare(current: { true })
      if case .failure(.setup) = result {} else { XCTFail("invalid byte input reached native admission") }
      XCTAssertTrue(native.configurations.isEmpty)
      XCTAssertTrue(native.stops.isEmpty)
    }
  }

  func testUnavailableMemoryRecordNeverLoadsPrivateBytes() async throws {
    let native = Recorder()
    var loads = 0
    let owner = try fixture(recorder: native,
      pairingData: { loads += 1; throw IOSPhonePairingError.missing }, pairingAvailable: { false })
    let result = await owner.prepare(current: { true })
    if case .failure(.setup) = result {} else { XCTFail("unavailable record started preparation") }
    XCTAssertEqual(loads, 0)
    XCTAssertTrue(native.configurations.isEmpty)
  }

  func testPresentButUnreadableRecordFailsSetupWithoutNativeAdmission() async throws {
    let native = Recorder()
    var loads = 0
    let owner = try fixture(recorder: native,
      pairingData: { loads += 1; throw IOSPhonePairingError.missing }, pairingAvailable: { true })
    XCTAssertTrue(owner.isConfigured)
    XCTAssertEqual(loads, 0)
    let result = await owner.prepare(current: { true })
    if case .failure(.setup) = result {} else { XCTFail("record presence was mistaken for readable pairing") }
    XCTAssertEqual(loads, 1)
    XCTAssertTrue(native.configurations.isEmpty)
    XCTAssertTrue(native.callbacks.isEmpty)
    XCTAssertTrue(native.stops.isEmpty)
    XCTAssertTrue(owner.isConfigured)
    XCTAssertEqual(loads, 1, "later status must not reread the record")
  }

  func testConcurrentWaitersShareStartupAndOneCancellationDoesNotStopTheOther() async throws {
    let native = Recorder()
    let owner = try fixture(recorder: native)
    let first = Task { await owner.prepare(current: { true }) }
    let second = Task { await owner.prepare(current: { true }) }
    try await wait { native.configurations.count == 1 }
    try await Task.sleep(nanoseconds: 80_000_000)
    first.cancel()
    if case .failure(.cancelled) = await first.value {} else { XCTFail("cancelled caller unexpectedly became ready") }
    XCTAssertTrue(native.stops.isEmpty)
    let ready = try native.ready()
    let secondResult = await second.value
    XCTAssertEqual(try secondResult.get(), ready)
    XCTAssertEqual(native.configurations.count, 1)
    owner.stop()
    native.stopped()
  }

  func testCancelledStartupRejectsLateReadyAndWaitsForNativeStopBeforeRestart() async throws {
    let native = Recorder()
    let owner = try fixture(recorder: native)
    let pending = Task { await owner.prepare(current: { true }) }
    try await wait { native.configurations.count == 1 }
    pending.cancel()
    // Ready can arrive before the cancelled waiter's defer executes.
    let late = try native.ready()
    if case .failure(.cancelled) = await pending.value {} else { XCTFail("cancelled startup unexpectedly succeeded") }
    XCTAssertEqual(native.stops, [1])
    XCTAssertFalse(owner.mayUseMacFallback)
    XCTAssertFalse(owner.owns(late))
    _ = try native.ready()
    let next = Task { await owner.prepare(current: { true }) }
    try await Task.sleep(nanoseconds: 75_000_000)
    XCTAssertEqual(native.configurations.count, 1)
    native.stopped()
    try await wait { native.configurations.count == 2 }
    let ready = try native.ready(1)
    let nextResult = await next.value
    XCTAssertEqual(try nextResult.get(), ready)
    // A replay from the retired native session cannot replace the current endpoint.
    _ = try native.ready(0)
    XCTAssertTrue(owner.owns(ready))
    owner.stop()
    native.stopped(1)
  }

  func testInvalidReadinessStopsNativeRatherThanPublishingAnEndpoint() async throws {
    let native = Recorder()
    let owner = try fixture(recorder: native)
    let pending = Task { await owner.prepare(current: { true }) }
    try await wait { native.configurations.count == 1 }
    native.callbacks[0](native.configurations[0].runId, 1, "not-a-ciphertext")
    if case .failure(.invalidHandshake) = await pending.value {} else { XCTFail("invalid readiness was accepted") }
    XCTAssertEqual(native.stops, [1])
    XCTAssertFalse(owner.mayUseMacFallback)
    native.stopped()
  }

  func testExpiredCallerNeverStartsNative() async throws {
    let native = Recorder()
    let owner = try fixture(recorder: native)
    let result = await owner.prepare(current: { false })
    if case .failure(.cancelled) = result {} else { XCTFail("expired owner unexpectedly started") }
    XCTAssertTrue(native.configurations.isEmpty)
  }

  func testPortResolutionCompletingAfterTimeoutCannotStartNative() async throws {
    let native = Recorder()
    var resolution: CheckedContinuation<UInt16, Never>?
    var instant = Date()
    let owner = try fixture(recorder: native, timeout: 5,
      resolvePort: { await withCheckedContinuation { resolution = $0 } }, configuredPort: nil, now: { instant })
    let pending = Task { await owner.prepare(current: { true }) }
    try await wait { resolution != nil }
    instant = instant.addingTimeInterval(10)
    let result = await pending.value
    if case .failure(.timedOut) = result {} else { XCTFail("startup deadline was ignored") }
    resolution?.resume(returning: 49152)
    resolution = nil
    try await Task.sleep(nanoseconds: 60_000_000)
    XCTAssertTrue(native.configurations.isEmpty)
    XCTAssertTrue(owner.mayUseMacFallback)
  }

  func testNativeTimeoutRequestsStopAndUnconfirmedStopPreventsAnotherStart() async throws {
    let native = Recorder()
    var instant = Date()
    let owner = try fixture(recorder: native, now: { instant })
    let pending = Task { await owner.prepare(current: { true }) }
    try await wait { native.configurations.count == 1 }
    instant = instant.addingTimeInterval(6)
    if case .failure(.timedOut) = await pending.value {} else { XCTFail("native startup ignored its deadline") }
    XCTAssertEqual(native.stops, [1])
    instant = instant.addingTimeInterval(6)
    let rejected = await owner.prepare(current: { true })
    if case .failure(.stopping) = rejected {} else { XCTFail("unconfirmed native stop allowed a new session") }
    XCTAssertEqual(native.configurations.count, 1)
    XCTAssertFalse(owner.mayUseMacFallback)
    native.stopped()
    XCTAssertTrue(owner.mayUseMacFallback)
  }

  func testUnconfirmedNativeCleanupPoisonsTheOwnerUntilAppRestart() async throws {
    let native = Recorder()
    let owner = try fixture(recorder: native)
    let pending = Task { await owner.prepare(current: { true }) }
    try await wait { native.configurations.count == 1 }
    native.callbacks[0](native.configurations[0].runId, 4, "")
    if case .failure(.faulted) = await pending.value {} else { XCTFail("unconfirmed native cleanup was treated as terminal") }
    let next = await owner.prepare(current: { true })
    if case .failure(.faulted) = next {} else { XCTFail("poisoned owner started another session") }
    XCTAssertEqual(native.configurations.count, 1)
    XCTAssertTrue(native.stops.isEmpty)
    XCTAssertFalse(owner.mayUseMacFallback)
    owner.stop()
    XCTAssertFalse(owner.mayUseMacFallback)
  }

  func testRetiredOwnerCannotStopOrCancelItsReplacement() async throws {
    let native = Recorder()
    let owner = try fixture(recorder: native)
    let first = Task { await owner.prepare(ownerID: "old", current: { true }) }
    try await wait { native.configurations.count == 1 }
    _ = try native.ready()
    _ = try await first.value.get()
    let replacement = Task { await owner.prepare(ownerID: "new", current: { true }) }
    try await wait { native.stops == [1] }
    XCTAssertEqual(native.configurations.count, 1)
    native.stopped()
    try await wait { native.configurations.count == 2 }
    owner.cancelPreparation(ownerID: "old")
    XCTAssertEqual(native.stops, [1])
    let ready = try native.ready(1)
    let result = await replacement.value
    XCTAssertEqual(try result.get(), ready)
    owner.stop(ownerID: "old")
    XCTAssertTrue(owner.owns(ready))
    XCTAssertEqual(native.stops, [1])
    owner.stop(ownerID: "new")
    native.stopped(1)
  }

  func testMissingDeveloperImageHasAnActionableFixedCodeError() async throws {
    let native = Recorder()
    let owner = try fixture(recorder: native)
    let pending = Task { await owner.prepare(current: { true }) }
    try await wait { native.configurations.count == 1 }
    native.callbacks[0](native.configurations[0].runId, 3, "ERR_PHONE_DDI_REQUIRED: fixed upstream diagnostic")
    let result = await pending.value
    if case .failure(.developerImageRequired) = result {} else { XCTFail("DDI preparation failure was hidden") }
    XCTAssertTrue(owner.mayUseMacFallback)
    XCTAssertTrue(native.stops.isEmpty)
  }

  func testDisabledNativeClientCannotConfigureOrPrepare() async {
    // The test bundle and imported Runner can have different compile conditions.
    let owner = IOSPhoneSelfRunner(native: nil, pairingURL: URL(fileURLWithPath: "/unused/pairingFile.plist"),
      runnerBundleId: "test.dsh.PhoneRunner.xctrunner", targetBundleId: "test.dsh")
    XCTAssertFalse(owner.isConfigured)
    let result = await owner.prepare(current: { true })
    if case .failure(.unavailable) = result {} else { XCTFail("disabled native client unexpectedly prepared") }
  }

  func testNativeStartRejectionIsAnErrorAndDoesNotInventAnEndpoint() async throws {
    let native = Recorder()
    native.rejectStart = true
    let owner = try fixture(recorder: native)
    let result = await owner.prepare(current: { true })
    if case .failure(.failed) = result {} else { XCTFail("native start rejection was ignored") }
    XCTAssertEqual(native.configurations.count, 1)
    XCTAssertTrue(owner.mayUseMacFallback)
    XCTAssertTrue(native.stops.isEmpty)
  }
}
