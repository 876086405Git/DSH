import Foundation

/// Run with the production helper and Apple's Security framework; no fake crypto.
@main
struct PhoneBootstrapChecks {
  static func expectThrows(_ body: () throws -> Void) throws {
    do {
      try body()
    } catch {
      return
    }
    throw CheckFailure.expectedRejection
  }

  enum CheckFailure: Error { case expectedRejection, wrongResult }

  static func main() throws {
    let run = UUID().uuidString.lowercased()
    let owner = try PhoneRunnerHandshake(runId: run)
    let endpoint = PhoneRunnerEndpoint(port: 43210, token: String(repeating: "a", count: 64), runId: run)
    let ciphertext = try PhoneRunnerHandshake.seal(endpoint, publicKeyBase64: owner.publicKeyBase64)
    guard try owner.decodeReady(ciphertext) == endpoint else { throw CheckFailure.wrongResult }
    guard !ciphertext.contains(endpoint.token), !ciphertext.contains(run),
      Data(base64Encoded: ciphertext)?.count == 256 else { throw CheckFailure.wrongResult }

    let otherKey = try PhoneRunnerHandshake(runId: run)
    try expectThrows { _ = try otherKey.decodeReady(ciphertext) }
    let wrongRun = PhoneRunnerEndpoint(port: endpoint.port, token: endpoint.token, runId: UUID().uuidString)
    let wrongRunCipher = try PhoneRunnerHandshake.seal(wrongRun, publicKeyBase64: owner.publicKeyBase64)
    try expectThrows { _ = try owner.decodeReady(wrongRunCipher) }
    var altered = Data(base64Encoded: ciphertext)!
    altered[0] ^= 1
    try expectThrows { _ = try owner.decodeReady(altered.base64EncodedString()) }
    for value in ["", "not base64", String(repeating: "A", count: 5000), Data(repeating: 0, count: 255).base64EncodedString()] {
      try expectThrows { _ = try owner.decodeReady(value) }
    }
    for key in ["", "not base64", String(repeating: "A", count: 5000)] {
      try expectThrows { _ = try PhoneRunnerHandshake.seal(endpoint, publicKeyBase64: key) }
    }
    for invalid in [
      PhoneRunnerEndpoint(v: 2, port: 1, token: endpoint.token, runId: run),
      PhoneRunnerEndpoint(port: 0, token: endpoint.token, runId: run),
      PhoneRunnerEndpoint(port: 65536, token: endpoint.token, runId: run),
      PhoneRunnerEndpoint(port: 1, token: "bad", runId: run),
      PhoneRunnerEndpoint(port: 1, token: String(repeating: "g", count: 64), runId: run),
      PhoneRunnerEndpoint(port: 1, token: endpoint.token),
    ] {
      try expectThrows { _ = try PhoneRunnerHandshake.seal(invalid, publicKeyBase64: owner.publicKeyBase64) }
    }
    try expectThrows { _ = try PhoneRunnerHandshake(runId: "invalid") }
    let legacy = try JSONDecoder().decode(PhoneRunnerEndpoint.self,
      from: Data("{\"v\":1,\"port\":1234,\"token\":\"\(endpoint.token)\"}".utf8))
    guard legacy.runId == nil, legacy.isValid(), !legacy.isValid(for: run) else { throw CheckFailure.wrongResult }
    print("PASS: real RSA readiness, key/run binding, tamper rejection, invalid inputs and legacy decoding")
  }
}
