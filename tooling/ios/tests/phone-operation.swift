import Foundation

@main struct PhoneOperationFixture {
  static func main() throws {
    func plan(_ method: String, _ params: [String: Any] = [:]) throws -> IOSPhoneOperation {
      let raw = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)
      let envelope: [String: Any] = ["v": 1, "runId": "synthetic", "id": "synthetic-call",
        "owner": ["sessionId": "synthetic-session", "callId": "synthetic-call"],
        "action": ["kind": "runner-call", "method": method, "params": raw], "expiresAt": 12345]
      let request = try JSONDecoder().decode(IOSPhoneRequest.self,
        from: JSONSerialization.data(withJSONObject: envelope))
      return try IOSPhoneOperation(request)
    }
    _ = try plan("screen")
    _ = try plan("open", ["app": "com.apple.Preferences"])
    _ = try plan("scroll", ["screen": "s1", "direction": "down"])
    for method in ["activate", "validate", "prepareInput", "ascii", "paste", "native"] {
      do { _ = try plan(method); fatalError("Private RPC entered the model plan") }
      catch is IOSPhoneOperationError {}
    }
    for key in ["returnTarget", "controllerBundleID", "xctestDeniedBundleIDs", "backend", "route"] {
      do { _ = try plan("screen", [key: "com.example.synthetic"]); fatalError("Native target policy entered the model plan") }
      catch is IOSPhoneOperationError {}
    }
    print("PASS: production phone plan accepts public operations and rejects private activation/target policy")
  }
}
