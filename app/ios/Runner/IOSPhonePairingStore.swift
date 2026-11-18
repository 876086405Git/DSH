import Foundation
import Security
import CryptoKit

enum IOSPhonePairingError: Error {
  case invalid, tooLarge, missing, unavailable, storage, superseded

  var code: String {
    switch self {
    case .invalid: return "ERR_PHONE_PAIRING_INVALID"
    case .tooLarge: return "ERR_PHONE_PAIRING_TOO_LARGE"
    case .missing: return "ERR_PHONE_PAIRING_REQUIRED"
    case .unavailable: return "ERR_PHONE_PAIRING_LOCKED"
    case .storage: return "ERR_PHONE_PAIRING_STORAGE"
    case .superseded: return "ERR_PHONE_PAIRING_CHANGED"
    }
  }
}

/// Only the fixed idevice RpPairingFile format, not a USB lockdown pairing file.
/// No caller may serialize this data into a Flutter result, log, or diagnostic.
enum IOSPhonePairingRecord {
  static let maximumBytes = 65_536

  static func normalized(_ data: Data) throws -> Data {
    guard !data.isEmpty, data.count <= maximumBytes else { throw IOSPhonePairingError.tooLarge }
    guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
      let dictionary = value as? [String: Any],
      let privateKey = dictionary["private_key"] as? Data, privateKey.count == 32,
      let publicKey = dictionary["public_key"] as? Data, publicKey.count == 32,
      let identifier = dictionary["identifier"] as? String,
      !identifier.isEmpty, identifier.utf8.count <= 128,
      identifier.utf8.allSatisfy({ (0x20...0x7e).contains($0) }),
      let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey),
      signingKey.publicKey.rawRepresentation == publicKey else { throw IOSPhonePairingError.invalid }
    var canonical: [String: Any] = [
      "private_key": privateKey, "public_key": publicKey, "identifier": identifier,
    ]
    if let value = dictionary["alt_irk"] {
      guard let irk = value as? Data, irk.count == 16 else { throw IOSPhonePairingError.invalid }
      canonical["alt_irk"] = irk
    }
    // Drop unrecognized fields instead of retaining unrelated device/user data.
    return try PropertyListSerialization.data(fromPropertyList: canonical, format: .binary, options: 0)
  }
}

@MainActor
protocol IOSPhonePairingKeychain {
  func contains() throws -> Bool
  func read() throws -> Data?
  func write(_ data: Data) throws
  func erase() throws
}

@MainActor
final class IOSPhoneDeviceKeychain: IOSPhonePairingKeychain {
  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "io.github.ccch1mneyyy.dshgo.remote-pairing.v1",
     kSecAttrAccount as String: "current-device",
     kSecAttrSynchronizable as String: false]
  }

  private func check(_ status: OSStatus) throws {
    if status == errSecInteractionNotAllowed || status == errSecNotAvailable {
      throw IOSPhonePairingError.unavailable
    }
    guard status == errSecSuccess else { throw IOSPhonePairingError.storage }
  }

  func contains() throws -> Bool {
    var request = query
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    request[kSecReturnAttributes as String] = true
    request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    let status = SecItemCopyMatching(request as CFDictionary, nil)
    if status == errSecItemNotFound { return false }
    try check(status)
    return true
  }

  func read() throws -> Data? {
    var request = query
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    request[kSecReturnData as String] = true
    request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    try check(status)
    guard let data = result as? Data, data.count <= IOSPhonePairingRecord.maximumBytes else {
      throw IOSPhonePairingError.invalid
    }
    return data
  }

  func write(_ data: Data) throws {
    // This exact class is not backed up or synchronized, and requires a device
    // passcode. Other ThisDeviceOnly classes can be backed up to the same device.
    // Failure must never silently downgrade to a weaker keychain class.
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
      kSecAttrSynchronizable as String: false,
    ]
    let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if update == errSecItemNotFound {
      var request = query
      for (key, value) in attributes { request[key] = value }
      try check(SecItemAdd(request as CFDictionary, nil))
    } else { try check(update) }
  }

  func erase() throws {
    let status = SecItemDelete(query as CFDictionary)
    if status != errSecItemNotFound { try check(status) }
  }
}

/// The persistent implementation has no file/export interface. Session data is
/// process memory only. Changing/revoking a record invalidates live native use.
@MainActor
final class IOSPhonePairingStore {
  enum Storage: String { case device, session }
  static let shared = IOSPhonePairingStore(keychain: IOSPhoneDeviceKeychain())

  private let keychain: IOSPhonePairingKeychain
  private var sessionRecord: Data?
  private var blocked = false
  private(set) var generation = UUID()
  var willChange: (() -> Void)?

  init(keychain: IOSPhonePairingKeychain) { self.keychain = keychain }

  /// Public status describes availability only; no key, identifier, original
  /// filename, base64, or credential digest leaves this object through status.
  func status() -> [String: Any] {
    if blocked { return ["present": false, "storage": "none", "code": "ERR_PHONE_PAIRING_REVOKED"] }
    if sessionRecord != nil { return ["present": true, "storage": Storage.session.rawValue, "code": "OK"] }
    do {
      let present = try keychain.contains()
      return ["present": present, "storage": present ? Storage.device.rawValue : "none",
        "code": present ? "OK" : IOSPhonePairingError.missing.code]
    } catch {
      return ["present": false, "storage": "unknown", "code": safeCode(error)]
    }
  }

  var hasRecord: Bool { status()["present"] as? Bool == true }

  func load() throws -> Data {
    guard !blocked else { throw IOSPhonePairingError.missing }
    if let sessionRecord { return sessionRecord }
    guard let record = try keychain.read() else { throw IOSPhonePairingError.missing }
    return try IOSPhonePairingRecord.normalized(record)
  }

  /// Invoked only after the native import dialog's explicit storage choice.
  func replace(_ input: Data, storage: Storage) throws {
    let record = try IOSPhonePairingRecord.normalized(input)
    blocked = true
    generation = UUID()
    let change = generation
    clearSession()
    willChange?()
    // A synchronous listener can revoke or replace again. The older operation
    // must not overwrite that newer decision or reopen a revoked record.
    guard generation == change else { throw IOSPhonePairingError.superseded }
    switch storage {
    case .device:
      try keychain.write(record)
      clearSession()
    case .session:
      // A previous remembered record must not reappear after this process exits.
      try keychain.erase()
      clearSession()
      sessionRecord = record
    }
    guard generation == change else { throw IOSPhonePairingError.superseded }
    blocked = false
  }

  func revoke() throws {
    blocked = true
    generation = UUID()
    let change = generation
    clearSession()
    willChange?()
    guard generation == change else { throw IOSPhonePairingError.superseded }
    // Even a Keychain error leaves this process revoked. Report failure rather
    // than claiming that a persistent item was deleted successfully.
    try keychain.erase()
  }

  func clearSession() {
    let count = sessionRecord?.count ?? 0
    sessionRecord?.resetBytes(in: 0..<count)
    sessionRecord = nil
    // Data/FFI can have temporary copies: this is not a claim of universal memory
    // zeroization. No session copy is deliberately persisted to disk.
  }

  private func safeCode(_ error: Error) -> String {
    (error as? IOSPhonePairingError)?.code ?? IOSPhonePairingError.storage.code
  }
}
