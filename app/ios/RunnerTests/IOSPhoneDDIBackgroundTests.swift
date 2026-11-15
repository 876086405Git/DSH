import Foundation
import XCTest
@testable import Runner

/// Tiny owned fixtures exercise the real SHA verifier and worker handoff.
/// These tests never download a DDI or contact a device/service.
@MainActor
final class IOSPhoneDDIBackgroundTests: XCTestCase {
  private enum FixtureError: Error { case timeout }

  private final class WorkerGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var didStart = false
    private var didFinish = false
    private var wasMain: Bool?
    var started: Bool { lock.lock(); defer { lock.unlock() }; return didStart }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return didFinish }
    var mainThread: Bool? { lock.lock(); defer { lock.unlock() }; return wasMain }
    func enter() throws {
      lock.lock(); wasMain = Thread.isMainThread; didStart = true; lock.unlock()
      guard release.wait(timeout: .now() + 4) == .success else { throw FixtureError.timeout }
      lock.lock(); didFinish = true; lock.unlock()
    }
    func markStarted() { lock.lock(); didStart = true; lock.unlock() }
    func finish() { release.signal() }
  }

  private func wait(_ predicate: () -> Bool) async throws {
    for _ in 0..<400 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("synthetic DDI worker did not enter")
    throw FixtureError.timeout
  }

  private func fixture() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dsh-ddi-worker-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    do { try Data("abc".utf8).write(to: directory.appendingPathComponent("fixture.bin"), options: .atomic) }
    catch { try? FileManager.default.removeItem(at: directory); throw error }
    return directory
  }

  private func asset(hash: String = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") -> IOSPhoneDDICache.Asset {
    .init(key: "synthetic", filename: "fixture.bin", bytes: 3, sha256: hash)
  }

  func testRealCachedSHAIsCheckedOffMainAndMainActorCanProgress() async throws {
    let directory = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("fixture.bin")
    let expected = asset()
    let gate = WorkerGate()
    defer { gate.finish() }
    let pending = Task {
      try await IOSPhoneDDICache.verifyOnWorker {
        try gate.enter()
        return try IOSPhoneDDICache.verify(url, asset: expected)
      }
    }
    try await wait { gate.started }
    XCTAssertTrue(Thread.isMainThread)
    XCTAssertEqual(gate.mainThread, false)
    gate.finish()
    let verified = try await pending.value
    XCTAssertTrue(verified)
    XCTAssertTrue(gate.finished)
  }

  func testWorkerPreservesTheRealDigestMismatchFailure() async throws {
    let directory = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("fixture.bin")
    let expected = asset(hash: String(repeating: "0", count: 64))
    do {
      _ = try await IOSPhoneDDICache.verifyOnWorker { try IOSPhoneDDICache.verify(url, asset: expected) }
      XCTFail("a changed digest must fail")
    } catch let error as IOSPhoneDDIError { XCTAssertEqual(error, .integrity) }
  }

  func testCancellationJoinsWorkerAndRejectsItsLateSuccess() async throws {
    let gate = WorkerGate()
    defer { gate.finish() }
    let pending = Task {
      try await IOSPhoneDDICache.verifyOnWorker { try gate.enter(); return true }
    }
    try await wait { gate.started }
    pending.cancel()
    XCTAssertFalse(gate.finished)
    gate.finish()
    do { _ = try await pending.value; XCTFail("cancelled work cannot return success") }
    catch is CancellationError { }
    XCTAssertTrue(gate.finished)
  }

  func testAnAlreadyCancelledCallerNeverStartsVerification() async throws {
    let gate = WorkerGate()
    let pending = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await IOSPhoneDDICache.verifyOnWorker { gate.markStarted(); return true }
    }
    do { _ = try await pending.value; XCTFail("cancelled work cannot start") }
    catch is CancellationError { }
    XCTAssertFalse(gate.started)
  }
}
