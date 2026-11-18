import Foundation

@main
struct CompanionWidgetContract {
  static func main() throws {
    var value = CompanionSnapshot()
    value.update(["name": "测试伙伴", "status": "玩耍中", "statusWaiting": "等你回来",
      "activity": "play", "bond": 2, "line": "你好", "saidAt": 10_000, "untilMs": 20_000])
    precondition(value.name == "测试伙伴" && value.bond == 2)
    precondition(value.displayStatus(at: Date(timeIntervalSince1970: 19)) == "玩耍中")
    precondition(value.displayStatus(at: Date(timeIntervalSince1970: 20)) == "等你回来")
    value.update(["status": "休息中"])
    precondition(value.line == "你好" && value.saidAt == 10_000)
    value.update(["line": NSNull(), "saidAt": NSNull(), "untilMs": NSNull(), "bond": NSNull()])
    precondition(value.line.isEmpty && value.saidAt == nil && value.untilMs == nil && value.bond == 0)
    value.update(["line": String(repeating: "鲸", count: 1000), "bond": 100,
      "untilMs": Double.infinity, "saidAt": -1])
    precondition(value.line.count == 512 && value.bond == 3 && value.untilMs == nil && value.saidAt == nil)
    value.update(["token": "synthetic-not-a-secret", "sessionId": "synthetic"])
    let data = try JSONEncoder().encode(value)
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    precondition(object["token"] == nil && object["sessionId"] == nil)
    let decoded = try JSONDecoder().decode(CompanionSnapshot.self, from: data)
    precondition(decoded == value)
    print("PASS: widget snapshot merge, explicit clearing, bounds, expiry and display-only fields")
  }
}
