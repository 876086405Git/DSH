import Foundation
import CryptoKit
import XCTest
@testable import Runner

/// Exercises the real parser/store with newly generated synthetic signing keys
/// and an in-memory Keychain adapter. It never touches the production service,
/// serializes a credential into test output, or claims to test iOS Keychain ACLs.
@MainActor
final class IOSPhonePairingStoreTests: XCTestCase {
  @MainActor
  private final class MemoryKeychain: IOSPhonePairingKeychain {
    var value: Data?
    var containsFailure: IOSPhonePairingError?
    var readFailure: IOSPhonePairingError?
    var writeFailure: IOSPhonePairingError?
    var eraseFailure: IOSPhonePairingError?
    private(set) var calls: [String] = []

    init(_ value: Data? = nil) { self.value = value }
    func contains() throws -> Bool {
      calls.append("contains")
      if let containsFailure { throw containsFailure }
      return value != nil
    }
    func read() throws -> Data? {
      calls.append("read")
      if let readFailure { throw readFailure }
      return value
    }
    func write(_ data: Data) throws {
      calls.append("write")
      if let writeFailure { throw writeFailure }
      value = data
    }
    func erase() throws {
      calls.append("erase")
      if let eraseFailure { throw eraseFailure }
      value = nil
    }
    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }
  }

  private func record(identifier: String = "synthetic-test-only",
                      extra: [String: Any] = [:]) throws -> Data {
    let key = Curve25519.Signing.PrivateKey()
    var fields: [String: Any] = [
      "private_key": key.rawRepresentation,
      "public_key": key.publicKey.rawRepresentation,
      "identifier": identifier,
    ]
    for (name, value) in extra { fields[name] = value }
    return try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
  }

  private func changing(_ input: Data, _ name: String, to value: Any) throws -> Data {
    var fields = try XCTUnwrap(PropertyListSerialization.propertyList(from: input, options: [], format: nil) as? [String: Any])
    fields[name] = value
    return try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
  }

  private func assertLoads(_ store: IOSPhonePairingStore, _ expected: Data,
                           file: StaticString = #filePath, line: UInt = #line) throws {
    // XCTAssertEqual(Data, Data) would disclose key bytes in a failure report.
    let actual = try store.load()
    XCTAssertTrue(try recordsEqual(actual, expected), "loaded the wrong synthetic record", file: file, line: line)
  }

  private func recordsEqual(_ lhs: Data, _ rhs: Data) throws -> Bool {
    guard let left = try PropertyListSerialization.propertyList(from: lhs, options: [], format: nil) as? NSDictionary,
      let right = try PropertyListSerialization.propertyList(from: rhs, options: [], format: nil) as? NSDictionary else { return false }
    // Binary plist key order is not part of the store's credential contract.
    // A Boolean assertion compares all decoded fields without printing keys.
    return left.isEqual(right)
  }

  private func assertBlocked(_ store: IOSPhonePairingStore,
                             file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(store.hasRecord, file: file, line: line)
    let status = store.status()
    XCTAssertEqual(Set(status.keys), Set(["present", "storage", "code"]), file: file, line: line)
    XCTAssertEqual(status["storage"] as? String, "none", file: file, line: line)
    XCTAssertEqual(status["code"] as? String, "ERR_PHONE_PAIRING_REVOKED", file: file, line: line)
    XCTAssertThrowsError(try store.load(), file: file, line: line)
  }

  func testNormalizationChecksRealKeyPairAndDropsUnrecognizedFields() throws {
    let input = try record(extra: ["alt_irk": Data(repeating: 7, count: 16),
                                   "unrelated_name": "must-not-survive", "unrelated_blob": Data([1, 2, 3])])
    let canonical = try IOSPhonePairingRecord.normalized(input)
    var format = PropertyListSerialization.PropertyListFormat.xml
    let fields = try XCTUnwrap(PropertyListSerialization.propertyList(from: canonical, options: [], format: &format) as? [String: Any])
    XCTAssertEqual(format, .binary)
    XCTAssertEqual(Set(fields.keys), Set(["private_key", "public_key", "identifier", "alt_irk"]))
    XCTAssertEqual((fields["private_key"] as? Data)?.count, 32)
    XCTAssertEqual((fields["public_key"] as? Data)?.count, 32)
    XCTAssertEqual((fields["alt_irk"] as? Data)?.count, 16)
    // The second normalization must preserve the authenticated, minimal record.
    XCTAssertTrue(try recordsEqual(IOSPhonePairingRecord.normalized(canonical), canonical))
  }

  func testMalformedRecordsCannotChangeAnExistingStore() throws {
    let valid = try record()
    let expected = try IOSPhonePairingRecord.normalized(valid)
    let keychain = MemoryKeychain(expected)
    let store = IOSPhonePairingStore(keychain: keychain)
    let generation = store.generation
    var changes = 0
    store.willChange = { changes += 1 }
    defer { store.willChange = nil }
    let unrelatedKey = Curve25519.Signing.PrivateKey()
    let invalid: [Data] = [
      Data(), Data(repeating: 0, count: IOSPhonePairingRecord.maximumBytes + 1),
      Data("not a property list".utf8),
      try changing(valid, "public_key", to: unrelatedKey.publicKey.rawRepresentation),
      try changing(valid, "private_key", to: Data(repeating: 0, count: 31)),
      try changing(valid, "identifier", to: ""),
      try changing(valid, "identifier", to: "synthetic\nidentifier"),
      try changing(valid, "identifier", to: String(repeating: "a", count: 129)),
      try changing(valid, "alt_irk", to: Data(repeating: 0, count: 15)),
    ]
    for input in invalid {
      XCTAssertThrowsError(try store.replace(input, storage: .session))
      XCTAssertEqual(store.generation, generation)
      try assertLoads(store, expected)
    }
    XCTAssertEqual(changes, 0)
    XCTAssertEqual(keychain.count("write"), 0)
    XCTAssertEqual(keychain.count("erase"), 0)
  }

  func testDeviceToSessionErasesRememberedRecordAndDoesNotSurviveNewStore() throws {
    let keychain = MemoryKeychain()
    let store = IOSPhonePairingStore(keychain: keychain)
    try store.replace(record(identifier: "synthetic-device"), storage: .device)
    let firstGeneration = store.generation
    let session = try record(identifier: "synthetic-session")
    let expected = try IOSPhonePairingRecord.normalized(session)
    try store.replace(session, storage: .session)
    XCTAssertNotEqual(store.generation, firstGeneration)
    XCTAssertEqual(keychain.count("write"), 1)
    XCTAssertEqual(keychain.count("erase"), 1)
    XCTAssertTrue(keychain.value == nil)
    XCTAssertEqual(store.status()["storage"] as? String, "session")
    try assertLoads(store, expected)
    // A fresh store has no reference to the first store's process-memory copy.
    let fresh = IOSPhonePairingStore(keychain: keychain)
    XCTAssertFalse(fresh.hasRecord)
    XCTAssertThrowsError(try fresh.load())
  }

  func testSessionToDeviceReplacesMemoryAndCanBeReadByNewStore() throws {
    let keychain = MemoryKeychain()
    let store = IOSPhonePairingStore(keychain: keychain)
    try store.replace(record(identifier: "synthetic-session"), storage: .session)
    let device = try record(identifier: "synthetic-device")
    let expected = try IOSPhonePairingRecord.normalized(device)
    let previous = store.generation
    try store.replace(device, storage: .device)
    XCTAssertNotEqual(store.generation, previous)
    XCTAssertEqual(store.status()["storage"] as? String, "device")
    try assertLoads(store, expected)
    try assertLoads(IOSPhonePairingStore(keychain: keychain), expected)
    // Clearing a former session must not change the chosen persistent record.
    store.clearSession()
    try assertLoads(store, expected)
  }

  func testFailedDeviceWriteBlocksTheOldPersistentRecordAndChangesGeneration() throws {
    let old = try IOSPhonePairingRecord.normalized(record())
    let keychain = MemoryKeychain(old)
    keychain.writeFailure = .unavailable
    let store = IOSPhonePairingStore(keychain: keychain)
    let previous = store.generation
    var callbacks = 0
    defer { store.willChange = nil }
    store.willChange = {
      callbacks += 1
      XCTAssertNotEqual(store.generation, previous)
      self.assertBlocked(store)
    }
    XCTAssertThrowsError(try store.replace(record(identifier: "synthetic-replacement"), storage: .device))
    XCTAssertEqual(callbacks, 1)
    XCTAssertNotEqual(store.generation, previous)
    XCTAssertTrue(keychain.value == old, "the failing fixture unexpectedly changed its storage")
    assertBlocked(store)
    let reads = keychain.count("read")
    XCTAssertThrowsError(try store.load())
    XCTAssertEqual(keychain.count("read"), reads, "blocked load consulted stale persistent data")
  }

  func testFailedSessionTransitionDoesNotExposeEitherTheOldOrNewRecord() throws {
    let old = try IOSPhonePairingRecord.normalized(record())
    let keychain = MemoryKeychain(old)
    let store = IOSPhonePairingStore(keychain: keychain)
    let previous = store.generation
    keychain.eraseFailure = .storage
    XCTAssertThrowsError(try store.replace(record(identifier: "synthetic-session"), storage: .session))
    XCTAssertNotEqual(store.generation, previous)
    XCTAssertTrue(keychain.value == old)
    assertBlocked(store)
    XCTAssertEqual(keychain.count("write"), 0)
  }

  func testFailedRevokeStillBlocksMemoryAndPersistentLoads() throws {
    let keychain = MemoryKeychain()
    let store = IOSPhonePairingStore(keychain: keychain)
    try store.replace(record(), storage: .session)
    let previous = store.generation
    keychain.eraseFailure = .unavailable
    XCTAssertThrowsError(try store.revoke())
    XCTAssertNotEqual(store.generation, previous)
    assertBlocked(store)
    XCTAssertEqual(keychain.count("read"), 0)
  }

  func testClearSessionDoesNotFallBackToAnOldRememberedRecord() throws {
    let keychain = MemoryKeychain(try IOSPhonePairingRecord.normalized(record()))
    let store = IOSPhonePairingStore(keychain: keychain)
    try store.replace(record(identifier: "synthetic-session"), storage: .session)
    store.clearSession()
    XCTAssertFalse(store.hasRecord)
    XCTAssertTrue(keychain.value == nil)
    XCTAssertThrowsError(try store.load())
  }

  func testUnavailableKeychainHasSanitizedStatusAndIsNeverReportedPresent() throws {
    let keychain = MemoryKeychain(try IOSPhonePairingRecord.normalized(record()))
    keychain.containsFailure = .unavailable
    keychain.readFailure = .unavailable
    let store = IOSPhonePairingStore(keychain: keychain)
    let status = store.status()
    XCTAssertEqual(Set(status.keys), Set(["present", "storage", "code"]))
    XCTAssertEqual(status["present"] as? Bool, false)
    XCTAssertEqual(status["storage"] as? String, "unknown")
    XCTAssertEqual(status["code"] as? String, "ERR_PHONE_PAIRING_LOCKED")
    XCTAssertThrowsError(try store.load())
  }

  func testWillChangeCanInspectTheBlockedNewGeneration() throws {
    let keychain = MemoryKeychain(try IOSPhonePairingRecord.normalized(record()))
    let store = IOSPhonePairingStore(keychain: keychain)
    let previous = store.generation
    var callbacks = 0
    defer { store.willChange = nil }
    store.willChange = {
      callbacks += 1
      XCTAssertNotEqual(store.generation, previous)
      self.assertBlocked(store)
    }
    let replacement = try record(identifier: "synthetic-replacement")
    try store.replace(replacement, storage: .device)
    XCTAssertEqual(callbacks, 1)
    try assertLoads(store, IOSPhonePairingRecord.normalized(replacement))
  }

  func testReentrantRevokeSupersedesTheOuterReplace() throws {
    let keychain = MemoryKeychain(try IOSPhonePairingRecord.normalized(record()))
    let store = IOSPhonePairingStore(keychain: keychain)
    var revokeGeneration: UUID?
    store.willChange = {
      store.willChange = nil
      do { try store.revoke(); revokeGeneration = store.generation }
      catch { XCTFail("synthetic nested revoke unexpectedly failed") }
    }
    XCTAssertThrowsError(try store.replace(record(identifier: "superseded"), storage: .device))
    XCTAssertEqual(store.generation, try XCTUnwrap(revokeGeneration))
    XCTAssertEqual(keychain.count("write"), 0, "superseded import wrote after a newer revoke")
    XCTAssertEqual(keychain.count("erase"), 1)
    assertBlocked(store)
  }

  func testReentrantReplaceSupersedesTheOuterReplace() throws {
    let keychain = MemoryKeychain()
    let store = IOSPhonePairingStore(keychain: keychain)
    let latest = try record(identifier: "synthetic-latest")
    let expected = try IOSPhonePairingRecord.normalized(latest)
    var latestGeneration: UUID?
    store.willChange = {
      store.willChange = nil
      do { try store.replace(latest, storage: .session); latestGeneration = store.generation }
      catch { XCTFail("synthetic nested replacement unexpectedly failed") }
    }
    XCTAssertThrowsError(try store.replace(record(identifier: "superseded"), storage: .device))
    XCTAssertEqual(store.generation, try XCTUnwrap(latestGeneration))
    XCTAssertEqual(keychain.count("write"), 0)
    XCTAssertEqual(store.status()["storage"] as? String, "session")
    try assertLoads(store, expected)
  }

  func testReentrantReplaceSupersedesTheOuterRevoke() throws {
    let keychain = MemoryKeychain()
    let store = IOSPhonePairingStore(keychain: keychain)
    let latest = try record(identifier: "synthetic-latest")
    let expected = try IOSPhonePairingRecord.normalized(latest)
    var latestGeneration: UUID?
    store.willChange = {
      store.willChange = nil
      do { try store.replace(latest, storage: .device); latestGeneration = store.generation }
      catch { XCTFail("synthetic nested replacement unexpectedly failed") }
    }
    XCTAssertThrowsError(try store.revoke())
    XCTAssertEqual(store.generation, try XCTUnwrap(latestGeneration))
    XCTAssertEqual(keychain.count("erase"), 0, "superseded revoke erased the newer import")
    try assertLoads(store, expected)
  }
}
