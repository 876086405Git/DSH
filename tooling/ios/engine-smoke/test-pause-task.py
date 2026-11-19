#!/usr/bin/env python3
"""Run production pause/ACK methods with queue/UIKit stand-ins on macOS.

Checks ordering and resource ownership, not actual iOS background scheduling.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

if sys.platform != "darwin":
    raise SystemExit("Requires the macOS Foundation/Swift toolchain")

root = Path(__file__).resolve().parents[3]
source = (root / "app/ios/Runner/EngineChannel.swift").read_text()
production = source.split("  // MARK: App lifecycle", 1)[1].split("  // MARK: Phone actions", 1)[0]
production += "  private func lifecycleChanged()" + source.split(
    "  private func lifecycleChanged()", 1)[1].split("  // MARK: Install", 1)[0]
# Keep the actual nested escaping closures, not a handwritten copy of their bodies.
production += "  private func attachProtection() {\n    backgroundProtection.onChange =" + source.split(
    "    backgroundProtection.onChange =", 1)[1].split("    let protectionStatus =", 1)[0] + "  }\n"

fixture = r'''
import Foundation

final class DispatchQueue {
  static let main = DispatchQueue()
  var pending: [() -> Void] = []
  func async(execute action: @escaping () -> Void) { pending.append(action) }
  func drain() { while !pending.isEmpty { pending.removeFirst()() } }
}
struct UIBackgroundTaskIdentifier: Equatable {
  let rawValue: Int
  static let invalid = Self(rawValue: -1)
}
final class UIApplication {
  enum State { case active, background }
  static let shared = UIApplication()
  var applicationState = State.background
  var denied = false
  var next = 0
  var endings: [UIBackgroundTaskIdentifier] = []
  var expiration: (() -> Void)?
  func beginBackgroundTask(withName: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
    guard !denied else { return .invalid }
    next += 1
    expiration = expirationHandler
    return UIBackgroundTaskIdentifier(rawValue: next)
  }
  func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
    precondition(identifier != .invalid && !endings.contains(identifier), "end exactly once")
    endings.append(identifier)
  }
}
final class Phone { func enteredBackground() {} }
final class Protection {
  var onChange: (([String: Any]) -> Void)?
  var backgrounds: [Bool] = []
  func update(background: Bool) { backgrounds.append(background) }
}
final class Native { func currentState() -> [String: Any] { ["phase": "running"] } }
final class Lifecycle {
  var failure: String?
  var revision = 1
  var acknowledged: Int?
  var foregrounds: [Bool] = []
  var enhanced: [Bool] = []
  func observe(foreground: Bool) { foregrounds.append(foreground); revision += 1 }
  func observe(backgroundAudio: Bool, backgroundLocation: Bool) {
    enhanced = [backgroundAudio, backgroundLocation]; revision += 1
  }
  func status() -> [String: Any?] { ["revision": revision, "acknowledgedRevision": acknowledged] }
}
final class EngineChannel: NSObject {
  static let notice = "fixture"
  var backgroundTask = UIBackgroundTaskIdentifier.invalid
  var pauseObservation: (owner: UUID, revision: Int?)?
  let queue = DispatchQueue()
  let lifecycle = Lifecycle()
  var native: Native? = Native()
  var phone: Phone?
  let backgroundProtection = Protection()
  var backgroundProtectionActive = false
  var backgroundProtectionStatus: [String: Any] = [:]
  var lastLifecycleError: String?
  func collect() {}
  func emit(_ event: [String: Any]) {}
  func emitStatus() {}
  // PRODUCTION

  static func check() {
    let app = UIApplication.shared
    let owner = EngineChannel()
    owner.lifecycle.acknowledged = owner.lifecycle.revision // An old foreground ACK.
    owner.enteredBackground()
    let first = owner.backgroundTask
    precondition(first != .invalid, "request before blocked engine queue drains")
    precondition(owner.backgroundProtection.backgrounds == [true])
    precondition(owner.lifecycle.foregrounds.isEmpty)
    owner.lifecycleChanged()
    DispatchQueue.main.drain()
    precondition(owner.backgroundTask == first, "old ACK before binding must not release")
    owner.queue.drain()
    DispatchQueue.main.drain()
    precondition(owner.backgroundTask == first && owner.lifecycle.foregrounds == [false])

    // A newer observation can supersede the pause HTTP request (e.g. PiP state).
    owner.lifecycle.revision += 1
    owner.lifecycle.acknowledged = owner.lifecycle.revision
    owner.lifecycleChanged()
    DispatchQueue.main.drain()
    precondition(owner.backgroundTask == .invalid && app.endings.last == first)

    owner.enteredBackground()
    let expiring = owner.backgroundTask
    owner.queue.drain(); DispatchQueue.main.drain()
    let count = app.endings.count
    app.expiration?()
    precondition(owner.backgroundTask == .invalid && app.endings.count == count + 1)
    precondition(app.endings.last == expiring, "expire synchronously")
    owner.endBackgroundTask()
    precondition(app.endings.count == count + 1)

    // Reusing a budget still replaces observation ownership before queue work.
    owner.enteredBackground()
    let reused = owner.backgroundTask
    owner.queue.drain(); DispatchQueue.main.drain()
    owner.lifecycle.acknowledged = owner.lifecycle.revision
    owner.lifecycleChanged() // Its main-thread release is delayed.
    owner.enteredBackground() // Same task ID, different pause observation owner.
    DispatchQueue.main.drain()
    precondition(owner.backgroundTask == reused, "old ACK cannot release a reused budget")
    owner.queue.drain(); DispatchQueue.main.drain()
    precondition(owner.backgroundTask == reused)
    owner.lifecycle.acknowledged = owner.lifecycle.revision
    owner.lifecycleChanged(); DispatchQueue.main.drain()
    precondition(owner.backgroundTask == .invalid)

    // A no-op continued observation may already have its ACK; bind must finish it.
    owner.enteredBackground()
    let noOpOwner = owner.pauseObservation!.owner
    owner.queue.drain(); DispatchQueue.main.drain()
    owner.lifecycle.acknowledged = owner.lifecycle.revision
    owner.bindPauseObservation(noOpOwner); DispatchQueue.main.drain()
    precondition(owner.backgroundTask == .invalid)

    // An idle cleanup pending on main cannot end the next departure.
    owner.native = nil
    owner.enteredBackground()
    let old = owner.backgroundTask
    owner.queue.drain()
    app.applicationState = .active
    owner.enteringForeground()
    precondition(owner.backgroundProtection.backgrounds.last == false)
    precondition(owner.backgroundTask == .invalid && app.endings.last == old)
    app.applicationState = .background
    owner.native = Native()
    owner.enteredBackground()
    let newer = owner.backgroundTask
    DispatchQueue.main.drain()
    precondition(owner.backgroundTask == newer, "old binding/idle cleanup cannot end new budget")
    owner.queue.drain(); DispatchQueue.main.drain()
    owner.endBackgroundTask()

    owner.native = nil
    owner.enteredBackground()
    let idle = owner.backgroundTask
    owner.queue.drain(); DispatchQueue.main.drain()
    precondition(owner.backgroundTask == .invalid && app.endings.last == idle)

    // Execute the real enhanced-protection callback, including all nested captures.
    let protected = EngineChannel()
    protected.attachProtection()
    protected.native = nil
    protected.backgroundProtection.onChange?(["audioActive": true, "locationActive": false])
    protected.queue.drain()
    precondition(protected.backgroundProtectionActive && protected.backgroundTask == .invalid)
    protected.backgroundProtection.onChange?(["audioActive": false, "locationActive": true])
    protected.queue.drain()
    precondition(protected.backgroundProtectionActive && protected.backgroundTask == .invalid, "remaining location is not lost")
    protected.backgroundProtection.onChange?(["audioActive": false, "locationActive": false])
    precondition(!protected.backgroundProtectionActive && protected.backgroundTask != .invalid, "withdrawal obtains pause budget before queue")
    protected.queue.drain(); DispatchQueue.main.drain()
    precondition(protected.lifecycle.enhanced == [false, false] && protected.backgroundTask == .invalid, "stopped engine releases withdrawal budget")

    protected.backgroundProtection.onChange?(["audioActive": true, "locationActive": false])
    protected.queue.drain()
    protected.backgroundProtection.onChange?(["audioActive": false, "locationActive": false])
    protected.queue.drain() // Withdrawal cleanup is still queued on main.
    protected.native = Native()
    protected.enteredBackground()
    let replacement = protected.backgroundTask
    DispatchQueue.main.drain()
    precondition(replacement != .invalid && protected.backgroundTask == replacement, "old withdrawal cannot end a new observation")
    protected.queue.drain(); DispatchQueue.main.drain()
    protected.endBackgroundTask()

    app.denied = true
    let beforeDenial = app.endings.count
    owner.enteredBackground()
    owner.queue.drain(); DispatchQueue.main.drain()
    precondition(owner.backgroundTask == .invalid && app.endings.count == beforeDenial)
    precondition(owner.lifecycle.foregrounds.last == false, "denial still reports background")
    print("PASS: production pause/ACK ownership, superseding ACKs, expiry, foreground, idle and denial")
  }
}
@main struct Main { static func main() { EngineChannel.check() } }
'''

with tempfile.TemporaryDirectory(prefix="dsh-pause-task-") as temporary:
    temporary = Path(temporary)
    swift = temporary / "check.swift"
    executable = temporary / "check"
    swift.write_text(fixture.replace("  // PRODUCTION", production))
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
