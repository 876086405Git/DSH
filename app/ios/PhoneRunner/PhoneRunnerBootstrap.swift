import Foundation
import Security

enum PhoneRunnerAppCatalog {
  static func bundleID(for value: String, apps: [[String: String]] = []) -> String? {
    let wanted = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if wanted.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil {
      return wanted
    }
    if ["设置", "系统设置", "settings", "system settings"].contains(wanted.lowercased()) { return "com.apple.Preferences" }
    return apps.first { $0["name"]?.caseInsensitiveCompare(wanted) == .orderedSame }?["id"]
  }
}

/// Shared by the app and the XCTest runner. Only encrypted readiness crosses DTX.
struct PhoneRunnerEndpoint: Codable, Equatable {
  let v: Int
  let port: Int
  let token: String
  let runId: String?

  init(v: Int = 1, port: Int, token: String, runId: String? = nil) {
    self.v = v
    self.port = port
    self.token = token
    self.runId = runId
  }

  func isValid(for expectedRunId: String? = nil) -> Bool {
    guard v == 1, (1...65535).contains(port), token.utf8.count == 64,
      token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
    if let expectedRunId { return runId == expectedRunId }
    return true
  }
}

/// A fresh, nonpersistent key per launch keeps the RPC bearer out of logs,
/// launch arguments/environment, the App Group and test-result attachments.
final class PhoneRunnerHandshake {
  static let activityPrefix = "DSH_PHONE_READY_V1:"
  static let publicKeyEnvironment = "DSH_PHONE_PUBLIC_KEY"
  static let runIdEnvironment = "DSH_PHONE_RUN_ID"
  private static let algorithm: SecKeyAlgorithm = .rsaEncryptionOAEPSHA256

  enum Failure: Error {
    case invalidRun, keyGeneration, invalidPublicKey, invalidEndpoint
    case encryptionFailed, invalidCiphertext, decryptionFailed
  }

  private let privateKey: SecKey
  private let runId: String
  let publicKeyBase64: String

  init(runId: String) throws {
    guard UUID(uuidString: runId) != nil else { throw Failure.invalidRun }
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeySizeInBits as String: 2048,
      kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
    ]
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
      let publicKey = SecKeyCopyPublicKey(key),
      let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
      throw Failure.keyGeneration
    }
    self.privateKey = key
    self.runId = runId
    publicKeyBase64 = bytes.base64EncodedString()
  }

  static func seal(_ endpoint: PhoneRunnerEndpoint, publicKeyBase64: String) throws -> String {
    guard let runId = endpoint.runId, UUID(uuidString: runId) != nil,
      endpoint.isValid(for: runId) else { throw Failure.invalidEndpoint }
    guard publicKeyBase64.utf8.count <= 4096,
      let bytes = Data(base64Encoded: publicKeyBase64), !bytes.isEmpty,
      let publicKey = SecKeyCreateWithData(bytes as CFData, [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        kSecAttrKeySizeInBits as String: 2048,
      ] as CFDictionary, nil), SecKeyGetBlockSize(publicKey) == 256 else {
      throw Failure.invalidPublicKey
    }
    let plaintext = try JSONEncoder().encode(endpoint)
    guard let encrypted = SecKeyCreateEncryptedData(publicKey, algorithm, plaintext as CFData, nil) as Data? else {
      throw Failure.encryptionFailed
    }
    return encrypted.base64EncodedString()
  }

  func decodeReady(_ ciphertext: String) throws -> PhoneRunnerEndpoint {
    guard ciphertext.utf8.count <= 4096, let encrypted = Data(base64Encoded: ciphertext),
      encrypted.count == SecKeyGetBlockSize(privateKey) else { throw Failure.invalidCiphertext }
    guard let plaintext = SecKeyCreateDecryptedData(privateKey, Self.algorithm, encrypted as CFData, nil) as Data? else {
      throw Failure.decryptionFailed
    }
    let endpoint = try JSONDecoder().decode(PhoneRunnerEndpoint.self, from: plaintext)
    guard endpoint.isValid(for: runId) else { throw Failure.invalidEndpoint }
    return endpoint
  }
}
